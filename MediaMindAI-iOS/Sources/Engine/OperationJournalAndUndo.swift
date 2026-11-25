import Foundation
import Observation

/// WAL 操作日志状态（1:1 对标 Android OperationJournal.kt）。
public enum JournalRowStatus: String, Codable, Sendable {
    case prepared
    case applied
    case skipped
    case uncertain
    case undoPrepared = "undo_prepared"
    case undone
}

public struct JournalRow: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let runId: String
    public let actionId: String
    public let op: String // "mkdir" | "rename" | "move" | "artwork" | "trash"
    public let kind: String // "file" | "folder" | "subtitle" | "image" | ...
    public let fileId: String?
    public let parentId: String?
    public let destParentId: String?
    public let oldName: String
    public let newName: String
    public var createdId: String? // 新建对象 ID，或 WebDAV 改名/移动后的最新路径 ID
    public var status: JournalRowStatus
    public let timestamp: Date
    public var error: String?

    public init(
        id: String = String(UUID().uuidString.prefix(10).lowercased()),
        runId: String,
        actionId: String,
        op: String,
        kind: String = "file",
        fileId: String?,
        parentId: String?,
        destParentId: String?,
        oldName: String,
        newName: String,
        createdId: String? = nil,
        status: JournalRowStatus = .prepared,
        timestamp: Date = Date(),
        error: String? = nil
    ) {
        self.id = id
        self.runId = runId
        self.actionId = actionId
        self.op = op
        self.kind = kind
        self.fileId = fileId
        self.parentId = parentId
        self.destParentId = destParentId
        self.oldName = oldName
        self.newName = newName
        self.createdId = createdId
        self.status = status
        self.timestamp = timestamp
        self.error = error
    }

    public var isReversible: Bool {
        guard status == .applied else { return false }
        switch op {
        case "rename": return (createdId != nil || fileId != nil) && !oldName.isEmpty
        case "move": return (createdId != nil || fileId != nil) && parentId != nil
        case "mkdir", "artwork":
            guard let cid = createdId, !cid.isEmpty, cid != "ok", cid != "秒传" else { return false }
            return true
        default: return false
        }
    }
}

/// 预写操作日志（Write-Ahead Log）：每条网盘写操作先落盘 `prepared`，成功转 `applied`，断网/崩溃遗留为 `uncertain` 供核实与撤销回滚。
@MainActor
@Observable
public final class OperationJournal {
    public static let shared = OperationJournal()

    public private(set) var rows: [JournalRow] = []
    private let fileUrl: URL
    private let maxRows = 3000

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.fileUrl = storageURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let folder = dir.appendingPathComponent("MediaMindAI", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileUrl = folder.appendingPathComponent("operation_journal.json")
        }
        if let data = try? Data(contentsOf: fileUrl), let list = try? JSONDecoder().decode([JournalRow].self, from: data) {
            self.rows = list
        }
    }

    @discardableResult
    public func prepare(
        runId: String,
        actionId: String,
        op: String,
        kind: String = "file",
        fileId: String?,
        parentId: String?,
        destParentId: String?,
        oldName: String,
        newName: String
    ) -> JournalRow {
        let row = JournalRow(
            runId: runId,
            actionId: actionId,
            op: op,
            kind: kind,
            fileId: fileId,
            parentId: parentId,
            destParentId: destParentId,
            oldName: oldName,
            newName: newName,
            status: .prepared
        )
        rows.append(row)
        if rows.count > maxRows {
            rows = Array(rows.suffix(maxRows))
        }
        persist()
        return row
    }

    public func markApplied(rowId: String, createdId: String? = nil) {
        guard let idx = rows.firstIndex(where: { $0.id == rowId }) else { return }
        rows[idx].status = .applied
        if let createdId, !createdId.isEmpty { rows[idx].createdId = createdId }
        rows[idx].error = nil
        persist()
    }

    public func markSkipped(rowId: String, error: String) {
        guard let idx = rows.firstIndex(where: { $0.id == rowId }) else { return }
        rows[idx].status = .skipped
        rows[idx].error = error
        persist()
    }

    public func markUncertain(rowId: String, error: String) {
        guard let idx = rows.firstIndex(where: { $0.id == rowId }) else { return }
        rows[idx].status = .uncertain
        rows[idx].error = error
        persist()
    }

    public func markStatus(rowId: String, status: JournalRowStatus, error: String? = nil) {
        guard let idx = rows.firstIndex(where: { $0.id == rowId }) else { return }
        rows[idx].status = status
        rows[idx].error = error
        persist()
    }

    public func rows(forRunId runId: String) -> [JournalRow] {
        rows.filter { $0.runId == runId }
    }

    public func uncertainRows() -> [JournalRow] {
        rows.filter { $0.status == .uncertain || $0.status == .prepared || $0.status == .undoPrepared }
    }

    public func hasRollbackableRows(runId: String) -> Bool {
        rows.contains { $0.runId == runId && $0.isReversible }
    }

    public func clear() {
        rows.removeAll()
        try? FileManager.default.removeItem(at: fileUrl)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rows) {
            try? data.write(to: fileUrl, options: .atomic)
        }
    }
}

