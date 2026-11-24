import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// iOS 后台保活管理器（对标 Android ExecForegroundService：切后台跑大批量整理时向系统申请后台执行配额）。
@MainActor
public final class BackgroundTaskManager {
    public static let shared = BackgroundTaskManager()

    #if canImport(UIKit)
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {}

    public func begin(name: String = "MediaMindExecution") {
        #if canImport(UIKit)
        guard bgTaskId == .invalid else { return }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
        #endif
    }

    public func end() {
        #if canImport(UIKit)
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
        #endif
    }
}

/// 1:1 对标 Android `CrashReporter.kt`：捕获未处理异常并落盘到本地诊断文件，下次启动可在设置页查看并复制反馈。
public enum CrashReporter {
    private static var crashFileUrl: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("MediaMindAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("last_crash.txt")
    }

    public static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let header = "=== MediaMind AI iOS Crash Report ===\nTime: \(Date())\nName: \(exception.name.rawValue)\nReason: \(exception.reason ?? "unknown")\n\nStack:\n"
            let body = header + exception.callStackSymbols.joined(separator: "\n")
            try? body.write(to: CrashReporter.crashFileUrl, atomically: true, encoding: .utf8)
        }
    }

    public static func recordNonFatal(tag: String, error: Error) {
        let line = "[\(Date())] [\(tag)] \(error.localizedDescription)\n"
        if let existing = try? String(contentsOf: crashFileUrl, encoding: .utf8) {
            let trimmed = String(existing.suffix(16_000))
            try? (trimmed + line).write(to: crashFileUrl, atomically: true, encoding: .utf8)
        } else {
            try? line.write(to: crashFileUrl, atomically: true, encoding: .utf8)
        }
    }

    public static func readReport() -> String? {
        guard let txt = try? String(contentsOf: crashFileUrl, encoding: .utf8), !txt.isEmpty else { return nil }
        return txt
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: crashFileUrl)
    }
}

/// 1:1 复刻自 Android `HostMatch.kt`：严格域名与子域名后缀匹配，避免子串误判。
public enum HostMatch {
    public static func isOrSubdomainOf(host: String?, domain: String) -> Bool {
        guard let rawHost = host?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let h = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let d = domain.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !h.isEmpty, !d.isEmpty else { return false }
        return h == d || h.hasSuffix(".\(d)")
    }

    public static func matchesAny(host: String?, domains: [String]) -> Bool {
        domains.contains { isOrSubdomainOf(host: host, domain: $0) }
    }
}

/// 1:1 复刻自 Android `AppDirs.kt`：统一管理缓存与数据目录并统计各分类磁盘占用。
public enum AppDirs {
    public struct Usage: Equatable, Sendable {
        public let tmdbCache: Int64
        public let imgCache: Int64
        public let plans: Int64
        public let logs: Int64
        public let history: Int64
        public var total: Int64 { tmdbCache + imgCache + plans + logs + history }
    }

    public static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MediaMindAI", isDirectory: true)
    }

    public static var cachesRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public static var tmdbCacheDir: URL { cachesRoot.appendingPathComponent("tmdb", isDirectory: true) }
    public static var imgCacheDir: URL { cachesRoot.appendingPathComponent("MediaMindAI/img_cache", isDirectory: true) }
    public static var plansDir: URL { supportRoot.appendingPathComponent("plans", isDirectory: true) }
    public static var logsDir: URL { supportRoot.appendingPathComponent("logs", isDirectory: true) }
    public static var historyDir: URL { supportRoot.appendingPathComponent("history", isDirectory: true) }

    public static func directorySize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true else { continue }
            total += Int64(vals.fileSize ?? 0)
        }
        return total
    }

    public static func usage() -> Usage {
        Usage(
            tmdbCache: directorySize(tmdbCacheDir),
            imgCache: directorySize(imgCacheDir),
            plans: directorySize(plansDir),
            logs: directorySize(logsDir),
            history: directorySize(historyDir)
        )
    }

    public static func sizeBytes() -> Int64 {
        usage().total
    }

    public static func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }
}
