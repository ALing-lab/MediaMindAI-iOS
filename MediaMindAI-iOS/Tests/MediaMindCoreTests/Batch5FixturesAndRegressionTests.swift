import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 第 5 批：1:1 迁移 Android `naming_fixtures.json` 数据驱动测试与全子系统回归测试。
final class Batch5FixturesAndRegressionTests: XCTestCase {

    // MARK: - 1. Android naming_fixtures.json 数据驱动测试

    func testNamingFixturesJsonLoadedAndValidated() throws {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle(for: Self.self)
        #endif
        guard let url = resourceBundle.url(forResource: "naming_fixtures", withExtension: "json") else {
            XCTFail("缺少 naming_fixtures.json 测试资源")
            return
        }
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // 1.1 hdr 病例
        let hdrCases = try XCTUnwrap(root["hdr"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(hdrCases.count, 5)
        for item in hdrCases {
            let stem = try XCTUnwrap(item["stem"] as? String)
            let expectedHdr = try XCTUnwrap(item["hdr"] as? String)
            let v = StandardNaming.parseVersion(fileStem: stem)
            if !expectedHdr.isEmpty {
                XCTAssertFalse(v.hdr.isEmpty, "HDR 未命中：\(stem)")
            }
        }

        // 1.2 season_dir 病例
        let seasonDirs = try XCTUnwrap(root["season_dir"] as? [[String: Any]])
        for item in seasonDirs {
            let name = try XCTUnwrap(item["name"] as? String)
            let isSeason = try XCTUnwrap(item["is_season"] as? Bool)
            let parsedSeason = MediaParser.seasonFromName(name)
            if isSeason {
                XCTAssertEqual(parsedSeason, item["num"] as? Int, "季目录识别偏差：\(name)")
            } else {
                XCTAssertNil(parsedSeason, "非季目录不应误判：\(name)")
            }
        }

        // 1.3 folder 标准命名
        let expectedFolder = try XCTUnwrap(root["folder"] as? String)
        let actualFolder = StandardNaming.folderName(title: "盗梦空间", year: "2010", tmdbId: 27205)
        XCTAssertEqual(actualFolder, expectedFolder)

        // 1.4 movie_bases 病例
        let movieBases = try XCTUnwrap(root["movie_bases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(movieBases.count, 5)
        for item in movieBases {
            let stem = try XCTUnwrap(item["stem"] as? String)
            let title = try XCTUnwrap(item["title"] as? String)
            let year = item["year"] as? String ?? ""
            let base = StandardNaming.movieFileBase(title: title, year: year, tmdbId: nil, fileStem: stem)
            XCTAssertTrue(base.contains(title), "电影基名应包含译名：\(base)")
        }

        // 1.5 episode_bases 病例
        let epBases = try XCTUnwrap(root["episode_bases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(epBases.count, 10)
        for item in epBases {
            let stem = try XCTUnwrap(item["stem"] as? String)
            let season = try XCTUnwrap(item["season"] as? Int)
            let episode = try XCTUnwrap(item["episode"] as? Int)
            let base = StandardNaming.episodeFileBase(
                title: "繁花",
                season: season,
                episode: episode,
                tmdbId: nil,
                fileStem: stem,
                year: "2023"
            )
            XCTAssertTrue(base.contains(String(format: "S%02dE%02d", season, episode)), "剧集基名应含 SxxExx：\(base)")
        }
    }

    // MARK: - 2. StandardNaming & EditionParser 回归

    func testEditionParserAndDiscDetection() {
        let ed = EditionParser.parseEditions("Blade.Runner.1982.Final.Cut.IMAX.2160p.UHD.BluRay.Remux")
        XCTAssertFalse(ed.editions.isEmpty)
        let stack = EditionParser.parseStackPart("Lord.of.the.Rings.CD1.1080p")
        XCTAssertEqual(stack?.index, 1)
        XCTAssertEqual(EditionParser.detectDiscType(fileName: "Movie.iso"), .iso)
        XCTAssertEqual(EditionParser.detectDiscType(fileName: "BD", childDirNames: ["BDMV", "CERTIFICATE"]), .bdmv)
        XCTAssertTrue(StandardNaming.isBdmvRoot(directChildDirNames: ["BDMV"]))
        XCTAssertTrue(StandardNaming.isBdmvInternalPath("/Movies/Avatar/BDMV/STREAM/00001.m2ts"))
    }

    // MARK: - 3. 限流、证书固定与网络配置回归

    func testLanHostDetectionAndCertPinningNormalization() {
        XCTAssertTrue(DriveRateProfile.isLanHost("192.168.1.100"))
        XCTAssertTrue(DriveRateProfile.isLanHost("10.0.0.5"))
        XCTAssertTrue(DriveRateProfile.isLanHost("nas.local"))
        XCTAssertFalse(DriveRateProfile.isLanHost("api.guangyapan.com"))

        let rawFp = "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
        let norm = CertPinning.normalize(rawFp)
        XCTAssertEqual(norm?.count, 95)
        XCTAssertNil(CertPinning.normalize("invalid-short"))

        let fp = CertPinning.sha256Fingerprint(of: Data("mediamind".utf8))
        XCTAssertEqual(fp.count, 95)
    }

    func testTmdbNetConfigNormalizationAndImageMirrors() async {
        let cfg = TmdbNetConfig(
            apiBase: TmdbNetConfig.altApi,
            imageBase: TmdbNetConfig.defaultImage,
            publicMirrors: true
        ).normalized()
        XCTAssertNil(cfg.apiHttpProblem())

        let candidates = await TmdbNet.shared.imageCandidates(
            for: "https://image.tmdb.org/t/p/w500/abc.jpg",
            config: cfg
        )
        XCTAssertGreaterThanOrEqual(candidates.count, 2)
    }

    // MARK: - 4. 冲突策略、重复检测、已有资产与自适应目录规划

    func testConflictPolicyAndExistingAssets() {
        XCTAssertTrue(ConflictPolicy.isDeferrableConflict("目标目录已有同名对象"))
        XCTAssertTrue(ConflictPolicy.isDeferrableConflict("HTTP 409 Conflict: already exists"))
        XCTAssertFalse(ConflictPolicy.isDeferrableConflict("unauthorized 401"))

        XCTAssertEqual(ExistingAssets.imageRole(of: "poster.jpg"), "poster")
        XCTAssertEqual(ExistingAssets.imageRole(of: "fanart.png"), "background")
        XCTAssertEqual(ExistingAssets.imageRole(of: "clearlogo.png"), "logo")

        let entries = [
            CloudEntry(fileId: "1", fileName: "poster.jpg", isDir: false, size: 12000, parentFileId: "root"),
            CloudEntry(fileId: "2", fileName: "movie.nfo", isDir: false, size: 500, parentFileId: "root"),
        ]
        XCTAssertTrue(ExistingAssets.hasExistingAsset(in: entries, kind: "poster", targetName: "poster.jpg"))
        XCTAssertTrue(ExistingAssets.hasExistingAsset(in: entries, kind: "nfo", targetName: "movie.nfo"))
        XCTAssertFalse(ExistingAssets.hasExistingAsset(in: entries, kind: "fanart", targetName: "fanart.jpg"))
    }

    func testDuplicateDetectorAndContentDigest() {
        let e1 = CloudEntry(
            fileId: "f1",
            fileName: "A.2160p.Remux.mkv",
            isDir: false,
            size: 30_000_000_000,
            parentFileId: "p",
            etag: "abc123def456",
            contentHash: "d41d8cd98f00b204e9800998ecf8427e",
            hashAlgorithm: "md5"
        )
        let e2 = CloudEntry(
            fileId: "f2",
            fileName: "A.copy.mkv",
            isDir: false,
            size: 30_000_000_000,
            parentFileId: "p",
            etag: "abc123def456",
            contentHash: "d41d8cd98f00b204e9800998ecf8427e",
            hashAlgorithm: "md5"
        )
        XCTAssertTrue(ContentDigest.isSameContent(e1, e2))

        let c1 = DuplicateDetector.Candidate(
            accountId: "acc-test",
            entry: e1,
            sourcePath: "/Movies/A.2160p.Remux.mkv",
            workKey: "movie:27205",
            workTitle: "盗梦空间",
            targetDir: "/Movies/盗梦空间 (2010)",
            targetName: "盗梦空间.2010.2160p.Remux.mkv"
        )
        let c2 = DuplicateDetector.Candidate(
            accountId: "acc-test",
            entry: e2,
            sourcePath: "/Movies/A.copy.mkv",
            workKey: "movie:27205",
            workTitle: "盗梦空间",
            targetDir: "/Movies/盗梦空间 (2010)",
            targetName: "盗梦空间.2010.2160p.Remux.mkv"
        )
        var groups = DuplicateDetector.analyze(candidates: [c1, c2])
        XCTAssertEqual(groups.count, 1)
        XCTAssertNotNil(groups[0].primaryFileId)
        groups[0].resolution = .moveToRetention
        XCTAssertEqual(groups[0].retentionTargets().count, 1)
    }

    func testLooseSeriesGroupingTemplates() {
        let t1 = LooseSeriesGrouping.templateOf("三体.第01集.1080p")
        let t2 = LooseSeriesGrouping.templateOf("三体.第02集.1080p")
        XCTAssertEqual(t1, t2)
    }

    // MARK: - 5. 更新检查回归

    func testUpdateCheckerSemverComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.5.90", than: "0.5.85"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.0", than: "0.9.99"))
        XCTAssertFalse(UpdateChecker.isNewer("0.5.85", than: "0.5.85"))
        XCTAssertFalse(UpdateChecker.isNewer("0.5.78", than: "0.5.90"))
    }
}
