import Foundation

/// 分网盘乐观高速 + 命中即退（AIMD）频控画像（完整移植自 Android v0.5.68–v0.5.78）。
public enum DriveRateProfile: String, Sendable {
    case standard
    case lanWebDav
    case remoteWebDav
    case pan123
    case guangya

    public var minIntervalMs: UInt64 {
        switch self {
        case .standard: return 100
        case .lanWebDav: return 10
        case .remoteWebDav: return 70
        case .pan123: return 60
        case .guangya: return 80
        }
    }

    public var defaultIntervalMs: UInt64 {
        switch self {
        case .standard: return 350
        case .lanWebDav: return 20
        case .remoteWebDav: return 140
        case .pan123: return 120
        case .guangya: return 150
        }
    }

    public var slowThresholdMs: UInt64 { self == .lanWebDav ? 800 : 1500 }

    public var penaltyBaseMs: UInt64 {
        switch self {
        case .standard: return 1500
        case .lanWebDav: return 400
        case .remoteWebDav, .pan123: return 1800
        case .guangya: return 2000
        }
    }

    public var maxPenaltyMs: UInt64 {
        switch self {
        case .standard: return 15_000
        case .lanWebDav: return 4_000
        case .remoteWebDav, .pan123: return 18_000
        case .guangya: return 20_000
        }
    }

    public var healthyThreshold: Int {
        switch self {
        case .standard: return 8
        case .lanWebDav: return 4
        case .remoteWebDav, .pan123, .guangya: return 6
        }
    }

    public var maxConcurrentReads: Int {
        switch self {
        case .standard: return 3
        case .lanWebDav: return 8
        case .pan123: return 5
        case .remoteWebDav, .guangya: return 4
        }
    }

    public var jitterMaxMs: UInt64 {
        switch self {
        case .standard, .lanWebDav: return 0
        case .pan123: return 20
        case .remoteWebDav, .guangya: return 25
        }
    }

    public var writeConcurrencyLevels: [Int] {
        switch self {
        case .standard: return [6, 3, 1]
        case .lanWebDav: return [10, 6, 3]
        case .pan123: return [6, 4, 2, 1]
        case .remoteWebDav, .guangya: return [6, 3, 2, 1]
        }
    }

    public static func forDrive(_ drive: any CloudDrive) -> DriveRateProfile {
        switch drive.kind {
        case .p123: return .pan123
        case .guangya: return .guangya
        case .webdav: return drive.isLanEndpoint ? .lanWebDav : .remoteWebDav
        }
    }

    /// 判断主机名/IP 是否属于局域网或本机回环地址（RFC 1918 / Loopback / Link-local / IPv6 ULA）。
    public static func isLanHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") {
            return true
        }
        if host.contains(":"), host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            return true
        }
        let parts = host.split(separator: ".")
        if parts.count == 4 {
            let nums = parts.compactMap { Int($0) }
            guard nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) else { return false }
            let (a, b) = (nums[0], nums[1])
            return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) || (a == 169 && b == 254)
        }
        return false
    }
}

/// 统一风控/限流错误识别（词边界匹配，避免把 movie_4290.mkv / ep_405.mkv 误判为限流）。
public enum RateLimitDetector {
    private static let guangyaRateLimitCodes: Set<Int> = [429]
    private static let codeRegex = try! NSRegularExpression(
        pattern: #"\b(?:http\s*429|status\s*[=:]\s*429|code\s*[=:]\s*429)\b"#,
        options: [.caseInsensitive]
    )
    private static let keywords = [
        "too many requests", "too many", "rate limit", "ratelimit",
        "throttle", "qps", "too quickly", "too fast",
        "限流", "频控", "风控", "访问上限", "已达到", "太频繁", "过于频繁", "请求频繁", "操作频繁", "稍后再试", "稍后重试", "滑块", "captcha"
    ]

