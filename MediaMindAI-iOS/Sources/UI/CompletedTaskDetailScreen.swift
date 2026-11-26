import SwiftUI
import UIKit

private struct TaskLogRequest: Identifiable {
    let id = UUID()
    let groupId: String
    let title: String
}

/// 任务执行结果详情页（参考图 3/4/5：顶部暖色结果头 + 每部作品海报与「已整理 / 已刮削」状态条 + 整理日志 / 刮削日志底部抽屉 + 重试与一键撤销回滚）。
public struct CompletedTaskDetailScreen: View {
    private let initialRun: TaskRun

    @State private var logRequest: TaskLogRequest?
    @State private var rollingBack = false
    @State private var rollbackHint: String?
    @State private var retryHint: String?
    @State private var showRollbackConfirm = false
    @State private var showRetryConfirm = false

    public init(run: TaskRun) {
        self.initialRun = run
    }

    private var run: TaskRun {
        if ExecutionEngine.shared.currentRun?.id == initialRun.id, let live = ExecutionEngine.shared.currentRun {
            return live
        }
        return PlanAndTaskStore.shared.tasks.first(where: { $0.id == initialRun.id }) ?? initialRun
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
        run.executionSnapshot
    }

    private var matchedGroups: [PlanGroup] {
        (matchingPlan?.groups ?? []).filter { $0.kind != "unmatched" }
    }

    private var countSummary: String {
        if let snapshot = matchingPlan { return "共 \(snapshot.uniqueMediaCount) 部影片" }
        return "共 \(run.total) 项操作"
    }

