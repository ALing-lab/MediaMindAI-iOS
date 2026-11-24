import Foundation

/// 1:1 逐行复刻自 Android `IdRemap.kt`（44 行）：
/// 路径型网盘（WebDAV）执行过程中的目录/文件 ID 重映射与环路检测。
public final class IdRemap: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String]
    private let pathMode: Bool

    public init(initial: [String: String] = [:], pathMode: Bool) {
        self.map = initial
        self.pathMode = pathMode
    }

    public func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return map
    }

    public func rebind(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        map.removeValue(forKey: id)
    }

    public func record(old: String, new: String) {
        guard old != new else { return }
        lock.lock()
        defer { lock.unlock() }
        map[old] = new
    }

    public func resolve(_ id: String?) throws -> String? {
        guard var cur = id else { return nil }
        lock.lock()
        let snap = map
        lock.unlock()

        var seen: Set<String> = []
        let maxSteps = max(64, snap.count * 2 + 16)
        for _ in 0..<maxSteps {
            guard seen.insert(cur).inserted else {
                throw DriveError.api(code: -10, message: "路径映射存在循环，已停止以避免操作错误对象")
            }
            if let exact = snap[cur], exact != cur {
                cur = exact
                continue
            }
            if !pathMode { return cur }
            let prefix = snap.keys
                .filter { k in
                    let normK = k.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard !normK.isEmpty else { return false }
                    return cur.hasPrefix("/\(normK)/") || cur.hasPrefix("\(normK)/")
                }
                .max(by: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).count < $1.trimmingCharacters(in: CharacterSet(charactersIn: "/")).count })
            guard let prefix, let mapped = snap[prefix] else {
                return cur
            }
            let normOld = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let matchedOld = cur.hasPrefix("/\(normOld)/") ? "/\(normOld)" : normOld
            let normNew = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let trimNew = normNew.isEmpty ? "" : (mapped.hasPrefix("/") ? "/\(normNew)" : normNew)
            cur = trimNew + String(cur.dropFirst(matchedOld.count))
        }
        throw DriveError.api(code: -11, message: "路径映射无法收敛，已停止以避免操作错误对象")
    }

    /// 非抛出便捷解析：若发生环路异常则回退原值（供日志/展示路径使用）。
    public func resolveOrSelf(_ id: String) -> String {
        (try? resolve(id)) ?? id
    }
}
