import SwiftUI
import UIKit

/// 任务中心页（参考任务中心双标签卡片流：进行中 / 已完成 + 4 步流水线状态 + 队列与实时进度 + WAL 崩溃核实）。
public struct TasksTabView: View {
    public let onOpenPreview: () -> Void
    public init(onOpenPreview: @escaping () -> Void = {}) {
        self.onOpenPreview = onOpenPreview
    }

    private enum TaskFilterTab: Int, CaseIterable {
        case active = 0
        case completed = 1
    }

    @State private var selectedTab: TaskFilterTab = .active
    @State private var engine = ExecutionEngine.shared
    @State private var store = PlanAndTaskStore.shared
    @State private var queue = TaskQueue.shared
    @State private var journal = OperationJournal.shared
    @State private var reconcileHint: String?
    @State private var reconciling = false
    @State private var showStopConfirm = false
    @State private var stoppingRun: TaskRun? = nil
    @State private var pendingDeleteRun: TaskRun? = nil
    @State private var pendingCancelPlan: ScrapePlan? = nil
    @State private var copiedToast: String? = nil

    private var activeRun: TaskRun? {
        guard engine.isRunning, let r = engine.currentRun else { return nil }
        return r
    }

    /// 尚未执行完、且当前未在运行或排队中的识别计划（显示在「进行中」的待确认卡片）。
    private var pendingPlans: [ScrapePlan] {
        let runningPlanId = activeRun?.planId
        let queuedPlanIds = Set(queue.items.map(\.planId))
        return store.plans.filter { plan in
            if plan.id == runningPlanId || queuedPlanIds.contains(plan.id) { return false }
            return plan.actions.contains { !$0.done && $0.enabled && $0.op != "unmatched" }
        }
    }

    private var activeCount: Int {
        (activeRun != nil ? 1 : 0) + queue.items.count + pendingPlans.count
    }

