import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 批次 5.2：1:1 迁移 Android Scrape / Scanner 模拟云盘集成单元测试
/// 覆盖：PlanStore / ScannerTypesAndTree (HolderOf M10) / EpisodeStrategy / PlanSelection /
/// PreviewFilter / PreviewGrouping / ManualConfirmation / LibraryDestination / LibraryTargets /
/// Scanner.scan & Scanner.replanGroup 模拟云盘端到端集成测试
final class ScrapeAndScannerSuiteTests: XCTestCase {

    @MainActor
    func testEmptyExecutionDoesNotCreateRecordsOrStartEngine() throws {
        let engine = ExecutionEngine.shared
        guard !engine.isRunning else { throw XCTSkip("另一执行测试仍在运行") }
        var plan = makeSamplePlan()
        plan.actions = []
        let taskIds = PlanAndTaskStore.shared.tasks.map(\.id)
        let planIds = PlanAndTaskStore.shared.plans.map(\.id)
        let queueIds = TaskQueue.shared.items.map(\.id)
        let previousRun = engine.currentRun?.id
        XCTAssertFalse(engine.start(plan: plan, drive: MockScrapeDrive(tree: [:]), skipDelaysForTest: true))
        XCTAssertFalse(engine.enqueueOrStart(plan: plan, drive: MockScrapeDrive(tree: [:])))
        XCTAssertEqual(PlanAndTaskStore.shared.tasks.map(\.id), taskIds)
        XCTAssertEqual(PlanAndTaskStore.shared.plans.map(\.id), planIds)
        XCTAssertEqual(TaskQueue.shared.items.map(\.id), queueIds)
        XCTAssertEqual(engine.currentRun?.id, previousRun)
        XCTAssertFalse(engine.isRunning)
        XCTAssertNotNil(engine.lastStartError)
    }

    func testExecutionSelectionRejectsSkipDisabledBlockedAndStaleIds() {
        var plan = makeSamplePlan(fileOperation: "skip")
        plan.actions[1].enabled = false
        XCTAssertTrue(ExecutionEngine.executableActionIds(plan: plan).isEmpty)
        // op 是只读字段：用原始 rename 动作副本恢复，不修改生产模型。
        plan.actions[0] = makeSamplePlan().actions[0]
        plan.actions[0].blocked = "待核实"
        XCTAssertTrue(ExecutionEngine.executableActionIds(plan: plan).isEmpty)
        plan.actions[0].blocked = nil
        plan.actions[0].selected = false
        XCTAssertTrue(ExecutionEngine.executableActionIds(plan: plan).isEmpty)
        XCTAssertEqual(ExecutionEngine.executableActionIds(plan: plan, requested: ["missing", "a1", "a1", "a2"]), ["a1"])
    }

