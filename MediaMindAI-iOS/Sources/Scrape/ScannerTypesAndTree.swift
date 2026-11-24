import Foundation

/// 1:1 逐行复刻自 Android `Scanner.kt`（L650–L1116）：
/// 目录分类器（BDMV/纯年份/分类目录/合集目录/不规范季目录推断）、
/// 过期元数据清理检测（`staleArtifacts`）、可注入 TMDB 扫描接口（`ScannerTmdbProvider`）、
/// 目录树 BFS 构建与 80 节点截断保护（`ScanTreeNode` / `buildTree`）、
/// 以及多余空目录与遗留文件删除规划（`planLeftovers`）。
public enum ScannerRole: String, Equatable, Sendable {
    case title = "TITLE"
    case container = "CONTAINER"
}

/// 扫描用的 TMDB 抽象接口（1:1 对标 Android `Scanner.Tmdb`，单元测试可替换成内存 Mock 绝不触网）。
public protocol ScannerTmdbProvider: Sendable {
    func show(names: [String], fixedId: Int?) async -> (MatchInfo?, Int)
    func movie(stem: String, fallbackNames: [String], fallbackId: Int?) async -> MatchInfo?
    func movieInfo(id: Int) async -> MatchInfo?
    func collectionOf(movieId: Int) async -> (Int, String)?
    func collectionPosterOf(movieId: Int, collectionId: Int) async -> String?
    func seasonCounts(showId: Int) async -> [Int: Int]
    func episodeGroupMap(groupId: String) async -> [EpisodeMapping.Episode: EpisodeMapping.Episode]
}

public extension ScannerTmdbProvider {
    func collectionPosterOf(movieId: Int, collectionId: Int) async -> String? { nil }
    func seasonCounts(showId: Int) async -> [Int: Int] { [:] }
    func episodeGroupMap(groupId: String) async -> [EpisodeMapping.Episode: EpisodeMapping.Episode] { [:] }
}

/// 片子文件夹内部的目录树节点（最多往下 3 层，跳过忽略目录）。
public final class ScanTreeNode: @unchecked Sendable {
    public let entry: CloudEntry
    public let items: [CloudEntry]
    public weak var parent: ScanTreeNode?
    public let depth: Int

    public var id: String { entry.fileId }

    public init(entry: CloudEntry, items: [CloudEntry], parent: ScanTreeNode?, depth: Int) {
        self.entry = entry
        self.items = items
        self.parent = parent
        self.depth = depth
    }

    public func chain() -> [ScanTreeNode] {
        var result: [ScanTreeNode] = []
        var cur: ScanTreeNode? = self
        while let n = cur {
            result.append(n)
            cur = n.parent
        }
        return result
    }

    /// 根目录下的直属子目录（自己在根下就是自己）。
    public func holder(root: ScanTreeNode) -> ScanTreeNode? {
        ScannerTreeEngine.holderOf(node: self, root: root, parent: { $0.parent })
    }

    public func pathFrom(root: ScanTreeNode) -> String {
        var parts: [String] = []
        var cur: ScanTreeNode? = self
        while let n = cur, n !== root {
            parts.append(n.entry.fileName)
            cur = n.parent
        }
        return parts.reversed().joined(separator: "/")
    }
}

public enum ScannerTreeEngine {
    public static let trashDir = "_刮削旧文件"
    public static let maxTreeNodes = 80

    public static let companionExts: Set<String> = [".jpg", ".jpeg", ".png", ".webp", ".nfo"]

