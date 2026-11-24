import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 用于单元测试的内存模拟云盘，严格遵循 CloudDrive 协议，支持扫描、自适应目标库、云端保留区与 WAL 回滚全链路测试。
private final class MockCloudDrive: CloudDrive, @unchecked Sendable {
    let kind: ProviderKind = .webdav
    let accountId: String = "mock-acct"
    let rootId: String = "/"

    var callOrder: [String] = []
    var renamed: [(String, String)] = []
    var moved: [(String, String)] = []
    var trashed: [String] = []
    var listingByFolder: [String: [CloudEntry]] = [:]

    func ping() async -> Bool { true }
    func list(folderId: String) async throws -> [CloudEntry] { listingByFolder[folderId] ?? [] }
    func mkdir(parentId: String, name: String) async throws -> String {
        let p = DrivePaths.join(parent: parentId, name: name)
        callOrder.append("mkdir:\(p)")
        return p
    }
    func rename(fileId: String, newName: String) async throws -> String {
        renamed.append((fileId, newName))
        callOrder.append("rename:\(fileId)->\(newName)")
        return DrivePaths.join(parent: DrivePaths.parentOf(fileId), name: newName)
    }
    func move(fileId: String, destParentId: String) async throws -> String {
        moved.append((fileId, destParentId))
        callOrder.append("move:\(fileId)->\(destParentId)")
        let name = fileId.split(separator: "/").last.map(String.init) ?? fileId
        return DrivePaths.join(parent: destParentId, name: name)
    }
    func moveBatch(fileIds: [String], destParentId: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        for fid in fileIds {
            out[fid] = try await move(fileId: fid, destParentId: destParentId)
        }
        return out
    }
    func trash(fileId: String) async throws -> String {
        trashed.append(fileId)
        callOrder.append("trash:\(fileId)")
        return fileId
    }
    func upload(parentId: String, name: String, data: Data) async throws -> String {
        DrivePaths.join(parent: parentId, name: name)
    }
}

final class MediaMindCoreTests: XCTestCase {

    // MARK: - 1. 定版命名规范（StandardNaming + EditionParser，1:1 对标 Android）

    func testStandardNamingMovieFullVersionOrder() {
        let base = StandardNaming.movieFileBase(
            title: "流浪地球",
            year: "2019",
            tmdbId: 535167,
            fileStem: "The.Wandering.Earth.2019.2160p.24fps.UHD.Blu-ray.TrueHD.7.1.Atmos"
        )
        XCTAssertEqual(base, "流浪地球 (2019) {tmdb-535167} - 2160p 24fps UHD BluRay TrueHD 7.1 Atmos")
    }

    func testStandardNamingTvEpisodeIncludesTmdbAfterSe() {
        let opts = MediaNamingPrefs.tvDefault().fileOptions()
        let base = StandardNaming.episodeFileBase(
            title: "爱情公寓5",
            season: 5,
            episode: 1,
            tmdbId: 68809,
            fileStem: "iPartment.5.S05E01.2160p.60fps.HDRVivid.DDP.5.1",
            options: opts,
            year: "2020"
        )
        XCTAssertEqual(base, "爱情公寓5 - S05E01 {tmdb-68809} - 2160p 60fps HDRVivid DDP5.1")
    }

    func testStandardNamingMultiEpisodeRangeWithTmdb() {
        let opts = MediaNamingPrefs.tvDefault().fileOptions()
        let base = StandardNaming.episodeFileBase(
            title: "权力的游戏",
            season: 1,
            episode: 1,
            episodeEnd: 3,
            tmdbId: 1399,
            fileStem: "Game.of.Thrones.S01E01-E03.1080p.DTS-HD.MA.5.1",
            options: opts
        )
        XCTAssertEqual(base, "权力的游戏 - S01E01-E03 {tmdb-1399} - 1080p DTS-HD MA 5.1")
    }

