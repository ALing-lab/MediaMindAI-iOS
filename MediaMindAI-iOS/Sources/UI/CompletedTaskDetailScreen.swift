import SwiftUI
import UIKit

/// 任务执行结果详情页（参考图 3/4/5：顶部暖色结果头 + 每部作品海报与「已整理 / 已刮削」状态条 + 整理日志 / 刮削日志底部抽屉 + 重试与一键撤销回滚）。
public struct CompletedTaskDetailScreen: View {
    public let run: TaskRun

    @State private var showLogSheet = false
    @State private var initialLogTab: TaskLogTab = .organize
    @State private var rollingBack = false
    @State private var rollbackHint: String?
    @State private var retryHint: String?
    @State private var showRollbackConfirm = false

    public init(run: TaskRun) {
        self.run = run
    }

    private var journalRows: [JournalRow] {
        OperationJournal.shared.rows(forRunId: run.id)
    }

    private var walRows: [ReversibleWalRecord] {
        ReversibleWalStore.shared.rows(taskId: run.id)
    }

    private var hasRollbackable: Bool {
        OperationJournal.shared.hasRollbackableRows(runId: run.id)
            || walRows.contains(where: { $0.state == "applied" })
    }

    private var matchingPlan: ScrapePlan? {
        PlanAndTaskStore.shared.plans.first(where: { $0.id == run.planId })
    }

    private var matchedGroups: [PlanGroup] {
        (matchingPlan?.groups ?? []).filter { $0.kind != "unmatched" }
    }

    private var totalFileCount: Int {
        if let plan = matchingPlan {
            let files = plan.actions.filter { $0.kind == "file" }.count
            if files > 0 { return files }
        }
        return run.total
    }

