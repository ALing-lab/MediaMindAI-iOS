import Foundation

/// 1:1 逐行复刻自 Android `EpisodeStrategy.kt`（76 行）：
/// 4 种剧集季集编号策略（默认原样 / 单季顺序拆多季 / 单季跳序拆多季 / 多季合并一季）与 TMDB 剧集组映射。
public enum EpisodeStrategy: String, CaseIterable, Codable, Identifiable, Sendable {
    case original = "original"
    case splitSequential = "split_sequential"
    case splitAbsolute = "split_absolute"
    case merge = "merge"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .original: return "默认策略：识别到的季集"
        case .splitSequential: return "拆分策略：单季顺序拆多季"
        case .splitAbsolute: return "拆分策略：单季跳序拆多季"
        case .merge: return "合并策略：多季合并一季"
        }
    }

    public var detailDescription: String {
        switch self {
        case .original: return "按照文件名和文件夹名正常识别季集信息。"
        case .splitSequential: return "按 TMDB 每季集数拆分连续集号，每季从第 1 集开始编号。"
        case .splitAbsolute: return "按 TMDB 每季集数拆分，只改季信息，保留原连续集号。"
        case .merge: return "合并为第 1 季，按 TMDB 各季集数累计编号；特别篇保持不变。"
        }
    }

    public static func fromId(_ id: String?) -> EpisodeStrategy {
        guard let id else { return .original }
        return EpisodeStrategy(rawValue: id) ?? .original
    }
}

public enum EpisodeStrategyError: LocalizedError, Sendable {
    case invalidInput(String)
    public var errorDescription: String? {
        switch self { case .invalidInput(let m): return m }
    }
}

public enum EpisodeStrategyMapper {
    public typealias Episode = EpisodeMapping.EpisodeKey

    /// 由 TMDB 剧集组结构生成编号映射；若组数据自相矛盾（目标编号重复），返回空表回退默认编号。
    public static func groupMap(groups: [[Episode]]) -> [Episode: Episode] {
        var out: [Episode: Episode] = [:]
        var nextSeason = 1
        for group in groups where !group.isEmpty {
            let season = group.allSatisfy({ $0.season == 0 }) ? 0 : nextSeason
            if season != 0 { nextSeason += 1 }
            for (idx, source) in group.enumerated() {
                out[source] = Episode(season: season, episode: idx + 1)
            }
        }
        if Set(out.values).count != out.count { return [:] }
        return out
    }

    public static func mapWithGroup(episodes: [Episode], groupMap: [Episode: Episode]) -> [Episode] {
        groupMap.isEmpty ? episodes : episodes.map { groupMap[$0] ?? $0 }
    }

    public static func map(
        strategy: EpisodeStrategy,
        episodes: [Episode],
        seasonCounts: [Int: Int]
    ) throws -> [Episode] {
        guard episodes.allSatisfy({ $0.season >= 0 && $0.episode > 0 }) else {
            throw EpisodeStrategyError.invalidInput("季集编号无效，请先纠错")
        }
        if strategy == .original { return episodes }
        let regular = episodes.filter { $0.season > 0 }
        if regular.isEmpty { return episodes }

        let positiveKeys = seasonCounts.keys.filter { $0 > 0 }.sorted()
        guard let lastKey = positiveKeys.last,
              positiveKeys == Array(1...lastKey),
              positiveKeys.allSatisfy({ (seasonCounts[$0] ?? 0) > 0 }) else {
            throw EpisodeStrategyError.invalidInput("TMDB 季集信息不完整，无法安全切换策略")
        }
        let total = positiveKeys.reduce(Int64(0)) { $0 + Int64(seasonCounts[$1] ?? 0) }
        guard total <= Int64(Int.max) else {
            throw EpisodeStrategyError.invalidInput("季集数量超出支持范围")
        }
        if strategy != .merge {
            guard regular.allSatisfy({ $0.season == 1 }) else {
                throw EpisodeStrategyError.invalidInput("拆分策略适用于全部正片位于第 1 季的连续集号，请先确认季集信息")
            }
        }

        return try episodes.map { source in
            if source.season == 0 { return source }
            switch strategy {
            case .original:
                return source
            case .merge:
                guard let count = seasonCounts[source.season] else {
                    throw EpisodeStrategyError.invalidInput("缺少第 \(source.season) 季集数")
                }
                guard source.episode <= count else {
                    throw EpisodeStrategyError.invalidInput("第 \(source.season) 季第 \(source.episode) 集超出 TMDB 集数")
                }
                let offset = positiveKeys.filter { $0 < source.season }.reduce(0) { $0 + (seasonCounts[$1] ?? 0) }
                return Episode(season: 1, episode: offset + source.episode)
            case .splitSequential, .splitAbsolute:
                guard Int64(source.episode) <= total else {
                    throw EpisodeStrategyError.invalidInput("第 \(source.episode) 集超出 TMDB 总集数，未应用策略")
                }
                var remaining = source.episode
                var target = 1
                for season in positiveKeys {
                    target = season
                    let cnt = seasonCounts[season] ?? 0
                    if remaining <= cnt { break }
                    remaining -= cnt
                }
                return Episode(season: target, episode: strategy == .splitSequential ? remaining : source.episode)
            }
        }
    }
}