    private static let seasonArtRx = try! NSRegularExpression(
        pattern: #"^season(\d{2}|-specials)-(poster|fanart|banner|landscape)\.(jpg|png)$"#,
        options: [.caseInsensitive]
    )
    private static let sharedArtifactNames: Set<String> = [
        "poster.jpg", "fanart.jpg", "clearlogo.png", "banner.jpg", "landscape.jpg", "folder.jpg",
    ]
    private static let specialDirRx = try! NSRegularExpression(
        pattern: #"^\s*(?:花絮|番外|番外篇|特典|特别篇|特別篇|SPs?|OVAs?|OADs?|Specials?|加更|彩蛋|纯享|纯享版|先导|先导片|幕后)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let yearOnlyRx = try! NSRegularExpression(pattern: #"^(?:19|20)\d{2}$"#)

    private static let genericDirs: Set<String> = [
        "new folder", "新建文件夹", "未命名", "未命名文件夹", "untitled", "download", "downloads",
        "下载", "我的资源", "资源", "分享", "temp", "tmp", "misc", "other", "默认",
    ]

    private static let categoryDirs: Set<String> = [
        "电影", "剧集", "电视剧", "动漫", "番剧", "综艺", "纪录片", "动画", "短剧", "影视", "美剧", "日剧",
        "韩剧", "港剧", "台剧", "国产剧", "国产", "欧美", "华语", "日韩", "英剧", "泰剧", "4k", "hdr",
        "movies", "movie", "tv", "tv shows", "shows", "series", "anime", "animation", "documentary",
        "documentaries", "variety", "videos", "video", "media", "cinema", "films", "film",
    ]

    private static let collectionHints: [String] = [
        "合集", "系列", "全集", "全系列", "三部曲", "四部曲", "五部曲", "部曲", "collection", "trilogy", "anthology", "saga",
    ]

    /// 本应用生成的、和新匹配不符的过期文件（1:1 复刻 `Scanner.staleArtifacts`）。
    public static func staleArtifacts(items: [CloudEntry], newKind: String, matchChanged: Bool) -> [CloudEntry] {
        items.filter { !$0.isDir }.filter { entry in
            let n = entry.fileName.lowercased()
            let ns = n as NSString
            let isSeasonArt = seasonArtRx.firstMatch(in: n, range: NSRange(location: 0, length: ns.length)) != nil
            if n == "tvshow.nfo" || isSeasonArt || n == "season.nfo" {
                return newKind == "movie" || matchChanged
            }
            if n == "movie.nfo" {
                return newKind == "tv" || matchChanged
            }
            if sharedArtifactNames.contains(n) {
                return matchChanged
            }
            return false
        }
    }

    public static func isVideo(_ e: CloudEntry) -> Bool {
        !e.isDir && MediaParser.isVideo(e.fileName)
    }

    public static func isSub(_ e: CloudEntry) -> Bool {
        !e.isDir && MediaParser.isSubtitle(e.fileName)
    }

    public static func isCompanion(_ e: CloudEntry) -> Bool {
        guard !e.isDir else { return false }
        let ext = "." + URL(fileURLWithPath: e.fileName).pathExtension.lowercased()
        return companionExts.contains(ext)
    }

    public static func ignoredDir(_ name: String) -> Bool {
        ScannerHeuristics.ignoredDir(name)
    }

    public static func isGenericDir(_ name: String) -> Bool {
        genericDirs.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func isCategoryDir(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if categoryDirs.contains(lower) { return true }
        let ns = trimmed as NSString
        return yearOnlyRx.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
    }

    public static func looksLikeCollectionName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return collectionHints.contains { lower.contains($0) }
    }

    private static let anchoredSeasonNumRx = try! NSRegularExpression(
        pattern: #"^\s*(?:Season|S)[._\s-]*(\d{1,2})\s*$"#,
        options: [.caseInsensitive]
    )
    private static let anchoredSeasonCnRx = try! NSRegularExpression(
        pattern: #"^\s*第\s*([0-9一二三四五六七八九十两百]{1,4})\s*季\s*$"#
    )

    /// 目录名对应的季号（严格全串锚点：季文件夹 / 特别篇文件夹 → 0；含片名的剧集根目录如「权力的游戏 第1季」返回 nil）。
    public static func seasonOfDir(_ name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        if specialDirRx.firstMatch(in: trimmed, range: range) != nil {
            return 0
        }
        if let m = anchoredSeasonNumRx.firstMatch(in: trimmed, range: range),
           m.range(at: 1).location != NSNotFound,
           let n = Int(ns.substring(with: m.range(at: 1))), (0...99).contains(n) {
            return n
        }
        if let m = anchoredSeasonCnRx.firstMatch(in: trimmed, range: range),
           m.range(at: 1).location != NSNotFound {
            return MediaParser.seasonFromName(trimmed)
        }
        return nil
    }

    /// 像片名的子目录（不是季 / 特别篇 / 无意义 / 分类 / 忽略目录）。
    public static func titleLikeDir(_ name: String) -> Bool {
        seasonOfDir(name) == nil && !isGenericDir(name) && !ignoredDir(name) && !isCategoryDir(name)
    }

    /// 1:1 复刻 `Scanner.classify(d, kids)`：判断目录是「一部片子」还是「分类 / 归档目录」。
    public static func classify(
        dir: CloudEntry,
        kids: [CloudEntry],
        list: (String) async throws -> [CloudEntry]
    ) async throws -> ScannerRole {
        let name = dir.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let vids = kids.filter { isVideo($0) }
        let allSubDirs = kids.filter { $0.isDir }
        if StandardNaming.isBdmvRoot(directChildDirNames: allSubDirs.map { $0.fileName }) {
            return .title
        }
        let dirs = allSubDirs.filter { !ignoredDir($0.fileName) }

        if isCategoryDir(name) {
            let ns = name as NSString
            let yearOnly = yearOnlyRx.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) != nil
            return (yearOnly && !vids.isEmpty && dirs.isEmpty) ? .title : .container
        }
        if isGenericDir(name) {
            return .container
        }

        let titleDirs = dirs.filter { titleLikeDir($0.fileName) }
        if looksLikeCollectionName(name) && !titleDirs.isEmpty {
            return .container
        }
        if dirs.contains(where: { seasonOfDir($0.fileName) != nil }) {
            return .title
        }
        if titleDirs.isEmpty {
            return .title
        }

        let epVids = vids.filter { MediaParser.parse($0.fileName).episode != nil }.count
        if !vids.isEmpty {
            if epVids > 0 && titleDirs.count <= 1 { return .title }     // 剧集 + 一个杂项目录
            if vids.count == 1 && epVids == 0 { return .title }         // 单部电影 + 杂项目录
            return .container                                           // 多部散落电影 + 别的片子文件夹
        }

        // 没有直属视频、只有像片名的子目录：子目录名都含本目录的片名、且里面是剧集 → 本目录是剧
        let core = TitleScorer.normalizeTitle(MediaParser.parse(name).cleanTitle)
        if core.count < 2 || titleDirs.count > 4 { return .container }
        if !titleDirs.allSatisfy({ TitleScorer.normalizeTitle($0.fileName).contains(core) }) {
            return .container
        }
        for c in titleDirs {
            let ck = try await list(c.fileId)
            if ck.contains(where: { $0.isDir && seasonOfDir($0.fileName) != nil }) {
                return .container // 子目录才是真正的剧
            }
            if !ck.contains(where: { isVideo($0) && MediaParser.parse($0.fileName).episode != nil }) {
                return .container
            }
        }
        return .title
    }

