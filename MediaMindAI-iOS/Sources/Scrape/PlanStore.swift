import Foundation
import CryptoKit

/// 1:1 逐行复刻自 Android `PlanStore.kt`（226 行）：
/// 预刮削计划原子落盘、规范化 SHA-256 计划身份哈希（`key`）、并发读写锁、
/// 勾选差量合并（`mergeSelection`）与按任务绑定校验（`forTask` / `updateBound`）。
public enum AtomicFileIO {
    /// 原子写入文本（先写同目录临时文件，再原子替换，防写入中断损坏 JSON）。
    public static func writeText(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString.prefix(8))")
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "AtomicFileIO", code: -1, userInfo: [NSLocalizedDescriptionKey: "UTF-8 编码失败"])
        }
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

public enum PlanStoreError: LocalizedError {
    case invalidPlanFile
    case noPlanFile
    case planChanged
    case planRebuilt
    case taskMismatch
    case taskActionsChanged
    case progressChanged

    public var errorDescription: String? {
        switch self {
        case .invalidPlanFile: return "无效的计划文件"
        case .noPlanFile: return "没有计划文件"
        case .planChanged: return "计划已变化，请重新打开预览"
        case .planRebuilt: return "计划已重新生成，请重新打开预览"
        case .taskMismatch: return "任务与计划不匹配，请重新扫描"
        case .taskActionsChanged: return "任务操作已变化，请重新扫描"
        case .progressChanged: return "计划进度已变化，请重新匹配"
        }
    }
}

public final class PlanStore: @unchecked Sendable {
    public static let shared = PlanStore()

    public struct PlanSummary: Equatable, Sendable {
        public let path: String
        public let createdAt: String
        public let groups: Int
        public let actions: Int
        public let unmatched: Int
        public let stats: PlanStats

        public init(path: String, createdAt: String, groups: Int, actions: Int, unmatched: Int, stats: PlanStats) {
            self.path = path
            self.createdAt = createdAt
            self.groups = groups
            self.actions = actions
            self.unmatched = unmatched
            self.stats = stats
        }
    }

    private let plansDir: URL
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public private(set) var currentPath: String?
    public private(set) var summary: PlanSummary?

    public init(plansDir: URL? = nil) {
        if let plansDir {
            self.plansDir = plansDir
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.plansDir = base.appendingPathComponent("MediaMindAI/plans", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.plansDir, withIntermediateDirectories: true)
    }

    private func validatePlanFileName(_ name: String) throws {
        let clean = URL(fileURLWithPath: name).lastPathComponent
        guard clean == name, name.hasPrefix("scrape_"), name.hasSuffix(".json") else {
            throw PlanStoreError.invalidPlanFile
        }
    }

    public func readNamed(_ name: String) throws -> ScrapePlan {
        lock.lock()
        defer { lock.unlock() }
        try validatePlanFileName(name)
        let data = try Data(contentsOf: plansDir.appendingPathComponent(name))
        return try decoder.decode(ScrapePlan.self, from: data)
    }

    public func latestFile() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: plansDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let candidates = urls.filter { $0.lastPathComponent.hasPrefix("scrape_") && $0.pathExtension == "json" }
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    @discardableResult
    public func save(_ plan: ScrapePlan, name: String? = nil) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let fileName = name ?? "scrape_\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.lowercased()).json"
        let file = plansDir.appendingPathComponent(fileName)
        let text = String(data: try encoder.encode(plan), encoding: .utf8) ?? "{}"
        try AtomicFileIO.writeText(text, to: file)
        try AtomicFileIO.writeText(fileName, to: plansDir.appendingPathComponent("current.txt"))
        updateSummary(file: file, plan: plan)
        return file
    }

    /// 仅原子落盘独立执行计划文件，不覆盖 `current.txt`（供部分执行解耦预览卡使用）。
    @discardableResult
    public func saveSilent(_ plan: ScrapePlan, name: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try validatePlanFileName(name)
        let file = plansDir.appendingPathComponent(name)
        let text = String(data: try encoder.encode(plan), encoding: .utf8) ?? "{}"
        try AtomicFileIO.writeText(text, to: file)
        return file
    }

    public func load(file: URL? = nil) throws -> ScrapePlan {
        lock.lock()
        defer { lock.unlock() }
        guard let target = file ?? latestFile() else { throw PlanStoreError.noPlanFile }
        let data = try Data(contentsOf: target)
        let plan = try decoder.decode(ScrapePlan.self, from: data)
        updateSummary(file: target, plan: plan)
        return plan
    }

    public func loadNamed(_ name: String) throws -> ScrapePlan {
        try validatePlanFileName(name)
        return try load(file: plansDir.appendingPathComponent(name))
    }

    public func loadOrNull() -> ScrapePlan? {
        guard let latest = latestFile() else { return nil }
        return try? load(file: latest)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentPath = nil
        summary = nil
    }

