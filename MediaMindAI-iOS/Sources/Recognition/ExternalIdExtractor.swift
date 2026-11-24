import Foundation

/// 1:1 逐行复刻自 Android `ExternalIdExtractor.kt`（101 行）：
/// 外部平台 ID（TMDB / IMDb / TVDB / Douban / Bangumi）与 Kodi/Jellyfin NFO Sidecar 提取器。
public enum ExternalIdExtractor {
    public struct ExternalIds: Equatable, Sendable {
        public let tmdbId: Int?
        public let tmdbKind: String? // "tv" / "movie" / nil
        public let imdbId: String?   // e.g. "tt1375666"
        public let tvdbId: Int?
        public let doubanId: String?
        public let bangumiId: Int?

        public var hasAny: Bool {
            tmdbId != nil || imdbId != nil || tvdbId != nil || doubanId != nil || bangumiId != nil
        }


        public init(
            tmdbId: Int? = nil,
            tmdbKind: String? = nil,
            imdbId: String? = nil,
            tvdbId: Int? = nil,
            doubanId: String? = nil,
            bangumiId: Int? = nil
        ) {
            self.tmdbId = tmdbId
            self.tmdbKind = tmdbKind
            self.imdbId = imdbId
            self.tvdbId = tvdbId
            self.doubanId = doubanId
            self.bangumiId = bangumiId
        }
    }

    private static let imdbTag = try! NSRegularExpression(
        pattern: #"(?i)(?:[\{\[\(（【](?:imdb(?:id)?[=:_ -]?)?(tt\d{6,9})[\}\]\）\)】]|(?<![A-Za-z0-9])(tt\d{7,9})(?![A-Za-z0-9]))"#
    )
    private static let tvdbTag = try! NSRegularExpression(
        pattern: #"(?i)[\{\[\(（【]?tvdb(?:id)?[=:_ -]?(\d{3,9})[\}\]\）\)】]?"#
    )
    private static let doubanTag = try! NSRegularExpression(
        pattern: #"(?i)(?:[\{\[\(（【]?douban(?:id)?[=:_ -]?(\d{5,10})[\}\]\）\)】]?|movie\.douban\.com/subject/(\d{5,10}))"#
    )
    private static let bgmTag = try! NSRegularExpression(
        pattern: #"(?i)(?:[\{\[\(（【]?(?:bgm|bangumi)(?:id)?[=:_ -]?(\d{2,8})[\}\]\）\)】]?|(?:bgm\.tv|bangumi\.tv)/subject/(\d{2,8}))"#
    )

