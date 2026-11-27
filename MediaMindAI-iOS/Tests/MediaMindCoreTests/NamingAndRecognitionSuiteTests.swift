import XCTest
import Foundation
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 批次 5.1：1:1 迁移 Android Naming / Recognition 全部 iOS 适用单元测试
/// 覆盖：NamingTest / StandardNamingTest / NamingLanguageTest / MultiVersionEpisodeTest /
/// TitleDeobfuscator / ReleaseTokenizer / ExternalIdExtractor / EpisodeRangeParser /
/// AnimeEpisodeParser / EpisodeMapping / SequelDisambiguator / FolderContextResolver / TitleScorer
private final class AssetReadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "asset.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        let status: Int
        if request.httpMethod == "PROPFIND" {
            let responses = ["asset.nfo", "short.nfo", "long.nfo", "denied.nfo"].map {
                "<d:response><d:href>/dav/\($0)</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>3</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            }.joined()
            body = Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(responses)</d:multistatus>".utf8)
            status = 207
        } else {
            body = Data((url.lastPathComponent == "short.nfo" ? "ab" : (url.lastPathComponent == "long.nfo" ? "abcd" : "abc")).utf8)
            status = url.lastPathComponent == "denied.nfo" ? 403 : 200
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NamingAndRecognitionSuiteTests: XCTestCase {

    private struct AssetMetadataDrive: CloudDrive {
        let kind: ProviderKind
        let accountId = "asset-test"
        let entries: [CloudEntry]
        let listings: [String: [CloudEntry]]?
        init(entries: [CloudEntry] = [], listings: [String: [CloudEntry]]? = nil, kind: ProviderKind = .p123) {
            self.entries = entries; self.listings = listings; self.kind = kind
        }
        func list(folderId: String) async throws -> [CloudEntry] { listings.map { $0[folderId] ?? [] } ?? entries }
        func rename(fileId: String, newName: String) async throws -> String { throw DriveError.unsupported("test") }
        func mkdir(parentId: String, name: String) async throws -> String { throw DriveError.unsupported("test") }
        func move(fileId: String, destParentId: String) async throws -> String { throw DriveError.unsupported("test") }
        func upload(parentId: String, name: String, data: Data) async throws -> String { throw DriveError.unsupported("test") }
    }

    func testAssetMD5RequiresExactIdentitySizeAndMD5Algorithm() async throws {
        let md5 = "900150983cd24fb0d6963f7d28e17f72"
        let valid = CloudEntry(fileId: "asset", fileName: "asset.nfo", isDir: false, size: 3,
                               contentHash: md5.uppercased(), hashAlgorithm: "MD5")
        let drive: any CloudDrive = AssetMetadataDrive(entries: [valid])
        let actual = try await drive.assetMD5(fileId: "asset", parentId: "0", expectedSize: 3)
        XCTAssertEqual(actual, md5)
        let wrongSize = try await drive.assetMD5(fileId: "asset", parentId: "0", expectedSize: 4)
        XCTAssertNil(wrongSize)
        let other = try await drive.assetMD5(fileId: "other", parentId: "0", expectedSize: 3)
        XCTAssertNil(other)
        let duplicate = try await AssetMetadataDrive(entries: [valid, valid]).assetMD5(fileId: "asset", parentId: "0", expectedSize: 3)
        XCTAssertNil(duplicate)
        let opaque = CloudEntry(fileId: "asset", fileName: "asset.nfo", isDir: false, size: 3, etag: md5)
        let unknown = try await AssetMetadataDrive(entries: [opaque]).assetMD5(fileId: "asset", parentId: "0", expectedSize: 3)
        XCTAssertNil(unknown, "任意 ETag 不能隐式当作 MD5")
    }

    func testUploadReconciliationRetainsLocalMD5WhenListHasNoChecksum() async throws {
        let expected = "900150983cd24fb0d6963f7d28e17f72"
        for state in ["prepared", "undo_prepared"] {
            for checksum in [nil, expected] as [String?] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-md5-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: url) }
                let wal = ReversibleWalStore(storageURL: url)
                let row = try wal.prepare(taskId: "upload", accountId: "asset-test", actionId: "poster", operation: "upload", before: nil,
                    after: RemoteSnapshot(id: "asset", parent: "0", name: "asset.nfo", directory: false, size: 3, contentMD5: expected))
                try wal.change(row, state: state)
                let entry = CloudEntry(fileId: "asset", fileName: "asset.nfo", isDir: false, size: 3,
                    contentHash: checksum, hashAlgorithm: checksum == nil ? nil : "MD5")
                let report = await JournalReconciler.reconcileReversibleWal(taskId: "upload", drive: AssetMetadataDrive(entries: [entry]), wal: wal)
                XCTAssertEqual(report.confirmedApplied, 1)
                XCTAssertEqual(wal.find(taskId: "upload", actionId: "poster")?.after?.contentMD5, expected)
                let reloaded = ReversibleWalStore(storageURL: url)
                XCTAssertEqual(reloaded.find(taskId: "upload", actionId: "poster")?.after?.contentMD5, expected)
            }
        }
    }

    func testUploadReconciliationDoesNotAcceptSameSizeDifferentMD5() async throws {
        let expected = "900150983cd24fb0d6963f7d28e17f72"
        for state in ["prepared", "undo_prepared"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-mismatch-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let wal = ReversibleWalStore(storageURL: url)
            let row = try wal.prepare(taskId: "upload", accountId: "asset-test", actionId: "poster", operation: "upload", before: nil,
                after: RemoteSnapshot(id: "asset", parent: "0", name: "asset.nfo", directory: false, size: 3, contentMD5: expected))
            try wal.change(row, state: state)
            let entry = CloudEntry(fileId: "asset", fileName: "asset.nfo", isDir: false, size: 3,
                contentHash: "d41d8cd98f00b204e9800998ecf8427e", hashAlgorithm: "MD5")
            let report = await JournalReconciler.reconcileReversibleWal(taskId: "upload", drive: AssetMetadataDrive(entries: [entry]), wal: wal)
            XCTAssertEqual(report.stillUncertain, 1)
            XCTAssertEqual(report.confirmedApplied, 0)
            XCTAssertEqual(report.confirmedNotApplied, 0)
            XCTAssertEqual(wal.find(taskId: "upload", actionId: "poster")?.state, state)
            XCTAssertEqual(wal.find(taskId: "upload", actionId: "poster")?.after?.contentMD5, expected)
        }
    }

    func testInterruptedStashMoveRestoresPersistedLocationAndPreservedState() async throws {
        for kind in [ProviderKind.p123, .webdav] {
            for preserving in [false, true] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("stash-recovery-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: url) }
                let wal = ReversibleWalStore(storageURL: url)
                let parent = kind == .webdav ? "/" : "0"
                let stash = kind == .webdav ? "/stash" : "stash"
                let id = kind == .webdav ? "/asset.nfo" : "asset"
                let targetId = kind == .webdav ? "/stash/asset.nfo" : id
                let after = RemoteSnapshot(id: id, parent: parent, name: "asset.nfo", directory: false, size: 3)
                let destination = after.with(id: targetId, parent: stash)
                let row = try wal.prepare(taskId: "undo", accountId: "asset-test", actionId: "asset", operation: "upload", before: nil, after: after)
                try wal.prepareUndo(row, destination: destination, preserving: preserving)
                let entry = CloudEntry(fileId: targetId, fileName: after.name, isDir: false, size: 3)
                let drive = AssetMetadataDrive(listings: [parent: [], stash: [entry]], kind: kind)
                let report = await JournalReconciler.reconcileReversibleWal(taskId: "undo", drive: drive, wal: wal)
                XCTAssertEqual(report.confirmedReverted, 1)
                let loaded = ReversibleWalStore(storageURL: url).find(taskId: "undo", actionId: "asset")
                XCTAssertEqual(loaded?.state, preserving ? "preserved" : "reverted")
                XCTAssertEqual(loaded?.undoResult?.parent, stash)
                XCTAssertEqual(loaded?.undoResult?.id, targetId)
                XCTAssertEqual(loaded?.preserveUnverifiedAsset, preserving)
            }
        }
    }

    func testStashRecoveryDoesNotGuessFromMissingSourceOrAmbiguousDestination() async throws {
        let source = CloudEntry(fileId: "asset", fileName: "asset.nfo", isDir: false, size: 3, etag: "old-etag")
        let target = CloudEntry(fileId: "asset", fileName: "asset.nfo", isDir: false, size: 3, etag: "old-etag")
        let wrongSize = CloudEntry(fileId: "asset", fileName: "asset.nfo", isDir: false, size: 4, etag: "old-etag")
        let wrongId = CloudEntry(fileId: "other", fileName: "asset.nfo", isDir: false, size: 3, etag: "old-etag")
        let changed = CloudEntry(fileId: "asset", fileName: "asset.nfo", isDir: false, size: 3, etag: "changed-etag")
        let cases: [([CloudEntry], [CloudEntry])] = [([], []), ([source], [target]), ([], [wrongSize]), ([], [wrongId]), ([], [changed]), ([], [target, target])]
        for (sources, targets) in cases {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stash-uncertain-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let wal = ReversibleWalStore(storageURL: url)
            let after = RemoteSnapshot.from(source, parent: "0")
            let row = try wal.prepare(taskId: "undo", accountId: "asset-test", actionId: "asset", operation: "upload", before: nil, after: after)
            try wal.prepareUndo(row, destination: after.with(parent: "stash"), preserving: true)
            let report = await JournalReconciler.reconcileReversibleWal(taskId: "undo",
                drive: AssetMetadataDrive(listings: ["0": sources, "stash": targets]), wal: wal)
            XCTAssertEqual(report.stillUncertain, 1)
            XCTAssertEqual(report.confirmedReverted, 0)
            XCTAssertEqual(report.confirmedApplied, 0)
            XCTAssertEqual(wal.find(taskId: "undo", actionId: "asset")?.state, "undo_prepared")
        }
    }

    func testStashRecoveryRejectsKnownDigestMismatchWithoutChangingTerminalState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stash-digest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let wal = ReversibleWalStore(storageURL: url)
        let after = RemoteSnapshot(id: "/asset.nfo", parent: "/", name: "asset.nfo", directory: false, size: 3,
            contentMD5: "900150983cd24fb0d6963f7d28e17f72")
        let row = try wal.prepare(taskId: "undo", accountId: "asset-test", actionId: "asset", operation: "upload", before: nil, after: after)
        try wal.prepareUndo(row, destination: after.with(id: "/stash/asset.nfo", parent: "/stash"), preserving: false)
        let changed = CloudEntry(fileId: "/stash/asset.nfo", fileName: "asset.nfo", isDir: false, size: 3,
            contentHash: "d41d8cd98f00b204e9800998ecf8427e", hashAlgorithm: "MD5")
        let report = await JournalReconciler.reconcileReversibleWal(taskId: "undo",
            drive: AssetMetadataDrive(listings: ["/": [], "/stash": [changed]], kind: .webdav), wal: wal)
        XCTAssertEqual(report.stillUncertain, 1)
        XCTAssertEqual(report.confirmedReverted, 0)
        XCTAssertEqual(wal.find(taskId: "undo", actionId: "asset")?.state, "undo_prepared")
    }

    func testStashRecoveryReturnsUnmovedSourceToAppliedWithoutLosingMD5() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stash-retry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let wal = ReversibleWalStore(storageURL: url)
        let expected = "900150983cd24fb0d6963f7d28e17f72"
        let after = RemoteSnapshot(id: "/asset.nfo", parent: "/", name: "asset.nfo", directory: false, size: 3, contentMD5: expected)
        let row = try wal.prepare(taskId: "undo", accountId: "asset-test", actionId: "asset", operation: "upload", before: nil, after: after)
        try wal.prepareUndo(row, destination: after.with(id: "/stash/asset.nfo", parent: "/stash"), preserving: false)
        let source = CloudEntry(fileId: after.id, fileName: after.name, isDir: false, size: 3)
        let report = await JournalReconciler.reconcileReversibleWal(taskId: "undo",
            drive: AssetMetadataDrive(listings: ["/": [source], "/stash": []], kind: .webdav), wal: wal)
        XCTAssertEqual(report.confirmedApplied, 1)
        XCTAssertEqual(report.confirmedReverted, 0)
        XCTAssertEqual(wal.find(taskId: "undo", actionId: "asset")?.state, "applied")
        XCTAssertEqual(wal.find(taskId: "undo", actionId: "asset")?.after?.contentMD5, expected)
    }

    func testWebDavAssetMD5StreamsAndRejectsInvalidBodies() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AssetReadProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let drive = try WebDavDrive(accountId: "dav-test", baseUrl: "https://asset.test/dav", username: "", password: "", session: session)
        let actual = try await drive.assetMD5(fileId: "/asset.nfo", parentId: "/", expectedSize: 3)
        XCTAssertEqual(actual, "900150983cd24fb0d6963f7d28e17f72")
        for name in ["short.nfo", "long.nfo", "denied.nfo"] {
            do {
                _ = try await drive.assetMD5(fileId: "/" + name, parentId: "/", expectedSize: 3)
                XCTFail("不能接受错误大小或失败响应：\(name)")
            } catch { }
        }
        let tooLarge = try await drive.assetMD5(fileId: "/asset.nfo", parentId: "/", expectedSize: 64 * 1024 * 1024 + 1)
        XCTAssertNil(tooLarge)
        do {
            _ = try await drive.assetMD5(fileId: "/../asset.nfo", parentId: "/", expectedSize: 3)
            XCTFail("越界路径不能读取")
        } catch { }
    }

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
