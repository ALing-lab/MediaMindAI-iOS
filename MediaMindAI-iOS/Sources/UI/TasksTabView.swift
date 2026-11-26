import SwiftUI
import UIKit

/// 任务中心页（参考任务中心双标签卡片流：进行中 / 已完成 + 4 步流水线状态 + 队列与实时进度 + WAL 崩溃核实）。
public struct TasksTabView: View {
    public init() {}
    @State private var previewPlan: ScrapePlan? = nil
    @State private var pendingCancelPlan: ScrapePlan? = nil

    private var pendingPlans: [ScrapePlan] { store.pendingPlans }

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
    @State private var cancellation = TaskCancellation.shared
    @State private var backupChoice: TaskControl? = nil
    @State private var applyingBackupChoice = false

    private var missingBackupControls: [TaskControl] {
        cancellation.controls.values.filter { $0.state == "needs_backup_choice" }
            .sorted { $0.taskId < $1.taskId }
    }

    private var activeRun: TaskRun? {
        guard engine.isRunning, let r = engine.currentRun else { return nil }
        return r
    }

    /// 已暂停且尚未完成的任务记录（显示在「进行中」以便随时继续或取消）。
    private var pausedRuns: [TaskRun] {
        let activeId = activeRun?.id
        return store.tasks.filter { $0.id != activeId && ($0.status == "paused" || $0.status == "running") }
    }

    private var activeCount: Int {
        pendingPlans.count + (activeRun != nil ? 1 : 0) + pausedRuns.count + queue.items.count
    }

