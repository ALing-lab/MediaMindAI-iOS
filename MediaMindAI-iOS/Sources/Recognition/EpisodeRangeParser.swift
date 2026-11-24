import Foundation

/// 1:1 逐行复刻自 Android `EpisodeRangeParser.kt`（100 行）：
/// 多集连号（Multi-Episode Range）与日期型综艺/日播节目解析器。
public enum EpisodeRangeParser {
    public struct ParsedEpisodes: Equatable, Sendable {
        public let season: Int?
        public let episodes: [Int]
        public let airDate: String? // YYYY-MM-DD（日期型综艺）

        public var primaryEpisode: Int { episodes.first ?? 0 }

        public init(season: Int?, episodes: [Int], airDate: String? = nil) {
            self.season = season
            self.episodes = episodes
            self.airDate = airDate
        }
    }

    /// S01E01-E03 / S01E01-03 / S01E01~03
    private static let seRange = try! NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9])S(\d{1,3})[ ._x-]*E(\d{1,4})(?:\s*[-~]\s*E?(\d{1,4}))(?![0-9])"#
    )
    /// S01E01E02E03（Kodi recursive tail 风格）
    private static let seRepeatHead = try! NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9])S(\d{1,3})[ ._x-]?E(\d{1,4})((?:[ ._x]?E\d{1,4}){1,12})"#
    )
    private static let repeatTail = try! NSRegularExpression(pattern: #"(?i)[ ._x-]*E(\d{1,4})"#)

    /// E01-E02 / EP01-02 / 第01-02集
    private static let eRange = try! NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9])EP?(\d{1,4})\s*[-~]\s*(?:EP?)?(\d{1,4})(?![0-9])"#
    )
    private static let cnRange = try! NSRegularExpression(
        pattern: #"第?\s*(\d{1,4})\s*[-~至到]\s*(\d{1,4})\s*[集话話期]"#
    )

    /// 日期型综艺：2025-05-12 / 2025.05.12 / 2025_05_12 / 20250512 / 第20250512期
    private static let dateEp = try! NSRegularExpression(
        pattern: #"(?<!\d)(19\d{2}|20[0-3]\d)([.\-_]?)(0[1-9]|1[0-2])\2(0[1-9]|[12]\d|3[01])(\s*期)?(?!\d)"#
    )

    public static func parse(_ stem: String, allowBareDate: Bool = false) -> ParsedEpisodes? {
        let masked = ReleaseTokenizer.maskTechnicalSpans(stem)
        let clean = masked.unmaskedText()
        let ns = clean as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 1. SxxExx-Eyy / SxxExx-yy 范围型多集（优先于重复型，避免 S01E01-E03 被误拆为 [1, 3]）
        if let m = seRange.firstMatch(in: clean, range: full),
           let a = Int(group(ns, m, 2)),
           let b = Int(group(ns, m, 3)),
           b >= a, (b - a) <= 24 {
            let s = Int(group(ns, m, 1))
            return ParsedEpisodes(season: s, episodes: Array(a...b))
        }

        // 2. SxxExxExx 重复型多集
        if let m = seRepeatHead.firstMatch(in: clean, range: full),
           let first = Int(group(ns, m, 2)) {
            let s = Int(group(ns, m, 1))
            let tailStr = group(ns, m, 3)
            let tailNs = tailStr as NSString
            let rest = repeatTail.matches(in: tailStr, range: NSRange(location: 0, length: tailNs.length))
                .compactMap { Int(group(tailNs, $0, 1)) }
            let all = Array(Set([first] + rest)).sorted()
            if all.count >= 2 {
                return ParsedEpisodes(season: s, episodes: all)
            }
        }

        // 3. E01-02 / 第01-02集
        if let m = eRange.firstMatch(in: clean, range: full),
           let a = Int(group(ns, m, 1)),
           let b = Int(group(ns, m, 2)),
           b >= a, (b - a) <= 24 {
            return ParsedEpisodes(season: MediaParser.seasonFromName(clean), episodes: Array(a...b))
        }
        if let m = cnRange.firstMatch(in: clean, range: full),
           let a = Int(group(ns, m, 1)),
           let b = Int(group(ns, m, 2)),
           b >= a, (b - a) <= 24 {
            return ParsedEpisodes(season: MediaParser.seasonFromName(clean), episodes: Array(a...b))
        }

        // 4. 日期型综艺/日播（守卫 C1：单文件默认要求带「期」后缀防电影发布日期误判）
        if let m = dateEp.firstMatch(in: clean, range: full) {
            let hasQiSuffix = !group(ns, m, 5).trimmingCharacters(in: .whitespaces).isEmpty
            if hasQiSuffix || allowBareDate,
               let y = Int(group(ns, m, 1)),
               let mo = Int(group(ns, m, 3)),
               let d = Int(group(ns, m, 4)),
               isValidCalendarDate(year: y, month: mo, day: d) {
                let iso = String(format: "%04d-%02d-%02d", y, mo, d)
                return ParsedEpisodes(season: y, episodes: [mo * 100 + d], airDate: iso)
            }
        }

        return nil
    }

    public static func isValidCalendarDate(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        let maxDay: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: maxDay = 31
        case 4, 6, 9, 11: maxDay = 30
        case 2:
            maxDay = ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) ? 29 : 28
        default:
            return false
        }
        return day <= maxDay
    }

    private static func group(_ ns: NSString, _ match: NSTextCheckingResult, _ idx: Int) -> String {
        guard idx < match.numberOfRanges else { return "" }
        let r = match.range(at: idx)
        guard r.location != NSNotFound else { return "" }
        return ns.substring(with: r)
    }
}
