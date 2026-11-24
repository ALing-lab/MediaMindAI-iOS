import Foundation
import CryptoKit

/// 1:1 复刻自 Android `TmdbNet.kt`：
/// TMDB 网络配置（API/图片地址规范化、禁止明文 http API 拦截、官方 CDN + 自定义镜像 + 公共镜像自动回退、图片魔数校验防劫持）。
public struct TmdbNetConfig: Codable, Hashable, Sendable {
    public static let defaultApi = "https://api.themoviedb.org/3"
    public static let altApi = "https://api.tmdb.org/3"
    public static let defaultImage = "https://image.tmdb.org"
    public static let mediaImage = "https://media.themoviedb.org"
    public static let publicMirrors = ["https://img.amodb.dev", "https://wsrv.nl/?url="]

    public var apiBase: String
    public var imageBase: String
    public var imageFallback: String
    public var publicMirrors: Bool
    public var proxyType: String // "none" | "http" | "socks"
    public var proxyHost: String
    public var proxyPort: Int

    public init(
        apiBase: String = TmdbNetConfig.altApi,
        imageBase: String = TmdbNetConfig.defaultImage,
        imageFallback: String = "",
        publicMirrors: Bool = false,
        proxyType: String = "none",
        proxyHost: String = "",
        proxyPort: Int = 0
    ) {
        self.apiBase = apiBase
        self.imageBase = imageBase
        self.imageFallback = imageFallback
        self.publicMirrors = publicMirrors
        self.proxyType = proxyType
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
    }

    /// 规范化：去掉末尾斜杠；API 地址缺 `/3` 时自动补 `/3`；图片基地址剥离末尾 `/t/p`。
    public func normalized() -> TmdbNetConfig {
        var a = apiBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if a.isEmpty { a = Self.defaultApi }
        if !a.lowercased().hasPrefix("http://") && !a.lowercased().hasPrefix("https://") { a = "https://\(a)" }
        if !a.hasSuffix("/3") { a += "/3" }

        var i = imageBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if i.isEmpty { i = Self.defaultImage }
        if !i.lowercased().hasPrefix("http://") && !i.lowercased().hasPrefix("https://") { i = "https://\(i)" }
        if i.hasSuffix("/t/p") { i = String(i.dropLast(4)) }

        var f = imageFallback.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if f.hasSuffix("/t/p") { f = String(f.dropLast(4)) }
        if !f.isEmpty && !f.lowercased().hasPrefix("http://") && !f.lowercased().hasPrefix("https://") { f = "https://\(f)" }

        return TmdbNetConfig(
            apiBase: a,
            imageBase: i,
            imageFallback: f,
            publicMirrors: publicMirrors,
            proxyType: proxyType,
            proxyHost: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
            proxyPort: proxyPort
        )
    }

    /// 明文 `http://` TMDB API 地址安全拦截（本机回环 localhost/127.*/::1 除外）。
    public func apiHttpProblem() -> String? {
        let a = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a.lowercased().hasPrefix("http://") else { return nil }
        let host = URL(string: a)?.host?.lowercased() ?? ""
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return nil }
        return "TMDB API 地址不能使用 http://（密钥会以明文发送），请改用 https:// 地址"
    }
}

