import Foundation
import CryptoKit

/// AI 识别配置（1:1 对标 Android `AiRecognizerConfig.kt`：国内直连预设、HTTPS 安全校验、独立/复用 TMDB 代理、单次扫盘预算上限）。
public struct AiRecognizerConfig: Codable, Hashable, Sendable {
    public static let proxyNone = "none"
    public static let proxyFollowTmdb = "follow_tmdb"
    public static let proxyHttp = "http"
    public static let proxySocks = "socks"

    public var enabled: Bool
    public var provider: String
    public var baseUrl: String
    public var model: String
    public var proxyType: String
    public var proxyHost: String
    public var proxyPort: Int
    public var autoTriggerThreshold: Double
    public var autoAcceptThreshold: Double
    public var enableCandidateRerank: Bool
    public var enableRuleDistillation: Bool
    public var maxCallsPerScan: Int

    public init(
        enabled: Bool = false,
        provider: String = "deepseek",
        baseUrl: String = "https://api.deepseek.com/v1",
        model: String = "deepseek-chat",
        proxyType: String = AiRecognizerConfig.proxyNone,
        proxyHost: String = "",
        proxyPort: Int = 0,
        autoTriggerThreshold: Double = 0.60,
        autoAcceptThreshold: Double = 0.80,
        enableCandidateRerank: Bool = true,
        enableRuleDistillation: Bool = true,
        maxCallsPerScan: Int = 30
    ) {
        self.enabled = enabled
        self.provider = provider
        self.baseUrl = baseUrl
        self.model = model
        self.proxyType = proxyType
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.autoTriggerThreshold = autoTriggerThreshold
        self.autoAcceptThreshold = autoAcceptThreshold
        self.enableCandidateRerank = enableCandidateRerank
        self.enableRuleDistillation = enableRuleDistillation
        self.maxCallsPerScan = maxCallsPerScan
    }

