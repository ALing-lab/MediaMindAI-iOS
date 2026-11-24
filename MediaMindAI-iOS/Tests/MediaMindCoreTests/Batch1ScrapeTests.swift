import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 第 1 批（data/scrape/ 1:1 逐行直译）独立单元测试套件：
/// 覆盖 PlanSelection、EpisodeStrategy、ManualConfirmation、PreviewTwoRowFilter、PreviewSectionGrouping、
/// LibraryDestination、LibraryTargets、EpisodeAssets、DuplicateRetentionPlanner 与 ScannerHeuristics。
final class Batch1ScrapeTests: XCTestCase {

    private final class StubDrive: CloudDrive, @unchecked Sendable {
        let kind: ProviderKind = .webdav
        let accountId: String = "acc-b1"
        let rootId: String = "/"
        var listings: [String: [CloudEntry]] = [:]

        func list(folderId: String) async throws -> [CloudEntry] { listings[folderId] ?? [] }
        func rename(fileId: String, newName: String) async throws -> String { fileId }
        func mkdir(parentId: String, name: String) async throws -> String { DrivePaths.join(parent: parentId, name: name) }
        func move(fileId: String, destParentId: String) async throws -> String { fileId }
        func upload(parentId: String, name: String, data: Data) async throws -> String { DrivePaths.join(parent: parentId, name: name) }
    }

    private func makeAction(
        id: String,
        op: String,
        groupId: String = "g1",
        fileId: String? = nil,
        parentId: String? = "/root",
        oldName: String = "a.mkv",
        newName: String = "A.mkv",
        destParentId: String? = nil,
        destRef: String? = nil,
        kind: String = "file",
        season: Int? = nil,
        episode: Int? = nil,
        selected: Bool = true,
        enabled: Bool = true
    ) -> PlanAction {
        PlanAction(
            id: id, op: op, groupId: groupId, fileId: fileId, parentId: parentId,
            oldName: oldName, newName: newName, destParentId: destParentId, destRef: destRef,
            kind: kind, mediaKind: "movie", tmdbId: 100, season: season, episode: episode,
            artworkUrl: nil, selected: selected, enabled: enabled, done: false, error: nil, note: nil
        )
    }

    func testPlanSelectionDependencyPropagationAndSharedMkdir() {
        let mk = makeAction(id: "mk1", op: "mkdir", groupId: "", newName: "电影", kind: AdaptiveDirectoryPlanner.kindCategoryMkdir, selected: true)
        let mv = makeAction(id: "mv1", op: "move", groupId: "g1", fileId: "/root/M1", destRef: "mk1", kind: AdaptiveDirectoryPlanner.kindAdaptiveMove, selected: true)
        let art = makeAction(id: "art1", op: "artwork", groupId: "g1", newName: "poster.jpg", destRef: "mk1", kind: "image", selected: true)
        let plan = ScrapePlan(id: "p", accountId: "a", provider: "webdav", createdAt: Date(), roots: [], groups: [], actions: [mk, mv, art], flags: [])

        // 取消 mkdir 自动级联取消依赖它的 move 和 artwork
        let unchecked = PlanSelection.set(plan: plan, ids: ["mk1"], on: false)
        XCTAssertTrue(unchecked.actions.allSatisfy { !$0.selected })

        // 重新勾选 move 自动补齐依赖的 mkdir
        let rechecked = PlanSelection.set(plan: unchecked, ids: ["mv1"], on: true)
        XCTAssertTrue(rechecked.actions.first(where: { $0.id == "mk1" })?.selected == true)
        XCTAssertTrue(rechecked.actions.first(where: { $0.id == "mv1" })?.selected == true)
        XCTAssertEqual(PlanSelection.selectedIds(plan: rechecked), ["mk1", "mv1"])
    }

