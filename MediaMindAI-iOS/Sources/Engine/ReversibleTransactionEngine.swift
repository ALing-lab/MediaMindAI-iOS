import Foundation
import CryptoKit

/// 1:1 逐行复刻自 Android `ReversibleOperations.kt`（422 行 / 29.4 KB）：
/// 先落盘 WAL 意图再执行云端写操作；支持单条/批量移动前置全量核对与异常核实、两阶段防复用 `mkdir`、
/// 覆盖上传前分层备份（`.PanScraper.Backup-<task>`）、暂存隔离（`.PanScraper.Trash-<task>`）、
/// 单条保留区恢复（`revertSingle`）、缺失备份审计与替换（`auditBackups`/`substituteNewFile`）以及严格逆序安全回滚（`undo`）。

public struct RemoteSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let parent: String
    public let name: String
    public let directory: Bool
    public let size: Int64
    public let etag: String?
    public let workLabel: String?

    public init(
        id: String,
        parent: String,
        name: String,
        directory: Bool,
        size: Int64 = 0,
        etag: String? = nil,
        workLabel: String? = nil
    ) {
        self.id = id
        self.parent = parent
        self.name = name
        self.directory = directory
        self.size = size
        self.etag = etag
        self.workLabel = workLabel
    }

    public static func from(_ entry: CloudEntry, parent: String, workLabel: String? = nil) -> RemoteSnapshot {
        RemoteSnapshot(
            id: entry.fileId,
            parent: parent,
            name: entry.fileName,
            directory: entry.isDir,
            size: entry.size,
            etag: entry.etag,
            workLabel: workLabel
        )
    }

    public func with(
        id: String? = nil,
        parent: String? = nil,
        name: String? = nil,
        size: Int64? = nil,
        etag: String? = nil,
        workLabel: String? = nil
    ) -> RemoteSnapshot {
        RemoteSnapshot(
            id: id ?? self.id,
            parent: parent ?? self.parent,
            name: name ?? self.name,
            directory: self.directory,
            size: size ?? self.size,
            etag: etag ?? self.etag,
            workLabel: workLabel ?? self.workLabel
        )
    }
}

public struct MissingBackup: Identifiable, Codable, Hashable, Sendable {
    public let actionId: String
    public let work: String
    public let fileName: String
    public var id: String { actionId }

    public init(actionId: String, work: String, fileName: String) {
        self.actionId = actionId
        self.work = work
        self.fileName = fileName
    }
}

public struct MissingBackupsError: LocalizedError, Sendable {
    public let files: [MissingBackup]

    public init(files: [MissingBackup]) {
        self.files = files
    }

    public var errorDescription: String? {
        "有 \(files.count) 个原备份缺失，当前文件保留，请选择处理方式"
    }
}

public struct AssetBackupScope: Hashable, Sendable {
    public let rootId: String
    public let workKey: String
    public let workLabel: String
    public let locationLabel: String

    public init(rootId: String, workKey: String, workLabel: String, locationLabel: String) {
        self.rootId = rootId
        self.workKey = workKey
        self.workLabel = workLabel
        self.locationLabel = locationLabel
    }
}

public struct BatchMoveItem: Hashable, Sendable {
    public let action: String
    public let id: String
    public let parent: String
    public let operation: String
    public let workLabel: String?

    public init(action: String, id: String, parent: String, operation: String = "move", workLabel: String? = nil) {
        self.action = action
        self.id = id
        self.parent = parent
        self.operation = operation
        self.workLabel = workLabel
    }
}

public struct ReversibleWalRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let taskId: String
    public let accountId: String
    public let actionId: String
    public let operation: String
    public let sequence: Int
    public var state: String // "prepared" | "applied" | "skipped" | "not_applied" | "uncertain" | "undo_prepared" | "reverted" | "substituted" | "substitution_output" | "conflict"
    public var before: RemoteSnapshot?
    public var after: RemoteSnapshot?
    public var undoResult: RemoteSnapshot?
    public var error: String?

    public init(
        id: String = UUID().uuidString,
        taskId: String,
        accountId: String,
        actionId: String,
        operation: String,
        sequence: Int,
        state: String = "prepared",
        before: RemoteSnapshot? = nil,
        after: RemoteSnapshot? = nil,
        undoResult: RemoteSnapshot? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.accountId = accountId
        self.actionId = actionId
        self.operation = operation
        self.sequence = sequence
        self.state = state
        self.before = before
        self.after = after
        self.undoResult = undoResult
        self.error = error
    }
}

/// 线程安全的可逆 WAL 事务存储（与 `ReversibleTransaction` 配套，支持单测注入独立临时路径）。
public final class ReversibleWalStore: @unchecked Sendable {
    public static let shared = ReversibleWalStore()