    private var isAllSucceeded: Bool {
        run.status == "done" && run.failed == 0
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()

            // 顶部暖金光晕渐变头（适配浅色/深色模式）
            LinearGradient(
                colors: [
                    (isAllSucceeded ? Color.orange : (run.failed > 0 ? MMTheme.redErr : Color.secondary)).opacity(0.32),
                    (isAllSucceeded ? Color.yellow : MMTheme.accent).opacity(0.10),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 220)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 顶部任务 ID 与文件数
                    HStack(spacing: 6) {
                        Text("任务 ID：\(run.id)，共 \(totalFileCount) 个文件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let fin = run.finishedAt {
                            let secs = max(0, Int(fin.timeIntervalSince(run.startedAt)))
                            Text("耗时 \(secs)s")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 顶部大状态头（对应参考图 3）
                    heroStatusHeader

                    // 每部作品整理与刮削结果卡片
                    if !matchedGroups.isEmpty, let plan = matchingPlan {
                        VStack(spacing: 12) {
                            ForEach(matchedGroups) { grp in
                                workResultCard(group: grp, plan: plan)
                            }
                        }
                    } else {
                        fallbackSummaryCard
                    }

                    // 错误摘要（若有）
                    if !run.errors.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("错误摘要（\(run.errors.count)）")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MMTheme.redErr)
                            ForEach(Array(run.errors.enumerated()), id: \.offset) { _, err in
                                Text("• \(err)")
                                    .font(.caption)
                                    .foregroundStyle(MMTheme.redErr)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(MMTheme.redErr.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // 提示信息
                    if let retryHint {
                        Text(retryHint)
                            .font(.footnote)
                            .foregroundStyle(MMTheme.accent)
                            .padding(.horizontal, 4)
                    }
                    if let rollbackHint {
                        Text(rollbackHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }

                    // 操作卡片：查看日志 / 逐条明细 / 重试失败项 / 一键撤销
                    actionSectionCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .navigationTitle("MediaMind AI 智能整理")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogSheet) {
            TaskExecutionLogSheet(
                run: run,
                initialTab: initialLogTab,
                journalRows: journalRows,
                walRows: walRows
            )
            .presentationDetents([.large, .medium])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("确认撤销本次任务的全部已执行操作？", isPresented: $showRollbackConfirm, titleVisibility: .visible) {
            Button("确认逆序撤销", role: .destructive) {
                Task { await runRollback() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部结果大头

    private var heroStatusHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isAllSucceeded
                                ? [Color(red: 1.0, green: 0.84, blue: 0.35), MMTheme.accent]
                                : (run.failed > 0
                                    ? [MMTheme.redErr.opacity(0.85), MMTheme.redErr]
                                    : [Color.secondary.opacity(0.45), Color.secondary.opacity(0.7)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                Image(systemName: isAllSucceeded ? "face.smiling" : (run.failed > 0 ? "exclamationmark.triangle.fill" : "minus.circle.fill"))
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(heroTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text(heroSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var heroTitle: String {
        if isAllSucceeded { return "全部成功" }
        if run.status == "stopped" { return "已取消" }
        if run.status == "paused" { return "已暂停" }
        if run.failed > 0 { return "部分失败" }
        return "执行完成"
    }

    private var heroSubtitle: String {
        if isAllSucceeded {
            return "智能整理和刮削影视库，帮助你轻松管理媒体库，秒出海报墙"
        }
        return "成功 \(run.succeeded) 项 · 失败 \(run.failed) 项 · 共 \(run.total) 项"
    }

    // MARK: - 单部作品整理/刮削结果卡（参考图 3）

    private func workResultCard(group g: PlanGroup, plan: ScrapePlan) -> some View {
        let groupActions = plan.actions.filter { $0.groupId == g.id }
        let fileActions = groupActions.filter { $0.kind == "file" }
        let seasons = Set(fileActions.compactMap(\.season))
        let organizedDone = groupActions.contains { ($0.op == "rename" || $0.op == "move" || $0.op == "mkdir") && $0.done }
            || journalRows.contains { $0.op != "artwork" && $0.status == .applied }
        let scrapedDone = groupActions.contains { $0.op == "artwork" && $0.done }
            || journalRows.contains { $0.op == "artwork" && $0.status == .applied }
        let hasScrapePlanned = groupActions.contains { $0.op == "artwork" && $0.enabled }

        let posterURL: URL? = g.posterPath.flatMap { AppSettings.shared.imageUrl(path: $0, size: "w185") }
        let badgeText: String = switch g.kind {
        case "tv": "剧集"
        case "movie": "电影"
        case "collection": "合集"
        default: "影视"
        }
        let titleSuffix: String = {
            if g.kind == "tv", !seasons.isEmpty {
                return " | 已识别 \(seasons.count) 季"
            }
            if !g.year.isEmpty {
                return " · \(g.year)"
            }
            return ""
        }()

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                TmdbImageView(url: posterURL, placeholderSystemName: g.kind == "tv" ? "tv" : "film")
            }
            .frame(width: 66, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(badgeText)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MMTheme.purpleBadge, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text((g.title.isEmpty ? g.folderName : g.title) + titleSuffix)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(g.kind == "tv"
                     ? "整理 \(fileActions.count) 集 | 成功执行 \(groupActions.filter(\.done).count) 项操作"
                     : "整理 \(fileActions.count) 个文件 | 成功执行 \(groupActions.filter(\.done).count) 项操作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    stageBadge(title: organizedDone ? "已整理" : "未整理", ok: organizedDone)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(height: 1)
                        .frame(maxWidth: 32)

                    if hasScrapePlanned || scrapedDone {
                        stageBadge(title: scrapedDone ? "已刮削" : "未刮削", ok: scrapedDone)
                    }

                    Spacer(minLength: 4)

                    Button("查看日志") {
                        initialLogTab = .organize
                        showLogSheet = true
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fallbackSummaryCard: some View {
        let organizedCount = journalRows.filter { $0.op != "artwork" && $0.status == .applied }.count
        let scrapedCount = journalRows.filter { $0.op == "artwork" && $0.status == .applied }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(run.sourceLabel.isEmpty ? "任务 \(run.id)" : run.sourceLabel)
                    .font(.subheadline.bold())
                Spacer()
                Button("查看日志") {
                    initialLogTab = .organize
                    showLogSheet = true
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(MMTheme.accent)
                .buttonStyle(.plain)
            }
            Text("网盘：\(run.provider) · 成功 \(run.succeeded) / 失败 \(run.failed) / 共 \(run.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                stageBadge(title: organizedCount > 0 ? "已整理 (\(organizedCount))" : "整理记录", ok: organizedCount > 0)
                if scrapedCount > 0 {
                    stageBadge(title: "已刮削 (\(scrapedCount))", ok: true)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func stageBadge(title: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.caption)
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(ok ? MMTheme.greenOk : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((ok ? MMTheme.greenOk : Color.secondary).opacity(0.14), in: Capsule())
    }

    // MARK: - 底部操作区

    private var actionSectionCard: some View {
        VStack(spacing: 0) {
            Button {
                initialLogTab = .organize
                showLogSheet = true
            } label: {
                actionRowLabel(icon: "doc.text.magnifyingglass", title: "查看整理日志 / 刮削日志", tint: MMTheme.accent)
            }
            .buttonStyle(.plain)

            if matchingPlan != nil {
                Divider().padding(.leading, 44)
                NavigationLink {
                    TaskItemsView(run: run)
                } label: {
                    actionRowLabel(icon: "checklist", title: "查看逐条计划操作明细", tint: .primary)
                }
                .buttonStyle(.plain)
            }

            if run.failed > 0, matchingPlan != nil {
                Divider().padding(.leading, 44)
                Button {
                    retryFailedActions()
                } label: {
                    actionRowLabel(icon: "arrow.clockwise.circle.fill", title: "仅重试失败 / 未完成项", tint: MMTheme.accent)
                }
                .buttonStyle(.plain)
            }

            if hasRollbackable {
                Divider().padding(.leading, 44)
                Button {
                    showRollbackConfirm = true
                } label: {
                    HStack(spacing: 12) {
                        if rollingBack {
                            ProgressView().controlSize(.small).frame(width: 22)
                        } else {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .foregroundStyle(MMTheme.redErr)
                                .frame(width: 22)
                        }
                        Text(rollingBack ? "正在按 WAL 逆序撤销…" : "一键撤销本次整理操作")
                            .font(.subheadline)
                            .foregroundStyle(MMTheme.redErr)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(rollingBack)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func actionRowLabel(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(tint)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - 动作逻辑

    private func retryFailedActions() {
        guard let plan = matchingPlan,
              let acct = AccountStore.shared.get(id: run.accountId),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            retryHint = "找不到原始计划或有效云盘账号，无法重试"
            return
        }
        let failedIds = plan.actions.filter {
            !$0.done && $0.enabled && $0.blocked == nil && $0.op != "unmatched" && $0.op != "skip"
                && !($0.error ?? "").isEmpty
        }.map(\.id)
        let targetIds: [String]
        if !failedIds.isEmpty {
            targetIds = FailedRetry.retryIds(selected: failedIds, plan: plan)
        } else {
            let pendingSelected = plan.actions.filter {
                !$0.done && $0.enabled && $0.blocked == nil && $0.selected && $0.op != "unmatched" && $0.op != "skip"
            }.map(\.id)
            targetIds = FailedRetry.retryIds(selected: pendingSelected, plan: plan)
        }
        guard !targetIds.isEmpty else {
            retryHint = "所有已勾选操作均已完成，无需重试"
            return
        }
        ExecutionEngine.shared.enqueueOrStart(plan: plan, drive: drive, actionIds: targetIds)
        retryHint = "已将 \(targetIds.count) 项失败/未完成操作重新提交执行队列"
    }

    private func runRollback() async {
        guard let acct = AccountStore.shared.get(id: run.accountId),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            rollbackHint = "找不到可用的云盘账号，无法撤销"
            return
        }
        rollingBack = true
        defer { rollingBack = false }
        let summary = await ExecutionEngine.shared.rollback(runId: run.id, drive: drive)
        if summary.failed == 0 {
            rollbackHint = "撤销完成：共回滚 \(summary.undone)/\(summary.total) 项操作"
        } else {
            rollbackHint = "撤销部分完成：成功 \(summary.undone) 项，失败 \(summary.failed) 项（\(summary.errors.first ?? "")）"
        }
    }
}

// MARK: - 整理日志 / 刮削日志底部抽屉（参考图 4 & 图 5）

private enum TaskLogTab: String, CaseIterable {
    case organize = "整理日志"
    case scrape = "刮削日志"
}

private struct TaskLogEntry: Identifiable {
    let id: String
    let isScrape: Bool
    let title: String
    let statusLabel: String
    let statusColor: Color
    let detail: String
    let error: String?
    let timestamp: Date
}

private struct TaskExecutionLogSheet: View {
    let run: TaskRun
    let initialTab: TaskLogTab
    let journalRows: [JournalRow]
    let walRows: [ReversibleWalRecord]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: TaskLogTab

    init(run: TaskRun, initialTab: TaskLogTab, journalRows: [JournalRow], walRows: [ReversibleWalRecord]) {
        self.run = run
        self.initialTab = initialTab
        self.journalRows = journalRows
        self.walRows = walRows
        self._selectedTab = State(initialValue: initialTab)
    }

    private var entries: [TaskLogEntry] {
        var result: [TaskLogEntry] = []
        var seenActionIds = Set<String>()

        for row in journalRows {
            seenActionIds.insert(row.actionId)
            let isScrape = row.op == "artwork"
            let title = humanTitle(op: row.op, kind: row.kind, newName: row.newName)
            let (stLabel, stColor) = statusPresentation(row.status.rawValue, hasError: row.error != nil)
            let detail: String = {
                if !row.oldName.isEmpty && !row.newName.isEmpty && row.oldName != row.newName {
                    return "\(row.oldName) → \(row.newName)"
                }
                return row.newName.isEmpty ? row.oldName : row.newName
            }()
            result.append(TaskLogEntry(
                id: "j-\(row.id)",
                isScrape: isScrape,
                title: title,
                statusLabel: stLabel,
                statusColor: stColor,
                detail: detail,
                error: row.error,
                timestamp: row.timestamp
            ))
        }

        for row in walRows where !seenActionIds.contains(row.actionId) {
            let isScrape = row.operation == "artwork" || row.operation == "upload"
            let primaryName = row.after?.name ?? row.before?.name ?? row.actionId
            let title = humanTitle(op: row.operation, kind: "", newName: primaryName)
            let (stLabel, stColor) = statusPresentation(row.state, hasError: !(row.error ?? "").isEmpty)
            let detail: String = {
                if let b = row.before?.name, let a = row.after?.name, !b.isEmpty, !a.isEmpty, b != a {
                    return "\(b) → \(a)"
                }
                return primaryName
            }()
            result.append(TaskLogEntry(
                id: "w-\(row.id)",
                isScrape: isScrape,
                title: title,
                statusLabel: stLabel,
                statusColor: stColor,
                detail: detail,
                error: row.error,
                timestamp: run.startedAt
            ))
        }

        return result
    }

    private var shownEntries: [TaskLogEntry] {
        entries.filter { selectedTab == .scrape ? $0.isScrape : !$0.isScrape }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()

            LinearGradient(
                colors: [Color.orange.opacity(0.24), Color.yellow.opacity(0.08), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 150)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // 顶部双 Tab：整理日志 | 刮削日志 + 右侧任务 ID
                HStack(alignment: .center, spacing: 18) {
                    ForEach(TaskLogTab.allCases, id: \.self) { tab in
                        let isOn = selectedTab == tab
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(isOn ? .headline.bold() : .subheadline)
                                .foregroundStyle(isOn ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("任务 ID：\(run.id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                if shownEntries.isEmpty {
                    ContentUnavailableView(
                        selectedTab == .organize ? "暂无整理日志" : "暂无刮削日志",
                        systemImage: selectedTab == .organize ? "folder" : "photo.on.rectangle.angled",
                        description: Text("本轮任务没有对应的执行日志记录。")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shownEntries.enumerated()), id: \.element.id) { idx, entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(entry.title)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                        Text(entry.statusLabel)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(entry.statusColor)
                                        Spacer()
                                        Text(Self.logTimeFormatter.string(from: entry.timestamp))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }

                                    if !entry.detail.isEmpty {
                                        Text(entry.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    if let err = entry.error, !err.isEmpty {
                                        Text(err)
                                            .font(.caption2)
                                            .foregroundStyle(MMTheme.redErr)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)

                                if idx < shownEntries.count - 1 {
                                    Divider().padding(.horizontal, 18)
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
        }
    }

    private func humanTitle(op: String, kind: String, newName: String) -> String {
        let low = newName.lowercased()
        switch op {
        case "mkdir":
            return low.hasPrefix("season") ? "创建季文件夹" : "创建作品文件夹"
        case "move":
            return kind == "subtitle" ? "移动字幕文件" : "移动视频文件"
        case "rename":
            if kind == "folder" { return "重命名文件夹" }
            if kind == "subtitle" { return "重命名字幕文件" }
            return "重命名视频文件"
        case "trash":
            return "清理重复/保留项"
        case "artwork", "upload":
            if kind == "episode_nfo" || (low.hasSuffix(".nfo") && low.contains("s0")) { return "上传分集 NFO" }
            if kind == "season_nfo" || low == "season.nfo" { return "上传季 NFO" }
            if kind == "tvshow_nfo" || kind == "movie_nfo" || low.hasSuffix(".nfo") { return "上传作品 NFO" }
            if kind == "clearlogo" || low.contains("logo") { return "上传作品 LOGO" }
            if low.contains("fanart") || low.contains("backdrop") { return "上传作品背景图" }
            if low.contains("thumb") { return "上传分集缩略图" }
            if low.contains("season") && low.contains("poster") { return "上传季海报" }
            if low.contains("poster") || low == "folder.jpg" { return "上传作品海报" }
            return "上传刮削素材"
        default:
            return MMTheme.opLabel(op)
        }
    }

    private func statusPresentation(_ state: String, hasError: Bool) -> (String, Color) {
        if hasError { return ("失败", MMTheme.redErr) }
        switch state {
        case "applied": return ("成功", MMTheme.accent)
        case "skipped": return ("跳过", .secondary)
        case "reverted": return ("已回滚", .secondary)
        case "failed", "uncertain", "conflict": return ("失败", MMTheme.redErr)
        default: return (state, .secondary)
        }
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
}