/// 1:1 复刻自 Android `TmdbRequestPacer.kt`：
/// 统一控制真实 TMDB HTTP 尝试节流（API 80ms、图片 50ms），并在收到 HTTP 429 时解析 `Retry-After`（秒数或 RFC 1123 日期）全局冷却。
public actor TmdbRequestPacer {
    public static let shared = TmdbRequestPacer()

    private var apiNextMs: UInt64 = 0
    private var imageNextMs: UInt64 = 0
    private var cooldownUntilMs: UInt64 = 0

    public static let apiIntervalMs: UInt64 = 80
    public static let imageIntervalMs: UInt64 = 50

    public init() {}

    public func acquire(isImage: Bool) async throws {
        while true {
            try Task.checkCancellation()
            let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
            let nextSlot = isImage ? imageNextMs : apiNextMs
            let gate = max(nextSlot, cooldownUntilMs)
            if gate <= nowMs {
                if isImage {
                    imageNextMs = nowMs + Self.imageIntervalMs
                } else {
                    apiNextMs = nowMs + Self.apiIntervalMs
                }
                return
            }
            let waitMs = min(gate - nowMs, 1_000)
            try await Task.sleep(nanoseconds: waitMs * 1_000_000)
        }
    }

    public func record429(retryAfter: String?, now: Date = Date()) {
        let delayMs = Self.retryDelayMs(header: retryAfter, now: now)
        let nowMono = DispatchTime.now().uptimeNanoseconds / 1_000_000
        cooldownUntilMs = max(cooldownUntilMs, nowMono + delayMs)
    }

    public func reset() {
        apiNextMs = 0
        imageNextMs = 0
        cooldownUntilMs = 0
    }

    /// 解析 HTTP `Retry-After`（整数秒或 RFC 1123 日期），区间钳制在 `[1s, 3600s]`，缺省 30s。
    public nonisolated static func retryDelayMs(header value: String?, now: Date = Date()) -> UInt64 {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return 30_000
        }
        if let seconds = Int64(trimmed) {
            let clamped = min(max(seconds, 1), 3600)
            return UInt64(clamped) * 1_000
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let target = df.date(from: trimmed) {
            let diffMs = Int64(target.timeIntervalSince(now) * 1000)
            let clamped = min(max(diffMs, 1_000), 3_600_000)
            return UInt64(clamped)
        }
        return 30_000
    }
}

