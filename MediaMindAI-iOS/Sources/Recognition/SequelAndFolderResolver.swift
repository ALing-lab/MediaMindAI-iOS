import Foundation

/// 续集编号消歧与父目录上下文解析（1:1 移植自 Android SequelDisambiguator.kt + FolderContextResolver.kt）。
public enum SequelDisambiguator {
    private static let romanMap: [String: Int] = [
        "XII": 12, "XI": 11, "IX": 9, "X": 10, "VIII": 8, "VII": 7,
        "VI": 6, "IV": 4, "V": 5, "III": 3, "II": 2,
    ]
    private static let trailingRomanRx = try! NSRegularExpression(
        pattern: #"(?<=\s)(XII|XI|IX|X|VIII|VII|VI|IV|V|III|II)(?=$|[\s:：\-·\(\[])"#
    )
    private static let partWordMap: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    private static let partWordRx = try! NSRegularExpression(
        pattern: #"(?i)\b(?:part|pt\.?)\s+(1[0-5]|[1-9]|one|two|three|four|five|six|seven|eight|nine|ten)\b"#
    )
    private static let zhNumMap: [String: Int] = [
        "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        "十": 10, "十一": 11, "十二": 12, "十三": 13, "十四": 14, "十五": 15,
    ]

    /// 提取片名中的续集序号（如 `死神来了2` / `Iron Man III` / `第3部` -> 2 / 3 / 3）。

    /// 将片名中的罗马数字与中文序号统一归一化为阿拉伯数字，便于续集精确匹配。
    public static func normalizeNumerals(_ text: String) -> String {
        var out = text
        let romans: [(String, String)] = [
            ("XII", "12"), ("XI", "11"), ("IX", "9"), ("VIII", "8"), ("VII", "7"),
            ("VI", "6"), ("IV", "4"), ("III", "3"), ("II", "2"), ("X", "10"), ("V", "5"),
        ]
        for (r, d) in romans {
            out = out.replacingOccurrences(of: "(?<=\\s)\(r)(?=\\s|$|[.,:\\-])", with: d, options: .regularExpression)
        }
        let cnMap: [(String, String)] = [
            ("第十二部", "12"), ("第十一部", "11"), ("第十部", "10"), ("第九部", "9"),
            ("第八部", "8"), ("第七部", "7"), ("第六部", "6"), ("第五部", "5"),
            ("第四部", "4"), ("第三部", "3"), ("第二部", "2"), ("第一部", "1"),
        ]
        for (c, d) in cnMap {
            out = out.replacingOccurrences(of: c, with: d)
        }
        return out
    }

