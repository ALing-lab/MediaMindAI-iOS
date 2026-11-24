import Foundation

/// 1:1 复刻自 Android `ContentDigest.kt`：强格式内容哈希归一化与同内容判定。
public enum ContentDigest {
    private static let algoLengths: [String: Int] = [
        "MD5": 32,
        "SHA-1": 40,
        "SHA1": 40,
        "SHA-256": 64,
        "SHA256": 64,
    ]

    public static func normalize(algorithm: String?, hash: String?) -> (algorithm: String, digest: String)? {
        guard let rawAlgo = algorithm?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "_", with: "-"),
              let expectedLen = algoLengths[rawAlgo],
              let rawHash = hash?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
              !rawHash.isEmpty,
              !rawHash.lowercased().hasPrefix("w/"),
              !rawHash.contains("-"),
              rawHash.count == expectedLen else {
            return nil
        }
        let lower = rawHash.lowercased()
        guard lower.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        let normAlgo: String
        switch rawAlgo {
        case "SHA1": normAlgo = "SHA-1"
        case "SHA256": normAlgo = "SHA-256"
        default: normAlgo = rawAlgo
        }
        return (normAlgo, lower)
    }

    /// 123 / 光鸭等仅在确认为纯 32 位十六进制（非分片 ETag、非弱标记）时提取 MD5。
    public static func parseMd5OrNull(_ raw: String?) -> (algorithm: String, digest: String)? {
        normalize(algorithm: "MD5", hash: raw)
    }

    /// 115 列表的 sha 字段：严格校验 40 位 SHA-1。
    public static func parseSha1OrNull(_ raw: String?) -> (algorithm: String, digest: String)? {
        normalize(algorithm: "SHA-1", hash: raw)
    }

    /// 解析 Nextcloud/ownCloud WebDAV 扩展 oc:checksums（如 "SHA1:... MD5:..."）。
    public static func parseWebDavChecksums(_ raw: String?) -> (algorithm: String, digest: String)? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for preferred in ["SHA-256", "SHA256", "SHA-1", "SHA1", "MD5"] {
            let prefix = "\(preferred):"
            if let token = parts.first(where: { $0.lowercased().hasPrefix(prefix.lowercased()) }) {
                let value = String(token.dropFirst(prefix.count))
                if let parsed = normalize(algorithm: preferred, hash: value) {
                    return parsed
                }
            }
        }
        return nil
    }

    public static func isSameContent(_ a: CloudEntry, _ b: CloudEntry) -> Bool {
        guard !a.isDir, !b.isDir, a.size > 0, a.size == b.size else { return false }
        guard let da = normalize(algorithm: a.hashAlgorithm, hash: a.contentHash),
              let db = normalize(algorithm: b.hashAlgorithm, hash: b.contentHash) else {
            return false
        }
        return da.algorithm == db.algorithm && da.digest == db.digest
    }
}

/// 1:1 复刻自 Android `DuplicateDetector.kt`：
/// 区分 SAME_OBJECT / MULTI_VERSION / CONFIRMED_DUPLICATE / SUSPECTED_DUPLICATE / NAME_CONFLICT，
/// 确定性挑选主库主本，默认原位不动绝不自动删除。
public enum DuplicateDetector {
    public enum Kind: String, Codable, Sendable {
        case sameObject = "SAME_OBJECT"
        case multiVersion = "MULTI_VERSION"
        case confirmedDuplicate = "CONFIRMED_DUPLICATE"
        case suspectedDuplicate = "SUSPECTED_DUPLICATE"
        case nameConflict = "NAME_CONFLICT"

        public var label: String {
            switch self {
            case .sameObject: return "同一对象重复扫描"
            case .multiVersion: return "多版本共存"
            case .confirmedDuplicate: return "确定重复（内容校验相同）"
            case .suspectedDuplicate: return "疑似重复（缺少完整校验）"
            case .nameConflict: return "命名冲突"
            }
        }
    }

    public enum Resolution: String, Codable, Sendable {
        case keepInPlace = "KEEP_IN_PLACE"
        case moveToRetention = "MOVE_TO_RETENTION"

        public var label: String {
            switch self {
            case .keepInPlace: return "原位置不动"
            case .moveToRetention: return "转移至重复保留区"
            }
        }
    }

    public struct Candidate: Codable, Hashable, Sendable {
        public let accountId: String
        public let entry: CloudEntry
        public let sourcePath: String
        public let workKey: String
        public let workTitle: String
        public let season: Int?
        public let episode: Int?
        public let versionLabel: String
        public let targetDir: String
        public let targetName: String