    private var completedRuns: [TaskRun] {
        let activeId = activeRun?.id
        return store.tasks.filter { $0.id != activeId && ["done", "failed", "stopped", "no_changes"].contains($0.status) }
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

                    let uncertain = journal.uncertainRows()
                    let walUncertain = ReversibleWalStore.shared.uncertainRecords()
                    let hasBanners = !missingBackupControls.isEmpty || reconcileHint != nil || !uncertain.isEmpty || !walUncertain.isEmpty
                    let isTabEmpty = (selectedTab == .active && activeCount == 0) || (selectedTab == .completed && completedRuns.isEmpty)

                    if isTabEmpty && !hasBanners {
                        ContentUnavailableView(
                            selectedTab == .active ? "暂无进行中的任务" : "暂无已完成任务",
                            systemImage: selectedTab == .active ? "bolt.circle" : "checkmark.circle",
                            description: Text(selectedTab == .active
                                              ? "在「云盘」扫描完成后，待执行任务会显示在这里。"
                                              : "执行完成或已取消的任务记录会归档在这里，可随时查看日志与一键回滚。")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(missingBackupControls) { control in
                                    Button("撤销暂停：\(control.missingBackupIds.count) 项备份缺失，选择处理方式") {
                                        backupChoice = control
                                    }
                                    .font(.footnote)
                                    .padding(12)
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
            }
            .navigationTitle("任务中心")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(item: $previewPlan) { plan in
                PreviewTabView(planId: plan.id, onStartExecution: {
                    previewPlan = nil
                    selectedTab = .active
                })
            }
            .onChange(of: pendingPlans.map(\.id)) { old, new in
                if new.contains(where: { !old.contains($0) }) { selectedTab = .active }
            }
            .alert("取消待执行任务？", isPresented: Binding(get: { pendingCancelPlan != nil }, set: { if !$0 { pendingCancelPlan = nil } }), presenting: pendingCancelPlan) { plan in
                Button("取消任务", role: .destructive) {
                    store.cancelPendingPlan(id: plan.id)
                    pendingCancelPlan = nil
                }
                Button("继续保留", role: .cancel) { pendingCancelPlan = nil }
            } message: { _ in Text("仅取消本地待执行计划，不修改云盘文件。") }
            .sheet(item: $backupChoice) { control in
                NavigationStack {
                    Form {
                        Section {
                            Text("原备份已缺失。继续后将尝试采用本任务当前生成的文件，或重新刮削补齐；这些文件不是原备份。无法核验的文件不会被覆盖。")
                            ForEach(control.missingBackupIds, id: \.self) { actionId in
                                let row = ReversibleWalStore.shared.find(taskId: control.taskId, actionId: actionId)
                                Text(row?.before?.name ?? actionId)
                            }
                        }
                        Button("同意以新文件补齐并继续撤销", role: .destructive) {
                            continueUndoWithSubstitutions(control)
                        }
                        .disabled(applyingBackupChoice)
                        Button("暂不处理，保留当前文件") { backupChoice = nil }
                            .disabled(applyingBackupChoice)
                    }
                    .navigationTitle("缺失备份处理")
                    .interactiveDismissDisabled(applyingBackupChoice)
                }
            }
            .alert("停止当前任务？", isPresented: $showStopConfirm) {
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
                                            reconcileHint = "撤销暂停：缺失备份 \(done.missingBackupIds.count) 项，请在任务中心选择处理方式"
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
            .alert(
                "确认删除任务记录？",
                isPresented: Binding(get: { pendingDeleteRun != nil }, set: { if !$0 { pendingDeleteRun = nil } }),
                presenting: pendingDeleteRun
            ) { target in
                Button("删除记录", role: .destructive) {
                    let isActive = engine.currentRun?.id == target.id && (engine.isRunning || engine.isPaused)
                    store.deleteTask(id: target.id, allowPaused: !isActive)
                    pendingDeleteRun = nil
                }
                Button("取消", role: .cancel) { pendingDeleteRun = nil }
            } message: { _ in
                Text("仅移除本地任务卡片，不影响网盘已有文件。若后续需要一键撤销回滚，建议保留该记录。")
            }
        }
    }

    private func continueUndoWithSubstitutions(_ control: TaskControl) {
        guard !applyingBackupChoice else { return }
        guard let account = AccountStore.shared.accounts.first(where: { $0.id == control.accountId }) else {
            reconcileHint = "原任务所属云盘账号已删除或不可用"
            backupChoice = nil
            return
        }
        applyingBackupChoice = true
        Task { @MainActor in
            defer { applyingBackupChoice = false; backupChoice = nil }
            do {
                let drive = try AccountStore.shared.buildDrive(for: account)
                let request = try cancellation.request(taskId: control.taskId, accountId: control.accountId, undo: true,
                                                       acceptedSubstitutions: control.missingBackupIds)
                let result = await cancellation.apply(control: request, drive: drive)
                reconcileHint = result.state == "completed" ? "已补齐并完成撤销" : "撤销仍有缺失备份、冲突或待核实日志，请核实后重试"
            } catch {
                reconcileHint = "继续撤销失败：\(error.localizedDescription)"
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
                description: Text("在「云盘」扫描完成后，待执行任务会显示在这里。")
            )
            .padding(.top, 48)
        } else {
            ForEach(pendingPlans) { plan in pendingPlanCard(plan) }
            if let run = activeRun {
                runningTaskCard(run)
            }

            ForEach(pausedRuns) { run in
                pausedTaskCard(run)
            }

            ForEach(queue.items) { item in
                queuedTaskCard(item)
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

    private func pendingPlanCard(_ plan: ScrapePlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeaderRow(taskId: plan.id,
                subtitle: "\(providerDisplay(plan.provider)) · \(plan.roots.map(\.name).joined(separator: "、"))",
                badgeText: "", badgeColor: MMTheme.accent)
                .contentShape(Rectangle()).onTapGesture { previewPlan = plan }
            pipelineStepRow(steps: [("识别", .done), ("待执行", .active), ("整理", .pending), ("刮削", .pending)])
                .contentShape(Rectangle()).onTapGesture { previewPlan = plan }
            if let update = plan.flags.last(where: { $0.hasPrefix("扫描更新：") }) {
                Text(update).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .contentShape(Rectangle()).onTapGesture { previewPlan = plan }
            }
            HStack {
                Button("取消任务") { pendingCancelPlan = plan }
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer()
                Button {
                    guard let account = AccountStore.shared.get(id: plan.accountId),
                          let drive = try? AccountStore.shared.buildDrive(for: account) else {
                        reconcileHint = "找不到任务所属云盘账号，请检查账号配置"
                        return
                    }
                    if !engine.enqueueOrStart(plan: plan, drive: drive) { reconcileHint = engine.lastStartError }
                } label: {
                    Text(engine.isRunning ? "加入队列" : "立即执行").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .foregroundStyle(.white).background(MMTheme.accent, in: Capsule())
                }
            }
            .buttonStyle(.plain).foregroundStyle(MMTheme.accent)
            cardFooterRow(fileCount: uniqueVideoCount(in: plan, pendingOnly: true) ?? 0, folderCount: plan.groups.count, extraCount: nil, date: plan.createdAt)
                .contentShape(Rectangle()).onTapGesture { previewPlan = plan }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture { previewPlan = plan }
                .accessibilityLabel("预览扫描计划 \(plan.id)")
                .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: - 1. 正在执行卡片

    private func uniqueVideoCount(in plan: ScrapePlan?, pendingOnly: Bool = false) -> Int? {
        guard let plan else { return nil }
        let keys = Set(plan.actions.filter { $0.kind == "file" && (!pendingOnly || (!$0.done && !(plan.submittedActionIds ?? []).contains($0.id))) }.map { $0.fileId ?? $0.id })
        return keys.isEmpty ? nil : keys.count
    }

    private func runningTaskCard(_ run: TaskRun) -> some View {
        let linkedPlan = store.plans.first(where: { $0.id == run.planId })
        let fileCount = uniqueVideoCount(in: run.executionSnapshot) ?? 0
        let folderCount = run.executionSnapshot?.groups.count ?? 0
        let hasScrape = run.executionSnapshot?.actions.contains(where: { $0.op == "artwork" && $0.selected }) ?? false

        return VStack(alignment: .leading, spacing: 10) {
            cardHeaderRow(
                taskId: run.id,
                subtitle: "\(providerDisplay(run.provider)) · \(run.sourceLabel.isEmpty ? run.planId : run.sourceLabel)",
                badgeText: "",
                badgeColor: .blue
            )

            pipelineStepRow(steps: [
                ("识别", .done),
                ("整理", engine.isPaused ? .pending : (engine.currentPhase == ExecPhases.artwork ? .done : .active)),
                ("刮削", hasScrape ? (engine.isPaused ? .pending : (engine.currentPhase == ExecPhases.artwork ? .active : ((engine.currentPhase ?? 0) > ExecPhases.artwork ? .done : .pending))) : .none)
            ])

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(run.message.isEmpty ? (engine.isPaused ? "任务已暂停" : "正在执行云端操作…") : run.message)
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
                    engine.isPaused.toggle()
                } label: {
                    Text(engine.isPaused ? "继续任务" : "暂停任务")
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

    private func continuePaused(_ run: TaskRun, plan: ScrapePlan, drive: any CloudDrive) {
        guard let captured = run.executionSnapshot else {
            reconcileHint = "旧任务缺少执行范围，不能自动扩大续跑；请重新扫描确认"
            return
        }
        let ids = captured.actions.filter { !$0.done && ExecutionEngine.execOps.contains($0.op) }.map(\.id)
        guard Set(ids).isSubset(of: Set(plan.actions.map(\.id))), engine.enqueueOrStart(plan: plan, drive: drive, actionIds: ids) else {
            reconcileHint = engine.lastStartError ?? "原动作已变更，请重新扫描确认"
            return
        }
        var old = run
        old.status = "stopped"; old.message = "已发起限定原范围的续跑任务"
        store.saveTask(old)
    }

    private func pausedTaskCard(_ run: TaskRun) -> some View {
        let linkedPlan = store.plans.first(where: { $0.id == run.planId })
        let fileCount = uniqueVideoCount(in: run.executionSnapshot) ?? 0
        let folderCount = run.executionSnapshot?.groups.count ?? 0
        let hasScrape = run.executionSnapshot?.actions.contains(where: { $0.op == "artwork" && $0.selected }) ?? false

        return VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                CompletedTaskDetailScreen(run: run)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    cardHeaderRow(
                        taskId: run.id,
                        subtitle: "\(providerDisplay(run.provider)) · \(run.sourceLabel.isEmpty ? run.planId : run.sourceLabel)",
                        badgeText: "已暂停",
                        badgeColor: .orange
                    )

                    pipelineStepRow(steps: [
                        ("识别", .done),
                        ("整理", .pending),
                        ("刮削", hasScrape ? .pending : .none)
                    ])

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("任务已暂停 · 已完成 \(run.completed)/\(run.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("查看详情 ›")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(MMTheme.accent)
                        }
                        ProgressView(value: Double(run.completed), total: Double(max(1, run.total)))
                            .tint(.orange)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Button {
                    var stopped = run
                    stopped.status = "stopped"
                    stopped.message = "已取消"
                    stopped.finishedAt = Date()
                    store.saveTask(stopped)
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
                    guard let pausedPlan = linkedPlan,
                          let acct = AccountStore.shared.get(id: run.accountId),
                          let drive = try? AccountStore.shared.buildDrive(for: acct) else {
                        reconcileHint = "找不到原计划或云盘账号，无法继续任务"
                        return
                    }
                    continuePaused(run, plan: pausedPlan, drive: drive)
                } label: {
                    Text("继续任务")
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

    // MARK: - 4. 已完成 / 已取消历史卡片（对应参考图 2）

    private func completedTaskCard(_ run: TaskRun) -> some View {
        let linkedPlan = run.executionSnapshot
        let rows = journal.rows(forRunId: run.id)
        let walRows = ReversibleWalStore.shared.rows(taskId: run.id)
        let fileCount = uniqueVideoCount(in: linkedPlan) ?? Set(rows.filter { $0.kind == "file" }.map { $0.fileId ?? $0.actionId }).count
        let folderCount = linkedPlan?.groups.count ?? rows.filter { $0.kind == "folder" }.count
        let artworkCount = rows.filter { $0.op == "artwork" }.count
        let isStopped = run.status == "stopped"
        let isDone = run.isSuccessful
        let hasScrape = artworkCount > 0 || (linkedPlan?.actions.contains { $0.op == "artwork" && $0.done } ?? false)
        let hasRollback = journal.hasRollbackableRows(runId: run.id) || walRows.contains(where: { $0.state == "applied" })

        let steps: [(String, StepState)] = isStopped
            ? [("识别", .cancelled), ("整理", .cancelled), ("刮削", .cancelled)]
            : [
                ("识别", .done),
                ("整理", isDone ? .done : (run.failed > 0 ? .failed : .pending)),
                ("刮削", hasScrape ? .done : .none)
            ]

        return NavigationLink {
            CompletedTaskDetailScreen(run: run)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                cardHeaderRow(
                    taskId: run.id,
                    subtitle: "\(providerDisplay(run.provider)) · \(run.sourceLabel.isEmpty ? run.planId : run.sourceLabel)",
                    badgeText: "",
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
                    } else if run.hasNoEffectiveOperations {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        Text("无有效操作").font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
                    continuePaused(run, plan: pausedPlan, drive: drive)
                } label: {
                    Label("继续任务", systemImage: "play.fill")
                }
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


                Spacer()

                if !badgeText.isEmpty {
                    Text(badgeText)
                        .font(.caption2.weight(.medium)).foregroundStyle(badgeColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(badgeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
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
            TaskStepIcon(name: icon, rotating: state == .active)
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

/// 兼容 iOS 17，动画生命周期随图标出现/消失，不创建计时器。
private struct TaskStepIcon: View {
    let name: String
    let rotating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var body: some View {
        Image(systemName: name)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(spinning ? .linear(duration: 1.2).repeatForever(autoreverses: false) : .default, value: spinning)
            .onAppear { spinning = rotating && !reduceMotion }
            .onChange(of: rotating) { _, value in spinning = value && !reduceMotion }
            .onChange(of: reduceMotion) { _, value in spinning = rotating && !value }
            .onDisappear { spinning = false }
    }
}
