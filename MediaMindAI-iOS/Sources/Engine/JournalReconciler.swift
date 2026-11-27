import Foundation

/// 1:1 逐行复刻自 Android `JournalReconciler.kt`（137 行）：
/// 针对崩溃/断网残留的 `uncertain` / `prepared` / `undo_prepared` 日志行执行只读云端目录对账：
/// - 正向中断（prepared / uncertain）：目标态存在且原态消失 → `applied`；目标态不存在且原态仍在 → `skipped`（未生效）；双态并存或多同名 → 保持 `uncertain` 绝不猜测。
/// - 撤销中断（undo_prepared，M-6）：逆向判定——原态恢复且目标态消失 → `undone`（已撤销）；目标态仍在且原态缺失 → 恢复为 `applied` 供继续撤销；双态不明 → 保持 `uncertain`。
public enum JournalReconciler {
    private static func manualCheckBlocked(taskId: String) async -> Bool {
        await MainActor.run {
            ExecutionEngine.shared.isRollingBack
                || (ExecutionEngine.shared.isRunning && ExecutionEngine.shared.currentRun?.id == taskId)
        }
    }

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
        if await manualCheckBlocked(taskId: runId) {
            return ReconcileReport(confirmedApplied: 0, confirmedNotApplied: 0, confirmedReverted: 0,
                stillUncertain: pending.count, entries: pending.map { row in
                    ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.op, outcome: "uncertain", detail: "任务仍在执行／撤销，未核实在途请求")
                })
        }
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
        if await manualCheckBlocked(taskId: taskId) {
            let pending = wal.uncertainRecords().filter { $0.taskId == taskId }
            return ReconcileReport(confirmedApplied: 0, confirmedNotApplied: 0, confirmedReverted: 0,
                stillUncertain: pending.count, entries: pending.map { row in
                    ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "任务仍在执行／撤销，未核实在途请求")
                })
        }
        let preliminary: ReconcileReport
        if wal.uncertainRecords().contains(where: { $0.taskId == taskId && $0.mayStillComplete == true }) {
            preliminary = await reconcileForwardAutomatically(taskId: taskId, drive: drive, wal: wal)
        } else { preliminary = ReconcileReport(confirmedApplied: 0, confirmedNotApplied: 0, confirmedReverted: 0, stillUncertain: 0, entries: []) }
        let pending = wal.uncertainRecords().filter { $0.taskId == taskId }
        guard !pending.isEmpty else { return preliminary }
        var applied = preliminary.confirmedApplied, notApplied = preliminary.confirmedNotApplied, reverted = 0, still = 0
        var entries = preliminary.entries.filter { $0.outcome != "uncertain" }
        for row in pending {
            guard row.accountId == drive.accountId else {
                still += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "日志账号与当前网盘不匹配，跳过核实"))
                continue
            }
            if row.mayStillComplete == true && (row.state == "prepared" || row.state == "uncertain") {
                still += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain",
                    detail: "已受理操作的身份或结果尚未确认，保留待核实状态"))
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
            // 上传后发现同名但大小不同的文件时，不得把它核实为成功或未写入。
            if row.operation == "upload", let after = row.after,
               afterList?.contains(where: { !$0.isDir && $0.fileName.caseInsensitiveCompare(after.name) == .orderedSame && $0.size != after.size }) == true {
                still += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "上传文件大小与日志不符，请人工核实"))
                continue
            }
            if row.operation == "upload", let after = row.after,
               let expected = ContentDigest.parseMd5OrNull(after.contentMD5)?.digest,
               afterList?.contains(where: { entry in
                   guard !entry.isDir, entry.fileName.caseInsensitiveCompare(after.name) == .orderedSame,
                         let actual = ContentDigest.normalize(algorithm: entry.hashAlgorithm, hash: entry.contentHash),
                         actual.algorithm == "MD5" else { return false }
                   return actual.digest != expected
               }) == true {
                still += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "上传内容 MD5 与日志不符，请人工核实"))
                continue
            }
            func reconciledSnapshot(_ entry: CloudEntry, intended: RemoteSnapshot) -> RemoteSnapshot {
                // 列表可能不提供 MD5；恢复状态不能抹掉上传前落盘的本地摘要。
                let actual = RemoteSnapshot.from(entry, parent: intended.parent, workLabel: intended.workLabel)
                return row.operation == "upload" ? actual.with(contentMD5: intended.contentMD5) : actual
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

            do {
                if row.state == "undo_prepared" {
                    if row.before == nil, let destination = row.undoResult, let after = row.after {
                        guard let targetList = try? await drive.list(folderId: destination.parent) else {
                            still += 1
                            entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "无法读取撤销保留区，转存状态仍待核实"))
                            continue
                        }
                        let targetCandidates = targetList.filter {
                            $0.fileId == destination.id || $0.fileName.caseInsensitiveCompare(destination.name) == .orderedSame
                        }
                        let targetMatches = targetCandidates.filter { entry in
                            guard entry.fileId == destination.id && entry.fileName == destination.name
                                && entry.isDir == destination.directory
                                && (destination.directory || entry.size == destination.size)
                                && (destination.directory || destination.etag?.isEmpty != false || entry.etag == destination.etag) else { return false }
                            if !destination.directory, let expected = destination.contentMD5,
                               let actual = ContentDigest.normalize(algorithm: entry.hashAlgorithm, hash: entry.contentHash), actual.algorithm == "MD5" {
                                return actual.digest == expected
                            }
                            return true
                        }
                        let sourceOccupied = afterList?.contains {
                            $0.fileId == after.id || $0.fileName.caseInsensitiveCompare(after.name) == .orderedSame
                        } == true
                        if !sourceOccupied, targetCandidates.count == 1, targetMatches.count == 1 {
                            let restored = RemoteSnapshot.from(targetMatches[0], parent: destination.parent, workLabel: destination.workLabel)
                            let preserved = row.preserveUnverifiedAsset == true
                            try wal.reverted(row, undoResult: restored, preserved: preserved)
                            reverted += 1
                            entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "reverted", detail: preserved ? "核实确认当前素材已转存保留" : "核实确认新建对象已转存撤销区"))
                        } else if afterMatches.count == 1, targetCandidates.isEmpty {
                            try wal.change(row, state: "applied", after: reconciledSnapshot(afterMatches[0], intended: after))
                            applied += 1
                            entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "applied", detail: "转存未落地，已恢复为可重试撤销状态"))
                        } else {
                            still += 1
                            entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "撤销转存存在双态或目标快照不符，需人工核实"))
                        }
                        continue
                    }
                    if let before = row.before, beforeMatches.count == 1, afterMatches.isEmpty {
                        try wal.reverted(row, undoResult: RemoteSnapshot.from(beforeMatches[0], parent: before.parent))
                        if row.operation == "retention_move" {
                            RetentionZoneEngine.shared.markRestored(taskId: row.taskId, actionId: row.actionId)
                        }
                        reverted += 1
                        entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "reverted", detail: "核实确认撤销已生效"))
                    } else if row.before == nil, afterMatches.isEmpty {
                        try wal.reverted(row, undoResult: nil)
                        reverted += 1
                        entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "reverted", detail: "核实确认新建对象已撤销移除"))
                    } else if let after = row.after, afterMatches.count == 1, beforeMatches.isEmpty {
                        try wal.change(row, state: "applied", after: reconciledSnapshot(afterMatches[0], intended: after))
                        applied += 1
                        entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "applied", detail: "撤销尚未落地，已恢复为可重试撤销状态"))
                    } else {
                        still += 1
                        entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "撤销状态仍待人工核实"))
                    }
                } else {
                    if let after = row.after, afterMatches.count == 1, beforeMatches.isEmpty {
                        try wal.change(row, state: "applied", after: reconciledSnapshot(afterMatches[0], intended: after))
                        applied += 1
                        entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "applied", detail: "核实确认远端操作已生效"))
                    } else if afterMatches.isEmpty && (row.before == nil || beforeMatches.count == 1) && row.mayStillComplete != true {
                        try wal.change(row, state: "not_applied", error: "核实确认远端未发生变化")
                        notApplied += 1
                        entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "not_applied", detail: "核实确认远端未发生变化"))
                    } else {
                        still += 1
                        entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "无法自动确认远端状态"))
                    }
                }
            } catch {
                still += 1
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation, outcome: "uncertain", detail: "核实结果写盘失败：\(error.localizedDescription)"))
            }
        }
        return ReconcileReport(confirmedApplied: applied, confirmedNotApplied: notApplied, confirmedReverted: reverted, stillUncertain: still, entries: entries)
    }
    /// 自动恢复仅核实本次正向事务；不猜测路径身份，不触碰撤销日志，也不执行云端写入。
    public static func reconcileForwardAutomatically(
        taskId: String,
        drive: any CloudDrive,
        wal: ReversibleWalStore = .shared
    ) async -> ReconcileReport {
        let pending = wal.uncertainRecords().filter {
            $0.taskId == taskId && ($0.state == "prepared" || $0.state == "uncertain")
        }
        var applied = 0, notApplied = 0, still = 0
        var entries: [ReconcileEntry] = []
        var listings: [String: [CloudEntry]] = [:]
        var unreadable = Set<String>()
        var digests: [String: String] = [:]
        var digestRequested = Set<String>()

        var backgroundStates: [String: PendingOperationState] = [:]
        func jobKey(_ row: ReversibleWalRecord) -> String? {
            guard let id = row.backgroundTaskId, !id.isEmpty, let operation = row.backgroundOperation,
                  operation == "move" || operation == "upload" else { return nil }
            return operation + "\u{0}" + id
        }
        // 先获得后台终态，再读取目录，避免用后台结束前的旧目录快照判定未生效。
        for row in pending where row.accountId == drive.accountId && row.mayStillComplete == true {
            guard !Task.isCancelled else { break }
            guard let key = jobKey(row), backgroundStates[key] == nil,
                  let id = row.backgroundTaskId, let operation = row.backgroundOperation else { continue }
            do { backgroundStates[key] = try await drive.pendingOperationState(taskId: id, operation: operation) }
            catch { backgroundStates[key] = .processing }
        }

        func list(_ parent: String) async -> [CloudEntry]? {
            if let cached = listings[parent] { return cached }
            guard !Task.isCancelled && !unreadable.contains(parent) else { return nil }
            do {
                let result = try await drive.list(folderId: parent)
                listings[parent] = result
                return result
            } catch {
                unreadable.insert(parent)
                return nil
            }
        }
        func md5(_ entry: CloudEntry, parent: String) async -> String? {
            if let known = ContentDigest.normalize(algorithm: entry.hashAlgorithm, hash: entry.contentHash), known.algorithm == "MD5" {
                return known.digest
            }
            let key = parent + "\u{0}" + entry.fileId
            if digestRequested.contains(key) { return digests[key] }
            guard !Task.isCancelled else { return nil }
            digestRequested.insert(key)
            guard let value = try? await drive.assetMD5(fileId: entry.fileId, parentId: parent, expectedSize: entry.size),
                  let normalized = ContentDigest.parseMd5OrNull(value)?.digest else { return nil }
            digests[key] = normalized
            return normalized
        }
        func strongEtag(_ value: String?) -> Bool {
            guard let value, !value.isEmpty else { return false }
            return !value.lowercased().hasPrefix("w/")
        }
        func matches(_ entry: CloudEntry, snapshot: RemoteSnapshot, expectedId: String) async -> Bool {
            guard entry.fileName == snapshot.name, entry.isDir == snapshot.directory,
                  !expectedId.isEmpty, entry.fileId == expectedId else { return false }
            if !snapshot.directory {
                guard entry.size == snapshot.size else { return false }
                if let etag = snapshot.etag, !etag.isEmpty, entry.etag != etag { return false }
                if let expected = snapshot.contentMD5 {
                    guard let actual = await md5(entry, parent: snapshot.parent), actual == expected else { return false }
                }
            }
            return true
        }
        func unresolved(_ row: ReversibleWalRecord, _ reason: String) {
            still += 1
            entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation,
                outcome: "uncertain", detail: reason))
        }

        let supported: Set<String> = ["rename", "move", "backup", "quarantine", "retention_move", "mkdir", "upload"]
        for row in pending {
            guard !Task.isCancelled else { unresolved(row, "自动核实已取消，未改写日志"); continue }
            guard row.accountId == drive.accountId else { unresolved(row, "任务账号与当前网盘不匹配，未自动核实"); continue }
            guard supported.contains(row.operation), let after = row.after else {
                unresolved(row, "缺少可安全自动核实的正向快照"); continue
            }
            guard let destination = await list(after.parent) else {
                unresolved(row, "目标目录读取失败，保留待核实状态"); continue
            }
            var source: [CloudEntry] = []
            if let before = row.before {
                guard let result = await list(before.parent) else {
                    unresolved(row, "源目录读取失败，保留待核实状态"); continue
                }
                source = result.filter { $0.fileName.caseInsensitiveCompare(before.name) == .orderedSame }
            }
            let target = destination.filter { $0.fileName.caseInsensitiveCompare(after.name) == .orderedSame }
            guard target.count <= 1, source.count <= 1 else {
                unresolved(row, "源或目标存在同名歧义，未自动判定"); continue
            }
            let targetId = drive.kind.idsArePaths ? DrivePaths.join(parent: after.parent, name: after.name) : after.id
            var outcome: String?
            var confirmed: RemoteSnapshot?
            if let entry = target.first, source.isEmpty {
                var proven = false
                if row.operation == "upload", row.before == nil, !after.directory, let expected = after.contentMD5 {
                    // 上传意图尚未获得稳定 ID 时，也必须以本地上传字节摘要证明内容。
                    let identityMatches = targetId.isEmpty || entry.fileId == targetId
                    let etagMatches = after.etag?.isEmpty != false || entry.etag == after.etag
                    if identityMatches && entry.fileName == after.name && !entry.isDir && entry.size == after.size && etagMatches,
                       let actual = await md5(entry, parent: after.parent), actual == expected { proven = true }
                } else if row.before == nil, row.operation == "mkdir", after.directory,
                          after.name.hasPrefix(".PanScraper.New-"),
                          UUID(uuidString: String(after.name.dropFirst(".PanScraper.New-".count))) != nil {
                    proven = entry.fileName == after.name && entry.isDir && (targetId.isEmpty || entry.fileId == targetId)
                } else if let before = row.before {
                    proven = await matches(entry, snapshot: after, expectedId: targetId)
                    if proven && drive.kind.idsArePaths {
                        let etagProof = strongEtag(before.etag) && entry.etag == before.etag
                        let digestProof: Bool
                        if let expected = before.contentMD5, !entry.isDir {
                            digestProof = await md5(entry, parent: after.parent) == expected
                        } else { digestProof = false }
                        proven = etagProof || digestProof
                    }
                }
                if proven {
                    outcome = "applied"
                    confirmed = RemoteSnapshot.from(entry, parent: after.parent, workLabel: after.workLabel)
                        .with(contentMD5: after.contentMD5)
                }
            } else if target.isEmpty {
                if let before = row.before, let entry = source.first {
                    var unchanged = await matches(entry, snapshot: before, expectedId: before.id)
                    if unchanged && drive.kind.idsArePaths {
                        let etagProof = strongEtag(before.etag) && entry.etag == before.etag
                        let digestProof: Bool
                        if let expected = before.contentMD5, !entry.isDir {
                            digestProof = await md5(entry, parent: before.parent) == expected
                        } else { digestProof = false }
                        unchanged = etagProof || digestProof
                    }
                    if unchanged { outcome = "not_applied" }
                } else if row.before == nil {
                    // 获得过对象 ID 时，改名后出现于同一父目录不等于“从未写入”。
                    let idStillPresent = !after.id.isEmpty && destination.contains { $0.fileId == after.id }
                    if !idStillPresent && (row.operation == "upload" || row.operation == "mkdir") { outcome = "not_applied" }
                }
            }
            let backgroundFailed = jobKey(row).map { backgroundStates[$0] == .failed } ?? false
            if outcome == "not_applied", row.mayStillComplete == true && !backgroundFailed { outcome = nil }
            guard !Task.isCancelled else { unresolved(row, "自动核实已取消，未改写日志"); continue }
            guard let outcome else {
                unresolved(row, "身份、内容或位置证据不足／存在冲突，保留待核实状态"); continue
            }
            do {
                // 读取期间若其他收口已更改该行，绝不覆盖其终态。
                guard try wal.reconcileForwardIfPending(row, state: outcome, after: confirmed,
                    error: outcome == "not_applied" ? "自动核实确认未生效" : nil, backgroundTaskFailed: backgroundFailed) else { continue }
                if outcome == "applied" { applied += 1 } else { notApplied += 1 }
                entries.append(ReconcileEntry(id: row.id, actionId: row.actionId, operation: row.operation,
                    outcome: outcome, detail: outcome == "applied" ? "自动核实确认已生效" : "自动核实确认未生效，可安全重试"))
            } catch { unresolved(row, "核实结果写盘失败，未继续执行") }
        }
        return ReconcileReport(confirmedApplied: applied, confirmedNotApplied: notApplied, confirmedReverted: 0, stillUncertain: still, entries: entries)
    }

}
