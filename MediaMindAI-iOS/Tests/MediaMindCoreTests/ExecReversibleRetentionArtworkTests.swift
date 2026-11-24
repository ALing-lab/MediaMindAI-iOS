import XCTest
#if canImport(MediaMindCore)
@testable import MediaMindCore
#else
@testable import MediaMindAI
#endif

/// 第 5.3 批单元测试套件：
/// 覆盖 ExecutionEngine（五阶段排序/并发判定/有界视频计数）、AdaptiveConcurrencyGate、
/// ConflictPolicy / ExistingAssets / LooseSeriesGrouping、ReversibleWalStore & ReversibleTransaction、
/// RetentionZoneEngine 全生命周期以及 ArtworkFetcher / MovieNfo / NfoFields。
final class ExecReversibleRetentionArtworkTests: XCTestCase {

    // MARK: - 内存虚拟网盘（支持 rename / mkdir / move / moveBatch / upload / trash）

    private final class InMemoryCloudDrive: CloudDrive, @unchecked Sendable {
        struct Node {
            var id: String
            var parentId: String
            var name: String
            var isDir: Bool
            var size: Int64
            var etag: String?
            var contentHash: String?
            var hashAlgorithm: String?
            var data: Data?
        }

        let kind: ProviderKind
        let accountId: String
        let rootId: String
        let trashSupport: TrashSupport

        private let lock = NSLock()
        private var seq: Int = 100
        private var nodes: [String: Node] = [:]
        var trashedIds: [String] = []

        init(
            kind: ProviderKind = .p123,
            accountId: String = "acc-test",
            rootId: String = "0",
            trashSupport: TrashSupport = .recycle
        ) {
            self.kind = kind
            self.accountId = accountId
            self.rootId = rootId
            self.trashSupport = trashSupport
            self.nodes[rootId] = Node(id: rootId, parentId: "", name: "", isDir: true, size: 0)
        }

        @discardableResult
        func seedDir(id: String? = nil, parentId: String, name: String) -> String {
            lock.lock(); defer { lock.unlock() }
            let nid = id ?? nextIdLocked(prefix: "d")
            nodes[nid] = Node(id: nid, parentId: parentId, name: name, isDir: true, size: 0)
            return nid
        }

        @discardableResult
        func seedFile(
            id: String? = nil,
            parentId: String,
            name: String,
            size: Int64 = 1024,
            etag: String? = nil,
            contentHash: String? = nil,
            hashAlgorithm: String? = nil,
            data: Data = Data("dummy".utf8)
        ) -> String {
            lock.lock(); defer { lock.unlock() }
            let nid = id ?? nextIdLocked(prefix: "f")
            nodes[nid] = Node(
                id: nid,
                parentId: parentId,
                name: name,
                isDir: false,
                size: size,
                etag: etag ?? "\"etag-\(nid)\"",
                contentHash: contentHash,
                hashAlgorithm: hashAlgorithm,
                data: data
            )
            return nid
        }

        func node(id: String) -> Node? {
            lock.lock(); defer { lock.unlock() }
            return nodes[id]
        }

        func removeSilently(id: String) {
            lock.lock(); defer { lock.unlock() }
            nodes.removeValue(forKey: id)
        }

        func mutateSize(id: String, newSize: Int64) {
            lock.lock(); defer { lock.unlock() }
            nodes[id]?.size = newSize
        }

        private func nextIdLocked(prefix: String) -> String {
            seq += 1
            return "\(prefix)\(seq)"
        }

        func list(folderId: String) async throws -> [CloudEntry] {
            lock.withLock {
                nodes.values
                    .filter { $0.parentId == folderId && $0.id != folderId }
                    .sorted { $0.name < $1.name }
                    .map {
                        CloudEntry(
                            fileId: $0.id,
                            fileName: $0.name,
                            isDir: $0.isDir,
                            size: $0.size,
                            parentFileId: $0.parentId,
                            etag: $0.etag,
                            contentHash: $0.contentHash,
                            hashAlgorithm: $0.hashAlgorithm
                        )
                    }
            }
        }

        func rename(fileId: String, newName: String) async throws -> String {
            try lock.withLock {
                guard var n = nodes[fileId] else { throw DriveError.invalidInput("not found: \(fileId)") }
                let conflict = nodes.values.contains { $0.parentId == n.parentId && $0.id != fileId && $0.name.caseInsensitiveCompare(newName) == .orderedSame }
                if conflict { throw DriveError.api(code: 409, message: "目标目录已有同名对象") }
                n.name = newName
                nodes[fileId] = n
                return fileId
            }
        }

