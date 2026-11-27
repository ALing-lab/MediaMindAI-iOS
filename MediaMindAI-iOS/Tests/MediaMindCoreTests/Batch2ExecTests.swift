import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 第 2 批（data/exec/ 1:1 逐行直译）独立单元测试套件：
/// 覆盖 NfoXml、ImageBytes、JournalReconciler（正向与 undo_prepared 逆向核实）与 TaskCancellation。
final class Batch2ExecTests: XCTestCase {

    private func historyRun(_ id: String, date: TimeInterval, parent: String? = nil, root: String? = nil,
                            account: String = "history-account", plan: String = "history-plan", status: String = "failed") -> TaskRun {
        var run = TaskRun(id: id, planId: plan, accountId: account, provider: "webdav", sourceLabel: "same source",
            status: status, total: 2, completed: 2, succeeded: 1, failed: 1, message: "", startedAt: Date(timeIntervalSince1970: date), finishedAt: nil, errors: [])
        run.retryOfRunId = parent; run.retryRootRunId = root
        return run
    }

    func testRetryLineageUsesLatestRepresentativeWithoutMergingUnrelatedRuns() {
        let first = historyRun("first", date: 1)
        let retry = historyRun("retry", date: 2, parent: first.id, root: first.id, status: "running")
        let latest = historyRun("latest", date: 3, parent: retry.id, root: first.id, status: "done")
        let unrelated = historyRun("unrelated", date: 4)
        let runs = [first, retry, latest, unrelated]
        XCTAssertEqual(TaskRunHistory.representatives(in: runs).map(\.id), ["unrelated", "latest"])
        XCTAssertEqual(TaskRunHistory.attempts(for: latest, in: runs).map(\.id), ["latest", "retry", "first"])
        XCTAssertEqual(runs.count, 4)
        XCTAssertEqual(TaskRunHistory.representatives(in: runs).last?.succeeded, latest.succeeded)
    }

    func testRetryLineageIsScopedByAccountAndPlanAndSurvivesMissingParent() {
        let first = historyRun("first", date: 1)
        let retry = historyRun("retry", date: 2, parent: first.id, root: first.id)
        let latest = historyRun("latest", date: 3, parent: retry.id, root: first.id)
        let otherAccount = historyRun("account", date: 4, parent: first.id, root: first.id, account: "other")
        let otherPlan = historyRun("plan", date: 5, parent: first.id, root: first.id, plan: "other")
        XCTAssertEqual(TaskRunHistory.representatives(in: [retry, latest, otherAccount, otherPlan]).count, 3)
        XCTAssertEqual(TaskRunHistory.attempts(for: latest, in: [retry, latest, otherAccount, otherPlan]).map(\.id), ["latest", "retry"])
        let linkedWithoutRoot = historyRun("linked", date: 6, parent: first.id)
        XCTAssertEqual(TaskRunHistory.rootId(of: linkedWithoutRoot, in: [first, linkedWithoutRoot]), first.id)
    }

