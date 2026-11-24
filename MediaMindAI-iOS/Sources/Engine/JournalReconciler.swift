import Foundation

/// 1:1 逐行复刻自 Android `JournalReconciler.kt`（137 行）：
/// 针对崩溃/断网残留的 `uncertain` / `prepared` / `undo_prepared` 日志行执行只读云端目录对账：
/// - 正向中断（prepared / uncertain）：目标态存在且原态消失 → `applied`；目标态不存在且原态仍在 → `skipped`（未生效）；双态并存或多同名 → 保持 `uncertain` 绝不猜测。
/// - 撤销中断（undo_prepared，M-6）：逆向判定——原态恢复且目标态消失 → `undone`（已撤销）；目标态仍在且原态缺失 → 恢复为 `applied` 供继续撤销；双态不明 → 保持 `uncertain`。
public enum JournalReconciler {
    public struct ReconcileEntry: Identifiable, Hashable, Sendable {
        public let id: String
        public let actionId: String
        public let operation: String
        public let outcome: String // "applied" | "not_applied" | "reverted" | "uncertain"
        public let detail: String

        public init(id: String, actionId: String, operation: String, outcome: String, detail: String) {
            self.id = id
            self.actionId = actionId
            self.operation = operation
            self.outcome = outcome
            self.detail = detail
        }
    }

    public struct ReconcileReport: Hashable, Sendable {
        public let confirmedApplied: Int
        public let confirmedNotApplied: Int
        public let confirmedReverted: Int
        public let stillUncertain: Int
        public let entries: [ReconcileEntry]

        public init(confirmedApplied: Int, confirmedNotApplied: Int, confirmedReverted: Int, stillUncertain: Int, entries: [ReconcileEntry]) {
            self.confirmedApplied = confirmedApplied
            self.confirmedNotApplied = confirmedNotApplied
            self.confirmedReverted = confirmedReverted
            self.stillUncertain = stillUncertain
            self.entries = entries
        }
    }

    @MainActor
    public static func uncertainRows(runId: String, journal: OperationJournal = .shared) -> [JournalRow] {
        guard !runId.isEmpty else { return [] }
        return journal.rows(forRunId: runId).filter {
            $0.status == .uncertain || $0.status == .prepared || $0.status == .undoPrepared
        }
    }

