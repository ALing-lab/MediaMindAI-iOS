import Foundation
import CryptoKit

/// 1:1 逐行复刻自 Android `RetentionZone.kt`（430 行 / 22.8 KB）：
/// 主库外「重复保留区」管理：
/// - 确定重复：`重复保留区/确定重复/<taskId>/<workTitle>/<uniqueSourceKey>/<originalName>`
/// - 疑似重复：`重复保留区/疑似重复/<taskId>/<workTitle>/<uniqueSourceKey>/<originalName>`
/// - 支持损坏登记 `.corrupt` 备份保护、先写 intent 后移远端、`ReversibleTransaction.revertSingle` 单行恢复、
///   未归档任务清理排除、实时核验（`verifyForCleanup`）与删除前逐条二次复验（`cleanupVerified`）。
public final class RetentionZoneEngine: @unchecked Sendable {
    public static let shared = RetentionZoneEngine()

    public static let rootDir = "重复保留区"
    public static let dirConfirmed = "确定重复"
    public static let dirSuspected = "疑似重复"
    public static let catConfirmed = "confirmed"
    public static let catSuspected = "suspected"
    public static let statusRetained = "retained"
    public static let statusRestored = "restored"
    public static let statusCleaned = "cleaned"
    public static let cleanupWarning = "根据任务记录，保留区内可能存在以下重复文件。一键清理无法恢复，请谨慎操作。"

    public struct Record: Identifiable, Codable, Hashable, Sendable {
        public let recordId: String
        public let accountId: String
        public let provider: String
        public let taskId: String
        public let actionId: String
        public let workTitle: String
        public let category: String // confirmed | suspected
        public let reason: String
        public let originalFileId: String
        public let originalParentId: String
        public let originalPath: String
        public let originalName: String
        public let size: Int64
        public let contentHash: String?
        public let hashAlgorithm: String?
        public let etag: String?
        public var retentionFileId: String
        public let retentionParentId: String
        public let retentionPath: String
        public let movedAt: Int64
        public var status: String // retained | restored | cleaned
        public var cleanedMode: String? // recycle | permanent
        public var updatedAt: Int64

        public var id: String { recordId }

        public init(
            recordId: String,
            accountId: String,
            provider: String,
            taskId: String,
            actionId: String,
            workTitle: String,
            category: String,
            reason: String,
            originalFileId: String,
            originalParentId: String,
            originalPath: String,
            originalName: String,
            size: Int64 = 0,
            contentHash: String? = nil,
            hashAlgorithm: String? = nil,
            etag: String? = nil,
            retentionFileId: String,
            retentionParentId: String,
            retentionPath: String,
            movedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
            status: String = RetentionZoneEngine.statusRetained,
            cleanedMode: String? = nil,
            updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        ) {
            self.recordId = recordId
            self.accountId = accountId
            self.provider = provider
            self.taskId = taskId
            self.actionId = actionId
            self.workTitle = workTitle
            self.category = category
            self.reason = reason
            self.originalFileId = originalFileId
            self.originalParentId = originalParentId
            self.originalPath = originalPath
            self.originalName = originalName
            self.size = size
            self.contentHash = contentHash
            self.hashAlgorithm = hashAlgorithm
            self.etag = etag
            self.retentionFileId = retentionFileId
            self.retentionParentId = retentionParentId
            self.retentionPath = retentionPath
            self.movedAt = movedAt
            self.status = status
            self.cleanedMode = cleanedMode
            self.updatedAt = updatedAt
        }
    }

    private struct Registry: Codable {
        var version: Int = 1
        var records: [Record] = []
    }

    public struct CleanupCheck: Identifiable, Hashable, Sendable {
        public let record: Record
        public let verified: Bool
        public let detail: String
        public var id: String { record.recordId }

        public init(record: Record, verified: Bool, detail: String) {
            self.record = record
            self.verified = verified
            self.detail = detail
        }
    }

    public struct CleanupOutcome: Equatable, Sendable {
        public let cleaned: Int
        public let skipped: Int
        public let failed: Int
        public let modeLabel: String
        public let details: [String]

        public init(cleaned: Int, skipped: Int, failed: Int, modeLabel: String, details: [String]) {
            self.cleaned = cleaned
            self.skipped = skipped
            self.failed = failed
            self.modeLabel = modeLabel
            self.details = details
        }
    }

    private let lock = NSRecursiveLock()
    private let registryURL: URL
    private let wal: ReversibleWalStore
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()
    private var registryCorrupt: String?