    public static func extractSequelNumber(_ title: String) -> Int? {
        let t = TitleDeobfuscator.clean(title)
        let full = NSRange(t.startIndex..<t.endIndex, in: t)
        if let rx = try? NSRegularExpression(pattern: #"第\s*(1[0-5]|[1-9]|十[一二三四五]|[一二两三四五六七八九十])\s*[部集辑]"#),
           let m = rx.firstMatch(in: t, range: full),
           let r = Range(m.range(at: 1), in: t) {
            let tok = String(t[r])
            if let n = Int(tok) { return n }
            if let n = zhNumMap[tok] { return n }
        }
        if let m = partWordRx.firstMatch(in: t, range: full),
           let r = Range(m.range(at: 1), in: t) {
            let tok = String(t[r]).lowercased()
            if let n = Int(tok) { return n }
            if let n = partWordMap[tok] { return n }
        }
        if let rx = try? NSRegularExpression(pattern: #"(?:^|\s|[^\d])(1[0-5]|[2-9])(?:\s*$|\s*[：:\(\[])"#),
           let m = rx.firstMatch(in: t, range: full),
           let r = Range(m.range(at: 1), in: t),
           let n = Int(t[r]) {
            return n
        }
        if let m = trailingRomanRx.firstMatch(in: t, range: full),
           let r = Range(m.range(at: 1), in: t),
           let val = romanMap[String(t[r])] {
            return val
        }
        return nil
    }

    /// 对候选列表应用续集序号与年份加权打分（避免《死神来了2》误匹配到《死神来了》第一部）。
    public static func scoreCandidate(query: String, queryYear: Int?, candidate: MatchInfo) -> Double {
        let parts = TmdbClient.splitQuery(query)
        let queryParts = parts.isEmpty ? [query] : parts
        let candNames = [candidate.title, candidate.originalTitle ?? ""].filter { !$0.isEmpty }
        var score = 0.0
        for q in queryParts {
            for n in candNames {
                score = max(score, MediaParser.titleSimilarityScore(q, n))
            }
        }
        let cjkParts = queryParts.filter { TmdbClient.hasCjk($0) }
        if !cjkParts.isEmpty {
            var cjkBest = 0.0
            for q in cjkParts {
                for n in candNames {
                    cjkBest = max(cjkBest, MediaParser.titleSimilarityScore(q, n))
                }
            }
            if cjkBest >= 85 {
                score += 30
            } else if !candNames.contains(where: { TmdbClient.hasCjk($0) }) {
                score -= 30
            }
        }
        let qSeq = extractSequelNumber(query)
        let cSeq = extractSequelNumber(candidate.title) ?? candidate.originalTitle.flatMap { extractSequelNumber($0) }
        if let qSeq {
            if cSeq == qSeq { score += 18 }
            else if cSeq == nil && qSeq > 1 {
                if candidate.kind != "tv" { score -= 22 }
            }
            else if cSeq != nil && cSeq != qSeq { score -= 28 }
        } else if let cSeq, cSeq > 1 {
            score -= 12
        }
        if let qy = queryYear, let cy = Int(candidate.year) {
            let diff = abs(qy - cy)
            if diff == 0 { score += 15 }
            else if diff == 1 { score += 6 }
            else if diff >= 3 { score -= 18 }
        }
        return score
    }
}

public enum FolderContextResolver {
    private static let genericFolderNames: Set<String> = [
        "电影", "剧集", "电视剧", "动漫", "动画", "综艺", "纪录片", "影视", "下载", "未整理",
        "movies", "movie", "tv", "shows", "series", "anime", "downloads", "media", "video", "videos", "4k", "1080p",
    ]

    public static func isGenericContainer(_ name: String) -> Bool {
        genericFolderNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// 结合父目录与祖先目录链补全文件缺少的片名/季号/年份（如 `权力的游戏 (2011)/Season 2/01.mkv`）。
    public static func enrich(parsed: ParsedMedia, folderName: String, ancestors: [String]) -> ParsedMedia {
        var title = parsed.cleanTitle
        var year = parsed.year
        var season = parsed.season
        var tmdbId = parsed.tmdbId
        var imdbId = parsed.imdbId

        let chain = [folderName] + ancestors.reversed()
        for dir in chain where !isGenericContainer(dir) {
            let dp = MediaParser.parse(dir)
            if season == nil, let s = dp.season { season = s }
            if year == nil, let y = dp.year { year = y }
            if tmdbId == nil, let tid = dp.tmdbId { tmdbId = tid }
            if imdbId == nil, let iid = dp.imdbId { imdbId = iid }
            // 若文件名本身只有集数（如 "01" / "E01" / "S01E01"），借用有意义的父目录名作为片名
            let isBareEp = title.count <= 2 || title.allSatisfy(\.isNumber) || title.lowercased().hasPrefix("s0") || title.lowercased().hasPrefix("ep")
            if isBareEp && !dp.cleanTitle.isEmpty && !dp.cleanTitle.lowercased().hasPrefix("season") && MediaParser.seasonFromName(dir) == nil {
                title = dp.cleanTitle
            }
        }
        return ParsedMedia(
            rawName: parsed.rawName,
            cleanTitle: title,
            year: year,
            season: season,
            episode: parsed.episode,
            episodeEnd: parsed.episodeEnd,
            isTvHint: parsed.isTvHint || season != nil,
            imdbId: imdbId,
            tmdbId: tmdbId,
            tvdbId: parsed.tvdbId,
            resolution: parsed.resolution,
            edition: parsed.edition
        )
    }
}
