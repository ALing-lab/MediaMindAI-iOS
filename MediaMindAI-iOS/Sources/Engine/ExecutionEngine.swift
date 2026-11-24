import Foundation
import Observation

/// 1:1 复刻 Android `ExecPhases`：严格五阶段执行序号与中文标签。
public enum ExecPhases {
    public static let rename = 1
    public static let mkdir = 2
    public static let move = 3
    public static let artwork = 4
    public static let delete = 5
    public static let count = 5

    public static func of(_ op: String) -> Int {
        switch op {
        case "rename": return rename
        case "mkdir": return mkdir
        case "move": return move
        case "artwork": return artwork
        case "delete", "trash": return delete
        default: return count
        }
    }

    public static func label(_ phase: Int) -> String {
        switch phase {
        case rename: return "重命名"
        case mkdir: return "新建文件夹"
        case move: return "移动归位"
        case artwork: return "写入海报与 NFO"
        case delete: return "清理多余目录"
        default: return "整理中"
        }
    }
}

/// 自适应并发闸门（1:1 复刻 Android `AdaptiveConcurrencyGate.kt`：按网盘画像起步并发，命中真实风控只降不升）。
public actor AdaptiveConcurrencyGate {
    public static let defaultLevels = [6, 3, 1]

    private let levels: [Int]
    private var levelIndex = 0
    private var active = 0
    public private(set) var peakActive = 0
    private var backoffUntilNs: UInt64 = 0
    private var lastStepDownNs: UInt64 = 0

    public init(levels: [Int] = AdaptiveConcurrencyGate.defaultLevels) {
        self.levels = levels.isEmpty ? Self.defaultLevels : levels
    }

    public var currentLimit: Int { levels[levelIndex] }

    public func acquire(skipBackoff: Bool = false) async throws {
        while true {
            try Task.checkCancellation()
            if !skipBackoff {
                let now = DispatchTime.now().uptimeNanoseconds
                if backoffUntilNs > now {
                    let wait = min(backoffUntilNs - now, 250_000_000)
                    try await Task.sleep(nanoseconds: wait)
                    continue
                }
            }
            if active < levels[levelIndex] {
                active += 1
                if active > peakActive { peakActive = active }
                return
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    public func release() {
        active = max(0, active - 1)
    }

    nonisolated public func withPermit<T>(isolation: isolated (any Actor)? = #isolation, skipBackoff: Bool = false, _ op: () async throws -> T) async throws -> T {
        try await acquire(skipBackoff: skipBackoff)
        do {
            let result = try await op()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    public func onSuccess() {
        // 策略：命中真实风控后只降不升，成功不主动回升避免二次触发频控。
    }

    @discardableResult
    public func onRateLimited(backoffMs: UInt64 = 1500, minStepDownGapNs: UInt64 = 1_500_000_000) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastStepDownNs == 0 || (now - lastStepDownNs) >= minStepDownGapNs {
            if levelIndex + 1 < levels.count {
                levelIndex += 1
                lastStepDownNs = now
            }
        }
        backoffUntilNs = max(backoffUntilNs, now &+ backoffMs * 1_000_000)
        return levels[levelIndex]
    }
}

/// 删除前安全扫描结果（1:1 对标 Android `ExecutionEngine.VideoScan`）。
public struct VideoScanResult: Equatable, Sendable {
    public let videos: Int
    public let complete: Bool

    public init(videos: Int, complete: Bool) {
        self.videos = videos
        self.complete = complete
    }
}

/// 1:1 逐行复刻自 Android `ExecutionEngine.kt`（981 行 / 60.3 KB）：
/// 五阶段严格排序（`executionOrder`）+ 启动 WAL 未收口拦截 + 100 项 `moveBatch` 打包与单条回退 +
/// 首项探针并发波次（`AdaptiveConcurrencyGate` 6→3→1 降档与重试）+ 可挂起冲突连带挂起（`ConflictPolicy`）+
/// 连续失败熔断（5 次自动暂停）+ 重复保留区强哈希复核 + 删除前有界 BFS 视频扫描（`countVideosBounded`）+
/// `IdRemap` WebDAV 路径重映射 + `PlanStore` / `HistoryStore` / `TaskQueue` 全链路闭环。
@MainActor
@Observable
public final class ExecutionEngine {
    public static let shared = ExecutionEngine()

    public nonisolated static let execOps: Set<String> = ["rename", "mkdir", "move", "artwork", "delete", "trash"]
    public nonisolated static let maxConsecutiveFails = 5
    public nonisolated static let settleDelayNs: UInt64 = 1_200_000_000
    public nonisolated static let uploadRetryDelaysNs: [UInt64] = [2_000_000_000, 5_000_000_000]
    public nonisolated static let deleteTooBigMessage = "文件夹太大，未检查完，已跳过删除"

    private nonisolated static let sequentialMoveKinds: Set<String> = [
        "folder", "disc_folder", "cleanup",
        LibraryDestination.kind,
        AdaptiveDirectoryPlanner.kindAdaptiveMove,
        DuplicateRetentionPlanner.kindRetentionDuplicate,
    ]

    public private(set) var currentRun: TaskRun?
    public private(set) var isRunning = false
    public var isPaused = false
    public private(set) var isRollingBack = false
    public private(set) var rollbackMessage: String?
    public private(set) var lastPeakConcurrency: Int = 0
    public private(set) var lastConcurrencyLimit: Int = 0

    private var activeTask: Task<Void, Never>?
    private var stopRequested = false
    public var driveResolver: (@MainActor (String) -> (any CloudDrive)?)?

    private init() {}

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
    }

    public func stop() {
        stopRequested = true
        isPaused = false
    }

    /// 发出温和停止信号并等待在途单步云端写入自然落盘退出（不强杀在途网络请求，避免 WAL 变 uncertain 阻塞撤销）。
    public func stopAndWait() async {
        stopRequested = true
        isPaused = false
        if let task = activeTask {
            await task.value
            if activeTask == nil {
                isRunning = false
                isPaused = false
                BackgroundTaskManager.shared.end()
            }
        }
    }

    /// 若当前已有任务运行，则自动加入 TaskQueue 排队等待；否则立即开始执行。
    public func enqueueOrStart(plan: ScrapePlan, drive: any CloudDrive, actionIds: [String]? = nil) {
        if isRunning {
            TaskQueue.shared.enqueue(plan: plan, actionIds: actionIds)
            return
        }
        start(plan: plan, drive: drive, actionIds: actionIds)
    }

    public func rollback(runId: String, drive: any CloudDrive) async -> RollbackSummary {
        if currentRun?.id == runId {
            await stopAndWait()
        }
        isRollingBack = true
        rollbackMessage = "正在按逆序回滚网盘操作…"
        let walRows = ReversibleWalStore.shared.rows(taskId: runId)
        if !walRows.isEmpty {
            let tx = ReversibleTransaction(taskId: runId, drive: drive)
            let subActions: [String: PlanAction] = {
                guard let run = PlanAndTaskStore.shared.tasks.first(where: { $0.id == runId }),
                      let plan = PlanAndTaskStore.shared.plans.first(where: { $0.id == run.planId }) else { return [:] }
                return Dictionary(plan.actions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            }()
            do {
                try await tx.undo(substitutionActions: subActions) { done, total in
                    Task { @MainActor in self.rollbackMessage = "正在逆序回滚 \(done)/\(total)…" }
                }
                for jRow in OperationJournal.shared.rows(forRunId: runId) where jRow.status == .applied {
                    OperationJournal.shared.markStatus(rowId: jRow.id, status: .undone)
                }
                let summary = RollbackSummary(total: walRows.count, undone: walRows.count, failed: 0, errors: [])
                rollbackMessage = "回滚完成：已安全撤销 \(walRows.count) 项"
                isRollingBack = false
                return summary
            } catch let mb as MissingBackupsError {
                let msg = mb.localizedDescription
                rollbackMessage = msg
                isRollingBack = false
                return RollbackSummary(total: walRows.count, undone: 0, failed: mb.files.count, errors: [msg])
            } catch {
                let msg = error.localizedDescription
                rollbackMessage = "回滚中止：\(msg)"
                isRollingBack = false
                return RollbackSummary(total: walRows.count, undone: 0, failed: 1, errors: [msg])
            }
        }
        let summary = await ReversibleOperations.rollback(runId: runId, drive: drive) { msg in
            Task { @MainActor in self.rollbackMessage = msg }
        }
        rollbackMessage = "回滚完成：已撤销 \(summary.undone) 项，失败 \(summary.failed) 项"
        isRollingBack = false
        return summary
    }

    // MARK: - 1. 严格五阶段执行顺序（1:1 对标 ExecutionEngine.executionOrder）

    /// ① 重命名（先目录后文件，浅层目录先于深层目录）→ ② 新建文件夹 → ③ 移动 → ④ 上传海报与 NFO → ⑤ 删除多余目录。
    public nonisolated static func executionOrder(ids: [String], actions: [String: PlanAction]) -> [String] {
        func rank(_ id: String) -> Int {
            guard let a = actions[id] else { return 99 }
            let p = ExecPhases.of(a.op)
            return p * 2 + (a.op == "rename" && a.kind != "folder" ? 1 : 0)
        }
        func depth(_ id: String) -> Int {
            guard let a = actions[id], a.op == "rename", a.kind == "folder" else { return 0 }
            return (a.fileId ?? "").filter { $0 == "/" }.count
        }
        return ids.enumerated().sorted { lhs, rhs in
            let r1 = rank(lhs.element), r2 = rank(rhs.element)
            if r1 != r2 { return r1 < r2 }
            let d1 = depth(lhs.element), d2 = depth(rhs.element)
            if d1 != d2 { return d1 < d2 }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    public nonisolated static func canRunConcurrently(_ action: PlanAction?) -> Bool {
        guard let a = action else { return false }
        return (a.op == "rename" || a.op == "move" || a.op == "artwork") && !sequentialMoveKinds.contains(a.kind)
    }

    public nonisolated static func labelOf(_ a: PlanAction) -> String {
        switch a.op {
        case "rename": return "改名 \(a.oldName) → \(a.newName)"
        case "mkdir": return "新建 \(a.newName)"
        case "move": return "移动 \(a.oldName) → \(a.destLabel ?? a.destParentId ?? "")"
        case "artwork": return "上传 \(a.newName)"
        case "delete", "trash": return "删除 \(a.oldName)"
        default: return a.op
        }
    }

    nonisolated public static func resolveDest(action: PlanAction, refs: [String: String]) -> String? {
        if let dp = action.destParentId, !dp.isEmpty { return dp }
        if let ref = action.destRef, let hit = refs["action:\(ref)"] { return hit }
        if let ref = action.destRef, let hit = refs[ref] { return hit }
        guard let label = action.destLabel, !label.isEmpty else { return nil }
        if let parent = action.parentId, let hit = refs["\(parent):\(label)"] { return hit }
        return refs.first(where: { $0.key.hasSuffix(":\(label)") })?.value
    }

    /// 删除前有界 BFS 视频计数（1:1 对标 Android `countVideosBounded`：超过层级/条目/目录上限立即返回 complete=false 拒绝删除）。
    public nonisolated static func countVideosBounded(
        drive: any CloudDrive,
        folderId: String,
        maxDepth: Int = 8,
        maxEntries: Int = 5_000,
        maxDirs: Int = 300
    ) async throws -> VideoScanResult {
        var videos = 0
        var entries = 0
        var dirs = 0
        var frontier: [String] = [folderId]
        var depth = 0
        while !frontier.isEmpty {
            if depth > maxDepth { return VideoScanResult(videos: videos, complete: false) }
            var next: [String] = []
            for dir in frontier {
                dirs += 1
                if dirs > maxDirs { return VideoScanResult(videos: videos, complete: false) }
                let kids = try await drive.list(folderId: dir)
                entries += kids.count
                if entries > maxEntries { return VideoScanResult(videos: videos, complete: false) }
                for k in kids {
                    if k.isDir {
                        next.append(k.fileId)
                    } else if MediaParser.isVideo(k.fileName) {
                        videos += 1
                    }
                }
            }
            frontier = next
            depth += 1
        }
        return VideoScanResult(videos: videos, complete: true)
    }

    // MARK: - 2. 完整五阶段批处理状态机（1:1 对标 ExecutionEngine.run）

    public func start(
        plan: ScrapePlan,
        drive: any CloudDrive,
        actionIds: [String]? = nil,
        skipDelaysForTest: Bool = false
    ) {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        stopRequested = false
        BackgroundTaskManager.shared.begin()

        let requestedIds: [String]
        if let actionIds {
            requestedIds = actionIds
        } else {
            requestedIds = plan.actions.filter { $0.selected && PlanSelection.executable($0) && Self.execOps.contains($0.op) }.map(\.id)
        }

        let runId = String(UUID().uuidString.prefix(8).lowercased())
        var run = TaskRun(
            id: runId,
            planId: plan.id,
            accountId: plan.accountId,
            provider: plan.provider,
            sourceLabel: plan.roots.map(\.name).joined(separator: "、"),
            status: "running",
            total: requestedIds.count,
            completed: 0,
            succeeded: 0,
            failed: 0,
            message: "正在准备执行…",
            startedAt: Date(),
            finishedAt: nil,
            errors: []
        )
        currentRun = run
        PlanAndTaskStore.shared.saveTask(run)

        activeTask = Task {
            let profile = DriveRateProfile.forDrive(drive)
            let gate = AdaptiveConcurrencyGate(levels: profile.writeConcurrencyLevels)
            let journal = OperationJournal.shared

            if !drive.approvalBinding.isEmpty {
                let currentBinding = AccountStore.shared.approvalBinding(for: drive.accountId)
                if currentBinding != drive.approvalBinding {
                    run.status = "stopped"
                    run.finishedAt = Date()
                    run.message = "账号凭据或服务器地址已变更，为防止误操作已中止执行，请重新扫描确认"
                    currentRun = run
                    PlanAndTaskStore.shared.saveTask(run)
                    activeTask = nil
                    isRunning = false
                    BackgroundTaskManager.shared.end()
                    return
                }
            }

            // 启动前 WAL 安全检查：若 WAL 存储已损坏则立即 fail-closed 拦截写入
            if ReversibleWalStore.shared.hasStorageCorruption {
                run.status = "failed"
                run.finishedAt = Date()
                run.message = ReversibleWalStore.shared.lastStorageError ?? "可逆日志已损坏，已阻止写入以保护历史记录"
                currentRun = run
                PlanAndTaskStore.shared.saveTask(run)
                activeTask = nil
                isRunning = false
                BackgroundTaskManager.shared.end()
                return
            }
            // 启动前 WAL 安全检查：仅按当前账号范围拦截未收口操作日志，避免跨账号永久死锁
            let acctRunIds = Set(PlanAndTaskStore.shared.tasks.filter { $0.accountId == plan.accountId }.map(\.id))
            let uncertainAtStart = journal.uncertainRows().filter { acctRunIds.isEmpty || acctRunIds.contains($0.runId) }
            let uncertainWalAtStart = ReversibleWalStore.shared.uncertainRecords().filter { $0.accountId.isEmpty || $0.accountId == plan.accountId }
            if !uncertainAtStart.isEmpty || !uncertainWalAtStart.isEmpty {
                let hasUndoPrepared = uncertainAtStart.contains { $0.status == .undoPrepared }
                    || uncertainWalAtStart.contains { $0.state == "undo_prepared" }
                let totalUncertain = uncertainAtStart.count + uncertainWalAtStart.count
                run.status = "stopped"
                run.finishedAt = Date()
                run.message = hasUndoPrepared
                    ? "存在撤销中断的操作，请先在任务中心核实日志后再继续"
                    : "存在 \(totalUncertain) 条待核实的云盘操作，已拦截写入"
                currentRun = run
                PlanAndTaskStore.shared.saveTask(run)
                activeTask = nil
                isRunning = false
                BackgroundTaskManager.shared.end()
                return
            }

            var updatedPlan = plan
            var planActions = Dictionary(plan.actions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let planGroups = Dictionary(plan.groups.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let ordered = Self.executionOrder(ids: requestedIds, actions: planActions)

            // 启动前检查全部通过后，清理本轮待执行项的旧错误并从历史已生效 WAL 重建 mkdirRefs 与 idRemap（保证失败子集重试可找到前置目录与改名后路径）
            for rid in ordered {
                if var a = planActions[rid], !a.done {
                    a.error = nil
                    planActions[rid] = a
                    if let idx = updatedPlan.actions.firstIndex(where: { $0.id == rid }) {
                        updatedPlan.actions[idx].error = nil
                    }
                }
            }
            var mkdirRefs: [String: String] = [:]
            let idRemap = IdRemap(pathMode: drive.kind.idsArePaths)
            let planTaskIds = Set(PlanAndTaskStore.shared.tasks.filter { $0.planId == plan.id }.map(\.id))
            let priorApplied = ReversibleWalStore.shared.appliedRecords(
                accountId: plan.accountId,
                actionIds: Set(planActions.keys),
                taskIds: planTaskIds.isEmpty ? nil : planTaskIds
            )
            // 第 1 遍先建 idRemap（含 :finalize 重命名），第 2 遍再用 remap 解析重建 mkdirRefs（含 parent:label 键）
            for rec in priorApplied where rec.operation == "rename" || rec.operation == "move" || rec.operation == "quarantine" || rec.operation == "backup" {
                if let oldId = rec.before?.id, let newId = rec.after?.id, !oldId.isEmpty, !newId.isEmpty {
                    idRemap.record(old: oldId, new: newId)
                }
            }
            for rec in priorApplied where rec.operation == "mkdir" {
                if let rawAfterId = rec.after?.id, !rawAfterId.isEmpty {
                    let resolvedId = idRemap.resolveOrSelf(rawAfterId)
                    mkdirRefs["action:\(rec.actionId)"] = resolvedId
                    mkdirRefs[rec.actionId] = resolvedId
                    if let act = planActions[rec.actionId], !act.newName.isEmpty {
                        let pid = act.parentId ?? drive.rootId
                        mkdirRefs["\(pid):\(act.newName)"] = resolvedId
                    }
                }
            }
            var newlyOkIds: [String] = []
            let tx = ReversibleTransaction(taskId: runId, drive: drive, cancellationCheck: { Task.isCancelled })
            var settled = !ordered.contains { planActions[$0]?.op != "artwork" }
            var deferredConflicts = Set<String>()
            var deferredByDep: [String: String] = [:]
            var batchConsumed = Set<String>()
            var streak = 0
            var stoppedOnFails = false
            var stoppedEarly = false

            @MainActor func syncPlanAction(_ id: String, done: Bool, error: String?, note: String? = nil, recordInHistory: Bool = true) {
                if var a = planActions[id] {
                    if done && !a.done && recordInHistory { newlyOkIds.append(id) }
                    a.done = done
                    a.error = error
                    if let note { a.note = note }
                    planActions[id] = a
                }
                if let idx = updatedPlan.actions.firstIndex(where: { $0.id == id }) {
                    updatedPlan.actions[idx].done = done
                    updatedPlan.actions[idx].error = error
                    if let note { updatedPlan.actions[idx].note = note }
                }
            }

            @MainActor func recordOutcome(actionId: String, ok: Bool, skipped: Bool = false, noopNote: String? = nil, markDone: Bool = true, err: String?) {
                run.completed += 1
                if let noopNote {
                    // 禁用项 / 非执行 op / TMDB 暂无素材：不计入 newlyOkIds、不覆盖为「已存在，未覆盖」
                    streak = 0
                    if !noopNote.isEmpty {
                        syncPlanAction(actionId, done: markDone ? true : (planActions[actionId]?.done ?? false), error: nil, note: noopNote, recordInHistory: false)
                    }
                } else if ok || skipped {
                    run.succeeded += 1
                    streak = 0
                    syncPlanAction(actionId, done: markDone, error: nil, note: skipped ? "已存在，未覆盖" : nil, recordInHistory: ok && !skipped)
                } else {
                    run.failed += 1
                    if let err { run.errors.append(err) }
                    syncPlanAction(actionId, done: false, error: err, recordInHistory: false)
                }
                currentRun = run
            }

            @MainActor func waitIfPaused() async -> Bool {
                while isPaused && !stopRequested && !Task.isCancelled {
                    run.status = "paused"
                    run.message = "已暂停"
                    currentRun = run
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if stopRequested || Task.isCancelled {
                    stoppedEarly = true
                    return false
                }
                if run.status == "paused" {
                    streak = 0
                    run.status = "running"
                    run.message = "继续执行…"
                    currentRun = run
                }
                return true
            }

            @MainActor func executeOne(_ act: PlanAction) async throws -> (resultId: String?, note: String?) {
                switch act.op {
                case "rename":
                    guard let rawFid = act.fileId else { throw DriveError.invalidInput("缺少 fileId") }
                    let fid = ((try? idRemap.resolve(rawFid)) ?? rawFid)
                    let resolvedParent: String?
                    if let rawParent = act.parentId {
                        resolvedParent = idRemap.resolveOrSelf(rawParent)
                    } else if drive.kind.idsArePaths {
                        resolvedParent = DrivePaths.parentOf(fid)
                    } else {
                        resolvedParent = try await drive.parentIdOf(fileId: fid)
                    }
                    guard let safeParent = resolvedParent else {
                        throw DriveError.invalidInput("缺少原父目录，无法记录可撤销重命名操作")
                    }
                    let newId = try await tx.rename(action: act.id, id: fid, parent: safeParent, name: act.newName)
                    idRemap.record(old: fid, new: newId)
                    idRemap.record(old: rawFid, new: newId)
                    return (newId, nil)

                case "mkdir":
                    if act.destRef != nil && Self.resolveDest(action: act, refs: mkdirRefs) == nil {
                        throw DriveError.invalidInput("上级文件夹还没建好")
                    }
                    let resolvedParent = Self.resolveDest(action: act, refs: mkdirRefs) ?? act.parentId ?? drive.rootId
                    let parent = idRemap.resolveOrSelf(resolvedParent)
                    let createdId = try await tx.mkdir(action: act.id, parent: parent, name: act.newName)
                    mkdirRefs["action:\(act.id)"] = createdId
                    mkdirRefs[act.id] = createdId
                    mkdirRefs["\(act.parentId ?? drive.rootId):\(act.newName)"] = createdId
                    return (createdId, nil)

                case "move":
                    guard let rawFid = act.fileId else { throw DriveError.invalidInput("缺少 fileId") }
                    let fid = ((try? idRemap.resolve(rawFid)) ?? rawFid)
                    let parent = act.parentId.map { idRemap.resolveOrSelf($0) }
                    let resolvedMoveParent: String?
                    if let safeParent = parent {
                        resolvedMoveParent = safeParent
                    } else if drive.kind.idsArePaths {
                        resolvedMoveParent = DrivePaths.parentOf(fid)
                    } else {
                        resolvedMoveParent = try await drive.parentIdOf(fileId: fid)
                    }
                    // 重复保留区移入前强复核：必须重新列目录确认 size > 0 且具备强格式内容哈希
                    if act.kind == DuplicateRetentionPlanner.kindRetentionDuplicate {
                        guard let safeParent = resolvedMoveParent else {
                            throw DriveError.invalidInput("缺少原父目录，无法移入重复保留区")
                        }
                        let liveItems = try await drive.list(folderId: safeParent)
                        guard let liveEntry = liveItems.first(where: { !$0.isDir && $0.fileId == fid }) else {
                            throw DriveError.invalidInput("执行前复核未找到待移入保留区的重复文件，已停止移动")
                        }
                        guard liveEntry.size > 0,
                              ContentDigest.normalize(algorithm: liveEntry.hashAlgorithm, hash: liveEntry.contentHash) != nil else {
                            throw DriveError.invalidInput("执行前复核未通过：文件缺少强格式内容哈希或大小为 0，已保留原位")
                        }
                        let grp = planGroups[act.groupId]
                        let workTitle = (grp?.title.isEmpty == false ? grp?.title : grp?.folderName) ?? act.oldName
                        let rec = try await RetentionZoneEngine.shared.moveToRetention(
                            ops: tx,
                            drive: drive,
                            taskId: runId,
                            actionId: act.id,
                            entry: liveEntry,
                            originalParentId: safeParent,
                            originalPath: act.folderPath ?? safeParent,
                            workTitle: workTitle,
                            confirmedDuplicate: true,
                            reason: act.note ?? "完全重复文件",
                            customRootId: act.destParentId
                        )
                        idRemap.record(old: fid, new: rec.retentionFileId)
                        idRemap.record(old: rawFid, new: rec.retentionFileId)
                        return (rec.retentionFileId, "已移入重复保留区")
                    }
                    guard let rawDest = Self.resolveDest(action: act, refs: mkdirRefs) else {
                        throw DriveError.invalidInput("目标文件夹还没建好")
                    }
                    let dest = idRemap.resolveOrSelf(rawDest)
                    guard let safeParent = resolvedMoveParent else {
                        throw DriveError.invalidInput("缺少原父目录，无法记录可撤销移动操作")
                    }
                    let newId = try await tx.move(action: act.id, id: fid, parent: safeParent, dest: dest)
                    idRemap.record(old: fid, new: newId)
                    idRemap.record(old: rawFid, new: newId)
                    return (newId, nil)

                case "artwork":
                    let rawDest: String?
                    if let ref = act.destRef {
                        rawDest = mkdirRefs["action:\(ref)"] ?? mkdirRefs[ref]
                    } else {
                        rawDest = act.destParentId ?? act.parentId
                    }
                    guard let rawDest else {
                        throw DriveError.invalidInput("目标文件夹 \(act.destLabel ?? "") 还没建好")
                    }
                    let dest = idRemap.resolveOrSelf(rawDest)
                    let grp = planGroups[act.groupId]
                    let kind = act.mediaKind ?? (grp?.kind == "tv" || grp?.kind == "movie" ? grp?.kind : nil) ?? "tv"
                    let title = grp?.kind == "collection" ? (act.destLabel ?? "电影") : ((grp?.title.isEmpty == false ? grp?.title : nil) ?? "影视作品")
                    let root = grp?.kind == "collection" ? dest : (grp?.folderId.map { idRemap.resolveOrSelf($0) } ?? dest)
                    let yrPart = (grp?.year.isEmpty == false) ? " (\(grp!.year))" : ""
                    let tid = act.tmdbId ?? grp?.tmdbId
                    let scope = AssetBackupScope(
                        rootId: root,
                        workKey: tid.map { "\(kind):\($0)" } ?? "\(kind):\(act.groupId)",
                        workLabel: "\(String(title.prefix(48)))\(yrPart) [\(kind)-tmdb-\(tid ?? 0)]",
                        locationLabel: dest == root ? "根目录" : (act.destLabel ?? (act.season.map { String(format: "Season %02d", $0) } ?? "子目录-\(String(dest.suffix(8)))"))
                    )
                    let created = try await tx.upload(
                        action: act.id,
                        parent: dest,
                        name: act.newName,
                        replaceExisting: act.replaceExisting,
                        backupScope: scope
                    ) {
                        try await ArtworkFetcher.shared.contentFor(action: act)
                    }
                    return (nil, created ? nil : "已存在")

                case "delete", "trash":
                    if let blocked = act.blocked { throw DriveError.invalidInput(blocked) }
                    guard let rawFid = act.fileId else { throw DriveError.invalidInput("缺少 fileId") }
                    let fid = ((try? idRemap.resolve(rawFid)) ?? rawFid)
                    if act.kind != "file" {
                        let unmet = PlanSelection.deleteNeeds(act, all: Array(planActions.values)).filter { !$0.done || $0.error != nil }
                        if !unmet.isEmpty {
                            throw DriveError.invalidInput("仍有 \(unmet.count) 个视频或字幕未移出，为安全起见未删除")
                        }
                        let scan = try await Self.countVideosBounded(drive: drive, folderId: fid)
                        if !scan.complete { throw DriveError.invalidInput(Self.deleteTooBigMessage) }
                        if scan.videos > 0 {
                            throw DriveError.invalidInput("文件夹里还有 \(scan.videos) 个视频（可能移动没成功），为安全起见未删除")
                        }
                    }
                    let resolvedDelParent: String?
                    if let rawParent = act.parentId {
                        resolvedDelParent = idRemap.resolveOrSelf(rawParent)
                    } else if drive.kind.idsArePaths {
                        resolvedDelParent = DrivePaths.parentOf(fid)
                    } else {
                        resolvedDelParent = try await drive.parentIdOf(fileId: fid)
                    }
                    guard let safeParent = resolvedDelParent else {
                        throw DriveError.invalidInput("缺少原父目录，无法移入可恢复暂存目录")
                    }
                    let moved = try await tx.quarantine(action: act.id, id: fid, parent: safeParent)
                    idRemap.record(old: fid, new: moved)
                    return (moved, "已移入可恢复暂存目录")

                default:
                    return (nil, "跳过")
                }
            }

            @MainActor func runSingleAction(_ id: String) async {
                guard !stopRequested && !Task.isCancelled else { return }
                guard let act = planActions[id] else {
                    recordOutcome(actionId: id, ok: false, noopNote: "", err: nil)
                    return
                }
                if act.done || !act.enabled || !Self.execOps.contains(act.op) {
                    recordOutcome(actionId: id, ok: false, noopNote: "", err: nil)
                    return
                }
                if let depReason = deferredByDep[id] {
                    recordOutcome(actionId: id, ok: false, err: depReason)
                    run.message = "已挂起依赖项：\(Self.labelOf(act))"
                    currentRun = run
                    return
                }

                let phase = ExecPhases.of(act.op)
                run.message = "\(ExecPhases.label(phase)) · \(Self.labelOf(act))"
                currentRun = run

                let resolvedDest = Self.resolveDest(action: act, refs: mkdirRefs).map { idRemap.resolveOrSelf($0) }
                let row = journal.prepare(
                    runId: runId, actionId: act.id, op: act.op, kind: act.kind,
                    fileId: act.fileId.map { idRemap.resolveOrSelf($0) },
                    parentId: act.parentId.map { idRemap.resolveOrSelf($0) },
                    destParentId: resolvedDest,
                    oldName: act.oldName, newName: act.newName
                )

                var outcome: Result<(resultId: String?, note: String?), Error>
                do {
                    let r = try await gate.withPermit(skipBackoff: skipDelaysForTest) {
                        try await executeOne(act)
                    }
                    outcome = .success(r)
                } catch {
                    outcome = .failure(error)
                }

                // 命中真实限流（429 / 频控）：自动降档并重试一次
                if case .failure(let err) = outcome, RateLimitDetector.isRateLimitError(err), !stopRequested {
                    let nextLimit = await gate.onRateLimited(backoffMs: skipDelaysForTest ? 0 : 1500)
                    run.message = "触发限流，已自动降为 \(nextLimit) 并发并重试…"
                    currentRun = run
                    do {
                        let r = try await gate.withPermit(skipBackoff: skipDelaysForTest) {
                            try await executeOne(act)
                        }
                        outcome = .success(r)
                    } catch {
                        outcome = .failure(error)
                    }
                }

                // 数据源确实无此素材（如 TMDB 暂无单集剧照）：记为跳过，标已完成但不计入历史、不重试、不计失败
                if case .failure(let err) = outcome, err is ArtworkUnavailableError {
                    await gate.onSuccess()
                    journal.markSkipped(rowId: row.id, error: err.localizedDescription)
                    recordOutcome(actionId: act.id, ok: false, noopNote: err.localizedDescription, markDone: true, err: nil)
                    return
                }

                // 海报 / NFO 上传失败退避重试（2s -> 5s）；若 WAL 已存在 uncertain/prepared 行则严禁重试
                if case .failure = outcome, act.op == "artwork", !stopRequested,
                   !ReversibleWalStore.shared.hasUncertain(taskId: runId) {
                    for (idx, waitNs) in Self.uploadRetryDelaysNs.enumerated() {
                        if stopRequested || Task.isCancelled || ReversibleWalStore.shared.hasUncertain(taskId: runId) { break }
                        run.message = "上传 \(act.newName) 失败，稍后第 \(idx + 1)/\(Self.uploadRetryDelaysNs.count) 次重试"
                        currentRun = run
                        if !skipDelaysForTest { try? await Task.sleep(nanoseconds: waitNs) }
                        do {
                            let r = try await gate.withPermit(skipBackoff: skipDelaysForTest) {
                                try await executeOne(act)
                            }
                            outcome = .success(r)
                            break
                        } catch {
                            outcome = .failure(error)
                        }
                    }
                }

                switch outcome {
                case .success(let res):
                    await gate.onSuccess()
                    let existed = res.note == "已存在"
                    if existed {
                        journal.markSkipped(rowId: row.id, error: "已存在")
                    } else {
                        journal.markApplied(rowId: row.id, createdId: res.resultId)
                    }
                    recordOutcome(actionId: act.id, ok: !existed, skipped: existed, err: nil)

                case .failure(let error):
                    let errStr = "\(Self.labelOf(act))：\(error.localizedDescription)"
                    let isUncertain = (error as NSError).domain == NSURLErrorDomain
                        || ReversibleWalStore.shared.hasUncertain(taskId: runId)
                    if isUncertain {
                        journal.markUncertain(rowId: row.id, error: errStr)
                        stopRequested = true
                        stoppedEarly = true
                        run.message = "云盘操作结果待核实，已停止避免重复写入"
                        recordOutcome(actionId: act.id, ok: false, err: errStr)
                        return
                    }
                    journal.markSkipped(rowId: row.id, error: errStr)

                    // 可挂起冲突：挂起本项及所有下游依赖项，继续处理其它独立作品
                    if ConflictPolicy.isDeferrableConflict(error.localizedDescription) {
                        deferredConflicts.insert(act.id)
                        let deps = ConflictPolicy.dependentActionIds(conflictAction: act, allActions: Array(planActions.values))
                        for depId in deps where deferredByDep[depId] == nil {
                            deferredByDep[depId] = "前置冲突已挂起（\(Self.labelOf(act))）：\(error.localizedDescription)"
                        }
                        run.message = "冲突已挂起（\(deferredConflicts.count) 项），继续处理其他独立项…"
                        recordOutcome(actionId: act.id, ok: false, err: errStr)
                        return
                    }

                    streak += 1
                    recordOutcome(actionId: act.id, ok: false, err: errStr)
                    if streak >= Self.maxConsecutiveFails && !stopRequested {
                        stoppedOnFails = true
                        isPaused = true
                        run.status = "paused"
                        run.message = "连续失败 \(Self.maxConsecutiveFails) 次，已自动暂停"
                        currentRun = run
                    }
                }
            }

            // MARK: 主游标状态机循环
            var cursor = 0
            while cursor < ordered.count {
                if let ctrl = TaskCancellation.shared.controls[runId], ctrl.state != "completed" {
                    stopRequested = true
                }
                if stopRequested || Task.isCancelled { stoppedEarly = true; break }
                if !(await waitIfPaused()) { break }

                let id = ordered[cursor]
                if batchConsumed.contains(id) { cursor += 1; continue }
                let action = planActions[id]

                // 上传阶段前统一等待一次网盘后台落盘
                if action?.op == "artwork" && !settled {
                    settled = true
                    if !skipDelaysForTest {
                        run.message = "等待网盘处理改名 / 新建文件夹…"
                        currentRun = run
                        try? await Task.sleep(nanoseconds: Self.settleDelayNs)
                    }
                }

                // 稳定 ID 云盘（123 / 光鸭）：连续 2..100 条同目标 move 打包为一次 moveBatch
                if let action, action.op == "move",
                   !Self.sequentialMoveKinds.contains(action.kind),
                   !action.done, action.enabled, deferredByDep[id] == nil,
                   !drive.kind.idsArePaths,
                   let rawFirstDest = Self.resolveDest(action: action, refs: mkdirRefs) {
                    let firstDest = idRemap.resolveOrSelf(rawFirstDest)
                    var batch: [PlanAction] = [action]
                    var look = cursor + 1
                    while look < ordered.count && batch.count < 100 {
                        let nextId = ordered[look]
                        guard let next = planActions[nextId],
                              next.op == "move",
                              !Self.sequentialMoveKinds.contains(next.kind),
                              !next.done, next.enabled,
                              deferredByDep[nextId] == nil,
                              !batchConsumed.contains(nextId),
                              let rawNextDest = Self.resolveDest(action: next, refs: mkdirRefs),
                              idRemap.resolveOrSelf(rawNextDest) == firstDest else { break }
                        batch.append(next)
                        look += 1
                    }

                    if batch.count >= 2 {
                        for b in batch where b.id != id { batchConsumed.insert(b.id) }
                        run.message = "批量移动 \(batch.count) 项 → \(action.destLabel ?? firstDest)"
                        currentRun = run

                        let rows = batch.map { b in
                            journal.prepare(
                                runId: runId, actionId: b.id, op: "move", kind: b.kind,
                                fileId: b.fileId.map { idRemap.resolveOrSelf($0) },
                                parentId: b.parentId.map { idRemap.resolveOrSelf($0) },
                                destParentId: firstDest, oldName: b.oldName, newName: b.newName
                            )
                        }
                        do {
                            var batchItems: [BatchMoveItem] = []
                            for b in batch {
                                guard let fid = b.fileId else { throw DriveError.invalidInput("缺少 fileId") }
                                let resolvedFid = idRemap.resolveOrSelf(fid)
                                let resolvedParent: String
                                if let rawParent = b.parentId {
                                    resolvedParent = idRemap.resolveOrSelf(rawParent)
                                } else if drive.kind.idsArePaths {
                                    resolvedParent = DrivePaths.parentOf(resolvedFid)
                                } else if let p = try await drive.parentIdOf(fileId: resolvedFid) {
                                    resolvedParent = p
                                } else {
                                    throw DriveError.invalidInput("缺少原父目录，无法记录批量移动操作")
                                }
                                batchItems.append(BatchMoveItem(action: b.id, id: resolvedFid, parent: resolvedParent))
                            }
                            let movedByAction = try await gate.withPermit(skipBackoff: skipDelaysForTest) {
                                try await tx.moveBatch(items: batchItems, dest: firstDest)
                            }
                            await gate.onSuccess()
                            for (idx, b) in batch.enumerated() {
                                let fid = batchItems[idx].id
                                let newId = movedByAction[b.id] ?? fid
                                idRemap.record(old: fid, new: newId)
                                if let orig = b.fileId { idRemap.record(old: orig, new: newId) }
                                journal.markApplied(rowId: rows[idx].id, createdId: newId)
                                recordOutcome(actionId: b.id, ok: true, err: nil)
                            }
                            cursor = look
                            continue
                        } catch {
                            if RateLimitDetector.isRateLimitError(error) {
                                _ = await gate.onRateLimited(backoffMs: skipDelaysForTest ? 0 : 1500)
                            }
                            let isUncertain = (error as NSError).domain == NSURLErrorDomain
                                || ReversibleWalStore.shared.hasUncertain(taskId: runId)
                            if isUncertain {
                                for r in rows { journal.markUncertain(rowId: r.id, error: error.localizedDescription) }
                                for b in batch { recordOutcome(actionId: b.id, ok: false, err: error.localizedDescription) }
                                stopRequested = true
                                stoppedEarly = true
                                run.message = "批量移动结果待核实，已停止避免重复写入"
                                break
                            } else {
                                // 无不确定 WAL 行：退回逐条执行精确定位失败项
                                for r in rows { journal.markSkipped(rowId: r.id, error: "批量移动回退逐条执行") }
                                for b in batch where b.id != id { batchConsumed.remove(b.id) }
                                await runSingleAction(id)
                                cursor += 1
                                continue
                            }
                        }
                    }
                }

                // 同阶段无冲突波次：首项探针串行 + 其余按 gate.currentLimit 并发执行
                if Self.canRunConcurrently(action), let waveOp = action?.op {
                    var waveIds: [String] = []
                    var seenFileIds = Set<String>()
                    var look = cursor
                    while look < ordered.count {
                        let wid = ordered[look]
                        if batchConsumed.contains(wid) { look += 1; continue }
                        guard let wa = planActions[wid], wa.op == waveOp, Self.canRunConcurrently(wa) else { break }
                        // 稳定 ID 云盘上若遇到连续 2+ 同目标 move，交回外层 moveBatch 打包
                        if waveOp == "move" && !drive.kind.idsArePaths && !waveIds.isEmpty,
                           let d0 = Self.resolveDest(action: wa, refs: mkdirRefs).map({ idRemap.resolveOrSelf($0) }),
                           look + 1 < ordered.count,
                           let nextAct = planActions[ordered[look + 1]],
                           nextAct.op == "move", Self.canRunConcurrently(nextAct),
                           let d1 = Self.resolveDest(action: nextAct, refs: mkdirRefs).map({ idRemap.resolveOrSelf($0) }),
                           d0 == d1 {
                            break
                        }
                        if let fid = wa.fileId, !fid.isEmpty, !seenFileIds.insert(fid).inserted { break }
                        waveIds.append(wid)
                        look += 1
                    }

                    if waveIds.count >= 2 {
                        // 首项探针：先串行执行第 1 项
                        await runSingleAction(waveIds[0])
                        var processed = 1
                        let rest = Array(waveIds.dropFirst())
                        if !stopRequested && !Task.isCancelled && !rest.isEmpty {
                            if await waitIfPaused() {
                                var idx = 0
                                while idx < rest.count {
                                    if stopRequested || Task.isCancelled { stoppedEarly = true; break }
                                    if isPaused, !(await waitIfPaused()) { break }
                                    let width = max(1, await gate.currentLimit)
                                    let end = min(idx + width, rest.count)
                                    let slice = Array(rest[idx..<end])
                                    // 仅将纯云端 IO 放入 TaskGroup 并发执行，所有状态/日志记账集中回到 @MainActor 避免捕获可变局部变量
                                    var prepared: [(act: PlanAction, row: JournalRow)] = []
                                    for wid in slice {
                                        guard let act = planActions[wid] else {
                                            recordOutcome(actionId: wid, ok: false, noopNote: "", err: nil)
                                            continue
                                        }
                                        if act.done || !act.enabled || !Self.execOps.contains(act.op) {
                                            recordOutcome(actionId: wid, ok: false, noopNote: "", err: nil)
                                            continue
                                        }
                                        if let depReason = deferredByDep[wid] {
                                            recordOutcome(actionId: wid, ok: false, err: depReason)
                                            continue
                                        }
                                        let dest = Self.resolveDest(action: act, refs: mkdirRefs).map { idRemap.resolveOrSelf($0) }
                                        let row = journal.prepare(
                                            runId: runId, actionId: act.id, op: act.op, kind: act.kind,
                                            fileId: act.fileId.map { idRemap.resolveOrSelf($0) },
                                            parentId: act.parentId.map { idRemap.resolveOrSelf($0) },
                                            destParentId: dest, oldName: act.oldName, newName: act.newName
                                        )
                                        prepared.append((act, row))
                                    }
                                    let refsSnapshot = mkdirRefs
                                    let results = await withTaskGroup(of: (PlanAction, JournalRow, Result<(String?, String?), Error>).self) { tg in
                                        for item in prepared {
                                            let act = item.act
                                            let row = item.row
                                            tg.addTask {
                                                do {
                                                    let res = try await gate.withPermit(skipBackoff: skipDelaysForTest) {
                                                        try await Self.executeWaveIo(
                                                            act: act, drive: drive, tx: tx,
                                                            idRemap: idRemap, mkdirRefs: refsSnapshot,
                                                            planGroups: planGroups
                                                        )
                                                    }
                                                    return (act, row, .success(res))
                                                } catch {
                                                    return (act, row, .failure(error))
                                                }
                                            }
                                        }
                                        var collected: [(PlanAction, JournalRow, Result<(String?, String?), Error>)] = []
                                        for await r in tg { collected.append(r) }
                                        return collected
                                    }
                                    for (act, row, res) in results {
                                        switch res {
                                        case .success(let pair):
                                            await gate.onSuccess()
                                            let existed = pair.1 == "已存在"
                                            if existed {
                                                journal.markSkipped(rowId: row.id, error: "已存在")
                                            } else {
                                                journal.markApplied(rowId: row.id, createdId: pair.0)
                                            }
                                            recordOutcome(actionId: act.id, ok: !existed, skipped: existed, err: nil)
                                        case .failure(let error):
                                            if error is ArtworkUnavailableError {
                                                await gate.onSuccess()
                                                journal.markSkipped(rowId: row.id, error: error.localizedDescription)
                                                recordOutcome(actionId: act.id, ok: false, noopNote: error.localizedDescription, markDone: true, err: nil)
                                                continue
                                            }
                                            if RateLimitDetector.isRateLimitError(error) {
                                                _ = await gate.onRateLimited(backoffMs: skipDelaysForTest ? 0 : 1500)
                                            }
                                            let errStr = "\(Self.labelOf(act))：\(error.localizedDescription)"
                                            let actWalState = ReversibleWalStore.shared.find(taskId: runId, actionId: act.id)?.state
                                            let isUncertain = (error as NSError).domain == NSURLErrorDomain
                                                || actWalState == "prepared" || actWalState == "uncertain" || actWalState == "undo_prepared" 
                                            if isUncertain {
                                                journal.markUncertain(rowId: row.id, error: errStr)
                                                stopRequested = true
                                                stoppedEarly = true
                                                recordOutcome(actionId: act.id, ok: false, err: errStr)
                                            } else {
                                                journal.markSkipped(rowId: row.id, error: errStr)
                                                if ConflictPolicy.isDeferrableConflict(error.localizedDescription) {
                                                    deferredConflicts.insert(act.id)
                                                    let deps = ConflictPolicy.dependentActionIds(conflictAction: act, allActions: Array(planActions.values))
                                                    for depId in deps where deferredByDep[depId] == nil {
                                                        deferredByDep[depId] = "前置冲突已挂起（\(Self.labelOf(act))）：\(error.localizedDescription)"
                                                    }
                                                    recordOutcome(actionId: act.id, ok: false, err: errStr)
                                                } else {
                                                    streak += 1
                                                    recordOutcome(actionId: act.id, ok: false, err: errStr)
                                                    if streak >= Self.maxConsecutiveFails && !stopRequested {
                                                        stoppedOnFails = true
                                                        isPaused = true
                                                        run.status = "paused"
                                                        run.message = "连续失败 \(Self.maxConsecutiveFails) 次，已自动暂停"
                                                        currentRun = run
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    processed += slice.count
                                    idx = end
                                }
                            }
                        }
                        cursor = stopRequested ? (cursor + processed) : look
                        continue
                    }
                }

                // 串行项（目录改名、mkdir、清理/目标库移动、delete、单个项）
                await runSingleAction(id)
                cursor += 1
            }

            lastPeakConcurrency = await gate.peakActive
            lastConcurrencyLimit = await gate.currentLimit

            let pausedForConflicts = !stoppedEarly && !stopRequested && !Task.isCancelled && !deferredConflicts.isEmpty
            if pausedForConflicts {
                run.status = "paused"
                run.finishedAt = nil
                let depPart = deferredByDep.isEmpty ? "" : "（连带 \(deferredByDep.count) 项）"
                run.message = "独立项已完成（成功 \(run.succeeded)），另有 \(deferredConflicts.count) 项冲突已挂起\(depPart)，请在失败明细中修正或跳过后继续"
            } else if stopRequested || Task.isCancelled {
                run.status = "stopped"
                run.finishedAt = Date()
                run.message = "已停止（成功 \(run.succeeded) · 失败 \(run.failed)）"
            } else {
                run.status = run.failed == 0 ? "done" : "failed"
                run.finishedAt = Date()
                let extra = stoppedOnFails ? "（曾因连续失败暂停）" : ""
                run.message = "完成：成功 \(run.succeeded) 项，失败 \(run.failed) 项\(extra)"
            }

            currentRun = run
            PlanAndTaskStore.shared.savePlan(updatedPlan)
            _ = try? PlanStore.shared.save(updatedPlan)
            PlanAndTaskStore.shared.saveTask(run)

            if AppSettings.shared.rememberHistory && !newlyOkIds.isEmpty {
                let newlyOkSet = Set(newlyOkIds)
                let actionMap = Dictionary(updatedPlan.actions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                let fullyDoneGroups = updatedPlan.groups.filter { g in
                    let gActs = g.actionIds.compactMap { actionMap[$0] }.filter { Self.execOps.contains($0.op) && $0.enabled && $0.blocked == nil }
                    return !gActs.isEmpty && gActs.allSatisfy(\.done) && gActs.contains(where: { newlyOkSet.contains($0.id) })
                }
                let doneFolders = fullyDoneGroups.compactMap { $0.folderId.map { idRemap.resolveOrSelf($0) } }
                if !doneFolders.isEmpty {
                    PlanAndTaskStore.shared.markFoldersOrganized(accountId: plan.accountId, folderIds: doneFolders)
                }
                _ = HistoryStore.shared.recordRun(
                    plan: updatedPlan,
                    actions: actionMap,
                    okIds: newlyOkIds,
                    idRemap: idRemap.snapshot(),
                    pathIds: drive.kind.idsArePaths
                )
                for g in fullyDoneGroups {
                    guard let rawFid = g.folderId, !rawFid.isEmpty else { continue }
                    let mappedFid = idRemap.resolveOrSelf(rawFid)
                    HistoryStore.shared.record(
                        accountId: plan.accountId,
                        provider: plan.provider,
                        folderId: mappedFid,
                        folderName: g.folderNewName ?? g.folderName,
                        matchedTitle: g.title.isEmpty ? g.folderName : g.title,
                        actionCount: g.actionIds.count
                    )
                }
            }

            activeTask = nil
            isRunning = false
            if !pausedForConflicts { isPaused = false }
            BackgroundTaskManager.shared.end()

            // 自动拉起排队中的下一个可执行任务（先 peek 校验，跳过无效项后再 pop 启动，杜绝误丢队首或阻断后续队列）
            if !Task.isCancelled && !stopRequested && !pausedForConflicts, let resolver = driveResolver {
                while let candidate = TaskQueue.shared.peekNext() {
                    guard let nextPlan = PlanAndTaskStore.shared.plans.first(where: { $0.id == candidate.planId }),
                          let nextDrive = resolver(candidate.accountId) else {
                        TaskQueue.shared.remove(id: candidate.id)
                        continue
                    }
                    _ = TaskQueue.shared.popNext()
                    start(plan: nextPlan, drive: nextDrive, actionIds: candidate.actionIds)
                    break
                }
            }
        }
    }

    /// 纯云端并发 IO 辅助（nonisolated，全程经由 ReversibleTransaction 落盘 WAL 与覆盖前备份）。
    nonisolated private static func executeWaveIo(
        act: PlanAction,
        drive: any CloudDrive,
        tx: ReversibleTransaction,
        idRemap: IdRemap,
        mkdirRefs: [String: String],
        planGroups: [String: PlanGroup]
    ) async throws -> (String?, String?) {
        switch act.op {
        case "rename":
            guard let rawFid = act.fileId else { throw DriveError.invalidInput("缺少 fileId") }
            let fid = idRemap.resolveOrSelf(rawFid)
            let resolvedParent: String?
            if let rawParent = act.parentId {
                resolvedParent = idRemap.resolveOrSelf(rawParent)
            } else if drive.kind.idsArePaths {
                resolvedParent = DrivePaths.parentOf(fid)
            } else {
                resolvedParent = try await drive.parentIdOf(fileId: fid)
            }
            guard let safeParent = resolvedParent else {
                throw DriveError.invalidInput("缺少原父目录，无法记录可撤销重命名操作")
            }
            let newId = try await tx.rename(action: act.id, id: fid, parent: safeParent, name: act.newName)
            idRemap.record(old: fid, new: newId)
            idRemap.record(old: rawFid, new: newId)
            return (newId, nil)
        case "move":
            guard let rawFid = act.fileId else { throw DriveError.invalidInput("缺少 fileId") }
            let fid = idRemap.resolveOrSelf(rawFid)
            guard let rawDest = Self.resolveDest(action: act, refs: mkdirRefs) else {
                throw DriveError.invalidInput("目标文件夹还没建好")
            }
            let dest = idRemap.resolveOrSelf(rawDest)
            let resolvedMoveParent: String?
            if let rawParent = act.parentId {
                resolvedMoveParent = idRemap.resolveOrSelf(rawParent)
            } else if drive.kind.idsArePaths {
                resolvedMoveParent = DrivePaths.parentOf(fid)
            } else {
                resolvedMoveParent = try await drive.parentIdOf(fileId: fid)
            }
            guard let safeParent = resolvedMoveParent else {
                throw DriveError.invalidInput("缺少原父目录，无法记录可撤销移动操作")
            }
            let newId = try await tx.move(action: act.id, id: fid, parent: safeParent, dest: dest)
            idRemap.record(old: fid, new: newId)
            idRemap.record(old: rawFid, new: newId)
            return (newId, nil)
        case "artwork":
            let rawDest: String?
            if let ref = act.destRef {
                rawDest = mkdirRefs["action:\(ref)"] ?? mkdirRefs[ref]
            } else {
                rawDest = act.destParentId ?? act.parentId
            }
            guard let rawDest else {
                throw DriveError.invalidInput("目标文件夹 \(act.destLabel ?? "") 还没建好")
            }
            let dest = idRemap.resolveOrSelf(rawDest)
            let grp = planGroups[act.groupId]
            let kind = act.mediaKind ?? (grp?.kind == "tv" || grp?.kind == "movie" ? grp?.kind : nil) ?? "tv"
            let title = grp?.kind == "collection" ? (act.destLabel ?? "电影") : ((grp?.title.isEmpty == false ? grp?.title : nil) ?? "影视作品")
            let root = grp?.kind == "collection" ? dest : (grp?.folderId.map { idRemap.resolveOrSelf($0) } ?? dest)
            let yrPart = (grp?.year.isEmpty == false) ? " (\(grp!.year))" : ""
            let tid = act.tmdbId ?? grp?.tmdbId
            let scope = AssetBackupScope(
                rootId: root,
                workKey: tid.map { "\(kind):\($0)" } ?? "\(kind):\(act.groupId)",
                workLabel: "\(String(title.prefix(48)))\(yrPart) [\(kind)-tmdb-\(tid ?? 0)]",
                locationLabel: dest == root ? "根目录" : (act.destLabel ?? (act.season.map { String(format: "Season %02d", $0) } ?? "子目录-\(String(dest.suffix(8)))"))
            )
            let created = try await tx.upload(
                action: act.id,
                parent: dest,
                name: act.newName,
                replaceExisting: act.replaceExisting,
                backupScope: scope
            ) {
                try await ArtworkFetcher.shared.contentFor(action: act)
            }
            return (nil, created ? nil : "已存在")
        default:
            return (nil, "跳过")
        }
    }
}