    func testExecutionSnapshotDoesNotFollowLaterPlanChanges() throws {
        var plan = makeSamplePlan()
        plan.actions[0].selected = false
        let snapshot = plan.executionSnapshot(actionIds: ["a1"])
        plan.actions[0].newName = "重新识别后的文件名.mkv"
        plan.actions[0].selected = false
        plan.actions[0].done = true
        plan.groups[0].title = "另一部电影"
        XCTAssertEqual(snapshot.actions.map(\.id), ["a1"])
        XCTAssertTrue(snapshot.actions[0].selected, "实际提交的依赖项也属于当次执行范围")
        XCTAssertEqual(snapshot.groups[0].actionIds, ["a1"])
        XCTAssertEqual(snapshot.groups[0].title, "盗梦空间")
        XCTAssertFalse(snapshot.actions[0].done)
        var run = sampleRun(total: 1, completed: 1, succeeded: 1)
        run.executionSnapshot = snapshot
        let loaded = try JSONDecoder().decode(TaskRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(loaded.executionSnapshot?.actions[0].newName, snapshot.actions[0].newName)
        XCTAssertEqual(loaded.executionSnapshot?.groups[0].title, "盗梦空间")
    }

    func testLegacyZeroRunDecodesWithoutSnapshotAndIsNotSuccess() throws {
        let run = sampleRun(total: 0, completed: 0, succeeded: 0)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        json.removeValue(forKey: "executionSnapshot")
        let loaded = try JSONDecoder().decode(TaskRun.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(loaded.executionSnapshot)
        XCTAssertFalse(loaded.isSuccessful)
        XCTAssertTrue(loaded.hasNoEffectiveOperations)
    }

    func testSuccessRequiresNonEmptyFullyProcessedRun() {
        XCTAssertFalse(sampleRun(total: 0, completed: 0, succeeded: 0).isSuccessful)
        XCTAssertFalse(sampleRun(total: 2, completed: 1, succeeded: 1).isSuccessful)
        XCTAssertFalse(sampleRun(total: 2, completed: 2, succeeded: 0).isSuccessful)
        XCTAssertTrue(sampleRun(total: 2, completed: 2, succeeded: 2).isSuccessful)
        var failed = sampleRun(total: 2, completed: 2, succeeded: 1)
        failed.failed = 1
        XCTAssertFalse(failed.isSuccessful)
    }

    @MainActor
    func testScanPlansPersistAsPendingWithoutFakeTaskRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pending-plans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        for index in 0..<25 {
            let source = makeSamplePlan()
            var plan = ScrapePlan(id: "pending-\(UUID().uuidString)-\(index)", accountId: source.accountId, provider: source.provider,
                createdAt: Date(), roots: source.roots, groups: source.groups, actions: source.actions, flags: [])
            plan.reviewDisposition = "pending"
            store.savePlan(plan)
        }
        XCTAssertEqual(store.pendingPlans.count, 25)
        XCTAssertTrue(store.tasks.isEmpty)
        let cancelled = try XCTUnwrap(store.pendingPlans.first)
        store.cancelPendingPlan(id: cancelled.id)
        let reloaded = PlanAndTaskStore(storageURL: dir)
        XCTAssertEqual(reloaded.pendingPlans.count, 24)
        XCTAssertFalse(reloaded.pendingPlans.contains { $0.id == cancelled.id })
        XCTAssertTrue(reloaded.tasks.isEmpty)
    }

    func testMovieVarietyAndCollectionFiltersAreExclusive() {
        let movie = makeSamplePlan().groups[0]
        var variety = movie
        variety.kind = "tv"
        variety.genreIds = [10764]
        var tv = movie
        tv.kind = "tv"
        var collection = movie
        collection.kind = "collection"
        let groups = [movie, variety, tv, collection]
        XCTAssertEqual(PreviewFilter.apply(groups: groups, kind: .movie, query: "").count, 1)
        XCTAssertEqual(PreviewFilter.apply(groups: groups, kind: .tv, query: "").count, 1)
        XCTAssertEqual(PreviewFilter.apply(groups: groups, kind: .variety, query: "").count, 1)
        XCTAssertEqual(PreviewFilter.apply(groups: groups, kind: .collection, query: "").count, 1)
        XCTAssertEqual(PreviewSectionGrouping.category(plan: makeSamplePlan(), group: collection), "合集")
        XCTAssertEqual(PreviewFilterKind.visibleCases.map(\.rawValue), ["全部", "电影", "剧集", "综艺", "合集"])
    }

    func testMediaCountDeduplicatesVersionsAndCollectionMembership() {
        var plan = makeSamplePlan()
        var sameMovieAnotherVersion = plan.groups[0]
        sameMovieAnotherVersion.folderId = "another-version"
        plan.groups.append(sameMovieAnotherVersion)
        XCTAssertEqual(plan.uniqueMediaCount, 1)
        plan.groups[0].kind = "collection"
        // 同一电影既单独存在又出现在合集里，仍只计一部。
        XCTAssertEqual(plan.uniqueMediaCount, 1)
    }

    func testReviewDispositionDoesNotChangePlanIdentity() {
        var plan = makeSamplePlan()
        let original = PlanStore.shared.key(plan)
        plan.reviewDisposition = "started"
        XCTAssertEqual(PlanStore.shared.key(plan), original)
    }

    @MainActor
    func testQueueFreezesAcceptedIdsInsteadOfExecutingFutureRecognitionResults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-scope-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = TaskQueue(storageURL: url)
        var plan = makeSamplePlan()
        let accepted = ExecutionEngine.executableActionIds(plan: plan)
        let queued = queue.enqueue(plan: plan)
        plan.actions.removeFirst()
        XCTAssertEqual(queued.actionIds, accepted)
        XCTAssertEqual(queued.actionCount, accepted.count)
        let reloaded = TaskQueue(storageURL: url)
        XCTAssertEqual(reloaded.items.first?.actionIds, accepted)
        XCTAssertEqual(ExecutionEngine.executableActionIds(plan: plan, requested: queued.actionIds), ["a2"])
    }

    func testLegacyPlanAndMetadataDecodeWithOptionalWorkflowFields() throws {
        let plan = makeSamplePlan()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        json.removeValue(forKey: "reviewDisposition")
        let loaded = try JSONDecoder().decode(ScrapePlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(loaded.reviewDisposition)
        XCTAssertEqual(loaded.actions.count, plan.actions.count)
        let oldMovie = Data("{\"kind\":\"movie\",\"id\":1,\"title\":\"Title\",\"year\":\"2020\",\"overview\":\"\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(MatchInfo.self, from: oldMovie).genreIds)
    }

    func testDirectoryCoverageUsesAncestryAndPathBoundaries() {
        let graph = ["child": "parent", "parent": "root", "cycle": "cycle"]
        XCTAssertTrue(ScanPlanUpdater.contains("child", root: "root", parents: graph, paths: false))
        XCTAssertFalse(ScanPlanUpdater.contains("cycle", root: "root", parents: graph, paths: false))
        XCTAssertTrue(ScanPlanUpdater.overlap([PlanRoot(folderId: "parent", name: "")], [PlanRoot(folderId: "child", name: "")], parents: graph, paths: false))
        XCTAssertFalse(ScanPlanUpdater.contains("/movies2/file", root: "/movies", parents: [:], paths: true))
        XCTAssertTrue(ScanPlanUpdater.contains("/movies/show/file", root: "/movies", parents: [:], paths: true))
    }

    func testWebDavIdentityRequiresStrongEvidence() {
        let before = CloudEntry(fileId: "/old", fileName: "A.mkv", isDir: false, size: 100, etag: "\"hash\"")
        let renamed = CloudEntry(fileId: "/new", fileName: "B.mkv", isDir: false, size: 100, etag: "\"hash\"")
        let replaced = CloudEntry(fileId: "/old", fileName: "A.mkv", isDir: false, size: 101, etag: "\"other\"")
        XCTAssertTrue(ScanPlanUpdater.sameSource(before, renamed, paths: true))
        XCTAssertFalse(ScanPlanUpdater.sameSource(before, replaced, paths: false))
        let weak = CloudEntry(fileId: "/old", fileName: "A.mkv", isDir: false, size: 100, etag: "W/\"hash\"")
        XCTAssertFalse(ScanPlanUpdater.sameSource(weak, weak, paths: true))
    }

    @MainActor
    func testPartialExecutionKeepsRemainingAndReservationSurvivesHistoryDeletion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        var plan = makeSamplePlan(); plan.reviewDisposition = "pending"; store.savePlan(plan)
        let begun = store.markExecutionStarted(plan, requested: ["a1"], runId: "run-A")
        var run = sampleRun(total: 1, completed: 1, succeeded: 1)
        run.executionSnapshot = plan.executionSnapshot(actionIds: ["a1"])
        store.saveTask(run)
        XCTAssertEqual(begun.reviewDisposition, "pending")
        let remaining = try XCTUnwrap(store.pendingPlans.first)
        XCTAssertEqual(ExecutionEngine.executableActionIds(plan: remaining), ["a2"])
        XCTAssertFalse(remaining.actions.first { $0.id == "a1" }!.selected)
        store.deleteTask(id: run.id)
        let reloaded = PlanAndTaskStore(storageURL: dir)
        let restored = try XCTUnwrap(reloaded.pendingPlans.first)
        XCTAssertEqual(ExecutionEngine.executableActionIds(plan: restored), ["a2"])
        let final = reloaded.markExecutionStarted(restored, requested: ["a2"], runId: "run-B")
        XCTAssertEqual(final.reviewDisposition, "started")
        XCTAssertEqual(Set(final.executionRunIds ?? []), ["run-A", "run-B"])
    }

    func testDefaultExecutionCannotResubmitHistoricalOperations() {
        var plan = makeSamplePlan(); plan.submittedActionIds = ["a1"]
        XCTAssertEqual(ExecutionEngine.executableActionIds(plan: plan), ["a2"])
        XCTAssertEqual(ExecutionEngine.executableActionIds(plan: plan, requested: ["a1"]), ["a1"])
    }

    @MainActor
    func testStaleAsyncEditCannotOverwriteMergedOrUpdatedPlan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        var original = makeSamplePlan(); original.reviewDisposition = "pending"; store.savePlan(original)
        let captured = store.pendingProjection(original)
        var updated = original; updated.groups[0].title = "扫描更新后的标题"
        try store.commitScan(updated, replacing: [original.id])
        XCTAssertThrowsError(try store.saveEditedPlan(captured, original: captured))
        XCTAssertEqual(store.plans.first?.groups.first?.title, "扫描更新后的标题")
        store.deletePlan(id: original.id)
        XCTAssertThrowsError(try store.saveEditedPlan(captured, original: captured))
        XCTAssertTrue(store.plans.isEmpty)
    }