        public init(
            accountId: String,
            entry: CloudEntry,
            sourcePath: String,
            workKey: String,
            workTitle: String,
            season: Int? = nil,
            episode: Int? = nil,
            versionLabel: String = "",
            targetDir: String = "",
            targetName: String = ""
        ) {
            self.accountId = accountId
            self.entry = entry
            self.sourcePath = sourcePath
            self.workKey = workKey
            self.workTitle = workTitle
            self.season = season
            self.episode = episode
            self.versionLabel = versionLabel
            self.targetDir = targetDir
            self.targetName = targetName
        }
    }

    public struct DuplicateGroup: Identifiable, Codable, Hashable, Sendable {
        public let id: String
        public let kind: Kind
        public let workTitle: String
        public let targetName: String
        public let items: [Candidate]
        public let evidence: String
        public var resolution: Resolution
        public var primaryFileId: String?

        public init(
            id: String,
            kind: Kind,
            workTitle: String,
            targetName: String,
            items: [Candidate],
            evidence: String,
            resolution: Resolution = .keepInPlace,
            primaryFileId: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.workTitle = workTitle
            self.targetName = targetName
            self.items = items
            self.evidence = evidence
            self.resolution = resolution
            self.primaryFileId = primaryFileId
        }

        public func retentionTargets() -> [Candidate] {
            guard resolution == .moveToRetention else { return [] }
            guard let keepId = primaryFileId ?? items.first?.entry.fileId else { return [] }
            return items.filter { $0.entry.fileId != keepId }
        }
    }

    private static func pickPrimaryFileId(_ items: [Candidate]) -> String? {
        items.min { a, b in
            let aMatch = (!a.targetName.isEmpty && a.entry.fileName.caseInsensitiveCompare(a.targetName) == .orderedSame) ? 0 : 1
            let bMatch = (!b.targetName.isEmpty && b.entry.fileName.caseInsensitiveCompare(b.targetName) == .orderedSame) ? 0 : 1
            if aMatch != bMatch { return aMatch < bMatch }
            if a.sourcePath.count != b.sourcePath.count { return a.sourcePath.count < b.sourcePath.count }
            if a.entry.fileName.count != b.entry.fileName.count { return a.entry.fileName.count < b.entry.fileName.count }
            return a.entry.fileId < b.entry.fileId
        }?.entry.fileId
    }

    public static func analyze(candidates: [Candidate]) -> [DuplicateGroup] {
        var seenPairs: Set<String> = []
        let unique = candidates.filter { seenPairs.insert("\($0.accountId)|\($0.entry.fileId)").inserted }

        var result: [DuplicateGroup] = []
        let bySlot = Dictionary(grouping: unique) { c in
            "\(c.accountId)|\(c.workKey)|\(c.season.map(String.init) ?? "")|\(c.episode.map(String.init) ?? "")"
        }

        var seq = 0
        for (_, groupItems) in bySlot.sorted(by: { $0.key < $1.key }) {
            guard groupItems.count > 1 else { continue }
            let workTitle = groupItems[0].workTitle

            // 1. 同目标目录 + 同目标名碰撞检查
            let byTarget = Dictionary(grouping: groupItems) { "\($0.targetDir.lowercased())|\($0.targetName.lowercased())" }
            var handledIds: Set<String> = []

            for (_, colliding) in byTarget.sorted(by: { $0.key < $1.key }) {
                guard colliding.count > 1, !colliding[0].targetName.isEmpty else { continue }
                let first = colliding[0].entry
                let allSameContent = colliding.dropFirst().allSatisfy { ContentDigest.isSameContent(first, $0.entry) }
                let allHaveDigest = colliding.allSatisfy { ContentDigest.normalize(algorithm: $0.entry.hashAlgorithm, hash: $0.entry.contentHash) != nil }

                let kind: Kind
                let evidence: String
                if allSameContent {
                    kind = .confirmedDuplicate
                    evidence = "大小一致（\(first.size) B）且 \(first.hashAlgorithm ?? "") 完整校验相同"
                } else if allHaveDigest {
                    kind = .nameConflict
                    evidence = "目标名相同但内容校验不同，阻止覆盖"
                } else {
                    kind = .suspectedDuplicate
                    evidence = "拟生成相同目标名且缺少可比完整校验，标记为疑似重复"
                }
                seq += 1
                result.append(DuplicateGroup(
                    id: "dup-\(seq)",
                    kind: kind,
                    workTitle: workTitle,
                    targetName: colliding[0].targetName,
                    items: colliding,
                    evidence: evidence,
                    primaryFileId: pickPrimaryFileId(colliding)
                ))
                for c in colliding { handledIds.insert(c.entry.fileId) }
            }

            // 2. 剩余不同目标名的同作品同季集文件
            let remaining = groupItems.filter { !handledIds.contains($0.entry.fileId) }
            guard remaining.count > 1 else { continue }

            // 2a. 按可靠内容哈希归并确定重复
            var byHash: [String: [Candidate]] = [:]
            for c in remaining {
                if let d = ContentDigest.normalize(algorithm: c.entry.hashAlgorithm, hash: c.entry.contentHash), c.entry.size > 0 {
                    let key = "\(d.algorithm)|\(d.digest)|\(c.entry.size)"
                    byHash[key, default: []].append(c)
                }
            }
            for (key, matched) in byHash.sorted(by: { $0.key < $1.key }) where matched.count > 1 {
                let parts = key.split(separator: "|")
                let algo = parts.first.map(String.init) ?? "HASH"
                let sz = parts.last.map(String.init) ?? "0"
                seq += 1
                result.append(DuplicateGroup(
                    id: "dup-\(seq)",
                    kind: .confirmedDuplicate,
                    workTitle: workTitle,
                    targetName: matched[0].targetName.isEmpty ? matched[0].entry.fileName : matched[0].targetName,
                    items: matched,
                    evidence: "大小一致（\(sz) B）且 \(algo) 完整校验相同",
                    primaryFileId: pickPrimaryFileId(matched)
                ))
                for c in matched { handledIds.insert(c.entry.fileId) }
            }

            // 2b. 剩余项按 (versionLabel, size) 检查疑似重复；版本不同则属多版本共存不列为重复
            let rest = remaining.filter { !handledIds.contains($0.entry.fileId) }
            let byVerSize = Dictionary(grouping: rest) { "\($0.versionLabel.lowercased())|\($0.entry.size)" }
            for (_, matched) in byVerSize.sorted(by: { $0.key < $1.key }) where matched.count > 1 {
                let sz = matched[0].entry.size
                let ver = matched[0].versionLabel
                if sz <= 0 && ver.isEmpty { continue }
                seq += 1
                result.append(DuplicateGroup(
                    id: "dup-\(seq)",
                    kind: .suspectedDuplicate,
                    workTitle: workTitle,
                    targetName: matched[0].targetName.isEmpty ? matched[0].entry.fileName : matched[0].targetName,
                    items: matched,
                    evidence: "同作品同季集、版本与大小一致（\(sz) B），但缺少可比完整内容校验",
                    primaryFileId: pickPrimaryFileId(matched)
                ))
            }
        }
        return result
    }
}