public struct RollbackSummary: Sendable {
    public let total: Int
    public let undone: Int
    public let failed: Int
    public let errors: [String]

    public init(total: Int, undone: Int, failed: Int, errors: [String]) {
        self.total = total
        self.undone = undone
        self.failed = failed
        self.errors = errors
    }
}

/// 可逆操作与崩溃核实引擎（1:1 移植自 Android ReversibleOperations.kt，完整兼容 WebDAV 路径变更与 ID 型网盘）。
public enum ReversibleOperations {
    /// 核实崩溃/断网残留的 `prepared` / `uncertain` 日志行，检查云端真实状态并收口。
    public static func reconcileUncertain(
        drive: any CloudDrive,
        journal: OperationJournal? = nil
    ) async -> Int {
        let store = await MainActor.run { journal ?? OperationJournal.shared }
        let pending = await MainActor.run { store.uncertainRows() }
        var resolved = 0
        for row in pending where row.status != .undoPrepared {
            guard let parent = row.destParentId ?? row.parentId else { continue }
            guard let listing = try? await drive.list(folderId: parent) else { continue }
            let landed = listing.contains { $0.fileName == row.newName || (row.fileId != nil && $0.fileId == row.fileId && $0.fileName == row.newName) }
            await MainActor.run {
                if landed {
                    let hitId = listing.first(where: { $0.fileName == row.newName })?.fileId
                    store.markApplied(rowId: row.id, createdId: hitId)
                } else {
                    store.markSkipped(rowId: row.id, error: "核实未落地")
                }
            }
            resolved += 1
        }
        return resolved
    }

