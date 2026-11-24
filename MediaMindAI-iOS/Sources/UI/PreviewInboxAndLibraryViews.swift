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

/// 影视库总览：只读展示已整理/刮削成功的作品记录卡片（不可点击跳转）。
public struct FilmLibraryView: View {
    private enum LibraryKindFilter: String, CaseIterable {
        case all = "全部"
        case movie = "电影"
        case tv = "剧集"
        case collection = "合集"
    }

    private struct CompletedWorkRecord: Identifiable {
        let id: String
        let group: PlanGroup
        let provider: String
        let posterUrl: URL?
        let fileCount: Int
        let seasonCount: Int
        let organized: Bool
        let scraped: Bool
        let completedAt: Date
    }

    @State private var store = PlanAndTaskStore.shared
    @State private var search = ""
    @State private var showSearch = false
    @State private var kindFilter: LibraryKindFilter = .all

    public init() {}

    private var completedRecords: [CompletedWorkRecord] {
        let runsByPlan = Dictionary(grouping: store.tasks, by: \.planId)
        var records: [CompletedWorkRecord] = []
        var seenKeys = Set<String>()

        for plan in store.plans {
            let planRuns = runsByPlan[plan.id] ?? []
            let latestSuccessRun = planRuns.first(where: { $0.status == "done" || $0.succeeded > 0 })
            let completedDate = latestSuccessRun?.finishedAt ?? latestSuccessRun?.startedAt ?? plan.createdAt

            for grp in plan.groups where grp.kind != "unmatched" {
                let grpActions = plan.actions.filter { $0.groupId == grp.id }
                let doneOrganize = grpActions.contains { ($0.op == "rename" || $0.op == "move" || $0.op == "mkdir") && $0.done }
                let doneScrape = grpActions.contains { $0.op == "artwork" && $0.done }
                guard doneOrganize || doneScrape else { continue }

                let dedupKey = grp.tmdbId.map { "\(grp.kind)-\($0)" } ?? grp.id
                guard seenKeys.insert(dedupKey).inserted else { continue }

                let fileActions = grpActions.filter { $0.kind == "file" }
                let seasons = Set(fileActions.compactMap(\.season))
                let posterUrl: URL? = {
                    if let pp = grp.posterPath, !pp.isEmpty {
                        return AppSettings.shared.imageUrl(path: pp, size: "w342")
                    }
                    if let fallback = grpActions.first(where: { $0.kind == "image" && $0.newName.lowercased() == "poster.jpg" })?.artworkUrl {
                        return URL(string: fallback.replacingOccurrences(of: "/t/p/w780/", with: "/t/p/w342/"))
                    }
                    return nil
                }()
                records.append(CompletedWorkRecord(
                    id: "\(plan.id)-\(grp.id)",
                    group: grp,
                    provider: plan.provider,
                    posterUrl: posterUrl,
                    fileCount: Set(fileActions.map { $0.fileId ?? $0.id }).count,
                    seasonCount: seasons.count,
                    organized: doneOrganize,
                    scraped: doneScrape,
                    completedAt: completedDate
                ))
            }
        }
        return records.sorted { $0.completedAt > $1.completedAt }
    }

    private var filteredRecords: [CompletedWorkRecord] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return completedRecords.filter { rec in
            switch kindFilter {
            case .all: break
            case .movie: if rec.group.kind != "movie" { return false }
            case .tv: if rec.group.kind != "tv" { return false }
            case .collection: if rec.group.kind != "collection" { return false }
            }
            guard !q.isEmpty else { return true }
            return rec.group.title.lowercased().contains(q)
                || rec.group.folderName.lowercased().contains(q)
                || rec.group.year.contains(q)
                || (rec.group.tmdbId.map { String($0).contains(q) } ?? false)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !completedRecords.isEmpty {
                Picker("分类筛选", selection: $kindFilter) {
                    ForEach(LibraryKindFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if completedRecords.isEmpty {
                ContentUnavailableView(
                    "暂无已整理作品",
                    systemImage: "film.stack",
                    description: Text("完成整理与刮削任务后，成功的电影、剧集与合集作品记录会展示在这里。")
                )
            } else if filteredRecords.isEmpty {
                ContentUnavailableView(
                    "未找到匹配作品",
                    systemImage: "magnifyingglass",
                    description: Text("试试更换关键字或切换分类筛选。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredRecords) { rec in
                            workRecordCard(rec)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .bottomFloatingSearch(
            text: $search,
            prompt: "搜索片名、年份或 TMDB ID",
            visible: !completedRecords.isEmpty
        )
        .navigationTitle("影视库总览")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func workRecordCard(_ rec: CompletedWorkRecord) -> some View {
        let g = rec.group
        let posterURL = rec.posterUrl
        let badgeText: String = switch g.kind {
        case "tv": "剧集"
        case "movie": "电影"
        case "collection": "合集"
        default: "影视"
        }

        return HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                TmdbImageView(url: posterURL, placeholderSystemName: g.kind == "tv" ? "tv" : "film")
                Text(badgeText)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MMTheme.purpleBadge, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(width: 64, height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(g.title.isEmpty ? g.folderName : g.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if !g.year.isEmpty { Text(g.year) }
                    if let r = g.rating, r > 0 { Text(String(format: "★ %.1f", r)) }
                    if let tid = g.tmdbId { Text("TMDB \(tid)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(summaryLine(rec))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if rec.organized {
                        recordStatusBadge("已整理")
                    }
                    if rec.scraped {
                        recordStatusBadge("已刮削")
                    }
                    Spacer(minLength: 4)
                    Text(Self.dateFormatter.string(from: rec.completedAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func recordStatusBadge(_ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(MMTheme.greenOk)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(MMTheme.greenOk.opacity(0.14), in: Capsule())
    }

    private func summaryLine(_ rec: CompletedWorkRecord) -> String {
        let providerLabel: String = switch rec.provider.lowercased() {
        case "guangya": "光鸭"
        case "p123", "123": "123"
        case "webdav": "WebDAV"
        default: rec.provider
        }
        if rec.group.kind == "tv", rec.seasonCount > 0 {
            return "\(providerLabel) · \(rec.seasonCount) 季 · \(rec.fileCount) 集"
        }
        return "\(providerLabel) · \(rec.fileCount) 个文件"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()
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
