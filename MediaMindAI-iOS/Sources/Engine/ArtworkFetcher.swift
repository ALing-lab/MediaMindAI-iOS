import Foundation
import CryptoKit

/// 素材在数据源处确实不存在（如 TMDB 没有该集剧照）：不是失败，执行时记为跳过。
public struct ArtworkUnavailableError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 1:1 逐行复刻自 Android `ArtworkFetcher.kt`（490 行 / 24.6 KB）：
/// - 8 MB / 32 项有界图片字节 LRU 内存缓存 + 磁盘原子缓存 + Singleflight 并发下载去重
/// - 多语言评分优选器（`vote_average * 1000 + width`）：海报 `zh > 无字 > en`、背景图 `无字 > zh > en`、Logo `zh > en > 无字`
/// - 整季接口批量取单集详情与剧照（32 集仅发 1 次 TMDB 请求）
/// - 完整 Kodi / Jellyfin / Emby NFO XML 生成（`movie.nfo` / `tvshow.nfo` / `season.nfo` / `episode.nfo`），含演员表/导演/编剧/合集/外链 ID 与 `NfoXml` 安全转义
public actor ArtworkFetcher {
    public static let shared = ArtworkFetcher()

    private static let maxImgMemBytes = 8 * 1024 * 1024
    private static let maxImgMemEntries = 32

    private struct ImgMemEntry {
        let bytes: Data
        let mtime: Date
        var lastAccess: UInt64
    }

    private var imgMemCache: [String: ImgMemEntry] = [:]
    private var imgMemBytes = 0
    private var accessClock: UInt64 = 0
    private var imgInFlight: [String: Task<Data, Error>] = [:]
    private let cacheDir: URL

    public init(cacheDir: URL? = nil) {
        if let cacheDir {
            self.cacheDir = cacheDir
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDir = base.appendingPathComponent("MediaMindAI/img_cache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    public func clearMemoryCache() {
        imgMemCache.removeAll()
        imgMemBytes = 0
    }

    private func putImgMem(url: String, bytes: Data, mtime: Date) {
        guard bytes.count <= Self.maxImgMemBytes / 2 else { return }
        if let old = imgMemCache.removeValue(forKey: url) {
            imgMemBytes -= old.bytes.count
        }
        accessClock &+= 1
        imgMemCache[url] = ImgMemEntry(bytes: bytes, mtime: mtime, lastAccess: accessClock)
        imgMemBytes += bytes.count
        while imgMemBytes > Self.maxImgMemBytes || imgMemCache.count > Self.maxImgMemEntries {
            guard let eldestKey = imgMemCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key,
                  let removed = imgMemCache.removeValue(forKey: eldestKey) else { break }
            imgMemBytes -= removed.bytes.count
        }
    }

    // MARK: - 1. 统一内容生成入口（1:1 对标 ArtworkFetcher.contentFor）

    public func contentFor(action: PlanAction, tmdb: TmdbClient = .shared) async throws -> Data {
        switch action.kind {
        case "image", "clearlogo":
            let url: String
            if let direct = action.artworkUrl, !direct.isEmpty {
                url = direct
            } else if let resolved = try await resolveImageUrl(action: action, tmdb: tmdb) {
                url = resolved
            } else {
                throw ArtworkUnavailableError("没有可用的图片 URL：\(action.newName)")
            }
            return try await download(url: url)

        case "tvshow_nfo":
            guard let tid = action.tmdbId else { throw DriveError.invalidInput("无 tmdb id") }
            let xml = try await buildTvshowNfo(tid: tid, tmdb: tmdb)
            return Data(filterNfo(xml).utf8)

        case "movie_nfo":
            guard let mid = action.tmdbId else { throw DriveError.invalidInput("无 tmdb id") }
            let xml = try await buildMovieNfo(mid: mid, tmdb: tmdb)
            return Data(filterNfo(xml).utf8)

        case "episode_nfo":
            let xml = try await buildEpisodeNfo(action: action, tmdb: tmdb)
            return Data(filterNfo(xml).utf8)

        case "season_nfo":
            let xml = await buildSeasonNfo(tid: action.tmdbId, snum: action.season ?? 1, tmdb: tmdb)
            return Data(xml.utf8)

        default:
            throw DriveError.invalidInput("不支持的 artwork kind=\(action.kind)")
        }
    }

    /// 只读 URL 解析（供预览页展示，不触发下载或上传）。
    public func previewImageUrl(action: PlanAction, tmdb: TmdbClient = .shared) async -> String? {
        guard action.kind == "image" || action.kind == "clearlogo" else { return nil }
        if let direct = action.artworkUrl, !direct.isEmpty { return direct }
        return try? await resolveImageUrl(action: action, tmdb: tmdb)
    }

    // MARK: - 2. 分辨率档位与多语言评分优选器

    public static func imageSize(slot: String, quality: String? = nil) -> String {
        switch quality {
        case "original":
            return "original"
        case "compact":
            return slot == "backdrop" ? "w780" : "w500"
        default:
            switch slot {
            case "logo": return "original"
            case "backdrop": return "w1280"
            default: return "w780"
            }
        }
    }

    private func resolveImageUrl(action: PlanAction, tmdb: TmdbClient) async throws -> String? {
        guard let tid = action.tmdbId else { return nil }
        let name = action.newName.lowercased()
        let quality: String?
        switch AppSettings.shared.imageQuality {
        case .original: quality = "original"
        case .compact: quality = "compact"
        case .standard: quality = nil
        }

        if action.episode != nil && name.hasSuffix("-thumb.jpg") {
            let season = action.metadataSeason ?? action.season ?? 1
            let episode = action.metadataEpisode ?? action.episode ?? 1
            let epObj: [String: Any]?
            if let batched = await fetchEpisodeFromSeasonBatch(tvId: tid, season: season, episode: episode, tmdb: tmdb) {
                epObj = batched
            } else if let data = await tmdb.get(path: "/tv/\(tid)/season/\(season)/episode/\(episode)", query: ["language": "zh-CN"]),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                epObj = obj
            } else {
                epObj = nil
            }
            guard let still = epObj?["still_path"] as? String, still.hasPrefix("/") else {
                throw ArtworkUnavailableError("TMDB 暂无该集剧照，已跳过")
            }
            let sz = Self.imageSize(slot: "thumb", quality: quality)
            return "https://image.tmdb.org/t/p/\(sz)\(still)"
        }

        if action.mediaKind == "movie" {
            if name.hasPrefix("logo") || name.hasPrefix("clearlogo") {
                return await movieImage(mid: tid, key: "logos", langs: ["zh", "en", nil], size: Self.imageSize(slot: "logo", quality: quality), tmdb: tmdb, fallback: { _ in nil })
            }
            if name.hasPrefix("fanart") || name.hasPrefix("backdrop") || name.hasPrefix("background") {
                return await movieImage(mid: tid, key: "backdrops", langs: [nil, "zh", "en"], size: Self.imageSize(slot: "backdrop", quality: quality), tmdb: tmdb, fallback: { $0.backdropPath })
            }
            return await movieImage(mid: tid, key: "posters", langs: ["zh", nil, "en"], size: Self.imageSize(slot: "poster", quality: quality), tmdb: tmdb, fallback: { $0.posterPath })
        }

        if name.hasPrefix("season") && name.contains("poster") {
            if let sp = await seasonPosterUrl(tid: tid, season: action.season ?? 1, quality: quality, tmdb: tmdb) {
                return sp
            }
            return await showPosterUrl(tid: tid, quality: quality, tmdb: tmdb)
        }
        if name.hasPrefix("poster") {
            return await showPosterUrl(tid: tid, quality: quality, tmdb: tmdb)
        }
        if name.hasPrefix("fanart") || name.hasPrefix("backdrop") || name.hasPrefix("background") {
            return await backdropUrl(tid: tid, quality: quality, tmdb: tmdb)
        }
        if name.hasPrefix("logo") || name.hasPrefix("clearlogo") {
            return await logoUrl(tid: tid, quality: quality, tmdb: tmdb)
        }
        return await showPosterUrl(tid: tid, quality: quality, tmdb: tmdb)
    }

    private func movieImage(
        mid: Int,
        key: String,
        langs: [String?],
        size: String,
        tmdb: TmdbClient,
        fallback: (MatchInfo) -> String?
    ) async -> String? {
        let data = await tmdb.get(
            path: "/movie/\(mid)/images",
            query: ["include_image_language": "zh,en,null", "language": "zh"]
        )
        if let picked = Self.pickPath(jsonData: data, key: key, langs: langs) {
            return "https://image.tmdb.org/t/p/\(size)\(picked)"
        }
        guard let detail = await tmdb.movieDetails(id: mid), let fb = fallback(detail), !fb.isEmpty else {
            return nil
        }
        return "https://image.tmdb.org/t/p/\(size)\(fb)"
    }

    private func showPosterUrl(tid: Int, quality: String?, tmdb: TmdbClient) async -> String? {
        let sz = Self.imageSize(slot: "poster", quality: quality)
        if let path = await pickFromTvImages(tid: tid, key: "posters", langs: ["zh", nil, "en"], tmdb: tmdb) {
            return "https://image.tmdb.org/t/p/\(sz)\(path)"
        }
        guard let detail = await tmdb.tvDetails(id: tid), let pp = detail.posterPath, !pp.isEmpty else { return nil }
        return "https://image.tmdb.org/t/p/\(sz)\(pp)"
    }

    private func backdropUrl(tid: Int, quality: String?, tmdb: TmdbClient) async -> String? {
        let sz = Self.imageSize(slot: "backdrop", quality: quality)
        if let detail = await tmdb.tvDetails(id: tid), let bp = detail.backdropPath, !bp.isEmpty {
            return "https://image.tmdb.org/t/p/\(sz)\(bp)"
        }
        if let path = await pickFromTvImages(tid: tid, key: "backdrops", langs: [nil, "zh", "en"], tmdb: tmdb) {
            return "https://image.tmdb.org/t/p/\(sz)\(path)"
        }
        return nil
    }

    private func logoUrl(tid: Int, quality: String?, tmdb: TmdbClient) async -> String? {
        let sz = Self.imageSize(slot: "logo", quality: quality)
        guard let path = await pickFromTvImages(tid: tid, key: "logos", langs: ["zh", "en", nil], tmdb: tmdb) else { return nil }
        return "https://image.tmdb.org/t/p/\(sz)\(path)"
    }

    private func seasonPosterUrl(tid: Int, season: Int, quality: String?, tmdb: TmdbClient) async -> String? {
        let sz = Self.imageSize(slot: "poster", quality: quality)
        let imgs = await tmdb.get(
            path: "/tv/\(tid)/season/\(season)/images",
            query: ["include_image_language": "zh,null,en", "language": "zh"]
        )
        if let path = Self.pickPath(jsonData: imgs, key: "posters", langs: ["zh", nil, "en"]) {
            return "https://image.tmdb.org/t/p/\(sz)\(path)"
        }
        guard let data = await tmdb.get(path: "/tv/\(tid)/season/\(season)", query: ["language": "zh-CN"]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = obj["poster_path"] as? String, !path.isEmpty else { return nil }
        return "https://image.tmdb.org/t/p/\(sz)\(path)"
    }

    private func pickFromTvImages(tid: Int, key: String, langs: [String?], tmdb: TmdbClient) async -> String? {
        let data = await tmdb.get(
            path: "/tv/\(tid)/images",
            query: ["include_image_language": "zh,en,null", "language": "zh"]
        )
        return Self.pickPath(jsonData: data, key: key, langs: langs)
    }

    /// 1:1 复刻 Android `ArtworkFetcher.pickPath`：按语言优先级分层，层内按 `vote_average * 1000 + width` 降序择优。
    public static func pickPath(jsonData: Data?, key: String, langs: [String?]) -> String? {
        guard let jsonData,
              let root = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              let arr = root[key] as? [[String: Any]] else { return nil }

        for lang in langs {
            var cands: [[String: Any]] = []
            for item in arr {
                let rawLang = item["iso_639_1"] as? String
                let itemLang: String? = (rawLang?.isEmpty == false) ? rawLang : nil
                if itemLang == lang {
                    cands.append(item)
                }
            }
            if !cands.isEmpty {
                cands.sort { a, b in
                    let sa = ((a["vote_average"] as? Double) ?? 0.0) * 1000.0 + Double((a["width"] as? Int) ?? 0)
                    let sb = ((b["vote_average"] as? Double) ?? 0.0) * 1000.0 + Double((b["width"] as? Int) ?? 0)
                    return sa > sb
                }
                if let path = cands.first?["file_path"] as? String, !path.isEmpty {
                    return path
                }
            }
        }
        return nil
    }

    /// 优先从整季接口 `/tv/{id}/season/{s}` 批量取单集详情（32 集仅发 1 次 TMDB 请求）。
    private func fetchEpisodeFromSeasonBatch(tvId: Int, season: Int, episode: Int, tmdb: TmdbClient) async -> [String: Any]? {
        guard let data = await tmdb.get(path: "/tv/\(tvId)/season/\(season)", query: ["language": "zh-CN"]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["episodes"] as? [[String: Any]] else { return nil }
        return arr.first { ($0["episode_number"] as? Int) == episode }
    }

    // MARK: - 3. 图片下载（磁盘缓存 + LRU 内存缓存 + Singleflight 去重 + 15MB 魔数校验）

    private func download(url: String) async throws -> Data {
        let digest = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = ImageBytes.safeExt(url: url)
        let cacheURL = cacheDir.appendingPathComponent("\(digest).\(ext)")

        if FileManager.default.fileExists(atPath: cacheURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let fSize = attrs[.size] as? Int, fSize > 0, fSize <= ImageBytes.maxBytes {
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            if let mem = imgMemCache[url], mem.mtime == mtime {
                accessClock &+= 1
                imgMemCache[url]?.lastAccess = accessClock
                return mem.bytes
            }
            if let diskData = try? Data(contentsOf: cacheURL), ImageBytes.looksLikeImage(diskData) {
                putImgMem(url: url, bytes: diskData, mtime: mtime)
                return diskData
            }
            try? FileManager.default.removeItem(at: cacheURL)
        }

        if let existing = imgInFlight[url] {
            return try await existing.value
        }

        let cfg = AppSettings.shared.tmdbNetConfig
        let task = Task<Data, Error> {
            let bytes = try await TmdbNet.shared.downloadImageWithFallback(urlStr: url, config: cfg)
            guard bytes.count <= ImageBytes.maxBytes else {
                throw DriveError.invalidInput("图片太大（超过 15 MB），已跳过")
            }
            guard ImageBytes.looksLikeImage(bytes) else {
                throw DriveError.invalidInput("下载到的不是图片（可能被网络劫持），已跳过")
            }
            return bytes
        }
        imgInFlight[url] = task
        defer { imgInFlight.removeValue(forKey: url) }

        let bytes = try await task.value
        try? bytes.write(to: cacheURL, options: .atomic)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date) ?? Date()
        putImgMem(url: url, bytes: bytes, mtime: mtime)
        return bytes
    }

    // MARK: - 4. 全类型 Kodi / Jellyfin / Emby NFO XML 生成

    private func buildMovieNfo(mid: Int, tmdb: TmdbClient) async throws -> String {
        guard let raw = await tmdb.get(path: "/movie/\(mid)", query: ["language": "zh-CN"]) else {
            throw DriveError.network("TMDB 电影详情失败")
        }
        let credits = await tmdb.get(path: "/movie/\(mid)/credits", query: ["language": "zh-CN"])
        let detail = await tmdb.movieDetails(id: mid)
        return MovieNfo.build(mid: mid, detailData: raw, creditsData: credits, zhTitle: detail?.title ?? "")
    }

    private func buildTvshowNfo(tid: Int, tmdb: TmdbClient) async throws -> String {
        guard let raw = await tmdb.get(path: "/tv/\(tid)", query: ["language": "zh-CN"]),
              let d = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw DriveError.network("TMDB 剧集详情失败")
        }
        let creditsData = await tmdb.get(path: "/tv/\(tid)/credits", query: ["language": "zh-CN"])
        let extData = await tmdb.get(path: "/tv/\(tid)/external_ids", query: [:])
        let credits = creditsData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let ext = extData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]

        var lines: [String] = []
        lines.append(NfoXml.tag(name: "tmdbid", value: tid))
        lines.append("  <uniqueid type=\"tmdb\" default=\"false\">\(tid)</uniqueid>")
        if let tvdb = ext["tvdb_id"] as? Int, tvdb > 0 {
            lines.append(NfoXml.tag(name: "tvdbid", value: tvdb))
            lines.append("  <uniqueid type=\"tvdb\">\(tvdb)</uniqueid>")
        }
        if let imdb = ext["imdb_id"] as? String, !imdb.isEmpty {
            lines.append(NfoXml.tag(name: "imdbid", value: imdb))
            lines.append("  <uniqueid type=\"imdb\" default=\"true\">\(NfoXml.esc(imdb))</uniqueid>")
        }

        let plot = NfoXml.flat(d["overview"] as? String)
        lines.append(NfoXml.cdata(name: "plot", value: plot))
        lines.append(NfoXml.cdata(name: "outline", value: plot))

        let crew = (credits["crew"] as? [[String: Any]]) ?? []
        var seenDirectors = Set<Int>()
        for c in crew where (c["job"] as? String) == "Director" {
            let cid = (c["id"] as? Int) ?? 0
            guard seenDirectors.insert(cid).inserted else { continue }
            lines.append("  <director tmdbid=\"\(cid)\">\(NfoXml.esc((c["name"] as? String) ?? ""))</director>")
        }
        let writerJobs: Set<String> = ["Writer", "Screenplay", "Story", "Teleplay"]
        var seenWriters = Set<String>()
        for c in crew {
            let name = (c["name"] as? String) ?? ""
            if let job = c["job"] as? String, writerJobs.contains(job), !name.isEmpty, seenWriters.insert(name).inserted {
                lines.append(NfoXml.tag(name: "credits", value: name))
            }
        }
        let cast = (credits["cast"] as? [[String: Any]]) ?? []
        for a in cast.prefix(40) {
            lines.append("  <actor>")
            lines.append("    <name>\(NfoXml.esc((a["name"] as? String) ?? ""))</name>")
            lines.append("    <type>Actor</type>")
            if let role = a["character"] as? String, !role.isEmpty {
                lines.append("    <role>\(NfoXml.esc(role))</role>")
            }
            let aid = (a["id"] as? Int) ?? 0
            lines.append("    <tmdbid>\(aid)</tmdbid>")
            if let pp = a["profile_path"] as? String, !pp.isEmpty {
                let thumbUrl = NfoXml.esc("https://image.tmdb.org/t/p/original" + pp)
                lines.append("    <thumb>\(thumbUrl)</thumb>")
            }
            lines.append("    <profile>https://www.themoviedb.org/person/\(aid)</profile>")
            lines.append("  </actor>")
        }
        for g in (d["genres"] as? [[String: Any]]) ?? [] {
            if let gn = g["name"] as? String, !gn.isEmpty { lines.append(NfoXml.tag(name: "genre", value: gn)) }
        }
        if let rating = d["vote_average"] as? Double, rating > 0 {
            lines.append(NfoXml.tag(name: "rating", value: String(format: "%.1f", rating)))
        }
        for co in (d["production_countries"] as? [[String: Any]]) ?? [] {
            if let cn = co["name"] as? String, !cn.isEmpty { lines.append(NfoXml.tag(name: "country", value: cn)) }
        }
        let title = (d["name"] as? String) ?? ""
        let origTitle = (d["original_name"] as? String) ?? ""
        lines.append(NfoXml.tag(name: "title", value: title))
        lines.append(NfoXml.tag(name: "originaltitle", value: origTitle))
        if let fd = d["first_air_date"] as? String, !fd.isEmpty {
            lines.append(NfoXml.tag(name: "premiered", value: fd))
            lines.append(NfoXml.tag(name: "year", value: String(fd.prefix(4))))
        }
        lines.append("  <season>-1</season>")
        lines.append("  <episode>-1</episode>")
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<tvshow>\n" + lines.joined(separator: "\n") + "\n</tvshow>\n"
    }

    private func buildSeasonNfo(tid: Int?, snum: Int, tmdb: TmdbClient) async -> String {
        var title = snum == 0 ? "特别篇" : "第 \(snum) 季"
        var plot = ""
        var premiered = ""
        if let tid, let data = await tmdb.get(path: "/tv/\(tid)/season/\(snum)", query: ["language": "zh-CN"]),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let n = obj["name"] as? String, !n.isEmpty { title = n }
            if let ov = obj["overview"] as? String { plot = NfoXml.flat(ov) }
            if let air = obj["air_date"] as? String { premiered = air }
        }
        var lines: [String] = []
        lines.append(NfoXml.cdata(name: "plot", value: plot))
        lines.append(NfoXml.cdata(name: "outline", value: plot))
        lines.append(NfoXml.tag(name: "title", value: title))
        if !premiered.isEmpty {
            lines.append(NfoXml.tag(name: "premiered", value: premiered))
            lines.append(NfoXml.tag(name: "releasedate", value: premiered))
            lines.append(NfoXml.tag(name: "year", value: String(premiered.prefix(4))))
        }
        lines.append(NfoXml.tag(name: "seasonnumber", value: snum))
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<season>\n" + lines.joined(separator: "\n") + "\n</season>\n"
    }

    private func buildEpisodeNfo(action: PlanAction, tmdb: TmdbClient) async throws -> String {
        guard let tid = action.tmdbId else { throw DriveError.invalidInput("缺少 TMDB ID") }
        let metaSeason = action.metadataSeason ?? action.season ?? 1
        let metaEpisode = action.metadataEpisode ?? action.episode ?? 1
        let epObj: [String: Any]?
        if let batched = await fetchEpisodeFromSeasonBatch(tvId: tid, season: metaSeason, episode: metaEpisode, tmdb: tmdb) {
            epObj = batched
        } else if let data = await tmdb.get(path: "/tv/\(tid)/season/\(metaSeason)/episode/\(metaEpisode)", query: ["language": "zh-CN"]),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            epObj = obj
        } else {
            epObj = nil
        }
        guard let data = epObj else {
            throw DriveError.network("单集信息不可用")
        }
        let lines = [
            NfoXml.tag(name: "title", value: (data["name"] as? String) ?? ""),
            NfoXml.tag(name: "season", value: action.season ?? metaSeason),
            NfoXml.tag(name: "episode", value: action.episode ?? metaEpisode),
            NfoXml.tag(name: "aired", value: (data["air_date"] as? String) ?? ""),
            NfoXml.cdata(name: "plot", value: NfoXml.flat(data["overview"] as? String)),
        ]
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<episodedetails>\n" + lines.joined(separator: "\n") + "\n</episodedetails>\n"
    }

    private func filterNfo(_ xml: String) -> String {
        NfoFields.filter(xml: xml, selection: AppSettings.shared.nfoFields)
    }
}