    /// 排除执行进度、勾选与展示元数据，计算计划内容与所属账号的规范 SHA-256 身份哈希。
    public func key(_ plan: ScrapePlan) -> String {
        var stable = plan
        stable.taskPolicy = nil
        stable.reviewDisposition = nil
        stable.actions = plan.actions.map { act in
            var copy = act
            copy.done = false
            copy.selected = true
            copy.error = nil
            return copy
        }
        stable.groups = plan.groups.map { grp in
            var copy = grp
            copy.policyOverride = nil
            copy.sourceRootId = nil
            return copy
        }
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        canonicalEncoder.dateEncodingStrategy = .iso8601
        guard let data = try? canonicalEncoder.encode(stable),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return stable.id
        }
        obj.removeValue(forKey: "taskPolicy")
        if var groups = obj["groups"] as? [[String: Any]] {
            groups = groups.map { g in
                var fields = g
                fields.removeValue(forKey: "policyOverride")
                fields.removeValue(forKey: "sourceRootId")
                fields.removeValue(forKey: "posterPath")
                fields.removeValue(forKey: "rating")
                return fields
            }
            obj["groups"] = groups
        }
        if var actions = obj["actions"] as? [[String: Any]] {
            actions = actions.map { a in
                var fields = a
                if (fields["enabled"] as? Bool) == true { fields.removeValue(forKey: "enabled") }
                fields.removeValue(forKey: "error")
                fields.removeValue(forKey: "note")
                return fields
            }
            obj["actions"] = actions
        }
        let serialized = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? data
        let digest = SHA256.hash(data: serialized)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func fileFor(_ plan: ScrapePlan) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let expected = key(plan)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: plansDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { throw PlanStoreError.planChanged }

        let sorted = urls
            .filter { $0.lastPathComponent.hasPrefix("scrape_") && $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for url in sorted {
            if let data = try? Data(contentsOf: url),
               let candidate = try? decoder.decode(ScrapePlan.self, from: data),
               key(candidate) == expected {
                return url
            }
        }
        throw PlanStoreError.planChanged
    }

    @discardableResult
    public func updateBound(file: URL, expectedKey: String, transform: (ScrapePlan) throws -> ScrapePlan) throws -> ScrapePlan {
        lock.lock()
        defer { lock.unlock() }
        let data = try Data(contentsOf: file)
        let current = try decoder.decode(ScrapePlan.self, from: data)
        guard key(current) == expectedKey else { throw PlanStoreError.planRebuilt }
        let updated = try transform(current)
        let text = String(data: try encoder.encode(updated), encoding: .utf8) ?? "{}"
        try AtomicFileIO.writeText(text, to: file)
        if currentPath == file.path {
            updateSummary(file: file, plan: updated)
        }
        return updated
    }

    @discardableResult
    public func replace(before: ScrapePlan, after: ScrapePlan) throws -> ScrapePlan {
        let file = try fileFor(before)
        return try updateBound(file: file, expectedKey: key(before)) { cur in
            guard cur.actions == before.actions else { throw PlanStoreError.progressChanged }
            return after
        }
    }

    /// 只合并本次勾选差量，保留执行器写入的 done/error。
    @discardableResult
    public func mergeSelection(before: ScrapePlan, after: ScrapePlan) throws -> ScrapePlan {
        let file = try fileFor(before)
        return try updateBound(file: file, expectedKey: key(before)) { cur in
            let old = Dictionary(before.actions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let changes = after.actions.filter { old[$0.id]?.selected != $0.selected }
            var next = PlanSelection.set(plan: cur, ids: changes.filter { $0.selected }.map { $0.id }, on: true)
            next = PlanSelection.set(plan: next, ids: changes.filter { !$0.selected }.map { $0.id }, on: false)
            return next
        }
    }

    @discardableResult
    public func update(_ transform: (ScrapePlan) throws -> ScrapePlan) throws -> ScrapePlan {
        lock.lock()
        defer { lock.unlock() }
        guard let file = latestFile() else { throw PlanStoreError.noPlanFile }
        let current = try load(file: file)
        let updated = try transform(current)
        let text = String(data: try encoder.encode(updated), encoding: .utf8) ?? "{}"
        try AtomicFileIO.writeText(text, to: file)
        updateSummary(file: file, plan: updated)
        return updated
    }

    /// 按文件名更新指定计划（多张待确认任务卡并存时，任务设置写回对应计划，不串到最新计划）。
    @discardableResult
    public func updateNamed(_ name: String, transform: (ScrapePlan) throws -> ScrapePlan) throws -> ScrapePlan {
        lock.lock()
        defer { lock.unlock() }
        try validatePlanFileName(name)
        let file = plansDir.appendingPathComponent(name)
        let current = try load(file: file)
        let updated = try transform(current)
        let text = String(data: try encoder.encode(updated), encoding: .utf8) ?? "{}"
        try AtomicFileIO.writeText(text, to: file)
        if currentPath == file.path {
            updateSummary(file: file, plan: updated)
        }
        return updated
    }

    /// 校验任务卡与计划文件一致性（1:1 对标 Android `PlanStore.forTask`）。
    public func forTask(planName: String, expectedAccountId: String, expectedPlanKey: String, actionIds: [String]) throws -> ScrapePlan {
        let plan = try loadNamed(planName)
        guard plan.accountId == expectedAccountId,
              expectedPlanKey.isEmpty || key(plan) == expectedPlanKey else {
            throw PlanStoreError.taskMismatch
        }
        let existingIds = Set(plan.actions.map { $0.id })
        guard actionIds.allSatisfy({ existingIds.contains($0) }) else {
            throw PlanStoreError.taskActionsChanged
        }
        return plan
    }

    public static func nowLabel(date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return df.string(from: date) + "（洛杉矶）"
    }

    private func updateSummary(file: URL, plan: ScrapePlan) {
        let stats = PlanStats.compute(groups: plan.groups, actions: plan.actions)
        currentPath = file.path
        summary = PlanSummary(
            path: file.path,
            createdAt: Self.nowLabel(date: plan.createdAt),
            groups: plan.groups.count,
            actions: plan.actions.count,
            unmatched: stats.unmatchedGroups,
            stats: stats
        )
    }
}
