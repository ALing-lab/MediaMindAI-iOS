import Foundation

/// 1:1 逐行复刻自 Android `Scanner.kt`（L1549–L2145）：
/// 剧场版分离规划（`planExtraMovie`）、电影目录与 TMDB 合集规划（`planMovieFolder`）、
/// 根级季目录规划（`planDirAsShowOrMovie` / `planDir`）、分类目录散文件规划（`planLooseFiles`）、
/// 电影与剧集海报/NFO 增量规划（`planMovieArtwork` / `planTvArtwork`），
/// 以及把模块 1 全部四个文件（Tree + Replan + Tv/BDMV + Movie/Loose/Artwork）贯通的统一工厂钩子。
public final class ScannerMovieVideo: @unchecked Sendable {
    public let entry: CloudEntry
    public let node: ScanTreeNode
    public let stem: String
    public let ext: String
    public var info: MatchInfo? = nil
    public var newBase: String = ""
    public var newName: String

    public init(entry: CloudEntry, node: ScanTreeNode, stem: String, ext: String) {
        self.entry = entry
        self.node = node
        self.stem = stem
        self.ext = ext
        self.newName = entry.fileName
    }
}

public enum ScannerMovieLooseAndArtwork {
    private static let imgExtRx = try! NSRegularExpression(pattern: #"\.(jpg|jpeg|png|webp)$"#, options: [.caseInsensitive])
    private static let cjkRx = try! NSRegularExpression(pattern: #"[\u4E00-\u9FFF]"#)

    private static func aid() -> String { String(UUID().uuidString.prefix(8)) }

    private static func hasCjk(_ s: String) -> Bool {
        let ns = s as NSString
        return cjkRx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func isImageFile(_ lowerName: String) -> Bool {
        let ns = lowerName as NSString
        return imgExtRx.firstMatch(in: lowerName, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func stemBeforeLastDot(_ lowerName: String) -> String {
        guard let dot = lowerName.lastIndex(of: ".") else { return lowerName }
        return String(lowerName[..<dot])
    }

    public static func buildCollectionName(title: String, collectionId: Int) -> String {
        let clean = StandardNaming.cleanTitle(title)
        let suffixed = clean.hasSuffix("（系列）") || clean.hasSuffix("(系列)") ? clean : "\(clean)（系列）"
        return "\(suffixed){tmdb-collection-\(collectionId)}"
    }

    // MARK: - 1. 剧集目录中的剧场版独立建夹（1:1 对标 planExtraMovie）

    public static func planExtraMovie(
        video v: ScannerTvVideo,
        info: MatchInfo,
        folderName: String,
        parentId: String,
        show: MatchInfo,
        fullScrape: Bool,
        actions: inout [PlanAction],
        groups: inout [PlanGroup],
        flags: inout [String]
    ) {
        let gid = "movie-\(info.id)-extra-\(v.entry.fileId)"
        let start = actions.count
        let mk = aid()
        actions.append(PlanAction(
            id: mk, op: "mkdir", groupId: gid, fileId: nil, parentId: parentId,
            oldName: "", newName: folderName, destParentId: nil, destRef: nil, destLabel: nil,
            kind: "folder", mediaKind: "movie", tmdbId: info.id,
            season: nil, episode: nil, artworkUrl: nil,
            selected: true, enabled: true, blocked: nil, done: false, error: nil,
            note: "剧场版单独建电影文件夹（与剧集文件夹同级）"
        ))

        let base = StandardNaming.movieFileBase(
            title: info.title, year: info.year, tmdbId: info.id, fileStem: v.stem
        )
        let target = base + v.ext
        if target != v.entry.fileName {
            actions.append(PlanAction(
                id: aid(), op: "rename", groupId: gid, fileId: v.entry.fileId, parentId: v.node.id,
                oldName: v.entry.fileName, newName: target, destParentId: nil, destRef: nil, destLabel: nil,
                kind: "file", mediaKind: "movie", tmdbId: info.id,
                season: nil, episode: nil, artworkUrl: nil,
                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
            ))
        }
        actions.append(ScannerTreeEngine.makeMoveAction(
            gid: gid, entry: v.entry, fromId: v.node.id, name: target,
            destId: nil, destLabel: folderName, destRef: mk, kind: "file", note: "剧场版移进电影文件夹"
        ))

        for s in v.node.items where ScannerTreeEngine.isSub(s) && s.fileName.lowercased().hasPrefix(v.stem.lowercased()) {
            let (sStem, sExt) = MediaParser.splitNameExt(s.fileName)
            let rest = String(sStem.dropFirst(v.stem.count)).trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
            let name = base + (rest.isEmpty ? "" : ".\(rest)") + sExt
            if name != s.fileName {
                actions.append(PlanAction(
                    id: aid(), op: "rename", groupId: gid, fileId: s.fileId, parentId: v.node.id,
                    oldName: s.fileName, newName: name, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "subtitle", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
            }
            actions.append(ScannerTreeEngine.makeMoveAction(
                gid: gid, entry: s, fromId: v.node.id, name: name,
                destId: nil, destLabel: folderName, destRef: mk, kind: "subtitle", note: "字幕跟随剧场版移动"
            ))
        }

        planMovieArtwork(
            folderId: nil, tmdbId: info.id, posterPath: info.posterPath, gid: gid,
            actions: &actions, items: [], destRef: mk, destLabel: folderName, full: fullScrape
        )
        flags.append("《\(show.title)》里的「\(v.entry.fileName)」识别为剧场版，按电影匹配到《\(info.title)》(\(info.year))，请确认")
        groups.append(PlanGroup(
            id: gid, kind: "movie", tmdbId: info.id,
            collectionId: info.collectionId, collectionName: info.collectionName,
            title: info.title, year: info.year, posterPath: info.posterPath,
            folderId: nil, folderName: folderName, folderNewName: nil,
            rating: info.rating, confidence: "中", note: "剧场版（来自《\(show.title)》）",
            warn: nil, actionIds: actions[start..<actions.count].map { $0.id }
        ))
    }

    // MARK: - 2. 电影目录与 TMDB 合集规划（1:1 对标 planMovieFolder）

    public static func planMovieFolder(
        folder: CloudEntry,
        tree: [ScanTreeNode],
        allVideos: [CloudEntry],
        drive: any CloudDrive,
        tmdb: any ScannerTmdbProvider,
        fullScrape: Bool,
        actions: inout [PlanAction],
        groups: inout [PlanGroup],
        flags: inout [String],
        rootTaken: inout Set<String>,
        forced: MatchInfo?,
        remembered: MatchInfo?,
        doneId: Int?
    ) async -> Int {
        let root = tree[0]
        let gidBase = "folder-\(folder.fileId)"
        let start = actions.count
        let single = allVideos.count == 1
        let fbNames = single ? [folder.fileName] : []
        let fbId = single ? doneId : nil
        var taken = Set(tree.flatMap { n in n.items.map { $0.fileName.lowercased() } })
        var unmatched = 0
        var mv: [ScannerMovieVideo] = []

        for n in tree {
            for f in n.items where ScannerTreeEngine.isVideo(f) {
                let (stem, ext) = MediaParser.splitNameExt(f.fileName)
                let normalizedEntry = f.parentFileId == nil
                    ? CloudEntry(fileId: f.fileId, fileName: f.fileName, isDir: f.isDir, size: f.size, parentFileId: n.id, etag: f.etag, contentHash: f.contentHash, hashAlgorithm: f.hashAlgorithm)
                    : f
                let v = ScannerMovieVideo(entry: normalizedEntry, node: n, stem: stem, ext: ext)
                let parsedFolder = MediaParser.parse(folder.fileName)
                let folderFirst = single && parsedFolder.year != nil && hasCjk(parsedFolder.cleanTitle)
                let info: MatchInfo?
                if let forced {
                    info = forced
                } else if let remembered {
                    info = remembered
                } else if folderFirst {
                    info = await tmdb.movie(stem: folder.fileName, fallbackNames: [stem], fallbackId: fbId)
                } else {
                    info = await tmdb.movie(stem: stem, fallbackNames: fbNames, fallbackId: fbId)
                }

                guard let info else {
                    unmatched += 1
                    let ugid = "unmatched-\(folder.fileId)"
                    if !groups.contains(where: { $0.id == ugid }) {
                        groups.append(PlanGroup(
                            id: ugid, kind: "unmatched", tmdbId: nil, title: folder.fileName, year: "",
                            posterPath: nil, folderId: folder.fileId, folderName: folder.fileName,
                            folderNewName: nil, rating: nil, confidence: nil,
                            note: "文件夹内存在未识别电影", warn: nil, actionIds: []
                        ))
                    }
                    actions.append(PlanAction(
                        id: aid(), op: "unmatched", groupId: ugid, fileId: f.fileId, parentId: f.parentFileId ?? n.id,
                        oldName: f.fileName, newName: "", destParentId: nil, destRef: nil, destLabel: nil,
                        kind: "file", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                        selected: false, enabled: true, blocked: nil, done: false, error: nil, note: nil
                    ))
                    mv.append(v)
                    continue
                }

                v.info = info
                let base = StandardNaming.movieFileBase(
                    title: info.title, year: info.year, tmdbId: info.id, fileStem: stem, releaseDirName: folder.fileName
                )
                mv.append(v)
                guard let target = ScannerTvAndBdmv.claimName(base + ext, currentName: f.fileName, taken: &taken) else {
                    flags.append("目标名已被占用（命名冲突），未改名：\(f.fileName)")
                    continue
                }
                v.newName = target
                v.newBase = MediaParser.splitNameExt(target).0
                actions.append(PlanAction(
                    id: aid(), op: target == f.fileName ? "skip" : "rename", groupId: gidBase,
                    fileId: f.fileId, parentId: f.parentFileId ?? n.id,
                    oldName: f.fileName, newName: target, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "file", mediaKind: "movie", tmdbId: info.id,
                    season: nil, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
            }
        }

        let matched = mv.filter { $0.info != nil && !$0.newBase.isEmpty }

        // 字幕匹配：原名前缀 -> 新名前缀 -> 短前缀去语言后缀唯一匹配 -> 同目录唯一视频
        var subsOf: [String: [(CloudEntry, String)]] = [:]
        for n in tree {
            let local = matched.filter { $0.node === n }
            let totalLocalVideos = mv.filter { $0.node === n }.count
            for s in n.items where ScannerTreeEngine.isSub(s) {
                let (stem, ext) = MediaParser.splitNameExt(s.fileName)
                var hit: ScannerMovieVideo? = nil
                var rest = ""

                outer: for useOld in [true, false] {
                    let ordered = local.sorted { (useOld ? $0.stem.count : $0.newBase.count) > (useOld ? $1.stem.count : $1.newBase.count) }
                    for v in ordered {
                        let k = useOld ? v.stem : v.newBase
                        if stem.lowercased().hasPrefix(k.lowercased()) {
                            let r = String(stem.dropFirst(k.count))
                            if r.isEmpty || ".-_ ".contains(r.first!) {
                                hit = v
                                rest = r.trimmingCharacters(in: CharacterSet(charactersIn: ".-_ ")).replacingOccurrences(of: " ", with: ".")
                                break outer
                            }
                        }
                    }
                }
                if hit == nil {
                    let lang = ScannerTvAndBdmv.langSuffix(of: stem)
                    let core = (lang.isEmpty ? stem : String(stem.dropLast(min(stem.count, lang.count + 1)))).lowercased()
                    if core.count >= 2 {
                        let cands = local.filter { v in
                            let o = v.stem.lowercased()
                            guard o.hasPrefix(core) else { return false }
                            if o.count == core.count { return true }
                            let nextChar = o[o.index(o.startIndex, offsetBy: core.count)]
                            return ".-_ [(".contains(nextChar)
                        }
                        if cands.count == 1 {
                            hit = cands[0]
                            rest = lang
                        }
                    }
                }
                if hit == nil && local.count == 1 && totalLocalVideos == 1 {
                    hit = local[0]
                    rest = ScannerTvAndBdmv.langSuffix(of: stem)
                }
                guard let h = hit else {
                    flags.append("字幕找不到对应的视频，未改名：\(s.fileName)")
                    continue
                }
                let desired = h.newBase + (rest.isEmpty ? "" : ".\(rest)") + ext
                guard let want = ScannerTvAndBdmv.claimName(desired, currentName: s.fileName, taken: &taken) else {
                    flags.append("字幕目标名已被占用（命名冲突），未改名：\(s.fileName)")
                    continue
                }
                if want != s.fileName {
                    actions.append(PlanAction(
                        id: aid(), op: "rename", groupId: gidBase, fileId: s.fileId, parentId: n.id,
                        oldName: s.fileName, newName: want, destParentId: nil, destRef: nil, destLabel: nil,
                        kind: "subtitle", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                        selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                    ))
                }
                subsOf[h.entry.fileId, default: []].append((s, want))
            }
        }

        // 单部电影 vs 合集 / 多部电影目录判定
        var distinctIds: [Int] = []
        var seenIds = Set<Int>()
        for m in matched {
            if let id = m.info?.id, seenIds.insert(id).inserted { distinctIds.append(id) }
        }

        var folderTarget: String? = nil
        var groupKind = "movie"
        var groupTitle = folder.fileName
        var groupYear = ""
        var groupTmdb: Int? = nil
        var poster: String? = nil
        var perMovie = false

        if distinctIds.count == 1 && unmatched == 0, let info = matched.first?.info {
            folderTarget = StandardNaming.folderName(title: info.title, year: info.year, tmdbId: info.id)
            groupTitle = info.title
            groupYear = info.year
            groupTmdb = info.id
            poster = info.posterPath
        } else if distinctIds.count == 1 {
            flags.append("文件夹「\(folder.fileName)」有 \(unmatched) 个视频没匹配上 TMDB，文件夹名保持不变")
        } else if distinctIds.count >= 2 {
            perMovie = true
            var cols: [Int: String] = [:]
            var missing: [String] = []
            for mid in distinctIds {
                if let (cid, cname) = await tmdb.collectionOf(movieId: mid) {
                    cols[cid] = cname
                } else {
                    missing.append("tmdb-\(mid)")
                }
            }
            let memberPoster = matched
                .compactMap { $0.info }
                .sorted { (Int($0.year) ?? 9999) < (Int($1.year) ?? 9999) }
                .first(where: { !($0.posterPath ?? "").isEmpty })?.posterPath

            if unmatched == 0 && missing.isEmpty && cols.count == 1, let (cid, cname) = cols.first {
                folderTarget = buildCollectionName(title: cname, collectionId: cid)
                groupKind = "collection"
                groupTitle = cname
                groupTmdb = cid
                var colPoster: String? = nil
                for mid in distinctIds {
                    if let p = await tmdb.collectionPosterOf(movieId: mid, collectionId: cid), !p.isEmpty {
                        colPoster = p
                        break
                    }
                }
                poster = colPoster ?? memberPoster
            } else {
                poster = memberPoster
                let why: String
                if unmatched > 0 { why = "有 \(unmatched) 个视频没匹配上 TMDB" }
                else if !missing.isEmpty { why = "这些电影不属于任何 TMDB 合集：\(missing.joined(separator: ", "))" }
                else { why = "电影分属不同合集" }
                flags.append("文件夹「\(folder.fileName)」\(why)，文件夹名保持不变；已为每部电影单独建文件夹")
            }
        } else if unmatched > 0 {
            flags.append("文件夹「\(folder.fileName)」有 \(unmatched) 个视频没匹配上 TMDB，文件夹名保持不变")
        }

        var moved = Set<String>()
        var keep = Set<String>()
        func companionsOf(_ v: ScannerMovieVideo) -> [CloudEntry] {
            let ls0 = v.stem.lowercased()
            return v.node.items.filter { c in
                guard ScannerTreeEngine.isCompanion(c) else { return false }
                let s = MediaParser.splitNameExt(c.fileName).0.lowercased()
                return s == ls0 || s.hasPrefix(ls0 + ".") || s.hasPrefix(ls0 + "-") || s.hasPrefix(ls0 + "_")
            }
        }

        if perMovie {
            for mid in distinctIds {
                let group = matched.filter { $0.info?.id == mid }
                guard let info = group.first?.info else { continue }
                let name = StandardNaming.folderName(title: info.title, year: info.year, tmdbId: info.id, isTv: info.kind == "tv")
                let existing = tree.first(where: { $0.parent === root && $0.entry.fileName.caseInsensitiveCompare(name) == .orderedSame })
                let mk: String? = existing == nil ? aid() : nil
                if let mk {
                    actions.append(PlanAction(
                        id: mk, op: "mkdir", groupId: gidBase, fileId: nil, parentId: folder.fileId,
                        oldName: "", newName: name, destParentId: nil, destRef: nil, destLabel: nil,
                        kind: "folder", mediaKind: "movie", tmdbId: info.id,
                        season: nil, episode: nil, artworkUrl: nil,
                        selected: true, enabled: true, blocked: nil, done: false, error: nil, note: "每部电影单独一个文件夹"
                    ))
                } else if let ex = existing {
                    keep.insert(ex.id)
                }

                var companions: [CloudEntry] = []
                for v in group {
                    if let ex = existing, v.node === ex { continue }
                    actions.append(ScannerTreeEngine.makeMoveAction(
                        gid: gidBase, entry: v.entry, fromId: v.node.id, name: v.newName,
                        destId: existing?.id, destLabel: name, destRef: mk, kind: "file", note: "移进电影文件夹 \(name)"
                    ))
                    moved.insert(v.entry.fileId)
                    for (s, sn) in subsOf[v.entry.fileId] ?? [] {
                        actions.append(ScannerTreeEngine.makeMoveAction(
                            gid: gidBase, entry: s, fromId: v.node.id, name: sn,
                            destId: existing?.id, destLabel: name, destRef: mk, kind: "subtitle", note: "字幕跟随电影移动"
                        ))
                        moved.insert(s.fileId)
                    }
                    for c in companionsOf(v) {
                        let (cStem, cExt) = MediaParser.splitNameExt(c.fileName)
                        let rest = String(cStem.dropFirst(v.stem.count))
                        let claimed = ScannerTvAndBdmv.claimName(v.newBase + rest + cExt, currentName: c.fileName, taken: &taken)
                        if claimed == nil {
                            flags.append("附属文件「\(c.fileName)」目标名已被占用（命名冲突），保留原名")
                        }
                        let cn = claimed ?? c.fileName
                        if cn != c.fileName {
                            actions.append(PlanAction(
                                id: aid(), op: "rename", groupId: gidBase, fileId: c.fileId, parentId: v.node.id,
                                oldName: c.fileName, newName: cn, destParentId: nil, destRef: nil, destLabel: nil,
                                kind: "companion", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                            ))
                        }
                        actions.append(ScannerTreeEngine.makeMoveAction(
                            gid: gidBase, entry: c, fromId: v.node.id, name: cn,
                            destId: existing?.id, destLabel: name, destRef: mk, kind: "companion", note: "同名图片 / NFO 跟随电影移动"
                        ))
                        moved.insert(c.fileId)
                        companions.append(CloudEntry(fileId: c.fileId, fileName: cn, isDir: false, size: c.size, parentFileId: c.parentFileId))
                    }
                }
                planMovieArtwork(
                    folderId: existing?.id, tmdbId: info.id, posterPath: info.posterPath, gid: gidBase,
                    actions: &actions, items: companions + (existing?.items ?? []),
                    destRef: mk, destLabel: name, full: fullScrape
                )
            }
        } else if !matched.isEmpty {
            for v in matched where v.node !== root {
                actions.append(ScannerTreeEngine.makeMoveAction(
                    gid: gidBase, entry: v.entry, fromId: v.node.id, name: v.newName,
                    destId: folder.fileId, destLabel: folder.fileName, destRef: nil, kind: "file",
                    note: "从 \(v.node.pathFrom(root: root)) 移到电影文件夹根下"
                ))
                moved.insert(v.entry.fileId)
                for (s, sn) in subsOf[v.entry.fileId] ?? [] {
                    actions.append(ScannerTreeEngine.makeMoveAction(
                        gid: gidBase, entry: s, fromId: v.node.id, name: sn,
                        destId: folder.fileId, destLabel: folder.fileName, destRef: nil, kind: "subtitle", note: "字幕跟随视频移动"
                    ))
                    moved.insert(s.fileId)
                }
                for c in companionsOf(v) {
                    actions.append(ScannerTreeEngine.makeMoveAction(
                        gid: gidBase, entry: c, fromId: v.node.id, name: c.fileName,
                        destId: folder.fileId, destLabel: folder.fileName, destRef: nil, kind: "companion", note: "同名图片 / NFO 跟随视频移动"
                    ))
                    moved.insert(c.fileId)
                }
            }
        }

        ScannerTreeEngine.planLeftovers(
            root: root, tree: tree, keepIds: keep, movedIds: moved, gid: gidBase,
            trashSupportLabel: drive.trashSupport.rawValue,
            trashBlockedHint: drive.trashSupport == .none ? TrashSupport.none.rawValue : nil,
            actions: &actions
        )

        if let folderTarget, folderTarget != folder.fileName {
            if rootTaken.contains(folderTarget.lowercased()) && folderTarget.lowercased() != folder.fileName.lowercased() {
                flags.append("文件夹目标名「\(folderTarget)」已被占用，「\(folder.fileName)」保持不变")
            } else {
                actions.append(PlanAction(
                    id: aid(), op: "rename", groupId: gidBase, fileId: folder.fileId, parentId: folder.parentFileId,
                    oldName: folder.fileName, newName: folderTarget, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "folder", mediaKind: groupKind, tmdbId: groupTmdb,
                    season: nil, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
                rootTaken.remove(folder.fileName.lowercased())
                rootTaken.insert(folderTarget.lowercased())
            }
        }

        if groupKind == "movie", let groupTmdb, unmatched == 0 {
            let movedIn = tree.dropFirst().flatMap { n in n.items.filter { moved.contains($0.fileId) } }
            planMovieArtwork(
                folderId: folder.fileId, tmdbId: groupTmdb, posterPath: poster, gid: gidBase,
                actions: &actions, items: root.items + movedIn, full: fullScrape
            )
        }

        let matchedInfo = mv.compactMap { $0.info }.first(where: { $0.id == groupTmdb })
        let mismatch = forced == nil && remembered == nil && groupKind == "movie" && groupTmdb != nil
            && ScannerHeuristics.folderTitleMismatch(folderName: folder.fileName, matchedTitle: groupTitle, matchedOriginal: matchedInfo?.originalTitle)
        let conf: String?
        if forced != nil { conf = "手动" }
        else if remembered != nil { conf = "历史" }
        else if groupTmdb == nil { conf = nil }
        else if doneId != nil { conf = "高" }
        else if mismatch { conf = "低" }
        else { conf = "中" }

        let warn = mismatch ? "文件夹名与文件名不一致：匹配到《\(groupTitle)》" : nil
        if let warn { flags.append("「\(folder.fileName)」\(warn)，请确认或点分组重新匹配") }

        let ids = actions[start..<actions.count].filter { $0.groupId == gidBase }.map { $0.id }
        let renamedFolder = actions.contains(where: { $0.groupId == gidBase && $0.op == "rename" && $0.fileId == folder.fileId })
        groups.append(PlanGroup(
            id: gidBase, kind: groupKind, tmdbId: groupTmdb,
            collectionId: matchedInfo?.collectionId,
            collectionName: matchedInfo?.collectionName,
            title: groupTitle, year: groupYear, posterPath: poster,
            folderId: folder.fileId, folderName: folder.fileName,
            folderNewName: renamedFolder ? folderTarget : nil,
            rating: matchedInfo?.rating, confidence: conf,
            note: perMovie ? "\(distinctIds.count) 部电影，各自单独建文件夹" : nil,
            warn: warn, actionIds: ids,
            originalTitle: matchedInfo?.originalTitle
        ))
        return allVideos.count
    }

    // MARK: - 3. 根级季目录规划（1:1 对标 planDirAsShowOrMovie / planDir）

    public static func planDirAsShowOrMovie(
        folder: CloudEntry,
        items: [CloudEntry],
        defaultSeason: Int?,
        tmdb: any ScannerTmdbProvider,
        visited: inout Set<String>,
        actions: inout [PlanAction],
        groups: inout [PlanGroup],
        flags: inout [String],
        parentFolderName: String? = nil
    ) async -> Int {
        guard visited.insert(folder.fileId).inserted else { return 0 }
        let videos = items.filter { ScannerTreeEngine.isVideo($0) }
        if videos.isEmpty { return 0 }
        let parentHint = parentFolderName.flatMap { MediaParser.tmdbHint($0) }
        var names: [String] = []
        if let parent = parentFolderName, !parent.isEmpty, !ScannerTreeEngine.isCategoryDir(parent) {
            names.append(parent)
        }
        names.append(contentsOf: videos.prefix(2).map { MediaParser.splitNameExt($0.fileName).0 })
        let (show, _) = await tmdb.show(names: names, fixedId: parentHint?.id)
        guard let show else {
            flags.append("季文件夹「\(folder.fileName)」无法匹配剧集")
            return videos.count
        }
        let gid = "tv-\(show.id)-\(folder.fileId)"
        let ids = planDir(items: items, show: show, defaultSeason: defaultSeason, gid: gid, actions: &actions, flags: &flags)
        groups.append(PlanGroup(
            id: gid, kind: "tv", tmdbId: show.id, title: show.title, year: show.year, posterPath: show.posterPath,
            folderId: folder.fileId, folderName: folder.fileName, folderNewName: nil,
            rating: show.rating, confidence: "中", note: "季文件夹（不改名）", warn: nil, actionIds: ids
        ))
        return videos.count
    }

    public static func planDir(
        items: [CloudEntry],
        show: MatchInfo,
        defaultSeason: Int?,
        gid: String,
        actions: inout [PlanAction],
        flags: inout [String]
    ) -> [String] {
        struct VideoPlan { let oldStem: String; let newBase: String; let season: Int; let episode: Int }
        var taken = Set(items.map { $0.fileName.lowercased() })
        var ids: [String] = []
        var videos: [VideoPlan] = []

        for item in items where !item.isDir && ScannerTreeEngine.isVideo(item) {
            let (stem, ext) = MediaParser.splitNameExt(item.fileName)
            let parsed = MediaParser.parse(stem)
            guard let epNum = parsed.episode else {
                flags.append("剧集文件认不出集数，未改名：\(item.fileName)")
                let id = aid()
                actions.append(PlanAction(
                    id: id, op: "unmatched", groupId: gid, fileId: item.fileId, parentId: item.parentFileId,
                    oldName: item.fileName, newName: "", destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "file", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                    selected: false, enabled: true, blocked: nil, done: false, error: nil, note: "无集数"
                ))
                ids.append(id)
                continue
            }
            let season = parsed.season ?? defaultSeason ?? 1
            let base = StandardNaming.episodeFileBase(
                title: show.title, season: season, episode: epNum, tmdbId: show.id, fileStem: stem, year: show.year
            )
            guard let target = ScannerTvAndBdmv.claimName(base + ext, currentName: item.fileName, taken: &taken) else {
                flags.append("目标名已被占用（命名冲突），未改名：\(item.fileName)")
                continue
            }
            videos.append(VideoPlan(oldStem: stem, newBase: MediaParser.splitNameExt(target).0, season: season, episode: epNum))
            let id = aid()
            actions.append(PlanAction(
                id: id, op: target == item.fileName ? "skip" : "rename", groupId: gid,
                fileId: item.fileId, parentId: item.parentFileId,
                oldName: item.fileName, newName: target, destParentId: nil, destRef: nil, destLabel: nil,
                kind: "file", mediaKind: "tv", tmdbId: show.id, season: season, episode: epNum, artworkUrl: nil,
                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
            ))
            ids.append(id)
        }

        for item in items where !item.isDir && ScannerTreeEngine.isSub(item) {
            let (stem, ext) = MediaParser.splitNameExt(item.fileName)
            var matched: VideoPlan? = nil
            var lang = ""
            outer: for useOld in [true, false] {
                let ordered = videos.sorted { (useOld ? $0.oldStem.count : $0.newBase.count) > (useOld ? $1.oldStem.count : $1.newBase.count) }
                for v in ordered {
                    let k = useOld ? v.oldStem : v.newBase
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
                    let s = ep.season ?? defaultSeason ?? 1
                    matched = videos.first(where: { $0.episode == epNum && $0.season == s })
                } else if videos.count == 1 {
                    matched = videos[0]
                }
                lang = ScannerTvAndBdmv.langSuffix(of: stem)
            }
            guard let m = matched else {
                flags.append("字幕找不到对应的视频，未改名：\(item.fileName)")
                continue
            }
            guard let target = ScannerTvAndBdmv.claimName(m.newBase + (lang.isEmpty ? "" : ".\(lang)") + ext, currentName: item.fileName, taken: &taken) else {
                flags.append("字幕目标名已被占用（命名冲突），未改名：\(item.fileName)")
                continue
            }
            if target == item.fileName { continue }
            let id = aid()
            actions.append(PlanAction(
                id: id, op: "rename", groupId: gid, fileId: item.fileId, parentId: item.parentFileId,
                oldName: item.fileName, newName: target, destParentId: nil, destRef: nil, destLabel: nil,
                kind: "subtitle", mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
            ))
            ids.append(id)
        }
        return ids
    }

    // MARK: - 4. 分类目录散文件规划（1:1 对标 planLooseFiles）

    public static func planLooseFiles(
        dir: CloudEntry,
        items: [CloudEntry],
        tmdb: any ScannerTmdbProvider,
        fullScrape: Bool,
        actions: inout [PlanAction],
        groups: inout [PlanGroup],
        flags: inout [String],
        taken: inout Set<String>,
        forced: (fileId: String?, info: MatchInfo)? = nil,
        sharedMkdirs: [PlanAction] = [],
        episodeOverride: (fileId: String, season: Int, episode: Int)? = nil
    ) async -> Int {
        var seen = 0
        var folderMade: [Int: (dirId: String?, mkdirId: String?)] = [:]
        for mk in sharedMkdirs where mk.parentId == dir.fileId {
            if let tid = mk.tmdbId { folderMade[tid] = (nil, mk.id) }
        }

        // 先对本目录散落视频按常规 TMDB 识别；若存在多个未命中且已启用 AI，则触发 AiBatchPlanner 批量消歧（1:1 对标 Android Scanner.kt）
        let looseVideos = items.filter { ScannerTreeEngine.isVideo($0) && (forced == nil || $0.fileId == forced?.fileId) }
        var preResolved: [String: (info: MatchInfo?, epPair: (Int?, Int)?)] = [:]
        var unmatchedForBatch: [CloudEntry] = []

        for item in looseVideos {
            let (stem, _) = MediaParser.splitNameExt(item.fileName)
            let parsed = MediaParser.parse(stem)
            let epPair: (Int?, Int)?
            if let ov = episodeOverride, ov.fileId == item.fileId {
                epPair = (ov.season, ov.episode)
            } else if let e = parsed.episode {
                epPair = (parsed.season, e)
            } else {
                epPair = nil
            }

            let dirHint = MediaParser.tmdbHint(dir.fileName)
            let dirIsCategory = ScannerTreeEngine.isCategoryDir(dir.fileName)
            let stemHint = MediaParser.tmdbHint(stem)
            let effectiveHint = stemHint ?? dirHint
            let stemHasTitle = parsed.cleanTitle.unicodeScalars.contains {
                (0x4E00...0x9FFF).contains($0.value) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
            } && !parsed.cleanTitle.lowercased().hasPrefix("s0") && !parsed.cleanTitle.lowercased().hasPrefix("s1")
            let tvCandidateNames: [String] = {
                if !dirIsCategory && !dir.fileName.isEmpty && (dirHint != nil || !stemHasTitle) {
                    return [dir.fileName, stem]
                }
                if !dirIsCategory && !dir.fileName.isEmpty {
                    return [stem, dir.fileName]
                }
                return [stem]
            }()
            let movieFallbacks: [String] = (!dirIsCategory && !dir.fileName.isEmpty) ? [dir.fileName] : []
            let info: MatchInfo?
            if let forced {
                info = forced.info
            } else if effectiveHint?.kind == "tv" {
                info = await tmdb.show(names: tvCandidateNames, fixedId: effectiveHint?.id).0
            } else if effectiveHint?.kind == "movie" {
                info = await tmdb.movie(stem: stemHasTitle ? stem : dir.fileName, fallbackNames: movieFallbacks, fallbackId: effectiveHint?.id)
            } else if epPair != nil {
                info = await tmdb.show(names: tvCandidateNames, fixedId: effectiveHint?.id).0
            } else if let sh = effectiveHint {
                if let m = await tmdb.movie(stem: stemHasTitle ? stem : dir.fileName, fallbackNames: movieFallbacks, fallbackId: sh.id) {
                    info = m
                } else {
                    info = await tmdb.show(names: tvCandidateNames, fixedId: sh.id).0
                }
            } else {
                info = await tmdb.movie(stem: stemHasTitle ? stem : dir.fileName, fallbackNames: movieFallbacks, fallbackId: nil)
            }
            preResolved[item.fileId] = (info, epPair)
            if info == nil && forced == nil {
                unmatchedForBatch.append(item)
            }
        }

        if unmatchedForBatch.count >= 2 && AppSettings.shared.aiEnabled {
            let batchItems = unmatchedForBatch.map { AiBatchPlanner.BatchItem(id: $0.fileId, folderName: dir.fileName, fileName: $0.fileName) }
            for chunk in AiBatchPlanner.planBatches(batchItems, maxPerBatch: AiBatchPlanner.maxBatchSize) {
                let guesses = await AiBatchPlanner.recognizeBatch(folderName: dir.fileName, fileNames: chunk.map(\.fileName))
                for (idx, bItem) in chunk.enumerated() {
                    guard let g = guesses[idx], !g.title.isEmpty, g.confidence >= AppSettings.shared.aiConfig.autoTriggerThreshold else { continue }
                    let yr = g.year.flatMap(Int.init)
                    // 直接查询 TmdbClient 核验批量猜测，绝不重入 HybridRecognitionOrchestrator 造成二次 AI 调用或双记诊断
                    let candidates = g.kind == "tv"
                        ? await TmdbClient.shared.searchTv(query: g.title, year: yr)
                        : await TmdbClient.shared.searchMovie(query: g.title, year: yr)
                    if let top = HybridRecognitionOrchestrator.rerankCandidates(query: g.title, year: yr, candidates: candidates).first,
                       SequelDisambiguator.scoreCandidate(query: g.title, queryYear: yr, candidate: top) >= 35 {
                        let detailed = top.kind == "movie" ? (await TmdbClient.shared.movieDetails(id: top.id) ?? top) : top
                        await HybridRecognitionOrchestrator.onAiVerifiedMatch(rawName: bItem.fileName, verified: detailed)
                        let existingEp = preResolved[bItem.id]?.epPair
                        let resolvedEp: (Int?, Int)? = existingEp ?? (g.episode.map { (g.season, $0) })
                        preResolved[bItem.id] = (detailed, resolvedEp)
                    }
                }
            }
        }

        for item in looseVideos {
            let (stem, ext) = MediaParser.splitNameExt(item.fileName)
            seen += 1
            let resolved = preResolved[item.fileId]
            let epPair = resolved?.epPair
            let info = resolved?.info

            let parent = item.parentFileId ?? dir.fileId
            guard let info else {
                // 同文件夹下的未识别散文件合并为同一张待确认文件夹卡片，手动识别一次即可整组纠正
                let gid = "unmatched-dir-\(parent)"
                let aidVal = aid()
                if let existingIdx = groups.firstIndex(where: { $0.id == gid }) {
                    groups[existingIdx].actionIds.append(aidVal)
                } else {
                    groups.append(PlanGroup(
                        id: gid, kind: "unmatched", tmdbId: nil,
                        title: dir.fileName.isEmpty ? item.fileName : dir.fileName, year: "",
                        posterPath: nil, folderId: parent, folderName: dir.fileName, folderNewName: nil,
                        rating: nil, confidence: nil, note: "同目录待手动识别", warn: nil, actionIds: [aidVal]
                    ))
                }
                actions.append(PlanAction(
                    id: aidVal, op: "unmatched", groupId: gid, fileId: item.fileId, parentId: parent,
                    oldName: item.fileName, newName: "", destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "file", mediaKind: nil, tmdbId: nil, season: epPair?.0, episode: epPair?.1, artworkUrl: nil,
                    selected: false, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
                continue
            }

            let gid = "\(info.kind)-\(info.id)-loose-\(item.fileId)"
            let start = actions.count
            if info.kind == "tv" {
                guard let ep = epPair else {
                    actions.append(PlanAction(
                        id: aid(), op: "unmatched", groupId: gid, fileId: item.fileId, parentId: parent,
                        oldName: item.fileName, newName: "", destParentId: nil, destRef: nil, destLabel: nil,
                        kind: "file", mediaKind: "tv", tmdbId: info.id, season: nil, episode: nil, artworkUrl: nil,
                        selected: false, enabled: true, blocked: nil, done: false, error: nil,
                        note: "认不出集数，请先补充 SxxEyy 后重新扫描"
                    ))
                    groups.append(PlanGroup(
                        id: gid, kind: "tv", tmdbId: info.id, title: info.title, year: info.year, posterPath: info.posterPath,
                        folderId: parent, folderName: dir.fileName, folderNewName: nil,
                        rating: info.rating, confidence: "中", note: "无集数，未操作", warn: nil,
                        actionIds: actions[start..<actions.count].map { $0.id }
                    ))
                    continue
                }
                let season = ep.0 ?? 1
                let base = StandardNaming.episodeFileBase(
                    title: info.title, season: season, episode: ep.1, tmdbId: info.id, fileStem: stem, year: info.year
                )
                guard let target = ScannerTvAndBdmv.claimName(base + ext, currentName: item.fileName, taken: &taken) else {
                    flags.append("目标名已被占用（命名冲突），未改名：\(item.fileName)")
                    continue
                }
                actions.append(PlanAction(
                    id: aid(), op: target == item.fileName ? "skip" : "rename", groupId: gid,
                    fileId: item.fileId, parentId: parent, oldName: item.fileName, newName: target,
                    destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "file", mediaKind: info.kind, tmdbId: info.id, season: season, episode: ep.1, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
                groups.append(PlanGroup(
                    id: gid, kind: info.kind, tmdbId: info.id, title: info.title, year: info.year, posterPath: info.posterPath,
                    folderId: nil, folderName: dir.fileName, folderNewName: nil,
                    rating: info.rating, confidence: "中", note: "散文件（剧集单集，只改名）", warn: nil,
                    actionIds: actions[start..<actions.count].map { $0.id }
                ))
                continue
            }

            let base = StandardNaming.movieFileBase(title: info.title, year: info.year, tmdbId: info.id, fileStem: stem)
            let name = StandardNaming.folderName(title: info.title, year: info.year, tmdbId: info.id, isTv: info.kind == "tv")
            let existingDir = items.first(where: { $0.isDir && $0.fileName.caseInsensitiveCompare(name) == .orderedSame })
            let destPair: (dirId: String?, mkdirId: String?)
            if let existing = folderMade[info.id] {
                destPair = existing
            } else if let existingDir {
                destPair = (existingDir.fileId, nil)
                folderMade[info.id] = destPair
            } else {
                let id = aid()
                actions.append(PlanAction(
                    id: id, op: "mkdir", groupId: gid, fileId: nil, parentId: dir.fileId,
                    oldName: "", newName: name, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "folder", mediaKind: "movie", tmdbId: info.id,
                    season: nil, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: "散落的电影单独建文件夹"
                ))
                taken.insert(name.lowercased())
                destPair = (nil, id)
                folderMade[info.id] = destPair
            }

            let target = base + ext
            if target != item.fileName {
                actions.append(PlanAction(
                    id: aid(), op: "rename", groupId: gid, fileId: item.fileId, parentId: parent,
                    oldName: item.fileName, newName: target, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "file", mediaKind: "movie", tmdbId: info.id, season: nil, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                ))
            }
            actions.append(ScannerTreeEngine.makeMoveAction(
                gid: gid, entry: item, fromId: parent, name: target,
                destId: destPair.dirId, destLabel: name, destRef: destPair.mkdirId, kind: "file", note: "移进电影文件夹 \(name)"
            ))

            var companions: [CloudEntry] = []
            let ls0 = stem.lowercased()
            for c in items where !c.isDir && c.fileId != item.fileId {
                let (cs, cext) = MediaParser.splitNameExt(c.fileName)
                let lc = cs.lowercased()
                guard lc == ls0 || lc.hasPrefix("\(ls0).") || lc.hasPrefix("\(ls0)-") || lc.hasPrefix("\(ls0)_") else { continue }
                guard ScannerTreeEngine.isSub(c) || ScannerTreeEngine.isCompanion(c) else { continue }
                let rest = String(cs.dropFirst(stem.count))
                let cn = base + rest + cext
                let kind = ScannerTreeEngine.isSub(c) ? "subtitle" : "companion"
                if cn != c.fileName {
                    actions.append(PlanAction(
                        id: aid(), op: "rename", groupId: gid, fileId: c.fileId, parentId: parent,
                        oldName: c.fileName, newName: cn, destParentId: nil, destRef: nil, destLabel: nil,
                        kind: kind, mediaKind: nil, tmdbId: nil, season: nil, episode: nil, artworkUrl: nil,
                        selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil
                    ))
                }
                actions.append(ScannerTreeEngine.makeMoveAction(
                    gid: gid, entry: c, fromId: parent, name: cn,
                    destId: destPair.dirId, destLabel: name, destRef: destPair.mkdirId, kind: kind, note: "跟随电影移动"
                ))
                if kind == "companion" {
                    companions.append(CloudEntry(fileId: c.fileId, fileName: cn, isDir: false, size: c.size, parentFileId: c.parentFileId))
                }
            }

            planMovieArtwork(
                folderId: destPair.dirId, tmdbId: info.id, posterPath: info.posterPath, gid: gid,
                actions: &actions, items: companions, destRef: destPair.mkdirId, destLabel: name, full: fullScrape
            )
            groups.append(PlanGroup(
                id: gid, kind: info.kind, tmdbId: info.id,
                collectionId: info.collectionId, collectionName: info.collectionName,
                title: info.title, year: info.year, posterPath: info.posterPath,
                folderId: nil, folderName: name, folderNewName: nil,
                rating: info.rating, confidence: "中", note: "散落的电影：单独建文件夹并移入",
                warn: nil, actionIds: actions[start..<actions.count].map { $0.id }
            ))
        }
        return seen
    }

    // MARK: - 5. 电影与剧集海报/NFO 增量规划（1:1 对标 planMovieArtwork / planArtwork）

    public static func planMovieArtwork(
        folderId: String?,
        tmdbId: Int,
        posterPath: String?,
        gid: String,
        actions: inout [PlanAction],
        items: [CloudEntry],
        destRef: String? = nil,
        destLabel: String? = nil,
        full: Bool = false
    ) {
        let files = items.filter { !$0.isDir }.map { $0.fileName.lowercased() }
        let hasPoster = files.contains { f in
            guard isImageFile(f) else { return false }
            let base = stemBeforeLastDot(f)
            return ["poster", "folder", "cover", "movie"].contains(base) || base.hasSuffix("-poster")
        }
        let hasFanart = files.contains { f in
            guard isImageFile(f) else { return false }
            let base = stemBeforeLastDot(f)
            return ["fanart", "backdrop", "background"].contains(base) || base.hasSuffix("-fanart")
        }
        let hasLogo = files.contains { ExistingAssets.imageRole(of: $0) == "logo" }

        var videoStems = Set(items.filter { ScannerTreeEngine.isVideo($0) }.map { MediaParser.splitNameExt($0.fileName).0.lowercased() })
        for a in actions where a.groupId == gid && a.kind == "file" {
            videoStems.insert(MediaParser.splitNameExt(a.oldName).0.lowercased())
            videoStems.insert(MediaParser.splitNameExt(a.newName).0.lowercased())
        }
        let hasNfo = files.contains { f in
            f == "movie.nfo" || (f.hasSuffix(".nfo") && videoStems.contains(stemBeforeLastDot(f)))
        }

        func add(_ name: String, kind: String, url: String? = nil) {
            actions.append(PlanAction(
                id: aid(), op: "artwork", groupId: gid, fileId: nil, parentId: folderId,
                oldName: "", newName: name, destParentId: nil, destRef: destRef, destLabel: destLabel,
                kind: kind, mediaKind: "movie", tmdbId: tmdbId, season: nil, episode: nil, artworkUrl: url,
                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil, replaceExisting: full
            ))
        }

        if full || !hasPoster {
            add("poster.jpg", kind: "image", url: posterPath.map { "https://image.tmdb.org/t/p/w780\($0)" })
        }
        if full || !hasFanart { add("fanart.jpg", kind: "image") }
        if full || !hasLogo { add("clearlogo.png", kind: "clearlogo") }
        if full || !hasNfo { add("movie.nfo", kind: "movie_nfo") }
    }

    public static func planTvArtwork(
        folderId: String,
        folderName: String,
        show: MatchInfo,
        gid: String,
        fullScrape: Bool,
        actions: inout [PlanAction],
        items: [CloudEntry],
        newSeasonDirs: [Int: (String, String)] = [:],
        seasonItems: [String: [CloudEntry]] = [:]
    ) {
        let have = Set(items.filter { !$0.isDir }.map { $0.fileName.lowercased() })
        func missing(_ fn: String) -> Bool {
            switch fn {
            case "poster.jpg":
                return !items.contains(where: { !$0.isDir && ExistingAssets.imageRole(of: $0.fileName) == "poster" })
            case "fanart.jpg", "backdrop.jpg":
                return !items.contains(where: { !$0.isDir && ExistingAssets.imageRole(of: $0.fileName) == "background" })
            case "logo.png", "clearlogo.png":
                return !items.contains(where: { !$0.isDir && ExistingAssets.imageRole(of: $0.fileName) == "logo" })
            default:
                return !have.contains(fn)
            }
        }
        func addImage(_ fn: String, url: String?, kind: String = "image") {
            guard fullScrape || missing(fn) else { return }
            actions.append(PlanAction(
                id: aid(), op: "artwork", groupId: gid, fileId: nil, parentId: folderId,
                oldName: "", newName: fn, destParentId: nil, destRef: nil, destLabel: nil,
                kind: kind, mediaKind: "tv", tmdbId: show.id, season: nil, episode: nil, artworkUrl: url,
                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil, replaceExisting: fullScrape
            ))
        }

        addImage("poster.jpg", url: show.posterPath.map { "https://image.tmdb.org/t/p/w780\($0)" })
        addImage("fanart.jpg", url: nil)
        addImage("backdrop.jpg", url: nil)
        addImage("clearlogo.png", url: nil, kind: "clearlogo")
        if fullScrape || missing("tvshow.nfo") {
            actions.append(PlanAction(
                id: aid(), op: "artwork", groupId: gid, fileId: nil, parentId: folderId,
                oldName: "", newName: "tvshow.nfo", destParentId: nil, destRef: nil, destLabel: nil,
                kind: "tvshow_nfo", mediaKind: "tv", tmdbId: show.id, season: nil, episode: nil, artworkUrl: nil,
                selected: true, enabled: true, blocked: nil, done: false, error: nil, note: nil, replaceExisting: fullScrape
            ))
        }

        for d in items where d.isDir {
            guard let n = MediaParser.seasonFromName(d.fileName) else { continue }
            let posterName = n == 0 ? "season-specials-poster.jpg" : String(format: "season%02d-poster.jpg", n)
            let seasonPosterRx = try? NSRegularExpression(pattern: "(?i)season0*\(n)(?:-poster)?\\.(jpg|jpeg|png|webp)")
            let hasInRoot = have.contains(posterName) || have.contains { f in
                let ns = f as NSString
                return seasonPosterRx?.firstMatch(in: f, range: NSRange(location: 0, length: ns.length)) != nil
            }
            let hasInSeason = (seasonItems[d.fileId] ?? []).contains(where: { !$0.isDir && ExistingAssets.imageRole(of: $0.fileName) == "poster" })
            if fullScrape || (!hasInSeason && !hasInRoot) {
                actions.append(PlanAction(
                    id: aid(), op: "artwork", groupId: gid, fileId: nil, parentId: folderId,
                    oldName: "", newName: posterName, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "image", mediaKind: "tv", tmdbId: show.id, season: n, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: "季海报（执行时下载）", replaceExisting: fullScrape
                ))
            }
        }

        for (n, ref) in newSeasonDirs {
            let posterName = n == 0 ? "season-specials-poster.jpg" : String(format: "season%02d-poster.jpg", n)
            if fullScrape || !have.contains(posterName) {
                actions.append(PlanAction(
                    id: aid(), op: "artwork", groupId: gid, fileId: nil, parentId: folderId,
                    oldName: "", newName: posterName, destParentId: nil, destRef: nil, destLabel: nil,
                    kind: "image", mediaKind: "tv", tmdbId: show.id, season: n, episode: nil, artworkUrl: nil,
                    selected: true, enabled: true, blocked: nil, done: false, error: nil, note: "季海报（执行时下载）", replaceExisting: fullScrape
                ))
            }
        }
    }

    // MARK: - 6. 贯通模块 1 全部子引擎的默认钩子工厂

    public static func makeTvAndBdmvHooks(
        drive: any CloudDrive,
        tmdb: any ScannerTmdbProvider,
        fullScrape: Bool
    ) -> ScannerTvAndBdmvHooks {
        ScannerTvAndBdmvHooks(
            planMovieFolder: { folder, tree, allVideos, actions, groups, flags, rootTaken, forced, remembered, doneId in
                await planMovieFolder(
                    folder: folder, tree: tree, allVideos: allVideos, drive: drive, tmdb: tmdb,
                    fullScrape: fullScrape, actions: &actions, groups: &groups, flags: &flags,
                    rootTaken: &rootTaken, forced: forced, remembered: remembered, doneId: doneId
                )
            },
            planExtraMovie: { video, info, folderName, parentId, show, actions, groups, flags in
                planExtraMovie(
                    video: video, info: info, folderName: folderName, parentId: parentId, show: show,
                    fullScrape: fullScrape, actions: &actions, groups: &groups, flags: &flags
                )
            },
            planArtwork: { folderId, folderName, show, gid, actions, virtualItems, newSeasonDirs, dirItems in
                planTvArtwork(
                    folderId: folderId, folderName: folderName, show: show, gid: gid,
                    fullScrape: fullScrape, actions: &actions, items: virtualItems,
                    newSeasonDirs: newSeasonDirs, seasonItems: dirItems
                )
            }
        )
    }

    public static func makeReplanHooks(
        drive: any CloudDrive,
        tmdb: any ScannerTmdbProvider,
        fullScrape: Bool
    ) -> ScannerReplanHooks {
        let tvHooks = makeTvAndBdmvHooks(drive: drive, tmdb: tmdb, fullScrape: fullScrape)
        return ScannerReplanHooks(
            planTitleFolder: { folder, items, forced, strategy, episodeGroupId, episodeGroupName, actions, groups, flags in
                var visited = Set<String>()
                var dirPathMap: [String: String] = [:]
                var rootTaken = Set<String>()
                _ = try await ScannerTvAndBdmv.planTitleFolder(
                    folder: folder, items: items, drive: drive, tmdb: tmdb,
                    visited: &visited, dirPathMap: &dirPathMap,
                    actions: &actions, groups: &groups, flags: &flags, rootTaken: &rootTaken,
                    forced: forced, remembered: nil, strategy: strategy,
                    episodeGroupId: episodeGroupId, episodeGroupName: episodeGroupName, hooks: tvHooks
                )
            },
            planLooseFile: { dir, items, sourceFileId, info, existingMkdirs, episodeOverride, actions, groups, flags in
                var taken = Set(items.map { $0.fileName.lowercased() })
                let ov = episodeOverride.map { (fileId: sourceFileId, season: $0.0, episode: $0.1) }
                _ = await planLooseFiles(
                    dir: dir, items: items, tmdb: tmdb, fullScrape: fullScrape,
                    actions: &actions, groups: &groups, flags: &flags, taken: &taken,
                    forced: (fileId: sourceFileId, info: info), sharedMkdirs: existingMkdirs, episodeOverride: ov
                )
            }
        )
    }
}
