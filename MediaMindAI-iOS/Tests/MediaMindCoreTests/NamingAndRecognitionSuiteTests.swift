import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 批次 5.1：1:1 迁移 Android Naming / Recognition 全部 iOS 适用单元测试
/// 覆盖：NamingTest / StandardNamingTest / NamingLanguageTest / MultiVersionEpisodeTest /
/// TitleDeobfuscator / ReleaseTokenizer / ExternalIdExtractor / EpisodeRangeParser /
/// AnimeEpisodeParser / EpisodeMapping / SequelDisambiguator / FolderContextResolver / TitleScorer
final class NamingAndRecognitionSuiteTests: XCTestCase {

    // MARK: - 1. StandardNaming & Multi-Version Parsing

    func testStandardNamingVersionParsingAndFiltering() {
        let v = StandardNaming.parseVersion(
            fileStem: "Dune.Part.Two.2024.2160p.UHD.BluRay.60fps.HDR10+.TrueHD.7.1.Atmos",
            releaseDirName: nil
        )
        XCTAssertEqual(v.resolution, "2160p")
        XCTAssertEqual(v.fps, "60fps")
        XCTAssertFalse(v.hdr.isEmpty)
        XCTAssertFalse(v.audio.isEmpty)
        XCTAssertFalse(v.label.isEmpty)

        var opts = StandardNaming.FileOptions()
        opts.keepExtraInfo = true
        opts.keepResolution = true
        opts.keepQuality = true
        opts.keepFps = false
        opts.keepAudio = false
        let filtered = v.filteredBy(opts)
        XCTAssertEqual(filtered.resolution, "2160p")
        XCTAssertTrue(filtered.fps.isEmpty)
        XCTAssertTrue(filtered.audio.isEmpty)
    }

    func testStandardNamingDefaultSdrWhenMissing() {
        let plain = StandardNaming.parseVersion(fileStem: "Inception.2010.1080p.WEB-DL.AAC", releaseDirName: nil)
        XCTAssertTrue(plain.hdr.isEmpty)

        var opts = StandardNaming.FileOptions()
        opts.keepExtraInfo = true
        opts.keepQuality = true
        opts.defaultSdrWhenMissing = true
        let withSdr = plain.filteredBy(opts)
        XCTAssertEqual(withSdr.hdr, "SDR")
    }

    func testStandardNamingFolderAndFileFormatting() {
        let prefs = MediaNamingPrefs.movieDefault()
        let folder = StandardNaming.folderName(title: "盗梦空间", year: "2010", tmdbId: 27205, prefs: prefs)
        XCTAssertTrue(folder.contains("盗梦空间"))
        XCTAssertTrue(folder.contains("2010"))
        XCTAssertTrue(folder.contains("27205"))

        XCTAssertEqual(StandardNaming.seasonDirName(0), "Season 00")
        XCTAssertEqual(StandardNaming.seasonDirName(1), "Season 01")
        XCTAssertEqual(StandardNaming.seasonDirName(12), "Season 12")

        XCTAssertEqual(StandardNaming.stripTmdbMark("盗梦空间 (2010) {tmdb-27205}"), "盗梦空间 (2010)")
        XCTAssertEqual(StandardNaming.tmdbTag(27205, style: "{tmdb-id}"), "{tmdb-27205}")
        XCTAssertEqual(StandardNaming.tmdbTag(27205, style: "[tmdbid=id]"), "[tmdbid=27205]")
        XCTAssertEqual(StandardNaming.formatYear("2024", style: "(year)"), "(2024)")
        XCTAssertEqual(StandardNaming.formatYear("2024", style: "[year]"), "[2024]")
        XCTAssertEqual(StandardNaming.formatYear("2024", style: "year"), "2024")
    }

    func testStandardNamingBdmvDetection() {
        XCTAssertTrue(StandardNaming.isBdmvRoot(directChildDirNames: ["BDMV", "CERTIFICATE"]))
        XCTAssertFalse(StandardNaming.isBdmvRoot(directChildDirNames: ["Season 01", "Extras"]))
        XCTAssertTrue(StandardNaming.isBdmvInternalPath("/Movies/Dune/BDMV/STREAM/00001.m2ts"))
        XCTAssertFalse(StandardNaming.isBdmvInternalPath("/Movies/Dune/Dune.mkv"))
    }

    // MARK: - 2. MediaNamingPrefs Language & Live Previews