    public static func reconcile(
        runId: String,
        drive: any CloudDrive,
        journal: OperationJournal? = nil
    ) async -> ReconcileReport {
        let store = await MainActor.run { journal ?? OperationJournal.shared }
        let pending = await MainActor.run { uncertainRows(runId: runId, journal: store) }
        guard !pending.isEmpty else {
            return ReconcileReport(confirmedApplied: 0, confirmedNotApplied: 0, confirmedReverted: 0, stillUncertain: 0, entries: [])
        }

        var cache: [String: [CloudEntry]] = [:]
        func listCached(_ parent: String) async -> [CloudEntry]? {
            if let hit = cache[parent] { return hit }
            guard let list = try? await drive.list(folderId: parent) else { return nil }
            cache[parent] = list
            return list
        }

        var entries: [ReconcileEntry] = []
        var applied = 0
        var notApplied = 0
        var reverted = 0
        var stillUncertain = 0

        for row in pending {
            guard let afterParent = row.destParentId ?? row.parentId else {
                stillUncertain += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "uncertain", detail: "日志缺少预期目标目录快照，需手动核实"))
                continue
            }
            guard let afterList = await listCached(afterParent) else {
                stillUncertain += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "uncertain", detail: "无法读取目标目录，请检查网络或权限"))
                continue
            }
            let expectDir = (
                row.op == "mkdir"
                || row.kind == "folder"
                || row.kind == "disc_folder"
                || row.kind == "leftover"
                || row.kind == LibraryDestination.kind
                || row.kind == AdaptiveDirectoryPlanner.kindAdaptiveMove
            )
            let afterMatches = afterList.filter { $0.fileName.caseInsensitiveCompare(row.newName) == .orderedSame && $0.isDir == expectDir }
            let exactAfter = afterMatches.count == 1 ? afterMatches[0] : nil

            var exactBefore: CloudEntry? = nil
            let hasBefore = !row.oldName.isEmpty && row.parentId != nil
            if hasBefore, let bp = row.parentId {
                guard let bList = await listCached(bp) else {
                    stillUncertain += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "uncertain", detail: "核实失败：源目录读取失败，请检查网络后重试"))
                    continue
                }
                let bMatches = bList.filter { e in
                    e.fileName.caseInsensitiveCompare(row.oldName) == .orderedSame && e.isDir == expectDir && (row.fileId == nil || e.fileId == row.fileId)
                }
                exactBefore = bMatches.count == 1 ? bMatches[0] : nil
            }

            // 1. 撤销中断核实（M-6：undo_prepared 逆向判定）
            if row.status == .undoPrepared {
                if (hasBefore && exactBefore != nil && exactAfter == nil) || (!hasBefore && exactAfter == nil) {
                    await MainActor.run { store.markStatus(rowId: row.id, status: .undone, error: nil) }
                    reverted += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "reverted", detail: hasBefore ? "已确认撤销生效：对象已回到原位置" : "已确认新建对象已撤销移除"))
                } else if exactAfter != nil && exactBefore == nil {
                    await MainActor.run { store.markApplied(rowId: row.id, createdId: exactAfter?.fileId) }
                    applied += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "applied", detail: "已确认撤销未生效：对象仍在新位置，已恢复为 applied 可重试撤销"))
                } else {
                    stillUncertain += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "uncertain", detail: "撤销状态无法自动判定，请手动核实网盘"))
                }
                continue
            }

            // 2. 正向中断核实（prepared / uncertain）
            if let hit = exactAfter, exactBefore == nil {
                await MainActor.run { store.markApplied(rowId: row.id, createdId: hit.fileId) }
                applied += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "applied", detail: "已确认远端生效：\(hit.fileName)"))
            } else if afterMatches.isEmpty && (!hasBefore || exactBefore != nil) {
                await MainActor.run { store.markSkipped(rowId: row.id, error: "核实确认远端未写入") }
                notApplied += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "not_applied", detail: "已确认远端未生效，可安全重跑"))
            } else {
                stillUncertain += 1
                let why: String
                if afterMatches.count > 1 { why = "目标目录存在多个同名对象，无法自动判定" }
                else if exactAfter != nil && exactBefore != nil { why = "源对象与目标对象同时存在，需手动核实" }
                else { why = "远端状态与预期前后快照不完全匹配，保留暂停" }
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "uncertain", detail: why))
            }
        }

        return ReconcileReport(
            confirmedApplied: applied,
            confirmedNotApplied: notApplied,
            confirmedReverted: reverted,
            stillUncertain: stillUncertain,
            entries: entries
        )
    }

    /// 同步核实 `ReversibleWalStore` 中处于 `prepared` / `uncertain` / `undo_prepared` 的可逆事务行。
    public static func reconcileReversibleWal(
        taskId: String,
        drive: any CloudDrive,
        wal: ReversibleWalStore = .shared
    ) async -> ReconcileReport {
        let pending = wal.uncertainRecords().filter { $0.taskId == taskId }
        guard !pending.isEmpty else {
            return ReconcileReport(confirmedApplied: 0, confirmedNotApplied: 0, confirmedReverted: 0, stillUncertain: 0, entries: [])
        }
        var applied = 0, notApplied = 0, reverted = 0, still = 0
        var entries: [ReconcileEntry] = []
        for row in pending {
            guard row.accountId == drive.accountId else {
                still += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "日志账号与当前网盘不匹配，跳过核实"))
                continue
            }
            let beforeList = row.before != nil ? (try? await drive.list(folderId: row.before!.parent)) : nil
            let afterList = row.after != nil ? (try? await drive.list(folderId: row.after!.parent)) : nil
            // 任一需核对目录读取失败（断网/权限异常）立即保守维持 uncertain，绝不按空目录误判
            if (row.before != nil && beforeList == nil) || (row.after != nil && afterList == nil) {
                still += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "读取远端目录失败，维持待核实状态"))
                continue
            }
            func matchesSnapshot(_ entry: CloudEntry, _ snap: RemoteSnapshot) -> Bool {
                guard entry.fileName.caseInsensitiveCompare(snap.name) == .orderedSame && entry.isDir == snap.directory else {
                    return false
                }
                if !snap.id.isEmpty && !drive.kind.idsArePaths {
                    return entry.fileId == snap.id
                }
                if !snap.directory && snap.size > 0 && entry.size > 0 {
                    return entry.size == snap.size
                }
                return true
            }
            let beforeMatches = (row.before != nil && beforeList != nil)
                ? beforeList!.filter { matchesSnapshot($0, row.before!) }
                : []
            let afterMatches = (row.after != nil && afterList != nil)
                ? afterList!.filter { matchesSnapshot($0, row.after!) }
                : []

            if beforeMatches.count > 1 || afterMatches.count > 1 || (!beforeMatches.isEmpty && !afterMatches.isEmpty && row.before?.id != row.after?.id) {
                still += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "远端存在双态并存或同名歧义，需人工核实"))
                continue
            }

            if row.state == "undo_prepared" {
                if let before = row.before, beforeMatches.count == 1, afterMatches.isEmpty {
                    wal.reverted(row, undoResult: RemoteSnapshot.from(beforeMatches[0], parent: before.parent))
                    if row.operation == "retention_move" {
                        RetentionZoneEngine.shared.markRestored(taskId: row.taskId, actionId: row.actionId)
                    }
                    reverted += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "reverted", detail: "核实确认撤销已生效"))
                } else if row.before == nil, afterMatches.isEmpty {
                    wal.reverted(row, undoResult: nil)
                    reverted += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "reverted", detail: "核实确认新建对象已撤销移除"))
                } else if let after = row.after, afterMatches.count == 1, beforeMatches.isEmpty {
                    wal.change(row, state: "applied", after: RemoteSnapshot.from(afterMatches[0], parent: after.parent, workLabel: after.workLabel))
                    applied += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "applied", detail: "撤销尚未落地，已恢复为可重试撤销状态"))
                } else {
                    still += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "撤销状态仍待人工核实"))
                }
            } else {
                if let after = row.after, afterMatches.count == 1, beforeMatches.isEmpty {
                    wal.change(row, state: "applied", after: RemoteSnapshot.from(afterMatches[0], parent: after.parent, workLabel: after.workLabel))
                    applied += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "applied", detail: "核实确认远端操作已生效"))
                } else if afterMatches.isEmpty && (row.before == nil || beforeMatches.count == 1) {
                    wal.change(row, state: "not_applied", error: "核实确认远端未发生变化")
                    notApplied += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "not_applied", detail: "核实确认远端未发生变化"))
                } else {
                    still += 1
                    entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "无法自动确认远端状态"))
                }
            }
        }
        return ReconcileReport(confirmedApplied: applied, confirmedNotApplied: notApplied, confirmedReverted: reverted, stillUncertain: still, entries: entries)
    }
}