    func testStandardNamingHdrMultiTagOrderAndHlgConflict() {
        let dvHdr = StandardNaming.parseVersion(fileStem: "Dune.2021.2160p.Dolby.Vision.HDR10+.DTS-X.7.1")
        XCTAssertEqual(dvHdr.hdr, "DV HDR10+")
        XCTAssertEqual(dvHdr.audio, "DTS-X 7.1")
        XCTAssertFalse(dvHdr.needsConfirm)

        let conflict = StandardNaming.parseVersion(fileStem: "Sample.2160p.HLG.DV")
        XCTAssertTrue(conflict.needsConfirm)
        XCTAssertEqual(conflict.confirmReason, "HDR 标注互相矛盾")
    }

    func testStandardNamingSdrCompletionWhenMissing() {
        let parsed = StandardNaming.parseVersion(fileStem: "Inception.2010.1080p.AAC.2.0")
        XCTAssertEqual(parsed.hdr, "")

        var optsNoSdr = StandardNaming.FileOptions()
        optsNoSdr.defaultSdrWhenMissing = false
        XCTAssertEqual(parsed.filteredBy(optsNoSdr).label, "1080p AAC2.0")

        var optsWithSdr = StandardNaming.FileOptions()
        optsWithSdr.defaultSdrWhenMissing = true
        XCTAssertEqual(parsed.filteredBy(optsWithSdr).label, "1080p SDR AAC2.0")
    }

    func testStandardNamingInheritsVersionFromReleaseDirAndDetectsResConflict() {
        let inherited = StandardNaming.parseVersion(
            fileStem: "E01",
            releaseDirName: "Three.Body.2023.S01.2160p.60帧.杜比视界.全景声"
        )
        XCTAssertEqual(inherited.resolution, "2160p")
        XCTAssertEqual(inherited.fps, "60fps")
        XCTAssertEqual(inherited.hdr, "DV")
        XCTAssertEqual(inherited.audio, "Atmos")
        XCTAssertFalse(inherited.needsConfirm)

        let resConflict = StandardNaming.parseVersion(fileStem: "Movie.1080p.2160p")
        XCTAssertTrue(resConflict.needsConfirm)
        XCTAssertEqual(resConflict.confirmReason, "分辨率标注互相矛盾")
    }

    func testStandardNamingTmdbTagStylesAndBdmvProtection() {
        XCTAssertEqual(StandardNaming.tmdbTag(27205, style: "{tmdb-id}"), "{tmdb-27205}")
        XCTAssertEqual(StandardNaming.tmdbTag(27205, style: "[tmdb-id]"), "[tmdb-27205]")
        XCTAssertEqual(StandardNaming.tmdbTag(27205, style: "[tmdbid=id]"), "[tmdbid=27205]")
        XCTAssertEqual(StandardNaming.tmdbTag(27205, style: "tmdb-id"), "tmdb-27205")

        XCTAssertTrue(StandardNaming.isBdmvRoot(directChildDirNames: ["BDMV", "CERTIFICATE"]))
        XCTAssertFalse(StandardNaming.isBdmvRoot(directChildDirNames: ["Season 01"]))
        XCTAssertTrue(StandardNaming.isBdmvInternalPath("/Movies/Avatar/BDMV/STREAM/00001.m2ts"))
    }

    func testEditionParserKometaWeighting3DAndStacking() {
        let ed = EditionParser.parseEditions("LOTR.2001.IMAX.Enhanced.Extended.Director's.Cut.4K.Remastered.3D.HSBS")
        XCTAssertEqual(ed.editions, ["Extended", "Director's Cut", "IMAX Enhanced", "4K Remastered"])
        XCTAssertEqual(ed.threeD, "3D HSBS")
        XCTAssertFalse(ed.editions.contains("IMAX"))
        XCTAssertFalse(ed.editions.contains("Remastered"))

        let cd = EditionParser.parseStackPart("Titanic.1997.CD2.1080p")
        XCTAssertEqual(cd?.type, "CD")
        XCTAssertEqual(cd?.index, 2)

        let cn = EditionParser.parseStackPart("赤壁.上部.2008")
        XCTAssertEqual(cn?.type, "UpperLower")
        XCTAssertEqual(cn?.index, 1)

        XCTAssertEqual(EditionParser.detectDiscType(fileName: "Avatar.iso"), .iso)
        XCTAssertEqual(EditionParser.detectDiscType(fileName: "Avatar", childDirNames: ["BDMV"]), .bdmv)
    }