    public static func isRateLimitError(_ error: Error?) -> Bool {
        guard let error else { return false }
        if case DriveError.rateLimited = error {
            return true
        }
        if case let DriveError.api(code, _) = error, guangyaRateLimitCodes.contains(code) {
            return true
        }
        let msg = error.localizedDescription.lowercased()
        guard !msg.isEmpty else { return false }
        let range = NSRange(msg.startIndex..<msg.endIndex, in: msg)
        if codeRegex.firstMatch(in: msg, range: range) != nil { return true }
        return keywords.contains { msg.contains($0) }
    }
}

/// 乐观全速起跑 + 命中真实风控后学习安全下限（AIMD）的自适应读频控器。
public actor AdaptiveReadRate {
    public let profile: DriveRateProfile
    private var latency: Double = 0
    private var penalty: UInt64 = 0
    private var learnedFloorMs: UInt64 = 0
    private var healthy: Int = 0

    public init(profile: DriveRateProfile = .standard) {
        self.profile = profile
    }

    public func interval() -> UInt64 {
        let network: UInt64
        if latency == 0 {
            network = profile.defaultIntervalMs
        } else if latency < 250 {
            network = profile.minIntervalMs
        } else if latency < Double(profile.slowThresholdMs) {
            network = profile.defaultIntervalMs
        } else {
            network = max(profile.slowThresholdMs, UInt64(latency * 0.3))
        }
        return min(max(network, max(penalty, learnedFloorMs)), profile.maxPenaltyMs)
    }

    public func nextDelayWithJitter() -> UInt64 {
        let base = interval()
        guard profile.jitterMaxMs > 0 else { return base }
        let jitter = UInt64.random(in: 0...profile.jitterMaxMs)
        return min(base + jitter, profile.maxPenaltyMs)
    }

    public func feedback(durationMs: UInt64, throttled: Bool, success: Bool) {
        let sample = Double(max(durationMs, 1))
        latency = latency == 0 ? sample : (latency * 0.8 + sample * 0.2)
        if throttled {
            let doubled = penalty == 0 ? profile.penaltyBaseMs : penalty * 2
            penalty = min(max(profile.penaltyBaseMs, doubled), profile.maxPenaltyMs)
            if profile != .standard && profile != .lanWebDav {
                learnedFloorMs = min(max(learnedFloorMs + 80, profile.defaultIntervalMs * 2), 1_000)
            }
            healthy = 0
        } else if success {
            healthy += 1
            if healthy >= profile.healthyThreshold {
                let decayed = UInt64(Double(penalty) * 0.7)
                penalty = decayed >= profile.defaultIntervalMs ? decayed : 0
                healthy = 0
            }
        } else {
            healthy = 0
            penalty = max(penalty, min(max(profile.defaultIntervalMs * 2, 700), profile.maxPenaltyMs))
        }
    }
}

/// 异步信号量（Swift Concurrency 原生实现，避免阻塞线程）。
public actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        self.value = max(1, value)
    }

    public func acquire() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    public func release() {
        if let first = waiters.first {
            waiters.removeFirst()
            first.resume()
        } else {
            value += 1
        }
    }
}

/// 网盘读限速包装器（对标 Android PacedDrive + DrivePacer：自动模式走 AIMD，手动模式尊重用户选定的扫描档位）。
public final class PacedDrive: CloudDrive, @unchecked Sendable {
    private let delegate: any CloudDrive
    public let profile: DriveRateProfile
    private let rate: AdaptiveReadRate
    private let semaphore: AsyncSemaphore
    private let serialGate = AsyncSemaphore(value: 1)
    private let slotCoordinator = SlotCoordinator()

