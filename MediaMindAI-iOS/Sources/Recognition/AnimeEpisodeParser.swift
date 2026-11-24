import Foundation

/// 1:1 逐行复刻自 Android `AnimeEpisodeParser.kt`（117 行）：
/// 动漫字幕组 / 绝对集数 / 小数特别篇（13.5）/ NCOP·NCED·OVA / Cour·Part / 同目录高频数字守卫。
public enum AnimeEpisodeParser {
    public struct AnimeMatch: Hashable, Sendable {
        public let season: Int?
        public let episode: Int
        public let version: Int?
        public let isSpecial: Bool
        public let specialKind: String? // OVA / OAD / SP / NCOP / NCED / PV / DECIMAL
        public let partOrCour: Int?

        public init(season: Int?, episode: Int, version: Int? = nil, isSpecial: Bool = false, specialKind: String? = nil, partOrCour: Int? = nil) {
            self.season = season
            self.episode = episode
            self.version = version
            self.isSpecial = isSpecial
            self.specialKind = specialKind
            self.partOrCour = partOrCour
        }
    }

    private static let courPartRegex = try? NSRegularExpression(pattern: #"(?i)(?<![A-Za-z])(?:Part|Cour)\s*0*(\d{1,2})(?!\d)"#)
    private static let ordinalSeasonRegex = try? NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9])(\d{1,2})(?:st|nd|rd|th)\s+Season(?![A-Za-z])"#)
    private static let romanSeasonRegex = try? NSRegularExpression(pattern: #"(?i)(?<![A-Za-z])Season\s+(II|III|IV|V|VI)(?![A-Za-z])"#)
    private static let decimalSpecialRegex = try? NSRegularExpression(pattern: #"(?<![0-9SsvVv])(\d{1,3})\.([1-9])(?![0-9])"#)
    private static let animeExtraRegex = try? NSRegularExpression(pattern: #"(?i)(?<![A-Za-z])(NCOP|NCED|OP|ED|OVA|OAD|SP|PV)\s*0*(\d{1,3})?(?![A-Za-z0-9])"#)
    private static let bracketEpRegex = try? NSRegularExpression(pattern: #"(?i)[\[\(【]\s*第?\s*0*(\d{1,4})\s*[话話集]?(?:v(\d))?\s*[\]\)】]"#)
    private static let hyphenEpRegex = try? NSRegularExpression(pattern: #"(?i)\s+[-–—]\s+(\d{1,4})(?:v(\d))?(?=\s|$|[\[\(\.\-_])"#)
    private static let trailingEpRegex = try? NSRegularExpression(pattern: #"(?i)\s+0*(\d{1,4})(?:v(\d))?\s*$"#)
    private static let numRegex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,4})(?!\d)"#)
    private static let romanMap: [String: Int] = ["II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6]

    /// 同目录高频数字过滤：若一个数字出现在 >=3 个且占比 >=70% 的文件中（如 `2077`），视为片名自带数字而非集数。
    public static func repeatedTitleNumbers(stems: [String]) -> Set<Int> {
        guard stems.count >= 3, let rx = numRegex else { return [] }
        var freq: [Int: Int] = [:]
        for s in stems {
            let unmasked = ReleaseTokenizer.maskTechnicalSpans(s).unmaskedText()
            let matches = rx.matches(in: unmasked, range: NSRange(unmasked.startIndex..<unmasked.endIndex, in: unmasked))
            let uniq = Set(matches.compactMap { m -> Int? in
                guard let r = Range(m.range(at: 1), in: unmasked) else { return nil }
                return Int(unmasked[r])
            })
            for n in uniq { freq[n, default: 0] += 1 }
        }
        let threshold = max(3, Int(Double(stems.count) * 0.7))
        return Set(freq.filter { $0.value >= threshold }.keys)
    }

    public static func parse(_ stem: String, ignoredNumbers: Set<Int> = []) -> AnimeMatch? {
        let masked = ReleaseTokenizer.maskTechnicalSpans(stem)
        let clean = masked.unmaskedText()
        let fullClean = NSRange(clean.startIndex..<clean.endIndex, in: clean)

        func groupStr(_ m: NSTextCheckingResult, _ idx: Int, in str: String) -> String? {
            guard idx < m.numberOfRanges, m.range(at: idx).location != NSNotFound,
                  let r = Range(m.range(at: idx), in: str) else { return nil }
            return String(str[r])
        }

        let partOrCour = courPartRegex?.firstMatch(in: clean, range: fullClean).flatMap { groupStr($0, 1, in: clean) }.flatMap(Int.init)
        let seasonHint = ordinalSeasonRegex?.firstMatch(in: clean, range: fullClean).flatMap { groupStr($0, 1, in: clean) }.flatMap(Int.init)
            ?? romanSeasonRegex?.firstMatch(in: clean, range: fullClean).flatMap { groupStr($0, 1, in: clean)?.uppercased() }.flatMap { romanMap[$0] }
            ?? MediaParser.seasonFromName(clean)

        // 1. 特典 / NCOP / NCED / OVA / OAD / SP
        if let m = animeExtraRegex?.firstMatch(in: clean, range: fullClean),
           let kind = groupStr(m, 1, in: clean)?.uppercased() {
            let num = groupStr(m, 2, in: clean).flatMap(Int.init) ?? 1
            return AnimeMatch(season: 0, episode: num, isSpecial: true, specialKind: kind, partOrCour: partOrCour)
        }

        // 2. 小数特别篇（如 13.5）
        if let m = decimalSpecialRegex?.firstMatch(in: clean, range: fullClean),
           let whole = groupStr(m, 1, in: clean).flatMap(Int.init),
           !(1900...2099).contains(whole), !ignoredNumbers.contains(whole) {
            return AnimeMatch(season: 0, episode: whole, isSpecial: true, specialKind: "DECIMAL", partOrCour: partOrCour)
        }

        func validEp(_ ep: Int?) -> Bool {
            guard let ep else { return false }
            return (1...2500).contains(ep) && !(1900...2099).contains(ep) && !ignoredNumbers.contains(ep)
        }

        // 3. 括号集数 `[07]` / `[第07话]` / `[07v2]`
        if let rx = bracketEpRegex {
            let fullOrig = NSRange(stem.startIndex..<stem.endIndex, in: stem)
            for m in rx.matches(in: stem, range: fullOrig) {
                if let r0 = Range(m.range, in: stem) {
                    let pos = stem.distance(from: stem.startIndex, to: r0.lowerBound)
                    if pos < masked.mask.count && masked.mask[pos] { continue }
                }
                if let ep = groupStr(m, 1, in: stem).flatMap(Int.init), validEp(ep) {
                    return AnimeMatch(season: seasonHint, episode: ep, version: groupStr(m, 2, in: stem).flatMap(Int.init), partOrCour: partOrCour)
                }
            }
        }

        // 4. 连字符集数 ` - 07`（守卫 C1：防止 `碟中谍 - 7` 电影被误判为剧集）
        if let rx = hyphenEpRegex {
            for m in rx.matches(in: clean, range: fullClean) {
                guard let rawDigits = groupStr(m, 1, in: clean), let ep = Int(rawDigits) else { continue }
                let ver = groupStr(m, 2, in: clean).flatMap(Int.init)
                let looksMovieSequel = masked.releaseGroup == nil && ver == nil && seasonHint == nil
                    && ignoredNumbers.isEmpty && rawDigits.count == 1 && (1...9).contains(ep)
                if !looksMovieSequel && validEp(ep) {
                    return AnimeMatch(season: seasonHint, episode: ep, version: ver, partOrCour: partOrCour)
                }
            }
        }

        // 5. 有字幕组前缀时允许末尾孤立数字集数（如 `[ANi] 葬送的芙莉莲 07`）
        if masked.releaseGroup != nil {
            let trimmed = clean.trimmingCharacters(in: .whitespaces)
            if let m = trailingEpRegex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
               let ep = groupStr(m, 1, in: trimmed).flatMap(Int.init), validEp(ep) {
                return AnimeMatch(season: seasonHint, episode: ep, version: groupStr(m, 2, in: trimmed).flatMap(Int.init), partOrCour: partOrCour)
            }
        }
        return nil
    }
}