    // MARK: - 2. 全量反混淆词库与算法（TitleDeobfuscator 674 行 1:1 复刻）

    func testTitleDeobfuscatorFullDictionaryAndMultiStagePipeline() {
        // 1. 港台繁简词组
        XCTAssertEqual(TitleDeobfuscator.traditionalToSimplified("駭客任務"), "黑客帝国")
        XCTAssertEqual(TitleDeobfuscator.traditionalToSimplified("全面啟動"), "盗梦空间")
        XCTAssertEqual(TitleDeobfuscator.traditionalToSimplified("神隱少女"), "千与千寻")

        // 2. 声调拼音 + 中间 Emoji 替字 + 末尾装饰 Emoji 剥离（Què🦴❄️ -> 雀骨）
        let queGu = TitleDeobfuscator.extract("Què🦴❄️")
        XCTAssertTrue(queGu.queries.contains("雀骨"))

        // 3. 多音节 DFS 混合拼音还原（sishen来了 -> 死神来了）
        XCTAssertEqual(TitleDeobfuscator.restoreMixedPinyin("sishen来了"), "死神来了")
        XCTAssertEqual(TitleDeobfuscator.restoreMixedPinyin("X战警"), "X战警") // 全大写不误伤

        // 4. 高置信防和谐谐音词组前置
        let fourGod = TitleDeobfuscator.extract("四神来了 2000")
        XCTAssertEqual(fourGod.queries.first, "死神来了")

        // 5. 全角数字/空格归一化 + 汉字间符号折叠 + 前置字母与系列后缀剥离
        XCTAssertEqual(TitleDeobfuscator.normalizeFullWidth("盗梦空间（２０１０）"), "盗梦空间(2010)")
        XCTAssertEqual(TitleDeobfuscator.collapseHanObfuscation("流★浪★地★球"), "流浪地球")
        let lead = TitleDeobfuscator.extract("J今天是太阳雨")
        XCTAssertTrue(lead.queries.contains("今天是太阳雨"))
    }

    // MARK: - 3. TMDB 网络安全与镜像回退（TmdbNet）

