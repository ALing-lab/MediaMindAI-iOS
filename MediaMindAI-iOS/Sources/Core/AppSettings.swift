import Foundation
import Observation

public enum AppThemeMode: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

public enum ImageQualityOption: String, CaseIterable, Codable, Sendable {
    case compact
    case standard
    case original

    public var label: String {
        switch self {
        case .compact: return "省流"
        case .standard: return "高清"
        case .original: return "原图"
        }
    }

    public var posterSize: String {
        switch self {
        case .compact: return "w500"
        case .standard: return "w780"
        case .original: return "original"
        }
    }

    public var backdropSize: String {
        switch self {
        case .compact: return "w780"
        case .standard: return "w1280"
        case .original: return "original"
        }
    }
}

/// 全局应用设置（1:1 对标 Android Settings + DefaultPolicies 三级策略第 1 层 + NfoFields + TmdbNetConfig + AiRecognizerConfig）。
@Observable
public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // 外观主题（浅色 / 深色 / 跟随系统）
    public var themeMode: AppThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: "app_theme_mode") }
    }

    // 扫描限流
    public var scanAutomatic: Bool {
        didSet { defaults.set(scanAutomatic, forKey: "scan_auto") }
    }

    // 第 1 层：全局默认策略（完整包含电影/剧集独立 MediaNamingPrefs 与 MediaDefaults）
    public var policies: DefaultPolicies {
        didSet {
            if let d = try? JSONEncoder().encode(policies) {
                defaults.set(d, forKey: "global_default_policies_v2")
            }
        }
    }

    // NFO 精细字段过滤
    public var nfoFields: NfoFieldSelection {
        didSet {
            if let d = try? JSONEncoder().encode(nfoFields) {
                defaults.set(d, forKey: "policy_nfo_fields")
            }
        }
    }

    public var rememberHistory: Bool {
        didSet {
            let val = rememberHistory
            defaults.set(val, forKey: "history_enabled")
            Task { @MainActor in HistoryStore.shared.setEnabled(val) }
        }
    }

    // 便捷桥接属性（统一映射到 policies，保证所有调用方单一数据源无冲突）
    public var appendTmdbTag: Bool {
        get { policies.movieNaming.folderTmdbEnabled }
        set {
            policies.movieNaming.folderTmdbEnabled = newValue
            policies.movieNaming.fileTmdbEnabled = newValue
            policies.tvNaming.folderTmdbEnabled = newValue
            policies.tvNaming.fileTmdbEnabled = newValue
        }
    }
    public var mergeSameSeries: Bool {
        get { policies.mergeSeries }
        set { policies.mergeSeries = newValue }
    }
    public var writeNfo: Bool {
        get { policies.movie.nfo }
        set { policies.movie.nfo = newValue; policies.tv.nfo = newValue }
    }
    public var downloadPoster: Bool {
        get { policies.movie.poster }
        set { policies.movie.poster = newValue; policies.tv.poster = newValue }
    }
    public var downloadFanart: Bool {
        get { policies.movie.fanart }
        set { policies.movie.fanart = newValue; policies.tv.fanart = newValue }
    }
    public var downloadClearlogo: Bool {
        get { policies.movie.logo }
        set { policies.movie.logo = newValue; policies.tv.logo = newValue }
    }
    public var downloadEpisodeThumb: Bool {
        get { policies.episodeThumb }
        set { policies.episodeThumb = newValue }
    }
    public var imageQuality: ImageQualityOption {
        get { policies.imageQuality }
        set { policies.imageQuality = newValue }
    }

    // TMDB 网络（完整持久化 TmdbNetConfig + 调试日志落盘开关）
    public var tmdbApiBase: String {
        didSet { defaults.set(tmdbApiBase, forKey: "tmdb_api_base"); syncTmdbNet() }
    }
    public var tmdbImageBase: String {
        didSet { defaults.set(tmdbImageBase, forKey: "tmdb_img_base"); syncTmdbNet() }
    }
    public var tmdbImageFallback: String {
        didSet { defaults.set(tmdbImageFallback, forKey: "tmdb_img_fallback"); syncTmdbNet() }
    }
    public var tmdbPublicMirrors: Bool {
        didSet { defaults.set(tmdbPublicMirrors, forKey: "tmdb_public_mirrors"); syncTmdbNet() }
    }
    public var tmdbProxyType: String {
        didSet { defaults.set(tmdbProxyType, forKey: "tmdb_proxy_type"); syncTmdbNet() }
    }
    public var tmdbProxyHost: String {
        didSet { defaults.set(tmdbProxyHost, forKey: "tmdb_proxy_host"); syncTmdbNet() }
    }
    public var tmdbProxyPort: Int {
        didSet { defaults.set(tmdbProxyPort, forKey: "tmdb_proxy_port"); syncTmdbNet() }
    }
    public var tmdbLanguage: String {
        didSet { defaults.set(tmdbLanguage, forKey: "tmdb_lang") }
    }
    public var netLogFileEnabled: Bool {
        didSet {
            defaults.set(netLogFileEnabled, forKey: "net_log_file_enabled")
            let enabled = netLogFileEnabled
            Task { await NetLog.shared.setFileEnabled(enabled) }
        }
    }

    public var tmdbNetConfig: TmdbNetConfig {
        TmdbNetConfig(
            apiBase: tmdbApiBase,
            imageBase: tmdbImageBase,
            imageFallback: tmdbImageFallback,
            publicMirrors: tmdbPublicMirrors,
            proxyType: tmdbProxyType,
            proxyHost: tmdbProxyHost,
            proxyPort: tmdbProxyPort
        ).normalized()
    }

    private func syncTmdbNet() {
        let cfg = tmdbNetConfig
        Task { await TmdbNet.shared.apply(cfg) }
    }

    // AI 智能识别（1:1 对标 Android AiRecognizerConfig）
    public var aiEnabled: Bool {
        didSet { defaults.set(aiEnabled, forKey: "ai_enabled") }
    }
    public var aiProviderId: String {
        didSet { defaults.set(aiProviderId, forKey: "ai_provider") }
    }
    public var aiBaseUrl: String {
        didSet { defaults.set(aiBaseUrl, forKey: "ai_base_url") }
    }
    public var aiModel: String {
        didSet { defaults.set(aiModel, forKey: "ai_model") }
    }
    public var aiProxyType: String {
        didSet { defaults.set(aiProxyType, forKey: "ai_proxy_type") }
    }
    public var aiProxyHost: String {
        didSet { defaults.set(aiProxyHost, forKey: "ai_proxy_host") }
    }
    public var aiProxyPort: Int {
        didSet { defaults.set(aiProxyPort, forKey: "ai_proxy_port") }
    }
    public var aiMaxCallsPerScan: Int {
        didSet { defaults.set(aiMaxCallsPerScan, forKey: "ai_max_calls_per_scan") }
    }
    public var aiEnableCandidateRerank: Bool {
        didSet { defaults.set(aiEnableCandidateRerank, forKey: "ai_enable_rerank") }
    }
    public var aiEnableRuleDistillation: Bool {
        didSet { defaults.set(aiEnableRuleDistillation, forKey: "ai_enable_distill") }
    }
    public var aiAutoTriggerThreshold: Double {
        didSet { defaults.set(aiAutoTriggerThreshold, forKey: "ai_auto_trigger_threshold") }
    }

    public var aiConfig: AiRecognizerConfig {
        AiRecognizerConfig(
            enabled: aiEnabled,
            provider: aiProviderId,
            baseUrl: aiBaseUrl,
            model: aiModel,
            proxyType: aiProxyType,
            proxyHost: aiProxyHost,
            proxyPort: aiProxyPort,
            autoTriggerThreshold: aiAutoTriggerThreshold,
            enableCandidateRerank: aiEnableCandidateRerank,
            enableRuleDistillation: aiEnableRuleDistillation,
            maxCallsPerScan: aiMaxCallsPerScan
        ).sanitized()
    }

    private init() {
        self.themeMode = AppThemeMode(rawValue: defaults.string(forKey: "app_theme_mode") ?? "") ?? .system
        self.scanAutomatic = defaults.object(forKey: "scan_auto") as? Bool ?? true
        if let d = defaults.data(forKey: "global_default_policies_v2"),
           let p = try? JSONDecoder().decode(DefaultPolicies.self, from: d) {
            self.policies = p
        } else {
            self.policies = DefaultPolicies()
        }
        if let d = defaults.data(forKey: "policy_nfo_fields"),
           let f = try? JSONDecoder().decode(NfoFieldSelection.self, from: d) {
            self.nfoFields = f
        } else {
            self.nfoFields = NfoFieldSelection()
        }
        self.rememberHistory = defaults.object(forKey: "history_enabled") as? Bool ?? true
        HistoryStore.shared.setEnabled(self.rememberHistory)
        self.tmdbApiBase = defaults.string(forKey: "tmdb_api_base") ?? TmdbNetConfig.altApi
        self.tmdbImageBase = defaults.string(forKey: "tmdb_img_base") ?? TmdbNetConfig.defaultImage
        self.tmdbImageFallback = defaults.string(forKey: "tmdb_img_fallback") ?? ""
        self.tmdbPublicMirrors = defaults.object(forKey: "tmdb_public_mirrors") as? Bool ?? false
        self.tmdbProxyType = defaults.string(forKey: "tmdb_proxy_type") ?? "none"
        self.tmdbProxyHost = defaults.string(forKey: "tmdb_proxy_host") ?? ""
        self.tmdbProxyPort = defaults.integer(forKey: "tmdb_proxy_port")
        self.tmdbLanguage = defaults.string(forKey: "tmdb_lang") ?? "zh-CN"
        self.netLogFileEnabled = defaults.object(forKey: "net_log_file_enabled") as? Bool ?? false
        self.aiEnabled = defaults.object(forKey: "ai_enabled") as? Bool ?? false
        self.aiProviderId = defaults.string(forKey: "ai_provider") ?? "deepseek"
        self.aiBaseUrl = defaults.string(forKey: "ai_base_url") ?? "https://api.deepseek.com/v1"
        self.aiModel = defaults.string(forKey: "ai_model") ?? "deepseek-chat"
        self.aiProxyType = defaults.string(forKey: "ai_proxy_type") ?? AiRecognizerConfig.proxyNone
        self.aiProxyHost = defaults.string(forKey: "ai_proxy_host") ?? ""
        self.aiProxyPort = defaults.integer(forKey: "ai_proxy_port")
        self.aiMaxCallsPerScan = defaults.object(forKey: "ai_max_calls_per_scan") as? Int ?? 30
        self.aiEnableCandidateRerank = defaults.object(forKey: "ai_enable_rerank") as? Bool ?? true
        self.aiEnableRuleDistillation = defaults.object(forKey: "ai_enable_distill") as? Bool ?? true
        self.aiAutoTriggerThreshold = defaults.object(forKey: "ai_auto_trigger_threshold") as? Double ?? 0.60
    }

    public func imageUrl(path: String, size: String? = nil) -> URL? {
        let clean = path.hasPrefix("/") ? path : "/\(path)"
        let base = tmdbNetConfig.imageBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resolvedSize = size ?? imageQuality.posterSize
        return URL(string: "\(base)/t/p/\(resolvedSize)\(clean)")
    }
}