public actor TmdbNet {
    public static let shared = TmdbNet()

    public private(set) var config: TmdbNetConfig = TmdbNetConfig()
    public private(set) var apiBaseRejection: String?
    public private(set) var preferredImageBase: String?
    public var tryOfficialImage = true

    private var cachedProxyKey: String?
    private var cachedProxySession: URLSession?

    public func apply(_ c: TmdbNetConfig) async {
        let n = c.normalized()
        if n.imageBase != config.imageBase || n.imageFallback != config.imageFallback || n.proxyType != config.proxyType || n.proxyHost != config.proxyHost || n.proxyPort != config.proxyPort {
            preferredImageBase = nil
        }
        if let problem = n.apiHttpProblem() {
            apiBaseRejection = problem
            var safe = n
            safe.apiBase = TmdbNetConfig.altApi
            config = safe
            await NetLog.shared.error("TMDB", "\(problem)（已改用默认地址 \(TmdbNetConfig.altApi)）")
        } else {
            apiBaseRejection = nil
            config = n
        }
    }

    public func setPreferredImageBase(_ base: String?) {
        preferredImageBase = base
    }

    /// 把默认的 `image.tmdb.org` 换成当前设置里的图片基地址。
    public func imageUrl(_ url: String, config overrideCfg: TmdbNetConfig? = nil) -> String {
        let base = (overrideCfg ?? config).imageBase
        if base != TmdbNetConfig.defaultImage && url.hasPrefix(TmdbNetConfig.defaultImage) {
            return base + String(url.dropFirst(TmdbNetConfig.defaultImage.count))
        }
        return url
    }

    public func describe(_ overrideCfg: TmdbNetConfig? = nil) -> String {
        let c = overrideCfg ?? config
        var out = c.apiBase
        if out.hasPrefix("https://") { out = String(out.dropFirst(8)) }
        if out.hasSuffix("/3") { out = String(out.dropLast(2)) }
        if c.proxyType != "none" && !c.proxyHost.isEmpty {
            out += " · \(c.proxyType.uppercased()) 代理"
        }
        if c == config, apiBaseRejection != nil {
            out += " · 已拦截 http API 地址，请改用 https"
        }
        return out
    }

    /// 构造支持可选 HTTP / SOCKS 代理的 URLSession（未配置代理时复用 `.shared`）。
    public func session(for cfg: TmdbNetConfig? = nil) -> URLSession {
        let c = (cfg ?? config).normalized()
        let pType = c.proxyType.lowercased()
        guard (pType == "http" || pType == "socks"), !c.proxyHost.isEmpty, (1...65535).contains(c.proxyPort) else {
            if let old = cachedProxySession {
                Task.detached { try? await Task.sleep(nanoseconds: 5_000_000_000); old.finishTasksAndInvalidate() }
            }
            cachedProxySession = nil
            cachedProxyKey = nil
            return .shared
        }
        let key = "\(c.proxyType.lowercased())|\(c.proxyHost)|\(c.proxyPort)"
        if let existing = cachedProxySession, cachedProxyKey == key {
            return existing
        }
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = 30
        conf.timeoutIntervalForResource = 90
        var proxyDict: [AnyHashable: Any] = [:]
        if c.proxyType.lowercased() == "http" {
            proxyDict["HTTPEnable"] = 1
            proxyDict["HTTPProxy"] = c.proxyHost
            proxyDict["HTTPPort"] = c.proxyPort
            proxyDict["HTTPSEnable"] = 1
            proxyDict["HTTPSProxy"] = c.proxyHost
            proxyDict["HTTPSPort"] = c.proxyPort
        } else if c.proxyType.lowercased() == "socks" {
            proxyDict["SOCKSEnable"] = 1
            proxyDict["SOCKSProxy"] = c.proxyHost
            proxyDict["SOCKSPort"] = c.proxyPort
        }
        conf.connectionProxyDictionary = proxyDict
        let built = URLSession(configuration: conf)
        if let old = cachedProxySession {
            Task.detached { try? await Task.sleep(nanoseconds: 5_000_000_000); old.finishTasksAndInvalidate() }
        }
        cachedProxySession = built
        cachedProxyKey = key
        return built
    }

    /// 校验字节流头部是否为真实图片魔数（JPEG / PNG / WebP / GIF），防止运营商或反代劫持返回 HTML 页面。
    public nonisolated static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true } // JPEG
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true } // PNG
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return true } // GIF
        if b.count >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true } // WebP
        return false
    }

    private func imageBases(_ c: TmdbNetConfig) -> [String] {
        var bases: [String] = [c.imageBase]
        if tryOfficialImage {
            bases.append(TmdbNetConfig.defaultImage)
            bases.append(TmdbNetConfig.mediaImage)
        }
        if !c.imageFallback.isEmpty { bases.append(c.imageFallback) }
        if c.publicMirrors && tryOfficialImage { bases.append(contentsOf: TmdbNetConfig.publicMirrors) }
        return bases
    }

    private func baseOf(config c: TmdbNetConfig, url: URL) -> String? {
        guard let uHost = url.host?.lowercased() else { return nil }
        let uPort = url.port ?? ((url.scheme?.lowercased() == "https") ? 443 : 80)
        let pool = imageBases(c) + [TmdbNetConfig.defaultImage, TmdbNetConfig.mediaImage] + TmdbNetConfig.publicMirrors
        var seen = Set<String>()
        for b in pool where !b.isEmpty && seen.insert(b).inserted {
            if let bu = URL(string: b), let bh = bu.host?.lowercased() {
                let bp = bu.port ?? ((bu.scheme?.lowercased() == "https") ? 443 : 80)
                if bh == uHost && bp == uPort { return b }
            }
        }
        return nil
    }

    public func isImageHost(_ url: URL) -> Bool {
        baseOf(config: config, url: url) != nil
    }

    /// 生成图片多路回退候选 URL：上次最快可用基地址 → 主地址 → 官方 image.tmdb.org → 官网 CDN media.themoviedb.org → 自定义备用 → 公共镜像。
    public func imageCandidates(for urlStr: String, config c: TmdbNetConfig) -> [URL] {
        guard let origUrl = URL(string: urlStr) else { return [] }
        let fullPath = origUrl.path
        guard let range = fullPath.range(of: "/t/p/") else { return [origUrl] }
        let tpPath = String(fullPath[range.lowerBound...])
        let official = TmdbNetConfig.defaultImage + tpPath

        var distinctBases: [String] = []
        for b in imageBases(c) where !b.isEmpty && !distinctBases.contains(b) {
            distinctBases.append(b)
        }
        if let pref = preferredImageBase, let idx = distinctBases.firstIndex(of: pref), idx > 0 {
            distinctBases.remove(at: idx)
            distinctBases.insert(pref, at: 0)
        }

        var out: [URL] = []
        for b in distinctBases {
            let built: String
            if b.contains("{url}") {
                built = b.replacingOccurrences(of: "{url}", with: official)
            } else if b.hasSuffix("=") {
                built = b + official
            } else {
                built = b.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + tpPath
            }
            if let u = URL(string: built), !out.contains(u) {
                out.append(u)
            }
        }
        return out
    }

    /// 依次尝试多个图片镜像源，经 `TmdbRequestPacer` 限频，附带 Referer（media.themoviedb.org 必需）并做魔数防劫持校验。
    public func downloadImageWithFallback(urlStr: String, config c: TmdbNetConfig, session customSession: URLSession? = nil) async throws -> Data {
        let candidates = imageCandidates(for: urlStr, config: c)
        guard !candidates.isEmpty else { throw DriveError.invalidInput("无效的图片 URL") }

        var lastErr: Error?
        var lastHostList: [String] = []
        for (idx, url) in candidates.enumerated() {
            let host = url.host ?? url.absoluteString
            lastHostList.append(host)
            if idx > 0 {
                let prevHost = candidates[idx - 1].host ?? ""
                await NetLog.shared.line("TMDB", "图片地址 \(prevHost) 不可用，改用 \(host)")
            }
            try await TmdbRequestPacer.shared.acquire(isImage: true)
            let activeSession = customSession ?? session(for: c)
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            if host.lowercased() == "media.themoviedb.org" {
                req.setValue("https://www.themoviedb.org/", forHTTPHeaderField: "Referer")
            }
            do {
                let (data, resp) = try await activeSession.data(for: req)
                let httpResp = resp as? HTTPURLResponse
                let code = httpResp?.statusCode ?? 0
                if code == 429 {
                    await TmdbRequestPacer.shared.record429(retryAfter: httpResp?.value(forHTTPHeaderField: "Retry-After"))
                }
                let rawType = httpResp?.value(forHTTPHeaderField: "Content-Type") ?? ""
                let mime = rawType.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                let isImg = mime.hasPrefix("image/") || Self.looksLikeImage(data)
                if (200...299).contains(code) && !data.isEmpty && isImg {
                    if let matchedBase = baseOf(config: c, url: url) {
                        preferredImageBase = matchedBase
                    }
                    return data
                }
                await NetLog.shared.error("TMDB", "图片 \(host) 返回 HTTP \(code) \(mime)")
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw CancellationError()
            } catch {
                await NetLog.shared.error("TMDB", "图片 \(host) 连接失败：\(error.localizedDescription)")
                lastErr = error
            }
        }
        let tried = lastHostList.joined(separator: "、")
        let detail = lastErr.map { "；最后的错误：\($0.localizedDescription)" } ?? ""
        throw DriveError.api(code: -2, message: "所有图片地址都连不上（试过 \(tried)）。请在「设置 › TMDB 网络」里配置代理，或填一个能访问的图片镜像\(detail)")
    }
}