    func testNamingLanguagePreferencesAndPreviews() {
        var prefs = MediaNamingPrefs.movieDefault()
        XCTAssertEqual(prefs.resolveTitle(lang: "chinese", zh: "流浪地球2", en: "The Wandering Earth II", orig: "流浪地球2"), "流浪地球2")
        XCTAssertEqual(prefs.resolveTitle(lang: "english", zh: "流浪地球2", en: "The Wandering Earth II", orig: "流浪地球2"), "The Wandering Earth II")
        let bilingual = prefs.resolveTitle(lang: "bilingual", zh: "流浪地球2", en: "The Wandering Earth II", orig: "流浪地球2")
        XCTAssertTrue(bilingual.contains("流浪地球2"))
        XCTAssertTrue(bilingual.contains("The Wandering Earth II"))

        prefs.fileLanguage = "english"
        prefs.folderMatchFileName = true
        XCTAssertEqual(prefs.effectiveFolderLanguage(), "english")
        prefs.folderMatchFileName = false
        prefs.folderLanguage = "chinese"
        XCTAssertEqual(prefs.effectiveFolderLanguage(), "chinese")

        let beforeFolder = prefs.previewFolder(isTv: false, renameFolders: false)
        let afterFolder = prefs.previewFolder(isTv: false, renameFolders: true)
        XCTAssertFalse(beforeFolder.isEmpty)
        XCTAssertFalse(afterFolder.isEmpty)
        XCTAssertNotEqual(beforeFolder, afterFolder)

        let tvBefore = MediaNamingPrefs.tvDefault().previewFile(isTv: true, renameFiles: false)
        let tvAfter = MediaNamingPrefs.tvDefault().previewFile(isTv: true, renameFiles: true)
        XCTAssertFalse(tvBefore.isEmpty)
        XCTAssertFalse(tvAfter.isEmpty)
    }

    // MARK: - 3. EditionParser & Disc / Stack Detection

    func testEditionParserAndStackParts() {
        let ed = EditionParser.parseEditions("Avatar.2009.Extended.Directors.Cut.IMAX.3D.HSBS.2160p")
        XCTAssertFalse(ed.editions.isEmpty)
        XCTAssertEqual(ed.threeD, "3D HSBS")
        XCTAssertFalse(ed.displayLabel.isEmpty)

        let cd1 = EditionParser.parseStackPart("Lord.of.the.Rings.CD1.1080p")
        XCTAssertEqual(cd1?.type, "CD")
        XCTAssertEqual(cd1?.index, 1)

        let part2 = EditionParser.parseStackPart("Dune.Part2.2160p")
        XCTAssertEqual(part2?.index, 2)

        XCTAssertEqual(EditionParser.detectDiscType(fileName: "Movie", childDirNames: ["BDMV", "CERTIFICATE"]), .bdmv)
        XCTAssertEqual(EditionParser.detectDiscType(fileName: "Movie", childDirNames: ["VIDEO_TS"]), .videoTs)
        XCTAssertEqual(EditionParser.detectDiscType(fileName: "Movie.iso"), .iso)
    }

    // MARK: - 4. TitleDeobfuscator & ReleaseTokenizer

    func testTitleDeobfuscatorAntiEvasionPipeline() {
        XCTAssertEqual(TitleDeobfuscator.normalizeFullWidth("流　浪（２０２３）"), "流 浪(2023)")
        XCTAssertEqual(TitleDeobfuscator.traditionalToSimplified("進擊的巨人"), "进击的巨人")

        let collapsed = TitleDeobfuscator.collapseHanObfuscation("流_浪_地_球_2")
        XCTAssertTrue(collapsed.contains("流浪地球"))

        let ext = TitleDeobfuscator.extract("【高清影视】流.浪.地.球.2.2023.2160p.HDR.mkv")
        XCTAssertEqual(ext.year, "2023")
        XCTAssertFalse(ext.queries.isEmpty)
        XCTAssertFalse(ext.primaryTitle.isEmpty)

        XCTAssertTrue(TitleDeobfuscator.containsEmoji("🎬 盗梦空间"))
        XCTAssertFalse(TitleDeobfuscator.containsEmoji("盗梦空间 2010"))
    }