    private var isAllSucceeded: Bool {
        run.isSuccessful
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()

            // 顶部暖金光晕渐变头（成功与未完成统一暖金渐变，适配浅色/深色模式）
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.84, blue: 0.28).opacity(0.42),
                    Color(red: 1.0, green: 0.90, blue: 0.50).opacity(0.14),
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
                        Text("任务 ID：\(run.id)，\(countSummary)")
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
                        if run.executionSnapshot == nil {
                            Text("旧版记录未保存当次执行快照，仅展示原始计数和日志，不关联当前预览计划。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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

                    // 操作卡片：逐条明细 / 重试失败项 / 一键撤销
                    if matchingPlan != nil || hasRollbackable { actionSectionCard }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .navigationTitle("MediaMind AI 智能整理")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $logRequest) { request in
            let scope = TaskLogScope(plan: matchingPlan, groupId: request.groupId)
            TaskExecutionLogSheet(
                run: run,
                initialTab: .organize,
                journalRows: journalRows.filter { row in scope.contains(actionId: row.actionId) },
                walRows: walRows.filter { row in scope.contains(actionId: row.actionId) },
                scopeTitle: request.title
            )
            .presentationDetents([.large, .medium])
            .presentationDragIndicator(.visible)
        }
        .alert("重试失败／未完成项？", isPresented: $showRetryConfirm) {
            Button(ExecutionEngine.shared.isRunning ? "加入重试队列" : "确认重试") { retryFailedActions() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅提交本次任务的失败或未完成项，并补齐必要的目录依赖。确认后会生成新的执行记录，旧记录保留。")
        }
        .alert("撤销本次任务？", isPresented: $showRollbackConfirm) {
            Button("确认逆序撤销", role: .destructive) {
                Task { await runRollback() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("尝试按逆序撤销本次任务已执行的操作。遇到文件变更、冲突或素材校验信息不足时会停止，并保留日志。")
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
                                : [Color(red: 0.98, green: 0.67, blue: 0.50), Color(red: 0.92, green: 0.45, blue: 0.34)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                if isAllSucceeded {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                } else {
                    SadFaceEmblem(size: 32, strokeColor: Color.black.opacity(0.75))
                }
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
        if run.hasNoEffectiveOperations { return "无有效操作" }
        return "任务未完成"
    }

    private var heroSubtitle: String {
        if run.hasNoEffectiveOperations { return "本条记录没有成功执行的操作，不能作为整理完成的依据。" }
        if isAllSucceeded {
            return "智能整理和刮削影视库，帮助你轻松管理媒体库，秒出海报墙"
        }
        if run.status == "stopped" {
            return run.failed > 0
                ? "任务已手动停止（成功 \(run.succeeded) / 失败 \(run.failed) / 共 \(run.total)）"
                : "任务已手动停止，尚有未完成操作（已完成 \(run.succeeded)/\(run.total)）"
        }
        if run.status == "paused" {
            return run.failed > 0
                ? "任务已暂停（成功 \(run.succeeded) / 失败 \(run.failed) / 共 \(run.total)）"
                : "任务已暂停，可返回任务中心继续执行（已完成 \(run.succeeded)/\(run.total)）"
        }
        return "任务执行失败，请检查后重新尝试（成功 \(run.succeeded) / 失败 \(run.failed)）"
    }

    // MARK: - 单部作品整理/刮削结果卡（参考图 3）

    private func workResultCard(group g: PlanGroup, plan: ScrapePlan) -> some View {
        let groupActions = plan.actions.filter { $0.groupId == g.id }
        let groupActionIds = Set(groupActions.map(\.id))
        let fileActions = groupActions.filter { $0.kind == "file" }
        let uniqueFileCount = Set(fileActions.map { $0.fileId ?? $0.id }).count
        let seasons = Set(fileActions.compactMap(\.season))

        let fileRenameActions = groupActions.filter { $0.op == "rename" && $0.kind == "file" && $0.selected }
        let folderRenameActions = groupActions.filter { ($0.op == "rename" || $0.op == "mkdir") && $0.kind == "folder" && $0.selected }
        let organizeActions = groupActions.filter { ($0.op == "rename" || $0.op == "move" || $0.op == "mkdir") && $0.selected }
        let scrapeActions = groupActions.filter { $0.op == "artwork" && $0.selected }

        let groupJournal = journalRows.filter { groupActionIds.contains($0.actionId) }
        let organizeAllDone = (!organizeActions.isEmpty && organizeActions.allSatisfy(\.done))
            || (organizeActions.isEmpty && groupJournal.contains { $0.op != "artwork" && $0.status == .applied })
        let scrapeAllDone = (!scrapeActions.isEmpty && scrapeActions.allSatisfy(\.done))
            || (scrapeActions.isEmpty && groupJournal.contains { $0.op == "artwork" && $0.status == .applied })
        let fileRenameAllDone = !fileRenameActions.isEmpty && fileRenameActions.allSatisfy(\.done)
        let folderRenameAllDone = !folderRenameActions.isEmpty && folderRenameActions.allSatisfy(\.done)
        let hasScrapePlanned = !scrapeActions.isEmpty

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

                let selectedCount = groupActions.filter(\.selected).count
                Text(selectedCount == 0
                     ? "未纳入本次执行"
                     : (g.kind == "tv"
                        ? "整理 \(uniqueFileCount) 集 | 已完成 \(groupActions.filter(\.done).count)/\(selectedCount) 项"
                        : "整理 \(uniqueFileCount) 个文件 | 已完成 \(groupActions.filter(\.done).count)/\(selectedCount) 项"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if selectedCount == 0 {
                        stageBadge(title: "未执行", ok: false, failed: false)
                    } else if !isAllSucceeded && !hasScrapePlanned && !fileRenameActions.isEmpty && !folderRenameActions.isEmpty {
                        stageBadge(title: "文件重命名", ok: fileRenameAllDone, failed: !fileRenameAllDone)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.28))
                            .frame(height: 1)
                            .frame(maxWidth: 24)
                        stageBadge(title: "文件夹重命名", ok: folderRenameAllDone, failed: !folderRenameAllDone)
                    } else {
                        stageBadge(title: organizeAllDone ? "已整理" : "整理未完成", ok: organizeAllDone, failed: !organizeAllDone && !isAllSucceeded)
                        if hasScrapePlanned || scrapeAllDone {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.28))
                                .frame(height: 1)
                                .frame(maxWidth: 28)
                            stageBadge(title: scrapeAllDone ? "已刮削" : "刮削未完成", ok: scrapeAllDone, failed: !scrapeAllDone && !isAllSucceeded)
                        }
                    }

                    Spacer(minLength: 4)

                    Button("查看日志") {
                        logRequest = TaskLogRequest(groupId: g.id, title: g.title.isEmpty ? g.folderName : g.title)
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

    private func stageBadge(title: String, ok: Bool, failed: Bool = false) -> some View {
        let tint: Color = ok ? MMTheme.greenOk : (failed ? Color(red: 0.96, green: 0.36, blue: 0.28) : .secondary)
        return HStack(spacing: 4) {
            if ok {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
            } else if failed {
                ZStack {
                    Circle()
                        .fill(tint)
                        .frame(width: 15, height: 15)
                    SadFaceEmblem(size: 10, strokeColor: .white)
                }
            } else {
                Image(systemName: "circle")
                    .font(.caption)
            }
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
    }

    // MARK: - 底部操作区

    private var actionSectionCard: some View {
        VStack(spacing: 0) {
            if matchingPlan != nil {
                NavigationLink {
                    TaskItemsView(run: run)
                } label: {
                    actionRowLabel(icon: "checklist", title: "查看逐条计划操作明细", tint: .primary)
                }
                .buttonStyle(.plain)
            }

            if !isAllSucceeded, matchingPlan != nil {
                Divider().padding(.leading, 44)
                Button {
                    showRetryConfirm = true
                } label: {
                    actionRowLabel(icon: "arrow.clockwise.circle.fill", title: "仅重试失败 / 未完成项", tint: MMTheme.accent)
                }
                .buttonStyle(.plain)
            }

            if hasRollbackable {
                if matchingPlan != nil { Divider().padding(.leading, 44) }
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
        guard let livePlan = PlanAndTaskStore.shared.plans.first(where: { $0.id == run.planId }),
              Set(targetIds).isSubset(of: Set(livePlan.actions.map(\.id))) else {
            retryHint = "原计划已重新识别或变更，请从任务中心重新预览确认"
            return
        }
        guard ExecutionEngine.shared.enqueueOrStart(plan: livePlan, drive: drive, actionIds: targetIds) else {
            retryHint = ExecutionEngine.shared.lastStartError
            return
        }
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
    let journalRows: [JournalRow]
    let walRows: [ReversibleWalRecord]
    let scopeTitle: String

    @State private var selectedTab: TaskLogTab

    init(run: TaskRun, initialTab: TaskLogTab, journalRows: [JournalRow], walRows: [ReversibleWalRecord], scopeTitle: String) {
        self.run = run
        self.journalRows = journalRows
        self.walRows = walRows
        self.scopeTitle = scopeTitle
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

                Text("作品：\(scopeTitle)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 8)

                if shownEntries.isEmpty {
                    ContentUnavailableView(
                        selectedTab == .organize ? "暂无整理日志" : "暂无刮削日志",
                        systemImage: selectedTab == .organize ? "folder" : "photo.on.rectangle.angled",
                        description: Text("这部作品在本轮任务中没有对应的执行日志记录。")
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
            if kind == "episode_nfo" || (low.hasSuffix(".nfo") && low.range(of: #"s\d{1,2}e\d{1,3}"#, options: .regularExpression) != nil) { return "上传分集 NFO" }
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

private struct SadFaceEmblem: View {
    let size: CGFloat
    let strokeColor: Color

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width
            let h = sz.height
            let eyeR = max(1.0, w * 0.085)
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.30 - eyeR, y: h * 0.36 - eyeR, width: eyeR * 2, height: eyeR * 2)), with: .color(strokeColor))
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.70 - eyeR, y: h * 0.36 - eyeR, width: eyeR * 2, height: eyeR * 2)), with: .color(strokeColor))
            var mouth = Path()
            mouth.move(to: CGPoint(x: w * 0.30, y: h * 0.72))
            mouth.addQuadCurve(to: CGPoint(x: w * 0.70, y: h * 0.72), control: CGPoint(x: w * 0.50, y: h * 0.52))
            ctx.stroke(mouth, with: .color(strokeColor), style: StrokeStyle(lineWidth: max(1.2, w * 0.08), lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}