    func testEpisodeStrategySplitSequentialAbsoluteAndMerge() throws {
        let eps = [
            EpisodeMapping.EpisodeKey(season: 1, episode: 1),
            EpisodeMapping.EpisodeKey(season: 1, episode: 13),
            EpisodeMapping.EpisodeKey(season: 0, episode: 1),
        ]
        let counts = [1: 12, 2: 12]

        let seq = try EpisodeStrategyMapper.map(strategy: .splitSequential, episodes: eps, seasonCounts: counts)
        XCTAssertEqual(seq[0], EpisodeMapping.EpisodeKey(season: 1, episode: 1))
        XCTAssertEqual(seq[1], EpisodeMapping.EpisodeKey(season: 2, episode: 1))
        XCTAssertEqual(seq[2], EpisodeMapping.EpisodeKey(season: 0, episode: 1)) // 特别篇不变

        let absSplit = try EpisodeStrategyMapper.map(strategy: .splitAbsolute, episodes: eps, seasonCounts: counts)
        XCTAssertEqual(absSplit[1], EpisodeMapping.EpisodeKey(season: 2, episode: 13))

        let merged = try EpisodeStrategyMapper.map(strategy: .merge, episodes: [EpisodeMapping.EpisodeKey(season: 2, episode: 3)], seasonCounts: counts)
        XCTAssertEqual(merged[0], EpisodeMapping.EpisodeKey(season: 1, episode: 15))
    }

    func testManualConfirmationGateBlocksYearAndTmdbContradictions() {
        let g = PlanGroup(id: "g1", kind: "movie", tmdbId: 999, title: "盗梦空间", year: "2010", posterPath: nil, folderId: "/d", folderName: "Inception (2022) {tmdb-123}", folderNewName: nil, rating: nil, confidence: "中", note: nil, warn: nil, actionIds: ["a1"])
        let a = makeAction(id: "a1", op: "rename", groupId: "g1", fileId: "/d/a.mkv", oldName: "Inception.mkv", newName: "盗梦空间 (2010).mkv", selected: true)
        let plan = ScrapePlan(id: "p", accountId: "a", provider: "123", createdAt: Date(), roots: [], groups: [g], actions: [a], flags: [])

        let gated = ManualConfirmation.applyGate(to: plan, standardSpec: true)
        XCTAssertTrue(gated.groups[0].confirmRequired)
        XCTAssertGreaterThanOrEqual(gated.groups[0].confirmReasons.count, 2)
        XCTAssertFalse(gated.actions[0].selected) // 自动取消勾选阻止写入
    }

    func testPreviewTwoRowFilterAndSectionGrouping() {
        let g1 = PlanGroup(id: "g1", kind: "movie", tmdbId: 1, title: "流浪地球", year: "2019", posterPath: nil, folderId: "/r/m1", folderName: "m1", folderNewName: nil, rating: nil, confidence: "高", note: nil, warn: nil, actionIds: ["a1"], sourceRootId: "/r")
        let g2 = PlanGroup(id: "g2", kind: "unmatched", tmdbId: nil, title: "神秘视频", year: "", posterPath: nil, folderId: "/r/u1", folderName: "u1", folderNewName: nil, rating: nil, confidence: nil, note: nil, warn: nil, actionIds: ["a2"], sourceRootId: "/r")
        let a1 = makeAction(id: "a1", op: "rename", groupId: "g1", selected: true)
        let a2 = makeAction(id: "a2", op: "unmatched", groupId: "g2", selected: false)
        let plan = ScrapePlan(id: "p", accountId: "a", provider: "webdav", createdAt: Date(), roots: [PlanRoot(folderId: "/r", name: "电影库")], groups: [g1, g2], actions: [a1, a2], flags: [])

        let summaryAll = PreviewTwoRowFilter.aggregate(plan: plan, state: PreviewTwoRowFilter.State())
        XCTAssertEqual(summaryAll.statusCount(.all), 2)
        XCTAssertEqual(summaryAll.statusCount(.matched), 1)
        XCTAssertEqual(summaryAll.statusCount(.unmatched), 1)
        XCTAssertEqual(summaryAll.opCount("rename").label, "1/1")

        let stUnmatched = PreviewTwoRowFilter.selectStatus(PreviewTwoRowFilter.State(status: .all, op: "rename"), .unmatched)
        XCTAssertNil(stUnmatched.op) // 未匹配状态自动清除操作筛选
        let sections = PreviewSectionGrouping.sections(plan: plan, groups: [g1, g2], bySource: false)
        XCTAssertEqual(sections.map(\.title), ["电影", "待手动确认"])
    }