    // NFO XML 标签
    private static let xmlUniqueId = try! NSRegularExpression(
        pattern: #"(?i)<uniqueid\b[^>]*\btype\s*=\s*["'](tmdb|imdb|tvdb|douban|bangumi)["'][^>]*>\s*([^<\s]+)\s*</uniqueid>"#
    )
    private static let xmlTmdbId = try! NSRegularExpression(pattern: #"(?i)<tmdbid>\s*(\d+)\s*</tmdbid>"#)
    private static let xmlImdbId = try! NSRegularExpression(pattern: #"(?i)<imdb_?id>\s*(tt\d{6,9})\s*</imdb_?id>"#)
    private static let xmlTvdbId = try! NSRegularExpression(pattern: #"(?i)<tvdbid>\s*(\d+)\s*</tvdbid>"#)
    /// Jellyfin Issue #5347 守卫：legacy `<id>` 仅在严格匹配 `tt\d+` 时才当成 IMDb ID，绝不把纯数字误当 IMDb。
    private static let xmlLegacyImdb = try! NSRegularExpression(pattern: #"(?i)<id>\s*(tt\d{6,9})\s*</id>"#)
    private static let tmdbUrlRx = try! NSRegularExpression(pattern: #"(?i)themoviedb\.org/(movie|tv)/(\d+)"#)
    private static let imdbUrlRx = try! NSRegularExpression(pattern: #"(?i)imdb\.com/title/(tt\d{6,9})"#)

    public static func fromName(_ name: String) -> ExternalIds {
        let tmdb = MediaParser.tmdbHint(name)
        let ns = name as NSString
        let full = NSRange(location: 0, length: ns.length)

        var imdb: String? = nil
        if let m = imdbTag.firstMatch(in: name, range: full) {
            let g1 = group(ns, m, 1)
            let raw = g1.isEmpty ? group(ns, m, 2) : g1
            let lowered = raw.lowercased()
            if lowered.hasPrefix("tt") { imdb = lowered }
        }

        let tvdb: Int? = tvdbTag.firstMatch(in: name, range: full).flatMap { Int(group(ns, $0, 1)) }

        var douban: String? = nil
        if let m = doubanTag.firstMatch(in: name, range: full) {
            let g1 = group(ns, m, 1)
            let raw = g1.isEmpty ? group(ns, m, 2) : g1
            if !raw.isEmpty { douban = raw }
        }

        var bgm: Int? = nil
        if let m = bgmTag.firstMatch(in: name, range: full) {
            let g1 = group(ns, m, 1)
            let raw = g1.isEmpty ? group(ns, m, 2) : g1
            bgm = Int(raw)
        }

        return ExternalIds(
            tmdbId: tmdb?.id,
            tmdbKind: tmdb?.kind,
            imdbId: imdb,
            tvdbId: tvdb,
            doubanId: douban,
            bangumiId: bgm
        )
    }

    /// 从 Kodi/Jellyfin/Emby 风格 NFO 内容（XML 或混合 URL NFO）提取外部 ID。
    public static func fromNfo(_ nfoContentRaw: String) -> ExternalIds {
        let nfoContent = nfoContentRaw.count > 65_536 ? String(nfoContentRaw.prefix(65_536)) : nfoContentRaw
        let ns = nfoContent as NSString
        let full = NSRange(location: 0, length: ns.length)

        var tmdbId: Int? = nil
        var imdbId: String? = nil
        var tvdbId: Int? = nil
        var doubanId: String? = nil
        var bangumiId: Int? = nil

        let lower = nfoContent.lowercased()
        let tmdbKind: String?
        if lower.contains("<tvshow") {
            tmdbKind = "tv"
        } else if lower.contains("<movie") {
            tmdbKind = "movie"
        } else {
            tmdbKind = nil
        }

        for m in xmlUniqueId.matches(in: nfoContent, range: full) {
            let type = group(ns, m, 1).lowercased()
            let value = group(ns, m, 2).trimmingCharacters(in: .whitespacesAndNewlines)
            switch type {
            case "tmdb":
                if tmdbId == nil { tmdbId = Int(value) }
            case "imdb":
                if imdbId == nil && value.lowercased().hasPrefix("tt") { imdbId = value.lowercased() }
            case "tvdb":
                if tvdbId == nil { tvdbId = Int(value) }
            case "douban":
                if doubanId == nil && !value.isEmpty && value.allSatisfy({ $0.isNumber }) { doubanId = value }
            case "bangumi":
                if bangumiId == nil { bangumiId = Int(value) }
            default:
                break
            }
        }

        if tmdbId == nil, let m = xmlTmdbId.firstMatch(in: nfoContent, range: full) {
            tmdbId = Int(group(ns, m, 1))
        }
        if imdbId == nil {
            if let m = xmlImdbId.firstMatch(in: nfoContent, range: full) {
                imdbId = group(ns, m, 1).lowercased()
            } else if let m = xmlLegacyImdb.firstMatch(in: nfoContent, range: full) {
                imdbId = group(ns, m, 1).lowercased()
            }
        }
        if tvdbId == nil, let m = xmlTvdbId.firstMatch(in: nfoContent, range: full) {
            tvdbId = Int(group(ns, m, 1))
        }

        // 兜底：Combination/Mixed NFO 末尾直接附带 TMDB / IMDb / Douban URL
        if tmdbId == nil, let m = tmdbUrlRx.firstMatch(in: nfoContent, range: full) {
            tmdbId = Int(group(ns, m, 2))
        }
        if imdbId == nil, let m = imdbUrlRx.firstMatch(in: nfoContent, range: full) {
            imdbId = group(ns, m, 1).lowercased()
        }
        if doubanId == nil, let m = doubanTag.firstMatch(in: nfoContent, range: full) {
            let g1 = group(ns, m, 1)
            let raw = g1.isEmpty ? group(ns, m, 2) : g1
            if !raw.isEmpty { doubanId = raw }
        }
        if bangumiId == nil, let m = bgmTag.firstMatch(in: nfoContent, range: full) {
            let g1 = group(ns, m, 1)
            let raw = g1.isEmpty ? group(ns, m, 2) : g1
            bangumiId = Int(raw)
        }

        return ExternalIds(
            tmdbId: tmdbId,
            tmdbKind: tmdbKind,
            imdbId: imdbId,
            tvdbId: tvdbId,
            doubanId: doubanId,
            bangumiId: bangumiId
        )
    }

    /// 合并两个来源的外部 ID（以优先级更高者为准）。
    public static func merge(primary: ExternalIds, fallback: ExternalIds) -> ExternalIds {
        ExternalIds(
            tmdbId: primary.tmdbId ?? fallback.tmdbId,
            tmdbKind: primary.tmdbKind ?? fallback.tmdbKind,
            imdbId: primary.imdbId ?? fallback.imdbId,
            tvdbId: primary.tvdbId ?? fallback.tvdbId,
            doubanId: primary.doubanId ?? fallback.doubanId,
            bangumiId: primary.bangumiId ?? fallback.bangumiId
        )
    }

    private static func group(_ ns: NSString, _ match: NSTextCheckingResult, _ idx: Int) -> String {
        guard idx < match.numberOfRanges else { return "" }
        let r = match.range(at: idx)
        guard r.location != NSNotFound else { return "" }
        return ns.substring(with: r)
    }
}