    func testTmdbNetHttpSecurityAndMirrorFallback() async {
        let httpCfg = TmdbNetConfig(apiBase: "http://api.tmdb.org/3")
        XCTAssertNotNil(httpCfg.apiHttpProblem())

        let localCfg = TmdbNetConfig(apiBase: "http://127.0.0.1:8080/3")
        XCTAssertNil(localCfg.apiHttpProblem())

        let norm = TmdbNetConfig(apiBase: "api.tmdb.org", imageBase: "image.tmdb.org/t/p/").normalized()
        XCTAssertEqual(norm.apiBase, "https://api.tmdb.org/3")
        XCTAssertEqual(norm.imageBase, "https://image.tmdb.org")

        let cfg = TmdbNetConfig(imageBase: "https://image.tmdb.org", imageFallback: "https://wsrv.nl/?url=", publicMirrors: true)
        let cands = await TmdbNet.shared.imageCandidates(for: "https://image.tmdb.org/t/p/w500/abc.jpg", config: cfg)
        XCTAssertTrue(cands.contains(where: { $0.absoluteString.contains("media.themoviedb.org/t/p/w500/abc.jpg") }))
        XCTAssertTrue(cands.contains(where: { $0.absoluteString.hasPrefix("https://wsrv.nl/?url=https://image.tmdb.org/t/p/w500/abc.jpg") }))

        // 图片魔数校验：JPEG 通过，HTML 劫持页拒绝
        XCTAssertTrue(TmdbNet.looksLikeImage(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])))
        XCTAssertTrue(TmdbNet.looksLikeImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])))
        XCTAssertFalse(TmdbNet.looksLikeImage(Data("<html>Blocked</html>".utf8)))
    }

    // MARK: - 4. 重复文件检测、云端保留区与冲突分级挂起

    func testContentDigestAndDuplicateDetectorClassifications() {
        let md5A = "0123456789abcdef0123456789abcdef"
        let md5B = "fedcba9876543210fedcba9876543210"
        let e1 = CloudEntry(fileId: "f1", fileName: "Inception.mkv", isDir: false, size: 1000, contentHash: md5A, hashAlgorithm: "MD5")
        let e2 = CloudEntry(fileId: "f2", fileName: "Inception_copy.mkv", isDir: false, size: 1000, contentHash: md5A.uppercased(), hashAlgorithm: "md5")
        let e3 = CloudEntry(fileId: "f3", fileName: "Inception_diff.mkv", isDir: false, size: 1000, contentHash: md5B, hashAlgorithm: "MD5")

        XCTAssertTrue(ContentDigest.isSameContent(e1, e2))
        XCTAssertFalse(ContentDigest.isSameContent(e1, e3))

        let c1 = DuplicateDetector.Candidate(accountId: "a", entry: e1, sourcePath: "/m/Inception.mkv", workKey: "movie:27205", workTitle: "盗梦空间", targetDir: "/m", targetName: "Inception.mkv")
        let c2 = DuplicateDetector.Candidate(accountId: "a", entry: e2, sourcePath: "/m/sub/Inception_copy.mkv", workKey: "movie:27205", workTitle: "盗梦空间", targetDir: "/m", targetName: "Inception.mkv")
        var groups = DuplicateDetector.analyze(candidates: [c1, c2])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .confirmedDuplicate)
        XCTAssertEqual(groups[0].primaryFileId, "f1")
        groups[0].resolution = .moveToRetention
        XCTAssertEqual(groups[0].retentionTargets().map(\.entry.fileId), ["f2"])

        // 校验同目标名不同哈希 -> NAME_CONFLICT
        let c3 = DuplicateDetector.Candidate(accountId: "a", entry: e3, sourcePath: "/m/Inception_diff.mkv", workKey: "movie:27205", workTitle: "盗梦空间", targetDir: "/m", targetName: "Inception.mkv")
        let conflictGroups = DuplicateDetector.analyze(candidates: [c1, c3])
        XCTAssertEqual(conflictGroups.first?.kind, .nameConflict)
    }

    func testConflictPolicyAndDependentActionSuspension() {
        XCTAssertTrue(ConflictPolicy.isDeferrableConflict("目标名称已存在，未覆盖"))
        XCTAssertTrue(ConflictPolicy.isDeferrableConflict("WebDAV HTTP 409 Conflict"))
        XCTAssertFalse(ConflictPolicy.isDeferrableConflict("HTTP 401 Unauthorized"))
        XCTAssertFalse(ConflictPolicy.isDeferrableConflict("HTTP 429 Too Many Requests"))
        XCTAssertFalse(ConflictPolicy.isDeferrableConflict("请求超时 timeout"))
        XCTAssertFalse(ConflictPolicy.isDeferrableConflict("账号凭据已失效"))

        let mk = PlanAction(id: "mk1", op: "mkdir", groupId: "g1", fileId: nil, parentId: "/", oldName: "", newName: "Dir", destParentId: "/", destRef: nil, kind: "folder", mediaKind: "movie", tmdbId: 1, season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let mv = PlanAction(id: "mv1", op: "move", groupId: "g1", fileId: "f1", parentId: "/", oldName: "a.mkv", newName: "a.mkv", destParentId: nil, destRef: "mk1", kind: "file", mediaKind: "movie", tmdbId: 1, season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let indep = PlanAction(id: "rn2", op: "rename", groupId: "g2", fileId: "f2", parentId: "/", oldName: "b.mkv", newName: "B.mkv", destParentId: nil, destRef: nil, kind: "file", mediaKind: "movie", tmdbId: 2, season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let deps = ConflictPolicy.dependentActionIds(conflictAction: mk, allActions: [mk, mv, indep])
        XCTAssertEqual(deps, ["mv1"])
    }

    func testExistingAssetsAndLooseSeriesGrouping() {
        let entries = [
            CloudEntry(fileId: "1", fileName: "folder.jpg", isDir: false),
            CloudEntry(fileId: "2", fileName: "backdrop.png", isDir: false),
            CloudEntry(fileId: "3", fileName: "movie.nfo", isDir: false),
        ]
        XCTAssertTrue(ExistingAssets.hasExistingAsset(in: entries, kind: "image", targetName: "poster.jpg"))
        XCTAssertTrue(ExistingAssets.hasExistingAsset(in: entries, kind: "image", targetName: "fanart.jpg"))
        XCTAssertTrue(ExistingAssets.hasExistingAsset(in: entries, kind: "movie_nfo", targetName: "movie.nfo"))
        XCTAssertFalse(ExistingAssets.hasExistingAsset(in: entries, kind: "clearlogo", targetName: "clearlogo.png"))

        let ep1 = PlanAction(id: "e1", op: "unmatched", groupId: "g1", fileId: "f1", parentId: "/tv", oldName: "Mystery.Show.S01E01.1080p.mkv", newName: "", destParentId: nil, destRef: nil, kind: "file", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil, selected: false, done: false, error: nil, note: nil)
        let ep2 = PlanAction(id: "e2", op: "unmatched", groupId: "g1", fileId: "f2", parentId: "/tv", oldName: "Mystery.Show.S01E02.1080p.mkv", newName: "", destParentId: nil, destRef: nil, kind: "file", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil, selected: false, done: false, error: nil, note: nil)
        let cands = LooseSeriesGrouping.candidates(from: [ep1, ep2])
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].files.count, 2)

        // 集数重复视为歧义，不自动聚组
        let ep2Dup = PlanAction(id: "e3", op: "unmatched", groupId: "g1", fileId: "f3", parentId: "/tv", oldName: "Mystery.Show.S01E02.1080p.mkv", newName: "", destParentId: nil, destRef: nil, kind: "file", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil, selected: false, done: false, error: nil, note: nil)
        XCTAssertTrue(LooseSeriesGrouping.candidates(from: [ep1, ep2, ep2Dup]).isEmpty)
    }

    func testAdaptiveDirectoryPlannerAndSelfContainmentGuard() async {
        let drive = MockCloudDrive()
        drive.listingByFolder["/Library"] = [
            CloudEntry(fileId: "/Library/电影", fileName: "电影", isDir: true),
        ]
        drive.listingByFolder["/Library/电影"] = [
            CloudEntry(fileId: "/Library/电影/Existing (2020)", fileName: "Existing (2020)", isDir: true),
        ]

        var policies = DefaultPolicies()
        policies.adaptiveDirectory = true
        policies.adaptiveTargetDirId = "/Library"
        policies.adaptiveTargetDirPath = "/Library"

        let g1 = PlanGroup(id: "g1", kind: "movie", tmdbId: 100, title: "NewMovie", year: "2024", posterPath: nil, folderId: "/Inbox/NewMovie", folderName: "NewMovie", folderNewName: "NewMovie (2024)", rating: nil, confidence: "高", note: nil, warn: nil, actionIds: [])
        let g2 = PlanGroup(id: "g2", kind: "movie", tmdbId: 101, title: "Existing", year: "2020", posterPath: nil, folderId: "/Inbox/Existing", folderName: "Existing", folderNewName: "Existing (2020)", rating: nil, confidence: "高", note: nil, warn: nil, actionIds: [])
        let plan = ScrapePlan(id: "p1", accountId: "a", provider: "webdav", createdAt: Date(), roots: [], groups: [g1, g2], actions: [], flags: [])

        let out = await AdaptiveDirectoryPlanner.apply(plan: plan, policies: policies, drive: drive)
        XCTAssertEqual(out.actions.filter { $0.kind == AdaptiveDirectoryPlanner.kindAdaptiveMove }.count, 1)
        XCTAssertTrue(out.flags.contains { $0.contains("Existing (2020)") && $0.contains("留在原地") })
    }

    func testCertPinningNormalizationAndFingerprint() {
        let raw = "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
        let norm = CertPinning.normalize(raw.replacingOccurrences(of: ":", with: " "))
        XCTAssertEqual(norm, raw.uppercased())
        XCTAssertNil(CertPinning.normalize("not-a-valid-sha256"))
        XCTAssertEqual(CertPinning.sha256Fingerprint(of: Data("test".utf8)).count, 95) // 32*2 + 31 colons
    }

    @MainActor
    func testCloudRetentionZoneParkRestoreAndDelete() async throws {
        let drive = MockCloudDrive()
        drive.listingByFolder["/"] = []
        let item = try await CloudRetentionZone.parkToCloud(
            fileId: "/Movies/dup.mkv",
            fileName: "dup.mkv",
            originalParentId: "/Movies",
            reason: "测试重复副本",
            drive: drive
        )
        XCTAssertEqual(drive.callOrder.first, "mkdir:/_MediaMind保留区")
        XCTAssertEqual(drive.moved.first?.1, "/_MediaMind保留区")

        try await CloudRetentionZone.restoreFromCloud(item: item, drive: drive)
        XCTAssertEqual(drive.moved.last?.1, "/Movies")
    }

    // MARK: - 5. 三级策略覆盖体系（影片级 > 任务级 > 全局级）与预览筛选

    func testThreeTierPolicyPrecedenceReplanAndPreviewFilter() {
        var global = DefaultPolicies()
        global.movieNaming.defaultSdrWhenMissing = false
        global.movie.fanart = false

        var taskNaming = MediaNamingPrefs.movieDefault()
        taskNaming.defaultSdrWhenMissing = true
        let taskOv = PolicyOverride(movieNaming: taskNaming, downloadFanart: true)

        var filmNaming = MediaNamingPrefs.movieDefault()
        filmNaming.fileTmdbEnabled = false
        filmNaming.keepAudio = false
        let filmOv = PolicyOverride(movieNaming: filmNaming, downloadFanart: false)

        XCTAssertEqual(PolicyResolver.resolve(isTv: false, global: global).sourceLayer, "全局策略")
        XCTAssertEqual(PolicyResolver.resolve(isTv: false, global: global, task: taskOv).sourceLayer, "任务策略")
        let effFilm = PolicyResolver.resolve(isTv: false, global: global, task: taskOv, film: filmOv)
        XCTAssertEqual(effFilm.sourceLayer, "影片策略")
        XCTAssertFalse(effFilm.naming.fileTmdbEnabled)
        XCTAssertFalse(effFilm.downloadFanart)

        let grp = PlanGroup(id: "g1", kind: "movie", tmdbId: 27205, title: "盗梦空间", year: "2010", posterPath: nil, folderId: "d1", folderName: "Inception", folderNewName: nil, rating: nil, confidence: "高", note: nil, warn: nil, actionIds: ["a1"], policyOverride: filmOv)
        let act = PlanAction(id: "a1", op: "rename", groupId: "g1", fileId: "f1", parentId: "d1", oldName: "Inception.2010.1080p.DDP5.1.mkv", newName: "old", destParentId: nil, destRef: nil, kind: "file", mediaKind: "movie", tmdbId: 27205, season: nil, episode: nil, artworkUrl: nil, selected: true, done: false, error: nil, note: nil)
        let plan = ScrapePlan(id: "p1", accountId: "a", provider: "123", createdAt: Date(), roots: [], groups: [grp], actions: [act], flags: [], taskPolicy: taskOv)
        let replanned = PolicyResolver.applyOverrides(to: plan, global: global)
        XCTAssertEqual(replanned.actions[0].newName, "盗梦空间 (2010) - 1080p.mkv")

        XCTAssertEqual(PreviewFilter.apply(groups: [grp], kind: .customPolicy, query: "盗梦").count, 1)
        XCTAssertEqual(PreviewFilter.apply(groups: [grp], kind: .tv, query: "").count, 0)
        XCTAssertEqual(PreviewGrouping.groupedByCategory([grp]).first?.category, "电影")
    }

    // MARK: - 6. 扫描端到端保护、频控、网盘认证、WAL、HistoryStore 与 UpdateChecker

    func testScannerProtectsBdmvAndSkipsOrganizedHistory() async throws {
        let drive = MockCloudDrive()
        drive.listingByFolder["/root"] = [
            CloudEntry(fileId: "/root/AvatarBD", fileName: "AvatarBD", isDir: true),
            CloudEntry(fileId: "/root/DoneMovie", fileName: "DoneMovie", isDir: true),
        ]
        drive.listingByFolder["/root/AvatarBD"] = [
            CloudEntry(fileId: "/root/AvatarBD/BDMV", fileName: "BDMV", isDir: true),
            CloudEntry(fileId: "/root/AvatarBD/CERTIFICATE", fileName: "CERTIFICATE", isDir: true),
        ]
        drive.listingByFolder["/root/DoneMovie"] = [
            CloudEntry(fileId: "/root/DoneMovie/a.mkv", fileName: "a.mkv", isDir: false),
        ]

        struct OfflineEmptyTmdb: ScannerTmdbProvider {
            func show(names: [String], fixedId: Int?) async -> (MatchInfo?, Int) { (nil, -1) }
            func movie(stem: String, fallbackNames: [String], fallbackId: Int?) async -> MatchInfo? { nil }
            func movieInfo(id: Int) async -> MatchInfo? { nil }
            func collectionOf(movieId: Int) async -> (Int, String)? { nil }
        }
        let plan = try await Scanner.scan(
            roots: [PlanRoot(folderId: "/root", name: "root")],
            drive: drive,
            tmdbProvider: OfflineEmptyTmdb(),
            organizedKeys: ["mock-acct|/root/DoneMovie"]
        )
        XCTAssertTrue(plan.flags.contains { $0.contains("BDMV") })
        XCTAssertTrue(plan.flags.contains { $0.contains("历史记录") })
        XCTAssertTrue(plan.actions.isEmpty)
    }

    func testLanHostDetectionRateLimitAimdAndGuangyaE164() async {
        XCTAssertTrue(DriveRateProfile.isLanHost("192.168.1.100"))
        XCTAssertTrue(DriveRateProfile.isLanHost("172.16.0.1"))
        XCTAssertFalse(DriveRateProfile.isLanHost("172.32.0.1"))

        XCTAssertTrue(RateLimitDetector.isRateLimitError(DriveError.rateLimited(code: 142, message: "error")))
        XCTAssertTrue(RateLimitDetector.isRateLimitError(DriveError.rateLimited(code: 405, message: "123pan")))
        XCTAssertFalse(RateLimitDetector.isRateLimitError(DriveError.api(code: 405, message: "光鸭云盘服务异常（HTTP 405）")))
        XCTAssertFalse(RateLimitDetector.isRateLimitError(DriveError.api(code: 142, message: "业务错误")))
        XCTAssertFalse(RateLimitDetector.isRateLimitError(DriveError.api(code: 404, message: "文件 movie_4290.mkv 不存在")))

        let gy = AdaptiveReadRate(profile: .guangya)
        let gyInit = await gy.interval()
        XCTAssertEqual(gyInit, 150)
        await gy.feedback(durationMs: 100, throttled: true, success: false)
        let gyThrottled = await gy.interval()
        XCTAssertEqual(gyThrottled, 2000)

        XCTAssertEqual(GuangyaDrive.normalizePhone("13800138000"), "+86 13800138000")
        XCTAssertEqual(GuangyaDrive.normalizePhone("+14155550100"), "+1 4155550100")
        XCTAssertEqual(GuangyaDrive.normalizePhone("+447911123456"), "+44 7911123456")
        XCTAssertEqual(GuangyaDrive.normalizePhone("+85291234567"), "+852 91234567")
    }

    func testUpdateCheckerSemverAndHistoryStore() async {
        XCTAssertTrue(UpdateChecker.isNewer("v0.5.86", than: "0.5.85"))
        XCTAssertTrue(UpdateChecker.isNewer("0.6.0", than: "0.5.99"))
        XCTAssertFalse(UpdateChecker.isNewer("0.5.85", than: "0.5.85"))
        XCTAssertFalse(UpdateChecker.isNewer("0.5.84", than: "0.5.85"))

        await MainActor.run {
            let tmp = FileManager.default.temporaryDirectory
            let hs = HistoryStore(storageURL: tmp.appendingPathComponent("test_hist_\(UUID().uuidString).json"))
            hs.record(accountId: "a1", provider: "123", folderId: "f1", folderName: "Inception", matchedTitle: "盗梦空间", actionCount: 4)
            hs.record(accountId: "a1", provider: "123", folderId: "f1", folderName: "Inception", matchedTitle: "盗梦空间", actionCount: 5)
            XCTAssertEqual(hs.records.count, 1)
            XCTAssertEqual(hs.records[0].actionCount, 5)
            hs.clear()
            XCTAssertTrue(hs.records.isEmpty)
        }
    }

    @MainActor
    func testOperationJournalWebDavRollbackReconcileAndTaskQueue() async {
        let tmp = FileManager.default.temporaryDirectory
        let journal = OperationJournal(storageURL: tmp.appendingPathComponent("test_journal_\(UUID().uuidString).json"))

        let rMk = journal.prepare(runId: "run1", actionId: "a1", op: "mkdir", kind: "folder", fileId: nil, parentId: "/", destParentId: "/", oldName: "", newName: "OldDir")
        journal.markApplied(rowId: rMk.id, createdId: "/OldDir")
        let rMv = journal.prepare(runId: "run1", actionId: "a2", op: "move", kind: "file", fileId: "/a.mkv", parentId: "/", destParentId: "/OldDir", oldName: "a.mkv", newName: "a.mkv")
        journal.markApplied(rowId: rMv.id, createdId: "/OldDir/a.mkv")
        let rRnFile = journal.prepare(runId: "run1", actionId: "a3", op: "rename", kind: "file", fileId: "/OldDir/a.mkv", parentId: "/OldDir", destParentId: "/OldDir", oldName: "a.mkv", newName: "Inception.mkv")
        journal.markApplied(rowId: rRnFile.id, createdId: "/OldDir/Inception.mkv")
        let rRnDir = journal.prepare(runId: "run1", actionId: "a4", op: "rename", kind: "folder", fileId: "/OldDir", parentId: "/", destParentId: "/", oldName: "OldDir", newName: "Inception (2010)")
        journal.markApplied(rowId: rRnDir.id, createdId: "/Inception (2010)")

        let drive = MockCloudDrive()
        let res = await ReversibleOperations.rollback(runId: "run1", drive: drive, journal: journal)
        XCTAssertEqual(res.undone, 4)
        XCTAssertEqual(res.failed, 0)
        XCTAssertEqual(drive.callOrder, [
            "rename:/Inception (2010)->OldDir",
            "rename:/OldDir/Inception.mkv->a.mkv",
            "move:/OldDir/a.mkv->/",
            "trash:/OldDir",
        ])

        let u1 = journal.prepare(runId: "run2", actionId: "u1", op: "rename", kind: "file", fileId: "/x.mkv", parentId: "/", destParentId: "/", oldName: "x.mkv", newName: "Landed.mkv")
        journal.markUncertain(rowId: u1.id, error: "timeout")
        drive.listingByFolder["/"] = [CloudEntry(fileId: "/Landed.mkv", fileName: "Landed.mkv", isDir: false)]
        let reconciled = await ReversibleOperations.reconcileUncertain(drive: drive, journal: journal)
        XCTAssertEqual(reconciled, 1)
        XCTAssertEqual(journal.rows.first(where: { $0.id == u1.id })?.status, .applied)
    }
}