        func mkdir(parentId: String, name: String) async throws -> String {
            lock.withLock {
                if let existing = nodes.values.first(where: { $0.parentId == parentId && $0.isDir && $0.name == name }) {
                    return existing.id
                }
                let nid = nextIdLocked(prefix: "d")
                nodes[nid] = Node(id: nid, parentId: parentId, name: name, isDir: true, size: 0)
                return nid
            }
        }

        func move(fileId: String, destParentId: String) async throws -> String {
            try lock.withLock {
                guard var n = nodes[fileId] else { throw DriveError.invalidInput("not found: \(fileId)") }
                let conflict = nodes.values.contains { $0.parentId == destParentId && $0.id != fileId && $0.name.caseInsensitiveCompare(n.name) == .orderedSame }
                if conflict { throw DriveError.api(code: 409, message: "目标目录已有同名对象") }
                n.parentId = destParentId
                nodes[fileId] = n
                return fileId
            }
        }

        func upload(parentId: String, name: String, data: Data) async throws -> String {
            lock.withLock {
                if let existing = nodes.values.first(where: { $0.parentId == parentId && $0.name == name }) {
                    var updated = existing
                    updated.size = Int64(data.count)
                    updated.data = data
                    updated.etag = "\"etag-u-\(seq + 1)\""
                    seq += 1
                    nodes[existing.id] = updated
                    return existing.id
                }
                let nid = nextIdLocked(prefix: "u")
                nodes[nid] = Node(id: nid, parentId: parentId, name: name, isDir: false, size: Int64(data.count), etag: "\"etag-\(nid)\"", data: data)
                return nid
            }
        }

        func trash(fileId: String) async throws -> String {
            try lock.withLock {
                guard nodes[fileId] != nil else { throw DriveError.invalidInput("not found") }
                nodes.removeValue(forKey: fileId)
                trashedIds.append(fileId)
                return fileId
            }
        }

        func parentIdOf(fileId: String) async throws -> String? {
            lock.withLock {
                nodes[fileId]?.parentId
            }
        }
    }

    // MARK: - Helper: PlanAction 完整必填参数工厂

    private func makeAction(
        id: String,
        op: String,
        groupId: String = "g1",
        fileId: String? = nil,
        parentId: String? = nil,
        oldName: String = "",
        newName: String = "",
        destParentId: String? = nil,
        destRef: String? = nil,
        destLabel: String? = nil,
        kind: String = "video",
        mediaKind: String? = "movie",
        tmdbId: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        artworkUrl: String? = nil,
        selected: Bool = true,
        done: Bool = false
    ) -> PlanAction {
        PlanAction(
            id: id,
            op: op,
            groupId: groupId,
            fileId: fileId,
            parentId: parentId,
            oldName: oldName,
            newName: newName,
            destParentId: destParentId,
            destRef: destRef,
            destLabel: destLabel,
            kind: kind,
            mediaKind: mediaKind,
            tmdbId: tmdbId,
            season: season,
            episode: episode,
            artworkUrl: artworkUrl,
            selected: selected,
            done: done,
            error: nil,
            note: nil
        )
    }

    // MARK: - 1. ExecPhases & ExecutionEngine 排序 / 并发判定 / 目标解析 / 有界视频扫描

