import SwiftUI
import UIKit

/// 识别结果预览页（1:1 对标 Android ScrapeScreens + FilmPolicySheets：任务级第 2 层策略 + 影片级第 3 层策略实时重算 + 冲突预警 + 批量手动修正 + 保留区）。
public struct PreviewTabView: View {
    public let onStartExecution: () -> Void
    private let planId: String
    @Environment(\.dismiss) private var dismiss
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    public init(planId: String, onStartExecution: @escaping () -> Void = {}) {
        self.planId = planId
        self.onStartExecution = onStartExecution
    }

    @State private var planStore = PlanAndTaskStore.shared
    @State private var manualTab = false
    @State private var rematchTargets: [PlanGroup] = []
    @State private var rematchSeasonFilter: Int? = nil
    @State private var showRematchSheet = false
    @State private var rematchApplying = false
    @State private var rematchError: String?
    @State private var editingStrategyGroup: PlanGroup?
    @State private var strategyEpisodeGroups: [TmdbEpisodeGroupSummary] = []
    @State private var strategyLoadEpoch = 0
    @State private var strategyApplying = false
    @State private var strategyError: String?
    @State private var showTaskPolicySheet = false
    @State private var filterKind: PreviewFilterKind = .all
    @State private var categoryToggleSelected = false
    @State private var groupBySource = false
    @State private var editingAssetsGroup: PlanGroup?
    @State private var searchQuery = ""
    @State private var editingFilmPolicyGroup: PlanGroup?
    @State private var batchSelectedManualIds: Set<String> = []
    @State private var errorMsg: String?

