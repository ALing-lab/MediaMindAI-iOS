import SwiftUI
import UIKit

/// 识别结果预览页（1:1 对标 Android ScrapeScreens + FilmPolicySheets：任务级第 2 层策略 + 影片级第 3 层策略实时重算 + 冲突预警 + 批量手动修正 + 保留区）。
public struct PreviewTabView: View {
    public let onStartExecution: () -> Void
    public init(onStartExecution: @escaping () -> Void = {}) {
        self.onStartExecution = onStartExecution
    }

    @State private var planStore = PlanAndTaskStore.shared
    @State private var selectedPlanId: String?
    @State private var manualTab = false
    @State private var rematchTargets: [PlanGroup] = []
    @State private var showRematchSheet = false
    @State private var rematchApplying = false
    @State private var rematchError: String?
    @State private var editingStrategyGroup: PlanGroup?
    @State private var strategyEpisodeGroups: [TmdbEpisodeGroupSummary] = []
    @State private var strategyApplying = false
    @State private var strategyError: String?
    @State private var showTaskPolicySheet = false
    @State private var showInboxSheet = false
    @State private var filterKind: PreviewFilterKind = .all
    @State private var groupBySource = false
    @State private var editingAssetsGroup: PlanGroup?
    @State private var searchQuery = ""
    @State private var editingFilmPolicyGroup: PlanGroup?
    @State private var batchSelectedManualIds: Set<String> = []
    @State private var errorMsg: String?

    private var activePlan: ScrapePlan? {
        if let id = selectedPlanId, let hit = planStore.plans.first(where: { $0.id == id }) { return hit }
        return planStore.plans.first
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()
                TopAmbientGlow()
                Group {
                if let plan = activePlan {
                    let ready = plan.groups.filter { $0.kind != "unmatched" }
                    let manual = plan.groups.filter { $0.kind == "unmatched" }
                    let baseShown = manualTab ? manual : ready
                    let shown = manualTab ? baseShown : PreviewFilter.apply(groups: baseShown, kind: filterKind, query: searchQuery)
                    let selectedCount = plan.actions.filter { $0.selected && !$0.done && $0.op != "unmatched" }.count
                    let conflicts = ConflictDetector.detect(in: plan.actions)

                    VStack(spacing: 0) {
                        Picker("分类", selection: $manualTab) {
                            Text("可整理 (\(ready.count))").tag(false)
                            Text("待手动确认 (\(manual.count))").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                        if !manualTab {
                                VStack(spacing: 6) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(PreviewFilterKind.allCases) { fk in
                                            Button(fk.rawValue) { filterKind = fk }
                                                .font(.caption.weight(filterKind == fk ? .semibold : .regular))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(filterKind == fk ? MMTheme.accent : Color.secondary.opacity(0.14), in: Capsule())
                                                .foregroundStyle(filterKind == fk ? .white : .primary)
                                        }
                                        Button(groupBySource ? "按来源分组" : "按类别分组") {
                                            groupBySource.toggle()
                                        }
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.secondary.opacity(0.14), in: Capsule())
                                        .foregroundStyle(MMTheme.accent)
                                    }
                                    .padding(.horizontal)
                                }
                            }
                            .padding(.bottom, 6)
                        }

                        if !conflicts.isEmpty && !manualTab {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("检测到 \(conflicts.count) 处目标文件名冲突（如：\(conflicts[0].targetName)），建议先取消重复项勾选。")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal)
                            .padding(.bottom, 6)
                        }

                        if let errorMsg {
                            Text(errorMsg).font(.footnote).foregroundStyle(MMTheme.redErr).padding(.horizontal)
                        }

