import Foundation
import CryptoKit

public struct MatchInfo: Codable, Hashable, Sendable {
    public let kind: String // "movie" | "tv"
    public let id: Int
    public let title: String
    public let originalTitle: String?
    public let year: String
    public let posterPath: String?
    public let backdropPath: String?
    public let overview: String
    public let rating: Double?
    public let collectionId: Int?
    public let collectionName: String?
    public let collectionPosterPath: String?
    public let genreIds: [Int]?

    public init(
        kind: String,
        id: Int,
        title: String,
        year: String = "",
        posterPath: String? = nil,
        backdropPath: String? = nil,
        originalTitle: String? = nil,
        overview: String = "",
        rating: Double? = nil,
        collectionId: Int? = nil,
        collectionName: String? = nil,
        collectionPosterPath: String? = nil,
        genreIds: [Int]? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.overview = overview
        self.rating = rating
        self.collectionId = collectionId
        self.collectionName = collectionName
        self.collectionPosterPath = collectionPosterPath
        self.genreIds = genreIds
    }
}

public struct SeasonMeta: Codable, Sendable {
    public let seasonNumber: Int
    public let name: String
    public let airDate: String
    public let overview: String
    public let posterPath: String?
}

public struct EpisodeMeta: Codable, Sendable {
    public let seasonNumber: Int
    public let episodeNumber: Int
    public let name: String
    public let airDate: String
    public let overview: String
    public let stillPath: String?
}

/// TMDB 剧集组概览项（`/tv/{id}/episode_groups`）。
public struct TmdbEpisodeGroupSummary: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: Int
    public let groupCount: Int
    public let episodeCount: Int

    public init(id: String, name: String, type: Int = 0, groupCount: Int = 0, episodeCount: Int = 0) {
        self.id = id
        self.name = name
        self.type = type
        self.groupCount = groupCount
        self.episodeCount = episodeCount
    }
}