    private let lock = NSRecursiveLock()
    private let storageURL: URL
    private var records: [ReversibleWalRecord] = []

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("MediaMindAI", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("reversible_wal.json")
        }
        load()
    }

    private var _lastStorageError: String?
    private var _isCorrupt: Bool = false

    public var lastStorageError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastStorageError
    }

    public var hasStorageCorruption: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCorrupt
    }

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            guard !data.isEmpty else { return }
            records = try JSONDecoder().decode([ReversibleWalRecord].self, from: data)
            _lastStorageError = nil
            _isCorrupt = false
        } catch {
            // 保护损坏的 WAL 文件不被空数组覆盖销毁：备份为 .corrupt 文件并锁定写路径（fail-closed）
            let ts = Int(Date().timeIntervalSince1970)
            let backup = storageURL.deletingPathExtension().appendingPathExtension("corrupt.\(ts).json")
            try? FileManager.default.copyItem(at: storageURL, to: backup)
            _isCorrupt = true
            _lastStorageError = "可逆日志读取损坏（已备份至 \(backup.lastPathComponent)），已阻止写入以防覆盖历史日志：\(error.localizedDescription)"
        }
    }

    private func persistLocked() {
        guard !_isCorrupt else { return }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageURL, options: .atomic)
            _lastStorageError = nil
        } catch {
            _lastStorageError = "可逆日志写盘失败：\(error.localizedDescription)"
        }
    }

    public func find(taskId: String, actionId: String) -> ReversibleWalRecord? {
        lock.lock(); defer { lock.unlock() }
        return records.last { $0.taskId == taskId && $0.actionId == actionId }
    }

    public func uncertainRecords() -> [ReversibleWalRecord] {
        lock.lock(); defer { lock.unlock() }
        let states: Set<String> = ["prepared", "uncertain", "undo_prepared"]
        return records.filter { states.contains($0.state) }.sorted { $0.sequence < $1.sequence }
    }

    public func hasUncertain(taskId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let states: Set<String> = ["prepared", "uncertain", "undo_prepared"]
        return records.contains { $0.taskId == taskId && states.contains($0.state) }
    }

    public func rows(taskId: String) -> [ReversibleWalRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.taskId == taskId }.sorted { $0.sequence > $1.sequence }
    }

    public func appliedRecords(
        accountId: String,
        actionIds: Set<String>,
        taskIds: Set<String>? = nil
    ) -> [ReversibleWalRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.filter { rec in
            guard rec.accountId == accountId && (rec.state == "applied" || rec.state == "skipped") else { return false }
            if let taskIds, !taskIds.isEmpty, !taskIds.contains(rec.taskId) { return false }
            if actionIds.contains(rec.actionId) { return true }
            if rec.actionId.hasSuffix(":finalize") {
                let base = String(rec.actionId.dropLast(":finalize".count))
                return actionIds.contains(base)
            }
            if rec.actionId.hasSuffix(":backup") {
                let base = String(rec.actionId.dropLast(":backup".count))
                return actionIds.contains(base)
            }
            return false
        }
    }

    public func prepare(
        taskId: String,
        accountId: String,
        actionId: String,
        operation: String,
        before: RemoteSnapshot?,
        after: RemoteSnapshot?
    ) throws -> ReversibleWalRecord {
        lock.lock(); defer { lock.unlock() }
        if _isCorrupt {
            throw DriveError.invalidInput(_lastStorageError ?? "可逆日志已损坏，已阻止写入以防数据丢失")
        }
        // 若存在已核实未生效的旧行，先删除再写入新行
        records.removeAll { $0.taskId == taskId && $0.actionId == actionId && $0.state == "not_applied" }
        // 严禁对同一 (taskId, actionId) 并发重入或覆盖任何非 not_applied 活跃/终态行（1:1 对标 Android UNIQUE(taskId, actionId)）
        if let existing = records.last(where: { $0.taskId == taskId && $0.actionId == actionId }) {
            throw DriveError.invalidInput("操作记录已存在（\(existing.state)），已停止以避免重复写入")
        }
        let nextSeq = (records.filter { $0.taskId == taskId }.map(\.sequence).max() ?? 0) + 1
        let rec = ReversibleWalRecord(
            taskId: taskId,
            accountId: accountId,
            actionId: actionId,
            operation: operation,
            sequence: nextSeq,
            state: "prepared",
            before: before,
            after: after
        )
        records.append(rec)
        persistLocked()
        if let err = _lastStorageError {
            records.removeAll { $0.id == rec.id }
            throw DriveError.invalidInput(err)
        }
        return rec
    }

    public func change(_ rec: ReversibleWalRecord, state: String, after: RemoteSnapshot? = nil, error: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let idx = records.lastIndex(where: { $0.id == rec.id }) {
            records[idx].state = state
            if let after { records[idx].after = after }
            records[idx].error = error
            persistLocked()
        }
    }

    public func reverted(_ rec: ReversibleWalRecord, undoResult: RemoteSnapshot?, substituted: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if let idx = records.lastIndex(where: { $0.id == rec.id }) {
            records[idx].state = substituted ? "substituted" : "reverted"
            records[idx].undoResult = undoResult
            records[idx].error = nil
            persistLocked()
        }
    }

    public func clear(taskId: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let taskId {
            records.removeAll { $0.taskId == taskId }
        } else {
            records.removeAll()
        }
        persistLocked()
    }
}

