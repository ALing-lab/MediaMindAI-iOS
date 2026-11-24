import Foundation

/// 1:1 逐行复刻自 Android `AiResponseParser.kt`（150 行）：
/// 严格 JSON 响应解析器与反幻觉守卫：
/// 容错剥离 Markdown 代码块与前后说明文本，严格校验字段边界（年份/季/集/置信度/非法路径字符），
/// 防止模型输出畸形数据或路径穿越字符污染后续刮削计划。
public enum AiResponseParser {
    public struct AiTitleGuess: Codable, Equatable, Sendable {
        public let title: String
        public let year: String?
        public let kind: String // "movie" | "tv" | ""
        public let season: Int?
        public let episode: Int?
        public let sequelIndex: Int?
        public let confidence: Double

        public init(
            title: String = "",
            year: String? = nil,
            kind: String = "",
            season: Int? = nil,
            episode: Int? = nil,
            sequelIndex: Int? = nil,
            confidence: Double = 0.0
        ) {
            self.title = title
            self.year = year
            self.kind = kind
            self.season = season
            self.episode = episode
            self.sequelIndex = sequelIndex
            self.confidence = confidence
        }

        enum CodingKeys: String, CodingKey {
            case title, year, kind, mediaType, season, episode, sequelIndex, confidence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
            if let s = try? c.decodeIfPresent(String.self, forKey: .year) {
                self.year = s
            } else if let n = try? c.decodeIfPresent(Int.self, forKey: .year) {
                self.year = String(n)
            } else {
                self.year = nil
            }
            self.kind = (try? c.decode(String.self, forKey: .kind)) ?? (try? c.decode(String.self, forKey: .mediaType)) ?? ""
            self.season = try? c.decodeIfPresent(Int.self, forKey: .season)
            self.episode = try? c.decodeIfPresent(Int.self, forKey: .episode)
            self.sequelIndex = try? c.decodeIfPresent(Int.self, forKey: .sequelIndex)
            self.confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0.0
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(year, forKey: .year)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(season, forKey: .season)
            try c.encodeIfPresent(episode, forKey: .episode)
            try c.encodeIfPresent(sequelIndex, forKey: .sequelIndex)
            try c.encode(confidence, forKey: .confidence)
        }
    }

    public struct AiBatchItem: Codable, Equatable, Sendable {
        public let index: Int
        public let title: String
        public let year: String?
        public let kind: String
        public let season: Int?
        public let episode: Int?
        public let sequelIndex: Int?
        public let confidence: Double

        public init(
            index: Int = -1,
            title: String = "",
            year: String? = nil,
            kind: String = "",
            season: Int? = nil,
            episode: Int? = nil,
            sequelIndex: Int? = nil,
            confidence: Double = 0.0
        ) {
            self.index = index
            self.title = title
            self.year = year
            self.kind = kind
            self.season = season
            self.episode = episode
            self.sequelIndex = sequelIndex
            self.confidence = confidence
        }

        enum CodingKeys: String, CodingKey {
            case index, title, year, kind, season, episode, sequelIndex, confidence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.index = (try? c.decode(Int.self, forKey: .index)) ?? -1
            self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
            if let s = try? c.decodeIfPresent(String.self, forKey: .year) {
                self.year = s
            } else if let n = try? c.decodeIfPresent(Int.self, forKey: .year) {
                self.year = String(n)
            } else {
                self.year = nil
            }
            self.kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
            self.season = try? c.decodeIfPresent(Int.self, forKey: .season)
            self.episode = try? c.decodeIfPresent(Int.self, forKey: .episode)
            self.sequelIndex = try? c.decodeIfPresent(Int.self, forKey: .sequelIndex)
            self.confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0.0
        }
    }

    public struct AiRerankChoice: Codable, Equatable, Sendable {
        public let tmdbId: Int
        public let confidence: Double
        public let reason: String

        public init(tmdbId: Int = 0, confidence: Double = 0.0, reason: String = "") {
            self.tmdbId = tmdbId
            self.confidence = confidence
            self.reason = reason
        }