                        if shown.isEmpty {
                            ContentUnavailableView(
                                manualTab ? "没有待手动确认的项目" : "暂无可整理作品",
                                systemImage: manualTab ? "checkmark.circle" : "film",
                                description: Text(manualTab ? "未识别的文件会显示在这里。" : "在「云盘」选择目录开始扫描。")
                            )
                        } else {
                            let sections = PreviewSectionGrouping.sections(plan: plan, groups: shown, bySource: groupBySource)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 14) {
                                    ForEach(sections) { sec in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(sec.title)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)

                                            ForEach(sec.groups) { group in
                                                let groupActions = plan.actions.filter { $0.groupId == group.id && $0.enabled }
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
                                                        onRematch: {
                                                            rematchTargets = [group]
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
                                                                    rematchTargets = [group]
                                                                    showRematchSheet = true
                                                                },
                                                                onEditPolicy: {
                                                                    editingFilmPolicyGroup = group
                                                                },
                                                                onEditAssets: {
                                                                    editingAssetsGroup = group
                                                                },
                                                                onEditEpisodeStrategy: group.kind == "tv" ? {
                                                                    strategyError = nil
                                                                    strategyEpisodeGroups = []
                                                                    editingStrategyGroup = group
                                                                    if let tid = group.tmdbId {
                                                                        Task {
                                                                            strategyEpisodeGroups = await TmdbClient.shared.tvEpisodeGroups(tvId: tid)
                                                                        }
                                                                    }
                                                                } : nil
                                                            )
                                                        }
                                                    )
                                                }
                                                .padding(14)
                                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                                .clipped()
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .background(Color.clear)
                        }

                        if manualTab && !batchSelectedManualIds.isEmpty {
                            HStack {
                                Text("已选 \(batchSelectedManualIds.count) 组待确认项").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    rematchTargets = manual.filter { batchSelectedManualIds.contains($0.id) }
                                    showRematchSheet = true
                                } label: {
                                    Text("批量匹配 (\(batchSelectedManualIds.count))")
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 10)
                                        .background(MMTheme.accent, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding()
                            .background(.bar)
                        } else if !manualTab {
                            HStack {
                                Button {
                                    showTaskPolicySheet = true
                                } label: {
                                    Label("设置", systemImage: "slider.horizontal.3")
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                if selectedCount > 0 {
                                    Button {
                                        execute(plan: plan)
                                    } label: {
                                        Text(ExecutionEngine.shared.isRunning ? "加入队列 (\(selectedCount))" : "立即执行 (\(selectedCount))")
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 18)
                                            .padding(.vertical, 10)
                                            .background(MMTheme.accent, in: Capsule())
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .padding()
                            .background(.bar)
                        }
                    }
                } else {
                    ContentUnavailableView("暂无识别结果", systemImage: "eye", description: Text("请在「云盘」页面选择文件夹并开始扫描。"))
                }
                }
            }
            .searchable(text: $searchQuery, prompt: "搜索片名、文件夹或年份")
            .navigationTitle("识别结果")
            .toolbar {
                if let plan = activePlan {
                    if manualTab {
                        let manual = plan.groups.filter { $0.kind == "unmatched" }
                        if !manual.isEmpty {
                            ToolbarItem(placement: .topBarLeading) {
                                let allOn = batchSelectedManualIds.count == manual.count
                                Button(allOn ? "取消全选" : "全选待确认") {
                                    batchSelectedManualIds = allOn ? [] : Set(manual.map(\.id))
                                }
                            }
                        }
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            let execs = plan.actions.filter { !$0.done && $0.op != "unmatched" }
                            let allSelected = !execs.isEmpty && execs.allSatisfy(\.selected)
                            Button(allSelected ? "取消全选" : "全选") {
                                toggleAll(selected: !allSelected)
                            }
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("收件箱") { showInboxSheet = true }
                        if planStore.plans.count > 1 {
                            Menu("切换") {
                                ForEach(planStore.plans) { p in
                                    Button("\(p.provider) · \(p.roots.map(\.name).joined(separator: "、"))") {
                                        selectedPlanId = p.id
                                        batchSelectedManualIds.removeAll()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showRematchSheet, onDismiss: {
                rematchApplying = false
                rematchError = nil
            }) {
                if let primary = rematchTargets.first {
                    let targets = buildMatchTargetGroups(for: rematchTargets, plan: activePlan)
                    let parsedPrimary = MediaParser.parse(primary.folderName)
                    ManualMatchSheet(
                        initialQuery: parsedPrimary.cleanTitle,
                        initialKind: primary.kind == "tv" ? "tv" : "movie",
                        initialYear: primary.year.isEmpty ? (parsedPrimary.year.map { "\($0)" } ?? "") : primary.year,
                        applying: rematchApplying,
                        applyError: rematchError,
                        targetGroups: targets,
                        onApply: { picked in
                            applyManualMatch(groups: rematchTargets, match: picked, overrides: [])
                        },
                        onApplyGroups: { picked, overrides in
                            applyManualMatch(groups: rematchTargets, match: picked, overrides: overrides)
                        }
                    )
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
            .sheet(isPresented: $showInboxSheet) {
                PreviewInboxView { pickedPlanId in
                    selectedPlanId = pickedPlanId
                    batchSelectedManualIds.removeAll()
                }
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
                let fallback = PolicyResolver.resolve(isTv: grp.kind == "tv", global: AppSettings.shared.policies, task: activePlan?.taskPolicy, film: grp.policyOverride)
                LibraryScrapeAssetsSheet(
                    title: grp.title,
                    isTv: grp.kind == "tv",
                    initial: grp.policyOverride,
                    fallback: fallback
                ) { override in
                    applyFilmPolicy(groupId: grp.id, override: override)
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
    }

    private func applyTaskPolicy(_ override: PolicyOverride?) {
        guard var plan = activePlan else { return }
        plan.taskPolicy = override
        plan = PolicyResolver.applyOverrides(to: plan, global: AppSettings.shared.policies)
        PlanAndTaskStore.shared.savePlan(plan)
    }

    private func applyFilmPolicy(groupId: String, override: PolicyOverride?) {
        guard var plan = activePlan, let idx = plan.groups.firstIndex(where: { $0.id == groupId }) else { return }
        plan.groups[idx].policyOverride = override
        plan = PolicyResolver.applyOverrides(to: plan, global: AppSettings.shared.policies)
        PlanAndTaskStore.shared.savePlan(plan)
    }

    private func execute(plan: ScrapePlan) {
        guard let acct = AccountStore.shared.accounts.first(where: { $0.id == plan.accountId }) else {
            errorMsg = "找不到对应的云盘账号"
            return
        }
        do {
            let drive = try AccountStore.shared.buildDrive(for: acct)
            ExecutionEngine.shared.enqueueOrStart(plan: plan, drive: drive)
            onStartExecution()
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
            var movedCount = 0
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
                    movedCount += 1
                    movedIds.append(act.id)
                } catch {
                    await MainActor.run { errorMsg = "移入保留区失败（\(fname)）：\(error.localizedDescription)" }
                }
            }
            if !movedIds.isEmpty {
                await MainActor.run {
                    let latest = PlanAndTaskStore.shared.plans.first(where: { $0.id == plan.id }) ?? plan
                    PlanAndTaskStore.shared.savePlan(PlanSelection.set(plan: latest, ids: movedIds, on: false))
                }
            }
        }
    }

    private func toggleAll(selected: Bool) {
        guard let plan = activePlan else { return }
        PlanAndTaskStore.shared.savePlan(PlanSelection.setAll(plan: plan, on: selected))
    }

    private func toggleGroup(groupId: String, selected: Bool) {
        guard let plan = activePlan else { return }
        let ids = PlanSelection.groupIds(plan: plan, groupId: groupId)
        PlanAndTaskStore.shared.savePlan(PlanSelection.set(plan: plan, ids: ids, on: selected))
    }

    private func buildMatchTargetGroups(for groups: [PlanGroup], plan: ScrapePlan?) -> [MatchTargetGroup] {
        guard let plan else { return [] }
        return groups.map { grp in
            let fileActions = plan.actions.filter { $0.groupId == grp.id && ($0.kind == "file" || $0.op == "unmatched") }
            let files = fileActions.map { MatchTargetGroup.FileItem(id: $0.id, name: $0.oldName.isEmpty ? $0.newName : $0.oldName) }
            let first = fileActions.first
            return MatchTargetGroup(
                key: grp.id,
                folderPath: grp.folderPath ?? grp.folderName,
                actionIds: fileActions.map(\.id),
                files: files,
                sampleFileName: first?.oldName ?? "",
                suggestedSeason: first?.season,
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
                    if hasFileOverrides {
                        cur = try await Scanner.replanTargetGroups(plan: cur, targets: overrides, info: match, drive: drive)
                    } else {
                        for grp in groups {
                            cur = try await Scanner.replanGroup(plan: cur, groupId: grp.id, info: match, drive: drive)
                        }
                    }
                    await MainActor.run {
                        PlanAndTaskStore.shared.savePlan(cur)
                        batchSelectedManualIds.removeAll()
                        rematchApplying = false
                        rematchError = nil
                        showRematchSheet = false
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
            plan.groups[idx].episodeGroupName = strategyEpisodeGroups.first(where: { $0.id == episodeGroupId })?.name
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
                    PlanAndTaskStore.shared.savePlan(replanned)
                    strategyApplying = false
                    if let updated = replanned.groups.first(where: { $0.id == group.id }) {
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
        PlanAndTaskStore.shared.savePlan(plan)
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
    let onRematch: () -> Void
    let onParkRetention: () -> Void
    @ViewBuilder let detailDestination: () -> DetailDestination

    @State private var expanded = false
    @State private var selectedSeason: Int?
    @State private var slideForward = true

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

    /// 仅保留视频/集文件条目（过滤季文件夹、海报、NFO、剧照等非集条目）。
    private var episodeFileActions: [PlanAction] {
        actions
            .filter { $0.kind == "file" || $0.op == "unmatched" }
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

    private struct SeasonBucket: Identifiable {
        let season: Int
        let items: [PlanAction]
        var id: Int { season }
        var label: String { season == 0 ? "特别篇" : "第 \(season) 季" }
    }

    private var seasonBuckets: [SeasonBucket] {
        guard group.kind == "tv" else { return [] }
        var map: [Int: [PlanAction]] = [:]
        for act in episodeFileActions {
            let s = resolvedSeason(for: act)
            map[s, default: []].append(act)
        }
        return map.keys.sorted().map { SeasonBucket(season: $0, items: map[$0] ?? []) }
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
                        .frame(width: 68, height: 100)
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

                            Text("\(episodeFileActions.count) 个文件 · \(actions.count) 项整理操作" + (group.note.map { " · \($0)" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)

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
                        let execs = actions.filter { !$0.done && $0.op != "unmatched" }
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

            if let newName = group.folderNewName {
                NavigationLink {
                    detailDestination()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(group.folderName) → \(newName)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
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
                        .transition(.opacity)
                }
            }
            .clipped()
        }
        .padding(.vertical, 4)
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
                    Text("\(only.label) (\(only.items.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MMTheme.accent)
                    episodeRowsList(only.items)
                }
            } else if !episodeFileActions.isEmpty {
                episodeRowsList(episodeFileActions)
            } else {
                Text("暂无视频文件条目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                onRematch()
            } label: {
                Label("手动识别", systemImage: "magnifyingglass")
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

    @ViewBuilder
    private func episodeRowsList(_ items: [PlanAction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, act in
                VStack(alignment: .leading, spacing: 3) {
                    Text(act.newName.isEmpty ? act.oldName : act.newName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if !act.oldName.isEmpty && act.oldName != act.newName {
                        Text(act.oldName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

                if idx < items.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
    }
}