/// 1:1 复刻 Android `MovieNfo`：纯函数构建标准 `movie.nfo`，便于单元测试直接验证。
public enum MovieNfo {
    public static func build(mid: Int, detailData: Data, creditsData: Data?, zhTitle: String) -> String {
        let d = (try? JSONSerialization.jsonObject(with: detailData)) as? [String: Any] ?? [:]
        func str(_ k: String) -> String {
            ((d[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines: [String] = []
        lines.append(NfoXml.tag(name: "title", value: zhTitle.isEmpty ? str("title") : zhTitle))
        lines.append(NfoXml.tag(name: "originaltitle", value: str("original_title")))
        let plot = NfoXml.flat(str("overview"))
        lines.append(NfoXml.cdata(name: "plot", value: plot))
        lines.append(NfoXml.cdata(name: "outline", value: plot))
        if !str("tagline").isEmpty { lines.append(NfoXml.tag(name: "tagline", value: str("tagline"))) }
        if let runtime = d["runtime"] as? Int, runtime > 0 { lines.append(NfoXml.tag(name: "runtime", value: runtime)) }
        let rd = str("release_date")
        if !rd.isEmpty {
            lines.append(NfoXml.tag(name: "premiered", value: rd))
            lines.append(NfoXml.tag(name: "releasedate", value: rd))
            lines.append(NfoXml.tag(name: "year", value: String(rd.prefix(4))))
        }
        if let rating = d["vote_average"] as? Double, rating > 0 {
            lines.append(NfoXml.tag(name: "rating", value: String(format: "%.1f", rating)))
        }
        lines.append(NfoXml.tag(name: "tmdbid", value: mid))
        let imdb = str("imdb_id")
        lines.append("  <uniqueid type=\"tmdb\" default=\"\(imdb.isEmpty ? "true" : "false")\">\(mid)</uniqueid>")
        if !imdb.isEmpty {
            lines.append(NfoXml.tag(name: "imdbid", value: imdb))
            lines.append("  <uniqueid type=\"imdb\" default=\"true\">\(NfoXml.esc(imdb))</uniqueid>")
        }
        for g in (d["genres"] as? [[String: Any]]) ?? [] {
            if let gn = g["name"] as? String, !gn.isEmpty { lines.append(NfoXml.tag(name: "genre", value: gn)) }
        }
        for co in (d["production_countries"] as? [[String: Any]]) ?? [] {
            if let cn = co["name"] as? String, !cn.isEmpty { lines.append(NfoXml.tag(name: "country", value: cn)) }
        }
        for st in ((d["production_companies"] as? [[String: Any]]) ?? []).prefix(5) {
            if let sn = st["name"] as? String, !sn.isEmpty { lines.append(NfoXml.tag(name: "studio", value: sn)) }
        }
        if let col = d["belongs_to_collection"] as? [String: Any], let cname = col["name"] as? String, !cname.isEmpty {
            lines.append("  <set>")
            lines.append("    <name>\(NfoXml.esc(cname))</name>")
            lines.append("  </set>")
        }

        let cr = creditsData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let crew = (cr["crew"] as? [[String: Any]]) ?? []
        var seenDirs = Set<Int>()
        for c in crew where (c["job"] as? String) == "Director" {
            let cid = (c["id"] as? Int) ?? 0
            guard seenDirs.insert(cid).inserted else { continue }
            lines.append("  <director tmdbid=\"\(cid)\">\(NfoXml.esc((c["name"] as? String) ?? ""))</director>")
        }
        let writerJobs: Set<String> = ["Writer", "Screenplay", "Story", "Teleplay"]
        var seenWriters = Set<String>()
        for c in crew {
            let name = (c["name"] as? String) ?? ""
            if let job = c["job"] as? String, writerJobs.contains(job), !name.isEmpty, seenWriters.insert(name).inserted {
                lines.append(NfoXml.tag(name: "credits", value: name))
            }
        }
        let cast = (cr["cast"] as? [[String: Any]]) ?? []
        for (idx, a) in cast.prefix(30).enumerated() {
            lines.append("  <actor>")
            lines.append("    <name>\(NfoXml.esc((a["name"] as? String) ?? ""))</name>")
            if let role = a["character"] as? String, !role.isEmpty {
                lines.append("    <role>\(NfoXml.esc(role))</role>")
            }
            lines.append("    <order>\(idx)</order>")
            if let pp = a["profile_path"] as? String, !pp.isEmpty {
                let thumbUrl = NfoXml.esc("https://image.tmdb.org/t/p/original" + pp)
                lines.append("    <thumb>\(thumbUrl)</thumb>")
            }
            lines.append("  </actor>")
        }
        return "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n<movie>\n" + lines.joined(separator: "\n") + "\n</movie>\n"
    }
}