/// 1:1 复刻 Android `ReversibleOperations` 核心事务执行器。
private actor BackupDirCoalescer {
    private var inFlight: [String: Task<String, Error>] = [:]

    func run(key: String, create: @escaping @Sendable () async throws -> String) async throws -> String {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<String, Error> {
            try await create()
        }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        return try await task.value
    }
}

public final class ReversibleTransaction: @unchecked Sendable {
    public let taskId: String
    public let drive: any CloudDrive
    public let wal: ReversibleWalStore
    public let cancellationCheck: @Sendable () -> Bool
    private let backupDirCoalescer = BackupDirCoalescer()

    public init(
        taskId: String,
        drive: any CloudDrive,
        wal: ReversibleWalStore = .shared,
        cancellationCheck: @escaping @Sendable () -> Bool = { false }
    ) {
        self.taskId = taskId
        self.drive = drive
        self.wal = wal
        self.cancellationCheck = cancellationCheck
    }

    private func isStrongEtag(_ etag: String?) -> Bool {
        guard let e = etag, !e.isEmpty else { return false }
        return !e.lowercased().hasPrefix("w/")
    }

    private func shortKey(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func snapshot(id: String, parent: String) async throws -> RemoteSnapshot {
        let list = try await drive.list(folderId: parent)
        let matches = list.filter { $0.fileId == id }
        guard matches.count == 1 else {
            throw DriveError.invalidInput("找不到待操作对象，未写入云盘")
        }
        return RemoteSnapshot.from(matches[0], parent: parent)
    }

    private func uniqueTarget(parent: String, name: String) async throws -> CloudEntry? {
        let found = try await drive.list(folderId: parent).filter { $0.fileName.caseInsensitiveCompare(name) == .orderedSame }
        guard found.count <= 1 else {
            throw DriveError.invalidInput("目标有多个同名对象，未写入，请先手动核实")
        }
        return found.first
    }

    @discardableResult
    private func verify(_ s: RemoteSnapshot) async throws -> RemoteSnapshot {
        let now = try await snapshot(id: s.id, parent: s.parent)
        let ok = now.name == s.name
            && now.directory == s.directory
            && (s.directory || now.size == s.size)
            && (s.directory || s.etag == nil || now.etag == s.etag)
        guard ok else {
            throw DriveError.invalidInput("对象已被修改，请核实后再处理")
        }
        return now
    }

    private func known(action: String) throws -> ReversibleWalRecord? {
        guard let row = wal.find(taskId: taskId, actionId: action) else { return nil }
        guard row.accountId == drive.accountId else {
            throw DriveError.invalidInput("操作日志账号不匹配")
        }
        if row.state == "not_applied" { return nil }
        guard row.state == "applied" || row.state == "skipped" else {
            throw DriveError.invalidInput("操作结果待核实，已停止以避免重复写入（\(row.state)）")
        }
        return row
    }

    private func replay(_ row: ReversibleWalRecord) async throws -> String {
        guard let after = row.after else {
            throw DriveError.invalidInput("日志缺少执行结果")
        }
        _ = try await verify(after)
        return after.id
    }

    private func write(_ row: ReversibleWalRecord, block: () async throws -> String) async throws -> String {
        if cancellationCheck() {
            wal.change(row, state: "not_applied", error: "任务已取消，未发送写请求")
            throw DriveError.invalidInput("任务已取消，未发送写请求")
        }
        do {
            let id = try await block()
            guard let intended = row.after else { throw DriveError.invalidInput("日志缺少预期状态") }
            let after = try await snapshot(id: id, parent: intended.parent).with(workLabel: intended.workLabel)
            guard after.name == intended.name && after.directory == intended.directory else {
                throw DriveError.invalidInput("网盘操作尚未生效，请稍后核实")
            }
            wal.change(row, state: "applied", after: after)
            return id
        } catch is CancellationError {
            wal.change(row, state: "uncertain", error: "请求中断，需核实远端状态")
            throw CancellationError()
        } catch {
            let state = RateLimitDetector.isRateLimitError(error) ? "not_applied" : "uncertain"
            wal.change(row, state: state, error: error.localizedDescription)
            throw error
        }
    }

    // MARK: - 1. rename / move / moveBatch / mkdir / upload / quarantine

    public func rename(action: String, id: String, parent: String, name: String, operation: String = "rename") async throws -> String {
        if let existing = try known(action: action) { return try await replay(existing) }
        let before = try await snapshot(id: id, parent: parent)
        let siblings = try await drive.list(folderId: parent)
        guard !siblings.contains(where: { $0.fileId != id && $0.fileName.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw DriveError.invalidInput("目标名称已存在，未覆盖")
        }
        let row = try wal.prepare(taskId: taskId, accountId: drive.accountId, actionId: action, operation: operation, before: before, after: before.with(name: name))
        return try await write(row) {
            try await self.drive.rename(fileId: id, newName: name)
        }
    }

    public func move(action: String, id: String, parent: String, dest: String, operation: String = "move", workLabel: String? = nil) async throws -> String {
        if let existing = try known(action: action) { return try await replay(existing) }
        let before = try await snapshot(id: id, parent: parent).with(workLabel: workLabel)
        let destList = try await drive.list(folderId: dest)
        guard !destList.contains(where: { $0.fileId != id && $0.fileName.caseInsensitiveCompare(before.name) == .orderedSame }) else {
            throw DriveError.invalidInput("目标目录已有同名对象，未覆盖")
        }
        let row = try wal.prepare(taskId: taskId, accountId: drive.accountId, actionId: action, operation: operation, before: before, after: before.with(parent: dest))
        return try await write(row) {
            try await self.drive.move(fileId: id, destParentId: dest)
        }
    }

    /// 1:1 复刻 `ReversibleOperations.moveBatch`：先全量核对再统一写 WAL，异常后逐项核实已到达目标的项。
    public func moveBatch(items: [BatchMoveItem], dest: String) async throws -> [String: String] {
        if items.count <= 1 {
            guard let one = items.first else { return [:] }
            let movedId = try await move(action: one.action, id: one.id, parent: one.parent, dest: dest, operation: one.operation, workLabel: one.workLabel)
            return [one.action: movedId]
        }

        var out: [String: String] = [:]
        var pending: [BatchMoveItem] = []
        for item in items {
            if let prev = try known(action: item.action) {
                out[item.action] = try await replay(prev)
            } else {
                pending.append(item)
            }
        }
        if pending.isEmpty { return out }

        var parentLists: [String: [CloudEntry]] = [:]
        for p in Set(pending.map(\.parent)) {
            parentLists[p] = try await drive.list(folderId: p)
        }
        let destList = try await drive.list(folderId: dest)
        let pendingIds = Set(pending.map(\.id))
        var destNames = Set(destList.filter { !pendingIds.contains($0.fileId) }.map { $0.fileName.lowercased() })

        // 先全量核对、再统一写 WAL（任一项核对失败时不留下任何 prepared 行）
        var befores: [(BatchMoveItem, RemoteSnapshot)] = []
        for item in pending {
            let matches = (parentLists[item.parent] ?? []).filter { $0.fileId == item.id }
            guard matches.count == 1 else {
                throw DriveError.invalidInput("找不到待操作对象，未写入云盘")
            }
            let before = RemoteSnapshot.from(matches[0], parent: item.parent, workLabel: item.workLabel)
            let clash = destList.contains { $0.fileId != item.id && $0.fileName.caseInsensitiveCompare(before.name) == .orderedSame }
            guard !clash && destNames.insert(before.name.lowercased()).inserted else {
                throw DriveError.invalidInput("目标目录已有同名对象，未覆盖")
            }
            befores.append((item, before))
        }

        var prepared: [(BatchMoveItem, ReversibleWalRecord)] = []
        do {
            for (item, before) in befores {
                let row = try wal.prepare(taskId: taskId, accountId: drive.accountId, actionId: item.action, operation: item.operation, before: before, after: before.with(parent: dest))
                prepared.append((item, row))
            }
        } catch {
            // 任一项落盘失败时回滚本批次已写 prepared 行，保证未发请求时不留孤儿 WAL
            for (_, row) in prepared {
                wal.change(row, state: "not_applied", error: "批次准备失败，未发送写请求")
            }
            throw error
        }

        if cancellationCheck() {
            for (_, row) in prepared { wal.change(row, state: "not_applied", error: "任务已取消，未发送写请求") }
            throw DriveError.invalidInput("任务已取消，未发送写请求")
        }

        do {
            let moved = try await drive.moveBatch(fileIds: prepared.map(\.0.id), destParentId: dest)
            let afterEntries = Dictionary(try await drive.list(folderId: dest).map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
            for (item, row) in prepared {
                let newId = moved[item.id] ?? item.id
                guard let intended = row.after, let e = afterEntries[newId] else {
                    throw DriveError.invalidInput("网盘批量移动尚未生效，请稍后核实")
                }
                let after = RemoteSnapshot.from(e, parent: dest, workLabel: intended.workLabel)
                guard after.name == intended.name && after.directory == intended.directory else {
                    throw DriveError.invalidInput("网盘操作尚未生效，请稍后核实")
                }
                wal.change(row, state: "applied", after: after)
                out[item.action] = newId
            }
            return out
        } catch is CancellationError {
            await Task { await self.reconcileBatch(prepared: prepared, dest: dest, errorMsg: "请求中断，需核实远端状态") }.value
            throw CancellationError()
        } catch {
            await reconcileBatch(prepared: prepared, dest: dest, errorMsg: error.localizedDescription)
            throw error
        }
    }

    private func reconcileBatch(prepared: [(BatchMoveItem, ReversibleWalRecord)], dest: String, errorMsg: String) async {
        do {
            let destNow = Dictionary(try await drive.list(folderId: dest).map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
            for (item, row) in prepared {
                if let intended = row.after, let inDest = destNow[item.id], inDest.fileName == intended.name {
                    wal.change(row, state: "applied", after: RemoteSnapshot.from(inDest, parent: dest, workLabel: intended.workLabel))
                } else {
                    wal.change(row, state: "uncertain", error: errorMsg)
                }
            }
        } catch {
            for (_, row) in prepared {
                wal.change(row, state: "uncertain", error: errorMsg)
            }
        }
    }

    /// 两阶段 `mkdir`：先创建 `.PanScraper.New-<UUID>` 私有临时目录，再改名为目标名，防止云盘静默复用已有同名目录。
    public func mkdir(action: String, parent: String, name: String, operation: String = "mkdir") async throws -> String {
        let finalAction = "\(action):finalize"
        if let existing = try known(action: action) {
            if existing.state == "skipped" { return try await replay(existing) }
            if let finalized = try known(action: finalAction) { return try await replay(finalized) }
            guard let temp = existing.after else { throw DriveError.invalidInput("新目录日志缺失") }
            _ = try await verify(temp)
            return try await rename(action: finalAction, id: temp.id, parent: parent, name: name, operation: operation == "undo_stash" ? "undo_stash" : "rename")
        }
        if let found = try await uniqueTarget(parent: parent, name: name) {
            guard found.isDir else { throw DriveError.invalidInput("目录名称已被文件占用") }
            guard operation != "undo_stash" else { throw DriveError.invalidInput("撤销暂存位置已被占用") }
            let s = RemoteSnapshot.from(found, parent: parent)
            let row = try wal.prepare(taskId: taskId, accountId: drive.accountId, actionId: action, operation: operation, before: s, after: s)
            wal.change(row, state: "skipped", after: s)
            return found.fileId
        }
        let temporary = ".PanScraper.New-\(UUID().uuidString.lowercased())"
        let siblings = try await drive.list(folderId: parent)
        guard !siblings.contains(where: { $0.fileName.caseInsensitiveCompare(temporary) == .orderedSame }) else {
            throw DriveError.invalidInput("临时名称冲突")
        }
        let row = try wal.prepare(
            taskId: taskId, accountId: drive.accountId, actionId: action, operation: operation,
            before: nil, after: RemoteSnapshot(id: "", parent: parent, name: temporary, directory: true)
        )
        let id = try await write(row) {
            try await self.drive.mkdir(parentId: parent, name: temporary)
        }
        return try await rename(action: finalAction, id: id, parent: parent, name: name, operation: operation == "undo_stash" ? "undo_stash" : "rename")
    }

    /// 1:1 复刻 `ReversibleOperations.upload`：先下载字节，复核目标未变，覆盖前分层移入 `.PanScraper.Backup-<task>` 再上传。
    @discardableResult
    public func upload(
        action: String,
        parent: String,
        name: String,
        replaceExisting: Bool = false,
        backupScope: AssetBackupScope? = nil,
        bytes: () async throws -> Data
    ) async throws -> Bool {
        if let existing = try known(action: action) {
            _ = try await replay(existing)
            return existing.state != "skipped"
        }
        let found = try await uniqueTarget(parent: parent, name: name)
        guard found?.isDir != true else { throw DriveError.invalidInput("素材目标被目录占用，未覆盖") }
        if let found, !replaceExisting {
            let s = RemoteSnapshot.from(found, parent: parent)
            let row = try wal.prepare(taskId: taskId, accountId: drive.accountId, actionId: action, operation: "upload", before: s, after: s)
            wal.change(row, state: "skipped", after: s)
            return false
        }
        let approved = found.map { RemoteSnapshot.from($0, parent: parent) }
        let content = try await bytes()
        let current = try await uniqueTarget(parent: parent, name: name)
        if let approved {
            guard current?.fileId == approved.id else { throw DriveError.invalidInput("下载期间原文件已被替换，未覆盖") }
            _ = try await verify(approved)
        } else {
            guard current == nil else { throw DriveError.invalidInput("下载期间目标位置出现新文件，未覆盖") }
        }
        if let found {
            let scope = backupScope ?? AssetBackupScope(rootId: parent, workKey: action, workLabel: "未命名作品-\(String(action.prefix(40)))", locationLabel: "根目录")
            let key = shortKey("\(scope.rootId)|\(scope.workKey)")
            let rootAction = "backup-root:\(scope.rootId)"
            let root = try await backupDirCoalescer.run(key: rootAction) {
                try await self.mkdir(action: rootAction, parent: scope.rootId, name: ".PanScraper.Backup-\(self.taskId)")
            }
            let workAction = "backup-work:\(key)"
            let work = try await backupDirCoalescer.run(key: workAction) {
                try await self.mkdir(action: workAction, parent: root, name: StandardNaming.cleanTitle(scope.workLabel))
            }
            let locAction = "backup-location:\(key):\(shortKey(parent))"
            let backup = try await backupDirCoalescer.run(key: locAction) {
                try await self.mkdir(action: locAction, parent: work, name: StandardNaming.cleanTitle(scope.locationLabel))
            }
            _ = try await move(action: "\(action):backup", id: found.fileId, parent: parent, dest: backup, operation: "backup", workLabel: scope.workLabel)
        }
        guard try await uniqueTarget(parent: parent, name: name) == nil else {
            throw DriveError.invalidInput("上传位置已被占用，未覆盖")
        }
        let row = try wal.prepare(
            taskId: taskId, accountId: drive.accountId, actionId: action, operation: "upload",
            before: nil, after: RemoteSnapshot(id: "", parent: parent, name: name, directory: false, size: Int64(content.count))
        )
        _ = try await write(row) {
            _ = try await self.drive.upload(parentId: parent, name: name, data: content)
            let items = try await self.drive.list(folderId: parent).filter { $0.fileName == name && !$0.isDir }
            guard items.count == 1 else { throw DriveError.invalidInput("上传结果待核实") }
            return items[0].fileId
        }
        return true
    }

    public func quarantine(action: String, id: String, parent: String) async throws -> String {
        let dir = try await mkdir(action: "\(action):trash-dir", parent: parent, name: ".PanScraper.Trash-\(taskId)")
        return try await move(action: action, id: id, parent: parent, dest: dir, operation: "quarantine")
    }

    // MARK: - 2. 单行保留区恢复（1:1 对标 revertSingle）

    public func revertSingle(actionId: String) async throws -> String {
        guard let row = wal.find(taskId: taskId, actionId: actionId) else {
            throw DriveError.invalidInput("找不到该保留操作的日志记录")
        }
        guard row.accountId == drive.accountId else { throw DriveError.invalidInput("操作日志账号不匹配") }
        guard row.operation == "retention_move" else { throw DriveError.invalidInput("该日志不是保留区移入操作") }
        if row.state == "reverted" || row.state == "substituted" {
            guard let id = row.undoResult?.id else { throw DriveError.invalidInput("恢复日志不完整") }
            return id
        }
        guard row.state == "applied" || row.state == "conflict" else {
            throw DriveError.invalidInput("该保留操作结果待核实，请先核实日志（\(row.state)）")
        }
        guard let before = row.before, let after = row.after else {
            throw DriveError.invalidInput("日志缺少原始或保留区位置记录")
        }
        do {
            _ = try await verify(after)
            let origSiblings = try await drive.list(folderId: before.parent)
            guard !origSiblings.contains(where: { $0.fileId != after.id && $0.fileName.caseInsensitiveCompare(before.name) == .orderedSame }) else {
                throw DriveError.invalidInput("原位置已被其他对象占用")
            }
            wal.change(row, state: "undo_prepared")
            if let err = wal.lastStorageError { throw DriveError.invalidInput(err) }
            let restored = try await drive.move(fileId: after.id, destParentId: before.parent)
            RetentionZoneEngine.shared.markRestored(taskId: taskId, actionId: row.actionId)
            wal.reverted(row, undoResult: after.with(id: restored, parent: before.parent, name: before.name))
            return restored
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let current = wal.find(taskId: taskId, actionId: row.actionId) ?? row
            if current.state != "undo_prepared" {
                wal.change(current, state: "conflict", error: error.localizedDescription)
            }
            throw error
        }
    }

    // MARK: - 3. 缺失备份审计、用户确认补齐与严格逆序回滚（1:1 对标 auditBackups / substituteNewFile / undo）

    public func auditBackups(
        substitutionActions: [String: PlanAction] = [:],
        acceptedSubstitutions: Set<String> = []
    ) async throws {
        var missing: [MissingBackup] = []
        var substitutes: [ReversibleWalRecord] = []

        let skipStates: Set<String> = ["reverted", "substituted", "skipped", "not_applied"]
        for row in wal.rows(taskId: taskId) where row.operation == "backup" && !skipStates.contains(row.state) {
            guard row.accountId == drive.accountId else { throw DriveError.invalidInput("备份账号不匹配") }
            guard let saved = row.after, let original = row.before else { throw DriveError.invalidInput("备份日志不完整") }
            let label = saved.workLabel ?? original.workLabel ?? "当前作品"
            let entries = try await drive.list(folderId: saved.parent)

            if entries.filter({ $0.fileId == saved.id }).count == 1 {
                do {
                    _ = try await verify(saved)
                } catch {
                    throw DriveError.invalidInput("「\(label)」的备份 \(saved.name) 已变更，保留当前文件，未继续撤销")
                }
                continue
            }

            let strong = isStrongEtag(saved.etag)
            let recovered = entries.filter { !$0.isDir && $0.fileName == saved.name && $0.size == saved.size && strong && $0.etag == saved.etag }
            if recovered.count == 1 && (row.state == "applied" || row.state == "conflict") {
                wal.change(row, state: "applied", after: RemoteSnapshot.from(recovered[0], parent: saved.parent, workLabel: label), error: "已核验找回的原备份")
                continue
            }

            let primaryId = row.actionId.hasSuffix(":backup") ? String(row.actionId.dropLast(7)) : row.actionId
            let uploadRow = wal.find(taskId: taskId, actionId: primaryId)
            if uploadRow?.state == "reverted" && isStrongEtag(original.etag) {
                let origEntries = try await drive.list(folderId: original.parent)
                let restored = origEntries.filter {
                    $0.fileName == original.name && !$0.isDir && $0.size == original.size && $0.etag == original.etag &&
                    (drive.kind == .webdav || $0.fileId == original.id)
                }
                if restored.count == 1 {
                    wal.reverted(row, undoResult: RemoteSnapshot.from(restored[0], parent: original.parent, workLabel: label))
                    continue
                }
            }

            if acceptedSubstitutions.contains(row.actionId) {
                substitutes.append(row)
            } else {
                missing.append(MissingBackup(actionId: row.actionId, work: label, fileName: saved.name))
            }
        }

        if !missing.isEmpty {
            throw MissingBackupsError(files: missing)
        }
        for row in substitutes {
            try await substituteNewFile(row: row, actions: substitutionActions)
        }
    }

    private func substituteNewFile(row: ReversibleWalRecord, actions: [String: PlanAction]) async throws {
        guard let original = row.before else { throw DriveError.invalidInput("缺少原文件位置") }
        let primaryId = row.actionId.hasSuffix(":backup") ? String(row.actionId.dropLast(7)) : row.actionId
        let primary = wal.find(taskId: taskId, actionId: primaryId)
        let outputId = "substitution:\(primaryId)"
        let output = wal.find(taskId: taskId, actionId: outputId)
        let adjustmentId = "substitution-name:\(primaryId)"
        let adjustment = wal.find(taskId: taskId, actionId: adjustmentId)
        let expected = adjustment?.after ?? output?.after ?? primary?.after

        let entries = try await drive.list(folderId: original.parent)
        let existing = entries.filter { $0.fileName.caseInsensitiveCompare(original.name) == .orderedSame }
        var replacement: RemoteSnapshot
        if !existing.isEmpty {
            guard existing.count == 1, let expected else {
                throw DriveError.invalidInput("目标已有无法核验的文件，未采用或覆盖，请手动检查")
            }
            replacement = try await verify(expected).with(workLabel: original.workLabel)
        } else {
            guard output == nil else { throw DriveError.invalidInput("补齐请求已有结果待核实，未重复生成") }
            guard let action = actions[primaryId], action.op == "artwork", action.tmdbId != nil else {
                throw DriveError.invalidInput("这种原文件不能通过刮削重建")
            }
            _ = try await upload(action: outputId, parent: original.parent, name: original.name) {
                try await ArtworkFetcher.shared.contentFor(action: action)
            }
            guard let generated = wal.find(taskId: taskId, actionId: outputId), let genAfter = generated.after else {
                throw DriveError.invalidInput("补齐日志未提交")
            }
            replacement = genAfter.with(workLabel: original.workLabel)
        }

        if replacement.name != original.name {
            let renamed = try await rename(action: adjustmentId, id: replacement.id, parent: original.parent, name: original.name, operation: "substitution_adjustment")
            replacement = try await snapshot(id: renamed, parent: original.parent).with(workLabel: original.workLabel)
        }
        if let adj = wal.find(taskId: taskId, actionId: adjustmentId) {
            wal.change(adj, state: "substitution_output", after: replacement, error: "补齐文件采用原文件名")
        }
        if let gen = wal.find(taskId: taskId, actionId: outputId) {
            guard gen.state == "applied" || gen.state == "substitution_output" else {
                throw DriveError.invalidInput("补齐结果待核实")
            }
            wal.change(gen, state: "substitution_output", after: replacement, error: "用户确认以新文件补齐，非原备份")
        }
        if let primary { wal.reverted(primary, undoResult: replacement, substituted: true) }
        wal.reverted(row, undoResult: replacement, substituted: true)
    }

    /// 严格逆序安全回滚：绝不覆盖或永久删除用户数据，新建目录/上传文件均移入 `.PanScraper.Undo-<task>/<seq>` 暂存。
    public func undo(
        substitutionActions: [String: PlanAction] = [:],
        acceptedSubstitutions: Set<String> = [],
        onProgress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws {
        try await auditBackups(substitutionActions: substitutionActions, acceptedSubstitutions: acceptedSubstitutions)
        let ignoreStates: Set<String> = ["skipped", "not_applied", "substitution_output"]
        let rows = wal.rows(taskId: taskId).filter { $0.operation != "undo_stash" && !ignoreStates.contains($0.state) }
        guard rows.allSatisfy({ $0.accountId == drive.accountId }) else {
            throw DriveError.invalidInput("撤销账号不匹配")
        }

        let remap = IdRemap(pathMode: drive.kind == .webdav)
        var substitutions: [String: RemoteSnapshot] = [:]

        func resolved(_ s: RemoteSnapshot) throws -> RemoteSnapshot {
            let rid = (try remap.resolve(s.id)) ?? s.id
            let rparent = (try remap.resolve(s.parent)) ?? s.parent
            let sub = substitutions[rid]
            return RemoteSnapshot(id: rid, parent: rparent, name: s.name, directory: s.directory, size: sub?.size ?? s.size, etag: sub != nil ? sub?.etag : s.etag, workLabel: s.workLabel)
        }

        for (index, row) in rows.enumerated() {
            onProgress(index, rows.count)
            let before = try row.before.map(resolved)
            guard let after = try row.after.map(resolved) else {
                throw DriveError.invalidInput("撤销日志不完整")
            }
            if row.state == "reverted" || row.state == "substituted" {
                if let res = row.undoResult {
                    if row.operation == "backup" {
                        remap.rebind(res.id)
                        if let oldBefore = row.before { remap.record(old: oldBefore.id, new: res.id) }
                        if row.state == "substituted" { substitutions[res.id] = res }
                    } else if substitutions.removeValue(forKey: after.id) != nil {
                        substitutions[res.id] = res
                    }
                    remap.record(old: after.id, new: res.id)
                }
                continue
            }
            guard row.state == "applied" || row.state == "conflict" else {
                throw DriveError.invalidInput("存在结果不确定的操作，需先核实，未继续撤销")
            }

            do {
                _ = try await verify(after)
                if row.operation == "upload" {
                    guard isStrongEtag(after.etag) else {
                        throw DriveError.invalidInput("云盘未提供素材校验信息，无法安全移除，请手动核实")
                    }
                }
                if let before {
                    let origList = try await drive.list(folderId: before.parent)
                    guard !origList.contains(where: { $0.fileId != after.id && $0.fileName.caseInsensitiveCompare(before.name) == .orderedSame }) else {
                        throw DriveError.invalidInput("原位置已被其他对象占用")
                    }
                }
                if row.operation == "mkdir" {
                    let kids = try await drive.list(folderId: after.id)
                    guard kids.isEmpty else {
                        throw DriveError.invalidInput("本任务新目录已有其他文件，未撤销该目录")
                    }
                }

                wal.change(row, state: "undo_prepared")
            if let err = wal.lastStorageError { throw DriveError.invalidInput(err) }
                let restored: String
                switch row.operation {
                case "rename":
                    guard let before else { throw DriveError.invalidInput("缺少改名前记录") }
                    restored = try await drive.rename(fileId: after.id, newName: before.name)
                case "move", "quarantine", "backup", "retention_move":
                    guard let before else { throw DriveError.invalidInput("缺少移动前记录") }
                    restored = try await drive.move(fileId: after.id, destParentId: before.parent)
                case "mkdir", "upload":
                    guard before == nil else { throw DriveError.invalidInput("不是本任务创建的对象，拒绝移除") }
                    let root = try await mkdir(action: "undo-root", parent: drive.rootId, name: ".PanScraper.Undo-\(taskId)", operation: "undo_stash")
                    let stash = try await mkdir(action: "undo-stash:\(row.sequence)", parent: root, name: "\(row.sequence)", operation: "undo_stash")
                    let stashItems = try await drive.list(folderId: stash)
                    guard !stashItems.contains(where: { $0.fileName.caseInsensitiveCompare(after.name) == .orderedSame }) else {
                        throw DriveError.invalidInput("撤销暂存目录已有同名对象")
                    }
                    restored = try await drive.move(fileId: after.id, destParentId: stash)
                default:
                    throw DriveError.invalidInput("不支持此操作的撤销")
                }

                if row.operation == "backup" {
                    remap.rebind(restored)
                    if let oldBefore = row.before { remap.record(old: oldBefore.id, new: restored) }
                }
                if substitutions.removeValue(forKey: after.id) != nil {
                    substitutions[restored] = after.with(id: restored, parent: before?.parent ?? after.parent, name: before?.name ?? after.name)
                }
                remap.record(old: after.id, new: restored)
                if row.operation == "retention_move" {
                    RetentionZoneEngine.shared.markRestored(taskId: taskId, actionId: row.actionId)
                }
                wal.reverted(row, undoResult: after.with(id: restored, parent: before?.parent ?? after.parent, name: before?.name ?? after.name))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let current = wal.find(taskId: taskId, actionId: row.actionId) ?? row
                if current.state != "undo_prepared" {
                    wal.change(current, state: "conflict", error: error.localizedDescription)
                }
                throw error
            }
        }
        onProgress(rows.count, rows.count)
    }
}