    private actor SlotCoordinator {
        private var nextAllowedUptimeNs: UInt64 = 0
        func reserveWaitNs(delayMs: UInt64) -> UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            let target = max(now, nextAllowedUptimeNs)
            nextAllowedUptimeNs = target &+ (delayMs * 1_000_000)
            return target > now ? (target - now) : 0
        }
    }

    private let explicitBinding: String?

    public init(delegate: any CloudDrive, approvalBinding: String? = nil) {
        self.delegate = delegate
        self.explicitBinding = approvalBinding
        let p = DriveRateProfile.forDrive(delegate)
        self.profile = p
        self.rate = AdaptiveReadRate(profile: p)
        self.semaphore = AsyncSemaphore(value: p.maxConcurrentReads)
    }

    public var kind: ProviderKind { delegate.kind }
    public var accountId: String { delegate.accountId }
    public var approvalBinding: String { explicitBinding ?? delegate.approvalBinding }
    public var rootId: String { delegate.rootId }
    public var writeIntervalMs: UInt64 { delegate.writeIntervalMs }
    public var isLanEndpoint: Bool { delegate.isLanEndpoint }
    public var trashSupport: TrashSupport { delegate.trashSupport }

    private func pacedRead<T>(_ op: () async throws -> T) async throws -> T {
        let isAuto = AppSettings.shared.scanAutomatic
        let delayMs: UInt64
        if isAuto {
            delayMs = await rate.nextDelayWithJitter()
        } else {
            delayMs = AppSettings.shared.scanSpeed.intervalMs
        }
        let activeSem = delayMs >= 1000 ? serialGate : semaphore
        await activeSem.acquire()
        defer { Task { await activeSem.release() } }

        let waitNs = await slotCoordinator.reserveWaitNs(delayMs: delayMs)
        if waitNs > 0 { try await Task.sleep(nanoseconds: waitNs) }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try await op()
            if isAuto {
                let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                await rate.feedback(durationMs: elapsedMs, throttled: false, success: true)
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isAuto {
                let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                await rate.feedback(durationMs: elapsedMs, throttled: RateLimitDetector.isRateLimitError(error), success: false)
            }
            throw error
        }
    }

    private func validateBinding() async throws {
        let expected = approvalBinding
        guard !expected.isEmpty else { return }
        let acct = await MainActor.run { AccountStore.shared.get(id: accountId) }
        guard let acct else {
            throw DriveError.unauthorized("网盘账号已被删除，已停止继续操作")
        }
        let secret = KeychainStore.loadAccountSecret(accountId: acct.id) ?? ""
        try AccountBinding.requireUnchanged(account: acct, secret: secret, expected: expected)
    }

    public func list(folderId: String) async throws -> [CloudEntry] {
        try await validateBinding()
        return try await pacedRead { try await delegate.list(folderId: folderId) }
    }

    public func rename(fileId: String, newName: String) async throws -> String {
        try await validateBinding()
        return try await delegate.rename(fileId: fileId, newName: newName)
    }

    public func mkdir(parentId: String, name: String) async throws -> String {
        try await validateBinding()
        return try await delegate.mkdir(parentId: parentId, name: name)
    }

    public func move(fileId: String, destParentId: String) async throws -> String {
        try await validateBinding()
        return try await delegate.move(fileId: fileId, destParentId: destParentId)
    }

    public func moveBatch(fileIds: [String], destParentId: String) async throws -> [String: String] {
        try await validateBinding()
        return try await delegate.moveBatch(fileIds: fileIds, destParentId: destParentId)
    }

    public func upload(parentId: String, name: String, data: Data) async throws -> String {
        try await validateBinding()
        return try await delegate.upload(parentId: parentId, name: name, data: data)
    }

    public func trash(fileId: String) async throws -> String {
        try await validateBinding()
        return try await delegate.trash(fileId: fileId)
    }

    public func parentIdOf(fileId: String) async throws -> String? {
        try await validateBinding()
        return try await pacedRead { try await delegate.parentIdOf(fileId: fileId) }
    }

    public func exists(parentId: String, name: String) async throws -> Bool {
        try await validateBinding()
        return try await pacedRead { try await delegate.exists(parentId: parentId, name: name) }
    }

    public func ping() async -> Bool {
        await delegate.ping()
    }
}
