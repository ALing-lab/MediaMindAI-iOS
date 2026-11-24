import SwiftUI
import UIKit

/// 任务中心页（1:1 对标 Android TasksScreen + CompletedTaskDetailScreen：实时进度、TaskQueue 排队队列、WAL 崩溃核实、操作日志详情与一键撤销回滚）。
public struct TasksTabView: View {
    public init() {}
    @State private var engine = ExecutionEngine.shared
    @State private var store = PlanAndTaskStore.shared
    @State private var queue = TaskQueue.shared
    @State private var journal = OperationJournal.shared
    @State private var reconcileHint: String?
    @State private var reconciling = false
    @State private var showStopConfirm = false
    @State private var stoppingRun: TaskRun? = nil
    @State private var pendingDeleteRun: TaskRun? = nil

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()
                TopAmbientGlow()
                List {
                let uncertain = journal.uncertainRows()
                let walUncertain = ReversibleWalStore.shared.uncertainRecords()
                if let reconcileHint {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill").foregroundStyle(MMTheme.accent)
                            Text(reconcileHint).font(.footnote)
                            Spacer()
                            Button("关闭") { self.reconcileHint = nil }.font(.caption)
                        }
                    }
                }

                if !uncertain.isEmpty || !walUncertain.isEmpty {
                    Section("异常中断核实") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("检测到 \(uncertain.count + walUncertain.count) 条未收口操作日志（可能因断网或中断导致）", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                            Button {
                                Task { await runReconcile() }
                            } label: {
                                if reconciling {
                                    ProgressView()
                                } else {
                                    Text("核实云端真实状态")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(reconciling)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let run = engine.currentRun, engine.isRunning {
                    Section("正在执行") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(run.sourceLabel).font(.headline)
                                Spacer()
                                Text("\(run.completed)/\(run.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(run.completed), total: Double(max(1, run.total)))
                            Text(run.message).font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Button(engine.isPaused ? "继续" : "暂停") {
                                    engine.isPaused.toggle()
                                }
                                .buttonStyle(.bordered)
                                Button("停止", role: .destructive) {
                                    stoppingRun = run
                                    showStopConfirm = true
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !queue.items.isEmpty {
                    Section("排队等待中（\(queue.items.count)）") {
                        ForEach(queue.items) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.sourceLabel.isEmpty ? "计划 \(item.planId)" : item.sourceLabel).font(.subheadline.bold())
                                    Text("\(item.provider) · \(item.actionCount) 项操作").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "clock").foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { idxs in
                            let ids = idxs.compactMap { queue.items.indices.contains($0) ? queue.items[$0].id : nil }
                            for id in ids { queue.remove(id: id) }
                        }
                    }
                }

                Section("任务记录（\(store.tasks.count)）") {
                    if store.tasks.isEmpty {
                        ContentUnavailableView("暂无任务记录", systemImage: "bolt", description: Text("在「预览」中点击执行后，任务进度、WAL 操作明细与一键回滚会显示在这里。"))
                    } else {
                        ForEach(store.tasks) { t in
                            NavigationLink {
                                CompletedTaskDetailScreen(run: t)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(t.sourceLabel.isEmpty ? "任务 \(t.id)" : t.sourceLabel).font(.headline)
                                        Spacer()
                                        statusPill(t.status)
                                    }
                                    Text("\(t.provider) · 成功 \(t.succeeded) / 失败 \(t.failed) / 共 \(t.total)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if journal.hasRollbackableRows(runId: t.id) || ReversibleWalStore.shared.rows(taskId: t.id).contains(where: { $0.state == "applied" }) {
                                        Text("支持一键撤销回滚").font(.caption2).foregroundStyle(MMTheme.accent)
                                    }
                                    if let firstErr = t.errors.first {
                                        Text(firstErr).font(.caption2).foregroundStyle(MMTheme.redErr).lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                let hasUncertain = journal.rows(forRunId: t.id).contains(where: { $0.status == .prepared || $0.status == .uncertain || $0.status == .undoPrepared })
                                    || ReversibleWalStore.shared.rows(taskId: t.id).contains(where: { $0.state == "uncertain" || $0.state == "prepared" || $0.state == "undo_prepared" })
                                let canResumePaused = t.status == "paused" && !hasUncertain
                                    && store.plans.contains(where: { $0.id == t.planId })
                                    && AccountStore.shared.get(id: t.accountId) != nil
                                let isActiveEngineRun = engine.currentRun?.id == t.id && (engine.isRunning || engine.isPaused)
                                if canResumePaused {
                                    Button {
                                        guard let pausedPlan = store.plans.first(where: { $0.id == t.planId }),
                                              let acct = AccountStore.shared.get(id: t.accountId),
                                              let drive = try? AccountStore.shared.buildDrive(for: acct) else { return }
                                        var superseded = t
                                        superseded.status = "stopped"
                                        superseded.message = "已发起续跑任务"
                                        store.saveTask(superseded)
                                        ExecutionEngine.shared.enqueueOrStart(plan: pausedPlan, drive: drive)
                                    } label: {
                                        Label("继续任务", systemImage: "play.fill")
                                    }
                                    .tint(MMTheme.accent)
                                }
                                if t.status != "running" && !isActiveEngineRun && !hasUncertain {
                                    Button(role: .destructive) {
                                        pendingDeleteRun = t
                                    } label: {
                                        Label("删除记录", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("任务中心")
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

    private func statusPill(_ status: String) -> some View {
        let (label, color): (String, Color) = switch status {
        case "done": ("已完成", MMTheme.greenOk)
        case "running": ("执行中", MMTheme.accent)
        case "paused": ("已暂停", .orange)
        case "stopped": ("已停止", .secondary)
        default: ("部分失败", MMTheme.redErr)
        }
        return Text(label)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// 已完成任务详情与一键撤销回滚页（1:1 对标 Android CompletedTaskDetailScreen）。