/// TMDB 预览海报异步加载器（1:1 对标 Android `TmdbImage.kt` 底层通道，位于 MediaMindCore 供 UI 与单测共用）：
/// 统一经由 `TmdbNet.downloadImageWithFallback` 下载（自动应用代理、自定义镜像、公共镜像回退与防劫持魔数校验），
/// 并提供有界内存 LRU、磁盘缓存（复用 `AppDirs.imgCacheDir`）及支持取消传播的 Singleflight 去重。
public actor TmdbImageLoader {
    public static let shared = TmdbImageLoader()

    private static let maxMemEntries = 128
    private static let maxDiskAgeSec: TimeInterval = 14 * 86_400

    private var mem: [String: (data: Data, access: UInt64)] = [:]
    private var accessCounter: UInt64 = 0
    private var inFlight: [String: (token: UUID, task: Task<Data?, Never>, waiters: Set<UUID>)] = [:]
    private let cacheDir: URL

    public init(cacheDir: URL? = nil) {
        self.cacheDir = cacheDir ?? AppDirs.imgCacheDir
    }

    public nonisolated static func cacheKey(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func cachedData(for urlString: String) -> Data? {
        let key = Self.cacheKey(for: urlString)
        if var hit = mem[key] {
            accessCounter &+= 1
            hit.access = accessCounter
            mem[key] = hit
            return hit.data
        }
        let file = cacheDir.appendingPathComponent("thumb_\(key).img")
        if let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970,
           Date().timeIntervalSince1970 - mtime > Self.maxDiskAgeSec {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        guard let data = try? Data(contentsOf: file), TmdbNet.looksLikeImage(data) else {
            return nil
        }
        putMem(key: key, data: data)
        return data
    }

    public func store(data: Data, for urlString: String) {
        guard TmdbNet.looksLikeImage(data) else { return }
        let key = Self.cacheKey(for: urlString)
        putMem(key: key, data: data)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = cacheDir.appendingPathComponent("thumb_\(key).img")
        try? data.write(to: file, options: .atomic)
    }

    public func load(urlString: String, bypassCache: Bool = false) async -> Data? {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let key = Self.cacheKey(for: clean)

        if !bypassCache, let cached = cachedData(for: clean) {
            return cached
        }
        let waiterId = UUID()
        if !bypassCache, var existing = inFlight[key] {
            existing.waiters.insert(waiterId)
            inFlight[key] = existing
            let tok = existing.token
            let sharedTask = existing.task
            let result: Data? = await withTaskCancellationHandler {
                await sharedTask.value
            } onCancel: {
                Task { await self.releaseWaiter(key: key, token: tok, waiterId: waiterId) }
            }
            releaseWaiter(key: key, token: tok, waiterId: waiterId)
            return result
        }
        if bypassCache, let old = inFlight.removeValue(forKey: key) {
            old.task.cancel()
        }

        let cfg = AppSettings.shared.tmdbNetConfig
        let task = Task<Data?, Never> {
            do {
                try Task.checkCancellation()
                let bytes = try await TmdbNet.shared.downloadImageWithFallback(urlStr: clean, config: cfg)
                try Task.checkCancellation()
                guard TmdbNet.looksLikeImage(bytes) else { return nil }
                await self.store(data: bytes, for: clean)
                return bytes
            } catch is CancellationError {
                return nil
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                return nil
            } catch {
                let hostPath = URL(string: clean).map { "\($0.host ?? "")\($0.path)" } ?? clean
                await NetLog.shared.error("TMDB", "缩略图加载失败 \(hostPath)：\(error.localizedDescription)")
                return nil
            }
        }
        let token = UUID()
        inFlight[key] = (token, task, [waiterId])
        let result: Data? = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.releaseWaiter(key: key, token: token, waiterId: waiterId) }
        }
        releaseWaiter(key: key, token: token, waiterId: waiterId)
        return result
    }

    private func releaseWaiter(key: String, token: UUID, waiterId: UUID) {
        guard var entry = inFlight[key], entry.token == token else { return }
        entry.waiters.remove(waiterId)
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }

    public func clearMemoryCache() {
        mem.removeAll()
    }

    public func clearCache() {
        for (_, entry) in inFlight {
            entry.task.cancel()
        }
        inFlight.removeAll()
        mem.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("thumb_") {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private func putMem(key: String, data: Data) {
        accessCounter &+= 1
        mem[key] = (data, accessCounter)
        if mem.count > Self.maxMemEntries {
            if let oldest = mem.min(by: { $0.value.access < $1.value.access })?.key {
                mem.removeValue(forKey: oldest)
            }
        }
    }
}
