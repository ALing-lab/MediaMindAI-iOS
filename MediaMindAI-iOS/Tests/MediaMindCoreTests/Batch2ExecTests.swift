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