    func testExecPhasesAndExecutionOrder() {
        XCTAssertEqual(ExecPhases.of("rename"), ExecPhases.rename)
        XCTAssertEqual(ExecPhases.of("mkdir"), ExecPhases.mkdir)
        XCTAssertEqual(ExecPhases.of("move"), ExecPhases.move)
        XCTAssertEqual(ExecPhases.of("artwork"), ExecPhases.artwork)
        XCTAssertEqual(ExecPhases.of("delete"), ExecPhases.delete)
        XCTAssertEqual(ExecPhases.of("trash"), ExecPhases.delete)
        XCTAssertEqual(ExecPhases.label(ExecPhases.artwork), "写入海报与 NFO")

        let aDel = makeAction(id: "del", op: "delete", fileId: "/a/empty", oldName: "empty", kind: "folder")
        let aArt = makeAction(id: "art", op: "artwork", newName: "poster.jpg", kind: "image")
        let aMove = makeAction(id: "mov", op: "move", fileId: "/a/f.mkv", oldName: "f.mkv", destParentId: "/dst")
        let aMkdir = makeAction(id: "mk", op: "mkdir", parentId: "/", newName: "Movies", kind: "folder")
        let aRenFile = makeAction(id: "rf", op: "rename", fileId: "/a/f.mkv", oldName: "f.mkv", newName: "Film.mkv", kind: "video")
        let aRenDeepDir = makeAction(id: "rd2", op: "rename", fileId: "/a/b/c", oldName: "c", newName: "Season 01", kind: "folder")
        let aRenShallowDir = makeAction(id: "rd1", op: "rename", fileId: "/a/b", oldName: "b", newName: "Show", kind: "folder")

        let actions = Dictionary(uniqueKeysWithValues: [aDel, aArt, aMove, aMkdir, aRenFile, aRenDeepDir, aRenShallowDir].map { ($0.id, $0) })
        let ordered = ExecutionEngine.executionOrder(
            ids: ["del", "art", "mov", "mk", "rf", "rd2", "rd1"],
            actions: actions
        )
        XCTAssertEqual(ordered, ["rd1", "rd2", "rf", "mk", "mov", "art", "del"])
    }

    func testExecutionEngineConcurrencyAndResolveDest() {
        let ren = makeAction(id: "1", op: "rename", kind: "video")
        let mov = makeAction(id: "2", op: "move", kind: "video")
        let movDisc = makeAction(id: "3", op: "move", kind: "disc_folder")
        let mk = makeAction(id: "4", op: "mkdir", kind: "folder")
        let del = makeAction(id: "5", op: "delete", kind: "folder")

        XCTAssertTrue(ExecutionEngine.canRunConcurrently(ren))
        XCTAssertTrue(ExecutionEngine.canRunConcurrently(mov))
        XCTAssertFalse(ExecutionEngine.canRunConcurrently(movDisc))
        XCTAssertFalse(ExecutionEngine.canRunConcurrently(mk))
        XCTAssertFalse(ExecutionEngine.canRunConcurrently(del))
        XCTAssertFalse(ExecutionEngine.canRunConcurrently(nil))

        let refs = ["action:mk1": "dir-100", "root:Movies": "dir-200"]
        let byRef = makeAction(id: "m1", op: "move", destRef: "mk1")
        let byLabel = makeAction(id: "m2", op: "move", parentId: "root", destLabel: "Movies")
        let byDirect = makeAction(id: "m3", op: "move", destParentId: "dir-direct", destRef: "mk1")

        XCTAssertEqual(ExecutionEngine.resolveDest(action: byRef, refs: refs), "dir-100")
        XCTAssertEqual(ExecutionEngine.resolveDest(action: byLabel, refs: refs), "dir-200")
        XCTAssertEqual(ExecutionEngine.resolveDest(action: byDirect, refs: refs), "dir-direct")
    }

    func testCountVideosBoundedCompleteAndLimitGuards() async throws {
        let drive = InMemoryCloudDrive()
        let top = drive.seedDir(parentId: "0", name: "Show")
        let s1 = drive.seedDir(parentId: top, name: "Season 01")
        drive.seedFile(parentId: s1, name: "E01.mkv")
        drive.seedFile(parentId: s1, name: "E02.mp4")
        drive.seedFile(parentId: s1, name: "poster.jpg")

        let ok = try await ExecutionEngine.countVideosBounded(drive: drive, folderId: top, maxDepth: 4, maxEntries: 50, maxDirs: 10)
        XCTAssertTrue(ok.complete)
        XCTAssertEqual(ok.videos, 2)

        let tooDeep = try await ExecutionEngine.countVideosBounded(drive: drive, folderId: top, maxDepth: 0, maxEntries: 50, maxDirs: 10)
        XCTAssertFalse(tooDeep.complete)

        let tooManyEntries = try await ExecutionEngine.countVideosBounded(drive: drive, folderId: top, maxDepth: 4, maxEntries: 2, maxDirs: 10)
        XCTAssertFalse(tooManyEntries.complete)

        let tooManyDirs = try await ExecutionEngine.countVideosBounded(drive: drive, folderId: top, maxDepth: 4, maxEntries: 50, maxDirs: 1)
        XCTAssertFalse(tooManyDirs.complete)
    }

    // MARK: - 2. AdaptiveConcurrencyGate 只降不升与许可释放

