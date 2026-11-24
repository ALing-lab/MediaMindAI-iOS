import Foundation

/// 剧集编号映射（1:1 移植自 Android EpisodeMapping.kt）：
/// 1. TMDB 剧集组（DVD Order / 分季组）播出序映射；
/// 2. 番剧绝对集号（如 26 集 -> S02E02）按季集数表映射；
/// 3. 特别篇 / OVA / SP 识别（映射至 Season 00 / Specials）。
public struct SeasonEpisodeCount: Codable, Hashable, Sendable {
    public let seasonNumber: Int
    public let episodeCount: Int

    public init(seasonNumber: Int, episodeCount: Int) {
        self.seasonNumber = seasonNumber
        self.episodeCount = episodeCount
    }
}

public enum EpisodeMapping {
    public typealias Episode = EpisodeKey

    public struct EpisodeKey: Hashable, Codable, Sendable {
        public let season: Int
        public let episode: Int
        public init(season: Int, episode: Int) {
            self.season = season
            self.episode = episode
        }
    }

    public struct EpisodeGroupSummary: Identifiable, Codable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let groupCount: Int
        public let episodeCount: Int

        public init(id: String, name: String, groupCount: Int, episodeCount: Int) {
            self.id = id
            self.name = name
            self.groupCount = groupCount
            self.episodeCount = episodeCount
        }
    }

    public struct EpisodeSubGroup: Codable, Sendable {
        public let order: Int
        public let name: String
        public let episodes: [EpisodeKey]

        public init(order: Int, name: String, episodes: [EpisodeKey]) {
            self.order = order
            self.name = name
            self.episodes = episodes
        }
    }

    /// 根据剧集组各分季子组，构建 `默认播出序 -> 组内序` 映射表。
    public static func buildGroupMap(subGroups: [EpisodeSubGroup]) -> [EpisodeKey: EpisodeKey] {
        var map: [EpisodeKey: EpisodeKey] = [:]
        let sorted = subGroups.sorted { $0.order < $1.order }
        for (idx, sub) in sorted.enumerated() {
            let targetSeason = sub.order > 0 ? sub.order : (idx + 1)
            for (epIdx, orig) in sub.episodes.enumerated() {
                map[orig] = EpisodeKey(season: targetSeason, episode: epIdx + 1)
            }
        }
        return map
    }

    public static func mapEpisode(season: Int, episode: Int, using table: [EpisodeKey: EpisodeKey]) -> EpisodeKey {
        table[EpisodeKey(season: season, episode: episode)] ?? EpisodeKey(season: season, episode: episode)
    }

    /// 将番剧绝对集号（1-based）按各季集数表映射为 `(season, episode)`。
    public static func mapAbsolute(_ absoluteEpisode: Int, seasons: [SeasonEpisodeCount]) -> EpisodeKey? {
        guard absoluteEpisode > 0 else { return nil }
        let ordered = seasons.filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }.sorted { $0.seasonNumber < $1.seasonNumber }
        var remaining = absoluteEpisode
        for s in ordered {
            if remaining <= s.episodeCount {
                return EpisodeKey(season: s.seasonNumber, episode: remaining)
            }
            remaining -= s.episodeCount
        }
        return nil
    }

    /// 检测文件名是否属于特别篇 / OVA / OAD / SP / 番外。
    public static func isSpecialHint(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let pattern = #"(?:^|[\s._\-\[\(])(?:ova|oad|ona|sp|special|specials|extra|ncop|nced|pv|cm)\d*(?:[\s._\-\]\)]|$)|(?:特别篇|番外|特典|剧场版特典)"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }
}