    private var activePlan: ScrapePlan? {
        planStore.pendingPlans.first { $0.id == planId }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let plan = activePlan {
                    let ready = plan.groups.filter { $0.kind != "unmatched" }
                    let manual = plan.groups.filter { $0.kind == "unmatched" }
                    let shown = PreviewFilter.apply(groups: manualTab ? manual : ready, kind: filterKind, query: searchQuery, plan: plan)
                    let sections = PreviewSectionGrouping.sections(plan: plan, groups: shown, bySource: groupBySource)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                            Section {
                                let conflicts = ConflictDetector.detect(in: plan.actions)
                                if !manualTab, let conflict = conflicts.first {
                                    Label("检测到 \(conflicts.count) 处命名冲突（如：\(conflict.targetName)），请检查勾选", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
                                }
                                if let errorMsg {
                                    Text(errorMsg).font(.footnote).foregroundStyle(MMTheme.redErr).padding(.horizontal, 20)
                                }
                                if shown.isEmpty {
                                    ContentUnavailableView(manualTab ? "没有待手动识别的项目" : "暂无匹配作品",
                                        systemImage: manualTab ? "checkmark.circle" : "film")
                                }
                                resultCards(plan: plan, sections: sections)
                            } header: {
                                previewHeader(plan: plan, ready: ready, manual: manual)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if showSearch {
                            searchKeyboardBar
                        } else {
                            bottomActions(plan: plan, manual: manual)
                        }
                    }
                } else {
                    ContentUnavailableView("暂无待执行内容", systemImage: "film",
                        description: Text("任务可能已取消或已提交执行，请返回任务中心查看。"))
                }
            }
            .background { previewSurface.ignoresSafeArea() }
            .navigationTitle("识别结果")
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.headline)
                            .frame(width: 36, height: 36).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("返回任务中心")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if showSearch { closeSearch() } else { showSearch = true }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.headline)
                            .frame(width: 36, height: 36).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("搜索识别结果")
                }
            }
            .onChange(of: manualTab) { _, _ in filterKind = .all; categoryToggleSelected = false }
            .sheet(isPresented: $showRematchSheet, onDismiss: {
                rematchApplying = false
                rematchError = nil
                rematchSeasonFilter = nil
            }) {
                if let primary = rematchTargets.first {
                    let submitted = Set(activePlan?.submittedActionIds ?? [])
                    let hasSubmittedActions = activePlan?.actions.contains { action in
                        submitted.contains(action.id) && rematchTargets.contains { $0.id == action.groupId }
                    } ?? false
                    let useTargetMode = primary.kind == "unmatched" || rematchSeasonFilter != nil || hasSubmittedActions
                    let targets = useTargetMode
                        ? buildMatchTargetGroups(for: rematchTargets, plan: activePlan, seasonFilter: rematchSeasonFilter)
                        : []
                    let parsedPrimary = MediaParser.parse(primary.folderName)
                    if useTargetMode && targets.isEmpty {
                        VStack {
                            ContentUnavailableView("没有可重新识别的剩余视频", systemImage: "checkmark.circle",
                                description: Text("已提交的文件请从历史任务重试；剩余素材与目录操作仍可按原计划执行。"))
                            Button("关闭") { showRematchSheet = false }.padding()
                        }
                    } else {
                        ManualMatchSheet(
                            initialQuery: parsedPrimary.cleanTitle,
                            initialKind: primary.kind == "tv" ? "tv" : "movie",
                            initialYear: primary.year.isEmpty ? (parsedPrimary.year.map { "\($0)" } ?? "") : primary.year,
                            applying: rematchApplying,
                            applyError: rematchError,
                            targetGroups: targets,
                            onApply: { picked in
                                if let s = rematchSeasonFilter {
                                    let seasonOverrides = targets.map {
                                        GroupMatchOverride(key: $0.key, actionIds: $0.actionIds, season: s)
                                    }
                                    applyManualMatch(groups: rematchTargets, match: picked, overrides: seasonOverrides)
                                } else {
                                    applyManualMatch(groups: rematchTargets, match: picked, overrides: [])
                                }
                            },
                            onApplyGroups: useTargetMode ? { picked, overrides in
                                applyManualMatch(groups: rematchTargets, match: picked, overrides: overrides)
                            } : nil
                        )
                    }
                }
            }
            .sheet(item: $editingStrategyGroup) { grp in
                EpisodeStrategySheet(
                    current: EpisodeStrategy.fromId(grp.episodeStrategy),
                    applying: strategyApplying,
                    error: strategyError,
                    episodeGroups: strategyEpisodeGroups,
                    selectedEpisodeGroupId: grp.episodeGroupId,
                    onConfirm: { picked in
                        applyEpisodeStrategy(group: grp, strategy: picked, episodeGroupId: nil)
                    },
                    onSelectEpisodeGroup: { gid in
                        applyEpisodeStrategy(group: grp, strategy: EpisodeStrategy.fromId(grp.episodeStrategy), episodeGroupId: gid)
                    }
                )
            }
            .sheet(isPresented: $showTaskPolicySheet) {
                if let plan = activePlan {
                    NavigationStack {
                        DefaultPolicyScreen(
                            initialCategory: .organize,
                            taskOverride: plan.taskPolicy
                        ) { updated in
                            applyTaskPolicy(updated)
                        }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showTaskPolicySheet = false }
                            }
                        }
                    }
                }
            }
            .sheet(item: $editingAssetsGroup) { grp in
                if let plan = activePlan {
                    NavigationStack {
                        DefaultPolicyScreen(
                            initialCategory: .scrape,
                            filmTitle: grp.title.isEmpty ? grp.folderName : grp.title,
                            filmIsTv: grp.kind == "tv",
                            taskOverride: plan.taskPolicy,
                            filmOverride: grp.policyOverride
                        ) { override in
                            applyFilmPolicy(groupId: grp.id, override: override)
                        }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { editingAssetsGroup = nil }
                            }
                        }
                    }
                }
            }
            .sheet(item: $editingFilmPolicyGroup) { grp in
                if let plan = activePlan {
                    NavigationStack {
                        DefaultPolicyScreen(
                            initialCategory: .organize,
                            filmTitle: grp.title.isEmpty ? grp.folderName : grp.title,
                            filmIsTv: grp.kind == "tv",
                            taskOverride: plan.taskPolicy,
                            filmOverride: grp.policyOverride
                        ) { updated in
                            applyFilmPolicy(groupId: grp.id, override: updated)
                        }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { editingFilmPolicyGroup = nil }
                            }
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: "recognitionViewport")
    }

    // 页面和置顶栏使用同一视口坐标的渐变切片；实色底层始终遮住作品内容。
    private var previewSurface: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground)
                LinearGradient(
                    colors: [MMTheme.accent.opacity(0.22), MMTheme.accent.opacity(0.06), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 180)
                .offset(y: -geometry.frame(in: .named("recognitionViewport")).minY)
            }
            .clipped()
        }
        .allowsHitTesting(false)
    }

    private func previewHeader(plan: ScrapePlan, ready: [PlanGroup], manual: [PlanGroup]) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("任务 ID：\(plan.id)，共 \(plan.uniqueMediaCount) 部影片")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Picker("识别状态", selection: $manualTab) {
                Text("可整理 (\(ready.count))").tag(false)
                Text("待手动识别 (\(manual.count))").tag(true)
            }
            .pickerStyle(.segmented)
            if !manualTab {
                HStack(spacing: 6) {
                    ForEach(PreviewFilterKind.visibleCases) { kind in
                        Button { selectCategory(kind, plan: plan) } label: {
                            Text(kind.rawValue).font(.caption.weight(.medium)).lineLimit(1)
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(filterKind == kind ? MMTheme.accent : Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(filterKind == kind ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("再次点击全选该分组，再次点击取消全选")
                    }
                    Button { groupBySource.toggle() } label: {
                        Image(systemName: groupBySource ? "folder" : "square.grid.2x2")
                            .font(.caption).frame(width: 28, height: 28)
                    }
                    .accessibilityLabel(groupBySource ? "切换为按类别分组" : "切换为按来源分组")
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background { previewSurface }
    }

    private var searchKeyboardBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索片名、目录、年份或 TMDB ID", text: $searchQuery)
                    .focused($searchFocused).submitLabel(.search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { searchFocused = false }
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("清空搜索")
                }
            }
            .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            Button("取消", action: closeSearch).font(.subheadline).foregroundStyle(MMTheme.accent)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(.bar)
        .onAppear { searchFocused = true }
    }

    private func closeSearch() {
        searchFocused = false
        showSearch = false
        searchQuery = ""
    }

    private func selectCategory(_ kind: PreviewFilterKind, plan: ScrapePlan) {
        guard filterKind == kind else { filterKind = kind; categoryToggleSelected = false; return }
        let groups = PreviewFilter.apply(groups: plan.groups.filter { $0.kind != "unmatched" }, kind: kind, query: searchQuery, plan: plan)
        let groupIds = Set(groups.map(\.id))
        let actions = plan.actions.filter { groupIds.contains($0.groupId) && !(plan.submittedActionIds ?? []).contains($0.id) && PlanSelection.executable($0) }
        guard !actions.isEmpty else { return }
        categoryToggleSelected.toggle()
        planStore.savePendingPlan(PlanSelection.set(plan: plan, ids: actions.map(\.id), on: categoryToggleSelected))
    }

    private func resultCards(plan: ScrapePlan, sections: [PreviewSectionGrouping.Section]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { sec in
                VStack(alignment: .leading, spacing: 8) {
                    Text(sec.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    ForEach(sec.groups) { group in
                        let groupActions = plan.actions.filter { $0.groupId == group.id && !(plan.submittedActionIds ?? []).contains($0.id) }
                        VStack(alignment: .leading, spacing: 8) {
                            if group.confirmRequired {
                                Label("需人工确认：\(group.confirmReasons.joined(separator: "、"))", systemImage: "exclamationmark.shield.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            MediaGroupCardRow(
                                group: group,
                                actions: groupActions,
                                hasTaskOverride: plan.taskPolicy != nil,
                                isManualMode: manualTab,
                                isBatchSelected: batchSelectedManualIds.contains(group.id),
                                onToggleBatchManual: {
                                    if batchSelectedManualIds.contains(group.id) {
                                        batchSelectedManualIds.remove(group.id)
                                    } else {
                                        batchSelectedManualIds.insert(group.id)
                                    }
                                },
                                onToggleGroup: { on in toggleGroup(groupId: group.id, selected: on) },
                                onRematch: { season in
                                    rematchTargets = [group]
                                    rematchSeasonFilter = season
                                    showRematchSheet = true
                                },
                                onParkRetention: {
                                    parkToRetention(plan: plan, group: group, actions: groupActions)
                                },
                                detailDestination: {
                                    MediaDetailView(
                                        planId: plan.id,
                                        groupId: group.id,
                                        onRematch: {
                                            let latest = activePlan?.groups.first(where: { $0.id == group.id }) ?? group
                                            rematchTargets = [latest]
                                            rematchSeasonFilter = nil
                                            showRematchSheet = true
                                        },
                                        onEditPolicy: {
                                            editingFilmPolicyGroup = activePlan?.groups.first(where: { $0.id == group.id }) ?? group
                                        },
                                        onEditAssets: {
                                            editingAssetsGroup = activePlan?.groups.first(where: { $0.id == group.id }) ?? group
                                        },
                                        onEditEpisodeStrategy: group.kind == "tv" ? {
                                            let latest = activePlan?.groups.first(where: { $0.id == group.id }) ?? group
                                            strategyError = nil
                                            strategyEpisodeGroups = []
                                            editingStrategyGroup = latest
                                            if let tid = latest.tmdbId {
                                                strategyLoadEpoch += 1
                                                let epoch = strategyLoadEpoch
                                                let targetGid = group.id
                                                Task {
                                                    let loaded = await TmdbClient.shared.tvEpisodeGroups(tvId: tid)
                                                    await MainActor.run {
                                                        guard strategyLoadEpoch == epoch, editingStrategyGroup?.id == targetGid else { return }
                                                        strategyEpisodeGroups = loaded
                                                    }
                                                }
                                            }
                                        } : nil
                                    )
                                }
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func bottomActions(plan: ScrapePlan, manual: [PlanGroup]) -> some View {
        let selectedCount = ExecutionEngine.executableActionIds(plan: plan).count
        if manualTab && !batchSelectedManualIds.isEmpty {
            HStack {
                Text("已选 \(batchSelectedManualIds.count) 组待确认项").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button {
                    rematchTargets = manual.filter { batchSelectedManualIds.contains($0.id) }
                    rematchSeasonFilter = nil
                    showRematchSheet = true
                } label: {
                    Text("批量匹配 (\(batchSelectedManualIds.count))")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(MMTheme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding()
            .background(.bar)
        } else if !manualTab {
            HStack(spacing: 12) {
                Button {
                    showTaskPolicySheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(MMTheme.accent)
                        Text("任务策略")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(.label))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                }
                .buttonStyle(.plain)

                Button {
                    execute(plan: plan)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: ExecutionEngine.shared.isRunning ? "text.badge.plus" : "play.fill")
                        Text(ExecutionEngine.shared.isRunning ? "加入队列" : "立即执行")
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .foregroundStyle(.white).background(MMTheme.accent, in: Capsule())
                    .shadow(color: MMTheme.accent.opacity(0.28), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(selectedCount == 0)
                .opacity(selectedCount == 0 ? 0.5 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func applyTaskPolicy(_ override: PolicyOverride?) {
        guard var plan = activePlan else { return }
        let global = AppSettings.shared.policies
        plan.taskPolicy = override
        plan = PolicyResolver.applyOverrides(to: plan, global: global)
        let mergeEnabled = plan.taskPolicy?.mergeSeries ?? global.mergeSeries
        let mergeMovies = plan.taskPolicy?.mergeMovieSeries ?? global.mergeMovieSeries
        let mergeTv = plan.taskPolicy?.mergeTvSeries ?? global.mergeTvSeries
        let appendTag = (plan.taskPolicy?.movieNaming ?? global.movieNaming).folderTmdbEnabled
        plan = SeriesMerger.mergeIfEnabled(plan, enabled: mergeEnabled, appendTag: appendTag, mergeMovies: mergeMovies, mergeTv: mergeTv)
        PlanAndTaskStore.shared.savePendingPlan(plan)
    }

    private func applyFilmPolicy(groupId: String, override: PolicyOverride?) {
        guard var plan = activePlan, let idx = plan.groups.firstIndex(where: { $0.id == groupId }) else { return }
        plan.groups[idx].policyOverride = override
        plan = PolicyResolver.applyOverrides(to: plan, global: AppSettings.shared.policies)
        PlanAndTaskStore.shared.savePendingPlan(plan)
    }

    private func execute(plan: ScrapePlan) {
        guard let acct = AccountStore.shared.accounts.first(where: { $0.id == plan.accountId }) else {
            errorMsg = "找不到对应的云盘账号"
            return
        }
        do {
            let drive = try AccountStore.shared.buildDrive(for: acct)
            if ExecutionEngine.shared.enqueueOrStart(plan: plan, drive: drive) {
                onStartExecution()
                dismiss()
            } else {
                errorMsg = ExecutionEngine.shared.lastStartError
            }
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    private func parkToRetention(plan: ScrapePlan, group: PlanGroup, actions: [PlanAction]) {
        guard let acct = AccountStore.shared.accounts.first(where: { $0.id == plan.accountId }),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            errorMsg = "未找到该计划对应的原网盘账号，已取消移入保留区"
            return
        }
        let targets = actions.filter { ($0.fileId ?? "").isEmpty == false }
        guard !targets.isEmpty else {
            return
        }
        Task {
            var movedIds: [String] = []
            for act in targets {
                guard let fid = act.fileId, !fid.isEmpty else { continue }
                let fname = act.oldName.isEmpty ? group.folderName : act.oldName
                let origParent = act.parentId ?? group.folderId ?? drive.rootId
                do {
                    _ = try await CloudRetentionZone.parkToCloud(
                        fileId: fid, fileName: fname, originalParentId: origParent,
                        reason: "预览页手动移入保留区", drive: drive
                    )
                    movedIds.append(act.id)
                } catch {
                    await MainActor.run { errorMsg = "移入保留区失败（\(fname)）：\(error.localizedDescription)" }
                }
            }
            if !movedIds.isEmpty {
                await MainActor.run {
                    let latest = PlanAndTaskStore.shared.plans.first(where: { $0.id == plan.id }) ?? plan
                    PlanAndTaskStore.shared.savePendingPlan(PlanSelection.set(plan: latest, ids: movedIds, on: false))
                }
            }
        }
    }


    private func toggleGroup(groupId: String, selected: Bool) {
        guard let plan = activePlan else { return }
        let ids = PlanSelection.groupIds(plan: plan, groupId: groupId).filter { !(plan.submittedActionIds ?? []).contains($0) }
        PlanAndTaskStore.shared.savePendingPlan(PlanSelection.set(plan: plan, ids: ids, on: selected))
    }

    private func buildMatchTargetGroups(for groups: [PlanGroup], plan: ScrapePlan?, seasonFilter: Int? = nil) -> [MatchTargetGroup] {
        guard let plan else { return [] }
        return groups.compactMap { grp in
            let allFiles = plan.manualMatchActions(groupId: grp.id)
            let fileActions: [PlanAction]
            if let seasonFilter {
                let bySeason = allFiles.filter { act in
                    let s = act.season ?? MediaParser.parse(act.oldName.isEmpty ? act.newName : act.oldName, folderHint: grp.folderName).season ?? 1
                    return s == seasonFilter
                }
                fileActions = bySeason
            } else {
                fileActions = allFiles
            }
            guard !fileActions.isEmpty else { return nil }
            let files = fileActions.map { MatchTargetGroup.FileItem(id: $0.id, name: $0.oldName.isEmpty ? $0.newName : $0.oldName) }
            let first = fileActions.first
            let basePath = grp.folderPath ?? grp.folderName
            let displayPath = seasonFilter.map { "\(basePath) · \($0 == 0 ? "特别篇" : "第 \($0) 季")" } ?? basePath
            return MatchTargetGroup(
                key: seasonFilter.map { "\(grp.id)-s\($0)" } ?? grp.id,
                folderPath: displayPath,
                actionIds: fileActions.map(\.id),
                files: files,
                sampleFileName: first?.oldName ?? "",
                suggestedSeason: seasonFilter ?? first?.season,
                suggestedYear: grp.year,
                suggestedEpisode: first?.episode
            )
        }
    }

    private func applyManualMatch(groups: [PlanGroup], match: MatchInfo, overrides: [GroupMatchOverride] = []) {
        if let plan = activePlan,
           let acct = AccountStore.shared.accounts.first(where: { $0.id == plan.accountId }),
           let drive = try? AccountStore.shared.buildDrive(for: acct) {
            rematchApplying = true
            rematchError = nil
            Task {
                do {
                    var cur = plan
                    let hasFileOverrides = overrides.contains { !$0.actionIds.isEmpty }
                    let beforeFlags = Set(cur.flags)
                    if hasFileOverrides {
                        cur = try await Scanner.replanTargetGroups(plan: cur, targets: overrides, info: match, drive: drive)
                    } else {
                        for grp in groups {
                            cur = try await Scanner.replanGroup(plan: cur, groupId: grp.id, info: match, drive: drive)
                        }
                    }
                    let newFailFlag = cur.flags.first(where: { !beforeFlags.contains($0) && $0.contains("批量识别未完成") })
                    await MainActor.run {
                        do { try PlanAndTaskStore.shared.saveEditedPlan(cur, original: plan) }
                        catch { rematchApplying = false; rematchError = error.localizedDescription; return }
                        batchSelectedManualIds.removeAll()
                        rematchApplying = false
                        if let failMsg = newFailFlag {
                            rematchError = failMsg
                        } else {
                            rematchError = nil
                            showRematchSheet = false
                        }
                    }
                } catch {
                    await MainActor.run {
                        rematchApplying = false
                        rematchError = error.localizedDescription
                    }
                }
            }
            return
        }
        applyManualMatchLocalFallback(groups: groups, match: match)
        batchSelectedManualIds.removeAll()
        showRematchSheet = false
    }

    private func applyEpisodeStrategy(group: PlanGroup, strategy: EpisodeStrategy, episodeGroupId: String?) {
        guard var plan = activePlan,
              let acct = AccountStore.shared.accounts.first(where: { $0.id == plan.accountId }),
              let drive = try? AccountStore.shared.buildDrive(for: acct),
              let tmdbId = group.tmdbId else {
            strategyError = "缺少有效云盘账号或 TMDB ID，无法切换剧集策略"
            return
        }
        if let idx = plan.groups.firstIndex(where: { $0.id == group.id }) {
            plan.groups[idx].episodeStrategy = strategy.rawValue
            plan.groups[idx].episodeGroupId = episodeGroupId
            plan.groups[idx].episodeGroupName = strategyEpisodeGroups.first(where: { $0.id == episodeGroupId })?.name ?? (episodeGroupId == group.episodeGroupId ? group.episodeGroupName : nil)
        }
        let info = MatchInfo(
            kind: "tv",
            id: tmdbId,
            title: group.title,
            year: group.year,
            posterPath: group.posterPath,
            backdropPath: nil,
            originalTitle: group.originalTitle,
            overview: "",
            rating: group.rating
        )
        strategyApplying = true
        strategyError = nil
        let targetPlan = plan
        Task {
            do {
                let pickedGroupName = strategyEpisodeGroups.first(where: { $0.id == episodeGroupId })?.name
                let replanned = try await Scanner.replanGroup(
                    plan: targetPlan,
                    groupId: group.id,
                    info: info,
                    drive: drive,
                    strategy: strategy,
                    episodeGroupId: episodeGroupId,
                    episodeGroupName: pickedGroupName
                )
                await MainActor.run {
                    do { try PlanAndTaskStore.shared.saveEditedPlan(replanned, original: targetPlan) }
                    catch { strategyApplying = false; strategyError = error.localizedDescription; return }
                    strategyApplying = false
                    if editingStrategyGroup?.id == group.id, let updated = replanned.groups.first(where: { $0.id == group.id }) {
                        editingStrategyGroup = updated
                    }
                }
            } catch {
                await MainActor.run {
                    strategyApplying = false
                    strategyError = error.localizedDescription
                }
            }
        }
    }

    private func applyManualMatchLocalFallback(groups: [PlanGroup], match: MatchInfo) {
        guard var plan = activePlan else { return }
        let global = AppSettings.shared.policies
        let targetIds = Set(groups.map(\.id))

        for i in plan.groups.indices where targetIds.contains(plan.groups[i].id) {
            let isTv = match.kind == "tv"
            let eff = PolicyResolver.resolve(isTv: isTv, global: global, task: plan.taskPolicy, film: plan.groups[i].policyOverride)
            let fileOpts = eff.naming.fileOptions()
            let rawFolder = plan.groups[i].folderName
            let targetFolder = StandardNaming.folderName(title: match.title, year: match.year, tmdbId: match.id, prefs: eff.naming)

            plan.groups[i].kind = match.kind
            plan.groups[i].tmdbId = match.id
            plan.groups[i].title = match.title
            plan.groups[i].year = match.year
            plan.groups[i].posterPath = match.posterPath
            plan.groups[i].folderNewName = targetFolder == rawFolder ? nil : targetFolder
            plan.groups[i].confidence = "手动"
            plan.groups[i].warn = nil

            let gid = plan.groups[i].id
            plan.actions.removeAll { a in
                a.groupId == gid && !a.done && a.op == "artwork" && a.mediaKind != nil && a.mediaKind != match.kind
            }
            for aIdx in plan.actions.indices where plan.actions[aIdx].groupId == gid && plan.actions[aIdx].op == "unmatched" {
                let old = plan.actions[aIdx].oldName
                let (oldStem, ext) = MediaParser.splitNameExt(old)
                let pm = MediaParser.parse(old, folderHint: rawFolder)
                let newName: String
                if isTv {
                    newName = StandardNaming.episodeFileBase(
                        title: match.title,
                        season: pm.season ?? 1,
                        episode: pm.episode ?? 1,
                        episodeEnd: pm.episodeEnd,
                        tmdbId: match.id,
                        fileStem: oldStem,
                        releaseDirName: rawFolder,
                        options: fileOpts,
                        year: match.year
                    ) + ext
                } else {
                    newName = StandardNaming.movieFileBase(
                        title: match.title,
                        year: match.year,
                        tmdbId: match.id,
                        fileStem: oldStem,
                        releaseDirName: rawFolder,
                        options: fileOpts
                    ) + ext
                }
                plan.actions[aIdx] = PlanAction(
                    id: plan.actions[aIdx].id,
                    op: "rename",
                    groupId: gid,
                    fileId: plan.actions[aIdx].fileId,
                    parentId: plan.actions[aIdx].parentId,
                    oldName: old,
                    newName: newName,
                    destParentId: nil,
                    destRef: nil,
                    kind: "file",
                    mediaKind: match.kind,
                    tmdbId: match.id,
                    season: isTv ? (pm.season ?? 1) : nil,
                    episode: isTv ? (pm.episode ?? 1) : nil,
                    artworkUrl: nil,
                    selected: eff.organizeEnabled && eff.renameFiles,
                    done: false,
                    error: nil,
                    note: "手动匹配生成"
                )
            }

            let settings = AppSettings.shared
            if let fid = plan.groups[i].folderId {
                if eff.scrapeEnabled && eff.writeNfo {
                    let nfoKind = isTv ? "tvshow_nfo" : "movie_nfo"
                    let nfoName = isTv ? "tvshow.nfo" : "movie.nfo"
                    if !plan.actions.contains(where: { $0.groupId == gid && $0.kind == nfoKind }) {
                        plan.actions.append(PlanAction(id: "act-\(UUID().uuidString.prefix(8).lowercased())", op: "artwork", groupId: gid, fileId: nil, parentId: fid, oldName: "", newName: nfoName, destParentId: fid, destRef: nil, kind: nfoKind, mediaKind: match.kind, tmdbId: match.id, season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: "手动匹配生成 NFO"))
                    }
                }
                if eff.scrapeEnabled && eff.downloadPoster, let pp = match.posterPath,
                   !plan.actions.contains(where: { $0.groupId == gid && $0.newName == "poster.jpg" }) {
                    let url = settings.imageUrl(path: pp, size: eff.imageQuality.posterSize)?.absoluteString
                    plan.actions.append(PlanAction(id: "act-\(UUID().uuidString.prefix(8).lowercased())", op: "artwork", groupId: gid, fileId: nil, parentId: fid, oldName: "", newName: "poster.jpg", destParentId: fid, destRef: nil, kind: "image", mediaKind: match.kind, tmdbId: match.id, season: nil, episode: nil, artworkUrl: url, selected: true, done: false, error: nil, note: "手动匹配下载海报"))
                }
            }

            let cleanPat = MediaParser.parse(rawFolder).cleanTitle
            Task {
                await AiRuleDistiller.shared.distill(pattern: cleanPat, targetTitle: match.title, mediaType: match.kind, tmdbId: match.id)
            }
        }
        PlanAndTaskStore.shared.savePendingPlan(plan)
    }
}

private struct MediaGroupCardRow<DetailDestination: View>: View {
    let group: PlanGroup
    let actions: [PlanAction]
    let hasTaskOverride: Bool
    let isManualMode: Bool
    let isBatchSelected: Bool
    let onToggleBatchManual: () -> Void
    let onToggleGroup: (Bool) -> Void
    let onRematch: (Int?) -> Void
    let onParkRetention: () -> Void
    @ViewBuilder let detailDestination: () -> DetailDestination

    @State private var expanded = false
    @State private var selectedSeason: Int?
    @State private var slideForward = true
    @State private var tmdbTotalCounts: (seasons: Int, episodes: Int)? = nil

    private var folderPathParts: (srcParent: String, srcName: String, dstParent: String, dstName: String) {
        let rawPath = (group.folderPath?.isEmpty == false ? group.folderPath : nil)
            ?? actions.first(where: { ($0.folderPath ?? "").isEmpty == false })?.folderPath
            ?? ""
        let cleanPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fallbackName = group.folderName.isEmpty
            ? (cleanPath.split(separator: "/").last.map(String.init) ?? "")
            : group.folderName

        let srcParent: String
        let srcName: String
        if !cleanPath.isEmpty {
            let comps = cleanPath.split(separator: "/").map(String.init)
            if comps.count >= 2 {
                if comps.last == fallbackName || group.folderName.isEmpty {
                    srcParent = "/" + comps.dropLast().joined(separator: "/")
                    srcName = comps.last ?? fallbackName
                } else {
                    srcParent = "/" + comps.joined(separator: "/")
                    srcName = fallbackName
                }
            } else if comps.first == fallbackName {
                srcParent = ""
                srcName = fallbackName
            } else {
                srcParent = "/" + comps.joined(separator: "/")
                srcName = fallbackName
            }
        } else {
            srcParent = ""
            srcName = fallbackName
        }

        let customDestParent: String? = actions.first(where: {
            $0.op == "move" && $0.kind == "folder" && $0.fileId == group.folderId && ($0.destLabel ?? "").isEmpty == false
        })?.destLabel
        let dstParent: String = {
            if let dp = customDestParent, !dp.isEmpty {
                let norm = dp.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return norm.isEmpty ? srcParent : "/\(norm)"
            }
            return srcParent
        }()
        let dstName = (group.folderNewName?.isEmpty == false ? group.folderNewName! : srcName)
        return (srcParent, srcName, dstParent, dstName)
    }

    private var posterUrl: URL? {
        if let pp = group.posterPath, !pp.isEmpty {
            return AppSettings.shared.imageUrl(path: pp, size: "w185")
        }
        if let fallback = actions.first(where: { $0.kind == "image" && $0.newName.lowercased() == "poster.jpg" })?.artworkUrl {
            return URL(string: fallback.replacingOccurrences(of: "/t/p/w780/", with: "/t/p/w185/"))
        }
        return nil
    }

    private var kindBadge: String {
        switch group.kind {
        case "tv": return "剧集"
        case "movie": return "电影"
        case "collection": return "合集"
        default: return "待识别"
        }
    }

    /// 仅保留视频/集文件条目并按 fileId 去重（合并 rename + move，避免同一集重复计数）。
    private var episodeFileActions: [PlanAction] {
        var merged: [String: PlanAction] = [:]
        var order: [String] = []
        for act in actions where act.kind == "file" || act.op == "unmatched" {
            let key = act.fileId ?? act.id
            if let existing = merged[key] {
                if existing.op != "rename" && act.op == "rename" {
                    merged[key] = act
                }
            } else {
                merged[key] = act
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
            .sorted { a, b in
                let sa = resolvedSeason(for: a)
                let sb = resolvedSeason(for: b)
                if sa != sb { return sa < sb }
                let ea = a.episode ?? Int.max
                let eb = b.episode ?? Int.max
                if ea != eb { return ea < eb }
                let na = a.newName.isEmpty ? a.oldName : a.newName
                let nb = b.newName.isEmpty ? b.oldName : b.newName
                return na.localizedStandardCompare(nb) == .orderedAscending
            }
    }

    private func resolvedSeason(for act: PlanAction) -> Int {
        if let s = act.season { return s }
        let parsed = MediaParser.parse(act.oldName.isEmpty ? act.newName : act.oldName, folderHint: group.folderName)
        return parsed.season ?? 1
    }

    private func resolvedEpisode(for act: PlanAction) -> Int? {
        if let e = act.episode { return e }
        return MediaParser.parse(act.oldName.isEmpty ? act.newName : act.oldName, folderHint: group.folderName).episode
    }

    private func episodeGroupKey(for act: PlanAction) -> String {
        if group.kind == "tv", let ep = resolvedEpisode(for: act) {
            return String(format: "S%02dE%02d", resolvedSeason(for: act), ep)
        }
        return act.fileId ?? act.id
    }

    private var uniqueEpisodeCount: Int {
        guard group.kind == "tv" else { return episodeFileActions.count }
        return Set(episodeFileActions.map { episodeGroupKey(for: $0) }).count
    }

    private var hasMultiVersion: Bool {
        if group.kind == "tv" {
            return episodeFileActions.count > uniqueEpisodeCount
        }
        if group.kind == "movie" {
            return episodeFileActions.count > 1
        }
        return false
    }

    private struct SeasonBucket: Identifiable {
        let season: Int
        let items: [PlanAction]
        let uniqueEpisodes: Int
        var id: Int { season }
        var label: String { season == 0 ? "特别篇" : "第 \(season) 季" }
        var countLabel: String {
            if items.count > uniqueEpisodes {
                return "\(uniqueEpisodes) 集 · \(items.count) 文件"
            }
            return "\(items.count)"
        }
    }

    private var seasonBuckets: [SeasonBucket] {
        guard group.kind == "tv" else { return [] }
        var map: [Int: [PlanAction]] = [:]
        for act in episodeFileActions {
            let s = resolvedSeason(for: act)
            map[s, default: []].append(act)
        }
        return map.keys.sorted().map { s in
            let bucketItems = map[s] ?? []
            let uniq = Set(bucketItems.map { episodeGroupKey(for: $0) }).count
            return SeasonBucket(season: s, items: bucketItems, uniqueEpisodes: uniq)
        }
    }

    private var activeSeasonNumber: Int {
        let buckets = seasonBuckets
        if let s = selectedSeason, buckets.contains(where: { $0.season == s }) {
            return s
        }
        return buckets.first?.season ?? 1
    }

    private func selectSeason(_ target: Int, in buckets: [SeasonBucket]) {
        let current = activeSeasonNumber
        guard target != current,
              let curIdx = buckets.firstIndex(where: { $0.season == current }),
              let dstIdx = buckets.firstIndex(where: { $0.season == target }) else {
            return
        }
        slideForward = dstIdx > curIdx
        withAnimation(.easeInOut(duration: 0.28)) {
            selectedSeason = target
        }
    }

    private func stepSeason(delta: Int, in buckets: [SeasonBucket]) {
        guard buckets.count > 1,
              let curIdx = buckets.firstIndex(where: { $0.season == activeSeasonNumber }) else {
            return
        }
        let nextIdx = curIdx + delta
        guard buckets.indices.contains(nextIdx) else { return }
        slideForward = delta > 0
        withAnimation(.easeInOut(duration: 0.28)) {
            selectedSeason = buckets[nextIdx].season
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                NavigationLink {
                    detailDestination()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.secondary.opacity(0.16))
                            TmdbImageView(
                                url: posterUrl,
                                placeholderSystemName: group.kind == "tv" ? "tv" : "film"
                            )
                            Text(kindBadge)
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MMTheme.purpleBadge, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .frame(width: 64, height: 94)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title.isEmpty ? group.folderName : group.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                if !group.year.isEmpty { Text(group.year) }
                                if let r = group.rating, r > 0 { Text(String(format: "★ %.1f", r)) }
                                if let tid = group.tmdbId { Text("TMDB \(tid)") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if group.kind == "tv", !episodeFileActions.isEmpty {
                                let recText = "已识别 \(max(1, seasonBuckets.count)) 季 \(uniqueEpisodeCount) 集"
                                let fullText: String = {
                                    if let c = tmdbTotalCounts {
                                        return "\(recText) | 共 \(c.seasons) 季 \(c.episodes) 集"
                                    }
                                    return recText
                                }()
                                Text(fullText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.88)
                            } else if group.kind == "unmatched" {
                                Text("同目录待手动识别")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if episodeFileActions.isEmpty {
                                Text("目录或素材操作")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 10) {
                                HStack(spacing: 4) {
                                    Image(systemName: "film")
                                        .font(.caption2)
                                    Text("\(episodeFileActions.count)")
                                        .font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(.secondary)

                                if let conf = group.confidence, !conf.isEmpty {
                                    let confColor: Color = switch conf {
                                    case "高": MMTheme.greenOk
                                    case "手动": MMTheme.accent
                                    case "中": .orange
                                    default: MMTheme.redErr
                                    }
                                    Text("置信度：\(conf)")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(confColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(confColor.opacity(0.14), in: Capsule())
                                }

                                if hasMultiVersion {
                                    Text("多版本")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(MMTheme.purpleBadge)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(MMTheme.purpleBadge.opacity(0.14), in: Capsule())
                                }
                            }

                            if group.policyOverride != nil {
                                Text("已启用影片级策略覆盖").font(.caption2).foregroundStyle(MMTheme.accent)
                            } else if hasTaskOverride {
                                Text("继承任务级策略").font(.caption2).foregroundStyle(.secondary)
                            }

                            if let warn = group.warn {
                                Text(warn).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .trailing, spacing: 6) {
                    if isManualMode {
                        Button {
                            onToggleBatchManual()
                        } label: {
                            Image(systemName: isBatchSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isBatchSelected ? MMTheme.accent : .secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)

                        Button("保留区") { onParkRetention() }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.borderless)
                    } else {
                        let execs = actions.filter { PlanSelection.executable($0) }
                        if !execs.isEmpty {
                            let allOn = execs.allSatisfy(\.selected)
                            Button {
                                onToggleGroup(!allOn)
                            } label: {
                                Image(systemName: allOn ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(allOn ? MMTheme.accent : .secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            let fp = folderPathParts
            if !fp.srcName.isEmpty {
                Divider().opacity(0.45)
                NavigationLink {
                    detailDestination()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundStyle(Color(.secondaryLabel))
                            if !fp.srcParent.isEmpty {
                                Text(fp.srcParent)
                                    .font(.caption)
                                    .foregroundStyle(Color(.secondaryLabel))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Text("/")
                                    .font(.caption)
                                    .foregroundStyle(Color(.tertiaryLabel))
                            }
                            Text(fp.srcName)
                                .font(.caption)
                                .foregroundStyle(Color(.secondaryLabel))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }

                        if group.kind != "unmatched" {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.caption)
                                    .foregroundStyle(Color(.label))
                                if !fp.dstParent.isEmpty {
                                    Text(fp.dstParent)
                                        .font(.caption)
                                        .foregroundStyle(Color(.label))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Text("/")
                                        .font(.caption)
                                        .foregroundStyle(Color(.tertiaryLabel))
                                }
                                Text(fp.dstName)
                                    .font(.caption)
                                    .foregroundStyle(fp.dstParent.isEmpty ? Color(.label) : Color(.secondaryLabel))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.26)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(group.kind == "tv"
                             ? (expanded ? "收起剧集详情" : "查看剧集详情")
                             : (expanded ? "收起整理详情" : "查看整理详情"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(MMTheme.accent)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MMTheme.accent)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    expandedDetailContent
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipped()
        }
        .padding(.vertical, 2)
        .task(id: group.tmdbId) {
            guard group.kind == "tv", let tid = group.tmdbId else {
                tmdbTotalCounts = nil
                return
            }
            let counts = await TmdbClient.shared.tvSeasonEpisodeCounts(id: tid)
            guard !Task.isCancelled else { return }
            tmdbTotalCounts = counts
        }
    }

    @ViewBuilder
    private var expandedDetailContent: some View {
        let buckets = seasonBuckets
        VStack(alignment: .leading, spacing: 10) {
            if group.kind == "tv" && !buckets.isEmpty {
                if buckets.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(buckets) { b in
                                let isOn = b.season == activeSeasonNumber
                                Button {
                                    selectSeason(b.season, in: buckets)
                                } label: {
                                    Text("\(b.label) (\(b.items.count))")
                                        .font(.caption.weight(isOn ? .semibold : .regular))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(isOn ? MMTheme.accent : Color.secondary.opacity(0.14), in: Capsule())
                                        .foregroundStyle(isOn ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    let activeItems = buckets.first(where: { $0.season == activeSeasonNumber })?.items ?? []
                    ZStack(alignment: .topLeading) {
                        episodeRowsList(activeItems)
                            .id(activeSeasonNumber)
                            .transition(.asymmetric(
                                insertion: .move(edge: slideForward ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: slideForward ? .leading : .trailing).combined(with: .opacity)
                            ))
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard abs(dx) > abs(dy) * 1.4, abs(dx) > 40 else { return }
                                stepSeason(delta: dx < 0 ? 1 : -1, in: buckets)
                            }
                    )
                } else if let only = buckets.first {
                    Text("\(only.label)（\(only.countLabel)）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MMTheme.accent)
                    episodeRowsList(only.items)
                }
            } else if !episodeFileActions.isEmpty {
                episodeRowsList(episodeFileActions)
            } else {
                Text("当前剩余操作不包含视频文件，可进入作品详情查看目录和素材。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let rematchSeason: Int? = (group.kind == "tv" && buckets.count > 1) ? activeSeasonNumber : nil
            let rematchTitle: String = {
                if let s = rematchSeason {
                    return s == 0 ? "手动识别特别篇" : "手动识别第 \(s) 季"
                }
                return "手动识别"
            }()
            Button {
                onRematch(rematchSeason)
            } label: {
                Label(rematchTitle, systemImage: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(MMTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(MMTheme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private struct GroupedEpisodeRow: Identifiable {
        let id: String
        let headerLabel: String
        let versions: [PlanAction]
    }

    private func buildGroupedRows(_ items: [PlanAction]) -> [GroupedEpisodeRow] {
        guard group.kind == "tv" else {
            return items.map { GroupedEpisodeRow(id: $0.id, headerLabel: "", versions: [$0]) }
        }
        var order: [String] = []
        var bucket: [String: [PlanAction]] = [:]
        for act in items {
            let key = episodeGroupKey(for: act)
            if bucket[key] == nil { order.append(key) }
            bucket[key, default: []].append(act)
        }
        return order.map { key in
            GroupedEpisodeRow(id: key, headerLabel: key, versions: bucket[key] ?? [])
        }
    }

    private func versionBadgeLabel(for act: PlanAction, fallbackIndex: Int) -> String {
        let display = act.newName.isEmpty ? act.oldName : act.newName
        let stem = MediaParser.splitNameExt(display).0
        let ver = StandardNaming.parseVersion(fileStem: stem).label
        if !ver.isEmpty { return ver }
        let oldStem = MediaParser.splitNameExt(act.oldName).0
        let oldVer = StandardNaming.parseVersion(fileStem: oldStem).label
        return oldVer.isEmpty ? "版本 \(fallbackIndex + 1)" : oldVer
    }

    @ViewBuilder
    private func episodeRowsList(_ items: [PlanAction]) -> some View {
        let rows = buildGroupedRows(items)
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                if row.versions.count >= 2 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(row.headerLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(row.versions.count) 个版本")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(MMTheme.purpleBadge)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(MMTheme.purpleBadge.opacity(0.14), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        ForEach(Array(row.versions.enumerated()), id: \.element.id) { vIdx, act in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(versionBadgeLabel(for: act, fallbackIndex: vIdx))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(MMTheme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(MMTheme.accent.opacity(0.12), in: Capsule())
                                        .lineLimit(1)
                                    Text(act.newName.isEmpty ? act.oldName : act.newName)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if !act.oldName.isEmpty && act.oldName != act.newName {
                                    Text(act.oldName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.leading, 4)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let act = row.versions.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(act.newName.isEmpty ? act.oldName : act.newName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if !act.oldName.isEmpty && act.oldName != act.newName {
                            Text(act.oldName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if idx < rows.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
        if rows.count > 5 {
            ScrollView {
                content
            }
            .frame(maxHeight: 280)
        } else {
            content
        }
    }
}
