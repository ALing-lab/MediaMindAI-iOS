import Foundation

/// 1:1 逐行复刻自 Android `Scanner.kt`（L1117–L1548）：
/// BDMV 原盘外层目录保护（`planBdmvFolder`）、作品目录总分发（`planTitleFolder`）与
/// 剧集多季混排/特别篇/剧场版分离/剧集组与分季策略/字幕与附属资产跟随/多余目录清理 10 步规划器（`planTvFolder`）。
public final class ScannerTvVideo: @unchecked Sendable {
    public let entry: CloudEntry
    public let node: ScanTreeNode
    public let stem: String
    public let ext: String
    public var season: Int = 1
    public var episode: Int = 0
    public var metadataSeason: Int? = nil
    public var metadataEpisode: Int? = nil
    public var special: Bool = false
    public var number: Int? = nil
    public var newName: String
    public var newBase: String
    public var target: ScannerSeasonTarget? = nil

    public init(entry: CloudEntry, node: ScanTreeNode, stem: String, ext: String) {
        self.entry = entry
        self.node = node
        self.stem = stem
        self.ext = ext
        self.newName = entry.fileName
        self.newBase = stem
    }
}

public final class ScannerSeasonTarget: @unchecked Sendable {
    public let season: Int
    public let label: String
    public let dirId: String?
    public let mkdirId: String?

    public init(season: Int, label: String, dirId: String?, mkdirId: String?) {
        self.season = season
        self.label = label
        self.dirId = dirId
        self.mkdirId = mkdirId
    }
}

/// 剧集与标题目录规划所需的外部回调（由批次 1.4 电影/海报规划器或单测注入）。
public struct ScannerTvAndBdmvHooks: Sendable {
    public let planMovieFolder: @Sendable (
        _ folder: CloudEntry,
        _ tree: [ScanTreeNode],
        _ allVideos: [CloudEntry],
        _ actions: inout [PlanAction],
        _ groups: inout [PlanGroup],
        _ flags: inout [String],
        _ rootTaken: inout Set<String>,
        _ forced: MatchInfo?,
        _ remembered: MatchInfo?,
        _ doneId: Int?
    ) async throws -> Int

    public let planExtraMovie: @Sendable (
        _ video: ScannerTvVideo,
        _ info: MatchInfo,
        _ folderName: String,
        _ parentId: String,
        _ show: MatchInfo,
        _ actions: inout [PlanAction],
        _ groups: inout [PlanGroup],
        _ flags: inout [String]
    ) async throws -> Void

    public let planArtwork: @Sendable (
        _ folderId: String,
        _ folderName: String,
        _ info: MatchInfo,
        _ gid: String,
        _ actions: inout [PlanAction],
        _ virtualItems: [CloudEntry],
        _ newSeasonDirs: [Int: (String, String)],
        _ dirItems: [String: [CloudEntry]]
    ) -> Void

    public init(
        planMovieFolder: @escaping @Sendable (
            CloudEntry, [ScanTreeNode], [CloudEntry],
            inout [PlanAction], inout [PlanGroup], inout [String], inout Set<String>,
            MatchInfo?, MatchInfo?, Int?
        ) async throws -> Int,
        planExtraMovie: @escaping @Sendable (
            ScannerTvVideo, MatchInfo, String, String, MatchInfo,
            inout [PlanAction], inout [PlanGroup], inout [String]
        ) async throws -> Void,
        planArtwork: @escaping @Sendable (
            String, String, MatchInfo, String, inout [PlanAction],
            [CloudEntry], [Int: (String, String)], [String: [CloudEntry]]
        ) -> Void
    ) {
        self.planMovieFolder = planMovieFolder
        self.planExtraMovie = planExtraMovie
        self.planArtwork = planArtwork
    }
}

