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

    func testWorkLogScopeSeparatesSameTitleAndPrefixCollisions() {
        var plan = makeSamplePlan()
        let movie = plan.groups[0]
        plan.groups.append(PlanGroup(id: "g2", kind: movie.kind, tmdbId: movie.tmdbId, title: movie.title, year: movie.year,
            posterPath: movie.posterPath, folderId: "f2", folderName: "Second", folderNewName: nil,
            rating: nil, confidence: nil, note: nil, warn: nil, actionIds: ["a10", "a1:backup"]))
        plan.actions += [videoAction(id: "a10", fileId: "vid2", groupId: "g2"),
                         videoAction(id: "a1:backup", fileId: "vid3", groupId: "g2")]
        let scope = TaskLogScope(plan: plan, groupId: "g1")
        XCTAssertTrue(scope.contains(actionId: "a1"))
        XCTAssertTrue(scope.contains(actionId: "a2"))
        XCTAssertFalse(scope.contains(actionId: "a10"))
        XCTAssertFalse(scope.contains(actionId: "a10:finalize"))
        XCTAssertFalse(scope.contains(actionId: "a1:backup"), "完整动作 ID 的归属优先于后缀推断")
        XCTAssertFalse(scope.contains(actionId: "substitution:a1:backup"))
        XCTAssertTrue(TaskLogScope(plan: plan, groupId: "g2").contains(actionId: "substitution:a1:backup"))
        XCTAssertFalse(scope.contains(actionId: "a1-other"))
    }

    func testWorkLogScopeIncludesOnlyItsDirectoryDependenciesAndDerivedSteps() {
        var plan = sharedDirectoryPlan()
        plan.actions.append(PlanAction(id: "work-B", op: "move", groupId: "g2", fileId: "vid-B", parentId: "f1",
            oldName: "B.mkv", newName: "B.mkv", destParentId: nil, destRef: "mkdir-B", kind: "file", mediaKind: "movie",
            tmdbId: 42, season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil))
        let scope = TaskLogScope(plan: plan, groupId: "g2")
        for id in ["work-B", "mkdir-B", "category", "category:finalize", "work-B:backup", "substitution:work-B", "substitution-name:work-B"] {
            XCTAssertTrue(scope.contains(actionId: id), id)
        }
        for id in ["rename-A", "mkdir-A", "mkdir-A:finalize", "undo-root", "backup-root:0"] {
            XCTAssertFalse(scope.contains(actionId: id), id)
        }
    }

    func testWorkLogScopeStaysOnExecutionSnapshotAndMissingScopeDoesNotShowAll() {
        var plan = makeSamplePlan()
        let snapshot = plan.executionSnapshot(actionIds: ["a1"])
        plan.actions = [videoAction(id: "later", fileId: "new-video")]
        let scope = TaskLogScope(plan: snapshot, groupId: "g1")
        XCTAssertTrue(scope.contains(actionId: "a1"))
        XCTAssertFalse(scope.contains(actionId: "a2"))
        XCTAssertFalse(scope.contains(actionId: "later"))
        XCTAssertFalse(TaskLogScope(plan: nil, groupId: "g1").contains(actionId: "a1"))
        XCTAssertFalse(TaskLogScope(plan: snapshot, groupId: "missing").contains(actionId: "a1"))
    }

    @MainActor
    func testSubmittedWorkWithOnlyDisabledRemainderDoesNotLeaveEmptyCard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        var plan = makeSamplePlan(); plan.actions[1].enabled = false; plan.actions[1].selected = false
        store.savePlan(plan)
        let begun = store.markExecutionStarted(plan, requested: ["a1"], runId: "cancelled-run")
        XCTAssertEqual(begun.reviewDisposition, "started")
        var run = sampleRun(total: 1, completed: 0, succeeded: 0); run.status = "stopped"
        run.executionSnapshot = plan.executionSnapshot(actionIds: ["a1"]); store.saveTask(run)
        XCTAssertTrue(store.pendingPlans.isEmpty)
        XCTAssertTrue(store.pendingProjection(begun).groups.isEmpty)
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.plans[0].actions.count, 2)
    }

    func testLegacyTaskControlDecodesWithoutUnverifiedAssetFields() throws {
        let previous = TaskControl(taskId: "old", accountId: "acct", mode: "undo", state: "needs_backup_choice", acceptedSubstitutions: ["poster:backup"])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
        json.removeValue(forKey: "unverifiedAssetIds")
        json.removeValue(forKey: "acceptedUnverifiedAssetIds")
        let loaded = try JSONDecoder().decode(TaskControl.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(loaded.unverifiedAssetIds.isEmpty)
        XCTAssertTrue(loaded.acceptedUnverifiedAssetIds.isEmpty)
        XCTAssertEqual(loaded.acceptedSubstitutions, ["poster:backup"])
    }

    @MainActor
    func testUnverifiedAssetConsentPersistsAndMergesAcrossChoices() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("asset-choice-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let taskId = UUID().uuidString
        let previous = TaskControl(taskId: taskId, accountId: "acct", mode: "undo", state: "needs_asset_choice",
            acceptedSubstitutions: ["poster:backup"], unverifiedAssetIds: ["row-second"], acceptedUnverifiedAssetIds: ["row-first"])
        try JSONEncoder().encode([taskId: previous]).write(to: url)
        let controls = TaskCancellation(storageURL: url)
        let loaded = try XCTUnwrap(controls.controls[taskId])
        XCTAssertEqual(loaded.state, "needs_asset_choice")
        XCTAssertEqual(loaded.unverifiedAssetIds, ["row-second"])
        let requested = try controls.request(taskId: taskId, accountId: "acct", undo: true,
            acceptedUnverifiedAssetIds: ["row-second", "row-first"])
        XCTAssertEqual(requested.state, "requested")
        XCTAssertEqual(requested.acceptedUnverifiedAssetIds, ["row-first", "row-second"])
        XCTAssertEqual(requested.acceptedSubstitutions, ["poster:backup"])
        let reloaded = TaskCancellation(storageURL: url)
        XCTAssertEqual(reloaded.controls[taskId]?.acceptedUnverifiedAssetIds, requested.acceptedUnverifiedAssetIds)
        XCTAssertThrowsError(try reloaded.request(taskId: taskId, accountId: "acct", undo: true), "requested / undoing不可重复提交")
    }

    @MainActor
    func testFix8StartedPlanRecoversUnsubmittedUnmatchedSourceAfterReload() throws {
        for useSnapshot in [false, true] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = PlanAndTaskStore(storageURL: dir)
            var plan = makeSamplePlan()
            plan.reviewDisposition = "started"
            plan.groups[0].kind = "tv"
            plan.actions[1].enabled = false
            plan.actions[1].selected = false
            plan.actions.append(videoAction(id: "pending-episode", fileId: "vid2", operation: "unmatched"))
            if useSnapshot {
                var run = sampleRun(total: 1, completed: 1, succeeded: 1)
                run.executionSnapshot = plan.executionSnapshot(actionIds: ["a1"])
                store.saveTask(run)
            } else { plan.submittedActionIds = ["a1"] }
            store.savePlan(plan)
            let reloaded = PlanAndTaskStore(storageURL: dir)
            let recovered = try XCTUnwrap(reloaded.pendingPlans.first)
            XCTAssertEqual(recovered.id, plan.id)
            XCTAssertEqual(recovered.reviewDisposition, "pending")
            XCTAssertEqual(recovered.groups.map(\.id), ["g1"])
            XCTAssertEqual(recovered.manualMatchActions(groupId: "g1").map(\.id), ["pending-episode"])
            XCTAssertTrue(recovered.submittedActionIds?.contains("a1") == true)
            XCTAssertFalse(recovered.actions.first { $0.id == "a1" }!.selected)
            XCTAssertTrue(ExecutionEngine.executableActionIds(plan: recovered).isEmpty)
            var edited = recovered
            edited.actions.removeAll { $0.id == "pending-episode" }
            edited.actions.append(videoAction(id: "recognized-episode", fileId: "vid2"))
            try reloaded.saveEditedPlan(edited, original: recovered)
            let afterEdit = PlanAndTaskStore(storageURL: dir)
            if useSnapshot { afterEdit.deleteTask(id: "history") }
            let ready = try XCTUnwrap(PlanAndTaskStore(storageURL: dir).pendingPlans.first)
            XCTAssertTrue(ready.submittedActionIds?.contains("a1") == true, "迁移后删除旧历史仍保留提交证据")
            XCTAssertEqual(ExecutionEngine.executableActionIds(plan: ready), ["recognized-episode"])
            XCTAssertFalse(ExecutionEngine.executableActionIds(plan: ready).contains("a1"))
            let begun = afterEdit.markExecutionStarted(ready, requested: ["recognized-episode"], runId: "next")
            XCTAssertEqual(begun.reviewDisposition, "started")
            XCTAssertTrue(afterEdit.pendingPlans.isEmpty, "已提交作品的禁用素材残留不能再生成空卡片")
        }
    }

    @MainActor
    func testFix8StartedRecoveryRejectsUntrustedScopeAndSubmittedSources() throws {
        for evidence in ["absent", "empty", "stale", "same-source", "disabled-only", "done-unmatched", "wrong-account"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = PlanAndTaskStore(storageURL: dir)
            var plan = makeSamplePlan()
            plan.reviewDisposition = "started"
            plan.actions[1].enabled = false
            plan.actions[1].selected = false
            if !["absent", "empty", "wrong-account"].contains(evidence) { plan.submittedActionIds = evidence == "stale" ? ["not-in-plan"] : ["a1"] }
            if evidence == "empty" { plan.submittedActionIds = [] }
            if evidence != "disabled-only" {
                var unmatched = videoAction(id: "pending", fileId: evidence == "same-source" ? "vid1" : "vid2", operation: "unmatched")
                unmatched.done = evidence == "done-unmatched"
                plan.actions.append(unmatched)
            }
            if evidence == "wrong-account" {
                let source = sampleRun(total: 1, completed: 1, succeeded: 1)
                var run = TaskRun(id: source.id, planId: plan.id, accountId: "different-account", provider: source.provider,
                    sourceLabel: source.sourceLabel, status: source.status, total: 1, completed: 1, succeeded: 1, failed: 0,
                    message: "", startedAt: Date(), finishedAt: Date(), errors: [])
                run.executionSnapshot = plan.executionSnapshot(actionIds: ["a1"])
                store.saveTask(run)
            }
            store.savePlan(plan)
            XCTAssertTrue(PlanAndTaskStore(storageURL: dir).pendingPlans.isEmpty, evidence)
        }
    }

    @MainActor
    func testFix8RecoveryDoesNotExposeCancelledOrActivePlan() throws {
        for status in ["cancelled", "running", "paused", "queued"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = PlanAndTaskStore(storageURL: dir)
            var plan = makeSamplePlan()
            plan.reviewDisposition = status == "cancelled" ? "cancelled" : "started"
            plan.submittedActionIds = ["a1"]
            plan.actions.append(videoAction(id: "pending", fileId: "vid2", operation: "unmatched"))
            store.savePlan(plan)
            if status == "queued" {
                let item = TaskQueue.shared.enqueue(plan: plan)
                defer { TaskQueue.shared.remove(id: item.id) }
                XCTAssertTrue(PlanAndTaskStore(storageURL: dir).pendingPlans.isEmpty)
            } else {
                if status != "cancelled" {
                    var run = sampleRun(total: 1, completed: 0, succeeded: 0)
                    run.status = status
                    store.saveTask(run)
                }
                XCTAssertTrue(PlanAndTaskStore(storageURL: dir).pendingPlans.isEmpty, status)
            }
        }
    }

    @MainActor
    func testOldPersistedGhostCardIsHiddenWithoutRemovingHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        var plan = makeSamplePlan()
        plan.reviewDisposition = "pending"; plan.submittedActionIds = ["a1"]
        plan.actions[1].enabled = false; plan.actions[1].selected = false
        store.savePlan(plan)
        let reloaded = PlanAndTaskStore(storageURL: dir)
        XCTAssertTrue(reloaded.pendingPlans.isEmpty)
        XCTAssertEqual(reloaded.plans[0].actions.map(\.id), ["a1", "a2"])
        XCTAssertEqual(reloaded.plans[0].submittedActionIds, ["a1"])
    }

    @MainActor
    func testUnselectedRemainderAndUntouchedDisabledWorkStayEditable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        var plan = makeSamplePlan(); plan.actions[1].selected = false
        store.savePlan(plan)
        let begun = store.markExecutionStarted(plan, requested: ["a1"], runId: "run")
        XCTAssertEqual(begun.reviewDisposition, "pending")
        XCTAssertEqual(store.pendingPlans.count, 1, "未勾选不等于禁用或取消")
        var untouched = makeSamplePlan()
        for index in untouched.actions.indices { untouched.actions[index].enabled = false; untouched.actions[index].selected = false }
        let untouchedStore = PlanAndTaskStore(storageURL: dir.appendingPathComponent("untouched"))
        untouchedStore.savePlan(untouched)
        XCTAssertEqual(untouchedStore.pendingPlans.count, 1, "尚未提交的作品仍允许在预览调整策略")
    }

    @MainActor
    func testUnsubmittedDisabledVideoInPartiallySubmittedGroupStaysVisible() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        var plan = makeSamplePlan(); plan.actions[1].enabled = false
        var otherVideo = videoAction(id: "another-video", fileId: "vid2")
        otherVideo.enabled = false; otherVideo.selected = false
        plan.actions.append(otherVideo); store.savePlan(plan)
        _ = store.markExecutionStarted(plan, requested: ["a1"], runId: "run")
        let remainder = try XCTUnwrap(store.pendingPlans.first)
        XCTAssertEqual(remainder.groups.map(\.id), ["g1"])
        XCTAssertEqual(remainder.manualMatchActions(groupId: "g1").map(\.fileId), ["vid2"])
    }

    @MainActor
    func testSubmittedGroupKeepsUnmatchedFilesForManualRecognition() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        var plan = makeSamplePlan(); plan.actions[1].enabled = false
        plan.actions.append(videoAction(id: "unmatched-episode", fileId: "vid2", operation: "unmatched"))
        store.savePlan(plan)
        _ = store.markExecutionStarted(plan, requested: ["a1"], runId: "run")
        let remainder = try XCTUnwrap(store.pendingPlans.first)
        XCTAssertEqual(remainder.groups.map(\.id), ["g1"])
        XCTAssertEqual(remainder.manualMatchActions(groupId: "g1").map(\.id), ["unmatched-episode"])
    }

    @MainActor
    func testCancellingPendingPlanDoesNotLeaveAnEditablePreview() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let plan = makeSamplePlan(); store.savePlan(plan)
        let original = try XCTUnwrap(store.pendingPlans.first)
        store.cancelPendingPlan(id: plan.id)
        XCTAssertNil(store.pendingPlans.first { $0.id == plan.id })
        XCTAssertThrowsError(try store.saveEditedPlan(original, original: original))
        XCTAssertEqual(store.plans.first?.reviewDisposition, "cancelled")
        XCTAssertTrue(store.tasks.isEmpty)
    }

    @MainActor
    func testScanPropagatesDiscoveredRootParentToFolderRename() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let video = CloudEntry(fileId: "episode", fileName: "Show.S01E01.mkv", isDir: false, size: 100, parentFileId: "show")
        let drive = MockScrapeDrive(tree: ["show": [video]], parents: ["show": "parent", "parent": "0"])
        let provider = MockScannerTmdb(movies: [:], shows: ["show": MatchInfo(kind: "tv", id: 777, title: "Show", year: "2020")], seasonCounts: [:])
        let plan = try await ScanPlanUpdater.scan(roots: [PlanRoot(folderId: "show", name: "Raw Show")],
            drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertEqual(plan.roots.first?.parentId, "parent")
        XCTAssertEqual(plan.scanParents?["show"], "parent")
        let rename = try XCTUnwrap(plan.actions.first { $0.op == "rename" && $0.kind == "folder" && $0.fileId == "show" })
        XCTAssertEqual(rename.parentId, "parent")
    }

    func testExplicitEmptyRootParentIsPreservedAndUnknownParentIsNotInvented() async throws {
        let video = CloudEntry(fileId: "episode", fileName: "Show.S01E01.mkv", isDir: false, parentFileId: "show")
        let provider = MockScannerTmdb(movies: [:], shows: ["show": MatchInfo(kind: "tv", id: 777, title: "Show", year: "2020")], seasonCounts: [:])
        let parents: [String?] = ["", nil]
        for parent in parents {
            let plan = try await Scanner.scan(roots: [PlanRoot(folderId: "show", name: "Show", parentId: parent)],
                drive: MockScrapeDrive(tree: ["show": [video]]), tmdbProvider: provider,
                globalPolicies: DefaultPolicies(), persistResult: false)
            let rename = try XCTUnwrap(plan.actions.first { $0.op == "rename" && $0.kind == "folder" && $0.fileId == "show" })
            XCTAssertEqual(rename.parentId, parent)
            XCTAssertEqual(plan.roots[0].parentId, parent)
        }
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

    func testManualMatchTargetsExcludeSubmittedSourceEvenWithDifferentActionId() {
        var plan = makeSamplePlan()
        let remaining = videoAction(id: "remaining", fileId: "vid2")
        plan.actions += [plan.actions[0].withId("same-source-new-id"), remaining]
        plan.submittedActionIds = ["a1"]
        XCTAssertEqual(plan.manualMatchActions(groupId: "g1").map(\.id), ["remaining"])
        plan.actions[plan.actions.count - 1].done = true
        XCTAssertTrue(plan.manualMatchActions(groupId: "g1").isEmpty)
    }

    @MainActor
    func testPendingEditRejectsSubmittedSourceRecreatedWithNewId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let original = makeSamplePlan(); store.savePlan(original)
        _ = store.markExecutionStarted(original, requested: ["a1"], runId: "history")
        let remainder = try XCTUnwrap(store.pendingPlans.first)
        var edited = remainder
        edited.actions += [original.actions[0].withId("new-id-for-submitted-video")]
        XCTAssertThrowsError(try store.saveEditedPlan(edited, original: remainder))
        store.savePendingPlan(edited)
        XCTAssertEqual(store.plans[0].actions.filter { $0.fileId == "vid1" }.map(\.id), ["a1"])
        XCTAssertEqual(store.plans[0].actions.count, original.actions.count)
    }

    @MainActor
    func testLegacySnapshotReservationsReachManualMatchProjection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let original = makeSamplePlan(); store.savePlan(original)
        var run = sampleRun(total: 1, completed: 0, succeeded: 0)
        run.executionSnapshot = original.executionSnapshot(actionIds: ["a1"])
        store.saveTask(run)
        let projected = store.pendingProjection(original)
        XCTAssertEqual(projected.submittedActionIds, ["a1"])
        XCTAssertTrue(projected.manualMatchActions(groupId: "g1").isEmpty)
    }

    func testReplanRejectsSubmittedFileAndWholeGroupBeforeReadingCloud() async throws {
        var plan = makeSamplePlan(); plan.submittedActionIds = ["a1"]
        let drive = MockScrapeDrive(tree: [:], accountId: plan.accountId)
        let info = MatchInfo(kind: "movie", id: 27205, title: "盗梦空间", year: "2010")
        let provider = MockScannerTmdb(movies: [:], shows: [:], seasonCounts: [:])
        let hooks = ScannerMovieLooseAndArtwork.makeReplanHooks(drive: drive, tmdb: provider, fullScrape: false)
        do {
            _ = try await ScannerReplan.replanFile(plan: plan, actionId: "a1", info: info, cloud: drive, hooks: hooks)
            XCTFail("已提交且未完成的文件不能重新规划")
        } catch let error as ScannerReplanError {
            if case .fileAlreadyProcessed = error { } else { XCTFail("错误类型不符：\(error)") }
        }
        do {
            _ = try await ScannerReplan.replanGroup(plan: plan, groupId: "g1", info: info, cloud: drive, hooks: hooks)
            XCTFail("含历史范围的整组不能全量重建")
        } catch let error as ScannerReplanError {
            if case .alreadyExecuted = error { } else { XCTFail("错误类型不符：\(error)") }
        }
    }

    @MainActor
    func testUnsubmittedVideoCanStillBeRematchedAndSaved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        var original = makeSamplePlan()
        original.actions.append(videoAction(id: "remaining", fileId: "vid2"))
        original.groups[0].actionIds.append("remaining")
        store.savePlan(original)
        _ = store.markExecutionStarted(original, requested: ["a1"], runId: "history")
        let remainder = try XCTUnwrap(store.pendingPlans.first)
        let drive = MockScrapeDrive(tree: ["f1": [CloudEntry(fileId: "vid2", fileName: "Video.mkv", isDir: false, parentFileId: "f1")]], accountId: original.accountId)
        let info = MatchInfo(kind: "movie", id: 27205, title: "盗梦空间", year: "2010")
        let provider = MockScannerTmdb(movies: [:], shows: [:], seasonCounts: [:])
        let hooks = ScannerMovieLooseAndArtwork.makeReplanHooks(drive: drive, tmdb: provider, fullScrape: false)
        let edited = try await ScannerReplan.replanFile(plan: remainder, actionId: "remaining", info: info, cloud: drive, hooks: hooks)
        try store.saveEditedPlan(edited, original: remainder)
        XCTAssertEqual(store.plans[0].actions.first { $0.id == "a1" }, original.actions[0])
        XCTAssertTrue(store.plans[0].actions.contains { $0.fileId == "vid2" && $0.tmdbId == 27205 })
        XCTAssertEqual(store.plans[0].actions.filter { $0.fileId == "vid1" }.count, 1)
    }

    func testRemainderExecutionRestoresOnlyRequiredDirectoryChain() throws {
        let plan = sharedDirectoryPlan()
        let selected = ExecutionEngine.executableActionIds(plan: plan)
        let prepared = try ExecutionEngine.preparedExecution(plan: plan, actionIds: selected, appliedDirectoryIds: [])
        XCTAssertEqual(prepared.actionIds, ["category", "mkdir-B", "move-B"])
        XCTAssertFalse(prepared.actionIds.contains("rename-A"))
        XCTAssertFalse(prepared.actionIds.contains("mkdir-A"))
        let snapshot = prepared.plan.executionSnapshot(actionIds: prepared.actionIds)
        XCTAssertEqual(snapshot.actions.count, 3)
        XCTAssertFalse(snapshot.actions.contains { $0.fileId == "vid1" })
    }

    func testAppliedSharedDirectoryIsReusedAndRevertedDoneDirectoryIsRebuilt() throws {
        var plan = sharedDirectoryPlan()
        plan.actions[0].done = true
        let selected = ExecutionEngine.executableActionIds(plan: plan)
        let reused = try ExecutionEngine.preparedExecution(plan: plan, actionIds: selected, appliedDirectoryIds: ["category"])
        XCTAssertEqual(reused.actionIds, ["mkdir-B", "move-B"])
        let rebuilt = try ExecutionEngine.preparedExecution(plan: plan, actionIds: selected, appliedDirectoryIds: [])
        XCTAssertEqual(rebuilt.actionIds, ["category", "mkdir-B", "move-B"])
        XCTAssertFalse(try XCTUnwrap(rebuilt.plan.actions.first { $0.id == "category" }).done)
    }

    func testDirectoryReuseIsScopedToPlanRunsAndExcludesRevertedWal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("directory-wal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let wal = ReversibleWalStore(storageURL: url)
        let plan = sharedDirectoryPlan()
        let record = try wal.prepare(taskId: "other-plan-run", accountId: plan.accountId, actionId: "category",
            operation: "mkdir", before: nil, after: RemoteSnapshot(id: "directory", parent: "0", name: "category", directory: true))
        try wal.change(record, state: "applied")
        XCTAssertTrue(ExecutionEngine.reusableDirectoryIds(plan: plan, runIds: [], wal: wal).isEmpty)
        XCTAssertTrue(ExecutionEngine.reusableDirectoryIds(plan: plan, runIds: ["this-plan-run"], wal: wal).isEmpty)
        XCTAssertEqual(ExecutionEngine.reusableDirectoryIds(plan: plan, runIds: ["other-plan-run"], wal: wal), ["category"])
        var rescanned = plan; rescanned.scanPriorRunIds = ["other-plan-run"]
        XCTAssertTrue(ExecutionEngine.reusableDirectoryIds(plan: rescanned, runIds: ["other-plan-run"], wal: wal).isEmpty)
        try wal.reverted(record, undoResult: nil)
        XCTAssertTrue(ExecutionEngine.reusableDirectoryIds(plan: plan, runIds: ["other-plan-run"], wal: wal).isEmpty)
    }

    @MainActor
    func testChangedLibraryDirectoryGetsFreshIdentityAcrossRepeatedScans() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let savedPolicies = AppSettings.shared.policies
        defer { AppSettings.shared.policies = savedPolicies }
        var policies = DefaultPolicies()
        policies.adaptiveDirectory = true
        policies.adaptiveTargetDirId = "library-A"; policies.adaptiveTargetDirPath = "/A"
        AppSettings.shared.policies = policies
        let folder = CloudEntry(fileId: "movie", fileName: "Inception", isDir: true, parentFileId: "source")
        let file = CloudEntry(fileId: "video", fileName: "Inception.2010.mkv", isDir: false, size: 100, parentFileId: "movie", etag: "unchanged")
        let drive = MockScrapeDrive(tree: ["source": [folder], "movie": [file]])
        let provider = MockScannerTmdb(movies: ["inception": MatchInfo(kind: "movie", id: 27205, title: "盗梦空间", year: "2010")], shows: [:], seasonCounts: [:])
        let roots = [PlanRoot(folderId: "source", name: "电影", parentId: "0")]
        let first = try await ScanPlanUpdater.scan(roots: roots, drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        let oldDirectory = try XCTUnwrap(first.actions.first { $0.kind == AdaptiveDirectoryPlanner.kindCategoryMkdir })
        _ = store.markExecutionStarted(first, requested: [oldDirectory.id], runId: "library-A-run")
        var oldRun = TaskRun(id: "library-A-run", planId: first.id, accountId: first.accountId, provider: first.provider,
            sourceLabel: "A", status: "done", total: 1, completed: 1, succeeded: 1, failed: 0, message: "",
            startedAt: Date(), finishedAt: Date(), errors: [])
        oldRun.executionSnapshot = first.executionSnapshot(actionIds: [oldDirectory.id]); store.saveTask(oldRun)
        let wal = ReversibleWalStore(storageURL: dir.appendingPathComponent("old-library-wal.json"))
        let record = try wal.prepare(taskId: "library-A-run", accountId: first.accountId, actionId: oldDirectory.id,
            operation: "mkdir", before: nil, after: RemoteSnapshot(id: "old-category", parent: "library-A", name: "电影", directory: true))
        try wal.change(record, state: "applied")
        var completedDirectoryPlan = try XCTUnwrap(store.plans.first)
        let directoryIndex = try XCTUnwrap(completedDirectoryPlan.actions.firstIndex { $0.id == oldDirectory.id })
        completedDirectoryPlan.actions[directoryIndex].done = true
        store.savePlan(completedDirectoryPlan)
        // 同一语义保留旧 ID 供历史重试，但当前列表已无目录时，旧完成日志不能阻止重建。
        let missingAgain = try await ScanPlanUpdater.scan(roots: roots, drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        let rebuiltDirectory = try XCTUnwrap(missingAgain.actions.first { $0.kind == AdaptiveDirectoryPlanner.kindCategoryMkdir })
        XCTAssertEqual(rebuiltDirectory.id, oldDirectory.id)
        XCTAssertFalse(rebuiltDirectory.done)
        let directoryIds = ExecutionEngine.reusableDirectoryIds(plan: missingAgain, runIds: ["library-A-run"], wal: wal)
        XCTAssertTrue(directoryIds.isEmpty)
        let dependent = try XCTUnwrap(missingAgain.actions.first { $0.destRef == rebuiltDirectory.id })
        let prepared = try ExecutionEngine.preparedExecution(plan: missingAgain, actionIds: [dependent.id], appliedDirectoryIds: directoryIds)
        XCTAssertTrue(prepared.actionIds.contains(oldDirectory.id))
        policies.adaptiveTargetDirId = "library-B"; policies.adaptiveTargetDirPath = "/B"
        AppSettings.shared.policies = policies
        var scanStore = store
        for iteration in 0..<2 {
            if iteration == 1 {
                scanStore.deleteTask(id: "library-A-run")
                scanStore = PlanAndTaskStore(storageURL: dir)
            }
            let refreshed = try await ScanPlanUpdater.scan(roots: roots, drive: drive, store: scanStore, tmdbProvider: provider, preflightTmdb: false)
            let directory = try XCTUnwrap(refreshed.actions.first { $0.kind == AdaptiveDirectoryPlanner.kindCategoryMkdir })
            XCTAssertEqual(directory.parentId, "library-B")
            XCTAssertNotEqual(directory.id, oldDirectory.id)
            XCTAssertTrue(refreshed.submittedActionIds?.contains(oldDirectory.id) == true)
            XCTAssertFalse(refreshed.submittedActionIds?.contains(directory.id) == true)
            XCTAssertTrue(refreshed.actions.contains { $0.destRef == directory.id })
            XCTAssertFalse(refreshed.actions.contains { $0.destRef == oldDirectory.id })
            XCTAssertTrue(ExecutionEngine.reusableDirectoryIds(plan: refreshed, runIds: ["library-A-run"], wal: wal).isEmpty)
            let actionIds = Set(refreshed.actions.map(\.id))
            XCTAssertTrue(refreshed.actions.allSatisfy { $0.destRef.map { actionIds.contains($0) } ?? true })
            XCTAssertTrue(refreshed.groups.allSatisfy { Set($0.actionIds).isSubset(of: actionIds) })
        }
        XCTAssertEqual(scanStore.plans.count, 1)
    }

    func testQueuedScopeGainsOnlyDirectoryDependenciesAtStart() throws {
        var plan = sharedDirectoryPlan()
        let queuedIds = ExecutionEngine.executableActionIds(plan: plan)
        // 排队后出现的新作品即使勾选，也不能扩入原队列的影片范围。
        plan.actions.append(videoAction(id: "later-video", fileId: "vid3"))
        let fixedIds = ExecutionEngine.executableActionIds(plan: plan, requested: queuedIds)
        let prepared = try ExecutionEngine.preparedExecution(plan: plan, actionIds: fixedIds, appliedDirectoryIds: [])
        XCTAssertEqual(prepared.actionIds, ["category", "mkdir-B", "move-B"])
        XCTAssertFalse(prepared.actionIds.contains("later-video"))
        XCTAssertFalse(prepared.actionIds.contains("rename-A"))
    }

    func testInvalidDirectoryDependenciesAreRejectedWithoutChangingPlan() throws {
        let original = sharedDirectoryPlan()
        var disabled = original; disabled.actions[0].enabled = false
        XCTAssertThrowsError(try ExecutionEngine.preparedExecution(plan: disabled, actionIds: ["move-B"], appliedDirectoryIds: []))
        var missing = original; missing.actions.removeAll { $0.id == "category" }
        XCTAssertThrowsError(try ExecutionEngine.preparedExecution(plan: missing, actionIds: ["move-B"], appliedDirectoryIds: []))
        var cyclic = original; cyclic.actions[0].destParentId = nil; cyclic.actions[0].destRef = "mkdir-B"
        XCTAssertThrowsError(try ExecutionEngine.preparedExecution(plan: cyclic, actionIds: ["move-B"], appliedDirectoryIds: []))
        XCTAssertEqual(original.actions.filter(\.selected).map(\.id), ["mkdir-B", "move-B"])
    }

    @MainActor
    func testBdmvWithExtrasAndDirectVideoCommitsWithoutPlanningProtectedVideos() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let movie = CloudEntry(fileId: "disc", fileName: "Disc Movie", isDir: true, parentFileId: "root")
        let bdmv = CloudEntry(fileId: "bdmv", fileName: "BDMV", isDir: true, parentFileId: "disc")
        let extras = CloudEntry(fileId: "extras", fileName: "Extras", isDir: true, parentFileId: "disc")
        let trailer = CloudEntry(fileId: "trailer", fileName: "trailer.mkv", isDir: false, parentFileId: "disc")
        let bonus = CloudEntry(fileId: "bonus", fileName: "bonus.mkv", isDir: false, parentFileId: "extras")
        let drive = MockScrapeDrive(tree: ["root": [movie], "disc": [bdmv, extras, trailer], "extras": [bonus]])
        let provider = MockScannerTmdb(movies: ["disc": MatchInfo(kind: "movie", id: 1234, title: "Disc Movie", year: "2020")], shows: [:], seasonCounts: [:])
        let roots = [PlanRoot(folderId: "root", name: "电影", parentId: "0")]
        let first = try await ScanPlanUpdater.scan(roots: roots, drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertTrue(first.groups.contains { $0.folderId == "disc" && $0.kind == "movie" })
        XCTAssertFalse(first.actions.contains { ["trailer", "bonus"].contains($0.fileId ?? "") })
        XCTAssertNil(first.scanListings?["extras"])
        let second = try await ScanPlanUpdater.scan(roots: roots, drive: drive, store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.plans.count, 1)
        // 原盘内部不做逐文件核验，沿用 fix7 的保守确认边界，不声称可自动继承身份。
        XCTAssertTrue(second.groups.contains { $0.folderId == "disc" && $0.confirmRequired })
        XCTAssertTrue(second.actions.allSatisfy { !$0.selected })
    }

    @MainActor
    func testUnmatchedBdmvStillProducesProtectedManualGroup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let bdmv = CloudEntry(fileId: "bdmv", fileName: "BDMV", isDir: true, parentFileId: "disc")
        let trailer = CloudEntry(fileId: "trailer", fileName: "trailer.mkv", isDir: false, parentFileId: "disc")
        let provider = MockScannerTmdb(movies: [:], shows: [:], seasonCounts: [:])
        let plan = try await ScanPlanUpdater.scan(roots: [PlanRoot(folderId: "disc", name: "Unknown Disc", parentId: "0")],
            drive: MockScrapeDrive(tree: ["disc": [bdmv, trailer]]), store: store, tmdbProvider: provider, preflightTmdb: false)
        XCTAssertTrue(plan.groups.contains { $0.folderId == "disc" && $0.kind == "unmatched" })
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertEqual(store.pendingPlans.count, 1)
    }

    @MainActor
    func testOrdinaryUnplannedVideoStillRejectsWholeScan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanAndTaskStore(storageURL: dir)
        let season = CloudEntry(fileId: "season", fileName: "Season 01", isDir: true, parentFileId: "0")
        let video = CloudEntry(fileId: "episode", fileName: "Unknown.S01E01.mkv", isDir: false, parentFileId: "season")
        let provider = MockScannerTmdb(movies: [:], shows: [:], seasonCounts: [:])
        do {
            _ = try await ScanPlanUpdater.scan(roots: [PlanRoot(folderId: "0", name: "根目录")],
                drive: MockScrapeDrive(tree: ["0": [season], "season": [video]]), store: store, tmdbProvider: provider, preflightTmdb: false)
            XCTFail("普通目录不能绕过完整性保护")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("部分源视频未进入识别计划"))
            XCTAssertTrue(store.plans.isEmpty)
        }
    }

    private func videoAction(id: String, fileId: String, operation: String = "rename", groupId: String = "g1") -> PlanAction {
        PlanAction(id: id, op: operation, groupId: groupId, fileId: fileId, parentId: "f1",
            oldName: "Video.mkv", newName: "Video (2020).mkv", destParentId: nil, destRef: nil,
            kind: "file", mediaKind: "movie", tmdbId: 27205, season: nil, episode: nil, artworkUrl: nil,
            selected: true, done: false, error: nil, note: nil)
    }

    private func sharedDirectoryPlan() -> ScrapePlan {
        func mkdir(_ id: String, parentRef: String? = nil, selected: Bool) -> PlanAction {
            PlanAction(id: id, op: "mkdir", groupId: id == "category" ? "" : "g1", fileId: nil, parentId: "0",
                oldName: "", newName: id, destParentId: parentRef == nil ? "0" : nil, destRef: parentRef,
                kind: "folder", mediaKind: "movie", tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                selected: selected, done: false, error: nil, note: nil)
        }
        var plan = makeSamplePlan()
        var historical = videoAction(id: "rename-A", fileId: "vid1"); historical.selected = false
        let move = PlanAction(id: "move-B", op: "move", groupId: "g1", fileId: "vid2", parentId: "f1",
            oldName: "B.mkv", newName: "B.mkv", destParentId: nil, destRef: "mkdir-B", kind: "file",
            mediaKind: "movie", tmdbId: 27205, season: nil, episode: nil, artworkUrl: nil,
            selected: true, done: false, error: nil, note: nil)
        plan.actions = [mkdir("category", selected: false), mkdir("mkdir-A", parentRef: "category", selected: false), historical,
                        mkdir("mkdir-B", parentRef: "category", selected: true), move]
        plan.submittedActionIds = ["category", "mkdir-A", "rename-A"]
        return plan
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

    func testScannerCreatesEnabledEpisodeAssetsFromPolicyWithoutManualConfiguration() async throws {
        let video = CloudEntry(fileId: "episode", fileName: "Show.S01E01.mkv", isDir: false, size: 100, parentFileId: "show")
        let provider = MockScannerTmdb(movies: [:], shows: ["show": MatchInfo(kind: "tv", id: 777, title: "Show")], seasonCounts: [777: [1: 10]])
        for enabled in [true, false] {
            var policies = DefaultPolicies(); policies.episodeNfo = enabled; policies.episodeThumb = enabled
            let plan = try await Scanner.scan(roots: [PlanRoot(folderId: "show", name: "Show", parentId: "0")],
                drive: MockScrapeDrive(tree: ["show": [video]]), tmdbProvider: provider, globalPolicies: policies, persistResult: false)
            let assets = plan.actions.filter { $0.kind == "episode_nfo" || ($0.kind == "image" && $0.episode != nil) }
            XCTAssertEqual(assets.count, enabled ? 2 : 0)
            XCTAssertTrue(assets.allSatisfy { $0.enabled && $0.selected && $0.episode == 1 && $0.tmdbId == 777 })
            if enabled {
                let file = try XCTUnwrap(plan.actions.first { $0.kind == "file" && $0.fileId == video.fileId && $0.op != "move" })
                let stem = MediaParser.splitNameExt(file.newName).0
                XCTAssertEqual(Set(assets.map(\.newName)), [stem + ".nfo", stem + "-thumb.jpg"])
                XCTAssertTrue(assets.allSatisfy { $0.destRef != nil || $0.destParentId != nil })
            }
        }
    }

    func testManualReplanCreatesEpisodeAssetsWithoutChangingUnrelatedGroup() async throws {
        let video = CloudEntry(fileId: "episode", fileName: "Show.S01E01.mkv", isDir: false, size: 100, parentFileId: "show")
        let show = MatchInfo(kind: "tv", id: 777, title: "Show")
        let provider = MockScannerTmdb(movies: [:], shows: ["show": show], seasonCounts: [777: [1: 10]])
        let drive = MockScrapeDrive(tree: ["show": [video]])
        var off = DefaultPolicies(); off.episodeNfo = false; off.episodeThumb = false
        var plan = try await Scanner.scan(roots: [PlanRoot(folderId: "show", name: "Show", parentId: "0")],
            drive: drive, tmdbProvider: provider, globalPolicies: off, persistResult: false)
        let group = try XCTUnwrap(plan.groups.first { $0.kind == "tv" })
        plan.taskPolicy = PolicyOverride(downloadEpisodeThumb: true, episodeNfo: true)
        let other = PlanGroup(id: "unrelated", kind: "tv", tmdbId: 888, title: "Other", year: "", posterPath: nil,
            folderId: "other", folderName: "Other", folderNewName: nil, rating: nil, confidence: "高", note: nil, warn: nil, actionIds: ["other-file"])
        let otherAction = PlanAction(id: "other-file", op: "skip", groupId: other.id, fileId: "other-episode", parentId: "other",
            oldName: "Other.S01E01.mkv", newName: "Other.S01E01.mkv", destParentId: nil, destRef: nil, kind: "file", mediaKind: "tv",
            tmdbId: 888, season: 1, episode: 1, artworkUrl: nil, selected: false, done: false, error: nil, note: nil)
        plan.groups.append(other); plan.actions.append(otherAction)
        let updated = try await Scanner.replanGroup(plan: plan, groupId: group.id, info: show, drive: drive, tmdbProvider: provider)
        XCTAssertEqual(updated.actions.filter { $0.groupId == group.id && ($0.kind == "episode_nfo" || ($0.kind == "image" && $0.episode != nil)) }.count, 2)
        XCTAssertEqual(updated.actions.filter { $0.groupId == other.id }, [otherAction])
    }

    // MARK: - Mock CloudDrive & Mock ScannerTmdbProvider

    private final class MockScrapeDrive: CloudDrive, @unchecked Sendable {
        let kind: ProviderKind = .p123
        let accountId: String
        let rootId: String = "0"
        let isLanEndpoint: Bool = false
        let trashSupport: TrashSupport = .recycle

        private let tree: [String: [CloudEntry]]
        private let parents: [String: String]

        init(tree: [String: [CloudEntry]], accountId: String = "mock-scrape-acct", parents: [String: String] = [:]) {
            self.tree = tree
            self.accountId = accountId
            self.parents = parents
        }

        func list(folderId: String) async throws -> [CloudEntry] {
            tree[folderId] ?? []
        }
        func parentIdOf(fileId: String) async throws -> String? { parents[fileId] }

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