    func testAdaptiveConcurrencyGateDemotionOnlyAndPermitRelease() async throws {
        let gate = AdaptiveConcurrencyGate(levels: [6, 3, 1])
        let initial = await gate.currentLimit
        XCTAssertEqual(initial, 6)

        let afterFirst = await gate.onRateLimited(backoffMs: 1)
        XCTAssertEqual(afterFirst, 3)
        await gate.onSuccess()
        let stillDemoted = await gate.currentLimit
        XCTAssertEqual(stillDemoted, 3, "命中真实风控后只降不升")

        let afterSecond = await gate.onRateLimited(backoffMs: 1, minStepDownGapNs: 0)
        XCTAssertEqual(afterSecond, 1)
        let afterThird = await gate.onRateLimited(backoffMs: 1, minStepDownGapNs: 0)
        XCTAssertEqual(afterThird, 1)

        let value = try await gate.withPermit(skipBackoff: true) { 42 }
        XCTAssertEqual(value, 42)

        do {
            let _: Int = try await gate.withPermit(skipBackoff: true) {
                throw DriveError.network("boom")
            }
            XCTFail("应透传内部异常")
        } catch {
            let recovered = try await gate.withPermit(skipBackoff: true) { 99 }
            XCTAssertEqual(recovered, 99)
        }
    }

    // MARK: - 3. ConflictPolicy / ExistingAssets / LooseSeriesGrouping