public enum ScannerTvAndBdmv {
    private static let cnExtraRx = try! NSRegularExpression(
        pattern: #"番外|花絮|加更|彩蛋|先导|纯享|特辑|特别篇|特別篇|幕后|剧场版|劇場版|OVA|OAD"#,
        options: [.caseInsensitive]
    )
    private static let extraMovieRx = try! NSRegularExpression(
        pattern: #"(?i)剧场版|劇場版|\bThe\s+Movie\b|\bMovie\b"#,
        options: []
    )
    private static let extraSpecialRx = try! NSRegularExpression(
        pattern: #"(?i)番外|花絮|加更|彩蛋|先导|纯享|特辑|特别篇|特別篇|幕后|\b(?:OVA|OAD|SP|Special|Bonus|Extra|PV|NCOP|NCED|CM)\b"#,
        options: []
    )
    private static let extraNumRx = try! NSRegularExpression(
        pattern: #"(?i)(?:SP|OVA|OAD|特别篇|特別篇|番外|花絮|加更|彩蛋|第)\s*0*(\d{1,3})"#
    )
    private static let langTokenRx = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[._\-\s])(chs|cht|zh|zh-cn|zh-tw|sc|tc|简体|繁体|简繁|双语|eng|en|jpn|ja|kor|ko|forced|default)(?:$|[._\-\s])"#
    )

    private static func aid() -> String { String(UUID().uuidString.prefix(8)) }

    private static func matches(_ rx: NSRegularExpression, _ s: String) -> Bool {
        let ns = s as NSString
        return rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    public static func extraKind(of stem: String) -> String? {
        if matches(extraMovieRx, stem) { return "movie" }
        if matches(extraSpecialRx, stem) { return "special" }
        return nil
    }

    public static func extraNumber(of stem: String) -> Int? {
        let ns = stem as NSString
        guard let m = extraNumRx.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    public static func langSuffix(of stem: String) -> String {
        let ns = stem as NSString
        let hits = langTokenRx.matches(in: stem, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).lowercased() }
        var seen = Set<String>()
        return hits.filter { seen.insert($0).inserted }.joined(separator: ".")
    }

    public static func companionSuffix(fileName: String, videoBase: String) -> String? {
        let lowerFile = fileName.lowercased()
        let lowerBase = videoBase.lowercased()
        guard lowerFile.hasPrefix(lowerBase), lowerFile.count > lowerBase.count else { return nil }
        let idx = fileName.index(fileName.startIndex, offsetBy: videoBase.count)
        let tail = String(fileName[idx...])
        guard let first = tail.first, first == "." || first == "-" else { return nil }
        return tail
    }

    /// 目标文件名防冲突占用（1:1 对标 Android `Naming.claim`）。
    public static func claimName(_ want: String, currentName: String, taken: inout Set<String>) -> String? {
        let low = want.lowercased()
        if low == currentName.lowercased() {
            taken.insert(low)
            return want
        }
        if taken.contains(low) { return nil }
        taken.insert(low)
        return want
    }

    // MARK: - 1. BDMV 原盘外层目录保护（1:1 对标 planBdmvFolder）

    public static func planBdmvFolder(
        folder: CloudEntry,
        items: [CloudEntry],
        driveRootId: String,
        tmdb: any ScannerTmdbProvider,
        actions: inout [PlanAction],
        groups: inout [PlanGroup],
        flags: inout [String],
        rootTaken: inout Set<String>,
        forced: MatchInfo?
    ) async -> Int {
        let doneId = MediaParser.tmdbHint(folder.fileName)?.id
        let info: MatchInfo?
        if let forced {
            info = forced
        } else {
            info = await tmdb.movie(stem: folder.fileName, fallbackNames: [], fallbackId: doneId)
        }
        let gid = info.map { "\($0.kind)-\($0.id)-\(folder.fileId)" } ?? "unmatched-\(folder.fileId)"
        guard let info else {
            groups.append(PlanGroup(
                id: gid, kind: "unmatched", tmdbId: nil, title: folder.fileName, year: "",
                posterPath: nil, folderId: folder.fileId, folderName: folder.fileName,
                folderNewName: nil, rating: nil, confidence: nil,
                note: "BDMV 原盘目录未匹配 TMDB（内部结构受保护）", warn: nil, actionIds: []
            ))
            flags.append("BDMV 目录「\(folder.fileName)」未匹配 TMDB，保持原样")
            return 0
        }

        let target = StandardNaming.folderName(title: info.title, year: info.year, tmdbId: info.id, isTv: info.kind == "tv")
        var ids: [String] = []
        if target != folder.fileName {
            if rootTaken.contains(target.lowercased()) && target.lowercased() != folder.fileName.lowercased() {
                flags.append("BDMV 目标目录「\(target)」已被占用，「\(folder.fileName)」保持不变")
            } else {
                let id = aid()
                actions.append(PlanAction(
                    id: id, op: "rename", groupId: gid, fileId: folder.fileId,
                    parentId: folder.parentFileId ?? driveRootId,
                    oldName: folder.fileName, newName: target, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "folder", mediaKind: info.kind, tmdbId: info.id,
                    season: nil, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil,
                    note: "BDMV 原盘：仅重命名外层目录，保护内部结构"
                ))
                ids.append(id)
                rootTaken.insert(target.lowercased())
            }
        }
        groups.append(PlanGroup(
            id: gid, kind: info.kind, tmdbId: info.id,
            collectionId: info.collectionId, collectionName: info.collectionName,
            title: info.title, year: info.year, posterPath: info.posterPath,
            folderId: folder.fileId, folderName: folder.fileName,
            folderNewName: (target != folder.fileName && !ids.isEmpty) ? target : nil,
            rating: info.rating, confidence: forced != nil ? "手动" : "高",
            note: "BDMV 原盘（仅改外层目录，内部结构保持原样）", warn: nil, actionIds: ids
        ))
        return 1
    }

    // MARK: - 2. 作品目录总分发（1:1 对标 planTitleFolder）

    public static func planTitleFolder(
        folder: CloudEntry,
        items: [CloudEntry],
        drive: any CloudDrive,
        tmdb: any ScannerTmdbProvider,
        visited: inout Set<String>,
        dirPathMap: inout [String: String],
        actions: inout [PlanAction],
        groups: inout [PlanGroup],
        flags: inout [String],
        rootTaken: inout Set<String>,
        forced: MatchInfo? = nil,
        remembered: MatchInfo? = nil,
        strategy: EpisodeStrategy = .original,
        episodeGroupId: String? = nil,
        episodeGroupName: String? = nil,
        hooks: ScannerTvAndBdmvHooks
    ) async throws -> Int {
        guard visited.insert(folder.fileId).inserted else { return 0 }
        if StandardNaming.isBdmvRoot(directChildDirNames: items.filter { $0.isDir }.map { $0.fileName }) {
            return await planBdmvFolder(
                folder: folder, items: items, driveRootId: drive.rootId, tmdb: tmdb,
                actions: &actions, groups: &groups, flags: &flags, rootTaken: &rootTaken, forced: forced
            )
        }

        let maxReads = DriveRateProfile.forDrive(drive).maxConcurrentReads
        let tree = try await ScannerTreeEngine.buildTree(
            folder: folder,
            items: items,
            descend: forced?.kind != "movie",
            maxDepth: 3,
            flags: &flags,
            visited: visited,
            dirPathMap: &dirPathMap,
            maxConcurrentReads: maxReads,
            list: { fid in try await drive.list(folderId: fid) }
        )
        for node in tree.dropFirst() { visited.insert(node.id) }

        let allVideos = tree.flatMap { n in n.items.filter { ScannerTreeEngine.isVideo($0) } }
        if allVideos.isEmpty {
            flags.append("「\(folder.fileName)」没有视频文件，跳过")
            return 0
        }

        let match0 = forced ?? remembered
        let folderHint = MediaParser.tmdbHint(folder.fileName)
        let distinctFileHints = Array(Set(allVideos.compactMap { v -> String? in
            guard let h = MediaParser.tmdbHint(v.fileName) else { return nil }
            return "\(h.kind ?? "")|\(h.id)"
        }))
        let fileHint: (kind: String?, id: Int)? = distinctFileHints.count == 1
            ? MediaParser.tmdbHint(allVideos.first(where: { MediaParser.tmdbHint($0.fileName) != nil })?.fileName ?? "")
            : nil
        let tagHint = folderHint ?? fileHint

        let isMultiPartMovie = allVideos.count >= 2 && allVideos.allSatisfy { EditionParser.parseStackPart(MediaParser.splitNameExt($0.fileName).0) != nil }
        let hasSeasonSubdir = tree.count > 1 && tree.dropFirst().contains(where: { ScannerTreeEngine.seasonOfDir($0.entry.fileName) != nil })
        let hasEpisodeVideo = allVideos.contains(where: { MediaParser.parse(MediaParser.splitNameExt($0.fileName).0).episode != nil })

        var resolvedIsTv: Bool
        if let match0 {
            resolvedIsTv = match0.kind == "tv"
        } else if tagHint?.kind == "tv" {
            resolvedIsTv = true
        } else if tagHint?.kind == "movie" || isMultiPartMovie {
            resolvedIsTv = false
        } else {
            resolvedIsTv = hasSeasonSubdir || hasEpisodeVideo
        }

        let doneId = folderHint?.id ?? tagHint?.id
        // 纯 TMDB 标签目录（无片名且未写 tv/movie 前缀）：按电影查不到时自动尝试按剧集 ID 查询
        if match0 == nil && !resolvedIsTv, let doneId, tagHint?.kind == nil,
           TitleDeobfuscator.extract(folder.fileName).queries.isEmpty {
            let asMovie = await tmdb.movieInfo(id: doneId)
            if asMovie == nil {
                let (asTv, _) = await tmdb.show(names: [], fixedId: doneId)
                if asTv != nil { resolvedIsTv = true }
            }
        }

        let startIdx = actions.count
        if resolvedIsTv {
            return try await planTvFolder(
                folder: folder, tree: tree, allVideos: allVideos, drive: drive, tmdb: tmdb,
                actions: &actions, groups: &groups, flags: &flags, rootTaken: &rootTaken,
                forced: forced, remembered: remembered, doneId: doneId, startIdx: startIdx,
                strategy: strategy, episodeGroupId: episodeGroupId, episodeGroupName: episodeGroupName,
                hooks: hooks
            )
        } else {
            return try await hooks.planMovieFolder(
                folder, tree, allVideos, &actions, &groups, &flags, &rootTaken, forced, remembered, doneId
            )
        }
    }

    // MARK: - 3. 剧集多季混排 10 步规划器（1:1 对标 planTvFolder）

    public static func planTvFolder(
        folder: CloudEntry,
        tree: [ScanTreeNode],
        allVideos: [CloudEntry],
        drive: any CloudDrive,
        tmdb: any ScannerTmdbProvider,
        actions: inout [PlanAction],
        groups: inout [PlanGroup],
        flags: inout [String],
        rootTaken: inout Set<String>,
        forced: MatchInfo?,
        remembered: MatchInfo?,
        doneId: Int?,
        startIdx: Int,
        strategy: EpisodeStrategy = .original,
        episodeGroupId: String? = nil,
        episodeGroupName: String? = nil,
        hooks: ScannerTvAndBdmvHooks
    ) async throws -> Int {
        let root = tree[0]
        var names = [folder.fileName]
        if let firstVid = allVideos.first {
            names.append(MediaParser.splitNameExt(firstVid.fileName).0)
        }
        var matchedBy = -1
        let fileIds = Array(Set(allVideos.compactMap { MediaParser.tmdbHint($0.fileName)?.id }))
        let hintId = doneId ?? (fileIds.count == 1 ? fileIds[0] : nil)

        let show: MatchInfo?
        if let forced {
            show = forced
        } else if let remembered {
            show = remembered
        } else {
            let (m, idx) = await tmdb.show(names: names, fixedId: hintId)
            matchedBy = idx
            show = m
        }

        guard let show else {
            let gid = "unmatched-\(folder.fileId)"
            groups.append(PlanGroup(
                id: gid, kind: "unmatched", tmdbId: nil, title: folder.fileName, year: "",
                posterPath: nil, folderId: folder.fileId, folderName: folder.fileName,
                folderNewName: nil, rating: nil, confidence: nil,
                note: "剧集 TMDB 未匹配", warn: nil, actionIds: []
            ))
            flags.append("剧集「\(folder.fileName)」TMDB 未匹配，整个文件夹未改名")
            for v in allVideos {
                actions.append(PlanAction(
                    id: aid(), op: "unmatched", groupId: gid, fileId: v.fileId,
                    parentId: v.parentFileId ?? folder.fileId,
                    oldName: v.fileName, newName: "", destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "file", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                    selected: false, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
            }
            return allVideos.count
        }

        let gid = "tv-\(show.id)-\(folder.fileId)"
        let folderClean = MediaParser.parse(folder.fileName).cleanTitle
        let titleNorms = [show.title, folderClean].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 }
        func stemForExtra(_ stem: String) -> String {
            var acc = stem
            for t in titleNorms {
                acc = acc.replacingOccurrences(of: t, with: " ", options: [.caseInsensitive])
            }
            return acc
        }

        // ① 收集视频：正片 / 特别篇 / 剧场版
        var vids: [ScannerTvVideo] = []
        var movieCands: [ScannerTvVideo] = []
        for n in tree {
            let hint = n.chain().compactMap { ScannerTreeEngine.seasonOfDir($0.entry.fileName) }.first
            for f in n.items where ScannerTreeEngine.isVideo(f) {
                let (stem, ext) = MediaParser.splitNameExt(f.fileName)
                let normalizedEntry = f.parentFileId == nil
                    ? CloudEntry(fileId: f.fileId, fileName: f.fileName, isDir: f.isDir, size: f.size, parentFileId: n.id, etag: f.etag, contentHash: f.contentHash, hashAlgorithm: f.hashAlgorithm)
                    : f
                let v = ScannerTvVideo(entry: normalizedEntry, node: n, stem: stem, ext: ext)
                let parsed = MediaParser.parse(stem)
                let s2 = stemForExtra(stem)
                var extra = extraKind(of: s2)
                if extra != nil, let ps = parsed.season, ps != 0, !matches(cnExtraRx, s2) {
                    extra = nil
                }
                if extra == "movie" && parsed.episode == nil {
                    movieCands.append(v)
                    continue
                } else if extra != nil || hint == 0 {
                    v.special = true
                    v.season = 0
                    v.number = (parsed.season == 0 ? parsed.episode : nil) ?? extraNumber(of: stem)
                } else if let epNum = parsed.episode {
                    v.season = parsed.season ?? hint ?? 1
                    v.episode = epNum
                } else {
                    flags.append("剧集文件认不出集数，未改名：\(f.fileName)")
                    actions.append(PlanAction(
                        id: aid(), op: "unmatched", groupId: gid, fileId: f.fileId, parentId: n.id,
                        oldName: f.fileName, newName: "", destParentId: nil, destRef: nil, destLabel: nil,
                        kind: "file", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                        selected: false, enabled: true, blocked: nil, done: false, error: nil, note: "无集数"
                    ))
                    continue
                }
                vids.append(v)
            }
        }

        // ② 剧场版：按电影匹配 TMDB，命中则在剧集旁边建电影目录，未命中降级为特别篇
        for v in movieCands {
            let parent = folder.parentFileId
            let qClean = MediaParser.parse(v.stem).cleanTitle
            let q = qClean.isEmpty ? show.title : qClean
            let info = parent != nil ? await tmdb.movie(stem: q, fallbackNames: [v.stem], fallbackId: nil) : nil
            let folderName = info.map { StandardNaming.folderName(title: $0.title, year: $0.year, tmdbId: $0.id, isTv: $0.kind == "tv") }
            if let info, let parent, let folderName, !rootTaken.contains(folderName.lowercased()) {
                try await hooks.planExtraMovie(v, info, folderName, parent, show, &actions, &groups, &flags)
                rootTaken.insert(folderName.lowercased())
            } else {
                v.special = true
                v.season = 0
                v.number = extraNumber(of: v.stem)
                vids.append(v)
            }
        }

        // ③ 特别篇编号 + 剧集组 / 分季策略映射
        let sp = vids.filter { $0.special }.sorted { a, b in
            let na = a.number ?? Int.max
            let nb = b.number ?? Int.max
            return na != nb ? na < nb : a.entry.fileName < b.entry.fileName
        }
        let nums = sp.compactMap { $0.number }
        let useOwn = nums.count == sp.count && Set(nums).count == nums.count && nums.allSatisfy { $0 > 0 }
        for (i, v) in sp.enumerated() {
            v.episode = useOwn ? (v.number ?? (i + 1)) : (i + 1)
        }

        let groupMap: [EpisodeMapping.EpisodeKey: EpisodeMapping.EpisodeKey]
        if let egId = episodeGroupId {
            groupMap = await tmdb.episodeGroupMap(groupId: egId)
            if groupMap.isEmpty {
                flags.append("剧集组「\(episodeGroupName ?? egId)」数据不可用，已按默认播出顺序编号：\(folder.fileName)")
            }
        } else {
            groupMap = [:]
        }

        if !groupMap.isEmpty {
            let original = vids.map { EpisodeMapping.EpisodeKey(season: $0.season, episode: $0.episode) }
            let mapped = EpisodeStrategyMapper.mapWithGroup(episodes: original, groupMap: groupMap)
            for i in vids.indices {
                vids[i].season = mapped[i].season
                vids[i].episode = mapped[i].episode
                vids[i].metadataSeason = original[i].season
                vids[i].metadataEpisode = original[i].episode
            }
        } else if strategy != .original {
            let counts = await tmdb.seasonCounts(showId: show.id)
            let original = vids.map { EpisodeMapping.EpisodeKey(season: $0.season, episode: $0.episode) }
            do {
                let mapped = try EpisodeStrategyMapper.map(strategy: strategy, episodes: original, seasonCounts: counts)
                let metadata: [EpisodeMapping.EpisodeKey]
                switch strategy {
                case .merge:
                    metadata = original
                case .splitAbsolute:
                    metadata = (try? EpisodeStrategyMapper.map(strategy: .splitSequential, episodes: original, seasonCounts: counts)) ?? mapped
                default:
                    metadata = mapped
                }
                for i in vids.indices {
                    vids[i].season = mapped[i].season
                    vids[i].episode = mapped[i].episode
                    vids[i].metadataSeason = metadata[i].season
                    vids[i].metadataEpisode = metadata[i].episode
                }
            } catch {
                flags.append("剧集「\(folder.fileName)」\(error.localizedDescription)，已保持原集序策略")
            }
        }

        let usedSeasons = Set(vids.map { $0.season })

        // ④ 季文件夹：已有季目录占位 -> 单季杂目录直接改名 -> 缺失季目录创建 mkdir
        let holders = tree.filter { $0.parent === root }
        var targets: [Int: ScannerSeasonTarget] = [:]

        for h in holders {
            guard let n = ScannerTreeEngine.seasonOfDir(h.entry.fileName) else { continue }
            if (strategy != .original || !groupMap.isEmpty) && !usedSeasons.contains(n) { continue }
            if targets[n] != nil { continue }
            let want = StandardNaming.seasonDirName(n)
            targets[n] = ScannerSeasonTarget(season: n, label: want, dirId: h.id, mkdirId: nil)
            if h.entry.fileName != want {
                actions.append(PlanAction(
                    id: aid(), op: "rename", groupId: gid, fileId: h.id, parentId: folder.fileId,
                    oldName: h.entry.fileName, newName: want, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "folder", mediaKind: nil, tmdbId: nil, season: n, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
            }
        }

        for h in holders {
            if targets.values.contains(where: { $0.dirId == h.id }) { continue }
            if ScannerTreeEngine.seasonOfDir(h.entry.fileName) != nil { continue }
            let seasons = Set(vids.filter { $0.node.holder(root: root) === h }.map { $0.season })
            guard seasons.count == 1, let n = seasons.first, targets[n] == nil else { continue }
            let want = StandardNaming.seasonDirName(n)
            if root.items.contains(where: { $0.isDir && $0.fileName.caseInsensitiveCompare(want) == .orderedSame && $0.fileId != h.id }) {
                continue
            }
            targets[n] = ScannerSeasonTarget(season: n, label: want, dirId: h.id, mkdirId: nil)
            let note = n == 0
                ? "这个子文件夹只装着特别篇，直接改名为 \(want)"
                : "这个子文件夹只装着第 \(n) 季的视频，直接改名为季文件夹（不新建、不移动）"
            actions.append(PlanAction(
                id: aid(), op: "rename", groupId: gid, fileId: h.id, parentId: folder.fileId,
                oldName: h.entry.fileName, newName: want, destParentId: nil, destRef: nil, destLabel: nil,
                kind: "folder", mediaKind: nil, tmdbId: nil, season: n, episode: nil, artworkUrl: nil,
                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: note
            ))
        }

        var newSeasonDirs: [Int: (String, String)] = [:]
        let sortedVids = vids.sorted { a, b in
            a.season != b.season ? a.season < b.season : a.episode < b.episode
        }
        for v in sortedVids {
            if let existing = targets[v.season] {
                v.target = existing
            } else {
                let name = StandardNaming.seasonDirName(v.season)
                let mkId = aid()
                actions.append(PlanAction(
                    id: mkId, op: "mkdir", groupId: gid, fileId: nil, parentId: folder.fileId,
                    oldName: "", newName: name, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "folder", mediaKind: nil, tmdbId: nil, season: v.season, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil,
                    note: v.season == 0 ? "特别篇需要 \(name) 文件夹（执行阶段创建）" : "散落单集需要季文件夹（执行阶段创建）"
                ))
                newSeasonDirs[v.season] = (mkId, name)
                let created = ScannerSeasonTarget(season: v.season, label: name, dirId: nil, mkdirId: mkId)
                targets[v.season] = created
                v.target = created
            }
        }

        // ⑤ 改名（按目标季文件夹查重）
        var takenBySeason: [Int: Set<String>] = [:]
        func ensureTaken(for t: ScannerSeasonTarget) {
            if takenBySeason[t.season] == nil {
                let existing = tree.first(where: { $0.id == t.dirId })?.items ?? []
                takenBySeason[t.season] = Set(existing.map { $0.fileName.lowercased() })
            }
        }

        var conflictedIds = Set<String>()
        for v in vids {
            guard let t = v.target else { continue }
            ensureTaken(for: t)
            let base = StandardNaming.episodeFileBase(
                title: show.title,
                season: v.season,
                episode: v.episode,
                tmdbId: show.id,
                fileStem: v.stem,
                releaseDirName: folder.fileName,
                year: show.year
            )
            let curName = v.node.id == t.dirId ? v.entry.fileName : ""
            var set = takenBySeason[t.season] ?? []
            guard let claimed = claimName(base + v.ext, currentName: curName, taken: &set) else {
                flags.append("目标名已被占用（命名冲突），未改名：\(v.entry.fileName)")
                conflictedIds.insert(v.entry.fileId)
                continue
            }
            takenBySeason[t.season] = set
            v.newName = claimed
            v.newBase = MediaParser.splitNameExt(claimed).0
            let op = claimed == v.entry.fileName ? "skip" : "rename"
            actions.append(PlanAction(
                id: aid(), op: op, groupId: gid, fileId: v.entry.fileId, parentId: v.node.id,
                oldName: v.entry.fileName, newName: claimed, destParentId: nil, destRef: nil, destLabel: nil,
                kind: "file", mediaKind: "tv", tmdbId: show.id, season: v.season, episode: v.episode, artworkUrl: nil,
                selected: true, enabled: true, blocked: nil, done: false, error: nil,
                note: v.special ? String(format: "特别篇 → S00E%02d", v.episode) : nil,
                metadataSeason: v.metadataSeason,
                metadataEpisode: v.metadataEpisode
            ))
        }

        // ⑥ 字幕与附属资产跟随
        var subsOf: [String: [(CloudEntry, String)]] = [:]
        for n in tree {
            let local = vids.filter { $0.node === n }
            for s in n.items where ScannerTreeEngine.isSub(s) {
                let (stem, ext) = MediaParser.splitNameExt(s.fileName)
                var matched: ScannerTvVideo? = nil
                var lang = ""

                outer: for useOld in [true, false] {
                    let ordered = local.sorted { (useOld ? $0.stem.count : $0.newBase.count) > (useOld ? $1.stem.count : $1.newBase.count) }
                    for v in ordered {
                        let k = useOld ? v.stem : v.newBase
                        if stem.lowercased().hasPrefix(k.lowercased()) {
                            let rest = String(stem.dropFirst(k.count))
                            if rest.isEmpty || ".-_ ".contains(rest.first!) {
                                matched = v
                                lang = rest.trimmingCharacters(in: CharacterSet(charactersIn: ".-_ ")).replacingOccurrences(of: " ", with: ".")
                                break outer
                            }
                        }
                    }
                }
                if matched == nil {
                    let ep = MediaParser.parse(stem)
                    if let epNum = ep.episode {
                        matched = local.first(where: { !$0.special && $0.episode == epNum && $0.season == (ep.season ?? $0.season) })
                    } else if local.count == 1 {
                        matched = local[0]
                    }
                    lang = langSuffix(of: stem)
                }
                guard let m = matched else {
                    flags.append("字幕找不到对应的视频，未改名：\(s.fileName)")
                    continue
                }
                if conflictedIds.contains(m.entry.fileId) { continue }
                guard let t = m.target else { continue }
                ensureTaken(for: t)
                var set = takenBySeason[t.season] ?? []
                let desired = m.newBase + (lang.isEmpty ? "" : ".\(lang)") + ext
                let curName = n.id == t.dirId ? s.fileName : ""
                guard let want = claimName(desired, currentName: curName, taken: &set) else {
                    flags.append("字幕目标名已被占用（命名冲突），未改名：\(s.fileName)")
                    continue
                }
                takenBySeason[t.season] = set
                if want != s.fileName {
                    actions.append(PlanAction(
                        id: aid(), op: "rename", groupId: gid, fileId: s.fileId, parentId: n.id,
                        oldName: s.fileName, newName: want, destParentId: nil, destRef: nil, destLabel: nil,
                        kind: "subtitle", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                        selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                    ))
                }
                subsOf[m.entry.fileId, default: []].append((s, want))
            }
        }

        var companionsOf: [String: [(CloudEntry, String)]] = [:]
        for node in tree {
            for entry in node.items where ScannerTreeEngine.isCompanion(entry) {
                let cands: [(ScannerTvVideo, String)] = vids
                    .filter { $0.node === node && !conflictedIds.contains($0.entry.fileId) }
                    .compactMap { video in
                        let suf = companionSuffix(fileName: entry.fileName, videoBase: video.stem)
                            ?? companionSuffix(fileName: entry.fileName, videoBase: video.newBase)
                        return suf.map { (video, $0) }
                    }
                guard cands.count == 1 else { continue }
                let (video, suffix) = cands[0]
                guard let t = video.target else { continue }
                ensureTaken(for: t)
                let name = video.newBase + suffix
                let set = takenBySeason[t.season] ?? []
                if set.contains(name.lowercased()) && !(t.dirId == node.id && name.caseInsensitiveCompare(entry.fileName) == .orderedSame) {
                    flags.append("附属文件「\(entry.fileName)」目标同名文件已存在，原文件保留，未覆盖")
                    continue
                }
                takenBySeason[t.season, default: []].insert(name.lowercased())
                actions.append(PlanAction(
                    id: aid(), op: name == entry.fileName ? "skip" : "rename", groupId: gid,
                    fileId: entry.fileId, parentId: node.id, oldName: entry.fileName, newName: name,
                    destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "companion", mediaKind: "tv", tmdbId: nil, season: video.season, episode: video.episode, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil,
                    note: "已有图片 / NFO 跟随对应单集，保留原内容"
                ))
                companionsOf[video.entry.fileId, default: []].append((entry, name))
            }
        }

        // ⑦ 移动：不在目标季目录里的视频（连同字幕及附属素材）移入
        var moved = Set<String>()
        for v in vids where !conflictedIds.contains(v.entry.fileId) {
            guard let t = v.target, t.dirId != v.node.id else { continue }
            let mvNote = "移入 \(t.label)" + (v.node !== root ? "（原在 \(v.node.pathFrom(root: root))）" : "（执行阶段）")
            actions.append(ScannerTreeEngine.makeMoveAction(
                gid: gid, entry: v.entry, fromId: v.node.id, name: v.newName,
                destId: t.dirId, destLabel: t.label, destRef: t.mkdirId, kind: "file",
                note: mvNote, season: v.season, episode: v.episode
            ))
            moved.insert(v.entry.fileId)
            for (s, name) in subsOf[v.entry.fileId] ?? [] {
                actions.append(ScannerTreeEngine.makeMoveAction(
                    gid: gid, entry: s, fromId: v.node.id, name: name,
                    destId: t.dirId, destLabel: t.label, destRef: t.mkdirId, kind: "subtitle",
                    note: "字幕跟随视频移入 \(t.label)"
                ))
                moved.insert(s.fileId)
            }
            for (entry, name) in companionsOf[v.entry.fileId] ?? [] {
                actions.append(ScannerTreeEngine.makeMoveAction(
                    gid: gid, entry: entry, fromId: v.node.id, name: name,
                    destId: t.dirId, destLabel: t.label, destRef: t.mkdirId, kind: "companion",
                    note: "已有图片 / NFO 跟随单集移入 \(t.label)", season: v.season, episode: v.episode
                ))
                moved.insert(entry.fileId)
            }
        }

        // ⑧ 多余文件夹（默认不勾选删除）
        let keepIds = Set(targets.values.compactMap { $0.dirId })
        ScannerTreeEngine.planLeftovers(
            root: root, tree: tree, keepIds: keepIds, movedIds: moved, gid: gid,
            trashSupportLabel: drive.trashSupport.rawValue, trashBlockedHint: drive.trashSupport == .none ? TrashSupport.none.rawValue : nil, actions: &actions
        )

        // ⑨ 剧集文件夹改名
        var folderTarget = StandardNaming.folderName(title: show.title, year: show.year, tmdbId: show.id, isTv: true)
        if folderTarget != folder.fileName {
            if rootTaken.contains(folderTarget.lowercased()) && folderTarget.lowercased() != folder.fileName.lowercased() {
                flags.append("文件夹目标名「\(folderTarget)」已被占用，「\(folder.fileName)」保持不变")
                folderTarget = folder.fileName
            } else {
                actions.append(PlanAction(
                    id: aid(), op: "rename", groupId: gid, fileId: folder.fileId, parentId: folder.parentFileId,
                    oldName: folder.fileName, newName: folderTarget, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "folder", mediaKind: "tv", tmdbId: show.id, season: nil, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
                rootTaken.remove(folder.fileName.lowercased())
                rootTaken.insert(folderTarget.lowercased())
            }
        } else {
            actions.append(PlanAction(
                id: aid(), op: "skip", groupId: gid, fileId: folder.fileId, parentId: folder.parentFileId,
                oldName: folder.fileName, newName: folderTarget, destParentId: nil, destRef: nil, destLabel: nil,
                kind: "folder", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: "文件夹已是目标名"
            ))
        }

        // ⑩ 海报 / NFO 规划与分组汇总
        let seasonDirsAfter = targets.values.compactMap { t -> CloudEntry? in
            guard let dirId = t.dirId else { return nil }
            return CloudEntry(fileId: dirId, fileName: t.label, isDir: true, parentFileId: folder.fileId)
        }
        let virtualItems = root.items.filter { !$0.isDir } + seasonDirsAfter
        let dirItems = Dictionary(tree.map { ($0.id, $0.items) }, uniquingKeysWith: { _, last in last })
        hooks.planArtwork(folder.fileId, folder.fileName, show, gid, &actions, virtualItems, newSeasonDirs, dirItems)

        let mismatch = forced == nil && remembered == nil && matchedBy > 0 && ScannerHeuristics.folderTitleMismatch(folderName: folder.fileName, matchedTitle: show.title, matchedOriginal: show.originalTitle)
        let conf: String
        if forced != nil { conf = "手动" }
        else if remembered != nil { conf = "历史" }
        else if doneId != nil || matchedBy == 0 { conf = "高" }
        else if mismatch { conf = "低" }
        else { conf = "中" }

        let warn = mismatch ? "文件夹名与文件名不一致：按文件名匹配到《\(show.title)》" : nil
        if let warn { flags.append("「\(folder.fileName)」\(warn)，请确认或点分组重新匹配") }

        let ids = actions[startIdx..<actions.count].filter { $0.groupId == gid }.map { $0.id }
        var noteParts: [String] = []
        let spCount = vids.filter { $0.special }.count
        if spCount > 0 { noteParts.append("特别篇 \(spCount) 个 → \(StandardNaming.seasonDirName(0))") }
        if !movieCands.isEmpty { noteParts.append("剧场版 \(movieCands.count) 个") }
        if let egName = episodeGroupName, !groupMap.isEmpty { noteParts.append("按剧集组「\(egName)」编号") }

        groups.append(PlanGroup(
            id: gid, kind: "tv", tmdbId: show.id,
            title: show.title, year: show.year, posterPath: show.posterPath,
            folderId: folder.fileId, folderName: folder.fileName,
            folderNewName: folderTarget != folder.fileName ? folderTarget : nil,
            rating: show.rating, confidence: conf,
            note: noteParts.isEmpty ? nil : noteParts.joined(separator: " · "),
            warn: warn, actionIds: ids,
            episodeStrategy: strategy.rawValue,
            episodeGroupId: episodeGroupId,
            episodeGroupName: episodeGroupName,
            originalTitle: show.originalTitle
        ))
        return allVideos.count
    }
}