    public static func joinDirPath(parent: String?, name: String) -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanParent = (parent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleanParent.isEmpty || cleanParent == "根目录" {
            return cleanName.isEmpty ? "/" : "/\(cleanName)"
        }
        let prefixedParent = "/\(cleanParent)"
        if cleanName.isEmpty { return prefixedParent }
        if prefixedParent.hasSuffix("/\(cleanName)") || cleanParent == cleanName {
            return prefixedParent
        }
        return "\(prefixedParent)/\(cleanName)"
    }

    /// M10 守卫：节点在 root 下的直属子目录；不在树内或本身是 root 返回 nil。
    public static func holderOf<T: AnyObject>(node: T, root: T, parent: (T) -> T?) -> T? {
        if node === root { return nil }
        var cur = node
        while true {
            guard let p = parent(cur) else { return nil }
            if p === root { return cur }
            cur = p
        }
    }

    public static func truncatedFlag(folder: String) -> String {
        "「\(folder)」文件太多，只扫描了前 \(maxTreeNodes) 项（其余子文件夹没有处理，可以分开选择这些子文件夹再扫描）"
    }

    public static func subtree(node: ScanTreeNode, in tree: [ScanTreeNode]) -> [ScanTreeNode] {
        tree.filter { t in t.chain().contains(where: { $0 === node }) }
    }

