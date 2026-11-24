import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 1:1 复刻自 Android `PreviewInboxScreen.kt`：多扫描计划收件箱（查看全部计划统计、切换活跃计划、左滑删除）。
public struct PreviewInboxView: View {
    public let onSelectPlan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = PlanAndTaskStore.shared

    public init(onSelectPlan: @escaping (String) -> Void) {
        self.onSelectPlan = onSelectPlan
    }

    public var body: some View {
        NavigationStack {
            List {
                if store.plans.isEmpty {
                    ContentUnavailableView("收件箱为空", systemImage: "tray", description: Text("在「云盘」扫描目录后会在此保留最近 20 个计划。"))
                } else {
                    ForEach(store.plans) { plan in
                        let readyCount = plan.groups.filter { $0.kind != "unmatched" }.count
                        let manualCount = plan.groups.filter { $0.kind == "unmatched" }.count
                        Button {
                            onSelectPlan(plan.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(plan.roots.map(\.name).joined(separator: "、"))
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(plan.provider)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(MMTheme.accentTint, in: Capsule())
                                        .foregroundStyle(MMTheme.accent)
                                }
                                Text("可整理 \(readyCount) 组 · 待确认 \(manualCount) 组 · 共 \(plan.actions.count) 项操作")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onDelete { idxs in
                        let ids = idxs.compactMap { store.plans.indices.contains($0) ? store.plans[$0].id : nil }
                        for id in ids { store.deletePlan(id: id) }
                    }
                }
            }
            .navigationTitle("扫描计划收件箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }
}

/// 1:1 复刻自 Android `FilmLibraryScreen.kt`：按「电影 / 剧集 / 合集」分类浏览全部已识别作品。
public struct FilmLibraryView: View {
    @State private var store = PlanAndTaskStore.shared
    @State private var search = ""
    @State private var rematchTarget: (plan: ScrapePlan, group: PlanGroup)? = nil
    @State private var policyTarget: (plan: ScrapePlan, group: PlanGroup)? = nil
    @State private var assetsTarget: (plan: ScrapePlan, group: PlanGroup)? = nil

    public init() {}

    public var body: some View {
        let allPairs: [(ScrapePlan, PlanGroup)] = store.plans.flatMap { p in
            p.groups.filter { $0.kind != "unmatched" }.map { (p, $0) }
        }
        let filtered = allPairs.filter { _, g in
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return q.isEmpty || g.title.lowercased().contains(q) || g.year.contains(q)
        }
        let movies = filtered.filter { $0.1.kind == "movie" }
        let tvs = filtered.filter { $0.1.kind == "tv" }
        let cols = filtered.filter { $0.1.kind == "collection" }

        List {
            if filtered.isEmpty {
                ContentUnavailableView("暂无已识别影视库", systemImage: "film.stack", description: Text("完成扫描后，所有识别出的电影、剧集与合集会归类展示于此。"))
            } else {
                if !movies.isEmpty {
                    Section("电影（\(movies.count)）") {
                        ForEach(movies, id: \.1.id) { pair in row(plan: pair.0, grp: pair.1) }
                    }
                }
                if !tvs.isEmpty {
                    Section("剧集（\(tvs.count)）") {
                        ForEach(tvs, id: \.1.id) { pair in row(plan: pair.0, grp: pair.1) }
                    }
                }
                if !cols.isEmpty {
                    Section("系列合集（\(cols.count)）") {
                        ForEach(cols, id: \.1.id) { pair in row(plan: pair.0, grp: pair.1) }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索片名或年份")
        .navigationTitle("影视库总览")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: Binding(get: { rematchTarget != nil }, set: { if !$0 { rematchTarget = nil } })) {
            if let t = rematchTarget {
                let livePlan = store.plans.first(where: { $0.id == t.plan.id }) ?? t.plan
                let liveGrp = livePlan.groups.first(where: { $0.id == t.group.id }) ?? t.group
                ManualMatchSheet(
                    initialQuery: liveGrp.title.isEmpty ? liveGrp.folderName : liveGrp.title,
                    initialKind: liveGrp.kind == "tv" ? "tv" : "movie",
                    onApply: { match in
                        rematchTarget = nil
                        Task {
                            let latestPlan = store.plans.first(where: { $0.id == t.plan.id }) ?? livePlan
                            if let acct = AccountStore.shared.get(id: latestPlan.accountId),
                               let drive = try? AccountStore.shared.buildDrive(for: acct),
                               let replanned = try? await Scanner.replanGroup(plan: latestPlan, groupId: t.group.id, info: match, drive: drive) {
                                await MainActor.run {
                                    store.savePlan(replanned)
                                }
                                return
                            }
                            await MainActor.run {
                                var updated = store.plans.first(where: { $0.id == t.plan.id }) ?? latestPlan
                                guard !updated.actions.contains(where: { $0.groupId == t.group.id && $0.done }) else { return }
                                if let idx = updated.groups.firstIndex(where: { $0.id == t.group.id }) {
                                    updated.groups[idx].tmdbId = match.id
                                    updated.groups[idx].title = match.title
                                    updated.groups[idx].year = match.year
                                    updated.groups[idx].posterPath = match.posterPath
                                    updated.groups[idx].kind = match.kind
                                }
                                for aIdx in updated.actions.indices where updated.actions[aIdx].groupId == t.group.id && !updated.actions[aIdx].done {
                                    let a = updated.actions[aIdx]
                                    var nextKind = a.kind
                                    var nextNewName = a.newName
                                    var nextArtUrl = a.artworkUrl
                                    if a.op == "artwork" {
                                        if a.kind == "movie_nfo" && match.kind == "tv" {
                                            nextKind = "tvshow_nfo"
                                            nextNewName = "tvshow.nfo"
                                        } else if a.kind == "tvshow_nfo" && match.kind == "movie" {
                                            nextKind = "movie_nfo"
                                            nextNewName = "movie.nfo"
                                        } else if a.kind == "image" {
                                            let low = a.newName.lowercased()
                                            if low.contains("poster") && !low.contains("season") {
                                                nextArtUrl = match.posterPath.flatMap { AppSettings.shared.imageUrl(path: $0)?.absoluteString }
                                            } else if low.contains("fanart") || low.contains("backdrop") {
                                                nextArtUrl = match.backdropPath.flatMap { AppSettings.shared.imageUrl(path: $0, size: AppSettings.shared.imageQuality.backdropSize)?.absoluteString }
                                            } else {
                                                nextArtUrl = nil
                                            }
                                        }
                                    }
                                    updated.actions[aIdx] = PlanAction(
                                        id: a.id,
                                        op: a.op,
                                        groupId: a.groupId,
                                        fileId: a.fileId,
                                        parentId: a.parentId,
                                        oldName: a.oldName,
                                        newName: nextNewName,
                                        destParentId: a.destParentId,
                                        destRef: a.destRef,
                                        destLabel: a.destLabel,
                                        kind: nextKind,
                                        mediaKind: match.kind,
                                        tmdbId: match.id,
                                        season: a.season,
                                        episode: a.episode,
                                        artworkUrl: nextArtUrl,
                                        selected: a.selected,
                                        enabled: a.enabled,
                                        blocked: a.blocked,
                                        done: a.done,
                                        error: a.error,
                                        note: a.note,
                                        metadataSeason: a.metadataSeason,
                                        metadataEpisode: a.metadataEpisode,
                                        replaceExisting: a.replaceExisting,
                                        folderPath: a.folderPath
                                    )
                                }
                                updated = PolicyResolver.applyOverrides(to: updated, global: AppSettings.shared.policies)
                                store.savePlan(updated)
                            }
                        }
                    }
                )
            }
        }
        .sheet(isPresented: Binding(get: { policyTarget != nil }, set: { if !$0 { policyTarget = nil } })) {
            if let t = policyTarget {
                let livePlan = store.plans.first(where: { $0.id == t.plan.id }) ?? t.plan
                let liveGrp = livePlan.groups.first(where: { $0.id == t.group.id }) ?? t.group
                let eff = PolicyResolver.resolve(isTv: liveGrp.kind == "tv", global: AppSettings.shared.policies, task: livePlan.taskPolicy)
                PolicyOverrideSheet(
                    title: "单作品策略：\(liveGrp.title.isEmpty ? liveGrp.folderName : liveGrp.title)",
                    isTv: liveGrp.kind == "tv",
                    current: liveGrp.policyOverride,
                    fallback: eff
                ) { ov in
                    var updated = store.plans.first(where: { $0.id == t.plan.id }) ?? livePlan
                    if let idx = updated.groups.firstIndex(where: { $0.id == t.group.id }) {
                        updated.groups[idx].policyOverride = ov
                    }
                    updated = PolicyResolver.applyOverrides(to: updated, global: AppSettings.shared.policies)
                    store.savePlan(updated)
                }
            }
        }
        .sheet(isPresented: Binding(get: { assetsTarget != nil }, set: { if !$0 { assetsTarget = nil } })) {
            if let t = assetsTarget {
                let livePlan = store.plans.first(where: { $0.id == t.plan.id }) ?? t.plan
                let liveGrp = livePlan.groups.first(where: { $0.id == t.group.id }) ?? t.group
                let eff = PolicyResolver.resolve(isTv: liveGrp.kind == "tv", global: AppSettings.shared.policies, task: livePlan.taskPolicy, film: liveGrp.policyOverride)
                LibraryScrapeAssetsSheet(
                    title: liveGrp.title.isEmpty ? liveGrp.folderName : liveGrp.title,
                    isTv: liveGrp.kind == "tv",
                    initial: liveGrp.policyOverride,
                    fallback: eff
                ) { ov in
                    var updated = store.plans.first(where: { $0.id == t.plan.id }) ?? livePlan
                    if let idx = updated.groups.firstIndex(where: { $0.id == t.group.id }) {
                        updated.groups[idx].policyOverride = ov
                    }
                    updated = PolicyResolver.applyOverrides(to: updated, global: AppSettings.shared.policies)
                    store.savePlan(updated)
                }
            }
        }
    }

    private func row(plan: ScrapePlan, grp: PlanGroup) -> some View {
        NavigationLink {
            MediaDetailView(
                planId: plan.id,
                groupId: grp.id,
                onRematch: { rematchTarget = (plan, grp) },
                onEditPolicy: { policyTarget = (plan, grp) },
                onEditAssets: { assetsTarget = (plan, grp) }
            )
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(grp.title.isEmpty ? grp.folderName : grp.title).font(.headline)
                Text("\(grp.year) · \(plan.provider)" + (grp.tmdbId.map { " · TMDB \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 崩溃日志查看页（对标 Android CrashReporter 查看入口）。
public struct CrashReportView: View {
    @State private var report: String? = CrashReporter.readReport()
    @State private var copied = false

    public init() {}

    public var body: some View {
        Group {
            if let report {
                ScrollView {
                    Text(report)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView("暂无崩溃记录", systemImage: "checkmark.shield", description: Text("应用运行正常，未捕获到异常崩溃堆栈。"))
            }
        }
        .navigationTitle("崩溃日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let report {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(copied ? "已复制" : "复制") {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = report
                        #endif
                        copied = true
                    }
                    Button("清空", role: .destructive) {
                        CrashReporter.clear()
                        self.report = nil
                    }
                }
            }
        }
    }
}
