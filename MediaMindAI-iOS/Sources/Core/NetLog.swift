import Foundation

/// 1:1 复刻自 Android `NetLog.kt`：
/// 线程安全网络与任务诊断日志（400 条内存环形缓冲 + 可选 2 MB 滚动落盘 `net.log` / `net.1.log` + 强力脱敏 + 一键合并崩溃报告导出）。
/// 绝不记录 Authorization / Cookie / api_key / password / 长令牌明文。
public actor NetLog {
    public static let shared = NetLog()

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let tag: String
        public let level: String
        public let message: String
    }

    public struct Activity: Equatable, Sendable {
        public var requests: Int
        public var inflight: String?
        public var inflightSince: Date?
        public var last: String?
        public var lastError: String?
        public var retryNote: String?
        public var retryAt: Date?
        public var lastActivityAt: Date?

        public init(
            requests: Int = 0,
            inflight: String? = nil,
            inflightSince: Date? = nil,
            last: String? = nil,
            lastError: String? = nil,
            retryNote: String? = nil,
            retryAt: Date? = nil,
            lastActivityAt: Date? = nil
        ) {
            self.requests = requests
            self.inflight = inflight
            self.inflightSince = inflightSince
            self.last = last
            self.lastError = lastError
            self.retryNote = retryNote
            self.retryAt = retryAt
            self.lastActivityAt = lastActivityAt
        }
    }

    private var entries: [Entry] = []
    private var ringLines: [String] = []
    private var activityState = Activity()
    private let maxEntries = 400
    private let maxDiskBytes: UInt64 = 2_000_000

    public var fileEnabled: Bool = false
    private let logDir: URL

    private static let bearerRegex = try! NSRegularExpression(pattern: #"(?i)(Bearer\s+)[A-Za-z0-9._\-+/=]{8,}"#)
    private static let querySecretRegex = try! NSRegularExpression(pattern: #"(?i)([?&](?:api_?key|key|token|access_token|refresh_token|secret|password)=)[^&\s]+"#)
    private static let kvSecretRegex = try! NSRegularExpression(pattern: #"(?i)(api_key|access_token|refresh_token|token|cookie|authorization|password|passwd|sign|signature|ak|sk|security_token)(["']?\s*[=:]\s*["']?)[^\s&"',;}]+"#)
    private static let skKeyRegex = try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_\-]{16,}\b"#)
    private static let aizaKeyRegex = try! NSRegularExpression(pattern: #"\bAIza[0-9A-Za-z_\-]{20,}\b"#)
    private static let longTokenRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-]{48,}"#)

    public init(logDirectory: URL? = nil) {
        if let dir = logDirectory {
            self.logDir = dir
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.logDir = support.appendingPathComponent("MediaMindAI/logs", isDirectory: true)
        }
    }

    /// 统一脱敏日志文本，防止 AI / TMDB / 网盘令牌与密码泄露。
    public nonisolated static func redactSecrets(_ text: String) -> String {
        sanitize(text)
    }

    public nonisolated static func sanitize(_ text: String) -> String {
        var out = text
        func replace(_ regex: NSRegularExpression, template: String) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        replace(bearerRegex, template: "$1***")
        replace(querySecretRegex, template: "$1***")
        replace(kvSecretRegex, template: "$1$2***")
        replace(skKeyRegex, template: "sk-***")
        replace(aizaKeyRegex, template: "AIza***")
        replace(longTokenRegex, template: "***")
        return out
    }

    public func setFileEnabled(_ enabled: Bool) {
        fileEnabled = enabled
    }

    public func logFileURL() -> URL {
        logDir.appendingPathComponent("net.log")
    }

    public func rotatedLogFileURL() -> URL {
        logDir.appendingPathComponent("net.1.log")
    }

    public func currentActivity() -> Activity {
        activityState
    }

    public func resetActivity() {
        activityState = Activity(lastActivityAt: Date())
    }

    public func line(_ tag: String, _ message: String) {
        append(tag: tag, level: "INFO", message: message)
    }

    public func note(_ tag: String, _ message: String) {
        append(tag: tag, level: "INFO", message: message)
        activityState.last = Self.sanitize("\(tag) \(message)")
        activityState.lastActivityAt = Date()
    }

    public func error(_ tag: String, _ message: String) {
        append(tag: tag, level: "ERR", message: message)
        activityState.lastError = Self.sanitize("\(tag)：\(message)")
        activityState.lastActivityAt = Date()
    }

    public func retrying(_ tag: String, note: String, waitMs: UInt64) {
        append(tag: tag, level: "RETRY", message: "\(note) in \(waitMs)ms")
        activityState.retryNote = Self.sanitize(note)
        activityState.retryAt = Date().addingTimeInterval(Double(waitMs) / 1000.0)
        activityState.lastActivityAt = Date()
    }

    public func clearRetry() {
        activityState.retryNote = nil
        activityState.retryAt = nil
    }

    public func recordRequest(provider: String, method: String, path: String, statusCode: Int?, durationMs: UInt64, error: String? = nil) {
        activityState.requests += 1
        let now = Date()
        activityState.lastActivityAt = now
        if let err = error {
            let msg = "\(method) \(path) -> FAIL \(durationMs)ms \(err)"
            append(tag: provider, level: "ERR", message: msg)
            activityState.lastError = Self.sanitize("\(provider) \(method) \(path)：\(err)")
        } else {
            let code = statusCode ?? 0
            let msg = "\(method) \(path) -> \(code) \(durationMs)ms"
            append(tag: provider, level: "INFO", message: msg)
            activityState.last = Self.sanitize("\(provider) \(method) \(path) → \(code) · \(durationMs)ms")
        }
    }

    private func append(tag: String, level: String, message: String) {
        let now = Date()
        let safe = Self.sanitize(message)
        entries.append(Entry(timestamp: now, tag: tag, level: level, message: safe))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        let formatted = "[\(Self.formatTime(now))] [\(level)] [\(tag)] \(safe)"
        ringLines.append(formatted)
        if ringLines.count > maxEntries {
            ringLines.removeFirst(ringLines.count - maxEntries)
        }
        if fileEnabled {
            appendToDisk(formatted + "\n")
        }
    }

    private func appendToDisk(_ line: String) {
        let fm = FileManager.default
        let file = logFileURL()
        do {
            try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: file.path),
               let attrs = try? fm.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? UInt64,
               size > maxDiskBytes {
                let rotated = rotatedLogFileURL()
                try? fm.removeItem(at: rotated)
                if (try? fm.moveItem(at: file, to: rotated)) == nil {
                    try Data().write(to: file, options: .atomic)
                }
            }
            let data = Data(line.utf8)
            if fm.fileExists(atPath: file.path), let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file, options: .atomic)
            }
        } catch {
            // 日志落盘失败不影响主业务
        }
    }

    private nonisolated static func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MM-dd HH:mm:ss.SSS"
        return fmt.string(from: date)
    }

    public func snapshot() -> [Entry] { entries }

    public func recent() -> [String] { ringLines }

    public func clear() {
        entries.removeAll()
        ringLines.removeAll()
        try? FileManager.default.removeItem(at: logFileURL())
        try? FileManager.default.removeItem(at: rotatedLogFileURL())
    }

    public func exportText() -> String {
        ringLines.joined(separator: "\n")
    }

    /// 导出完整诊断日志（设备头 + 滚动文件日志或内存环形缓冲 + 最近崩溃报告，全文二次脱敏）。
    public func exportTo(fileUrl: URL, header: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: fileUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
        var parts: [String] = [header, ""]
        let cur = logFileURL()
        let old = rotatedLogFileURL()
        if fileEnabled && fm.fileExists(atPath: cur.path) {
            if let oldTxt = try? String(contentsOf: old, encoding: .utf8), !oldTxt.isEmpty {
                parts.append(oldTxt)
            }
            if let curTxt = try? String(contentsOf: cur, encoding: .utf8), !curTxt.isEmpty {
                parts.append(curTxt)
            }
        } else {
            parts.append("（调试日志文件未开启，以下为内存中最近 \(ringLines.count) 条）")
            parts.append(ringLines.joined(separator: "\n"))
        }
        if let crash = CrashReporter.readReport(), !crash.isEmpty {
            parts.append("\n===== 最近的崩溃报告 =====\n\(crash)")
        }
        let sanitized = Self.sanitize(parts.joined(separator: "\n"))
        try AtomicFileIO.writeText(sanitized, to: fileUrl)
        return fileUrl
    }
}