    func testLibraryDestinationTargetsAndEpisodeAssets() throws {
        XCTAssertTrue(LibraryTargets.overlap([
            LibraryTarget(accountId: "a", folderId: "/Movies", path: "/Movies"),
            LibraryTarget(accountId: "a", folderId: "/Movies/Action", path: "/Movies/Action"),
        ]))
        XCTAssertFalse(LibraryTargets.overlap([
            LibraryTarget(accountId: "a", folderId: "/Movies", path: "/Movies"),
            LibraryTarget(accountId: "a", folderId: "/TV", path: "/TV"),
        ]))

        let g = PlanGroup(id: "g1", kind: "tv", tmdbId: 1399, title: "权力的游戏", year: "2011", posterPath: nil, folderId: "/Inbox/GOT", folderName: "GOT", folderNewName: "权力的游戏 (2011) {tmdb-1399}", rating: nil, confidence: "高", note: nil, warn: nil, actionIds: ["f1"])
        let f1 = makeAction(id: "f1", op: "rename", groupId: "g1", fileId: "/Inbox/GOT/E01.mkv", parentId: "/Inbox/GOT", oldName: "E01.mkv", newName: "权力的游戏 - S01E01 {tmdb-1399}.mkv", season: 1, episode: 1)
        let plan = ScrapePlan(id: "p", accountId: "a", provider: "webdav", createdAt: Date(), roots: [], groups: [g], actions: [f1], flags: [])

        let moved = try LibraryDestination.set(plan: plan, groupId: "g1", targetId: "/Library/TV", targetPath: "/Library/TV")
        XCTAssertTrue(moved.actions.contains(where: { $0.kind == LibraryDestination.kind && $0.destParentId == "/Library/TV" }))

        let withAssets = try EpisodeAssets.configure(plan: moved, groupId: "g1", nfo: true, thumbnails: true)
        XCTAssertTrue(withAssets.actions.contains(where: { $0.kind == "episode_nfo" }))
        XCTAssertTrue(withAssets.actions.contains(where: { $0.newName.hasSuffix("-thumb.jpg") }))
    }

    func testDuplicateRetentionPlannerAndScannerHeuristics() async {
        let drive = StubDrive()
        let md5 = "0123456789abcdef0123456789abcdef"
        drive.listings["/d"] = [
            CloudEntry(fileId: "f1", fileName: "Movie (2020).mkv", isDir: false, size: 5000, contentHash: md5, hashAlgorithm: "MD5"),
            CloudEntry(fileId: "f2", fileName: "Movie_copy.mkv", isDir: false, size: 5000, contentHash: md5, hashAlgorithm: "MD5"),
        ]
        var policies = DefaultPolicies()
        policies.autoMoveConfirmedDuplicates = true

        let g = PlanGroup(id: "g1", kind: "movie", tmdbId: 55, title: "Movie", year: "2020", posterPath: nil, folderId: "/d", folderName: "Movie", folderNewName: nil, rating: nil, confidence: "高", note: nil, warn: nil, actionIds: ["a1", "a2"])
        let a1 = makeAction(id: "a1", op: "rename", groupId: "g1", fileId: "f1", parentId: "/d", oldName: "Movie (2020).mkv", newName: "Movie (2020).mkv")
        let a2 = makeAction(id: "a2", op: "rename", groupId: "g1", fileId: "f2", parentId: "/d", oldName: "Movie_copy.mkv", newName: "Movie (2020).mkv")
        let plan = ScrapePlan(id: "p", accountId: "acc-b1", provider: "webdav", createdAt: Date(), roots: [], groups: [g], actions: [a1, a2], flags: [])

        let planned = await DuplicateRetentionPlanner.apply(plan: plan, policies: policies, drive: drive)
        XCTAssertEqual(planned.actions.filter { $0.kind == DuplicateRetentionPlanner.kindRetentionDuplicate }.count, 1)
        XCTAssertEqual(planned.actions.first(where: { $0.id == "a2" })?.enabled, false)

        // ScannerHeuristics
        XCTAssertEqual(ScannerHeuristics.seasonOfDir("Season 02"), 2)
        XCTAssertEqual(ScannerHeuristics.seasonOfDir("第3季"), 3)
        XCTAssertEqual(ScannerHeuristics.seasonOfDir("Specials"), 0)
        XCTAssertEqual(ScannerHeuristics.classify(folderName: "电影", kids: []), .container)
        XCTAssertEqual(ScannerHeuristics.classify(folderName: "权力的游戏", kids: [CloudEntry(fileId: "s1", fileName: "Season 01", isDir: true)]), .title)
        XCTAssertTrue(ScannerHeuristics.folderTitleMismatch(folderName: "流浪地球", matchedTitle: "星际穿越"))
        XCTAssertFalse(ScannerHeuristics.folderTitleMismatch(folderName: "流浪地球", matchedTitle: "流浪地球2"))
    }
}
