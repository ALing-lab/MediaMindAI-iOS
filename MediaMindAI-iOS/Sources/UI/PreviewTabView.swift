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
                                                        onToggleAction: { aid in toggleAction(actionId: aid) },
                                                        onRematch: {
                                                            rematchTargets = [group]
                                                            showRematchSheet = true
                                                        },
                                                        onEditFilmPolicy: {
                                                            editingFilmPolicyGroup = group
                                                        },
                                                        onParkRetention: {
                                                            parkToRetention(plan: plan, group: group, actions: groupActions)
                                                        }
                                                    )
                                                    Divider()
                                                    NavigationLink {
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
                                                    } label: {
                                                        HStack {
                                                            Text("查看完整作品详情与操作明细")
                                                                .font(.caption)
                                                                .foregroundStyle(MMTheme.accent)
                                                            Spacer()
                                                            Image(systemName: "chevron.right")
                                                                .font(.caption2)
                                                                .foregroundStyle(.tertiary)
                                                        }
                                                        .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
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
                    let isTv = grp.kind == "tv"
                    PolicyOverrideSheet(
                        title: "影片策略（第 3 层 · 最高优先）",
                        isTv: isTv,
                        current: grp.policyOverride,
                        fallback: PolicyResolver.resolve(isTv: isTv, global: AppSettings.shared.policies, task: plan.taskPolicy)
                    ) { updated in
                        applyFilmPolicy(groupId: grp.id, override: updated)
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

    private func toggleAction(actionId: String) {
        guard let plan = activePlan, let a = plan.actions.first(where: { $0.id == actionId }) else { return }
        PlanAndTaskStore.shared.savePlan(PlanSelection.set(plan: plan, ids: [actionId], on: !a.selected))
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

/// 第 3 层（影片策略）覆盖编辑器（对标 Android FilmPolicySheets）。
struct PolicyOverrideSheet: View {
    let title: String
    let isTv: Bool
    let current: PolicyOverride?
    let fallback: EffectivePolicy
    let onSave: (PolicyOverride?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renameFiles: Bool
    @State private var renameFolders: Bool
    @State private var fileTmdbEnabled: Bool
    @State private var keepResolution: Bool
    @State private var keepFps: Bool
    @State private var keepQuality: Bool
    @State private var keepAudio: Bool
    @State private var defaultSdrWhenMissing: Bool
    @State private var writeNfo: Bool
    @State private var downloadPoster: Bool
    @State private var downloadFanart: Bool
    @State private var hasOverride: Bool

    init(
        title: String,
        isTv: Bool,
        current: PolicyOverride?,
        fallback: EffectivePolicy,
        onSave: @escaping (PolicyOverride?) -> Void
    ) {
        self.title = title
        self.isTv = isTv
        self.current = current
        self.fallback = fallback
        self.onSave = onSave
        let n = (isTv ? current?.tvNaming : current?.movieNaming) ?? fallback.naming
        _renameFiles = State(initialValue: current?.renameFiles ?? fallback.renameFiles)
        _renameFolders = State(initialValue: current?.renameFolders ?? fallback.renameFolders)
        _fileTmdbEnabled = State(initialValue: n.fileTmdbEnabled)
        _keepResolution = State(initialValue: n.keepResolution)
        _keepFps = State(initialValue: n.keepFps)
        _keepQuality = State(initialValue: n.keepQuality)
        _keepAudio = State(initialValue: n.keepAudio)
        _defaultSdrWhenMissing = State(initialValue: n.defaultSdrWhenMissing)
        _writeNfo = State(initialValue: current?.writeNfo ?? fallback.writeNfo)
        _downloadPoster = State(initialValue: current?.downloadPoster ?? fallback.downloadPoster)
        _downloadFanart = State(initialValue: current?.downloadFanart ?? fallback.downloadFanart)
        _hasOverride = State(initialValue: current != nil)
    }

    private func liveBinding(_ state: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue },
            set: { newValue in
                state.wrappedValue = newValue
                applyNow()
            }
        )
    }

    private func applyNow() {
        var naming = (isTv ? current?.tvNaming : current?.movieNaming) ?? fallback.naming
        naming.fileTmdbEnabled = fileTmdbEnabled
        naming.keepResolution = keepResolution
        naming.keepFps = keepFps
        naming.keepQuality = keepQuality
        naming.keepAudio = keepAudio
        naming.defaultSdrWhenMissing = defaultSdrWhenMissing
        var ov = current ?? PolicyOverride()
        ov.renameFiles = renameFiles
        ov.renameFolders = renameFolders
        if isTv {
            ov.tvNaming = naming
        } else {
            ov.movieNaming = naming
        }
        ov.writeNfo = writeNfo
        ov.downloadPoster = downloadPoster
        ov.downloadFanart = downloadFanart
        hasOverride = true
        onSave(ov)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("文件与版本标签覆盖"), footer: Text("所有开关修改后实时生效，无需点击保存。")) {
                    Toggle("重命名文件", isOn: liveBinding($renameFiles))
                    Toggle("重命名目录", isOn: liveBinding($renameFolders))
                    Toggle("文件名包含 {tmdb-ID}", isOn: liveBinding($fileTmdbEnabled))
                    Toggle("保留分辨率（2160p / 1080p）", isOn: liveBinding($keepResolution))
                    Toggle("保留帧率（fps）", isOn: liveBinding($keepFps))
                    Toggle("保留画质（DV / HDR / UHD / BluRay）", isOn: liveBinding($keepQuality))
                    Toggle("保留音轨（TrueHD / Atmos / DDP）", isOn: liveBinding($keepAudio))
                    Toggle("缺失画质时自动补全 SDR", isOn: liveBinding($defaultSdrWhenMissing))
                }

                Section("刮削素材覆盖") {
                    Toggle("写入 NFO", isOn: liveBinding($writeNfo))
                    Toggle("下载海报（poster.jpg）", isOn: liveBinding($downloadPoster))
                    Toggle("下载背景图（fanart.jpg）", isOn: liveBinding($downloadFanart))
                }

                if hasOverride {
                    Section {
                        Button("恢复继承上层策略", role: .destructive) {
                            hasOverride = false
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct MediaGroupCardRow: View {
    let group: PlanGroup
    let actions: [PlanAction]
    let hasTaskOverride: Bool
    let isManualMode: Bool
    let isBatchSelected: Bool
    let onToggleBatchManual: () -> Void
    let onToggleGroup: (Bool) -> Void
    let onToggleAction: (String) -> Void
    let onRematch: () -> Void
    let onEditFilmPolicy: () -> Void
    let onParkRetention: () -> Void
    @State private var expanded = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if !group.year.isEmpty { Text(group.year) }
                        if let r = group.rating, r > 0 { Text(String(format: "★ %.1f", r)) }
                        if let tid = group.tmdbId { Text("TMDB \(tid)") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text("\(actions.count) 项整理操作" + (group.note.map { " · \($0)" } ?? ""))
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
                Spacer()
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
                    Button("匹配") { onRematch() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    if !isManualMode {
                        Button("策略") { onEditFilmPolicy() }
                            .font(.caption2)
                            .foregroundStyle(MMTheme.accent)
                            .buttonStyle(.borderless)
                    } else {
                        Button("保留区") { onParkRetention() }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.borderless)
                    }
                }
            }

            if let newName = group.folderNewName {
                Text("目录：\(group.folderName) → \(newName)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            expanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text("查看 \(actions.count) 项整理操作")
                                .font(.caption)
                                .foregroundStyle(MMTheme.accent)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(MMTheme.accent)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(actions) { act in
                                HStack(spacing: 8) {
                                    if act.op != "unmatched" && !act.done {
                                        Button {
                                            onToggleAction(act.id)
                                        } label: {
                                            Image(systemName: act.selected ? "checkmark.square.fill" : "square")
                                                .foregroundStyle(act.selected ? MMTheme.accent : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("[\(MMTheme.opLabel(act.op))] \(act.newName.isEmpty ? act.oldName : act.newName)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        if !act.oldName.isEmpty && act.oldName != act.newName {
                                            Text("原：\(act.oldName)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
