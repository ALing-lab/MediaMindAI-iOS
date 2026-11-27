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

    private func episodeAssetPlan(actions: [PlanAction]) -> ScrapePlan {
        let group = PlanGroup(id: "g1", kind: "tv", tmdbId: 1399, title: "Show", year: "2020", posterPath: nil,
            folderId: "/show", folderName: "Show", folderNewName: nil, rating: nil, confidence: "高", note: nil, warn: nil,
            actionIds: actions.map(\.id))
        return ScrapePlan(id: "episode-plan", accountId: "a", provider: "webdav", createdAt: Date(), roots: [], groups: [group], actions: actions, flags: [])
    }

    func testEpisodePolicyCreatesMissingAssetsAndTracksDisabledOrganizing() throws {
        let video = makeAction(id: "video", op: "rename", fileId: "/show/S01E01.mkv", parentId: "/show",
            oldName: "S01E01.mkv", newName: "Show.S01E01.mkv", season: 1, episode: 1)
        let mkdir = makeAction(id: "season", op: "mkdir", parentId: "/show", oldName: "", newName: "Season 01", kind: "folder", season: 1)
        let move = makeAction(id: "move", op: "move", fileId: video.fileId, parentId: "/show", oldName: video.oldName,
            newName: video.newName, destRef: mkdir.id, season: 1, episode: 1)
        var plan = episodeAssetPlan(actions: [video, mkdir, move])
        var global = DefaultPolicies(); global.episodeNfo = false; global.episodeThumb = false
        plan.taskPolicy = PolicyOverride(fullScrape: true, downloadEpisodeThumb: true, episodeNfo: true)
        let enabled = PolicyResolver.applyOverrides(to: plan, global: global)
        let assets = enabled.actions.filter { $0.op == "artwork" }
        XCTAssertEqual(assets.count, 2)
        XCTAssertTrue(assets.allSatisfy { $0.enabled && $0.selected && $0.destRef == mkdir.id && $0.parentId == nil && $0.replaceExisting })
        let finalVideo = try XCTUnwrap(enabled.actions.first { $0.id == video.id })
        XCTAssertEqual(Set(assets.map(\.newName)), [MediaParser.splitNameExt(finalVideo.newName).0 + ".nfo", MediaParser.splitNameExt(finalVideo.newName).0 + "-thumb.jpg"])
        let repeated = PolicyResolver.applyOverrides(to: enabled, global: global)
        XCTAssertEqual(repeated.actions.map(\.id), enabled.actions.map(\.id))
        XCTAssertEqual(Set(repeated.groups[0].actionIds), Set(repeated.actions.map(\.id)))

        var scrapeOnly = enabled
        scrapeOnly.taskPolicy = PolicyOverride(renameFiles: false, seasonFolders: false, downloadEpisodeThumb: true, episodeNfo: true)
        let originalLocation = PolicyResolver.applyOverrides(to: scrapeOnly, global: global)
        let sidecars = originalLocation.actions.filter { $0.op == "artwork" }
        XCTAssertEqual(sidecars.map(\.id), assets.map(\.id))
        XCTAssertTrue(sidecars.allSatisfy { $0.enabled && $0.selected && $0.destRef == nil && $0.destParentId == "/show" })
        XCTAssertEqual(Set(sidecars.map(\.newName)), ["S01E01.nfo", "S01E01-thumb.jpg"])
        XCTAssertTrue(sidecars.allSatisfy { !$0.replaceExisting })
        var disabled = originalLocation; disabled.taskPolicy = PolicyOverride(scrapeEnabled: false)
        let off = PolicyResolver.applyOverrides(to: disabled, global: global)
        XCTAssertTrue(off.actions.filter { $0.op == "artwork" }.allSatisfy { !$0.enabled && !$0.selected })
    }

    func testEpisodeAssetsPreserveSubmittedSourcesAndAllowOtherEpisodes() throws {
        let first = makeAction(id: "first", op: "rename", fileId: "/show/1.mkv", parentId: "/show",
            oldName: "1.mkv", newName: "Show.S01E01.mkv", season: 1, episode: 1)
        let second = makeAction(id: "second", op: "rename", fileId: "/show/2.mkv", parentId: "/show",
            oldName: "2.mkv", newName: "Show.S01E02.mkv", season: 1, episode: 2)
        var plan = episodeAssetPlan(actions: [first, second])
        plan = try EpisodeAssets.configure(plan: plan, groupId: "g1", nfo: true, thumbnails: false)
        let firstAssetId = try XCTUnwrap(plan.actions.first { $0.kind == "episode_nfo" && $0.episode == 1 }?.id)
        plan.submittedActionIds = [first.id, firstAssetId]
        let frozenIds = Set([first.id, firstAssetId])
        let frozenActions = plan.actions.filter { frozenIds.contains($0.id) }
        let updated = try EpisodeAssets.configure(plan: plan, groupId: "g1", nfo: true, thumbnails: true)
        XCTAssertEqual(updated.actions.filter { frozenIds.contains($0.id) }, frozenActions)
        XCTAssertEqual(updated.actions.filter { $0.op == "artwork" && $0.episode == 1 }.count, 1)
        XCTAssertEqual(updated.actions.filter { $0.op == "artwork" && $0.episode == 2 }.count, 2)
        XCTAssertTrue(updated.actions.filter { $0.op == "artwork" && $0.episode == 2 }.allSatisfy(\.selected))
    }

    func testEpisodeAssetsPreserveMetadataAndDoNotSelectUnconfirmedOrUnmatchedSources() throws {
        let video = PlanAction(id: "mapped", op: "rename", groupId: "g1", fileId: "v", parentId: "/show",
            oldName: "S01E13.mkv", newName: "Show.S02E01.mkv", destParentId: nil, destRef: nil, kind: "file", mediaKind: "tv",
            tmdbId: 1399, season: 2, episode: 1, artworkUrl: nil, selected: true, done: false, error: nil, note: nil,
            metadataSeason: 1, metadataEpisode: 13)
        let unknown = makeAction(id: "unknown", op: "unmatched", fileId: "u", season: 2, episode: 2)
        var plan = episodeAssetPlan(actions: [video, unknown]); plan.groups[0].confirmRequired = true
        let generated = try EpisodeAssets.configure(plan: plan, groupId: "g1", nfo: true, thumbnails: true)
        let assets = generated.actions.filter { $0.op == "artwork" }
        XCTAssertEqual(assets.count, 2)
        XCTAssertTrue(assets.allSatisfy { !$0.selected && $0.metadataSeason == 1 && $0.metadataEpisode == 13 })
        XCTAssertTrue(assets.allSatisfy { $0.season == 2 && $0.episode == 1 })
    }

    func testEpisodeVersionsHaveStableDistinctSidecarsAndUseUnselectedSourceLocation() throws {
        var a = makeAction(id: "a", op: "rename", fileId: "a", parentId: "/show", oldName: "raw1080.mkv", newName: "Show.S01E01.1080p.mkv", season: 1, episode: 1)
        let b = makeAction(id: "b", op: "rename", fileId: "b", parentId: "/show", oldName: "raw2160.mkv", newName: "Show.S01E01.2160p.mkv", season: 1, episode: 1)
        let plan = episodeAssetPlan(actions: [a, b])
        let generated = try EpisodeAssets.configure(plan: plan, groupId: "g1", nfo: true, thumbnails: true)
        XCTAssertEqual(generated.actions.filter { $0.op == "artwork" }.count, 4)
        XCTAssertEqual(Set(generated.actions.map(\.id)).count, generated.actions.count)
        let again = try EpisodeAssets.configure(plan: generated, groupId: "g1", nfo: true, thumbnails: true)
        XCTAssertEqual(again.actions.map(\.id), generated.actions.map(\.id))
        a.selected = false
        let move = makeAction(id: "move", op: "move", fileId: "a", parentId: "/show", destRef: "disabled-season", season: 1, episode: 1, selected: false)
        let unselected = try EpisodeAssets.configure(plan: episodeAssetPlan(actions: [a, move]), groupId: "g1", nfo: true, thumbnails: true)
        XCTAssertTrue(unselected.actions.filter { $0.op == "artwork" }.allSatisfy { !$0.selected && $0.destRef == nil && $0.destParentId == "/show" })
        XCTAssertEqual(Set(unselected.actions.filter { $0.op == "artwork" }.map(\.newName)), ["raw1080.nfo", "raw1080-thumb.jpg"])
    }

    func testSubmittedSidecarDoesNotFreezeSameNamedEpisodeInDifferentDirectory() throws {
        for legacy in [false, true] {
            let a = makeAction(id: "a", op: "skip", fileId: "/A/Show.S01E01.mkv", parentId: "/A", oldName: "Show.S01E01.mkv", newName: "Show.S01E01.mkv", season: 1, episode: 1)
            let b = makeAction(id: "b", op: "skip", fileId: "/B/Show.S01E01.mkv", parentId: "/B", oldName: a.oldName, newName: a.newName, season: 1, episode: 1)
            let c = makeAction(id: "c", op: "skip", fileId: "/B/Show.S01E02.mkv", parentId: "/B", oldName: "Show.S01E02.mkv", newName: "Show.S01E02.mkv", season: 1, episode: 2)
            var plan = episodeAssetPlan(actions: [a, b, c])
            if legacy {
                plan.actions.append(makeAction(id: "legacy-a", op: "artwork", parentId: "/A", oldName: "", newName: "Show.S01E01.nfo", kind: "episode_nfo", season: 1, episode: 1))
                plan.actions.append(makeAction(id: "legacy-b", op: "artwork", parentId: "/B", oldName: "", newName: "Show.S01E01.nfo", kind: "episode_nfo", season: 1, episode: 1))
            } else { plan = try EpisodeAssets.configure(plan: plan, groupId: "g1", nfo: true, thumbnails: false) }
            let savedA = try XCTUnwrap(plan.actions.first { $0.kind == "episode_nfo" && $0.parentId == "/A" })
            plan.submittedActionIds = [savedA.id]
            let updated = try EpisodeAssets.configure(plan: plan, groupId: "g1", nfo: true, thumbnails: true)
            XCTAssertEqual(updated.actions.first { $0.id == savedA.id }, savedA)
            XCTAssertEqual(updated.actions.filter { $0.op == "artwork" && $0.parentId == "/B" && $0.episode == 1 }.count, 2)
            XCTAssertEqual(updated.actions.filter { $0.op == "artwork" && $0.parentId == "/B" && $0.episode == 2 }.count, 2)
        }
    }

    func testEpisodeAssetsExcludeDuplicateMovedToRetentionZone() throws {
        let main = makeAction(id: "main", op: "rename", fileId: "main-file", parentId: "/show", oldName: "main.mkv", newName: "Show.S01E01.mkv", season: 1, episode: 1)
        let duplicate = makeAction(id: "duplicate", op: "rename", fileId: "duplicate-file", parentId: "/copy", oldName: "copy.mkv", newName: "Copy.S01E01.mkv", season: 1, episode: 1, selected: false, enabled: false)
        var plan = try EpisodeAssets.configure(plan: episodeAssetPlan(actions: [main, duplicate]), groupId: "g1", nfo: true, thumbnails: true)
        plan.actions.append(makeAction(id: "retention", op: "move", fileId: duplicate.fileId, parentId: "/copy", destRef: "retention-dir", kind: DuplicateRetentionPlanner.kindRetentionDuplicate))
        let updated = try EpisodeAssets.configure(plan: plan, groupId: "g1", nfo: true, thumbnails: true)
        let assets = updated.actions.filter { $0.op == "artwork" }
        XCTAssertEqual(assets.count, 2)
        XCTAssertTrue(assets.allSatisfy { $0.parentId == "/show" && $0.selected })
        XCTAssertTrue(updated.actions.contains { $0.id == "retention" && $0.selected })
        var onlyDuplicate = plan
        onlyDuplicate.actions.removeAll { $0.id == main.id || ($0.op == "artwork" && $0.parentId == "/show") }
        let cleaned = try EpisodeAssets.configure(plan: onlyDuplicate, groupId: "g1", nfo: true, thumbnails: true)
        XCTAssertFalse(cleaned.actions.contains { $0.op == "artwork" })
    }

    func testScopedMediaSwitchOffOnPersistsIndependentlyForTaskAndFilm() throws {
        let fields: [WritableKeyPath<MediaDefaults, Bool>] = [\.nfo, \.poster, \.fanart, \.logo]
        var global = DefaultPolicies()
        global.movie = MediaDefaults(nfo: true, poster: true, fanart: true, logo: true)
        global.tv = global.movie
        for filmLayer in [false, true] {
            let upper: PolicyOverride? = filmLayer ? PolicyOverride(renameFiles: false) : nil
            let base = global.applying(upper)
            for isTv in [false, true] {
                for field in fields {
                    var draft = base
                    if isTv { draft.tv[keyPath: field] = false } else { draft.movie[keyPath: field] = false }
                    let off = try JSONDecoder().decode(PolicyOverride.self, from: JSONEncoder().encode(draft.diffOverride(from: base)))
                    var reopened = base.applying(off)
                    XCTAssertFalse((isTv ? reopened.tv : reopened.movie)[keyPath: field])
                    XCTAssertTrue((isTv ? reopened.movie : reopened.tv)[keyPath: field])
                    if isTv { reopened.tv[keyPath: field] = true } else { reopened.movie[keyPath: field] = true }
                    let on = try JSONDecoder().decode(PolicyOverride.self, from: JSONEncoder().encode(reopened.diffOverride(from: base)))
                    let reloaded = base.applying(on)
                    XCTAssertTrue(reloaded.tv[keyPath: field]); XCTAssertTrue(reloaded.movie[keyPath: field])
                    let effective = PolicyResolver.resolve(isTv: isTv, global: global,
                        task: filmLayer ? upper : on, film: filmLayer ? on : nil)
                    XCTAssertTrue(effective.writeNfo && effective.downloadPoster && effective.downloadFanart && effective.downloadClearlogo)
                }
            }
        }
    }

    func testLegacySharedMediaOverrideCanReenableTvPosterAndKeepsFieldInheritance() throws {
        let legacy = try JSONDecoder().decode(PolicyOverride.self, from: Data(#"{"downloadPoster":false,"writeNfo":false}"#.utf8))
        XCTAssertNil(legacy.movieAssets); XCTAssertNil(legacy.tvAssets)
        var global = DefaultPolicies()
        var draft = global.applying(legacy)
        XCTAssertFalse(draft.movie.poster); XCTAssertFalse(draft.tv.poster)
        draft.tv.poster = true
        let edited = try JSONDecoder().decode(PolicyOverride.self, from: JSONEncoder().encode(draft.diffOverride(from: global)))
        let reopened = global.applying(edited)
        XCTAssertTrue(reopened.tv.poster); XCTAssertFalse(reopened.movie.poster)
        XCTAssertFalse(reopened.tv.nfo); XCTAssertFalse(reopened.movie.nfo)
        XCTAssertTrue(PolicyResolver.resolve(isTv: true, global: global, task: edited).downloadPoster)
        XCTAssertFalse(PolicyResolver.resolve(isTv: false, global: global, task: edited).downloadPoster)
        XCTAssertNil(edited.tvAssets?.fanart)
        global.tv.fanart = true
        XCTAssertTrue(PolicyResolver.resolve(isTv: true, global: global, task: edited).downloadFanart)
        let film = PolicyOverride(downloadPoster: false)
        XCTAssertFalse(PolicyResolver.resolve(isTv: true, global: global, task: edited, film: film).downloadPoster,
                       "影片旧式覆盖仍优先于任务新式覆盖")
        let filmSpecific = PolicyOverride(tvAssets: MediaPolicyOverride(poster: true))
        XCTAssertTrue(PolicyResolver.resolve(isTv: true, global: global, task: legacy, film: filmSpecific).downloadPoster)
    }

    func testTvPosterActionCanBeDisabledThenReenabledByScopedPolicy() {
        let poster = makeAction(id: "poster", op: "artwork", fileId: nil, oldName: "", newName: "poster.jpg", kind: "image")
        let base = DefaultPolicies()
        for filmLayer in [false, true] {
            var plan = episodeAssetPlan(actions: [poster])
            var draft = base; draft.tv.poster = false
            if filmLayer { plan.groups[0].policyOverride = draft.diffOverride(from: base) }
            else { plan.taskPolicy = draft.diffOverride(from: base) }
            let disabled = PolicyResolver.applyOverrides(to: plan, global: base)
            XCTAssertFalse(disabled.actions[0].enabled)
            var on = disabled
            draft.tv.poster = true
            if filmLayer { on.groups[0].policyOverride = draft.diffOverride(from: base) }
            else { on.taskPolicy = draft.diffOverride(from: base) }
            let enabled = PolicyResolver.applyOverrides(to: on, global: base)
            XCTAssertTrue(enabled.actions[0].enabled && enabled.actions[0].selected)
        }
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