/// 1:1 逐行复刻自 Android `TmdbClient.kt`（641 行）：
/// - 二级缓存：1024 条内存 LRU + 7 天磁盘缓存（`Caches/tmdb/<sha1>.json`，每 100 次写入自动裁剪至 600 文件）
/// - Singleflight 在途去重 + 256 条 5 分钟搜索空结果负缓存
/// - `TmdbRequestPacer` 80ms API 节流 + HTTP 429 全局冷却
/// - 自动识别 v4 Bearer Token（含 2 个点）与 v3 `api_key`
/// - 双官方域名自动回退（`api.tmdb.org` ↔ `api.themoviedb.org`）+ 30 秒连接熔断
/// - `scoreMovie` / `scoreTv` 融合评分、`yearCandidates`、`zhTitle` 多地区中文回退、`findByImdbId`/`findByTvdbId`、`episodeFromSeasonBatch`、`collectionParts`/`collectionPoster`、`test`/`testImage`
public actor TmdbClient {
    public static let shared = TmdbClient()

    public static let imageTestPath = "/t/p/w92/9gk7adHYeDvHkCSEqAvQNLV5Uge.jpg"
    private static let cacheDays: TimeInterval = 7 * 86_400
    private static let maxMemCache = 1024
    private static let maxNegCache = 256
    private static let negTtlSeconds: TimeInterval = 5 * 60
    private static let maxDiskCacheFiles = 600

    private static let featuretteRegex = try! NSRegularExpression(
        pattern: #"花絮|幕后|特辑|制作|纪录|featurette|making[ -]?of|behind[ -]the[ -]scenes|visual (?:effects|journey)|assembling|a visual|\bwired\b|\bspecial\b|road to|：.*之路"#,
        options: [.caseInsensitive]
    )
    private static let cjkRegex = try! NSRegularExpression(pattern: #"[\u4e00-\u9fff]"#)

    private struct MemCacheEntry {
        let data: Data
        let diskMtime: TimeInterval
        var lastAccess: UInt64
    }

    private let customSession: URLSession?
    private let cacheDir: URL
    private var memCache: [String: MemCacheEntry] = [:]
    private var accessCounter: UInt64 = 0
    private var negSearchCache: [String: Date] = [:]
    private enum GetOutcome { case ok(Data), notFound, transientError }
    private var inFlight: [String: (UUID, Task<Data?, Error>)] = [:]
    private var diskWrites = 0

    /// 连接失败熔断：30 秒内快速失败，避免每个目录重复等连接超时。
    private var failUntil: Date = .distantPast
    private var failMsg: String?
    /// 官方首选连不上时自动切换到的另一个官方域名。
    private var autoBase: String?

    public init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        self.customSession = session
        if let dir = cacheDirectory {
            self.cacheDir = dir
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDir = caches.appendingPathComponent("tmdb", isDirectory: true)
        }
    }

    // MARK: - 1. 缓存管理与故障熔断重置

    public func resetFailures() {
        failUntil = .distantPast
        failMsg = nil
        autoBase = nil
        negSearchCache.removeAll()
    }

    public func clearCache() {
        memCache.removeAll()
        negSearchCache.removeAll()
        resetFailures()
        try? FileManager.default.removeItem(at: cacheDir)
    }

    public func clearMemoryCache() {
        memCache.removeAll()
        negSearchCache.removeAll()
    }

    private func isNegativeCached(_ key: String) -> Bool {
        guard let ts = negSearchCache[key] else { return false }
        if Date().timeIntervalSince(ts) < Self.negTtlSeconds { return true }
        negSearchCache.removeValue(forKey: key)
        return false
    }

    private func markNegative(_ key: String) {
        if negSearchCache.count >= Self.maxNegCache, let oldest = negSearchCache.min(by: { $0.value < $1.value })?.key {
            negSearchCache.removeValue(forKey: oldest)
        }
        negSearchCache[key] = Date()
    }

    private func cacheFileURL(for cacheKey: String) -> URL {
        let hash = Insecure.SHA1.hash(data: Data(cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hash).json")
    }

    private func putMemCache(key: String, data: Data, diskMtime: TimeInterval) {
        accessCounter &+= 1
        if memCache.count >= Self.maxMemCache, let victim = memCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            memCache.removeValue(forKey: victim)
        }
        memCache[key] = MemCacheEntry(data: data, diskMtime: diskMtime, lastAccess: accessCounter)
    }

    private func pruneDiskCacheIfNeeded() {
        diskWrites += 1
        guard diskWrites % 100 == 0 else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.cacheDays)
        var alive: [(URL, Date)] = []
        for url in files where url.pathExtension == "json" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mtime < cutoff {
                try? fm.removeItem(at: url)
            } else {
                alive.append((url, mtime))
            }
        }
        if alive.count > Self.maxDiskCacheFiles {
            let sorted = alive.sorted { $0.1 < $1.1 }
            for (url, _) in sorted.prefix(alive.count - Self.maxDiskCacheFiles) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - 2. 官方双域名回退、Bearer/api_key 自动识别与核心 GET

    private func activeConfig() -> TmdbNetConfig {
        let cfg = AppSettings.shared.tmdbNetConfig
        if cfg.apiHttpProblem() != nil {
            var safe = cfg
            safe.apiBase = TmdbNetConfig.altApi
            return safe
        }
        return cfg
    }

    private func candidateBases(for cfg: TmdbNetConfig) -> [String] {
        let official: Set<String> = [TmdbNetConfig.defaultApi, TmdbNetConfig.altApi]
        if let auto = autoBase, official.contains(cfg.apiBase) {
            return [auto]
        }
        if cfg.apiBase == TmdbNetConfig.altApi {
            return [TmdbNetConfig.altApi, TmdbNetConfig.defaultApi]
        }
        if cfg.apiBase == TmdbNetConfig.defaultApi {
            return [TmdbNetConfig.defaultApi, TmdbNetConfig.altApi]
        }
        return [cfg.apiBase]
    }

    private static func isConnectOrTimeoutError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateUntrusted,
        ].contains(ns.code)
    }

    private static func netReason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "域名解析失败"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "TLS 握手失败（可能被拦截）"
            case NSURLErrorTimedOut:
                return "请求超时"
            case NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "连接超时 / 被拒绝"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    public static func connectHelp(host: String, why: String) -> String {
        "无法连接 TMDB（\(host)）：\(why)。请开启代理，或在「设置 › TMDB 网络」填写 TMDB 代理或反代地址"
    }

    private func fetchApi(path: String, query: [String: String], bypassCache: Bool = false) async throws -> (statusCode: Int, data: Data) {
        let rawKey = KeychainStore.tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else {
            throw DriveError.unauthorized("未设置 TMDB API 密钥")
        }
        let cleanKey = rawKey.hasPrefix("Bearer ") ? String(rawKey.dropFirst(7)).trimmingCharacters(in: .whitespaces) : rawKey
        let isBearer = cleanKey.filter { $0 == "." }.count == 2
        let cfg = activeConfig()
        let bases = candidateBases(for: cfg)

        var lastError: Error?
        var lastHost = ""
        for base in bases {
            let trimmedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard var comps = URLComponents(string: "\(trimmedBase)\(path)") else { continue }
            var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            if !isBearer {
                items.insert(URLQueryItem(name: "api_key", value: cleanKey), at: 0)
            }
            comps.queryItems = items
            guard let url = comps.url else { continue }
            lastHost = url.host ?? trimmedBase

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 25
            if bypassCache { req.cachePolicy = .reloadIgnoringLocalCacheData }
            req.setValue("MediaMindAI/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
            if isBearer {
                req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
            }

            try await TmdbRequestPacer.shared.acquire(isImage: false)
            let activeSession: URLSession
            if let custom = customSession {
                activeSession = custom
            } else {
                activeSession = await TmdbNet.shared.session(for: cfg)
            }
            do {
                let (data, resp) = try await activeSession.data(for: req)
                let httpResp = resp as? HTTPURLResponse
                let status = httpResp?.statusCode ?? 0
                if status == 429 {
                    await TmdbRequestPacer.shared.record429(retryAfter: httpResp?.value(forHTTPHeaderField: "Retry-After"))
                }
                if base != cfg.apiBase && autoBase == nil {
                    autoBase = base
                    await NetLog.shared.line("TMDB", "官方地址连不上，已自动改用 \(lastHost)")
                }
                return (status, data)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                await NetLog.shared.error("TMDB", "\(lastHost) \(Self.netReason(error))")
                if !Self.isConnectOrTimeoutError(error) { break }
            }
        }

        let err = lastError ?? DriveError.network("无法连接 TMDB")
        let hostDesc = bases.count > 1 ? "api.tmdb.org / api.themoviedb.org" : lastHost
        let msg = Self.connectHelp(host: hostDesc, why: Self.netReason(err))
        if Self.isConnectOrTimeoutError(err) {
            failUntil = Date().addingTimeInterval(30)
            failMsg = msg
        }
        throw DriveError.network(msg)
    }

    public func get(path: String, query: [String: String] = [:], freshSince: Date? = nil) async -> Data? {
        if case let .ok(data) = await getOutcome(path: path, query: query, freshSince: freshSince) {
            return data
        }
        return nil
    }

    private func getOutcome(path: String, query: [String: String] = [:], freshSince: Date? = nil) async -> GetOutcome {
        let apiKey = KeychainStore.tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return .transientError }

        var full = query
        if full["language"] == nil {
            let lang = AppSettings.shared.tmdbLanguage
            full["language"] = lang.isEmpty ? "zh-CN" : lang
        }
        let cacheKey = path + "?" + full
            .filter { $0.key != "api_key" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")

        let now = Date()
        let cp = cacheFileURL(for: cacheKey)
        let minTs = freshSince?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        let diskMtime: TimeInterval? = (try? cp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970)

        // 1. 内存 LRU 快速命中（校验磁盘 mtime 一致）
        if let mtime = diskMtime, mtime >= minTs, now.timeIntervalSince1970 - mtime < Self.cacheDays {
            if var hit = memCache[cacheKey], abs(hit.diskMtime - mtime) < 0.001 {
                accessCounter &+= 1
                hit.lastAccess = accessCounter
                memCache[cacheKey] = hit
                return .ok(hit.data)
            }
            // 2. 磁盘缓存命中并回填内存 LRU
            if let diskData = try? Data(contentsOf: cp), !diskData.isEmpty {
                putMemCache(key: cacheKey, data: diskData, diskMtime: mtime)
                return .ok(diskData)
            }
        } else if diskMtime == nil, let hit = memCache[cacheKey], hit.diskMtime >= minTs, now.timeIntervalSince1970 - hit.diskMtime < Self.cacheDays {
            accessCounter &+= 1
            var updated = hit
            updated.lastAccess = accessCounter
            memCache[cacheKey] = updated
            return .ok(hit.data)
        }

        // 熔断期内快速返回瞬时错误，避免误写负缓存
        if now < failUntil {
            return .transientError
        }

        // 3. Singleflight 在途去重
        if let existing = inFlight[cacheKey]?.1 {
            do {
                if let data = try await existing.value {
                    return .ok(data)
                }
                return .notFound
            } catch {
                return .transientError
            }
        }

        let task = Task<Data?, Error> { [self] in
            let (status, data) = try await self.fetchApi(path: path, query: full)
            guard (200...299).contains(status) else {
                if status == 401 {
                    await NetLog.shared.error("TMDB", "TMDB API 密钥无效（HTTP 401），请在 TMDB 网络设置中重新填写")
                } else {
                    await NetLog.shared.error("TMDB", "\(path) HTTP \(status)")
                }
                if status != 404 {
                    throw DriveError.api(code: status, message: "TMDB HTTP \(status)")
                }
                return nil
            }
            return data
        }
        let token = UUID()
        inFlight[cacheKey] = (token, task)

        defer {
            if inFlight[cacheKey]?.0 == token {
                inFlight.removeValue(forKey: cacheKey)
            }
        }
        do {
            guard let data = try await task.value else { return .notFound }
            var savedMtime = Date().timeIntervalSince1970
            if let text = String(data: data, encoding: .utf8) {
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try? AtomicFileIO.writeText(text, to: cp)
                if let m = try? cp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 {
                    savedMtime = m
                }
                pruneDiskCacheIfNeeded()
            }
            putMemCache(key: cacheKey, data: data, diskMtime: savedMtime)
            return .ok(data)
        } catch {
            return .transientError
        }
    }

    // MARK: - 3. 连通性与图片测试

    public func testConnectivity() async -> Bool {
        if case .success = await test() { return true }
        return false
    }

    /// 1:1 复刻 Android `TmdbClient.test()`：测试 `/configuration` 并返回中文耗时说明。
    public func test() async -> Result<String, Error> {
        resetFailures()
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let (status, _) = try await fetchApi(path: "/configuration", query: [:], bypassCache: true)
            let ms = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let cfg = activeConfig()
            let usedBase = autoBase ?? cfg.apiBase
            let host = URL(string: usedBase)?.host ?? usedBase
            let via = autoBase != nil ? "（首选地址不通，已自动改用另一个官方地址）" : ""
            switch status {
            case 200:
                return .success("连接成功：\(host) · \(ms)ms\(via)")
            case 401:
                return .failure(DriveError.unauthorized("已连上 \(host)，但 TMDB API 密钥无效（HTTP 401）"))
            default:
                return .failure(DriveError.api(code: status, message: "\(host) 返回 HTTP \(status)（\(ms)ms），如使用反代请检查地址"))
            }
        } catch {
            return .failure(error)
        }
    }

    /// 1:1 复刻 Android `TmdbClient.testImage()`：下载测试海报并报告可用图片主机与耗时。
    public func testImage() async -> Result<String, Error> {
        let started = DispatchTime.now().uptimeNanoseconds
        let cfg = activeConfig()
        let url = TmdbNetConfig.defaultImage + Self.imageTestPath
        do {
            let bytes = try await TmdbNet.shared.downloadImageWithFallback(urlStr: url, config: cfg, session: customSession, bypassCache: true)
            let ms = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let pref = await TmdbNet.shared.preferredImageBase ?? cfg.imageBase
            let host = URL(string: pref)?.host ?? pref
            return .success("图片正常：\(host) · \(ms)ms（\(bytes.count) B）")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 4. 融合搜索、评分排序与多地区中文名回退

    public nonisolated static func yearCandidates(_ year: String?) -> [String?] {
        guard let trimmed = year?.trimmingCharacters(in: .whitespacesAndNewlines),
              let y = Int(trimmed), trimmed.count == 4 else {
            return [nil]
        }
        return [trimmed, "\(y + 1)", "\(y - 1)", nil]
    }

    public nonisolated static func splitQuery(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = [trimmed]
        let hasCjk = cjkRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
        if hasCjk {
            let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: " /|·:：-"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
            let cjkPart = parts.filter { cjkRegex.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }.joined(separator: " ")
            let latinPart = parts.filter { cjkRegex.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) == nil }.joined(separator: " ")
            if !cjkPart.isEmpty && cjkPart != trimmed { out.append(cjkPart) }
            if latinPart.count >= 3 && latinPart != trimmed { out.append(latinPart) }
        }
        return out
    }

    public nonisolated static func scoreMovieRaw(_ item: [String: Any], parts: [String], year: String?) -> Double {
        let title = (item["title"] as? String) ?? ""
        let orig = (item["original_title"] as? String) ?? ""
        let rawNames = [title, orig].filter { !$0.isEmpty }
        var best = 0.0
        for q in parts {
            for n in rawNames {
                best = max(best, TitleScorer.titleSimilarityScore(q, n))
            }
        }
        var score = best
        let cjkParts = parts.filter { Self.hasCjk($0) }
        if !cjkParts.isEmpty {
            var cjkBest = 0.0
            for q in cjkParts {
                for n in rawNames {
                    cjkBest = max(cjkBest, TitleScorer.titleSimilarityScore(q, n))
                }
            }
            if cjkBest >= 85.0 {
                score += 35.0
            } else if !rawNames.contains(where: { Self.hasCjk($0) }) {
                score -= 20.0
            }
        }
        let ry = String(((item["release_date"] as? String) ?? "").prefix(4))
        let releaseYear = ry.count == 4 ? Int(ry) : nil
        let queryYear = year.flatMap { Int($0) }
        if let qy = queryYear, let ryi = releaseYear {
            let diff = abs(ryi - qy)
            switch diff {
            case 0: score += 40.0
            case 1: score += 15.0
            default: score -= 20.0
            }
        } else if let y = year, !y.isEmpty {
            score -= 10.0
        }
        let votes = (item["vote_count"] as? NSNumber)?.doubleValue ?? 0
        let popularity = (item["popularity"] as? NSNumber)?.doubleValue ?? 0
        score += 12.0 * log10(1.0 + votes) + 5.0 * log10(1.0 + popularity)
        if votes < 10 { score -= 20.0 }
        if (item["video"] as? Bool) == true { score -= 60.0 }
        let combined = "\(title) \(orig)"
        if featuretteRegex.firstMatch(in: combined, range: NSRange(location: 0, length: (combined as NSString).length)) != nil {
            score -= 60.0
        }
        return score
    }

    public nonisolated static func hasCjk(_ s: String) -> Bool {
        cjkRegex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    public nonisolated static func scoreTvRaw(_ item: [String: Any], parts: [String], year: String?) -> Double {
        let name = (item["name"] as? String) ?? ""
        let orig = (item["original_name"] as? String) ?? ""
        let rawNames = [name, orig].filter { !$0.isEmpty }
        var best = 0.0
        for q in parts {
            for n in rawNames {
                best = max(best, TitleScorer.titleSimilarityScore(q, n))
            }
        }
        var score = best
        let cjkParts = parts.filter { Self.hasCjk($0) }
        if !cjkParts.isEmpty {
            var cjkBest = 0.0
            for q in cjkParts {
                for n in rawNames {
                    cjkBest = max(cjkBest, TitleScorer.titleSimilarityScore(q, n))
                }
            }
            if cjkBest >= 85.0 {
                score += 35.0
            } else if !rawNames.contains(where: { Self.hasCjk($0) }) {
                score -= 20.0
            }
        }
        let fy = String(((item["first_air_date"] as? String) ?? "").prefix(4))
        let firstYear = fy.count == 4 ? Int(fy) : nil
        let queryYear = year.flatMap { Int($0) }
        if let qy = queryYear, let fyi = firstYear {
            let diff = abs(fyi - qy)
            switch diff {
            case 0: score += 40.0
            case 1: score += 15.0
            default: score -= 20.0
            }
        } else if let y = year, !y.isEmpty {
            score -= 10.0
        }
        let votes = (item["vote_count"] as? NSNumber)?.doubleValue ?? 0
        let popularity = (item["popularity"] as? NSNumber)?.doubleValue ?? 0
        score += 10.0 * log10(1.0 + votes) + 5.0 * log10(1.0 + popularity)
        return score
    }

    private func searchMovieRaw(query: String, year: String?) async -> [[String: Any]] {
        let negKey = "m|\(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(year ?? "")"
        if isNegativeCached(negKey) { return [] }
        var params: [String: String] = ["query": query, "include_adult": "false"]
        if let y = year, !y.isEmpty { params["primary_release_year"] = y }
        switch await getOutcome(path: "/search/movie", query: params) {
        case .ok(let data):
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else {
                return []
            }
            if results.isEmpty { markNegative(negKey) }
            return results
        case .notFound:
            markNegative(negKey)
            return []
        case .transientError:
            return []
        }
    }

    private func searchTvRaw(query: String, year: String?) async -> [[String: Any]] {
        let negKey = "t|\(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(year ?? "")"
        if isNegativeCached(negKey) { return [] }
        var params: [String: String] = ["query": query, "include_adult": "false"]
        if let y = year, !y.isEmpty { params["first_air_date_year"] = y }
        switch await getOutcome(path: "/search/tv", query: params) {
        case .ok(let data):
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else {
                return []
            }
            if results.isEmpty { markNegative(negKey) }
            return results
        case .notFound:
            markNegative(negKey)
            return []
        case .transientError:
            return []
        }
    }

    /// 融合搜索电影：多拆分子串 + 年份候选 `[y, y+1, y-1, nil]` + 综合评分降序返回。
    public func searchMovie(query: String, year: Int? = nil) async -> [MatchInfo] {
        let yearStr = year.map { "\($0)" }
        let parts = Self.splitQuery(query)
        guard !parts.isEmpty else { return [] }

        var byId: [Int: [String: Any]] = [:]
        var orderedIds: [Int] = []

        func merge(_ batch: [[String: Any]]) {
            for item in batch {
                guard let id = item["id"] as? Int, id > 0 else { continue }
                if byId[id] == nil {
                    byId[id] = item
                    orderedIds.append(id)
                }
            }
        }

        for q in parts {
            merge(await searchMovieRaw(query: q, year: yearStr))
        }
        let rankedFirst = orderedIds.compactMap { byId[$0] }.sorted {
            Self.scoreMovieRaw($0, parts: parts, year: yearStr) > Self.scoreMovieRaw($1, parts: parts, year: yearStr)
        }
        let bestScore = rankedFirst.first.map { Self.scoreMovieRaw($0, parts: parts, year: yearStr) } ?? -1e9
        let yearOk = yearStr == nil || ((rankedFirst.first?["release_date"] as? String) ?? "").hasPrefix(yearStr!)
        if !(rankedFirst.first != nil && yearOk && bestScore >= 135.0) {
            for y in Self.yearCandidates(yearStr).dropFirst() {
                for q in parts {
                    merge(await searchMovieRaw(query: q, year: y))
                }
            }
        }

        let ranked = orderedIds.compactMap { byId[$0] }.sorted {
            Self.scoreMovieRaw($0, parts: parts, year: yearStr) > Self.scoreMovieRaw($1, parts: parts, year: yearStr)
        }
        var out: [MatchInfo] = []
        out.reserveCapacity(ranked.count)
        for item in ranked {
            if let info = parseSearchItem(item, kind: "movie") {
                out.append(info)
            }
        }
        if ranked.count >= 2 && out.count >= 2 {
            let s1 = Self.scoreMovieRaw(ranked[0], parts: parts, year: yearStr)
            let s2 = Self.scoreMovieRaw(ranked[1], parts: parts, year: yearStr)
            if AiCandidateReranker.shouldRerank(topScore: s1, secondScore: s2),
               let picked = await AiCandidateReranker.rerank(rawName: query, kind: "movie", candidates: out),
               let idx = out.firstIndex(where: { $0.id == picked.id }), idx > 0 {
                let chosen = out.remove(at: idx)
                out.insert(chosen, at: 0)
            }
        }
        if let first = out.first {
            let zh = await zhTitle(kind: "movie", id: first.id, title: first.title)
            if zh != first.title {
                out[0] = MatchInfo(
                    kind: first.kind, id: first.id, title: zh, year: first.year,
                    posterPath: first.posterPath, backdropPath: first.backdropPath,
                    originalTitle: first.originalTitle, overview: first.overview,
                    rating: first.rating, collectionId: first.collectionId,
                    collectionName: first.collectionName, collectionPosterPath: first.collectionPosterPath
                )
            }
        }
        return out
    }

    /// 融合搜索剧集：多拆分子串 + 年份候选 `[y, y+1, y-1, nil]` + 综合评分降序返回。
    public func searchTv(query: String, year: Int? = nil) async -> [MatchInfo] {
        let yearStr = year.map { "\($0)" }
        let parts = Self.splitQuery(query)
        guard !parts.isEmpty else { return [] }

        var byId: [Int: [String: Any]] = [:]
        var orderedIds: [Int] = []

        func merge(_ batch: [[String: Any]]) {
            for item in batch {
                guard let id = item["id"] as? Int, id > 0 else { continue }
                if byId[id] == nil {
                    byId[id] = item
                    orderedIds.append(id)
                }
            }
        }

        for q in parts {
            merge(await searchTvRaw(query: q, year: yearStr))
        }
        let rankedFirst = orderedIds.compactMap { byId[$0] }.sorted {
            Self.scoreTvRaw($0, parts: parts, year: yearStr) > Self.scoreTvRaw($1, parts: parts, year: yearStr)
        }
        let bestScore = rankedFirst.first.map { Self.scoreTvRaw($0, parts: parts, year: yearStr) } ?? -1e9
        let yearOk = yearStr == nil || ((rankedFirst.first?["first_air_date"] as? String) ?? "").hasPrefix(yearStr!)
        let queryHasCjk = parts.contains(where: { Self.hasCjk($0) })
        let topHasCjk = rankedFirst.first.map {
            Self.hasCjk(($0["name"] as? String) ?? "") || Self.hasCjk(($0["original_name"] as? String) ?? "")
        } ?? false
        if !(rankedFirst.first != nil && yearOk && bestScore >= 110.0 && (!queryHasCjk || topHasCjk)) {
            for y in Self.yearCandidates(yearStr).dropFirst() {
                for q in parts {
                    merge(await searchTvRaw(query: q, year: y))
                }
                let bestNow = orderedIds.compactMap { byId[$0] }
                    .map { Self.scoreTvRaw($0, parts: parts, year: yearStr) }
                    .max() ?? -1e9
                if bestNow >= 110.0 { break }
            }
        }

        let ranked = orderedIds.compactMap { byId[$0] }.sorted {
            Self.scoreTvRaw($0, parts: parts, year: yearStr) > Self.scoreTvRaw($1, parts: parts, year: yearStr)
        }
        var out: [MatchInfo] = []
        out.reserveCapacity(ranked.count)
        for item in ranked {
            if let info = parseSearchItem(item, kind: "tv") {
                out.append(info)
            }
        }
        if ranked.count >= 2 && out.count >= 2 {
            let s1 = Self.scoreTvRaw(ranked[0], parts: parts, year: yearStr)
            let s2 = Self.scoreTvRaw(ranked[1], parts: parts, year: yearStr)
            if AiCandidateReranker.shouldRerank(topScore: s1, secondScore: s2),
               let picked = await AiCandidateReranker.rerank(rawName: query, kind: "tv", candidates: out),
               let idx = out.firstIndex(where: { $0.id == picked.id }), idx > 0 {
                let chosen = out.remove(at: idx)
                out.insert(chosen, at: 0)
            }
        }
        if let first = out.first {
            let zh = await zhTitle(kind: "tv", id: first.id, title: first.title)
            if zh != first.title {
                out[0] = MatchInfo(
                    kind: first.kind, id: first.id, title: zh, year: first.year,
                    posterPath: first.posterPath, backdropPath: first.backdropPath,
                    originalTitle: first.originalTitle, overview: first.overview,
                    rating: first.rating, collectionId: first.collectionId,
                    collectionName: first.collectionName, collectionPosterPath: first.collectionPosterPath
                )
            }
        }
        return out
    }

    /// 标题不含汉字时，查询 `/translations` 按 `CN → SG → TW → HK` 回退官方中文名。
    public func zhTitle(kind: String, id: Int, title: String) async -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return title }
        let lang = AppSettings.shared.tmdbLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lang.isEmpty || lang.hasPrefix("zh") else { return trimmed }
        if Self.cjkRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil {
            return trimmed
        }
        let seg = kind == "tv" ? "tv" : "movie"
        guard let data = await get(path: "/\(seg)/\(id)/translations", query: [:]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["translations"] as? [[String: Any]] else {
            return trimmed
        }
        var byRegion: [String: String] = [:]
        for item in list where (item["iso_639_1"] as? String) == "zh" {
            let region = (item["iso_3166_1"] as? String) ?? ""
            let d = item["data"] as? [String: Any]
            let t = ((d?["title"] as? String) ?? (d?["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { byRegion[region] = t }
        }
        for region in ["CN", "SG", "TW", "HK"] {
            if let hit = byRegion[region], !hit.isEmpty { return hit }
        }
        return trimmed
    }

    // MARK: - 5. 详情、季集批量拉取、剧集组、合集与外部 ID 反查

    public func movieDetails(id: Int) async -> MatchInfo? {
        guard let data = await get(path: "/movie/\(id)"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let rawTitle = (obj["title"] as? String) ?? (obj["original_title"] as? String) ?? ""
        let title = await zhTitle(kind: "movie", id: id, title: rawTitle)
        let year = String(((obj["release_date"] as? String) ?? "").prefix(4))
        let col = obj["belongs_to_collection"] as? [String: Any]
        return MatchInfo(
            kind: "movie",
            id: id,
            title: title,
            year: year,
            posterPath: obj["poster_path"] as? String,
            backdropPath: obj["backdrop_path"] as? String,
            originalTitle: obj["original_title"] as? String,
            overview: obj["overview"] as? String ?? "",
            rating: obj["vote_average"] as? Double,
            collectionId: col?["id"] as? Int,
            collectionName: col?["name"] as? String,
            collectionPosterPath: col?["poster_path"] as? String
        )
    }

    public func tvDetails(id: Int) async -> MatchInfo? {
        guard let data = await get(path: "/tv/\(id)"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let rawTitle = (obj["name"] as? String) ?? (obj["original_name"] as? String) ?? ""
        let title = await zhTitle(kind: "tv", id: id, title: rawTitle)
        let year = String(((obj["first_air_date"] as? String) ?? "").prefix(4))
        return MatchInfo(
            kind: "tv",
            id: id,
            title: title,
            year: year,
            posterPath: obj["poster_path"] as? String,
            backdropPath: obj["backdrop_path"] as? String,
            originalTitle: obj["original_name"] as? String,
            overview: obj["overview"] as? String ?? "",
            rating: obj["vote_average"] as? Double,
            genreIds: (obj["genres"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }
        )
    }

    public func tvSeasonEpisodeCounts(id: Int) async -> (seasons: Int, episodes: Int)? {
        guard let data = await get(path: "/tv/\(id)"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let seasons = (obj["number_of_seasons"] as? Int) ?? 0
        let episodes = (obj["number_of_episodes"] as? Int) ?? 0
        guard seasons > 0, episodes > 0 else { return nil }
        return (seasons, episodes)
    }

    public func seasonMeta(tvId: Int, season: Int) async -> SeasonMeta? {
        guard let data = await get(path: "/tv/\(tvId)/season/\(season)"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return SeasonMeta(
            seasonNumber: season,
            name: obj["name"] as? String ?? "第 \(season) 季",
            airDate: obj["air_date"] as? String ?? "",
            overview: obj["overview"] as? String ?? "",
            posterPath: obj["poster_path"] as? String
        )
    }

    /// 整季批量拉取单集元数据（剧集 NFO 与剧照共享同一次请求，失败回退单集接口）。
    public func episodeFromSeasonBatch(tvId: Int, season: Int, episode: Int) async -> EpisodeMeta? {
        if let data = await get(path: "/tv/\(tvId)/season/\(season)"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let eps = obj["episodes"] as? [[String: Any]],
           let hit = eps.first(where: { ($0["episode_number"] as? Int) == episode }) {
            return EpisodeMeta(
                seasonNumber: season,
                episodeNumber: episode,
                name: hit["name"] as? String ?? "第 \(episode) 集",
                airDate: hit["air_date"] as? String ?? "",
                overview: hit["overview"] as? String ?? "",
                stillPath: hit["still_path"] as? String
            )
        }
        if let data = await get(path: "/tv/\(tvId)/season/\(season)/episode/\(episode)"),
           let hit = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return EpisodeMeta(
                seasonNumber: season,
                episodeNumber: episode,
                name: hit["name"] as? String ?? "第 \(episode) 集",
                airDate: hit["air_date"] as? String ?? "",
                overview: hit["overview"] as? String ?? "",
                stillPath: hit["still_path"] as? String
            )
        }
        return nil
    }

    /// 拉取电影或剧集官方 ClearLogo 路径（优先中文，其次英文/无语言，按评分降序）。
    public func clearlogoPath(kind: String, id: Int) async -> String? {
        let seg = kind == "tv" ? "tv" : "movie"
        guard let data = await get(path: "/\(seg)/\(id)/images", query: ["include_image_language": "zh,en,null"]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let logos = obj["logos"] as? [[String: Any]] else { return nil }
        let sorted = logos.sorted { a, b in
            let la = (a["iso_639_1"] as? String) == "zh" ? 2 : ((a["iso_639_1"] as? String) == "en" ? 1 : 0)
            let lb = (b["iso_639_1"] as? String) == "zh" ? 2 : ((b["iso_639_1"] as? String) == "en" ? 1 : 0)
            if la != lb { return la > lb }
            return (a["vote_average"] as? Double ?? 0) > (b["vote_average"] as? Double ?? 0)
        }
        return sorted.compactMap { $0["file_path"] as? String }.first(where: { !$0.isEmpty })
    }

    /// 读取 TMDB 合集官方海报；若合集无图，自动回退为系列内最早有图电影的海报。
    public func collectionPoster(collectionId: Int) async -> String? {
        guard let data = await get(path: "/collection/\(collectionId)"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let p = obj["poster_path"] as? String, !p.isEmpty { return p }
        let parts = obj["parts"] as? [[String: Any]] ?? []
        let sorted = parts.sorted {
            let y1 = Int(String(($0["release_date"] as? String ?? "").prefix(4))) ?? 9999
            let y2 = Int(String(($1["release_date"] as? String ?? "").prefix(4))) ?? 9999
            return y1 < y2
        }
        return sorted.compactMap { $0["poster_path"] as? String }.first(where: { !$0.isEmpty })
    }

    public func collectionParts(collectionId: Int) async -> [MatchInfo] {
        guard let data = await get(path: "/collection/\(collectionId)", query: [:]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let parts = obj["parts"] as? [[String: Any]] else {
            return []
        }
        let colName = obj["name"] as? String
        let colPoster = obj["poster_path"] as? String
        let sorted = parts.sorted {
            let y1 = Int(String(($0["release_date"] as? String ?? "").prefix(4))) ?? 9999
            let y2 = Int(String(($1["release_date"] as? String ?? "").prefix(4))) ?? 9999
            return y1 < y2
        }
        return sorted.compactMap { item -> MatchInfo? in
            guard let id = item["id"] as? Int, id > 0,
                  let title = (item["title"] as? String) ?? (item["original_title"] as? String) else { return nil }
            let release = (item["release_date"] as? String) ?? ""
            return MatchInfo(
                kind: "movie",
                id: id,
                title: title,
                year: String(release.prefix(4)),
                posterPath: item["poster_path"] as? String,
                backdropPath: item["backdrop_path"] as? String,
                originalTitle: item["original_title"] as? String,
                overview: (item["overview"] as? String) ?? "",
                rating: item["vote_average"] as? Double,
                collectionId: collectionId,
                collectionName: colName,
                collectionPosterPath: colPoster
            )
        }
    }

    public func findByExternalId(_ externalId: String, source: String, preferKind: String? = nil) async -> MatchInfo? {
        guard let data = await get(path: "/find/\(externalId)", query: ["external_source": source]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let movie = (obj["movie_results"] as? [[String: Any]])?.first.flatMap { parseSearchItem($0, kind: "movie") }
        let tv = (obj["tv_results"] as? [[String: Any]])?.first.flatMap { parseSearchItem($0, kind: "tv") }
        if preferKind == "tv" { return tv ?? movie }
        return movie ?? tv
    }

    public func findByImdbId(_ imdbId: String, preferKind: String? = nil) async -> MatchInfo? {
        let clean = imdbId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.hasPrefix("tt") else { return nil }
        return await findByExternalId(clean, source: "imdb_id", preferKind: preferKind)
    }

    public func findByTvdbId(_ tvdbId: Int) async -> MatchInfo? {
        guard tvdbId > 0 else { return nil }
        return await findByExternalId("\(tvdbId)", source: "tvdb_id", preferKind: "tv")
    }

    public func tvSeasonCounts(id: Int) async -> [Int: Int] {
        guard let data = await get(path: "/tv/\(id)", query: [:]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let seasons = obj["seasons"] as? [[String: Any]] else {
            return [:]
        }
        var out: [Int: Int] = [:]
        for s in seasons {
            if let sn = s["season_number"] as? Int, let cnt = s["episode_count"] as? Int, cnt > 0 {
                out[sn] = cnt
            }
        }
        return out
    }

    public func tvEpisodeGroups(tvId: Int) async -> [TmdbEpisodeGroupSummary] {
        guard let data = await get(path: "/tv/\(tvId)/episode_groups", query: [:]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            return []
        }
        return results.compactMap { g in
            guard let id = g["id"] as? String, !id.isEmpty else { return nil }
            return TmdbEpisodeGroupSummary(
                id: id,
                name: (g["name"] as? String) ?? "",
                type: (g["type"] as? Int) ?? 0,
                groupCount: (g["group_count"] as? Int) ?? 0,
                episodeCount: (g["episode_count"] as? Int) ?? 0
            )
        }
    }

    public func tvEpisodeGroupDetails(groupId: String) async -> [[EpisodeMapping.EpisodeKey]] {
        guard let data = await get(path: "/tv/episode_group/\(groupId)", query: [:]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let groups = obj["groups"] as? [[String: Any]] else {
            return []
        }
        let sortedGroups = groups.sorted { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }
        return sortedGroups.map { g in
            let eps = (g["episodes"] as? [[String: Any]] ?? [])
                .sorted { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }
            return eps.compactMap { ep -> EpisodeMapping.EpisodeKey? in
                guard let s = ep["season_number"] as? Int, let e = ep["episode_number"] as? Int else { return nil }
                return EpisodeMapping.EpisodeKey(season: s, episode: e)
            }
        }
    }

    private func parseSearchItem(_ o: [String: Any], kind: String) -> MatchInfo? {
        guard let id = o["id"] as? Int, id > 0 else { return nil }
        let title = (kind == "movie" ? (o["title"] as? String ?? o["original_title"] as? String) : (o["name"] as? String ?? o["original_name"] as? String)) ?? ""
        let orig = kind == "movie" ? (o["original_title"] as? String) : (o["original_name"] as? String)
        let dateStr = (kind == "movie" ? o["release_date"] : o["first_air_date"]) as? String ?? ""
        return MatchInfo(
            kind: kind,
            id: id,
            title: title,
            year: String(dateStr.prefix(4)),
            posterPath: o["poster_path"] as? String,
            backdropPath: o["backdrop_path"] as? String,
            originalTitle: orig,
            overview: o["overview"] as? String ?? "",
            rating: o["vote_average"] as? Double,
            genreIds: o["genre_ids"] as? [Int]
        )
    }
}