    public init(registryURL: URL? = nil, wal: ReversibleWalStore = .shared) {
        self.wal = wal
        if let registryURL {
            self.registryURL = registryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("MediaMindAI/plans", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.registryURL = dir.appendingPathComponent("retention_registry.json")
        }
    }

    public func registryError() -> String? {
        lock.lock(); defer { lock.unlock() }
        return registryCorrupt
    }

    /// 写路径读登记：文件损坏时备份为 `.corrupt` 并抛错拒绝覆写，防止既有登记被空表覆盖。
    private func loadRecordsLocked() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            registryCorrupt = nil
            return []
        }
        let text = try String(contentsOf: registryURL, encoding: .utf8)
        do {
            let decoded = try decoder.decode(Registry.self, from: Data(text.utf8))
            registryCorrupt = nil
            return decoded.records
        } catch {
            let backup = registryURL.deletingLastPathComponent().appendingPathComponent(registryURL.lastPathComponent + ".corrupt")
            let existingBackup = try? String(contentsOf: backup, encoding: .utf8)
            if existingBackup != text {
                try? text.write(to: backup, atomically: true, encoding: .utf8)
            }
            let msg = "保留区登记文件已损坏（原文已备份为 \(registryURL.lastPathComponent).corrupt），已停止写入以免登记丢失：\(error.localizedDescription)"
            registryCorrupt = msg
            throw DriveError.invalidInput(msg)
        }
    }

    /// 展示读：损坏时降级为空表并通过 `registryError()` 暴露原因。
    public func allRecords() -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return (try? loadRecordsLocked()) ?? []
    }

    public func retainedRecords(category: String? = nil, accountId: String? = nil) -> [Record] {
        allRecords()
            .filter { rec in
                rec.status == Self.statusRetained
                    && (category == nil || rec.category == category)
                    && (accountId == nil || rec.accountId == accountId)
            }
            .sorted { $0.movedAt > $1.movedAt }
    }

    private func saveAllLocked(_ records: [Record]) throws {
        let data = try encoder.encode(Registry(version: 1, records: records))
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try AtomicFileIO.writeText(text, to: registryURL)
    }

    private func upsert(_ record: Record) throws {
        lock.lock(); defer { lock.unlock() }
        let cur = try loadRecordsLocked().filter { $0.recordId != record.recordId }
        try saveAllLocked(cur + [record])
    }

    public static func categoryDirName(_ category: String) -> String {
        category == catConfirmed ? dirConfirmed : dirSuspected
    }

    private static func safeSegment(_ raw: String, fallback: String) -> String {
        let cleaned = StandardNaming.cleanTitle(raw)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(cleaned.prefix(60))
        return prefix.isEmpty ? fallback : prefix
    }

    public static func uniqueSourceKey(originalFileId: String, originalParentId: String, originalPath: String) -> String {
        let digest = SHA256.hash(data: Data("\(originalParentId)|\(originalFileId)|\(originalPath)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(10))
    }

    public static func retentionDisplayPath(
        category: String,
        taskId: String,
        workTitle: String,
        sourceKey: String,
        fileName: String
    ) -> String {
        "\(rootDir)/\(categoryDirName(category))/\(safeSegment(taskId, fallback: "task"))/\(safeSegment(workTitle, fallback: "未命名"))/\(sourceKey)/\(fileName)"
    }

    private func ensureDir(drive: any CloudDrive, parentId: String, name: String) async throws -> String {
        let existing = try await drive.list(folderId: parentId).filter { $0.fileName.caseInsensitiveCompare(name) == .orderedSame }
        guard existing.count <= 1 else {
            throw DriveError.invalidInput("保留区目录「\(name)」存在多个同名对象，停止移动")
        }
        if let dir = existing.first {
            guard dir.isDir else {
                throw DriveError.invalidInput("保留区路径「\(name)」被文件占用，停止移动")
            }
            return dir.fileId
        }
        return try await drive.mkdir(parentId: parentId, name: name)
    }

    // MARK: - 1. 移入保留区（先写 intent 登记，再走 ReversibleTransaction）

    public func moveToRetention(
        ops: ReversibleTransaction,
        drive: any CloudDrive,
        taskId: String,
        actionId: String,
        entry: CloudEntry,
        originalParentId: String,
        originalPath: String,
        workTitle: String,
        confirmedDuplicate: Bool,
        reason: String,
        customRootId: String? = nil
    ) async throws -> Record {
        guard !entry.isDir else { throw DriveError.invalidInput("仅支持将重复文件移入保留区") }
        let category = confirmedDuplicate ? Self.catConfirmed : Self.catSuspected
        let catDirName = Self.categoryDirName(category)
        let taskSeg = Self.safeSegment(taskId, fallback: "task")
        let workSeg = Self.safeSegment(workTitle, fallback: "未命名")
        let srcKey = Self.uniqueSourceKey(originalFileId: entry.fileId, originalParentId: originalParentId, originalPath: originalPath)

        let baseParentId = (customRootId?.isEmpty == false ? customRootId : nil) ?? drive.rootId
        let rootId = try await ensureDir(drive: drive, parentId: baseParentId, name: Self.rootDir)
        let catId = try await ensureDir(drive: drive, parentId: rootId, name: catDirName)
        let taskDirId = try await ensureDir(drive: drive, parentId: catId, name: taskSeg)
        let workDirId = try await ensureDir(drive: drive, parentId: taskDirId, name: workSeg)
        let slotDirId = try await ensureDir(drive: drive, parentId: workDirId, name: srcKey)

        let displayPath = Self.retentionDisplayPath(
            category: category, taskId: taskId, workTitle: workTitle, sourceKey: srcKey, fileName: entry.fileName
        )

        // 先落盘 intent 登记，再执行云端移动
        var intent = Record(
            recordId: "\(taskId):\(actionId)",
            accountId: drive.accountId,
            provider: drive.kind.rawValue,
            taskId: taskId,
            actionId: actionId,
            workTitle: workTitle,
            category: category,
            reason: reason,
            originalFileId: entry.fileId,
            originalParentId: originalParentId,
            originalPath: originalPath,
            originalName: entry.fileName,
            size: entry.size,
            contentHash: entry.contentHash,
            hashAlgorithm: entry.hashAlgorithm,
            etag: entry.etag,
            retentionFileId: "",
            retentionParentId: slotDirId,
            retentionPath: displayPath,
            status: Self.statusRetained
        )
        try upsert(intent)

        let movedId: String
        do {
            movedId = try await ops.move(
                action: actionId,
                id: entry.fileId,
                parent: originalParentId,
                dest: slotDirId,
                operation: "retention_move",
                workLabel: workTitle
            )
        } catch {
            let rowState = wal.find(taskId: taskId, actionId: actionId)?.state
            if rowState == nil || rowState == "not_applied" {
                {
                    lock.lock(); defer { lock.unlock() }
                    if let cur = try? loadRecordsLocked() {
                        try? saveAllLocked(cur.filter { $0.recordId != intent.recordId })
                    }
                }()
            }
            throw error
        }

        intent.retentionFileId = movedId
        intent.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try upsert(intent)
        return intent
    }

    public func markRestored(taskId: String, actionId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let cur = try? loadRecordsLocked() else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let updated = cur.map { rec -> Record in
            guard rec.taskId == taskId && rec.actionId == actionId && rec.status == Self.statusRetained else { return rec }
            var copy = rec
            copy.status = Self.statusRestored
            copy.updatedAt = now
            return copy
        }
        try? saveAllLocked(updated)
    }

    // MARK: - 2. 定位与单条恢复（优先走 ReversibleTransaction.revertSingle）

    private func locateInRetention(drive: any CloudDrive, rec: Record) async throws -> CloudEntry? {
        let matches = try await drive.list(folderId: rec.retentionParentId).filter { entry in
            !entry.isDir && (entry.fileId == rec.retentionFileId ||
                (rec.retentionFileId.isEmpty && entry.fileName.caseInsensitiveCompare(rec.originalName) == .orderedSame))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func moveBackToOriginal(drive: any CloudDrive, rec: Record, inRetention: CloudEntry) async throws -> String {
        let movedId = try await drive.move(fileId: inRetention.fileId, destParentId: rec.originalParentId)
        if inRetention.fileName != rec.originalName {
            _ = try await drive.rename(fileId: movedId, newName: rec.originalName)
        }
        return movedId
    }

    public func restoreRecord(recordId: String, drive: any CloudDrive) async throws -> Record {
        let rec: Record = try {
            lock.lock(); defer { lock.unlock() }
            guard let found = try loadRecordsLocked().first(where: { $0.recordId == recordId }) else {
                throw DriveError.invalidInput("找不到保留区登记记录")
            }
            return found
        }()
        guard rec.status == Self.statusRetained else {
            throw DriveError.invalidInput("该记录当前不在保留区（\(rec.status)）")
        }
        guard rec.accountId == drive.accountId else {
            throw DriveError.invalidInput("网盘账号不匹配，无法恢复")
        }
        guard let inRetention = try await locateInRetention(drive: drive, rec: rec) else {
            throw DriveError.invalidInput("保留区中找不到该文件，可能已被手动移动或删除")
        }
        guard inRetention.size == rec.size else {
            throw DriveError.invalidInput("保留区文件大小已变化，已停止恢复，请手动核实")
        }
        let origSiblings = try await drive.list(folderId: rec.originalParentId)
        guard !origSiblings.contains(where: { $0.fileName.caseInsensitiveCompare(rec.originalName) == .orderedSame }) else {
            throw DriveError.invalidInput("原位置已存在同名文件，未覆盖")
        }

        if let row = wal.find(taskId: rec.taskId, actionId: rec.actionId), row.operation == "retention_move" {
            let tx = ReversibleTransaction(taskId: rec.taskId, drive: drive, wal: wal)
            _ = try await tx.revertSingle(actionId: rec.actionId)
        } else {
            _ = try await moveBackToOriginal(drive: drive, rec: rec, inRetention: inRetention)
        }

        var restored = rec
        restored.status = Self.statusRestored
        restored.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try upsert(restored)
        return restored
    }

    // MARK: - 3. 路径保护、未归档任务排除、核验与二次复验清理

    public static func isProtectedPath(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("panscraper.undo") || p.contains("panscraper.backup") || !path.hasPrefix("\(rootDir)/")
    }

    @MainActor
    public func cleanupProtectedTaskIds(
        records: [Record],
        activeTaskStatuses: [String: String]? = nil
    ) -> Set<String> {
        guard !records.isEmpty else { return [] }
        let statusMap: [String: String] = activeTaskStatuses ?? Dictionary(
            PlanAndTaskStore.shared.tasks.map { ($0.id, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        let pendingRowStates: Set<String> = ["prepared", "uncertain", "undo_prepared", "conflict"]
        let blockingControlStates: Set<String> = ["requested", "undoing", "conflict", "needs_backup_choice"]
        let openControls = Set(TaskCancellation.shared.controls.values.filter { blockingControlStates.contains($0.state) }.map(\.taskId))
        var out = Set<String>()
        for (taskId, taskRecords) in Dictionary(grouping: records, by: \.taskId) {
            let isUnfinishedCard: Bool
            if let status = statusMap[taskId] {
                isUnfinishedCard = (status != "done" && status != "stopped" && status != "failed")
            } else {
                isUnfinishedCard = false
            }
            let hasOpenControl = openControls.contains(taskId)
            let journalPending = taskRecords.contains { rec in
                guard let row = wal.find(taskId: taskId, actionId: rec.actionId) else { return false }
                return row.operation == "retention_move" && pendingRowStates.contains(row.state)
            }
            if isUnfinishedCard || hasOpenControl || journalPending {
                out.insert(taskId)
            }
        }
        return out
    }

    public func verifyForCleanup(
        records: [Record],
        drive: any CloudDrive,
        activeTaskIds: Set<String> = []
    ) async -> [CleanupCheck] {
        var out: [CleanupCheck] = []
        for rec in records {
            if rec.status != Self.statusRetained {
                out.append(CleanupCheck(record: rec, verified: false, detail: "记录状态不是保留中（\(rec.status)）"))
            } else if rec.accountId != drive.accountId {
                out.append(CleanupCheck(record: rec, verified: false, detail: "网盘账号与当前账号不匹配"))
            } else if activeTaskIds.contains(rec.taskId) {
                out.append(CleanupCheck(record: rec, verified: false, detail: "所属任务尚未终结归档（仍可撤销/恢复），跳过清理"))
            } else if Self.isProtectedPath(rec.retentionPath) {
                out.append(CleanupCheck(record: rec, verified: false, detail: "路径不在重复保留区内，拒绝清理"))
            } else {
                let found = try? await locateInRetention(drive: drive, rec: rec)
                guard let found else {
                    out.append(CleanupCheck(record: rec, verified: false, detail: "保留区中未找到该文件或存在同名歧义"))
                    continue
                }
                if found.size != rec.size {
                    out.append(CleanupCheck(record: rec, verified: false, detail: "远端文件大小已变化（现 \(found.size) B ≠ 原 \(rec.size) B），跳过"))
                } else if let ch = rec.contentHash, let fch = found.contentHash,
                          ((found.hashAlgorithm ?? "").caseInsensitiveCompare(rec.hashAlgorithm ?? "") != .orderedSame ||
                           fch.caseInsensitiveCompare(ch) != .orderedSame) {
                    out.append(CleanupCheck(record: rec, verified: false, detail: "远端内容校验值已变化，跳过"))
                } else if let et = rec.etag, let fet = found.etag, fet.caseInsensitiveCompare(et) != .orderedSame {
                    out.append(CleanupCheck(record: rec, verified: false, detail: "远端 ETag 已变化，跳过"))
                } else {
                    out.append(CleanupCheck(record: rec, verified: true, detail: "核验通过：\(rec.retentionPath)"))
                }
            }
        }
        return out
    }

    private func reverifiedEntry(rec: Record, drive: any CloudDrive) async throws -> (Record, CloudEntry) {
        let current: Record = try {
            lock.lock(); defer { lock.unlock() }
            guard let hit = try loadRecordsLocked().first(where: { $0.recordId == rec.recordId }) else {
                throw DriveError.invalidInput("登记记录已不存在")
            }
            return hit
        }()
        guard current.status == Self.statusRetained else { throw DriveError.invalidInput("记录状态已变化（\(current.status)）") }
        guard current.accountId == drive.accountId else { throw DriveError.invalidInput("网盘账号与当前账号不匹配") }
        guard !Self.isProtectedPath(current.retentionPath) else { throw DriveError.invalidInput("路径不在重复保留区内") }
        guard let found = try await locateInRetention(drive: drive, rec: current) else {
            throw DriveError.invalidInput("保留区中未找到该文件")
        }
        guard found.size == current.size else {
            throw DriveError.invalidInput("远端文件大小已变化（现 \(found.size) B ≠ 原 \(current.size) B）")
        }
        if let ch = current.contentHash, let fch = found.contentHash {
            guard (found.hashAlgorithm ?? "").caseInsensitiveCompare(current.hashAlgorithm ?? "") == .orderedSame,
                  fch.caseInsensitiveCompare(ch) == .orderedSame else {
                throw DriveError.invalidInput("远端内容校验值已变化")
            }
        }
        if let et = current.etag, let fet = found.etag {
            guard fet.caseInsensitiveCompare(et) == .orderedSame else {
                throw DriveError.invalidInput("远端 ETag 已变化")
            }
        }
        return (current, found)
    }

    /// 执行保留区清理：先核验登记可读，每条在删除前再复验一次，遇首条删除失败保守暂停。
    public func cleanupVerified(checks: [CleanupCheck], drive: any CloudDrive) async throws -> CleanupOutcome {
        try {
            lock.lock(); defer { lock.unlock() }
            _ = try loadRecordsLocked()
        }()

        let support = drive.trashSupport
        if support == .none {
            return CleanupOutcome(cleaned: 0, skipped: checks.count, failed: 0, modeLabel: "当前网盘不支持清理删除", details: [TrashSupport.noneHint(drive.kind)])
        }
        let mode = support == .recycle ? "recycle" : "permanent"
        let modeLabel = support == .recycle ? "移入云盘回收站" : "永久删除（无法恢复）"
        var cleaned = 0
        var skipped = 0
        var failed = 0
        var details: [String] = []

        for item in checks {
            if !item.verified {
                skipped += 1
                details.append("跳过 \(item.record.originalName)：\(item.detail)")
                continue
            }
            let current: Record
            let entry: CloudEntry
            do {
                (current, entry) = try await reverifiedEntry(rec: item.record, drive: drive)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped += 1
                details.append("跳过 \(item.record.originalName)：复验未通过（\(error.localizedDescription)）")
                continue
            }

            do {
                _ = try await drive.trash(fileId: entry.fileId)
                cleaned += 1
                var updated = current
                updated.status = Self.statusCleaned
                updated.cleanedMode = mode
                updated.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
                try upsert(updated)
                details.append("已清理 \(current.originalName)（\(modeLabel)）")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
                details.append("清理失败 \(current.originalName)：\(error.localizedDescription)")
                break // 未知请求结果保守暂停，不盲目继续永久删除
            }
        }
        return CleanupOutcome(cleaned: cleaned, skipped: skipped, failed: failed, modeLabel: modeLabel, details: details)
    }
}
