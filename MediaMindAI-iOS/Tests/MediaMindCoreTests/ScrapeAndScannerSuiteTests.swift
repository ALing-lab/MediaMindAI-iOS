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
        XCTAssertEqual(scoped.actions.filter(\.selected).map(\.id), ["a1"])
    }

    // MARK: - 2. ScannerTreeEngine 分类、旧产物检测与 M10 holderOf 守卫

    func testScannerTreeClassifyAndHolderOfGuard() {
        XCTAssertEqual(ScannerTreeEngine.seasonOfDir("Season 02"), 2)
        XCTAssertEqual(ScannerTreeEngine.seasonOfDir("Specials"), 0)
        XCTAssertEqual(ScannerTreeEngine.seasonOfDir("第3季"), 3)
        XCTAssertTrue(ScannerTreeEngine.ignoredDir("@eaDir"))
        XCTAssertTrue(ScannerTreeEngine.isGenericDir("电影"))

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
        XCTAssertNil(ScannerTreeEngine.holderOf(node: root, root: root, parent: { $0.parent }))
        XCTAssertTrue(ScannerTreeEngine.holderOf(node: child, root: root, parent: { $0.parent }) === child)
        XCTAssertTrue(ScannerTreeEngine.holderOf(node: grand, root: root, parent: { $0.parent }) === child)
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

    private func makeSamplePlan() -> ScrapePlan {
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
            op: "rename",
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