    /// 1:1 复刻 `Scanner.buildTree`：BFS 构建最多 `maxDepth` 层、最多 `maxTreeNodes` 个节点的目录树，支持并发预取。
    public static func buildTree(
        folder: CloudEntry,
        items: [CloudEntry],
        descend: Bool,
        maxDepth: Int = 3,
        flags: inout [String],
        visited: Set<String>,
        dirPathMap: inout [String: String],
        maxConcurrentReads: Int = 4,
        list: @escaping @Sendable (String) async throws -> [CloudEntry]
    ) async throws -> [ScanTreeNode] {
        let root = ScanTreeNode(entry: folder, items: items, parent: nil, depth: 0)
        var out: [ScanTreeNode] = [root]
        if !descend { return out }

        var seen: Set<String> = [folder.fileId]
        var queue: [ScanTreeNode] = [root]
        var head = 0
        let width = max(2, min(8, maxConcurrentReads))

        while head < queue.count {
            let n = queue[head]
            head += 1
            if n.depth >= maxDepth { continue }

            var pendingDirs: [CloudEntry] = []
            for d in n.items where d.isDir {
                if ignoredDir(d.fileName) || visited.contains(d.fileId) || !seen.insert(d.fileId).inserted {
                    continue
                }
                if out.count + pendingDirs.count >= maxTreeNodes {
                    let f = truncatedFlag(folder: folder.fileName)
                    if !flags.contains(f) { flags.append(f) }
                    break
                }
                pendingDirs.append(d)
            }

            if pendingDirs.isEmpty { continue }

            var fetched: [(CloudEntry, [CloudEntry])] = []
            if pendingDirs.count > 1 {
                // 分批并发预取，严格遵守网盘并发上限
                var idx = 0
                while idx < pendingDirs.count {
                    let end = min(idx + width, pendingDirs.count)
                    let chunk = Array(pendingDirs[idx..<end])
                    let chunkRes = try await withThrowingTaskGroup(of: (Int, CloudEntry, [CloudEntry]).self) { tg in
                        for (offset, d) in chunk.enumerated() {
                            tg.addTask {
                                let kids = try await list(d.fileId)
                                return (offset, d, kids)
                            }
                        }
                        var buf: [(Int, CloudEntry, [CloudEntry])] = []
                        for try await item in tg { buf.append(item) }
                        return buf.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
                    }
                    fetched.append(contentsOf: chunkRes)
                    idx = end
                }
            } else {
                let d = pendingDirs[0]
                let kids = try await list(d.fileId)
                fetched.append((d, kids))
            }

            for (d, childItems) in fetched {
                let normalizedEntry = d.parentFileId == nil
                    ? CloudEntry(
                        fileId: d.fileId,
                        fileName: d.fileName,
                        isDir: d.isDir,
                        size: d.size,
                        parentFileId: n.id,
                        etag: d.etag,
                        contentHash: d.contentHash,
                        hashAlgorithm: d.hashAlgorithm
                    )
                    : d
                let c = ScanTreeNode(entry: normalizedEntry, items: childItems, parent: n, depth: n.depth + 1)
                dirPathMap[c.id] = joinDirPath(parent: dirPathMap[n.id] ?? n.entry.fileName, name: c.entry.fileName)
                out.append(c)
                queue.append(c)
            }
        }
        return out
    }

