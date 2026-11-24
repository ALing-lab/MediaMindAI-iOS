import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 第 3 批（命名解析器 + 驱动 ID 重映射 1:1 逐行直译）独立单元测试套件。
final class Batch3NamingAndDriveTests: XCTestCase {

    func testReleaseTokenizerMasksTechnicalSpansWithoutFalsePositives() {
        let res = ReleaseTokenizer.maskTechnicalSpans("[ANi] 葬送的芙莉莲 - 08 [1080p][HEVC][DDP5.1][ABCD1234] 全28集")
        XCTAssertEqual(res.releaseGroup, "ANi")
        XCTAssertEqual(res.totalEpisodesHint, 28)
        let unmasked = res.unmaskedText()
        XCTAssertFalse(unmasked.contains("1080p"))
        XCTAssertFalse(unmasked.contains("ABCD1234"))
        XCTAssertTrue(unmasked.contains("08"))
    }

    func testAnimeEpisodeParserSpecialsBracketsAndSequelGuard() {
        // 小数特别篇
        let dec = AnimeEpisodeParser.parse("[LoliHouse] 某番 - 13.5 [1080p]")
        XCTAssertEqual(dec?.season, 0)
        XCTAssertEqual(dec?.isSpecial, true)
        XCTAssertEqual(dec?.specialKind, "DECIMAL")

        // 字幕组括号集数 + v2 版本号
        let br = AnimeEpisodeParser.parse("[SweetSub] 迷宫饭 [07v2][1080p]")
        XCTAssertEqual(br?.episode, 7)
        XCTAssertEqual(br?.version, 2)

        // 守卫 C1：无字幕组前缀的电影续集 `碟中谍 - 7` 不得误判为剧集
        XCTAssertNil(AnimeEpisodeParser.parse("碟中谍 - 7"))

        // 同目录高频片名数字过滤（如 2077）
        let repeated = AnimeEpisodeParser.repeatedTitleNumbers(stems: [
            "Cyberpunk 2077 - 01",
            "Cyberpunk 2077 - 02",
            "Cyberpunk 2077 - 03",
        ])
        XCTAssertTrue(repeated.contains(2077))
        XCTAssertFalse(repeated.contains(1))
    }

    func testTitleScorerFourSignalBlendedScoring() {
        XCTAssertEqual(TitleScorer.titleSimilarityScore("駭客任務", "黑客帝国"), 100.0)
        XCTAssertGreaterThan(TitleScorer.titleSimilarityScore("复仇者联盟：终局之战", "复仇者联盟终局之战"), 85.0)
        XCTAssertGreaterThan(TitleScorer.tokenSortRatio("Iron Man 2", "2 Man Iron"), 0.99)
        XCTAssertLessThan(TitleScorer.titleSimilarityScore("流浪地球", "星际穿越"), 30.0)
    }

    func testIdRemapNestedPathResolutionAndCycleDetection() throws {
        let remap = IdRemap(pathMode: true)
        remap.record(old: "/Movies/Old", new: "/Movies/New")
        XCTAssertEqual(try remap.resolve("/Movies/Old/a.mkv"), "/Movies/New/a.mkv")

        // 环路检测
        let cyclic = IdRemap(pathMode: true)
        cyclic.record(old: "/A", new: "/B")
        cyclic.record(old: "/B", new: "/A")
        XCTAssertThrowsError(try cyclic.resolve("/A"))
    }

    func testEpisodeRangeParser() {
        let r1 = EpisodeRangeParser.parse("Show.S01E01-E03.1080p.mkv")
        XCTAssertEqual(r1?.season, 1)
        XCTAssertEqual(r1?.episodes, [1, 2, 3])

        let r2 = EpisodeRangeParser.parse("Show.S02E04E05E06.mkv")
        XCTAssertEqual(r2?.season, 2)
        XCTAssertEqual(r2?.episodes, [4, 5, 6])

        let r3 = EpisodeRangeParser.parse("第05-07集.mp4")
        XCTAssertEqual(r3?.episodes, [5, 6, 7])

        // 守卫 C1：裸日期默认不触发，带「期」后缀才触发
        XCTAssertNil(EpisodeRangeParser.parse("Movie.2025-05-12.1080p.mkv", allowBareDate: false))
        let r4 = EpisodeRangeParser.parse("综艺节目 第20250512期.mp4")
        XCTAssertEqual(r4?.season, 2025)
        XCTAssertEqual(r4?.episodes, [512])
        XCTAssertEqual(r4?.airDate, "2025-05-12")
    }

    func testExternalIdExtractorFromNameAndNfo() {
        let fromName = ExternalIdExtractor.fromName("Inception (2010) {tmdb-27205} [tt1375666] [tvdb-999] douban-3541415 bgm-12345")
        XCTAssertEqual(fromName.tmdbId, 27205)
        XCTAssertEqual(fromName.imdbId, "tt1375666")
        XCTAssertEqual(fromName.tvdbId, 999)
        XCTAssertEqual(fromName.doubanId, "3541415")
        XCTAssertEqual(fromName.bangumiId, 12345)

        // Jellyfin Issue #5347 守卫：纯数字 <id> 绝不当作 IMDb
        let nfo = "<movie><id>12345</id><uniqueid type=\"tmdb\">27205</uniqueid><uniqueid type=\"imdb\">tt1375666</uniqueid></movie>"
        let fromNfo = ExternalIdExtractor.fromNfo(nfo)
        XCTAssertEqual(fromNfo.tmdbId, 27205)
        XCTAssertEqual(fromNfo.tmdbKind, "movie")
        XCTAssertEqual(fromNfo.imdbId, "tt1375666")
    }

    func testAiResponseParserAntiHallucinationAndSanitization() {
        let raw = "```json\n{\"title\": \"Inception/../../evil\", \"year\": \"2010\", \"kind\": \"电影\", \"confidence\": 1.5}\n```"
        let parsed = AiResponseParser.parseSingle(raw)
        XCTAssertEqual(parsed?.title, "Inception .. .. evil")
        XCTAssertEqual(parsed?.year, "2010")
        XCTAssertEqual(parsed?.kind, "movie")
        XCTAssertEqual(parsed?.confidence, 1.0)

        // 反幻觉守卫：编造的 tmdbId 必须被拒
        let fakeRerank = "{\"tmdbId\": 999999, \"confidence\": 0.99, \"reason\": \"hallucinated\"}"
        XCTAssertNil(AiResponseParser.parseRerank(fakeRerank, allowedIds: [27205, 155]))
        let okRerank = "{\"tmdbId\": 27205, \"confidence\": 0.92, \"reason\": \"year match\"}"
        XCTAssertEqual(AiResponseParser.parseRerank(okRerank, allowedIds: [27205, 155])?.tmdbId, 27205)
    }
}