/// 云端保留区实体操作引擎（1:1 对标 Android `RetentionZone.kt`：云盘新建保留区目录、实体移入、实体还原与确认清理）。
public enum CloudRetentionZone {
    public static let defaultFolderName = "_MediaMind保留区"

    /// 确保云端保留区目录存在并返回其目录 ID。
    public static func ensureRetentionFolder(drive: any CloudDrive, rootParentId: String? = nil) async throws -> String {
        let parent = rootParentId ?? drive.rootId
        let existing = try await drive.list(folderId: parent)
        if let hit = existing.first(where: { $0.isDir && $0.fileName == defaultFolderName }) {
            return hit.fileId
        }
        return try await drive.mkdir(parentId: parent, name: defaultFolderName)
    }

    /// 将文件真实移入云盘 `_MediaMind保留区` 目录，并写入本地 `RetentionZoneStore` 记录以便还原。
    @discardableResult
    public static func parkToCloud(
        fileId: String,
        fileName: String,
        originalParentId: String,
        reason: String,
        drive: any CloudDrive,
        rootParentId: String? = nil
    ) async throws -> RetentionItem {
        let folderId = try await ensureRetentionFolder(drive: drive, rootParentId: rootParentId)
        let movedId = try await drive.move(fileId: fileId, destParentId: folderId)
        let item = RetentionItem(
            accountId: drive.accountId,
            provider: drive.kind.rawValue,
            fileId: movedId.isEmpty ? fileId : movedId,
            fileName: fileName,
            originalParentId: originalParentId,
            reason: reason
        )
        await MainActor.run {
            RetentionZoneStore.shared.add(item)
        }
        return item
    }

    /// 将保留区文件实体还原到原目录（或当原目录缺失时还原到用户指定的 fallbackParentId）。
    public static func restoreFromCloud(
        item: RetentionItem,
        drive: any CloudDrive,
        fallbackParentId: String? = nil
    ) async throws {
        let dest = (fallbackParentId?.isEmpty == false ? fallbackParentId : nil) ?? item.originalParentId
        guard !dest.isEmpty else {
            throw DriveError.invalidInput("原目录信息缺失，请指定还原目标目录")
        }
        _ = try await drive.move(fileId: item.fileId, destParentId: dest)
        await MainActor.run {
            RetentionZoneStore.shared.remove(id: item.id)
        }
    }

    /// 确认清理保留区中的云端文件（移入回收站或 WebDAV 删除）并移除本地记录。
    public static func deleteFromCloud(item: RetentionItem, drive: any CloudDrive) async throws {
        _ = try await drive.trash(fileId: item.fileId)
        await MainActor.run {
            RetentionZoneStore.shared.remove(id: item.id)
        }
    }
}
