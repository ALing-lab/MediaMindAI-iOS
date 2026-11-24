import SwiftUI

/// 1:1 复刻自 Android `CompletedTaskDetailScreen.kt`：
/// 任务执行详情页（按全部/失败/可撤销筛选 + 关键字搜索 + WAL 事务明细 + 一键重试失败项 + 一键撤销回滚）。
public struct CompletedTaskDetailScreen: View {
    public let run: TaskRun

    @State private var filter: DetailFilter = .all
    @State private var searchQuery = ""
    @State private var rollingBack = false
    @State private var rollbackHint: String?
    @State private var retryHint: String?
    @State private var showRollbackConfirm = false

    public enum DetailFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case failed = "仅失败"
        case undoable = "可撤销"
        public var id: String { rawValue }
    }

    public init(run: TaskRun) {
        self.run = run
    }

    private var journalRows: [JournalRow] {
        OperationJournal.shared.rows(forRunId: run.id)
    }

    private var walRows: [ReversibleWalRecord] {
        ReversibleWalStore.shared.rows(taskId: run.id)
    }

    private var filteredJournalRows: [JournalRow] {
        let base: [JournalRow]
        switch filter {
        case .all:
            base = journalRows
        case .failed:
            base = journalRows.filter { $0.status == .uncertain || $0.status == .skipped || $0.error != nil }
        case .undoable:
            base = journalRows.filter { $0.status == .applied }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.op.lowercased().contains(q)
                || $0.oldName.lowercased().contains(q)
                || $0.newName.lowercased().contains(q)
                || ($0.error?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredWalRows: [ReversibleWalRecord] {
        let base: [ReversibleWalRecord]
        switch filter {
        case .all:
            base = walRows
        case .failed:
            base = walRows.filter { $0.state == "conflict" || $0.state == "uncertain" || $0.state == "not_applied" || ($0.error != nil && !($0.error?.isEmpty ?? true)) }
        case .undoable:
            base = walRows.filter { $0.state == "applied" }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.operation.lowercased().contains(q)
                || ($0.before?.name.lowercased().contains(q) ?? false)
                || ($0.after?.name.lowercased().contains(q) ?? false)
                || ($0.error?.lowercased().contains(q) ?? false)
        }
    }

    private var hasRollbackable: Bool {
        OperationJournal.shared.hasRollbackableRows(runId: run.id)
            || walRows.contains(where: { $0.state == "applied" })
    }

    private var matchingPlan: ScrapePlan? {
        PlanAndTaskStore.shared.plans.first(where: { $0.id == run.planId })
    }

    public var body: some View {
        List {
            Section("任务摘要") {
                LabeledContent("来源", value: run.sourceLabel.isEmpty ? run.id : run.sourceLabel)
                LabeledContent("网盘", value: run.provider)
                LabeledContent("状态", value: run.message)
                LabeledContent("统计", value: "成功 \(run.succeeded) / 失败 \(run.failed) / 共 \(run.total)")
                if let fin = run.finishedAt {
                    let secs = max(0, Int(fin.timeIntervalSince(run.startedAt)))
                    LabeledContent("耗时", value: "\(secs) 秒")
                }
            }

            Section("操作") {
                if matchingPlan != nil {
                    NavigationLink {
                        TaskItemsView(run: run)
                    } label: {
                        Label("查看逐条计划操作明细（全部/成功/失败/未执行）", systemImage: "checklist")
                    }
                }
                if run.failed > 0, matchingPlan != nil {
                    Button {
                        retryFailedActions()
                    } label: {
                        Label("仅重试失败 / 未完成项", systemImage: "arrow.clockwise.circle.fill")
                    }
                }

                if hasRollbackable {
                    Button(role: .destructive) {
                        showRollbackConfirm = true
                    } label: {
                        HStack {
                            if rollingBack { ProgressView().padding(.trailing, 6) }
                            Label(rollingBack ? "正在按 WAL 逆序撤销…" : "一键撤销本次整理操作", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                    }
                    .disabled(rollingBack)
                }

                if let retryHint {
                    Text(retryHint).font(.footnote).foregroundStyle(MMTheme.accent)
                }
                if let rollbackHint {
                    Text(rollbackHint).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !run.errors.isEmpty {
                Section("错误摘要（\(run.errors.count)）") {
                    ForEach(Array(run.errors.enumerated()), id: \.offset) { _, err in
                        Text(err).font(.caption).foregroundStyle(MMTheme.redErr)
                    }
                }
            }

            Section {
                Picker("明细筛选", selection: $filter) {
                    ForEach(DetailFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }

            if !filteredWalRows.isEmpty {
                Section("事务 WAL 记录（\(filteredWalRows.count)）") {
                    ForEach(filteredWalRows) { row in
                        let primaryName = row.before?.name ?? row.after?.name ?? row.actionId
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("[\(MMTheme.opLabel(row.operation))] \(primaryName)")
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                Spacer()
                                stateBadge(row.state)
                            }
                            if let afterName = row.after?.name, !afterName.isEmpty, afterName != primaryName {
                                Text("→ \(afterName)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            if let err = row.error, !err.isEmpty {
                                Text(err).font(.caption2).foregroundStyle(MMTheme.redErr)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !filteredJournalRows.isEmpty {
                Section("操作日志明细（\(filteredJournalRows.count)）") {
                    ForEach(filteredJournalRows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("[\(MMTheme.opLabel(row.op))] \(row.newName.isEmpty ? row.oldName : row.newName)")
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                Spacer()
                                stateBadge(row.status.rawValue)
                            }
                            if !row.oldName.isEmpty && row.oldName != row.newName {
                                Text("原名：\(row.oldName)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if let err = row.error, !err.isEmpty {
                                Text(err).font(.caption2).foregroundStyle(MMTheme.redErr)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else if filteredWalRows.isEmpty {
                Section {
                    ContentUnavailableView("当前筛选下无明细记录", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "按文件名、操作类型或错误信息搜索")
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确认撤销本次任务的全部已执行操作？", isPresented: $showRollbackConfirm, titleVisibility: .visible) {
            Button("确认逆序撤销", role: .destructive) {
                Task { await runRollback() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func stateBadge(_ state: String) -> some View {
        let color: Color
        switch state {
        case "applied": color = MMTheme.greenOk
        case "reverted": color = .secondary
        case "failed", "uncertain", "conflict": color = MMTheme.redErr
        default: color = .orange
        }
        return Text(state)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

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