    /// 1:1 复刻 `Scanner.planLeftovers`：视频/字幕都被移走且本身非目标季目录的多余目录，生成默认不勾选的删除操作。
    public static func planLeftovers(
        root: ScanTreeNode,
        tree: [ScanTreeNode],
        keepIds: Set<String>,
        movedIds: Set<String>,
        gid: String,
        trashSupportLabel: String,
        trashBlockedHint: String?,
        actions: inout [PlanAction]
    ) {
        let movedFromIds = Set(tree.filter { n in n.items.contains(where: { movedIds.contains($0.fileId) }) }.map { $0.id })
        if movedFromIds.isEmpty { return }

        var redundantNodes: [ScanTreeNode] = []
        var redundantIds = Set<String>()
        for n in tree {
            guard n !== root, !keepIds.contains(n.id) else { continue }
            let hasKeptDescendant = tree.contains { t in keepIds.contains(t.id) && t.chain().contains(where: { $0 === n }) }
            if hasKeptDescendant { continue }
            let sub = subtree(node: n, in: tree)
            if sub.contains(where: { movedFromIds.contains($0.id) }) {
                redundantNodes.append(n)
                redundantIds.insert(n.id)
            }
        }

        for n in redundantNodes where n.parent.map({ !redundantIds.contains($0.id) }) ?? true {
            let sub = subtree(node: n, in: tree)
            let treeIds = Set(tree.map { $0.id })
            let others = sub.flatMap { s in s.items.filter { !$0.isDir && !movedIds.contains($0.fileId) } }
            let unlisted = sub.flatMap { s in s.items.filter { $0.isDir && !treeIds.contains($0.fileId) } }
            let rest = others.map { $0.fileName } + unlisted.map { $0.fileName + "/" }
            let note: String
            if rest.isEmpty {
                note = "移走视频后这个文件夹是空的 · \(trashSupportLabel)"
            } else {
                let head = rest.prefix(3).joined(separator: "、")
                let suffix = rest.count > 3 ? " 等" : ""
                note = "移走视频后仍有其它文件 \(rest.count) 个：\(head)\(suffix)，删除时会一起删除 · \(trashSupportLabel)"
            }
            actions.append(PlanAction(
                id: String(UUID().uuidString.prefix(8)),
                op: "delete",
                groupId: gid,
                fileId: n.id,
                parentId: n.parent?.id,
                oldName: n.pathFrom(root: root),
                newName: "",
                destParentId: nil,
                destRef: nil,
                destLabel: nil,
                kind: "leftover",
                mediaKind: nil,
                tmdbId: nil,
                season: nil,
                episode: nil,
                artworkUrl: nil,
                selected: false,
                enabled: true,
                blocked: trashBlockedHint,
                done: false,
                error: nil,
                note: note
            ))
        }
    }

    public static func makeMoveAction(
        gid: String,
        entry: CloudEntry,
        fromId: String,
        name: String,
        destId: String?,
        destLabel: String,
        destRef: String?,
        kind: String,
        note: String? = nil,
        season: Int? = nil,
        episode: Int? = nil
    ) -> PlanAction {
        PlanAction(
            id: String(UUID().uuidString.prefix(8)),
            op: "move",
            groupId: gid,
            fileId: entry.fileId,
            parentId: fromId,
            oldName: name,
            newName: name,
            destParentId: destId,
            destRef: destRef,
            destLabel: destLabel,
            kind: kind,
            mediaKind: nil,
            tmdbId: nil,
            season: season,
            episode: episode,
            artworkUrl: nil,
            selected: true,
            enabled: true,
            blocked: nil,
            done: false,
            error: nil,
            note: note
        )
    }
}