        enum CodingKeys: String, CodingKey {
            case tmdbId, tmdb_id, confidence, reason
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.tmdbId = (try? c.decode(Int.self, forKey: .tmdbId))
                ?? (try? c.decode(Int.self, forKey: .tmdb_id)) ?? 0
            self.confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0.0
            self.reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tmdbId, forKey: .tmdbId)
            try c.encode(confidence, forKey: .confidence)
            try c.encode(reason, forKey: .reason)
        }
    }

    public struct AiFranchiseAssignment: Codable, Equatable, Sendable {
        public let fileIndex: Int
        public let tmdbId: Int
        public let confidence: Double

        public init(fileIndex: Int = -1, tmdbId: Int = 0, confidence: Double = 0.0) {
            self.fileIndex = fileIndex
            self.tmdbId = tmdbId
            self.confidence = confidence
        }

        enum CodingKeys: String, CodingKey {
            case fileIndex, file_index, tmdbId, tmdb_id, confidence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.fileIndex = (try? c.decode(Int.self, forKey: .fileIndex))
                ?? (try? c.decode(Int.self, forKey: .file_index)) ?? -1
            self.tmdbId = (try? c.decode(Int.self, forKey: .tmdbId))
                ?? (try? c.decode(Int.self, forKey: .tmdb_id)) ?? 0
            self.confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0.0
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(fileIndex, forKey: .fileIndex)
            try c.encode(tmdbId, forKey: .tmdbId)
            try c.encode(confidence, forKey: .confidence)
        }
    }

    private static let controlOrPath = try! NSRegularExpression(pattern: #"[\u0000-\u001F\u007F/\\:*?"<>|]"#)
    private static let multiSpace = try! NSRegularExpression(pattern: #"\s+"#)

    public static func extractJsonBlock(_ raw: String, expectArray: Bool = false) -> String? {
        var text = String(raw.prefix(131_072)).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let open: Character = expectArray ? "[" : "{"
        let close: Character = expectArray ? "]" : "}"
        guard let startIdx = text.firstIndex(of: open) else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var idx = startIdx
        while idx < text.endIndex {
            let c = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                if c == "\"" {
                    inString = true
                } else if c == open {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 {
                        return String(text[startIdx...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func cleanTitle(_ raw: String) -> String {
        let s1 = controlOrPath.stringByReplacingMatches(
            in: raw,
            range: NSRange(location: 0, length: (raw as NSString).length),
            withTemplate: " "
        )
        let s2 = multiSpace.stringByReplacingMatches(
            in: s1,
            range: NSRange(location: 0, length: (s1 as NSString).length),
            withTemplate: " "
        )
        return String(s2.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    private static func cleanYear(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4))
        guard digits.count == 4, let y = Int(digits), (1900...2099).contains(y) else { return nil }
        return digits
    }

    private static func cleanKind(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "movie", "film", "电影":
            return "movie"
        case "tv", "series", "show", "drama", "anime", "剧集", "电视剧", "综艺", "动漫":
            return "tv"
        default:
            return ""
        }
    }

    public static func parseSingle(_ raw: String) -> AiTitleGuess? {
        guard let block = extractJsonBlock(raw, expectArray: false),
              let data = block.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AiTitleGuess.self, from: data) else { return nil }
        let title = cleanTitle(parsed.title)
        guard !title.isEmpty else { return nil }
        return AiTitleGuess(
            title: title,
            year: cleanYear(parsed.year),
            kind: cleanKind(parsed.kind),
            season: parsed.season.flatMap { (0...99).contains($0) ? $0 : nil },
            episode: parsed.episode.flatMap { (1...2500).contains($0) ? $0 : nil },
            sequelIndex: parsed.sequelIndex.flatMap { (1...30).contains($0) ? $0 : nil },
            confidence: min(1.0, max(0.0, parsed.confidence))
        )
    }

    public static func parseBatch(_ raw: String, maxIndex: Int) -> [AiBatchItem] {
        guard let block = extractJsonBlock(raw, expectArray: true),
              let data = block.data(using: .utf8),
              let list = try? JSONDecoder().decode([AiBatchItem].self, from: data) else { return [] }
        var seen = Set<Int>()
        var out: [AiBatchItem] = []
        for item in list {
            let title = cleanTitle(item.title)
            guard (0..<maxIndex).contains(item.index), !title.isEmpty, seen.insert(item.index).inserted else {
                continue
            }
            out.append(AiBatchItem(
                index: item.index,
                title: title,
                year: cleanYear(item.year),
                kind: cleanKind(item.kind),
                season: item.season.flatMap { (0...99).contains($0) ? $0 : nil },
                episode: item.episode.flatMap { (1...2500).contains($0) ? $0 : nil },
                sequelIndex: item.sequelIndex.flatMap { (1...30).contains($0) ? $0 : nil },
                confidence: min(1.0, max(0.0, item.confidence))
            ))
        }
        return out
    }

    /// 反幻觉守卫：AI 只能在传入的合法 TMDB 候选 ID 集合中选择，绝不允许编造不存在的 TMDB ID。
    public static func parseRerank(_ raw: String, allowedIds: Set<Int>) -> AiRerankChoice? {
        guard let block = extractJsonBlock(raw, expectArray: false),
              let data = block.data(using: .utf8),
              let choice = try? JSONDecoder().decode(AiRerankChoice.self, from: data),
              allowedIds.contains(choice.tmdbId) else { return nil }
        return AiRerankChoice(
            tmdbId: choice.tmdbId,
            confidence: min(1.0, max(0.0, choice.confidence)),
            reason: String(choice.reason.prefix(120))
        )
    }

    /// 反幻觉守卫：系列分部映射结果中的每个 tmdbId 必须真实存在于 TMDB 合集分部列表中。
    public static func parseFranchiseAssignments(
        _ raw: String,
        fileCount: Int,
        allowedTmdbIds: Set<Int>
    ) -> [AiFranchiseAssignment] {
        guard let block = extractJsonBlock(raw, expectArray: true),
              let data = block.data(using: .utf8),
              let list = try? JSONDecoder().decode([AiFranchiseAssignment].self, from: data) else { return [] }
        var seen = Set<Int>()
        var out: [AiFranchiseAssignment] = []
        for item in list {
            guard (0..<fileCount).contains(item.fileIndex),
                  allowedTmdbIds.contains(item.tmdbId),
                  seen.insert(item.fileIndex).inserted else { continue }
            out.append(AiFranchiseAssignment(
                fileIndex: item.fileIndex,
                tmdbId: item.tmdbId,
                confidence: min(1.0, max(0.0, item.confidence))
            ))
        }
        return out
    }
}