    func testOldRunAndQueueDecodeWithoutRetryMetadata() throws {
        let data = try JSONEncoder().encode(historyRun("legacy", date: 1))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "retryOfRunId"); object.removeValue(forKey: "retryRootRunId")
        let decoded = try JSONDecoder().decode(TaskRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.retryOfRunId); XCTAssertNil(decoded.retryRootRunId)
        let item = QueuedTaskItem(planId: "plan", accountId: "account", provider: "webdav", sourceLabel: "", actionCount: 1)
        let decodedItem = try JSONDecoder().decode(QueuedTaskItem.self, from: JSONEncoder().encode(item))
        XCTAssertNil(decodedItem.retryOfRunId); XCTAssertNil(decodedItem.retryRootRunId)
    }

    func testQueuedRetrySuppressesOnlyItsHistoryAndSurvivesMissingParent() {
        let root = historyRun("root", date: 1)
        let retry = historyRun("retry", date: 2, parent: root.id, root: root.id)
        let unrelated = historyRun("unrelated", date: 3)
        let otherAccount = historyRun("other", date: 4, parent: root.id, root: root.id, account: "different")
        let item = QueuedTaskItem(planId: root.planId, accountId: root.accountId, provider: root.provider, sourceLabel: "", actionCount: 1,
            retryOfRunId: retry.id, retryRootRunId: root.id)
        XCTAssertTrue(item.isRetry(of: retry, in: [retry]))
        XCTAssertTrue(item.isRetry(of: root, in: [root]))
        XCTAssertFalse(item.isRetry(of: unrelated, in: [root, retry, unrelated]))
        XCTAssertFalse(item.isRetry(of: otherAccount, in: [root, retry, otherAccount]))
        let visible = TaskRunHistory.representatives(in: [root, retry, unrelated]).filter { !item.isRetry(of: $0, in: [root, retry, unrelated]) }
        XCTAssertEqual(visible.map(\.id), [unrelated.id])
        XCTAssertEqual(TaskRunHistory.representatives(in: [root, unrelated]).map(\.id), [unrelated.id, root.id], "删除最新一次后较早尝试应仍保留")
    }

    @MainActor
    func testRetryQueuePersistsScopeAndLineageAndStoreRetainsAllAttempts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let action = PlanAction(id: "action", op: "rename", groupId: "group", fileId: "video", parentId: "source",
            oldName: "old.mkv", newName: "new.mkv", destParentId: nil, destRef: nil, kind: "file", mediaKind: "movie", tmdbId: 1,
            season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let plan = ScrapePlan(id: "plan", accountId: "account", provider: "webdav", createdAt: Date(), roots: [], groups: [], actions: [action], flags: [])
        let url = dir.appendingPathComponent("queue.json")
        let queue = TaskQueue(storageURL: url)
        let item = queue.enqueue(plan: plan, actionIds: [action.id], retryOfRunId: "previous", retryRootRunId: "root")
        let restored = try XCTUnwrap(TaskQueue(storageURL: url).peekNext())
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.actionIds, [action.id])
        XCTAssertEqual(restored.retryOfRunId, "previous"); XCTAssertEqual(restored.retryRootRunId, "root")
        let store = PlanAndTaskStore(storageURL: dir.appendingPathComponent("store"))
        for index in 0..<55 { store.saveTask(historyRun("attempt-\(index)", date: Double(index), parent: index == 0 ? nil : "attempt-\(index - 1)", root: index == 0 ? nil : "attempt-0")) }
        let reloaded = PlanAndTaskStore(storageURL: dir.appendingPathComponent("store"))
        XCTAssertEqual(reloaded.tasks.count, 55)
        XCTAssertEqual(TaskRunHistory.representatives(in: reloaded.tasks).map(\.id), ["attempt-54"])
    }

    private final class MockExecDrive: CloudDrive, @unchecked Sendable {
        let kind: ProviderKind = .webdav
        let accountId: String = "acc-exec"
        let rootId: String = "/"
        var listings: [String: [CloudEntry]] = [:]
        var renamed: [(String, String)] = []

        func list(folderId: String) async throws -> [CloudEntry] { listings[folderId] ?? [] }
        func rename(fileId: String, newName: String) async throws -> String {
            renamed.append((fileId, newName))
            return DrivePaths.join(parent: DrivePaths.parentOf(fileId), name: newName)
        }
        func mkdir(parentId: String, name: String) async throws -> String { DrivePaths.join(parent: parentId, name: name) }
        func move(fileId: String, destParentId: String) async throws -> String { fileId }
        func upload(parentId: String, name: String, data: Data) async throws -> String { DrivePaths.join(parent: parentId, name: name) }
        func trash(fileId: String) async throws -> String { fileId }
    }

    @MainActor
    func testRetryStartKeepsIndependentRunAndClosesOnlyItsPausedLineage() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning else { throw XCTSkip("另一执行测试仍在运行") }
        let store = PlanAndTaskStore.shared
        for retryFromAncestor in [false, true] {
        let planId = "retry-lineage-\(UUID().uuidString)"
        let action = PlanAction(id: "retry-action", op: "rename", groupId: "group", fileId: "/source/old.mkv", parentId: "/source",
            oldName: "old.mkv", newName: "new.mkv", destParentId: nil, destRef: nil, kind: "file", mediaKind: "movie", tmdbId: 1,
            season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let plan = ScrapePlan(id: planId, accountId: "acc-exec", provider: "webdav", createdAt: Date(), roots: [], groups: [], actions: [action], flags: [])
        var parent = historyRun("parent-\(UUID().uuidString)", date: 1, account: plan.accountId, plan: planId, status: retryFromAncestor ? "failed" : "paused")
        parent.executionSnapshot = plan.executionSnapshot(actionIds: [action.id])
        store.savePlan(plan); store.saveTask(parent)
        var pausedDescendant: TaskRun?
        if retryFromAncestor {
            var descendant = historyRun("descendant-\(UUID().uuidString)", date: 2, parent: parent.id, root: parent.id,
                account: plan.accountId, plan: planId, status: "paused")
            descendant.executionSnapshot = parent.executionSnapshot
            pausedDescendant = descendant; store.saveTask(descendant)
        }
        let unrelated = historyRun("independent-\(UUID().uuidString)", date: 3, account: plan.accountId, plan: planId, status: "paused")
        store.saveTask(unrelated)
        defer {
            for item in TaskQueue.shared.items where item.planId == planId { TaskQueue.shared.remove(id: item.id) }
            for run in store.tasks where run.planId == planId { store.deleteTask(id: run.id, allowPaused: true) }
            store.deletePlan(id: planId)
        }
        guard engine.start(plan: plan, drive: MockExecDrive(), actionIds: [action.id], skipDelaysForTest: true, retryOfRunId: parent.id) else {
            XCTFail("有效重试应能创建独立尝试"); return
        }
        let child = engine.currentRun
        XCTAssertNotEqual(child?.id, parent.id)
        XCTAssertEqual(child?.retryOfRunId, parent.id)
        XCTAssertEqual(child?.retryRootRunId, parent.id)
        XCTAssertEqual(store.tasks.first { $0.id == parent.id }?.status, retryFromAncestor ? "failed" : "stopped")
        if let descendant = pausedDescendant { XCTAssertEqual(store.tasks.first { $0.id == descendant.id }?.status, "stopped") }
        XCTAssertEqual(store.tasks.first { $0.id == unrelated.id }?.status, "paused")
        XCTAssertEqual(store.tasks.first { $0.id == parent.id }?.executionSnapshot?.actions.map(\.id), [action.id])
        XCTAssertEqual(TaskRunHistory.representatives(in: store.tasks.filter { $0.planId == planId }).map(\.id), child.map { [$0.id, unrelated.id] } ?? [])
        XCTAssertFalse(engine.enqueueOrStart(plan: plan, drive: MockExecDrive(), actionIds: [action.id], retryOfRunId: parent.id), "运行中的同链不能给自己排重试")
        XCTAssertTrue(engine.enqueueOrStart(plan: plan, drive: MockExecDrive(), actionIds: [action.id], retryOfRunId: unrelated.id))
        XCTAssertFalse(engine.enqueueOrStart(plan: plan, drive: MockExecDrive(), actionIds: [action.id], retryOfRunId: unrelated.id), "同一链只能排一个重试")
        XCTAssertTrue(engine.lastStartError?.contains("已有排队") == true)
        for item in TaskQueue.shared.items where item.planId == planId { TaskQueue.shared.remove(id: item.id) }
        await engine.stopAndWait()
        XCTAssertEqual(store.tasks.filter { $0.planId == planId }.count, retryFromAncestor ? 4 : 3)
        }
    }

    @MainActor
    func testRetryBlockedBeforeCreatingAttemptOrClosingPausedHistory() throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning else { throw XCTSkip("另一执行测试仍在运行") }
        let store = PlanAndTaskStore.shared
        let planId = "blocked-retry-\(UUID().uuidString)"
        let action = PlanAction(id: "retry-action", op: "rename", groupId: "group", fileId: "/old.mkv", parentId: "/",
            oldName: "old.mkv", newName: "new.mkv", destParentId: nil, destRef: nil, kind: "file", mediaKind: "movie", tmdbId: 1,
            season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let plan = ScrapePlan(id: planId, accountId: "acc-exec", provider: "webdav", createdAt: Date(), roots: [], groups: [], actions: [action], flags: [])
        let parent = historyRun("paused-\(UUID().uuidString)", date: 1, account: plan.accountId, plan: planId, status: "paused")
        store.savePlan(plan); store.saveTask(parent)
        let otherTask = "uncertain-\(UUID().uuidString)"
        let row = try ReversibleWalStore.shared.prepare(taskId: otherTask, accountId: plan.accountId, actionId: "unknown", operation: "rename", before: nil, after: nil)
        try ReversibleWalStore.shared.change(row, state: "uncertain")
        defer {
            ReversibleWalStore.shared.clear(taskId: otherTask)
            store.deleteTask(id: parent.id, allowPaused: true); store.deletePlan(id: planId)
        }
        let beforeTasks = Set(store.tasks.map(\.id))
        XCTAssertFalse(engine.start(plan: plan, drive: MockExecDrive(), actionIds: [action.id], retryOfRunId: parent.id))
        XCTAssertEqual(Set(store.tasks.map(\.id)), beforeTasks)
        XCTAssertEqual(store.tasks.first { $0.id == parent.id }?.status, "paused")
        XCTAssertNil(store.plans.first { $0.id == planId }?.submittedActionIds)
        XCTAssertTrue(engine.lastStartError?.contains("待核实") == true)
        ReversibleWalStore.shared.clear(taskId: otherTask)
        let queued = TaskQueue.shared.enqueue(plan: plan, actionIds: [action.id], retryOfRunId: parent.id, retryRootRunId: parent.id)
        defer { TaskQueue.shared.remove(id: queued.id) }
        XCTAssertFalse(engine.enqueueOrStart(plan: plan, drive: MockExecDrive(), actionIds: [action.id], retryOfRunId: parent.id), "空闲时也不能绕过已存在的同链队列")
        XCTAssertTrue(engine.lastStartError?.contains("已有排队") == true)
        XCTAssertTrue(TaskQueue.shared.items.contains { $0.id == queued.id })
        XCTAssertEqual(Set(store.tasks.map(\.id)), beforeTasks)
    }

    private actor RecoveryGate {
        private var open = false
        private var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        var isEntered: Bool { entered }
        func wait() async {
            guard !open else { return }
            entered = true
            await withCheckedContinuation { waiter = $0 }
        }
        func release() {
            open = true
            waiter?.resume(); waiter = nil
        }
    }

    private final class RecoveryDrive: CloudDrive, @unchecked Sendable {
        enum RenameFault { case rejectOnce, landThenTimeout, alwaysReject, ambiguousDestination }
        struct Node {
            var id: String
            var parent: String
            var name: String
            var directory: Bool = false
            var size: Int64 = 100
            var etag: String { "\"etag-\(id)\"" }
        }
        let kind: ProviderKind = .guangya
        let accountId = "recovery-\(UUID().uuidString)"
        let rootId = "0"
        private let lock = NSLock()
        private var nodes: [String: Node] = [:]
        private let faults: [String: RenameFault]
        private let partialBatch: Bool
        private let directoryRenameTimeout: Bool
        private let verificationGate: RecoveryGate?
        private let blockVerificationRead: Int
        private let heldRenameFile: String?
        private let renameGate: RecoveryGate?
        private let pendingBatch: Bool
        private var renameCalls: [String: Int] = [:]
        private var moveCalls: [String: Int] = [:]
        private var batchCalls = 0
        private var faultHasOccurred = false
        private var readsAfterFault = 0

        init(count: Int, faults: [String: RenameFault] = [:], partialBatch: Bool = false, directoryRenameTimeout: Bool = false,
             verificationGate: RecoveryGate? = nil, blockVerificationRead: Int = 1,
             heldRenameFile: String? = nil, renameGate: RecoveryGate? = nil, pendingBatch: Bool = false) {
            self.faults = faults; self.partialBatch = partialBatch; self.directoryRenameTimeout = directoryRenameTimeout
            self.verificationGate = verificationGate; self.blockVerificationRead = blockVerificationRead
            self.heldRenameFile = heldRenameFile; self.renameGate = renameGate; self.pendingBatch = pendingBatch
            for index in 1...count {
                let id = "file-\(index)"
                nodes[id] = Node(id: id, parent: "source", name: "old-\(index).mkv")
            }
        }
        func renameCount(_ id: String) -> Int { lock.withLock { renameCalls[id] ?? 0 } }
        func moveCount(_ id: String) -> Int { lock.withLock { moveCalls[id] ?? 0 } }
        var batchCount: Int { lock.withLock { batchCalls } }
        var directoryIds: [String] { lock.withLock { nodes.values.filter(\.directory).map(\.id) } }
        var verificationReads: Int { lock.withLock { readsAfterFault } }
        func node(_ id: String) -> Node? { lock.withLock { nodes[id] } }

        func list(folderId: String) async throws -> [CloudEntry] {
            let shouldHold = lock.withLock {
                guard faultHasOccurred else { return false }
                readsAfterFault += 1
                return readsAfterFault == blockVerificationRead
            }
            if shouldHold, let verificationGate { await verificationGate.wait() }
            return lock.withLock {
                nodes.values.filter { $0.parent == folderId }.sorted { $0.id < $1.id }.map {
                    CloudEntry(fileId: $0.id, fileName: $0.name, isDir: $0.directory, size: $0.size,
                               parentFileId: $0.parent, etag: $0.etag)
                }
            }
        }
        func rename(fileId: String, newName: String) async throws -> String {
            if fileId == heldRenameFile, let renameGate { await renameGate.wait() }
            return try lock.withLock {
                guard var node = nodes[fileId] else { throw DriveError.invalidInput("missing test source") }
                renameCalls[fileId, default: 0] += 1
                let attempt = renameCalls[fileId] ?? 0
                if directoryRenameTimeout && node.directory && attempt == 1 {
                    node.name = newName; nodes[fileId] = node; faultHasOccurred = true
                    throw DriveError.network("response lost after finalizing a private directory")
                }
                if let fault = faults[fileId] {
                    switch fault {
                    case .rejectOnce:
                        if attempt == 1 {
                            faultHasOccurred = true
                            throw DriveError.api(code: 127, message: "操作过于频繁，请稍后重试")
                        }
                    case .alwaysReject:
                        faultHasOccurred = true
                        throw DriveError.api(code: 127, message: "操作过于频繁，请稍后重试")
                    case .landThenTimeout where attempt == 1:
                        node.name = newName; nodes[fileId] = node; faultHasOccurred = true
                        throw DriveError.network("response lost after rename")
                    case .ambiguousDestination where attempt == 1:
                        let foreign = "foreign-\(fileId)"
                        nodes[foreign] = Node(id: foreign, parent: node.parent, name: newName)
                        faultHasOccurred = true
                        throw DriveError.network("uncertain rename with conflicting destination")
                    default: break
                    }
                }
                node.name = newName; nodes[fileId] = node
                return fileId
            }
        }
        func move(fileId: String, destParentId: String) async throws -> String {
            try lock.withLock {
                guard var node = nodes[fileId] else { throw DriveError.invalidInput("missing test move source") }
                node.parent = destParentId; nodes[fileId] = node
                moveCalls[fileId, default: 0] += 1
                return fileId
            }
        }
        func moveBatch(fileIds: [String], destParentId: String) async throws -> [String: String] {
            try lock.withLock {
                batchCalls += 1
                if pendingBatch {
                    faultHasOccurred = true
                    throw GuangyaPendingOperationError(DriveError.network("background move accepted; status response lost"))
                }
                var output: [String: String] = [:]
                for (index, id) in fileIds.enumerated() {
                    if partialBatch && batchCalls == 1 && index == 1 {
                        faultHasOccurred = true
                        throw DriveError.network("batch response lost after the first item")
                    }
                    guard var node = nodes[id] else { throw DriveError.invalidInput("missing batch source") }
                    node.parent = destParentId; nodes[id] = node
                    moveCalls[id, default: 0] += 1; output[id] = id
                }
                return output
            }
        }
        func mkdir(parentId: String, name: String) async throws -> String {
            lock.withLock {
                let id = "directory-\(UUID().uuidString)"
                nodes[id] = Node(id: id, parent: parentId, name: name, directory: true, size: 0)
                return id
            }
        }
        func upload(parentId: String, name: String, data: Data) async throws -> String {
            lock.withLock {
                let id = "upload-\(UUID().uuidString)"
                nodes[id] = Node(id: id, parent: parentId, name: name, size: Int64(data.count))
                return id
            }
        }
        func parentIdOf(fileId: String) async throws -> String? { lock.withLock { nodes[fileId]?.parent } }
    }

    private func recoveryPlan(drive: RecoveryDrive, count: Int, operation: String = "rename") -> ScrapePlan {
        let actions = (1...count).map { index in
            PlanAction(id: "action-\(index)", op: operation, groupId: "group", fileId: "file-\(index)", parentId: "source",
                oldName: "old-\(index).mkv", newName: operation == "move" ? "old-\(index).mkv" : "new-\(index).mkv",
                destParentId: operation == "move" ? "destination" : nil, destRef: nil, kind: "file", mediaKind: "movie", tmdbId: 1,
                season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        }
        return ScrapePlan(id: "recovery-plan-\(UUID().uuidString)", accountId: drive.accountId, provider: drive.kind.rawValue,
                          createdAt: Date(), roots: [], groups: [], actions: actions, flags: [])
    }

    @MainActor
    private func finishRecoveryRun(_ runId: String) async throws -> TaskRun {
        let engine = ExecutionEngine.shared
        for _ in 0..<1_000 {
            if !engine.isRunning {
                return try XCTUnwrap(PlanAndTaskStore.shared.tasks.first { $0.id == runId })
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("automatic recovery must finish or persist a pause within the bounded test wait")
        await engine.stopAndWait()
        return try XCTUnwrap(PlanAndTaskStore.shared.tasks.first { $0.id == runId })
    }

    @MainActor
    private func waitForRecoveryState(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    @MainActor
    private func cleanRecoveryPlan(_ plan: ScrapePlan) {
        let store = PlanAndTaskStore.shared
        for run in store.tasks where run.planId == plan.id {
            for row in OperationJournal.shared.rows(forRunId: run.id)
                where row.status == .prepared || row.status == .uncertain || row.status == .undoPrepared {
                OperationJournal.shared.markSkipped(rowId: row.id, error: "test fixture cleanup")
            }
            ReversibleWalStore.shared.clear(taskId: run.id)
            store.deleteTask(id: run.id, allowPaused: true)
        }
        for queued in TaskQueue.shared.items where queued.planId == plan.id { TaskQueue.shared.remove(id: queued.id) }
        store.deletePlan(id: plan.id)
        ExecutionEngine.shared.resume()
    }

    @MainActor
    func testAutomaticSerialRecoveryRetriesRefusalButDoesNotRepeatLandedRename() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        for landed in [false, true] {
            let drive = RecoveryDrive(count: 1, faults: ["file-1": landed ? .landThenTimeout : .rejectOnce])
            let plan = recoveryPlan(drive: drive, count: 1)
            PlanAndTaskStore.shared.savePlan(plan)
            defer { cleanRecoveryPlan(plan) }
            XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
            let runId = try XCTUnwrap(engine.currentRun?.id)
            let run = try await finishRecoveryRun(runId)
            XCTAssertEqual(run.status, "done")
            XCTAssertEqual(run.completed, 1); XCTAssertEqual(run.succeeded, 1); XCTAssertEqual(run.failed, 0)
            XCTAssertTrue(run.errors.isEmpty)
            XCTAssertEqual(drive.renameCount("file-1"), landed ? 1 : 2)
            XCTAssertEqual(drive.node("file-1")?.name, "new-1.mkv")
            XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).count, 1)
            XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).first?.status, .applied)
        }
    }

    @MainActor
    func testAutomaticWaveRecoveryRetainsSiblingSuccessWithoutDuplicateAccounting() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        let drive = RecoveryDrive(count: 3, faults: ["file-2": .rejectOnce])
        let plan = recoveryPlan(drive: drive, count: 3)
        PlanAndTaskStore.shared.savePlan(plan); defer { cleanRecoveryPlan(plan) }
        XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
        let runId = try XCTUnwrap(engine.currentRun?.id)
        let run = try await finishRecoveryRun(runId)
        XCTAssertEqual(run.status, "done")
        XCTAssertEqual(run.completed, 3); XCTAssertEqual(run.succeeded, 3); XCTAssertEqual(run.failed, 0)
        XCTAssertTrue(run.errors.isEmpty)
        XCTAssertEqual(drive.renameCount("file-1"), 1)
        XCTAssertEqual(drive.renameCount("file-2"), 2)
        XCTAssertEqual(drive.renameCount("file-3"), 1)
        XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).count, 3)
        XCTAssertTrue(OperationJournal.shared.rows(forRunId: runId).allSatisfy { $0.status == .applied })
    }

    @MainActor
    func testPersistentRateLimitPausesAndKeepsSuccessfulSiblingAndQueue() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack && TaskQueue.shared.items.isEmpty else {
            throw XCTSkip("another engine or queue fixture is active")
        }
        let previousResolver = engine.driveResolver
        let drive = RecoveryDrive(count: 3, faults: ["file-2": .alwaysReject])
        engine.driveResolver = { accountId in accountId == drive.accountId ? drive : nil }
        defer { engine.driveResolver = previousResolver }
        let plan = recoveryPlan(drive: drive, count: 3)
        let queuedPlan = recoveryPlan(drive: drive, count: 1)
        PlanAndTaskStore.shared.savePlan(plan); PlanAndTaskStore.shared.savePlan(queuedPlan)
        let queued = TaskQueue.shared.enqueue(plan: queuedPlan)
        defer { cleanRecoveryPlan(plan); cleanRecoveryPlan(queuedPlan) }
        XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
        let runId = try XCTUnwrap(engine.currentRun?.id)
        let run = try await finishRecoveryRun(runId)
        XCTAssertEqual(run.status, "paused")
        XCTAssertNil(run.finishedAt)
        XCTAssertEqual(run.completed, 3); XCTAssertEqual(run.succeeded, 2); XCTAssertEqual(run.failed, 1)
        XCTAssertEqual(drive.renameCount("file-2"), 3, "initial attempt plus at most two bounded retries")
        XCTAssertEqual(drive.renameCount("file-1"), 1); XCTAssertEqual(drive.renameCount("file-3"), 1)
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(TaskQueue.shared.items.contains { $0.id == queued.id })
        XCTAssertFalse(PlanAndTaskStore.shared.tasks.contains { $0.planId == queuedPlan.id })
        let saved = try XCTUnwrap(PlanAndTaskStore.shared.plans.first { $0.id == plan.id })
        XCTAssertTrue(saved.actions.first { $0.id == "action-3" }?.done == true)
        XCTAssertTrue(saved.actions.first { $0.id == "action-2" }?.done == false)
    }

    @MainActor
    func testAmbiguousCloudStateStopsAutomaticWritesAfterTwoReadOnlyChecks() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        let drive = RecoveryDrive(count: 1, faults: ["file-1": .ambiguousDestination])
        let plan = recoveryPlan(drive: drive, count: 1)
        PlanAndTaskStore.shared.savePlan(plan); defer { cleanRecoveryPlan(plan) }
        XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
        let runId = try XCTUnwrap(engine.currentRun?.id)
        let run = try await finishRecoveryRun(runId)
        XCTAssertEqual(run.status, "paused")
        XCTAssertEqual(run.succeeded, 0); XCTAssertEqual(run.failed, 1)
        XCTAssertEqual(drive.renameCount("file-1"), 1)
        XCTAssertEqual(drive.verificationReads, 2, "one cached parent read in each of two verification rounds")
        XCTAssertEqual(drive.node("file-1")?.name, "old-1.mkv")
        XCTAssertEqual(drive.node("foreign-file-1")?.name, "new-1.mkv")
        XCTAssertEqual(ReversibleWalStore.shared.find(taskId: runId, actionId: "action-1")?.state, "uncertain")
        XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).first?.status, .uncertain)
    }

    @MainActor
    func testAutomaticBatchRecoveryMovesOnlyThePreviouslyUnappliedMember() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        let drive = RecoveryDrive(count: 2, partialBatch: true)
        let plan = recoveryPlan(drive: drive, count: 2, operation: "move")
        PlanAndTaskStore.shared.savePlan(plan); defer { cleanRecoveryPlan(plan) }
        XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
        let runId = try XCTUnwrap(engine.currentRun?.id)
        let run = try await finishRecoveryRun(runId)
        XCTAssertEqual(run.status, "done")
        XCTAssertEqual(run.completed, 2); XCTAssertEqual(run.succeeded, 2); XCTAssertEqual(run.failed, 0)
        XCTAssertTrue(run.errors.isEmpty)
        XCTAssertEqual(drive.batchCount, 2)
        for id in ["file-1", "file-2"] {
            XCTAssertEqual(drive.moveCount(id), 1)
            XCTAssertEqual(drive.node(id)?.parent, "destination")
        }
        XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).count, 2)
        XCTAssertTrue(OperationJournal.shared.rows(forRunId: runId).allSatisfy { $0.status == .applied })
    }

    @MainActor
    func testAutomaticDirectoryRecoveryReplaysFinalizationWithoutCreatingAnotherDirectory() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        let drive = RecoveryDrive(count: 1, directoryRenameTimeout: true)
        let action = PlanAction(id: "directory-action", op: "mkdir", groupId: "group", fileId: nil, parentId: "source",
            oldName: "", newName: "Season 01", destParentId: nil, destRef: nil, kind: "folder", mediaKind: "tv", tmdbId: 1,
            season: 1, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let plan = ScrapePlan(id: "directory-recovery-\(UUID().uuidString)", accountId: drive.accountId, provider: drive.kind.rawValue,
            createdAt: Date(), roots: [], groups: [], actions: [action], flags: [])
        PlanAndTaskStore.shared.savePlan(plan); defer { cleanRecoveryPlan(plan) }
        XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
        let runId = try XCTUnwrap(engine.currentRun?.id)
        let run = try await finishRecoveryRun(runId)
        XCTAssertEqual(run.status, "done")
        XCTAssertEqual(run.completed, 1); XCTAssertEqual(run.succeeded, 1); XCTAssertEqual(run.failed, 0)
        XCTAssertTrue(run.errors.isEmpty)
        XCTAssertEqual(drive.directoryIds.count, 1)
        let directoryId = try XCTUnwrap(drive.directoryIds.first)
        XCTAssertEqual(drive.node(directoryId)?.name, "Season 01")
        XCTAssertEqual(drive.renameCount(directoryId), 1)
        XCTAssertEqual(ReversibleWalStore.shared.find(taskId: runId, actionId: action.id)?.state, "applied")
        XCTAssertEqual(ReversibleWalStore.shared.find(taskId: runId, actionId: action.id + ":finalize")?.state, "applied")
        XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).count, 1)
        XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).first?.status, .applied)
    }

    @MainActor
    func testPausedAmbiguousWaveStillAccountsSiblingConfirmedDuringVerification() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        let lateSibling = RecoveryGate()
        let drive = RecoveryDrive(count: 3, faults: ["file-2": .ambiguousDestination, "file-3": .landThenTimeout],
                                  heldRenameFile: "file-3", renameGate: lateSibling)
        let plan = recoveryPlan(drive: drive, count: 3)
        PlanAndTaskStore.shared.savePlan(plan); defer { cleanRecoveryPlan(plan) }
        XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
        let runId = try XCTUnwrap(engine.currentRun?.id)
        let firstFailed = await waitForRecoveryState {
            let siblingWaiting = await lateSibling.isEntered
            return ReversibleWalStore.shared.find(taskId: runId, actionId: "action-2")?.state == "uncertain" && siblingWaiting
        }
        XCTAssertTrue(firstFailed)
        await lateSibling.release()
        let run = try await finishRecoveryRun(runId)
        XCTAssertEqual(run.status, "paused")
        XCTAssertEqual(run.completed, 3); XCTAssertEqual(run.succeeded, 2); XCTAssertEqual(run.failed, 1)
        XCTAssertEqual(drive.renameCount("file-1"), 1); XCTAssertEqual(drive.renameCount("file-2"), 1)
        XCTAssertEqual(drive.renameCount("file-3"), 1)
        XCTAssertEqual(ReversibleWalStore.shared.find(taskId: runId, actionId: "action-3")?.state, "applied")
        XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).first { $0.actionId == "action-3" }?.status, .applied)
        XCTAssertTrue(run.executionSnapshot?.actions.first { $0.id == "action-3" }?.done == true)
    }

    @MainActor
    func testStoppingDuringAutomaticReadKeepsLandedSuccessAndDoesNotWritePendingBatchMember() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        for batch in [false, true] {
            let readGate = RecoveryGate()
            let drive = RecoveryDrive(count: batch ? 2 : 1,
                faults: batch ? [:] : ["file-1": .landThenTimeout], partialBatch: batch,
                verificationGate: readGate, blockVerificationRead: batch ? 2 : 1)
            let plan = recoveryPlan(drive: drive, count: batch ? 2 : 1, operation: batch ? "move" : "rename")
            PlanAndTaskStore.shared.savePlan(plan); defer { cleanRecoveryPlan(plan) }
            XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
            let runId = try XCTUnwrap(engine.currentRun?.id)
            let entered = await waitForRecoveryState { await readGate.isEntered }
            XCTAssertTrue(entered, "the verification response must be held before requesting stop")
            let readsBeforeManualCheck = drive.verificationReads
            let pendingWal = ReversibleWalStore.shared.uncertainRecords().filter { $0.taskId == runId }
            let manualWal = await JournalReconciler.reconcileReversibleWal(taskId: runId, drive: drive)
            let manualJournal = await JournalReconciler.reconcile(runId: runId, drive: drive)
            XCTAssertEqual(manualWal.confirmedApplied, 0)
            XCTAssertEqual(manualWal.confirmedNotApplied, 0)
            XCTAssertEqual(manualWal.stillUncertain, pendingWal.count)
            XCTAssertGreaterThan(manualJournal.stillUncertain, 0)
            XCTAssertEqual(manualJournal.confirmedApplied, 0)
            XCTAssertEqual(manualJournal.confirmedNotApplied, 0)
            XCTAssertEqual(drive.verificationReads, readsBeforeManualCheck, "manual verification cannot inspect an active run's in-flight requests")
            for row in pendingWal {
                XCTAssertEqual(ReversibleWalStore.shared.find(taskId: runId, actionId: row.actionId)?.state, row.state)
            }
            engine.stop()
            await readGate.release()
            let run = try await finishRecoveryRun(runId)
            XCTAssertEqual(run.status, "stopped")
            XCTAssertEqual(run.completed, 1); XCTAssertEqual(run.succeeded, 1); XCTAssertEqual(run.failed, 0)
            if batch {
                XCTAssertEqual(drive.batchCount, 1)
                XCTAssertEqual(drive.moveCount("file-1"), 1); XCTAssertEqual(drive.moveCount("file-2"), 0)
                XCTAssertEqual(drive.node("file-2")?.parent, "source")
                XCTAssertTrue(run.executionSnapshot?.actions.first { $0.id == "action-2" }?.done == false)
            } else { XCTAssertEqual(drive.renameCount("file-1"), 1) }
            XCTAssertEqual(OperationJournal.shared.rows(forRunId: runId).first { $0.actionId == "action-1" }?.status, .applied)
        }
    }

    @MainActor
    func testUserPauseDuringAutomaticVerificationWaitsForResumeBeforeRetryingWrite() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        let readGate = RecoveryGate()
        let drive = RecoveryDrive(count: 1, faults: ["file-1": .rejectOnce], verificationGate: readGate)
        let plan = recoveryPlan(drive: drive, count: 1)
        PlanAndTaskStore.shared.savePlan(plan); defer { cleanRecoveryPlan(plan) }
        XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
        let runId = try XCTUnwrap(engine.currentRun?.id)
        let entered = await waitForRecoveryState { await readGate.isEntered }
        XCTAssertTrue(entered)
        engine.pause()
        await readGate.release()
        let waiting = await waitForRecoveryState { engine.currentRun?.id == runId && engine.currentRun?.status == "paused" }
        XCTAssertTrue(waiting, "recovery must enter the explicit user pause before issuing a retry")
        XCTAssertEqual(drive.renameCount("file-1"), 1)
        XCTAssertEqual(drive.node("file-1")?.name, "old-1.mkv")
        engine.resume()
        let run = try await finishRecoveryRun(runId)
        XCTAssertEqual(run.status, "done"); XCTAssertEqual(run.succeeded, 1); XCTAssertEqual(run.failed, 0)
        XCTAssertEqual(drive.renameCount("file-1"), 2)
    }

    @MainActor
    func testAcceptedBackgroundBatchIsNotResubmittedFromTemporarilyUnchangedDirectories() async throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning && !engine.isRollingBack else { throw XCTSkip("another engine test is active") }
        let previousResolver = engine.driveResolver; engine.driveResolver = nil
        defer { engine.driveResolver = previousResolver }
        let drive = RecoveryDrive(count: 2, pendingBatch: true)
        let plan = recoveryPlan(drive: drive, count: 2, operation: "move")
        PlanAndTaskStore.shared.savePlan(plan); defer { cleanRecoveryPlan(plan) }
        XCTAssertTrue(engine.start(plan: plan, drive: drive, skipDelaysForTest: true))
        let runId = try XCTUnwrap(engine.currentRun?.id)
        let run = try await finishRecoveryRun(runId)
        XCTAssertEqual(run.status, "paused")
        XCTAssertEqual(run.succeeded, 0)
        XCTAssertEqual(drive.batchCount, 1, "an accepted background move must never be resubmitted from an early empty target")
        for id in ["file-1", "file-2"] {
            XCTAssertEqual(drive.moveCount(id), 0)
            XCTAssertEqual(drive.node(id)?.parent, "source")
        }
        for action in plan.actions {
            let row = try XCTUnwrap(ReversibleWalStore.shared.find(taskId: runId, actionId: action.id))
            XCTAssertEqual(row.state, "uncertain")
            XCTAssertEqual(row.mayStillComplete, true)
        }
        XCTAssertGreaterThanOrEqual(drive.verificationReads, 1)
        XCTAssertLessThanOrEqual(drive.verificationReads, 5, "an immediate batch check and at most two cached source/target verification rounds")
    }

    func testUnfinishedPrivateDirectoryIsNotReusedBeforeFinalization() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unfinalized-directory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let wal = ReversibleWalStore(storageURL: url)
        let action = PlanAction(id: "mkdir", op: "mkdir", groupId: "group", fileId: nil, parentId: "0", oldName: "", newName: "Season 01",
            destParentId: nil, destRef: nil, kind: "folder", mediaKind: "tv", tmdbId: 1, season: 1, episode: nil,
            artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let plan = ScrapePlan(id: "directory-plan", accountId: "a", provider: "guangya", createdAt: Date(), roots: [], groups: [], actions: [action], flags: [])
        let temporary = RemoteSnapshot(id: "temp", parent: "0", name: ".PanScraper.New-\(UUID().uuidString)", directory: true)
        let created = try wal.prepare(taskId: "previous", accountId: "a", actionId: action.id, operation: "mkdir", before: nil, after: temporary)
        try wal.change(created, state: "applied")
        XCTAssertTrue(ExecutionEngine.reusableDirectoryIds(plan: plan, runIds: ["previous"], wal: wal).isEmpty)
        let finalize = try wal.prepare(taskId: "previous", accountId: "a", actionId: action.id + ":finalize", operation: "rename", before: temporary, after: temporary.with(name: "Season 01"))
        try wal.change(finalize, state: "applied")
        XCTAssertEqual(ExecutionEngine.reusableDirectoryIds(plan: plan, runIds: ["previous"], wal: wal), [action.id])
    }

    @MainActor
    func testCancellationRetryKeepsPreviouslyAcceptedSubstitutions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("controls-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString
        let previous = TaskControl(taskId: id, accountId: "acc", mode: "undo", state: "needs_backup_choice",
                                   missingBackupIds: ["second:backup"], acceptedSubstitutions: ["first:backup"])
        try JSONEncoder().encode([id: previous]).write(to: url)
        let controls = TaskCancellation(storageURL: url)
        let retry = try controls.request(taskId: id, accountId: "acc", undo: true, acceptedSubstitutions: ["second:backup"])
        XCTAssertEqual(Set(retry.acceptedSubstitutions), ["first:backup", "second:backup"])
        let reloaded = TaskCancellation(storageURL: url)
        XCTAssertEqual(reloaded.controls[id]?.acceptedSubstitutions, retry.acceptedSubstitutions)
    }

    func testNfoXmlEscapingCdataSplittingAndImageBytes() {
        XCTAssertEqual(NfoXml.esc("A & B <C> \"D\" 'E'\u{0001}"), "A &amp; B &lt;C&gt; &quot;D&quot; &apos;E&apos;")
        let cd = NfoXml.cdata(name: "plot", value: "hello ]]> world\u{0007}")
        XCTAssertEqual(cd, "  <plot><![CDATA[hello ]]]]><![CDATA[> world]]></plot>")
        XCTAssertEqual(NfoXml.flat("  line1 \r\n  line2  "), "line1line2")

        XCTAssertEqual(ImageBytes.safeExt(url: "https://image.tmdb.org/t/p/w780/a.png?v=1"), "png")
        XCTAssertEqual(ImageBytes.safeExt(url: "https://example.com/file.exe"), "jpg")
        XCTAssertTrue(ImageBytes.looksLikeImage(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])))
        XCTAssertFalse(ImageBytes.looksLikeImage(Data("<html>not img</html>".utf8)))
    }

    @MainActor
    func testJournalReconcilerForwardAndUndoPreparedDeadlockRecovery() async {
        let tmp = FileManager.default.temporaryDirectory
        let journal = OperationJournal(storageURL: tmp.appendingPathComponent("test_reconcile_\(UUID().uuidString).json"))

        // 1. 正向中断：目标已存在且原名消失 -> applied
        let r1 = journal.prepare(runId: "r1", actionId: "a1", op: "rename", kind: "file", fileId: "/m/old.mkv", parentId: "/m", destParentId: "/m", oldName: "old.mkv", newName: "new.mkv")
        journal.markUncertain(rowId: r1.id, error: "timeout")

        // 2. 撤销中断（undo_prepared）：原名已恢复且新名消失 -> reverted (.undone)
        let r2 = journal.prepare(runId: "r1", actionId: "a2", op: "rename", kind: "file", fileId: "/m/orig.mkv", parentId: "/m", destParentId: "/m", oldName: "orig.mkv", newName: "renamed.mkv")
        journal.markStatus(rowId: r2.id, status: .undoPrepared)

        let drive = MockExecDrive()
        drive.listings["/m"] = [
            CloudEntry(fileId: "/m/new.mkv", fileName: "new.mkv", isDir: false),
            CloudEntry(fileId: "/m/orig.mkv", fileName: "orig.mkv", isDir: false),
        ]

        let report = await JournalReconciler.reconcile(runId: "r1", drive: drive, journal: journal)
        XCTAssertEqual(report.confirmedApplied, 1)
        XCTAssertEqual(report.confirmedReverted, 1)
        XCTAssertEqual(report.stillUncertain, 0)
        XCTAssertEqual(journal.rows.first(where: { $0.id == r1.id })?.status, .applied)
        XCTAssertEqual(journal.rows.first(where: { $0.id == r2.id })?.status, .undone)
    }

    @MainActor
    func testTaskCancellationKeepAndUndoModes() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let cancelStore = TaskCancellation(storageURL: tmp.appendingPathComponent("test_cancel_\(UUID().uuidString).json"))
        let journal = OperationJournal(storageURL: tmp.appendingPathComponent("test_cj_\(UUID().uuidString).json"))
        let drive = MockExecDrive()

        let cKeep = try cancelStore.request(taskId: "t1", accountId: "acc-exec", undo: false)
        let doneKeep = await cancelStore.apply(control: cKeep, drive: drive, journal: journal)
        XCTAssertEqual(doneKeep.state, "completed")

        let row = journal.prepare(runId: "t2", actionId: "a1", op: "rename", kind: "file", fileId: "/m/a.mkv", parentId: "/m", destParentId: "/m", oldName: "a.mkv", newName: "b.mkv")
        journal.markApplied(rowId: row.id, createdId: "/m/b.mkv")
        let cUndo = try cancelStore.request(taskId: "t2", accountId: "acc-exec", undo: true)
        let doneUndo = await cancelStore.apply(control: cUndo, drive: drive, journal: journal)
        XCTAssertEqual(doneUndo.state, "completed")
        XCTAssertEqual(drive.renamed.first?.1, "a.mkv")
    }
}