    @MainActor
    func testFailedScanCommitDoesNotPublishOrRemoveOldPlan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let original = makeSamplePlan(); store.savePlan(original)
        try FileManager.default.removeItem(at: dir)
        try Data("not-a-directory".utf8).write(to: dir)
        var replacement = original; replacement.groups[0].title = "不能提交"
        XCTAssertThrowsError(try store.commitScan(replacement, replacing: [original.id]))
        XCTAssertEqual(store.plans.first?.groups.first?.title, original.groups.first?.title)
    }

    @MainActor
    func testRepeatedScanUpdatesOneCardAddsRemovesFilesAndKeepsDeselection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let root = PlanRoot(folderId: "root", name: "影视", parentId: "0")
        let folder = CloudEntry(fileId: "show", fileName: "Show", isDir: true, parentFileId: "root")
        func episode(_ number: Int) -> CloudEntry {
            CloudEntry(fileId: "e\(number)", fileName: String(format: "Show.S01E%02d.mkv", number), isDir: false, size: 1024,
                       parentFileId: "show", etag: "episode-\(number)")
        }
        let provider = MockScannerTmdb(movies: [:], shows: ["show": MatchInfo(kind: "tv", id: 777, title: "Show", year: "2020")], seasonCounts: [777: [1: 10]])
        var first = try await ScanPlanUpdater.scan(roots: [root], drive: MockScrapeDrive(tree: ["root": [folder], "show": [episode(1), episode(2)]]),
            store: store, tmdbProvider: provider, preflightTmdb: false)
        for index in first.actions.indices { first.actions[index].selected = false }; store.savePlan(first)
        let second = try await ScanPlanUpdater.scan(roots: [root], drive: MockScrapeDrive(tree: ["root": [folder], "show": [episode(2), episode(3)]]),
            store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.plans.count, 1)
        XCTAssertFalse(second.actions.contains { $0.fileId == "e1" })
        XCTAssertTrue(second.actions.contains { $0.fileId == "e3" })
        XCTAssertTrue(second.actions.filter { $0.fileId == "e3" }.allSatisfy { !$0.selected })
        XCTAssertTrue(store.tasks.isEmpty)
    }

    @MainActor
    func testParentAndChildScanMergeWithoutReadingUnchangedSibling() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let show = CloudEntry(fileId: "show", fileName: "Show", isDir: true, parentFileId: "root")
        let other = CloudEntry(fileId: "other", fileName: "Other", isDir: true, parentFileId: "root")
        let a = CloudEntry(fileId: "a", fileName: "Show.S01E01.mkv", isDir: false, size: 100, parentFileId: "show", etag: "a")
        let b = CloudEntry(fileId: "b", fileName: "Other.S01E01.mkv", isDir: false, size: 100, parentFileId: "other", etag: "b")
        let c = CloudEntry(fileId: "c", fileName: "Show.S01E02.mkv", isDir: false, size: 100, parentFileId: "show", etag: "c")
        let provider = MockScannerTmdb(movies: [:], shows: ["show": MatchInfo(kind: "tv", id: 777, title: "Show"), "other": MatchInfo(kind: "tv", id: 778, title: "Other")], seasonCounts: [:])
        let child = PlanRoot(folderId: "show", name: "Show", parentId: "root")
        let parent = PlanRoot(folderId: "root", name: "影视", parentId: "0")
        let initial = try await ScanPlanUpdater.scan(roots: [child], drive: MockScrapeDrive(tree: ["show": [a]]), store: store, tmdbProvider: provider, preflightTmdb: false)
        let merged = try await ScanPlanUpdater.scan(roots: [parent], drive: MockScrapeDrive(tree: ["root": [show, other], "show": [a], "other": [b]]), store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertEqual(initial.id, merged.id); XCTAssertEqual(merged.roots.map(\.folderId), ["root"])
        // 本次服务端未提供 other 的条目，若误读兄弟目录就会丢失 b；应使用旧快照保留它。
        let refreshed = try await ScanPlanUpdater.scan(roots: [child], drive: MockScrapeDrive(tree: ["show": [a, c]]), store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertEqual(store.plans.count, 1)
        XCTAssertTrue(refreshed.actions.contains { $0.fileId == "b" })
        XCTAssertTrue(refreshed.actions.contains { $0.fileId == "c" })
    }

    @MainActor
    func testUnchangedFilesKeepManualMatchOnRescan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let root = PlanRoot(folderId: "root", name: "影视", parentId: "0")
        let folder = CloudEntry(fileId: "show", fileName: "Show", isDir: true, parentFileId: "root")
        let file = CloudEntry(fileId: "manual-video", fileName: "Show.S01E01.mkv", isDir: false, size: 100, parentFileId: "show", etag: "unchanged")
        let drive = MockScrapeDrive(tree: ["root": [folder], "show": [file]])
        let provider = MockScannerTmdb(movies: [:], shows: ["show": MatchInfo(kind: "tv", id: 777, title: "Show")], seasonCounts: [:])
        var first = try await ScanPlanUpdater.scan(roots: [root], drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        let index = try XCTUnwrap(first.groups.firstIndex { $0.kind == "tv" })
        first.groups[index].confidence = "手动"; first.groups[index].tmdbId = 888; first.groups[index].title = "Manual Show"
        store.savePlan(first)
        let second = try await ScanPlanUpdater.scan(roots: [root], drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertTrue(second.groups.contains { $0.tmdbId == 888 && $0.title == "Manual Show" })
    }

    @MainActor
    func testOverlappingPausedExecutionBlocksScanCommit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let source = makeSamplePlan()
        let plan = ScrapePlan(id: "locked", accountId: "mock-scrape-acct", provider: "123", createdAt: Date(),
            roots: [PlanRoot(folderId: "0", name: "根目录")], groups: source.groups, actions: source.actions, flags: [])
        store.savePlan(plan)
        var run = TaskRun(id: "paused", planId: plan.id, accountId: plan.accountId, provider: plan.provider, sourceLabel: "",
            status: "paused", total: 1, completed: 0, succeeded: 0, failed: 0, message: "", startedAt: Date(), finishedAt: nil, errors: [])
        run.executionSnapshot = plan.executionSnapshot(actionIds: ["a1"]); store.saveTask(run)
        do {
            _ = try await ScanPlanUpdater.scan(roots: plan.roots, drive: MockScrapeDrive(tree: [:]), store: store, preflightTmdb: false)
            XCTFail("重叠执行中的范围不得提交更新")
        } catch { XCTAssertEqual(store.plans.map(\.id), ["locked"]) }
    }

    func testOverlayDoesNotKeepMovedFileInTwoDirectories() async throws {
        let file = CloudEntry(fileId: "same-id", fileName: "Show.S01E01.mkv", isDir: false, size: 100, parentFileId: "new", etag: "same")
        let proxy = ScanSnapshotDrive(MockScrapeDrive(tree: ["new": [file]]))
        let roots = [PlanRoot(folderId: "new", name: "Show", parentId: "0")]
        try await proxy.read(roots: roots)
        await proxy.overlay(["old": [file]], outside: roots, graph: ["new": "0", "old": "0"])
        let captured = await proxy.captured()
        XCTAssertEqual(captured.listings.values.flatMap { $0 }.filter { $0.fileId == "same-id" }.count, 1)
        XCTAssertEqual(captured.parents["same-id"], "new")
    }

    @MainActor
    func testScanCommitCannotReplaceAnotherAccountsPlan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let original = makeSamplePlan(); store.savePlan(original)
        let other = ScrapePlan(id: original.id, accountId: "other-account", provider: original.provider, createdAt: Date(),
            roots: original.roots, groups: original.groups, actions: original.actions, flags: [])
        XCTAssertThrowsError(try store.commitScan(other, replacing: [original.id]))
        XCTAssertEqual(store.plans.first?.accountId, original.accountId)
    }

    @MainActor
    func testUnchangedFilesKeepEpisodeStrategyOnRescan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let root = PlanRoot(folderId: "root", name: "影视", parentId: "0")
        let folder = CloudEntry(fileId: "show", fileName: "Show", isDir: true, parentFileId: "root")
        let file = CloudEntry(fileId: "episode-13", fileName: "Show.S01E13.mkv", isDir: false, size: 100, parentFileId: "show", etag: "episode-13")
        let drive = MockScrapeDrive(tree: ["root": [folder], "show": [file]])
        let show = MatchInfo(kind: "tv", id: 777, title: "Show")
        let provider = MockScannerTmdb(movies: [:], shows: ["show": show], seasonCounts: [777: [1: 12, 2: 12]])
        let first = try await ScanPlanUpdater.scan(roots: [root], drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        let group = try XCTUnwrap(first.groups.first { $0.kind == "tv" })
        let edited = try await Scanner.replanGroup(plan: first, groupId: group.id, info: show, drive: drive, strategy: .splitSequential, tmdbProvider: provider)
        store.savePlan(edited)
        let second = try await ScanPlanUpdater.scan(roots: [root], drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertTrue(second.groups.contains { $0.episodeStrategy == EpisodeStrategy.splitSequential.rawValue })
        XCTAssertTrue(second.actions.contains { $0.fileId == file.fileId && $0.kind == "file" && $0.season == 2 && $0.episode == 1 })
    }

    @MainActor
    func testEditingRemainderDoesNotRewriteSubmittedAction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let original = makeSamplePlan(); store.savePlan(original)
        _ = store.markExecutionStarted(original, requested: ["a1"], runId: "run-A")
        var remainder = try XCTUnwrap(store.pendingPlans.first)
        remainder.actions[0].newName = "不应修改历史动作"
        remainder.actions[1].newName = "new-poster.jpg"
        store.savePendingPlan(remainder)
        let stored = try XCTUnwrap(store.plans.first)
        XCTAssertEqual(stored.actions.first { $0.id == "a1" }?.newName, original.actions[0].newName)
        XCTAssertEqual(stored.actions.first { $0.id == "a2" }?.newName, "new-poster.jpg")
        XCTAssertEqual(stored.submittedActionIds, ["a1"])
    }

    @MainActor
    func testChangedScanBindingRejectsExecutionBeforeCreatingTask() {
        var plan = makeSamplePlan(); plan.scanBinding = "previous-account-binding"
        let before = PlanAndTaskStore.shared.tasks.map(\.id)
        XCTAssertFalse(ExecutionEngine.shared.enqueueOrStart(plan: plan, drive: MockScrapeDrive(tree: [:])))
        XCTAssertEqual(PlanAndTaskStore.shared.tasks.map(\.id), before)
        XCTAssertTrue(ExecutionEngine.shared.lastStartError?.contains("账号") == true)
    }

    private actor ReadProbeDrive: CloudDrive {
        nonisolated let kind: ProviderKind = .p123
        nonisolated let accountId = "acct_1"
        var writes = 0
        func list(folderId: String) async throws -> [CloudEntry] { throw DriveError.network("读取失败") }
        func rename(fileId: String, newName: String) async throws -> String { writes += 1; return fileId }
        func mkdir(parentId: String, name: String) async throws -> String { writes += 1; return name }
        func move(fileId: String, destParentId: String) async throws -> String { writes += 1; return fileId }
        func upload(parentId: String, name: String, data: Data) async throws -> String { writes += 1; return name }
    }

    @MainActor
    func testReadFailureKeepsExistingPlanAndScanProxyRejectsWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir); store.savePlan(makeSamplePlan())
        let before = store.plans.map(\.id)
        let drive = ReadProbeDrive()
        do {
            _ = try await ScanPlanUpdater.scan(roots: [PlanRoot(folderId: "0", name: "")], drive: drive, store: store, preflightTmdb: false)
            XCTFail("读取失败不能提交")
        } catch { XCTAssertEqual(store.plans.map(\.id), before) }
        let proxy = ScanSnapshotDrive(drive)
        do { _ = try await proxy.rename(fileId: "x", newName: "y"); XCTFail("扫描代理不能写入") } catch { }
        let writes = await drive.writes; XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testPolicyConflictLeavesBothPendingPlansUntouched() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let source = makeSamplePlan()
        for (id, value) in [("left", true), ("right", false)] {
            var policy = PolicyOverride(); policy.renameFiles = value
            var plan = ScrapePlan(id: id, accountId: "mock-scrape-acct", provider: "123", createdAt: Date(), roots: [PlanRoot(folderId: id, name: id, parentId: "root")], groups: source.groups, actions: source.actions, flags: [], taskPolicy: policy)
            plan.reviewDisposition = "pending"; store.savePlan(plan)
        }
        let children = ["left", "right"].map { CloudEntry(fileId: $0, fileName: $0, isDir: true, parentFileId: "root") }
        do {
            _ = try await ScanPlanUpdater.scan(roots: [PlanRoot(folderId: "root", name: "影视", parentId: "0")], drive: MockScrapeDrive(tree: ["root": children]), store: store, preflightTmdb: false)
            XCTFail("不同策略必须选择")
        } catch let conflict as ScanPolicyConflict {
            XCTAssertEqual(conflict.options.count, 3)
            XCTAssertEqual(Set(store.plans.map(\.id)), ["left", "right"])
        }
    }

    private func sampleRun(total: Int, completed: Int, succeeded: Int) -> TaskRun {
        TaskRun(id: "history", planId: "plan_1", accountId: "acct_1", provider: "p123", sourceLabel: "测试",
            status: "done", total: total, completed: completed, succeeded: succeeded, failed: 0, message: "",
            startedAt: Date(), finishedAt: Date(), errors: [])
    }

    func testTvFolderRangePreservedOrHeldForManualStrategyReview() async throws {
        let show = MatchInfo(kind: "tv", id: 1396, title: "绝命毒师", year: "2008", posterPath: nil)
        let folder = CloudEntry(fileId: "show", fileName: "Breaking Bad", isDir: true, parentFileId: "0")
        let item = CloudEntry(fileId: "range", fileName: "Breaking.Bad.S01E01-E03.mkv", isDir: false, parentFileId: "show")
        let node = ScanTreeNode(entry: folder, items: [item], parent: nil, depth: 0)
        let drive = MockScrapeDrive(tree: ["show": [item]])
        let tmdb = MockScannerTmdb(movies: [:], shows: ["breaking": show], seasonCounts: [1396: [1: 7]])
        let hooks = ScannerTvAndBdmvHooks(
            planMovieFolder: { _, _, _, _, _, _, _, _, _, _ in 0 },
            planExtraMovie: { _, _, _, _, _, _, _, _ in },
            planArtwork: { _, _, _, _, _, _, _, _ in })
        for strategy in [EpisodeStrategy.original, .merge] {
            var actions: [PlanAction] = []
            var groups: [PlanGroup] = []
            var flags: [String] = []
            var taken: Set<String> = []
            _ = try await ScannerTvAndBdmv.planTvFolder(folder: folder, tree: [node], allVideos: [item], drive: drive, tmdb: tmdb,
                actions: &actions, groups: &groups, flags: &flags, rootTaken: &taken,
                forced: show, remembered: nil, doneId: nil, startIdx: 0, strategy: strategy, hooks: hooks)
            let action = try XCTUnwrap(actions.first(where: { $0.fileId == item.fileId }))
            if strategy == .original {
                XCTAssertTrue(action.newName.contains("S01E01-E03"))
            } else {
                XCTAssertEqual(action.op, "unmatched")
                XCTAssertFalse(action.selected)
                XCTAssertFalse(flags.isEmpty)
            }
        }
    }

    func testLoosePlannerPreservesEpisodeRange() async {
        let show = MatchInfo(kind: "tv", id: 1396, title: "绝命毒师", year: "2008", posterPath: nil)
        let item = CloudEntry(fileId: "range", fileName: "Show.S01E01-E03.mkv", isDir: false, parentFileId: "root")
        let tmdb = MockScannerTmdb(movies: [:], shows: ["show": show], seasonCounts: [:])
        var actions: [PlanAction] = []
        var groups: [PlanGroup] = []
        var flags: [String] = []
        var taken: Set<String> = [item.fileName.lowercased()]
        _ = await ScannerMovieLooseAndArtwork.planLooseFiles(
            dir: CloudEntry(fileId: "root", fileName: "电视剧", isDir: true), items: [item], tmdb: tmdb, fullScrape: false,
            actions: &actions, groups: &groups, flags: &flags, taken: &taken, forced: (item.fileId, show))
        XCTAssertTrue(actions.first(where: { $0.fileId == item.fileId })?.newName.contains("S01E01-E03") == true)
    }

    func testSeasonDirectoryPlannerPreservesEpisodeRangeAndSingleEpisode() {
        let items = [
            CloudEntry(fileId: "range", fileName: "Show.S01E01-E03.mkv", isDir: false, parentFileId: "season"),
            CloudEntry(fileId: "single", fileName: "Show.S01E04.mkv", isDir: false, parentFileId: "season")
        ]
        var actions: [PlanAction] = []
        var flags: [String] = []
        _ = ScannerMovieLooseAndArtwork.planDir(items: items,
            show: MatchInfo(kind: "tv", id: 1396, title: "绝命毒师", year: "2008", posterPath: nil),
            defaultSeason: 1, gid: "g", actions: &actions, flags: &flags)
        XCTAssertTrue(actions.first(where: { $0.fileId == "range" })?.newName.contains("S01E01-E03") == true)
        XCTAssertTrue(actions.first(where: { $0.fileId == "single" })?.newName.contains("S01E04") == true)
        XCTAssertTrue(flags.isEmpty)
    }

    // MARK: - Mock CloudDrive & Mock ScannerTmdbProvider

    private final class MockScrapeDrive: CloudDrive, @unchecked Sendable {
        let kind: ProviderKind = .p123
        let accountId: String = "mock-scrape-acct"
        let rootId: String = "0"
        let isLanEndpoint: Bool = false
        let trashSupport: TrashSupport = .recycle

        private let tree: [String: [CloudEntry]]

        init(tree: [String: [CloudEntry]]) {
            self.tree = tree
        }

        func list(folderId: String) async throws -> [CloudEntry] {
            tree[folderId] ?? []
        }

        func rename(fileId: String, newName: String) async throws -> String { fileId }
        func mkdir(parentId: String, name: String) async throws -> String { "dir_\(parentId)_\(name)" }
        func move(fileId: String, destParentId: String) async throws -> String { fileId }
        func upload(parentId: String, name: String, data: Data) async throws -> String { "up_\(name)" }
        func trash(fileId: String) async throws -> String { "ok" }
    }

    private struct MockScannerTmdb: ScannerTmdbProvider {
        let movies: [String: MatchInfo]
        let shows: [String: MatchInfo]
        let seasonCounts: [Int: [Int: Int]]

        func show(names: [String], fixedId: Int?) async -> (MatchInfo?, Int) {
            if let fixedId, let hit = shows.values.first(where: { $0.id == fixedId }) { return (hit, -1) }
            for (idx, n) in names.enumerated() {
                let lower = n.lowercased()
                if let hit = shows.first(where: { lower.contains($0.key.lowercased()) })?.value {
                    return (hit, idx)
                }
            }
            return (nil, -1)
        }

        func movie(stem: String, fallbackNames: [String], fallbackId: Int?) async -> MatchInfo? {
            if let fallbackId, let hit = movies.values.first(where: { $0.id == fallbackId }) { return hit }
            for n in [stem] + fallbackNames {
                let lower = n.lowercased()
                if let hit = movies.first(where: { lower.contains($0.key.lowercased()) })?.value {
                    return hit
                }
            }
            return nil
        }

        func movieInfo(id: Int) async -> MatchInfo? {
            movies.values.first(where: { $0.id == id })
        }

        func collectionOf(movieId: Int) async -> (Int, String)? { nil }
        func collectionPosterOf(movieId: Int, collectionId: Int) async -> String? { nil }
        func seasonCounts(showId: Int) async -> [Int: Int] { seasonCounts[showId] ?? [:] }
        func episodeGroupMap(groupId: String) async -> [EpisodeMapping.Episode: EpisodeMapping.Episode] { [:] }
    }

    // MARK: - 1. PlanStore 原子读写、绑定键与安全校验

    func testPlanStoreAtomicSaveLoadAndBindingValidation() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plan_store_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = PlanStore(plansDir: tmpDir)
        let plan = makeSamplePlan()

        let savedUrl = try store.save(plan, name: "scrape_test.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedUrl.path))

        let loaded = try store.loadNamed("scrape_test.json")
        XCTAssertEqual(loaded.id, plan.id)
        XCTAssertEqual(loaded.groups.count, plan.groups.count)
        XCTAssertEqual(loaded.actions.count, plan.actions.count)

        let key1 = store.key(plan)
        let key2 = store.key(loaded)
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1.count, 64)

        // forTask 账号不匹配应拒绝
        XCTAssertThrowsError(try store.forTask(
            planName: "scrape_test.json",
            expectedAccountId: "other-account",
            expectedPlanKey: key1,
            actionIds: ["a1"]
        ))

        // forTask 合法绑定应返回筛选后的计划
        let scoped = try store.forTask(
            planName: "scrape_test.json",
            expectedAccountId: plan.accountId,
            expectedPlanKey: key1,
            actionIds: ["a1"]
        )
        XCTAssertEqual(scoped.actions.map(\.id), ["a1", "a2"])
    }

    // MARK: - 2. ScannerTreeEngine 分类、旧产物检测与 M10 holderOf 守卫

    func testScannerTreeClassifyAndHolderOfGuard() {
        XCTAssertEqual(ScannerTreeEngine.seasonOfDir("Season 02"), 2)
        XCTAssertEqual(ScannerTreeEngine.seasonOfDir("Specials"), 0)
        XCTAssertEqual(ScannerTreeEngine.seasonOfDir("第3季"), 3)
        XCTAssertTrue(ScannerTreeEngine.ignoredDir("@eaDir"))
        XCTAssertTrue(ScannerTreeEngine.isCategoryDir("电影"))

        let items = [
            CloudEntry(fileId: "1", fileName: "movie.nfo", isDir: false, size: 100),
            CloudEntry(fileId: "2", fileName: "tvshow.nfo", isDir: false, size: 100),
            CloudEntry(fileId: "3", fileName: "Movie.mkv", isDir: false, size: 1_000_000),
        ]
        let stale = ScannerTreeEngine.staleArtifacts(items: items, newKind: "tv", matchChanged: true)
        XCTAssertTrue(stale.contains(where: { $0.fileName == "movie.nfo" }))
        XCTAssertFalse(stale.contains(where: { $0.fileName == "Movie.mkv" }))

        // M10 holderOf 守卫
        final class Node {
            let name: String
            weak var parent: Node?
            init(_ name: String, parent: Node? = nil) { self.name = name; self.parent = parent }
        }
        let root = Node("root")
        let child = Node("child", parent: root)
        let grand = Node("grand", parent: child)
        let holderRoot = ScannerTreeEngine.holderOf(node: root, root: root, parent: { (n: Node) in n.parent })
        let holderChild = ScannerTreeEngine.holderOf(node: child, root: root, parent: { (n: Node) in n.parent })
        let holderGrand = ScannerTreeEngine.holderOf(node: grand, root: root, parent: { (n: Node) in n.parent })
        XCTAssertNil(holderRoot)
        XCTAssertTrue(holderChild === child)
        XCTAssertTrue(holderGrand === child)
    }

    // MARK: - 3. EpisodeStrategyMapper 四种集序策略

    func testEpisodeStrategyMapperAllStrategies() throws {
        let eps = [
            EpisodeMapping.EpisodeKey(season: 1, episode: 1),
            EpisodeMapping.EpisodeKey(season: 1, episode: 13),
        ]
        let counts = [1: 12, 2: 12]

        let orig = try EpisodeStrategyMapper.map(strategy: .original, episodes: eps, seasonCounts: counts)
        XCTAssertEqual(orig, eps)

        let splitSeq = try EpisodeStrategyMapper.map(strategy: .splitSequential, episodes: eps, seasonCounts: counts)
        XCTAssertEqual(splitSeq[0], EpisodeMapping.EpisodeKey(season: 1, episode: 1))
        XCTAssertEqual(splitSeq[1], EpisodeMapping.EpisodeKey(season: 2, episode: 1))

        let splitAbs = try EpisodeStrategyMapper.map(strategy: .splitAbsolute, episodes: eps, seasonCounts: counts)
        XCTAssertEqual(splitAbs[1], EpisodeMapping.EpisodeKey(season: 2, episode: 13))

        let twoSeason = [
            EpisodeMapping.EpisodeKey(season: 1, episode: 1),
            EpisodeMapping.EpisodeKey(season: 2, episode: 1),
        ]
        let merged = try EpisodeStrategyMapper.map(strategy: .merge, episodes: twoSeason, seasonCounts: counts)
        XCTAssertEqual(merged[1], EpisodeMapping.EpisodeKey(season: 1, episode: 13))
    }

    // MARK: - 4. PlanSelection、PreviewTwoRowFilter 与 LibraryTarget 重叠检测

    func testPlanSelectionAndPreviewFilters() {
        var plan = makeSamplePlan()
        XCTAssertEqual(PlanSelection.groupState(plan: plan, groupId: "g1"), .all)

        plan = PlanSelection.set(plan: plan, ids: ["a1"], on: false)
        XCTAssertEqual(PlanSelection.groupState(plan: plan, groupId: "g1"), .some)

        plan = PlanSelection.setAll(plan: plan, on: false)
        XCTAssertEqual(PlanSelection.selectedIds(plan: plan).count, 0)

        let agg = PreviewTwoRowFilter.aggregate(plan: plan, state: PreviewTwoRowFilter.State())
        XCTAssertEqual(agg.statusCount(.all), plan.actions.count)

        let sections = PreviewSectionGrouping.sections(plan: plan, groups: plan.groups, bySource: false)
        XCTAssertFalse(sections.isEmpty)

        // LibraryTarget 路径重叠检测
        let t1 = LibraryTarget(accountId: "a1", folderId: "/Movies", path: "/Movies")
        let t2 = LibraryTarget(accountId: "a1", folderId: "/Movies/SciFi", path: "/Movies/SciFi", parentId: "/Movies", ancestors: ["/Movies"])
        XCTAssertTrue(LibraryTargets.overlap([t1, t2]))
    }

    // MARK: - 5. 模拟云盘端到端 Scanner.scan 与 Scanner.replanGroup

    func testScannerEndToEndScanAndReplanWithMockDrive() async throws {
        let drive = MockScrapeDrive(tree: [
            "root_movies": [
                CloudEntry(fileId: "m_dir", fileName: "Inception.2010.1080p", isDir: true, parentFileId: "root_movies"),
                CloudEntry(fileId: "t_dir", fileName: "Breaking.Bad.S01", isDir: true, parentFileId: "root_movies"),
            ],
            "m_dir": [
                CloudEntry(fileId: "m_vid", fileName: "Inception.2010.1080p.BluRay.mkv", isDir: false, size: 2_000_000_000, parentFileId: "m_dir"),
            ],
            "t_dir": [
                CloudEntry(fileId: "t_e1", fileName: "Breaking.Bad.S01E01.1080p.mkv", isDir: false, size: 1_000_000_000, parentFileId: "t_dir"),
                CloudEntry(fileId: "t_e2", fileName: "Breaking.Bad.S01E02.1080p.mkv", isDir: false, size: 1_000_000_000, parentFileId: "t_dir"),
            ],
        ])

        let tmdb = MockScannerTmdb(
            movies: [
                "inception": MatchInfo(kind: "movie", id: 27205, title: "盗梦空间", year: "2010", posterPath: "/p1.jpg", originalTitle: "Inception"),
            ],
            shows: [
                "breaking": MatchInfo(kind: "tv", id: 1396, title: "绝命毒师", year: "2008", posterPath: "/p2.jpg", originalTitle: "Breaking Bad"),
            ],
            seasonCounts: [1396: [1: 7]]
        )

        let root = PlanRoot(folderId: "root_movies", name: "影视库", parentId: "0")
        let plan = try await Scanner.scan(
            roots: [root],
            drive: drive,
            tmdbProvider: tmdb
        )

        XCTAssertFalse(plan.groups.isEmpty)
        XCTAssertTrue(plan.groups.contains(where: { $0.tmdbId == 27205 }))
        XCTAssertTrue(plan.groups.contains(where: { $0.tmdbId == 1396 }))

        if let movieGroup = plan.groups.first(where: { $0.tmdbId == 27205 }) {
            let newMatch = MatchInfo(kind: "movie", id: 157336, title: "星际穿越", year: "2014", posterPath: "/inter.jpg", originalTitle: "Interstellar")
            let replanned = try await Scanner.replanGroup(
                plan: plan,
                groupId: movieGroup.id,
                info: newMatch,
                drive: drive,
                tmdbProvider: tmdb
            )
            XCTAssertTrue(replanned.groups.contains(where: { $0.tmdbId == 157336 && $0.title == "星际穿越" }))
        }
    }

    // MARK: - Helpers

    private func makeSamplePlan(fileOperation: String = "rename") -> ScrapePlan {
        let g1 = PlanGroup(
            id: "g1",
            kind: "movie",
            tmdbId: 27205,
            title: "盗梦空间",
            year: "2010",
            posterPath: "/p1.jpg",
            folderId: "f1",
            folderName: "Inception.2010",
            folderNewName: "盗梦空间 (2010) {tmdb-27205}",
            rating: 8.4,
            confidence: "high",
            note: nil,
            warn: nil,
            actionIds: ["a1", "a2"]
        )
        let a1 = PlanAction(
            id: "a1",
            op: fileOperation,
            groupId: "g1",
            fileId: "vid1",
            parentId: "f1",
            oldName: "Inception.2010.mkv",
            newName: "盗梦空间 (2010).mkv",
            destParentId: nil,
            destRef: nil,
            kind: "file",
            mediaKind: "movie",
            tmdbId: 27205,
            season: nil,
            episode: nil,
            artworkUrl: nil,
            selected: true,
            done: false,
            error: nil,
            note: nil
        )
        let a2 = PlanAction(
            id: "a2",
            op: "artwork",
            groupId: "g1",
            fileId: nil,
            parentId: "f1",
            oldName: "",
            newName: "poster.jpg",
            destParentId: nil,
            destRef: nil,
            kind: "image",
            mediaKind: "movie",
            tmdbId: 27205,
            season: nil,
            episode: nil,
            artworkUrl: nil,
            selected: true,
            done: false,
            error: nil,
            note: nil
        )
        return ScrapePlan(
            id: "plan_1",
            accountId: "acct_1",
            provider: "123云盘",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            roots: [PlanRoot(folderId: "0", name: "根目录")],
            groups: [g1],
            actions: [a1, a2],
            flags: []
        )
    }
}