    private static let validProxyTypes: Set<String> = [proxyNone, proxyFollowTmdb, proxyHttp, proxySocks]
    private static let modelSafeRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._:\-/]{1,80}$"#)
    private static let localHttpRegex = try! NSRegularExpression(
        pattern: #"^http://(?:localhost|127\.0\.0\.1|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})(?::\d{1,5})?(?:/.*)?$"#,
        options: [.caseInsensitive]
    )

    /// 规范化中转站地址：去掉末尾斜杠与误粘贴的 `/chat/completions`。
    public static func normalizeBaseUrl(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if u.lowercased().hasSuffix("/chat/completions") {
            u = String(u.dropLast("/chat/completions".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return u
    }

    /// 校验接口地址安全性：禁止对公网使用明文 http://，仅允许本地回环或局域网 IP（如 Ollama）。
    public static func validateBaseUrl(_ url: String) -> String? {
        let u = normalizeBaseUrl(url)
        if u.isEmpty { return "AI 接口地址不能为空" }
        let low = u.lowercased()
        if low.hasPrefix("https://") { return nil }
        if low.hasPrefix("http://") {
            let range = NSRange(location: 0, length: (u as NSString).length)
            if localHttpRegex.firstMatch(in: u, range: range) != nil { return nil }
            return "公网 AI 接口禁止使用 http://（会明文暴露 API 密钥），请改用 https:// 或仅在局域网使用 Ollama"
        }
        return "AI 接口地址必须以 https:// 或局域网 http:// 开头"
    }

    public func isOpenAiCompatible() -> Bool {
        let p = provider.lowercased()
        return p != "gemini"
    }

    public func sanitized() -> AiRecognizerConfig {
        let lowProvider = provider.lowercased() == "moonshot" ? "kimi" : provider.lowercased()
        let preset = AiProviderPreset.of(lowProvider)
        let normProvider = AiProviderPreset.all.contains(where: { $0.id == lowProvider }) ? lowProvider : "deepseek"
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelRange = NSRange(location: 0, length: (trimmedModel as NSString).length)
        let normModel = (!trimmedModel.isEmpty && !trimmedModel.contains("..") && Self.modelSafeRegex.firstMatch(in: trimmedModel, range: modelRange) != nil)
            ? trimmedModel
            : preset.defaultModel
        let normBase = Self.normalizeBaseUrl(baseUrl)
        let normProxy = Self.validProxyTypes.contains(proxyType.lowercased()) ? proxyType.lowercased() : Self.proxyNone
        return AiRecognizerConfig(
            enabled: enabled,
            provider: normProvider,
            baseUrl: normBase.isEmpty ? preset.defaultBaseUrl : normBase,
            model: normModel,
            proxyType: normProxy,
            proxyHost: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
            proxyPort: min(65535, max(0, proxyPort)),
            autoTriggerThreshold: min(0.95, max(0.10, autoTriggerThreshold)),
            autoAcceptThreshold: min(0.99, max(0.50, autoAcceptThreshold)),
            enableCandidateRerank: enableCandidateRerank,
            enableRuleDistillation: enableRuleDistillation,
            maxCallsPerScan: min(200, max(1, maxCallsPerScan))
        )
    }
}

public struct AiProviderPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let defaultBaseUrl: String
    public let defaultModel: String
    public let chinaDirect: Bool
    public let isGeminiNative: Bool

    public static let all: [AiProviderPreset] = [
        AiProviderPreset(id: "deepseek", label: "DeepSeek（国内直连）", defaultBaseUrl: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat", chinaDirect: true, isGeminiNative: false),
        AiProviderPreset(id: "siliconflow", label: "硅基流动（国内直连）", defaultBaseUrl: "https://api.siliconflow.cn/v1", defaultModel: "Qwen/Qwen2.5-7B-Instruct", chinaDirect: true, isGeminiNative: false),
        AiProviderPreset(id: "qwen", label: "通义千问（国内直连）", defaultBaseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-turbo", chinaDirect: true, isGeminiNative: false),
        AiProviderPreset(id: "zhipu", label: "智谱 GLM（国内直连）", defaultBaseUrl: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4-flash", chinaDirect: true, isGeminiNative: false),
        AiProviderPreset(id: "kimi", label: "Kimi 月之暗面（国内直连）", defaultBaseUrl: "https://api.moonshot.cn/v1", defaultModel: "moonshot-v1-8k", chinaDirect: true, isGeminiNative: false),
        AiProviderPreset(id: "openai", label: "OpenAI / 中转站", defaultBaseUrl: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini", chinaDirect: false, isGeminiNative: false),
        AiProviderPreset(id: "gemini", label: "Google Gemini", defaultBaseUrl: "https://generativelanguage.googleapis.com/v1beta", defaultModel: "gemini-2.0-flash", chinaDirect: false, isGeminiNative: true),
        AiProviderPreset(id: "ollama", label: "本地 Ollama", defaultBaseUrl: "http://127.0.0.1:11434/v1", defaultModel: "qwen2.5:7b", chinaDirect: true, isGeminiNative: false),
        AiProviderPreset(id: "custom", label: "自定义 OpenAI 兼容", defaultBaseUrl: "", defaultModel: "gpt-4o-mini", chinaDirect: false, isGeminiNative: false),
    ]

    public static func of(_ id: String) -> AiProviderPreset {
        let low = id.lowercased()
        if low == "moonshot" { return all.first(where: { $0.id == "kimi" }) ?? all[0] }
        return all.first(where: { $0.id == low }) ?? all[0]
    }
}

public struct AiRecognitionHint: Codable, Sendable {
    public let title: String
    public let year: Int?
    public let mediaType: String // "movie" | "tv"
    public let season: Int?
    public let episode: Int?

    public init(title: String, year: Int?, mediaType: String, season: Int?, episode: Int?) {
        self.title = title
        self.year = year
        self.mediaType = mediaType
        self.season = season
        self.episode = episode
    }
}

/// AI 识别有界内存 LRU + SHA-256 磁盘 TTL 缓存与传输故障熔断器（1:1 对标 Android `AiRecognitionCache.kt`）。
public actor AiRecognitionCache {
    public static let shared = AiRecognitionCache()

    public struct CacheEntry: Codable, Sendable {
        public let guess: AiResponseParser.AiTitleGuess?
        public let cachedAtMs: Int64

        public init(guess: AiResponseParser.AiTitleGuess?, cachedAtMs: Int64) {
            self.guess = guess
            self.cachedAtMs = cachedAtMs
        }
    }

    private static let maxMemEntries = 512
    private static let maxDiskFiles = 500
    private static let hitTtlMs: Int64 = 7 * 86_400_000
    private static let missTtlMs: Int64 = 10 * 60_000
    private static let circuitOpenMs: Int64 = 30_000

    private var mem: [String: (entry: CacheEntry, access: UInt64)] = [:]
    private var accessCounter: UInt64 = 0
    private var diskWrites: Int = 0
    private var circuitOpenUntilMs: Int64 = 0
    private var lastTransportError: String? = nil
    private let cacheDir: URL

    public init(cacheDir: URL? = nil) {
        if let cacheDir {
            self.cacheDir = cacheDir
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDir = base.appendingPathComponent("MediaMindAI/ai_cache", isDirectory: true)
        }
    }

    public nonisolated static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    public nonisolated static func cacheKey(provider: String, model: String, rawName: String, folderName: String?) -> String {
        let payload = "\(provider)|\(model)|\(rawName.trimmingCharacters(in: .whitespacesAndNewlines))|\((folderName ?? "").trimmingCharacters(in: .whitespacesAndNewlines))"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func isCircuitOpen(now: Int64 = AiRecognitionCache.nowMs()) -> Bool {
        now < circuitOpenUntilMs
    }

    public func tripCircuit(reason: String, now: Int64 = AiRecognitionCache.nowMs()) {
        circuitOpenUntilMs = now + Self.circuitOpenMs
        lastTransportError = String(reason.prefix(160))
    }

    public func resetCircuit() {
        circuitOpenUntilMs = 0
        lastTransportError = nil
    }

    public func lastError() -> String? {
        lastTransportError
    }

    public func get(key: String, now: Int64 = AiRecognitionCache.nowMs()) -> CacheEntry? {
        if var hit = mem[key] {
            let ttl = hit.entry.guess != nil ? Self.hitTtlMs : Self.missTtlMs
            if now - hit.entry.cachedAtMs < ttl {
                accessCounter &+= 1
                hit.access = accessCounter
                mem[key] = hit
                return hit.entry
            }
            mem.removeValue(forKey: key)
        }
        let file = cacheDir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else {
            return nil
        }
        let ttl = entry.guess != nil ? Self.hitTtlMs : Self.missTtlMs
        if now - entry.cachedAtMs >= ttl {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        putMem(key: key, entry: entry)
        return entry
    }

    public func put(key: String, guess: AiResponseParser.AiTitleGuess?, now: Int64 = AiRecognitionCache.nowMs()) {
        let entry = CacheEntry(guess: guess, cachedAtMs: now)
        putMem(key: key, entry: entry)
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            if let text = String(data: data, encoding: .utf8) {
                try AtomicFileIO.writeText(text, to: cacheDir.appendingPathComponent("\(key).json"))
            }
            diskWrites += 1
            if diskWrites % 50 == 0 {
                pruneDisk(now: now)
            }
        } catch {
            // 磁盘缓存写入失败不影响主流程
        }
    }

    public func clearMemory() {
        mem.removeAll()
    }

    public func clearAll() {
        mem.removeAll()
        resetCircuit()
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private func putMem(key: String, entry: CacheEntry) {
        accessCounter &+= 1
        mem[key] = (entry, accessCounter)
        if mem.count > Self.maxMemEntries {
            if let oldest = mem.min(by: { $0.value.access < $1.value.access })?.key {
                mem.removeValue(forKey: oldest)
            }
        }
    }

    private func pruneDisk(now: Int64) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        var alive: [(URL, TimeInterval)] = []
        let nowSec = Double(now) / 1000.0
        let hitSec = Double(Self.hitTtlMs) / 1000.0
        for f in files where f.pathExtension == "json" {
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
            if nowSec - mtime > hitSec {
                try? FileManager.default.removeItem(at: f)
            } else {
                alive.append((f, mtime))
            }
        }
        if alive.count > Self.maxDiskFiles {
            let sorted = alive.sorted { $0.1 < $1.1 }
            for (f, _) in sorted.prefix(alive.count - Self.maxDiskFiles) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}

/// AI 智能识别客户端（1:1 对标 Android `AiRecognizerClient.kt`：防注入围栏、代理复用/独立代理、HTTP 诊断分级、熔断器与磁盘缓存）。
public actor AiRecognizerClient {
    public static let shared = AiRecognizerClient()

    private let injectedSession: URLSession?
    private var proxySessionCache: (key: String, session: URLSession)? = nil

    public init(session: URLSession? = nil) {
        self.injectedSession = session
    }

    /// 不可信文本防 Prompt 注入围栏（1:1 对标 Android `AiRecognizerClient.fenceUntrusted`）。
    public nonisolated static func fenceUntrusted(tag: String, value: String) -> String {
        let safe = value
            .replacingOccurrences(of: "<", with: "＜")
            .replacingOccurrences(of: ">", with: "＞")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "<\(tag)>\(String(safe.prefix(240)))</\(tag)>"
    }

    /// 按状态码与服务商分类可读中文错误（1:1 对标 Android `classifyHttpError`）。
    public nonisolated static func classifyHttpError(code: Int, bodySnippet: String, provider: String) -> String {
        let snippet = bodySnippet.lowercased()
        switch code {
        case 401:
            return "API Key 无效或已过期（HTTP 401），请在 AI 设置中核对密钥"
        case 402:
            return "\(provider) 账户余额不足或配额耗尽（HTTP 402）"
        case 403:
            if snippet.contains("country") || snippet.contains("region") || snippet.contains("location") || snippet.contains("territory") || snippet.contains("not available") {
                return "当前地区受限（HTTP 403），请在 AI 设置中开启代理或改用国内直连模型"
            }
            return "接口拒绝访问（HTTP 403），请检查密钥权限或地区代理"
        case 404:
            return "模型名称或接口路径不存在（HTTP 404），请检查模型名与接口地址"
        case 429:
            return "AI 请求过于频繁或触发限流（HTTP 429），已暂时退避"
        case 451:
            return "当前地区法律或政策受限（HTTP 451），请在 AI 设置中开启代理或改用国内直连模型"
        case 500...599:
            return "AI 服务端暂时不可用（HTTP \(code)），请稍后重试"
        default:
            return "AI 接口请求失败（HTTP \(code)）"
        }
    }

    public func clearCache() async {
        await AiRecognitionCache.shared.clearAll()
    }

    private func resolveProxySpec(cfg: AiRecognizerConfig) -> (type: String, host: String, port: Int)? {
        switch cfg.proxyType {
        case AiRecognizerConfig.proxyFollowTmdb:
            let tmdb = AppSettings.shared.tmdbNetConfig
            let t = tmdb.proxyType.lowercased()
            guard (t == "http" || t == "socks"), !tmdb.proxyHost.isEmpty, (1...65535).contains(tmdb.proxyPort) else { return nil }
            return (t, tmdb.proxyHost, tmdb.proxyPort)
        case AiRecognizerConfig.proxyHttp, AiRecognizerConfig.proxySocks:
            guard !cfg.proxyHost.isEmpty, (1...65535).contains(cfg.proxyPort) else { return nil }
            return (cfg.proxyType, cfg.proxyHost, cfg.proxyPort)
        default:
            return nil
        }
    }

    private func makeProxySession(proxy: (type: String, host: String, port: Int)) -> URLSession {
        let conf = URLSessionConfiguration.ephemeral
        conf.timeoutIntervalForRequest = 25
        conf.timeoutIntervalForResource = 35
        var dict: [AnyHashable: Any] = [:]
        if proxy.type == "socks" {
            dict["SOCKSEnable"] = 1
            dict["SOCKSProxy"] = proxy.host
            dict["SOCKSPort"] = proxy.port
        } else {
            dict["HTTPEnable"] = 1
            dict["HTTPProxy"] = proxy.host
            dict["HTTPPort"] = proxy.port
            dict["HTTPSEnable"] = 1
            dict["HTTPSProxy"] = proxy.host
            dict["HTTPSPort"] = proxy.port
        }
        conf.connectionProxyDictionary = dict
        return URLSession(configuration: conf)
    }

    private func sessionFor(cfg: AiRecognizerConfig, ephemeral: Bool = false) -> (session: URLSession, owned: Bool) {
        if let injectedSession { return (injectedSession, false) }
        guard let proxy = resolveProxySpec(cfg: cfg) else {
            if !ephemeral {
                if let old = proxySessionCache?.session {
                    Task.detached { try? await Task.sleep(nanoseconds: 5_000_000_000); old.finishTasksAndInvalidate() }
                }
                proxySessionCache = nil
            }
            return (.shared, false)
        }
        if ephemeral {
            return (makeProxySession(proxy: proxy), true)
        }
        let cacheKey = "\(proxy.type)|\(proxy.host)|\(proxy.port)"
        if let cached = proxySessionCache, cached.key == cacheKey {
            return (cached.session, false)
        }
        let s = makeProxySession(proxy: proxy)
        if let old = proxySessionCache?.session {
            Task.detached { try? await Task.sleep(nanoseconds: 5_000_000_000); old.finishTasksAndInvalidate() }
        }
        proxySessionCache = (cacheKey, s)
        return (s, false)
    }

    public func testConnection(config: AiRecognizerConfig? = nil, apiKey: String? = nil) async -> Result<String, Error> {
        let cfg = (config ?? AppSettings.shared.aiConfig).sanitized()
        let key = (apiKey ?? KeychainStore.aiApiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = AiProviderPreset.of(cfg.provider)
        if let urlErr = AiRecognizerConfig.validateBaseUrl(cfg.baseUrl) {
            return .failure(DriveError.invalidInput(urlErr))
        }
        if preset.id != "ollama" && key.isEmpty {
            return .failure(DriveError.invalidInput("请先填写 API Key"))
        }
        await AiRecognitionCache.shared.resetCircuit()
        do {
            let reply = try await chat(prompt: "请只回复 OK", maxTokens: 16, config: cfg, apiKey: key, ephemeralSession: true)
            return .success("连接成功（\(preset.label)：\(reply.prefix(24))）")
        } catch {
            return .failure(error)
        }
    }

    /// 通用低层 LLM 补全入口（带熔断保护、代理路由与传输错误诊断，供单文件/批量/重排/合集四路共享）。
    public func complete(
        prompt: String,
        maxTokens: Int = 512,
        config: AiRecognizerConfig? = nil,
        apiKey: String? = nil
    ) async -> String? {
        let cfg = (config ?? AppSettings.shared.aiConfig).sanitized()
        guard cfg.enabled else { return nil }
        let key = (apiKey ?? KeychainStore.aiApiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = AiProviderPreset.of(cfg.provider)
        if preset.id != "ollama" && key.isEmpty { return nil }
        if AiRecognizerConfig.validateBaseUrl(cfg.baseUrl) != nil { return nil }
        if await AiRecognitionCache.shared.isCircuitOpen() { return nil }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let reply = try await chat(prompt: prompt, maxTokens: maxTokens, config: cfg, apiKey: key)
            let ms = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            await AiRecognitionDiagnostics.shared.recordAiLatency(ms)
            return reply
        } catch is CancellationError {
            return nil
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return nil
        } catch {
            let safeMsg = NetLog.redactSecrets(error.localizedDescription)
            let shouldTrip: Bool
            if case let DriveError.api(code, _) = error {
                shouldTrip = (code == 401 || code == 403 || code == 429 || code == 451 || (500...599).contains(code))
            } else {
                shouldTrip = true
            }
            if shouldTrip {
                await AiRecognitionCache.shared.tripCircuit(reason: safeMsg)
            }
            await AiRecognitionDiagnostics.shared.recordTransportError(safeMsg)
            await NetLog.shared.error("AI", safeMsg)
            return nil
        }
    }

    public func inferTitle(rawName: String, folderName: String?) async -> AiRecognitionHint? {
        let cfg = AppSettings.shared.aiConfig.sanitized()
        guard cfg.enabled else { return nil }
        guard let guess = await HybridRecognitionOrchestrator.assistTitleExtraction(
            rawName: rawName,
            folderName: folderName,
            expectedKind: nil,
            config: cfg,
            apiKey: KeychainStore.aiApiKey,
            client: self
        ) else {
            return nil
        }
        return AiRecognitionHint(
            title: guess.title,
            year: guess.year.flatMap(Int.init),
            mediaType: guess.kind.isEmpty ? "movie" : guess.kind,
            season: guess.season,
            episode: guess.episode
        )
    }

    private func chat(prompt: String, maxTokens: Int, config: AiRecognizerConfig, apiKey: String, ephemeralSession: Bool = false) async throws -> String {
        let preset = AiProviderPreset.of(config.provider)
        let base = AiRecognizerConfig.normalizeBaseUrl(config.baseUrl.isEmpty ? preset.defaultBaseUrl : config.baseUrl)
        let model = config.model.isEmpty ? preset.defaultModel : config.model
        guard !base.isEmpty else { throw DriveError.invalidInput("请填写 AI 接口地址") }
        let (sess, owned) = sessionFor(cfg: config, ephemeral: ephemeralSession)
        defer { if owned { sess.finishTasksAndInvalidate() } }

        if preset.isGeminiNative {
            guard let url = URL(string: "\(base)/models/\(model):generateContent") else {
                throw DriveError.invalidInput("无效的 Gemini 接口地址")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 25
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") }
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["maxOutputTokens": maxTokens, "temperature": 0.1],
            ])
            let (data, resp) = try await sess.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else {
                let snippet = String(data: data.prefix(240), encoding: .utf8) ?? ""
                throw DriveError.api(code: code, message: Self.classifyHttpError(code: code, bodySnippet: snippet, provider: preset.label))
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let cands = obj?["candidates"] as? [[String: Any]]
            let content = cands?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            let text = (parts?.first?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DriveError.network("Gemini 返回内容为空，请检查接口地址或模型配置") }
            return text
        } else {
            let apiBase: String
            if preset.id == "ollama", !base.lowercased().hasSuffix("/v1") {
                apiBase = "\(base)/v1"
            } else {
                apiBase = base
            }
            guard let url = URL(string: "\(apiBase)/chat/completions") else {
                throw DriveError.invalidInput("无效的 AI 接口地址")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 25
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [["role": "user", "content": prompt]],
                "temperature": 0.1,
                "max_tokens": maxTokens,
            ])
            let (data, resp) = try await sess.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else {
                let snippet = String(data: data.prefix(240), encoding: .utf8) ?? ""
                throw DriveError.api(code: code, message: Self.classifyHttpError(code: code, bodySnippet: snippet, provider: preset.label))
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = obj?["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            let text = (msg?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DriveError.network("AI 接口返回内容为空，请检查协议类型或模型名") }
            return text
        }
    }
}