    private var completedRuns: [TaskRun] {
        let activeId = activeRun?.id
        return store.tasks.filter { $0.id != activeId }
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()
                TopAmbientGlow()

                VStack(spacing: 0) {
                    // 顶部双标签：进行中 (N) | 已完成
                    Picker("任务状态", selection: $selectedTab) {
                        Text(activeCount > 0 ? "进行中 (\(activeCount))" : "进行中").tag(TaskFilterTab.active)
                        Text("已完成").tag(TaskFilterTab.completed)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if let copiedToast {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(MMTheme.greenOk)
                                    Text(copiedToast)
                                        .font(.caption)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }

                            if let reconcileHint {
                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle.fill").foregroundStyle(MMTheme.accent)
                                    Text(reconcileHint).font(.footnote)
                                    Spacer()
                                    Button("关闭") { self.reconcileHint = nil }
                                        .font(.caption)
                                        .foregroundStyle(MMTheme.accent)
                                }
                                .padding(12)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            let uncertain = journal.uncertainRows()
                            let walUncertain = ReversibleWalStore.shared.uncertainRecords()
                            if !uncertain.isEmpty || !walUncertain.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("检测到 \(uncertain.count + walUncertain.count) 条未收口操作日志（可能因断网或中断导致）", systemImage: "exclamationmark.triangle.fill")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(.orange)
                                    Button {
                                        Task { await runReconcile() }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if reconciling { ProgressView().controlSize(.small) }
                                            Text(reconciling ? "核实中…" : "核实云端真实状态")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(MMTheme.accent, in: Capsule())
                                        .foregroundStyle(.white)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(reconciling)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            if selectedTab == .active {
                                activeTabContent
                            } else {
                                completedTabContent
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("任务中心")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("停止当前任务", isPresented: $showStopConfirm, titleVisibility: .visible) {
                Button("停止并保留已完成项") {
                    let run = stoppingRun
                    if let run {
                        let acctId = !run.accountId.isEmpty ? run.accountId : (AccountStore.shared.activeAccount?.id ?? "")
                        Task {
                            if let ctrl = try? TaskCancellation.shared.request(taskId: run.id, accountId: acctId, undo: false) {
                                _ = await TaskCancellation.shared.applyKeep(control: ctrl)
                            } else {
                                await engine.stopAndWait()
                            }
                            await MainActor.run { reconcileHint = "任务已停止并保留已完成项" }
                        }
                    } else {
                        engine.stop()
                    }
                }
                Button("停止并撤销已完成项", role: .destructive) {
                    let run = stoppingRun
                    if let run {
                        let acct: DriveAccount? = !run.accountId.isEmpty
                            ? AccountStore.shared.get(id: run.accountId)
                            : AccountStore.shared.activeAccount
                        if let acct, let drive = try? AccountStore.shared.buildDrive(for: acct) {
                            Task {
                                do {
                                    let ctrl = try TaskCancellation.shared.request(taskId: run.id, accountId: acct.id, undo: true)
                                    let done = await TaskCancellation.shared.apply(control: ctrl, drive: drive)
                                    await MainActor.run {
                                        if done.state == "completed" {
                                            reconcileHint = "任务已停止并撤销已完成操作"
                                        } else if done.state == "needs_backup_choice" {
                                            reconcileHint = "撤销暂停：缺失备份 \(done.missingBackupIds.count) 项，请在任务详情中核实"
                                        } else {
                                            reconcileHint = "撤销遇到冲突或待核实日志，请先点击「核实云端真实状态」"
                                        }
                                    }
                                } catch {
                                    await engine.stopAndWait()
                                    await MainActor.run { reconcileHint = "停止撤销失败：\(error.localizedDescription)" }
                                }
                            }
                        } else {
                            engine.stop()
                            reconcileHint = "原任务所属云盘账号已删除或不可用，无法撤销已完成操作"
                        }
                    } else {
                        engine.stop()
                    }
                }
                Button("继续执行", role: .cancel) {}
            } message: {
                Text("选择停止方式：保留已完成项，或尝试把本轮已执行的云端操作逐条回滚。")
            }
            .confirmationDialog(
                "确认取消该待执行任务？",
                isPresented: Binding(get: { pendingCancelPlan != nil }, set: { if !$0 { pendingCancelPlan = nil } }),
                titleVisibility: .visible
            ) {
                Button("取消任务", role: .destructive) {
                    if let plan = pendingCancelPlan {
                        store.deletePlan(id: plan.id)
                    }
                    pendingCancelPlan = nil
                }
                Button("返回", role: .cancel) { pendingCancelPlan = nil }
            } message: {
                Text("将移除本地待确认计划，不会改动云盘上的任何文件。")
            }
            .confirmationDialog(
                "确认删除任务记录？",
                isPresented: Binding(get: { pendingDeleteRun != nil }, set: { if !$0 { pendingDeleteRun = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除记录", role: .destructive) {
                    if let target = pendingDeleteRun {
                        let isActive = engine.currentRun?.id == target.id && (engine.isRunning || engine.isPaused)
                        store.deleteTask(id: target.id, allowPaused: !isActive)
                    }
                    pendingDeleteRun = nil
                }
                Button("取消", role: .cancel) { pendingDeleteRun = nil }
            } message: {
                Text("仅移除本地任务卡片，不影响网盘已有文件。若后续需要一键撤销回滚，建议保留该记录。")
            }
        }
    }

    // MARK: - 进行中标签页

    @ViewBuilder
    private var activeTabContent: some View {
        if activeCount == 0 {
            ContentUnavailableView(
                "暂无进行中的任务",
                systemImage: "bolt.circle",
                description: Text("在「云盘」扫描目录或在「预览」发起整理后，任务进度会显示在这里。")
            )
            .padding(.top, 48)
        } else {
            if let run = activeRun {
                runningTaskCard(run)
            }

            ForEach(queue.items) { item in
                queuedTaskCard(item)
            }

            ForEach(pendingPlans) { plan in
                pendingPlanCard(plan)
            }
        }
    }

    // MARK: - 已完成标签页

    @ViewBuilder
    private var completedTabContent: some View {
        if completedRuns.isEmpty {
            ContentUnavailableView(
                "暂无已完成任务",
                systemImage: "checkmark.circle",
                description: Text("执行完成或已取消的任务记录会归档在这里，可随时查看日志与一键回滚。")
            )
            .padding(.top, 48)
        } else {
            ForEach(completedRuns) { run in
                completedTaskCard(run)
            }
        }
    }

    // MARK: - 1. 正在执行卡片

    private func runningTaskCard(_ run: TaskRun) -> some View {
        let linkedPlan = store.plans.first(where: { $0.id == run.planId })
        let fileCount = linkedPlan?.actions.filter { $0.kind == "file" }.count ?? run.total
        let folderCount = linkedPlan?.groups.count ?? 0
        let hasScrape = linkedPlan?.actions.contains(where: { $0.op == "artwork" && $0.selected }) ?? false

        return VStack(alignment: .leading, spacing: 10) {
            cardHeaderRow(
                taskId: run.id,
                subtitle: "\(providerDisplay(run.provider)) · \(run.sourceLabel.isEmpty ? run.planId : run.sourceLabel)",
                badgeText: "本机执行",
                badgeColor: .blue
            )

            pipelineStepRow(steps: [
                ("识别", .done),
                ("待确认", .done),
                ("整理", .active),
                ("刮削", hasScrape ? .pending : .none)
            ])

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(run.message.isEmpty ? (engine.isPaused ? "已暂停执行" : "正在执行云端操作…") : run.message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(run.completed)/\(run.total)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MMTheme.accent)
                }
                ProgressView(value: Double(run.completed), total: Double(max(1, run.total)))
                    .tint(MMTheme.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(MMTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Button {
                    stoppingRun = run
                    showStopConfirm = true
                } label: {
                    Text("停止任务")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MMTheme.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    engine.isPaused.toggle()
                } label: {
                    Text(engine.isPaused ? "继续执行" : "暂停执行")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(MMTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            cardFooterRow(fileCount: fileCount, folderCount: folderCount, extraCount: nil, date: run.startedAt)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 2. 排队等待卡片

    private func queuedTaskCard(_ item: QueuedTaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeaderRow(
                taskId: item.planId,
                subtitle: "\(providerDisplay(item.provider)) · \(item.sourceLabel.isEmpty ? item.planId : item.sourceLabel)",
                badgeText: "排队中",
                badgeColor: .orange
            )

            pipelineStepRow(steps: [
                ("识别", .done),
                ("待确认", .done),
                ("整理", .pending),
                ("刮削", .pending)
            ])

            HStack {
                Label("排队等待当前任务完成后自动开始（\(item.actionCount) 项操作）", systemImage: "clock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("移出队列") {
                    queue.remove(id: item.id)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(MMTheme.redErr)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 3. 待确认计划卡片（对应参考图 1）

    private func pendingPlanCard(_ plan: ScrapePlan) -> some View {
        let rootPath = plan.roots.map(\.name).joined(separator: "、")
        let fileCount = plan.actions.filter { $0.kind == "file" }.count
        let folderCount = plan.groups.count
        let selectedCount = plan.actions.filter { $0.selected && !$0.done && $0.op != "unmatched" }.count
        let hasScrape = plan.actions.contains { $0.op == "artwork" && $0.enabled }

        return VStack(alignment: .leading, spacing: 10) {
            cardHeaderRow(
                taskId: plan.id,
                subtitle: "\(providerDisplay(plan.provider)) · \(rootPath.isEmpty ? "待确认计划" : rootPath)",
                badgeText: "本机执行",
                badgeColor: .blue
            )

            pipelineStepRow(steps: [
                ("识别", .done),
                ("待确认", .active),
                ("整理", .pending),
                ("刮削", hasScrape ? .pending : .none)
            ])

            Button {
                onOpenPreview()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(MMTheme.accent)
                    Text("识别完成，请确认结果后继续执行")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 2) {
                        Text("去确认")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MMTheme.accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(MMTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Button {
                    pendingCancelPlan = plan
                } label: {
                    Text("取消任务")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MMTheme.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    startPlan(plan)
                } label: {
                    Text(selectedCount > 0 ? "立即执行" : "去预览确认")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(MMTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            cardFooterRow(fileCount: fileCount, folderCount: folderCount, extraCount: nil, date: plan.createdAt)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 4. 已完成 / 已取消历史卡片（对应参考图 2）

    private func completedTaskCard(_ run: TaskRun) -> some View {
        let linkedPlan = store.plans.first(where: { $0.id == run.planId })
        let rows = journal.rows(forRunId: run.id)
        let walRows = ReversibleWalStore.shared.rows(taskId: run.id)
        let fileCount = linkedPlan?.actions.filter { $0.kind == "file" }.count ?? max(run.total, rows.filter { $0.kind == "file" }.count)
        let folderCount = linkedPlan?.groups.count ?? rows.filter { $0.kind == "folder" }.count
        let artworkCount = rows.filter { $0.op == "artwork" }.count
        let isStopped = run.status == "stopped"
        let isDone = run.status == "done"
        let hasScrape = artworkCount > 0 || (linkedPlan?.actions.contains { $0.op == "artwork" && $0.done } ?? false)
        let hasRollback = journal.hasRollbackableRows(runId: run.id) || walRows.contains(where: { $0.state == "applied" })

        let steps: [(String, StepState)] = isStopped
            ? [("识别", .cancelled), ("待确认", .cancelled), ("整理", .cancelled), ("刮削", .cancelled)]
            : [
                ("识别", .done),
                ("待确认", .done),
                ("整理", run.failed > 0 && run.succeeded == 0 ? .failed : .done),
                ("刮削", hasScrape ? .done : .none)
            ]

        return NavigationLink {
            CompletedTaskDetailScreen(run: run)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                cardHeaderRow(
                    taskId: run.id,
                    subtitle: "\(providerDisplay(run.provider)) · \(run.sourceLabel.isEmpty ? run.planId : run.sourceLabel)",
                    badgeText: "本机执行",
                    badgeColor: .blue
                )

                pipelineStepRow(steps: steps)

                HStack(spacing: 6) {
                    if isDone && run.failed == 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MMTheme.greenOk)
                            .font(.subheadline)
                        Text("任务执行完成")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(MMTheme.greenOk)
                    } else if isStopped {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Text("已取消")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else if run.status == "paused" {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                        Text("已暂停 · 成功 \(run.succeeded)/\(run.total)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(MMTheme.redErr)
                            .font(.subheadline)
                        Text("部分失败 · 成功 \(run.succeeded) / 失败 \(run.failed)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(MMTheme.redErr)
                    }

                    Spacer()

                    if hasRollback {
                        Text("可回滚")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(MMTheme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(MMTheme.accent.opacity(0.12), in: Capsule())
                    }
                }

                cardFooterRow(
                    fileCount: fileCount,
                    folderCount: folderCount,
                    extraCount: artworkCount > 0 ? artworkCount : nil,
                    date: run.finishedAt ?? run.startedAt
                )
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            let hasUncertain = rows.contains(where: { $0.status == .prepared || $0.status == .uncertain || $0.status == .undoPrepared })
                || walRows.contains(where: { $0.state == "uncertain" || $0.state == "prepared" || $0.state == "undo_prepared" })
            if run.status == "paused", !hasUncertain,
               let pausedPlan = linkedPlan,
               let acct = AccountStore.shared.get(id: run.accountId),
               let drive = try? AccountStore.shared.buildDrive(for: acct) {
                Button {
                    var superseded = run
                    superseded.status = "stopped"
                    superseded.message = "已发起续跑任务"
                    store.saveTask(superseded)
                    ExecutionEngine.shared.enqueueOrStart(plan: pausedPlan, drive: drive)
                } label: {
                    Label("继续任务", systemImage: "play.fill")
                }
            }
            Button {
                copyTaskId(run.id)
            } label: {
                Label("复制任务 ID", systemImage: "doc.on.doc")
            }
            if !hasUncertain {
                Button(role: .destructive) {
                    pendingDeleteRun = run
                } label: {
                    Label("删除记录", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 共享卡片子组件

    private enum StepState {
        case done, active, pending, cancelled, failed, none
    }

    private func cardHeaderRow(taskId: String, subtitle: String, badgeText: String, badgeColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(taskId)
                    .font(.subheadline.monospaced().bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Button {
                    copyTaskId(taskId)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(badgeText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badgeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func pipelineStepRow(steps: [(String, StepState)]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, pair in
                if pair.1 != .none {
                    stepChip(title: pair.0, state: pair.1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func stepChip(title: String, state: StepState) -> some View {
        let (icon, fg, bg): (String, Color, Color) = switch state {
        case .done:
            ("checkmark", MMTheme.greenOk, MMTheme.greenOk.opacity(0.14))
        case .active:
            ("arrow.triangle.2.circlepath", MMTheme.accent, MMTheme.accent.opacity(0.14))
        case .pending:
            ("circle", .secondary, Color.secondary.opacity(0.12))
        case .cancelled:
            ("minus.circle", .secondary, Color.secondary.opacity(0.12))
        case .failed:
            ("xmark.circle", MMTheme.redErr, MMTheme.redErr.opacity(0.14))
        case .none:
            ("circle", .secondary, Color.clear)
        }
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func cardFooterRow(fileCount: Int, folderCount: Int, extraCount: Int?, date: Date) -> some View {
        HStack(spacing: 12) {
            Label("\(fileCount)", systemImage: "film")
            if folderCount > 0 {
                Label("\(folderCount)", systemImage: "folder")
            }
            if let extraCount, extraCount > 0 {
                Label("\(extraCount)", systemImage: "photo")
            }
            Spacer()
            Text(Self.shortDateFormatter.string(from: date))
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func providerDisplay(_ raw: String) -> String {
        switch raw.lowercased() {
        case "guangya": return "光鸭"
        case "p123", "123": return "123"
        case "webdav": return "WebDAV"
        default: return raw
        }
    }

    private func copyTaskId(_ id: String) {
        UIPasteboard.general.string = id
        copiedToast = "已复制任务 ID：\(id)"
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                if copiedToast == "已复制任务 ID：\(id)" {
                    copiedToast = nil
                }
            }
        }
    }

    private func startPlan(_ plan: ScrapePlan) {
        let selectedCount = plan.actions.filter { $0.selected && !$0.done && $0.op != "unmatched" }.count
        guard selectedCount > 0 else {
            onOpenPreview()
            return
        }
        guard let acct = AccountStore.shared.accounts.first(where: { $0.id == plan.accountId }),
              let drive = try? AccountStore.shared.buildDrive(for: acct) else {
            reconcileHint = "找不到该计划对应的云盘账号，无法启动执行"
            return
        }
        ExecutionEngine.shared.enqueueOrStart(plan: plan, drive: drive)
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private func runReconcile() async {
        reconciling = true
        defer { reconciling = false }
        var driveCache: [String: any CloudDrive] = [:]
        func resolveDrive(accountId: String) -> (any CloudDrive)? {
            let targetAcct: DriveAccount? = !accountId.isEmpty
                ? AccountStore.shared.get(id: accountId)
                : AccountStore.shared.activeAccount
            guard let acct = targetAcct else { return nil }
            if let cached = driveCache[acct.id] { return cached }
            guard let built = try? AccountStore.shared.buildDrive(for: acct) else { return nil }
            driveCache[acct.id] = built
            return built
        }

        let taskAccountById = Dictionary(store.tasks.map { ($0.id, $0.accountId) }, uniquingKeysWith: { _, last in last })
        let uncertainJournal = journal.uncertainRows()
        let runIds = Array(Set(uncertainJournal.map { $0.runId }))
        var applied = 0, notApplied = 0, reverted = 0, still = 0, missingAcct = 0
        for rid in runIds {
            let acctId = taskAccountById[rid] ?? ""
            guard let drive = resolveDrive(accountId: acctId) else {
                missingAcct += uncertainJournal.filter { $0.runId == rid }.count
                continue
            }
            let rep = await JournalReconciler.reconcile(runId: rid, drive: drive)
            applied += rep.confirmedApplied
            notApplied += rep.confirmedNotApplied
            reverted += rep.confirmedReverted
            still += rep.stillUncertain
        }

        let uncertainWal = ReversibleWalStore.shared.uncertainRecords()
        let walTaskIds = Array(Set(uncertainWal.map(\.taskId)))
        for tid in walTaskIds {
            let acctId = uncertainWal.first(where: { $0.taskId == tid && !$0.accountId.isEmpty })?.accountId
                ?? taskAccountById[tid] ?? ""
            guard let drive = resolveDrive(accountId: acctId) else {
                missingAcct += uncertainWal.filter { $0.taskId == tid }.count
                continue
            }
            let rep = await JournalReconciler.reconcileReversibleWal(taskId: tid, drive: drive)
            applied += rep.confirmedApplied
            notApplied += rep.confirmedNotApplied
            reverted += rep.confirmedReverted
            still += rep.stillUncertain
        }
        still += missingAcct
        let missingNote = missingAcct > 0 ? "（其中 \(missingAcct) 条所属账号不可用）" : ""
        reconcileHint = "核实完成：已生效 \(applied) / 未生效 \(notApplied) / 已回滚 \(reverted) / 待定 \(still)\(missingNote)"
    }
}