    /// 按安全逆序一键撤销某次整理任务中所有已落地的可逆操作：
    /// 0. 先还原目录改名（确保 WebDAV 路径恢复到原目录名）；
    /// 1. 回收本次上传的 NFO/海报素材；
    /// 2. 还原文件/字幕改名；
    /// 3. 将移动过的文件移回原始父目录；
    /// 4. 最后回收本次新建的空目录。
    public static func rollback(
        runId: String,
        drive: any CloudDrive,
        journal: OperationJournal? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> RollbackSummary {
        let store = await MainActor.run { journal ?? OperationJournal.shared }
        let reversible = await MainActor.run {
            store.rows(forRunId: runId).filter(\.isReversible).reversed()
        }
        func priority(of row: JournalRow) -> Int {
            if row.op == "rename" && row.kind == "folder" { return 0 }
            switch row.op {
            case "artwork": return 1
            case "rename": return 2
            case "move": return 3
            case "mkdir": return 4
            default: return 9
            }
        }
        let sorted = reversible.sorted { priority(of: $0) < priority(of: $1) }

        var undone = 0
        var failed = 0
        var errors: [String] = []

        for row in sorted {
            await MainActor.run { store.markStatus(rowId: row.id, status: .undoPrepared) }
            onProgress?("正在撤销：\(row.newName.isEmpty ? row.oldName : row.newName)")
            do {
                let effectiveId = (row.createdId?.isEmpty == false ? row.createdId : row.fileId)
                switch row.op {
                case "rename":
                    guard let fid = effectiveId else { throw DriveError.invalidInput("缺少 fileId") }
                    _ = try await drive.rename(fileId: fid, newName: row.oldName)
                case "move":
                    guard let fid = effectiveId, let origParent = row.parentId else {
                        throw DriveError.invalidInput("缺少原始目录信息")
                    }
                    _ = try await drive.move(fileId: fid, destParentId: origParent)
                case "mkdir", "artwork":
                    guard let cid = row.createdId, !cid.isEmpty else {
                        throw DriveError.invalidInput("缺少新建对象 ID")
                    }
                    _ = try await drive.trash(fileId: cid)
                default:
                    continue
                }
                await MainActor.run { store.markStatus(rowId: row.id, status: .undone) }
                undone += 1
            } catch {
                let msg = "撤销 \(row.newName.isEmpty ? row.oldName : row.newName) 失败：\(error.localizedDescription)"
                errors.append(msg)
                failed += 1
                await MainActor.run { store.markStatus(rowId: row.id, status: .applied, error: msg) }
            }
        }
        return RollbackSummary(total: sorted.count, undone: undone, failed: failed, errors: errors)
    }
}

/// 排队等待执行的整理任务项（1:1 移植自 Android TaskQueue.kt）。
public struct QueuedTaskItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let planId: String
    public let accountId: String
    public let provider: String
    public let sourceLabel: String
    public let actionCount: Int
    public let actionIds: [String]?
    public let enqueuedAt: Date

    public init(id: String = String(UUID().uuidString.prefix(8).lowercased()), planId: String, accountId: String, provider: String, sourceLabel: String, actionCount: Int, actionIds: [String]? = nil, enqueuedAt: Date = Date()) {
        self.id = id
        self.planId = planId
        self.accountId = accountId
        self.provider = provider
        self.sourceLabel = sourceLabel
        self.actionCount = actionCount
        self.actionIds = actionIds
        self.enqueuedAt = enqueuedAt
    }
}

@MainActor
@Observable
public final class TaskQueue {
    public static let shared = TaskQueue()

    public private(set) var items: [QueuedTaskItem] = []
    private let fileUrl: URL

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.fileUrl = storageURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let folder = dir.appendingPathComponent("MediaMindAI", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileUrl = folder.appendingPathComponent("task_queue.json")
        }
        if let data = try? Data(contentsOf: fileUrl), let list = try? JSONDecoder().decode([QueuedTaskItem].self, from: data) {
            self.items = list
        }
    }

    @discardableResult
    public func enqueue(plan: ScrapePlan, actionIds: [String]? = nil) -> QueuedTaskItem {
        // 固定排队时确认的动作 ID，避免消费队列时执行后来新增的识别结果。
        let acceptedIds = ExecutionEngine.executableActionIds(plan: plan, requested: actionIds)
        let actionIds: [String]? = acceptedIds
        if let existing = items.first(where: { item in
            guard item.planId == plan.id else { return false }
            switch (item.actionIds, actionIds) {
            case (nil, nil): return true
            case let (a?, b?): return Set(a) == Set(b)
            default: return false
            }
        }) { return existing }
        let count = acceptedIds.count
        let item = QueuedTaskItem(
            planId: plan.id,
            accountId: plan.accountId,
            provider: plan.provider,
            sourceLabel: plan.roots.map(\.name).joined(separator: "、"),
            actionCount: count,
            actionIds: actionIds
        )
        items.append(item)
        persist()
        return item
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    public func peekNext() -> QueuedTaskItem? {
        items.first
    }

    public func popNext() -> QueuedTaskItem? {
        guard !items.isEmpty else { return nil }
        let first = items.removeFirst()
        persist()
        return first
    }

    public func clear() {
        items.removeAll()
        try? FileManager.default.removeItem(at: fileUrl)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileUrl, options: .atomic)
        }
    }
}