    func testConflictPolicyAndExistingAssetsAndLooseGrouping() {
        XCTAssertTrue(ConflictPolicy.isDeferrableConflict("目标目录已有同名对象"))
        XCTAssertTrue(ConflictPolicy.isDeferrableConflict("HTTP 409 conflict: already exists"))
        XCTAssertFalse(ConflictPolicy.isDeferrableConflict("网络超时 timeout"))
        XCTAssertFalse(ConflictPolicy.isDeferrableConflict(nil))

        let conflict = makeAction(id: "a1", op: "rename", groupId: "g1", fileId: "f1", parentId: "p1", oldName: "a.mkv", newName: "b.mkv")
        let sameParentMove = makeAction(id: "a2", op: "move", groupId: "g1", fileId: "f1", parentId: "p1", oldName: "a.mkv", destParentId: "p2")
        let unrelated = makeAction(id: "a3", op: "rename", groupId: "g2", fileId: "f9", parentId: "p9", oldName: "x.mkv", newName: "y.mkv")
        let deps = ConflictPolicy.dependentActionIds(conflictAction: conflict, allActions: [conflict, sameParentMove, unrelated])
        XCTAssertTrue(deps.contains("a2"))
        XCTAssertFalse(deps.contains("a3"))

        XCTAssertEqual(ExistingAssets.imageRole(of: "poster.jpg"), "poster")
        XCTAssertEqual(ExistingAssets.imageRole(of: "fanart.png"), "background")
        XCTAssertEqual(ExistingAssets.imageRole(of: "clearlogo.png"), "logo")
        let entries = [CloudEntry(fileId: "1", fileName: "poster.png", isDir: false, size: 100)]
        XCTAssertTrue(ExistingAssets.hasExistingAsset(in: entries, kind: "image", targetName: "poster.jpg"))
        XCTAssertFalse(ExistingAssets.hasExistingAsset(in: entries, kind: "image", targetName: "fanart.jpg"))

        let looseA = makeAction(id: "l1", op: "rename", groupId: "g", fileId: "f1", parentId: "p", oldName: "Show.S01E01.1080p.mkv")
        let looseB = makeAction(id: "l2", op: "rename", groupId: "g", fileId: "f2", parentId: "p", oldName: "Show.S01E02.1080p.mkv")
        let looseC = makeAction(id: "l3", op: "rename", groupId: "g", fileId: "f3", parentId: "p", oldName: "Random.Movie.2024.mkv")
        let groups = LooseSeriesGrouping.candidates(from: [looseA, looseB, looseC])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.files.count, 2)
    }

    // MARK: - 4. ReversibleWalStore & ReversibleTransaction 全链路事务与逆序回滚

    func testReversibleTransactionForwardAndSafeUndoWithBackup() async throws {
        let walURL = FileManager.default.temporaryDirectory.appendingPathComponent("wal_\(UUID().uuidString).json")
        let wal = ReversibleWalStore(storageURL: walURL)
        let drive = InMemoryCloudDrive(kind: .p123, accountId: "acc-rev", rootId: "0")

        let srcDir = drive.seedDir(id: "d_src", parentId: "0", name: "Inbox")
        let videoId = drive.seedFile(id: "f_vid", parentId: srcDir, name: "raw.mkv", size: 2048)
        let oldPosterId = drive.seedFile(id: "f_old_poster", parentId: srcDir, name: "poster.jpg", size: 500, data: Data("OLD_POSTER".utf8))

        let tx = ReversibleTransaction(taskId: "task-rev-1", drive: drive, wal: wal)

        let renamedId = try await tx.rename(action: "act-ren", id: videoId, parent: srcDir, name: "Inception (2010).mkv")
        XCTAssertEqual(drive.node(id: renamedId)?.name, "Inception (2010).mkv")

        let dstDir = try await tx.mkdir(action: "act-mk", parent: "0", name: "Movies")
        XCTAssertNotNil(drive.node(id: dstDir))

        let movedId = try await tx.move(action: "act-mov", id: renamedId, parent: srcDir, dest: dstDir)
        XCTAssertEqual(drive.node(id: movedId)?.parentId, dstDir)

        let uploaded = try await tx.upload(
            action: "act-art",
            parent: srcDir,
            name: "poster.jpg",
            replaceExisting: true,
            backupScope: AssetBackupScope(rootId: "0", workKey: "g1", workLabel: "盗梦空间", locationLabel: "Inbox")
        ) {
            Data("NEW_POSTER_BYTES".utf8)
        }
        XCTAssertTrue(uploaded)
        let srcEntriesAfterUpload = try await drive.list(folderId: srcDir)
        XCTAssertEqual(srcEntriesAfterUpload.first(where: { $0.fileName == "poster.jpg" })?.size, Int64("NEW_POSTER_BYTES".utf8.count))

        let reloadedWal = ReversibleWalStore(storageURL: walURL)
        XCTAssertGreaterThanOrEqual(reloadedWal.rows(taskId: "task-rev-1").count, 4)

        try await tx.undo()

        XCTAssertEqual(drive.node(id: videoId)?.parentId, srcDir)
        XCTAssertEqual(drive.node(id: videoId)?.name, "raw.mkv")
        XCTAssertEqual(drive.node(id: oldPosterId)?.parentId, srcDir)
        XCTAssertEqual(drive.node(id: oldPosterId)?.name, "poster.jpg")
        XCTAssertTrue(drive.trashedIds.isEmpty)
        let rootNames = try await drive.list(folderId: "0").map(\.fileName)
        XCTAssertTrue(rootNames.contains { $0.hasPrefix(".PanScraper.Undo-") })
    }

    func testReversibleTransactionAuditBackupsThrowsWhenBackupMissing() async throws {
        let walURL = FileManager.default.temporaryDirectory.appendingPathComponent("wal_missing_\(UUID().uuidString).json")
        let wal = ReversibleWalStore(storageURL: walURL)
        let drive = InMemoryCloudDrive(kind: .p123, accountId: "acc-rev2", rootId: "0")

        let srcDir = drive.seedDir(id: "d_src", parentId: "0", name: "Show")
        let oldNfo = drive.seedFile(id: "f_nfo", parentId: srcDir, name: "movie.nfo", size: 120)

        let tx = ReversibleTransaction(taskId: "task-miss", drive: drive, wal: wal)
        _ = try await tx.upload(
            action: "act-nfo",
            parent: srcDir,
            name: "movie.nfo",
            replaceExisting: true,
            backupScope: AssetBackupScope(rootId: "0", workKey: "g1", workLabel: "测试电影", locationLabel: "Show")
        ) {
            Data("<movie><title>New</title></movie>".utf8)
        }

        drive.removeSilently(id: oldNfo)

        do {
            try await tx.auditBackups()
            XCTFail("备份缺失时 auditBackups 必须抛出 MissingBackupsError")
        } catch let err as MissingBackupsError {
            XCTAssertEqual(err.files.count, 1)
            XCTAssertEqual(err.files.first?.fileName, "movie.nfo")
        }
    }

    // MARK: - 5. RetentionZoneEngine 保留区移入、恢复、保护期与清理核验

    @MainActor
    func testRetentionZoneMoveRestoreProtectAndCleanup() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let wal = ReversibleWalStore(storageURL: tmp.appendingPathComponent("ret_wal_\(UUID().uuidString).json"))
        let engine = RetentionZoneEngine(
            registryURL: tmp.appendingPathComponent("ret_reg_\(UUID().uuidString).json"),
            wal: wal
        )
        let drive = InMemoryCloudDrive(kind: .p123, accountId: "acc-ret", rootId: "0", trashSupport: .recycle)

        XCTAssertTrue(RetentionZoneEngine.isProtectedPath(".PanScraper.Undo-t1/a.mkv"))
        XCTAssertTrue(RetentionZoneEngine.isProtectedPath(".PanScraper.Backup-t1/poster.jpg"))
        XCTAssertTrue(RetentionZoneEngine.isProtectedPath("Movies/Inception.mkv"))
        XCTAssertFalse(RetentionZoneEngine.isProtectedPath("\(RetentionZoneEngine.rootDir)/确定重复/t1/w/k/a.mkv"))

        let srcDir = drive.seedDir(id: "d_inbox", parentId: "0", name: "Inbox")
        let dupId = drive.seedFile(id: "f_dup", parentId: srcDir, name: "Dup.mkv", size: 4096, contentHash: "abc123", hashAlgorithm: "md5")
        let dupEntry = try await drive.list(folderId: srcDir).first { $0.fileId == dupId }!

        let tx = ReversibleTransaction(taskId: "t-ret-1", drive: drive, wal: wal)
        let rec = try await engine.moveToRetention(
            ops: tx,
            drive: drive,
            taskId: "t-ret-1",
            actionId: "act-dup-1",
            entry: dupEntry,
            originalParentId: srcDir,
            originalPath: "/Inbox/Dup.mkv",
            workTitle: "测试作品",
            confirmedDuplicate: true,
            reason: "MD5 完全一致"
        )
        XCTAssertEqual(rec.status, RetentionZoneEngine.statusRetained)
        XCTAssertEqual(rec.category, RetentionZoneEngine.catConfirmed)
        XCTAssertNotEqual(drive.node(id: dupId)?.parentId, srcDir)

        let protectedRunning = engine.cleanupProtectedTaskIds(records: [rec], activeTaskStatuses: ["t-ret-1": "running"])
        XCTAssertTrue(protectedRunning.contains("t-ret-1"))

        drive.mutateSize(id: dupId, newSize: 9999)
        let badChecks = await engine.verifyForCleanup(records: [rec], drive: drive, activeTaskIds: [])
        XCTAssertEqual(badChecks.count, 1)
        XCTAssertFalse(badChecks[0].verified)

        drive.mutateSize(id: dupId, newSize: 4096)
        let goodChecks = await engine.verifyForCleanup(records: [rec], drive: drive, activeTaskIds: [])
        XCTAssertEqual(goodChecks.count, 1)
        XCTAssertTrue(goodChecks[0].verified)

        let outcome = try await engine.cleanupVerified(checks: goodChecks, drive: drive)
        XCTAssertEqual(outcome.cleaned, 1)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertTrue(drive.trashedIds.contains(dupId))

        let dup2Id = drive.seedFile(id: "f_dup2", parentId: srcDir, name: "Dup2.mkv", size: 2048)
        let dup2Entry = try await drive.list(folderId: srcDir).first { $0.fileId == dup2Id }!
        let rec2 = try await engine.moveToRetention(
            ops: tx,
            drive: drive,
            taskId: "t-ret-1",
            actionId: "act-dup-2",
            entry: dup2Entry,
            originalParentId: srcDir,
            originalPath: "/Inbox/Dup2.mkv",
            workTitle: "测试作品",
            confirmedDuplicate: false,
            reason: "疑似重复"
        )
        let restored = try await engine.restoreRecord(recordId: rec2.recordId, drive: drive)
        XCTAssertEqual(restored.status, RetentionZoneEngine.statusRestored)
        XCTAssertEqual(drive.node(id: dup2Id)?.parentId, srcDir)
    }

    // MARK: - 6. ArtworkFetcher 分辨率/多语言优选 + MovieNfo 构建 + NfoFields 过滤

    func testArtworkFetcherImageSizeAndPickPath() {
        XCTAssertEqual(ArtworkFetcher.imageSize(slot: "poster", quality: "original"), "original")
        XCTAssertEqual(ArtworkFetcher.imageSize(slot: "backdrop", quality: "compact"), "w780")
        XCTAssertEqual(ArtworkFetcher.imageSize(slot: "poster", quality: "compact"), "w500")
        XCTAssertEqual(ArtworkFetcher.imageSize(slot: "logo", quality: nil), "original")
        XCTAssertEqual(ArtworkFetcher.imageSize(slot: "backdrop", quality: nil), "w1280")
        XCTAssertEqual(ArtworkFetcher.imageSize(slot: "poster", quality: nil), "w780")

        let json = """
        {
          "posters": [
            {"iso_639_1": "en", "vote_average": 9.5, "width": 2000, "file_path": "/en_best.jpg"},
            {"iso_639_1": "zh", "vote_average": 6.0, "width": 1000, "file_path": "/zh_low.jpg"},
            {"iso_639_1": "zh", "vote_average": 8.0, "width": 1500, "file_path": "/zh_high.jpg"},
            {"iso_639_1": null, "vote_average": 7.5, "width": 1800, "file_path": "/clean.jpg"}
          ]
        }
        """
        let data = Data(json.utf8)

        XCTAssertEqual(ArtworkFetcher.pickPath(jsonData: data, key: "posters", langs: ["zh", "en", nil]), "/zh_high.jpg")
        XCTAssertEqual(ArtworkFetcher.pickPath(jsonData: data, key: "posters", langs: [nil, "zh"]), "/clean.jpg")
        XCTAssertNil(ArtworkFetcher.pickPath(jsonData: data, key: "posters", langs: ["ja"]))
    }

    func testMovieNfoBuildAndNfoFieldsFilter() {
        let detailJson = """
        {
          "title": "Inception",
          "original_title": "Inception",
          "overview": "A thief who steals corporate secrets.\\nLine 2.",
          "tagline": "Your mind is the scene of the crime.",
          "runtime": 148,
          "release_date": "2010-07-16",
          "vote_average": 8.36,
          "imdb_id": "tt1375666",
          "genres": [{"name": "科幻"}, {"name": "动作"}],
          "production_countries": [{"name": "United States of America"}],
          "production_companies": [{"name": "Syncopy"}],
          "belongs_to_collection": {"name": "Dream Collection"}
        }
        """
        let creditsJson = """
        {
          "crew": [
            {"id": 525, "job": "Director", "name": "Christopher Nolan"},
            {"id": 525, "job": "Director", "name": "Christopher Nolan"},
            {"id": 525, "job": "Writer", "name": "Christopher Nolan"}
          ],
          "cast": [
            {"id": 6193, "name": "Leonardo DiCaprio", "character": "Cobb"}
          ]
        }
        """
        let xml = MovieNfo.build(
            mid: 27205,
            detailData: Data(detailJson.utf8),
            creditsData: Data(creditsJson.utf8),
            zhTitle: "盗梦空间"
        )
        XCTAssertTrue(xml.contains("<title>盗梦空间</title>"))
        XCTAssertTrue(xml.contains("<originaltitle>Inception</originaltitle>"))
        XCTAssertTrue(xml.contains("<year>2010</year>"))
        XCTAssertTrue(xml.contains("<rating>8.4</rating>"))
        XCTAssertTrue(xml.contains("<uniqueid type=\"imdb\" default=\"true\">tt1375666</uniqueid>"))
        XCTAssertTrue(xml.contains("<uniqueid type=\"tmdb\" default=\"false\">27205</uniqueid>"))
        XCTAssertTrue(xml.contains("<name>Dream Collection</name>"))
        XCTAssertEqual(xml.components(separatedBy: "<director ").count - 1, 1)

        var sel = NfoFieldSelection()
        sel.rating = false
        sel.plot = false
        sel.aired = false
        let filtered = NfoFields.filter(xml: xml, selection: sel)
        XCTAssertFalse(filtered.contains("<rating>"))
        XCTAssertFalse(filtered.contains("<plot>"))
        XCTAssertFalse(filtered.contains("<premiered>"))
        XCTAssertTrue(filtered.contains("<title>盗梦空间</title>"))
        XCTAssertTrue(filtered.contains("<tmdbid>27205</tmdbid>"))
    }

    func testReversibleTransactionMoveBatchAndUndo() async throws {
        let walURL = FileManager.default.temporaryDirectory.appendingPathComponent("wal_batch_\(UUID().uuidString).json")
        let wal = ReversibleWalStore(storageURL: walURL)
        let drive = InMemoryCloudDrive(kind: .p123, accountId: "acc-batch", rootId: "0")
        let src = drive.seedDir(id: "d_s", parentId: "0", name: "Src")
        let dst = drive.seedDir(id: "d_d", parentId: "0", name: "Dst")
        let f1 = drive.seedFile(id: "f_b1", parentId: src, name: "E01.mkv", size: 1000)
        let f2 = drive.seedFile(id: "f_b2", parentId: src, name: "E02.mkv", size: 1000)
        let tx = ReversibleTransaction(taskId: "t-batch-1", drive: drive, wal: wal)
        let moved = try await tx.moveBatch(items: [
            BatchMoveItem(action: "m1", id: f1, parent: src),
            BatchMoveItem(action: "m2", id: f2, parent: src),
        ], dest: dst)
        XCTAssertEqual(moved.count, 2)
        try await tx.undo()
        XCTAssertEqual(drive.node(id: f1)?.parentId, src)
        XCTAssertEqual(drive.node(id: f2)?.parentId, src)
    }

    func testSeriesMergerMergeSplitTvSeasons() {
        let g1 = PlanGroup(id: "g1", kind: "tv", tmdbId: 1396, title: "绝命毒师", year: "2008", posterPath: nil, folderId: "d1", folderName: "Breaking.Bad.S01", folderNewName: "绝命毒师 (2008)", rating: 9.0, confidence: "high", note: nil, warn: nil, actionIds: ["a1"])
        let g2 = PlanGroup(id: "g2", kind: "tv", tmdbId: 1396, title: "绝命毒师", year: "2008", posterPath: nil, folderId: "d2", folderName: "Breaking.Bad.S02", folderNewName: "绝命毒师 (2008)", rating: 9.0, confidence: "high", note: nil, warn: nil, actionIds: ["a2"])
        let a1 = makeAction(id: "a1", op: "rename", groupId: "g1", fileId: "f1", parentId: "d1", oldName: "S01E01.mkv", newName: "绝命毒师 S01E01.mkv", mediaKind: "tv", tmdbId: 1396, season: 1, episode: 1)
        let a2 = makeAction(id: "a2", op: "rename", groupId: "g2", fileId: "f2", parentId: "d2", oldName: "S02E01.mkv", newName: "绝命毒师 S02E01.mkv", mediaKind: "tv", tmdbId: 1396, season: 2, episode: 1)
        let plan = ScrapePlan(id: "p-merge", accountId: "a", provider: "123", createdAt: Date(), roots: [], groups: [g1, g2], actions: [a1, a2], flags: [])
        let merged = SeriesMerger.mergeSplitTvSeasons(plan)
        XCTAssertEqual(merged.groups.count, 1)
        XCTAssertEqual(Set(merged.actions.map(\.groupId)), Set(["g1"]))
    }

    func testFailedRetryDependencyClosureAndTaskDeletion() {
        let mk = makeAction(id: "mk1", op: "mkdir", fileId: nil, parentId: "0", oldName: "", newName: "盗梦空间 (2010)")
        let mv = makeAction(id: "mv1", op: "move", fileId: "f1", parentId: "0", oldName: "dm.mkv", newName: "dm.mkv", destRef: "mk1")
        let plan = ScrapePlan(
            id: "plan-retry-test",
            accountId: "acc-test",
            provider: "123",
            createdAt: Date(),
            roots: [],
            groups: [],
            actions: [mk, mv],
            flags: []
        )

        // 1. 勾选失败的 move 时自动连带勾选失败的上游 mkdir
        let failedBoth: Set<String> = ["mk1", "mv1"]
        let selOn = FailedRetry.toggle(selected: [], ids: ["mv1"], on: true, failed: failedBoth, plan: plan)
        XCTAssertEqual(selOn, ["mk1", "mv1"])

        // 2. 取消勾选 mkdir 时自动连带取消依赖它的下游 move
        let selOff = FailedRetry.toggle(selected: selOn, ids: ["mk1"], on: false, failed: failedBoth, plan: plan)
        XCTAssertTrue(selOff.isEmpty)

        // 3. 即使 mkdir 不在 failed 集合里，只要未完成（done == false），retryIds 仍会将其前置加入执行列表
        let idsToRun = FailedRetry.retryIds(selected: ["mv1"], plan: plan)
        XCTAssertEqual(idsToRun, ["mk1", "mv1"])
    }
}
