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

    private let defaults: UserDefaults
    @ObservationIgnored private let settingsLock = NSRecursiveLock()

    private func locked<T>(_ body: () -> T) -> T {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return body()
    }

    private func read<Value>(_ keyPath: KeyPath<AppSettings, Value>, _ value: () -> Value) -> Value {
        access(keyPath: keyPath)
        return locked(value)
    }

    private func update<Value>(_ keyPath: KeyPath<AppSettings, Value>, _ mutation: () -> Void) {
        withMutation(keyPath: keyPath) { locked(mutation) }
    }

    // 外观主题（浅色 / 深色 / 跟随系统）
    @ObservationIgnored private var stored_themeMode: AppThemeMode = .system
    public var themeMode: AppThemeMode {
        get { read(\.themeMode) { stored_themeMode } }
        set {
            update(\.themeMode) {
                stored_themeMode = newValue
                defaults.set(themeMode.rawValue, forKey: "app_theme_mode")
            }
        }
    }

    // 扫描限流
    @ObservationIgnored private var stored_scanAutomatic: Bool = false
    public var scanAutomatic: Bool {
        get { read(\.scanAutomatic) { stored_scanAutomatic } }
        set {
            update(\.scanAutomatic) {
                stored_scanAutomatic = newValue
                defaults.set(scanAutomatic, forKey: "scan_auto")
            }
        }
    }

    // 第 1 层：全局默认策略（完整包含电影/剧集独立 MediaNamingPrefs 与 MediaDefaults）
    @ObservationIgnored private var stored_policies: DefaultPolicies = DefaultPolicies()
    public var policies: DefaultPolicies {
        get { read(\.policies) { stored_policies } }
        set {
            update(\.policies) {
                stored_policies = newValue
                if let d = try? JSONEncoder().encode(policies) {
                    defaults.set(d, forKey: "global_default_policies_v2")
                }
            }
        }
    }

    // NFO 精细字段过滤
    @ObservationIgnored private var stored_nfoFields: NfoFieldSelection = NfoFieldSelection()
    public var nfoFields: NfoFieldSelection {
        get { read(\.nfoFields) { stored_nfoFields } }
        set {
            update(\.nfoFields) {
                stored_nfoFields = newValue
                if let d = try? JSONEncoder().encode(nfoFields) {
                    defaults.set(d, forKey: "policy_nfo_fields")
                }
            }
        }
    }

    @ObservationIgnored private var stored_rememberHistory: Bool = false
    public var rememberHistory: Bool {
        get { read(\.rememberHistory) { stored_rememberHistory } }
        set {
            update(\.rememberHistory) {
                stored_rememberHistory = newValue
                let val = rememberHistory
                defaults.set(val, forKey: "history_enabled")
                Task { @MainActor in HistoryStore.shared.setEnabled(val) }
            }
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
    @ObservationIgnored private var stored_tmdbApiBase: String = ""
    public var tmdbApiBase: String {
        get { read(\.tmdbApiBase) { stored_tmdbApiBase } }
        set {
            update(\.tmdbApiBase) {
                stored_tmdbApiBase = newValue
                defaults.set(tmdbApiBase, forKey: "tmdb_api_base"); syncTmdbNet()
            }
        }
    }
    @ObservationIgnored private var stored_tmdbImageBase: String = ""
    public var tmdbImageBase: String {
        get { read(\.tmdbImageBase) { stored_tmdbImageBase } }
        set {
            update(\.tmdbImageBase) {
                stored_tmdbImageBase = newValue
                defaults.set(tmdbImageBase, forKey: "tmdb_img_base"); syncTmdbNet()
            }
        }
    }
    @ObservationIgnored private var stored_tmdbImageFallback: String = ""
    public var tmdbImageFallback: String {
        get { read(\.tmdbImageFallback) { stored_tmdbImageFallback } }
        set {
            update(\.tmdbImageFallback) {
                stored_tmdbImageFallback = newValue
                defaults.set(tmdbImageFallback, forKey: "tmdb_img_fallback"); syncTmdbNet()
            }
        }
    }
    @ObservationIgnored private var stored_tmdbPublicMirrors: Bool = false
    public var tmdbPublicMirrors: Bool {
        get { read(\.tmdbPublicMirrors) { stored_tmdbPublicMirrors } }
        set {
            update(\.tmdbPublicMirrors) {
                stored_tmdbPublicMirrors = newValue
                defaults.set(tmdbPublicMirrors, forKey: "tmdb_public_mirrors"); syncTmdbNet()
            }
        }
    }
    @ObservationIgnored private var stored_tmdbProxyType: String = ""
    public var tmdbProxyType: String {
        get { read(\.tmdbProxyType) { stored_tmdbProxyType } }
        set {
            update(\.tmdbProxyType) {
                stored_tmdbProxyType = newValue
                defaults.set(tmdbProxyType, forKey: "tmdb_proxy_type"); syncTmdbNet()
            }
        }
    }
    @ObservationIgnored private var stored_tmdbProxyHost: String = ""
    public var tmdbProxyHost: String {
        get { read(\.tmdbProxyHost) { stored_tmdbProxyHost } }
        set {
            update(\.tmdbProxyHost) {
                stored_tmdbProxyHost = newValue
                defaults.set(tmdbProxyHost, forKey: "tmdb_proxy_host"); syncTmdbNet()
            }
        }
    }
    @ObservationIgnored private var stored_tmdbProxyPort: Int = 0
    public var tmdbProxyPort: Int {
        get { read(\.tmdbProxyPort) { stored_tmdbProxyPort } }
        set {
            update(\.tmdbProxyPort) {
                stored_tmdbProxyPort = newValue
                defaults.set(tmdbProxyPort, forKey: "tmdb_proxy_port"); syncTmdbNet()
            }
        }
    }
    @ObservationIgnored private var stored_tmdbLanguage: String = ""
    public var tmdbLanguage: String {
        get { read(\.tmdbLanguage) { stored_tmdbLanguage } }
        set {
            update(\.tmdbLanguage) {
                stored_tmdbLanguage = newValue
                defaults.set(tmdbLanguage, forKey: "tmdb_lang")
            }
        }
    }
    @ObservationIgnored private var stored_netLogFileEnabled: Bool = false
    public var netLogFileEnabled: Bool {
        get { read(\.netLogFileEnabled) { stored_netLogFileEnabled } }
        set {
            update(\.netLogFileEnabled) {
                stored_netLogFileEnabled = newValue
                defaults.set(netLogFileEnabled, forKey: "net_log_file_enabled")
                let enabled = netLogFileEnabled
                Task { await NetLog.shared.setFileEnabled(enabled) }
            }
        }
    }

    public var tmdbNetConfig: TmdbNetConfig {
        locked {
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
    }

    private func syncTmdbNet() {
        let cfg = tmdbNetConfig
        Task {
            await TmdbNet.shared.apply(cfg)
            await TmdbClient.shared.resetFailures()
        }
    }

    // AI 智能识别（1:1 对标 Android AiRecognizerConfig）
    @ObservationIgnored private var stored_aiEnabled: Bool = false
    public var aiEnabled: Bool {
        get { read(\.aiEnabled) { stored_aiEnabled } }
        set {
            update(\.aiEnabled) {
                stored_aiEnabled = newValue
                defaults.set(aiEnabled, forKey: "ai_enabled")
            }
        }
    }
    @ObservationIgnored private var stored_aiProviderId: String = ""
    public var aiProviderId: String {
        get { read(\.aiProviderId) { stored_aiProviderId } }
        set {
            update(\.aiProviderId) {
                stored_aiProviderId = newValue
                defaults.set(aiProviderId, forKey: "ai_provider")
            }
        }
    }
    @ObservationIgnored private var stored_aiBaseUrl: String = ""
    public var aiBaseUrl: String {
        get { read(\.aiBaseUrl) { stored_aiBaseUrl } }
        set {
            update(\.aiBaseUrl) {
                stored_aiBaseUrl = newValue
                defaults.set(aiBaseUrl, forKey: "ai_base_url")
            }
        }
    }
    @ObservationIgnored private var stored_aiModel: String = ""
    public var aiModel: String {
        get { read(\.aiModel) { stored_aiModel } }
        set {
            update(\.aiModel) {
                stored_aiModel = newValue
                defaults.set(aiModel, forKey: "ai_model")
            }
        }
    }
    @ObservationIgnored private var stored_aiProxyType: String = ""
    public var aiProxyType: String {
        get { read(\.aiProxyType) { stored_aiProxyType } }
        set {
            update(\.aiProxyType) {
                stored_aiProxyType = newValue
                defaults.set(aiProxyType, forKey: "ai_proxy_type")
            }
        }
    }
    @ObservationIgnored private var stored_aiProxyHost: String = ""
    public var aiProxyHost: String {
        get { read(\.aiProxyHost) { stored_aiProxyHost } }
        set {
            update(\.aiProxyHost) {
                stored_aiProxyHost = newValue
                defaults.set(aiProxyHost, forKey: "ai_proxy_host")
            }
        }
    }
    @ObservationIgnored private var stored_aiProxyPort: Int = 0
    public var aiProxyPort: Int {
        get { read(\.aiProxyPort) { stored_aiProxyPort } }
        set {
            update(\.aiProxyPort) {
                stored_aiProxyPort = newValue
                defaults.set(aiProxyPort, forKey: "ai_proxy_port")
            }
        }
    }
    @ObservationIgnored private var stored_aiMaxCallsPerScan: Int = 0
    public var aiMaxCallsPerScan: Int {
        get { read(\.aiMaxCallsPerScan) { stored_aiMaxCallsPerScan } }
        set {
            update(\.aiMaxCallsPerScan) {
                stored_aiMaxCallsPerScan = newValue
                defaults.set(aiMaxCallsPerScan, forKey: "ai_max_calls_per_scan")
            }
        }
    }
    @ObservationIgnored private var stored_aiEnableCandidateRerank: Bool = false
    public var aiEnableCandidateRerank: Bool {
        get { read(\.aiEnableCandidateRerank) { stored_aiEnableCandidateRerank } }
        set {
            update(\.aiEnableCandidateRerank) {
                stored_aiEnableCandidateRerank = newValue
                defaults.set(aiEnableCandidateRerank, forKey: "ai_enable_rerank")
            }
        }
    }
    @ObservationIgnored private var stored_aiEnableRuleDistillation: Bool = false
    public var aiEnableRuleDistillation: Bool {
        get { read(\.aiEnableRuleDistillation) { stored_aiEnableRuleDistillation } }
        set {
            update(\.aiEnableRuleDistillation) {
                stored_aiEnableRuleDistillation = newValue
                defaults.set(aiEnableRuleDistillation, forKey: "ai_enable_distill")
            }
        }
    }
    @ObservationIgnored private var stored_aiAutoTriggerThreshold: Double = 0
    public var aiAutoTriggerThreshold: Double {
        get { read(\.aiAutoTriggerThreshold) { stored_aiAutoTriggerThreshold } }
        set {
            update(\.aiAutoTriggerThreshold) {
                stored_aiAutoTriggerThreshold = newValue
                defaults.set(aiAutoTriggerThreshold, forKey: "ai_auto_trigger_threshold")
            }
        }
    }

    public var aiConfig: AiRecognizerConfig {
        locked {
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
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.stored_themeMode = AppThemeMode(rawValue: defaults.string(forKey: "app_theme_mode") ?? "") ?? .system
        self.stored_scanAutomatic = defaults.object(forKey: "scan_auto") as? Bool ?? true
        if let d = defaults.data(forKey: "global_default_policies_v2"),
           let p = try? JSONDecoder().decode(DefaultPolicies.self, from: d) {
            self.stored_policies = p
        } else {
            self.stored_policies = DefaultPolicies()
        }
        if let d = defaults.data(forKey: "policy_nfo_fields"),
           let f = try? JSONDecoder().decode(NfoFieldSelection.self, from: d) {
            self.stored_nfoFields = f
        } else {
            self.stored_nfoFields = NfoFieldSelection()
        }
        let initRememberHistory = defaults.object(forKey: "history_enabled") as? Bool ?? true
        self.stored_rememberHistory = initRememberHistory
        Task { @MainActor in HistoryStore.shared.setEnabled(initRememberHistory) }
        self.stored_tmdbApiBase = defaults.string(forKey: "tmdb_api_base") ?? TmdbNetConfig.altApi
        self.stored_tmdbImageBase = defaults.string(forKey: "tmdb_img_base") ?? TmdbNetConfig.defaultImage
        self.stored_tmdbImageFallback = defaults.string(forKey: "tmdb_img_fallback") ?? ""
        self.stored_tmdbPublicMirrors = defaults.object(forKey: "tmdb_public_mirrors") as? Bool ?? false
        self.stored_tmdbProxyType = defaults.string(forKey: "tmdb_proxy_type") ?? "none"
        self.stored_tmdbProxyHost = defaults.string(forKey: "tmdb_proxy_host") ?? ""
        self.stored_tmdbProxyPort = defaults.integer(forKey: "tmdb_proxy_port")
        self.stored_tmdbLanguage = defaults.string(forKey: "tmdb_lang") ?? "zh-CN"
        self.stored_netLogFileEnabled = defaults.object(forKey: "net_log_file_enabled") as? Bool ?? false
        self.stored_aiEnabled = defaults.object(forKey: "ai_enabled") as? Bool ?? false
        self.stored_aiProviderId = defaults.string(forKey: "ai_provider") ?? "deepseek"
        self.stored_aiBaseUrl = defaults.string(forKey: "ai_base_url") ?? "https://api.deepseek.com/v1"
        self.stored_aiModel = defaults.string(forKey: "ai_model") ?? "deepseek-chat"
        self.stored_aiProxyType = defaults.string(forKey: "ai_proxy_type") ?? AiRecognizerConfig.proxyNone
        self.stored_aiProxyHost = defaults.string(forKey: "ai_proxy_host") ?? ""
        self.stored_aiProxyPort = defaults.integer(forKey: "ai_proxy_port")
        self.stored_aiMaxCallsPerScan = defaults.object(forKey: "ai_max_calls_per_scan") as? Int ?? 30
        self.stored_aiEnableCandidateRerank = defaults.object(forKey: "ai_enable_rerank") as? Bool ?? true
        self.stored_aiEnableRuleDistillation = defaults.object(forKey: "ai_enable_distill") as? Bool ?? true
        self.stored_aiAutoTriggerThreshold = defaults.object(forKey: "ai_auto_trigger_threshold") as? Double ?? 0.60
    }

    public func imageUrl(path: String, size: String? = nil) -> URL? {
        let clean = path.hasPrefix("/") ? path : "/\(path)"
        let base = tmdbNetConfig.imageBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resolvedSize = size ?? imageQuality.posterSize
        return URL(string: "\(base)/t/p/\(resolvedSize)\(clean)")
    }
}
