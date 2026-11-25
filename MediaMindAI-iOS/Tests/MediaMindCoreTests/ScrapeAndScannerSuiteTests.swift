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