    func testReleaseTokenizerNoiseMasking() {
        let masked = ReleaseTokenizer.maskTechnicalSpans("Interstellar.2014.2160p.UHD.BluRay.REMUX.HEVC.DTS-HD.MA.5.1-FGT")
        XCTAssertFalse(masked.unmaskedText().contains("2160p"))
        XCTAssertFalse(masked.unmaskedText().contains("HEVC"))
        let cleaned = ReleaseTokenizer.stripNoiseForTitle("Interstellar.2014.2160p.WEB-DL.x265.10bit-FRDS")
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("Interstellar"))
        XCTAssertFalse(cleaned.contains("2160p"))
    }

    // MARK: - 5. ExternalIdExtractor (Filename & NFO)

    func testExternalIdExtractorFromNameAndNfo() {
        let fromName = ExternalIdExtractor.fromName("Inception (2010) {tmdb-27205} [tt1375666]")
        XCTAssertTrue(fromName.hasAny)
        XCTAssertEqual(fromName.tmdbId, 27205)
        XCTAssertEqual(fromName.imdbId, "tt1375666")

        let nfo = """
        <tvshow>
          <title>Breaking Bad</title>
          <uniqueid type="tmdb" default="true">1396</uniqueid>
          <uniqueid type="imdb">tt0903747</uniqueid>
          <uniqueid type="tvdb">81189</uniqueid>
        </tvshow>
        """
        let fromNfo = ExternalIdExtractor.fromNfo(nfo)
        XCTAssertEqual(fromNfo.tmdbId, 1396)
        XCTAssertEqual(fromNfo.imdbId, "tt0903747")
        XCTAssertEqual(fromNfo.tvdbId, 81189)

        let merged = ExternalIdExtractor.merge(
            primary: ExternalIdExtractor.fromName("Show {tmdb-100}"),
            fallback: fromNfo
        )
        XCTAssertEqual(merged.tmdbId, 100)
        XCTAssertEqual(merged.imdbId, "tt0903747")
    }

    // MARK: - 6. EpisodeRangeParser, AnimeEpisodeParser & EpisodeMapping

    func testEpisodeRangeAndAnimeParsers() {
        let multi = EpisodeRangeParser.parse("Breaking.Bad.S02E05-E07.1080p")
        XCTAssertEqual(multi?.season, 2)
        XCTAssertEqual(multi?.episodes, [5, 6, 7])
        XCTAssertEqual(multi?.primaryEpisode, 5)

        let dated = EpisodeRangeParser.parse("Running.Man.2024-05-12.1080p", allowBareDate: true)
        XCTAssertEqual(dated?.airDate, "2024-05-12")
        XCTAssertTrue(EpisodeRangeParser.isValidCalendarDate(year: 2024, month: 2, day: 29))
        XCTAssertFalse(EpisodeRangeParser.isValidCalendarDate(year: 2023, month: 2, day: 29))

        let anime = AnimeEpisodeParser.parse("[Lilith-Raws] Frieren - 12v2 [Baha][WEB-DL][1080p]")
        XCTAssertEqual(anime?.episode, 12)
        XCTAssertEqual(anime?.version, 2)
        XCTAssertEqual(anime?.isSpecial, false)

        let ova = AnimeEpisodeParser.parse("[Sub] Attack on Titan OVA 02 [1080p]")
        XCTAssertEqual(ova?.isSpecial, true)
        XCTAssertEqual(ova?.specialKind, "OVA")

        let repeated = AnimeEpisodeParser.repeatedTitleNumbers(stems: [
            "Mob Psycho 100 - 01", "Mob Psycho 100 - 02", "Mob Psycho 100 - 03"
        ])
        XCTAssertTrue(repeated.contains(100))
    }

    func testEpisodeMappingAbsoluteAndGroupTable() {
        let seasons = [
            SeasonEpisodeCount(seasonNumber: 1, episodeCount: 12),
            SeasonEpisodeCount(seasonNumber: 2, episodeCount: 13),
        ]
        XCTAssertEqual(EpisodeMapping.mapAbsolute(1, seasons: seasons), EpisodeMapping.EpisodeKey(season: 1, episode: 1))
        XCTAssertEqual(EpisodeMapping.mapAbsolute(13, seasons: seasons), EpisodeMapping.EpisodeKey(season: 2, episode: 1))
        XCTAssertEqual(EpisodeMapping.mapAbsolute(25, seasons: seasons), EpisodeMapping.EpisodeKey(season: 2, episode: 13))

        let table = EpisodeMapping.buildGroupMap(subGroups: [
            EpisodeMapping.EpisodeSubGroup(order: 1, name: "Part 1", episodes: [
                EpisodeMapping.EpisodeKey(season: 1, episode: 1),
                EpisodeMapping.EpisodeKey(season: 1, episode: 2),
            ]),
            EpisodeMapping.EpisodeSubGroup(order: 2, name: "Part 2", episodes: [
                EpisodeMapping.EpisodeKey(season: 1, episode: 3),
            ]),
        ])
        XCTAssertEqual(EpisodeMapping.mapEpisode(season: 1, episode: 3, using: table), EpisodeMapping.EpisodeKey(season: 2, episode: 1))
        XCTAssertTrue(EpisodeMapping.isSpecialHint("Show.SP01.1080p.mkv"))
    }

    // MARK: - 7. SequelDisambiguator, FolderContextResolver & TitleScorer

    func testSequelFolderResolverAndTitleScorer() {
        XCTAssertEqual(SequelDisambiguator.extractSequelNumber("流浪地球2"), 2)
        XCTAssertEqual(SequelDisambiguator.extractSequelNumber("The Godfather Part II"), 2)
        XCTAssertEqual(SequelDisambiguator.extractSequelNumber("指环王 第三部"), 3)
        XCTAssertTrue(SequelDisambiguator.normalizeNumerals("Dune Part II").contains("2"))

        XCTAssertTrue(FolderContextResolver.isGenericContainer("电影"))
        XCTAssertTrue(FolderContextResolver.isGenericContainer("Downloads"))
        XCTAssertFalse(FolderContextResolver.isGenericContainer("权力的游戏"))

        let rawParsed = MediaParser.parse("S01E01.mkv")
        let enriched = FolderContextResolver.enrich(parsed: rawParsed, folderName: "Season 01", ancestors: ["剧集", "三体 (2023)"])
        XCTAssertFalse(enriched.cleanTitle.isEmpty)

        let exact = TitleScorer.titleSimilarityScore("盗梦空间", "盗梦空间")
        let diff = TitleScorer.titleSimilarityScore("盗梦空间", "星际穿越")
        XCTAssertGreaterThan(exact, diff)
        XCTAssertGreaterThan(TitleScorer.jaroWinkler("inception", "inceptions"), 0.9)
    }
}
