import Foundation
import Observation

/// 跨目录同系列电影与同剧多季归并器（1:1 移植自 Android SeriesMerger.kt）。
public enum SeriesMerger {
    /// 对扫描生成的计划执行跨目录归并：
    /// 1. 同一 TMDB 合集的 2 部以上独立电影目录（且位于同一父目录下）→ 建立 `{tmdb-collection-ID}` 目录并移入；
    /// 2. 同一 TMDB ID 的多季独立剧集目录 → 合并到主剧集目录并保留各自 Season 文件夹。
    public static func mergeIfEnabled(
        _ plan: ScrapePlan,
        enabled: Bool,
        appendTag: Bool,
        mergeMovies: Bool? = nil,
        mergeTv: Bool? = nil
    ) -> ScrapePlan {
        let doMovies = enabled && (mergeMovies ?? true)
        let doTv = enabled && (mergeTv ?? true)
        guard doMovies || doTv else { return plan }
        var out = plan

        // 1. 跨目录同剧多季归并：自动提级 Season XX 子目录 / 重定向缺失季 mkdir 至主剧集目录，避免多套一层外层目录
        let tvGroups = doTv ? out.groups.filter { $0.kind == "tv" && $0.tmdbId != nil } : []
        let byShow = Dictionary(grouping: tvGroups) { $0.tmdbId ?? -1 }.filter { $0.key > 0 && $0.value.count >= 2 }
        for (showId, list) in byShow {
            let primary = list[0]
            guard let primaryFolderId = primary.folderId else { continue }
            for dup in list.dropFirst() {
                guard let dupFolderId = dup.folderId, dupFolderId != primaryFolderId else { continue }

                // 情况 A：dup 下本来就存在待新建的 Season XX mkdir（散落文件），直接把 mkdir 父目录重定向到 primaryFolderId
                var redirectedSeasonMkdir = false
                for aIdx in out.actions.indices {
                    let a = out.actions[aIdx]
                    if a.groupId == dup.id && a.op == "mkdir" && a.kind == "folder" && a.parentId == dupFolderId && a.season != nil {
                        out.actions[aIdx].parentId = primaryFolderId
                        out.actions[aIdx].destParentId = primaryFolderId
                        redirectedSeasonMkdir = true
                    }
                }

                // 情况 B：dup 内已有独立的季子目录（如 Season 02 / S02），直接把季子目录移入 primaryFolderId 成为主剧集下的 Season XX
                var seasonSubdirIds: [(id: String, name: String, season: Int?)] = []
                var seenSubIds = Set<String>()
                for a in out.actions where a.groupId == dup.id {
                    if a.op == "rename" && a.kind == "folder" && a.fileId != dupFolderId,
                       let fid = a.fileId, a.parentId == dupFolderId, !seenSubIds.contains(fid) {
                        seenSubIds.insert(fid)
                        seasonSubdirIds.append((fid, a.newName.isEmpty ? a.oldName : a.newName, a.season))
                    } else if (a.kind == "file" || a.kind == "subtitle" || a.kind == "companion"),
                              let pid = a.parentId, pid != dupFolderId, !seenSubIds.contains(pid) {
                        seenSubIds.insert(pid)
                        let sLabel = a.season.map { StandardNaming.seasonDirName($0) } ?? dup.folderName
                        seasonSubdirIds.append((pid, sLabel, a.season))
                    }
                }

                if !seasonSubdirIds.isEmpty {
                    for sub in seasonSubdirIds {
                        if out.actions.contains(where: { $0.op == "move" && $0.kind == "folder" && $0.fileId == sub.id && $0.destParentId == primaryFolderId }) {
                            continue
                        }
                        let moveAct = PlanAction(
                            id: "merge-\(UUID().uuidString.prefix(8).lowercased())",
                            op: "move",
                            groupId: primary.id,
                            fileId: sub.id,
                            parentId: dupFolderId,
                            oldName: sub.name,
                            newName: sub.name,
                            destParentId: primaryFolderId,
                            destRef: nil,
                            kind: "folder",
                            mediaKind: "tv",
                            tmdbId: showId,
                            season: sub.season,
                            episode: nil,
                            artworkUrl: nil,
                            selected: true,
                            done: false,
                            error: nil,
                            note: "同剧多季归并：将「\(sub.name)」直接移入《\(primary.title)》"
                        )
                        out.actions.append(moveAct)
                        if let pIdx = out.groups.firstIndex(where: { $0.id == primary.id }) {
                            out.groups[pIdx].actionIds.append(moveAct.id)
                        }
                    }
                    out.flags.append("同剧多季归并：已将「\(dup.folderName)」季目录合并至「\(primary.folderName)」")
                } else if redirectedSeasonMkdir {
                    out.flags.append("同剧多季归并：已将「\(dup.folderName)」分集规划移入「\(primary.folderName)」")
                } else {
                    if out.actions.contains(where: { $0.op == "move" && $0.kind == "folder" && $0.fileId == dupFolderId && $0.destParentId == primaryFolderId }) {
                        continue
                    }
                    let origParent = out.actions.first(where: { $0.fileId == dupFolderId })?.parentId
                    let moveAct = PlanAction(
                        id: "merge-\(UUID().uuidString.prefix(8).lowercased())",
                        op: "move",
                        groupId: primary.id,
                        fileId: dupFolderId,
                        parentId: origParent,
                        oldName: dup.folderName,
                        newName: dup.folderName,
                        destParentId: primaryFolderId,
                        destRef: nil,
                        kind: "folder",
                        mediaKind: "tv",
                        tmdbId: showId,
                        season: nil,
                        episode: nil,
                        artworkUrl: nil,
                        selected: true,
                        done: false,
                        error: nil,
                        note: "同剧多季跨目录归并至《\(primary.title)》"
                    )
                    out.actions.append(moveAct)
                    if let pIdx = out.groups.firstIndex(where: { $0.id == primary.id }) {
                        out.groups[pIdx].actionIds.append(moveAct.id)
                    }
                    out.flags.append("同剧多季归并：已将「\(dup.folderName)」规划移入「\(primary.folderName)」")
                }
            }
        }

        // 2. 跨目录同系列电影合集归并（同一父目录下 2 部以上属于同一 TMDB Collection 的独立电影目录）
        let movieColGroups = doMovies ? out.groups.filter { $0.kind == "movie" && $0.collectionId != nil && $0.folderId != nil } : []
        let byCol = Dictionary(grouping: movieColGroups) { $0.collectionId ?? -1 }.filter { $0.key > 0 && $0.value.count >= 2 }
        for (cid, list) in byCol {
            // 仅当这些电影目录共享同一个父目录时才建合集文件夹，避免跨磁盘/跨根目录误移
            let parents = Set(list.compactMap { g in out.actions.first(where: { $0.fileId == g.folderId })?.parentId })
            guard parents.count == 1, let sharedParent = parents.first else { continue }
            let colName = list.compactMap(\.collectionName).first ?? list[0].title
            let colFolderName = MediaParser.buildCollectionName(name: colName, collectionId: cid, appendTag: appendTag)
            if out.actions.contains(where: { $0.op == "mkdir" && $0.mediaKind == "collection" && $0.tmdbId == cid && $0.parentId == sharedParent }) {
                continue
            }
            let mkId = "mkcol-\(UUID().uuidString.prefix(8).lowercased())"
            let primaryGroupId = list[0].id
            out.actions.append(PlanAction(
                id: mkId,
                op: "mkdir",
                groupId: primaryGroupId,
                fileId: nil,
                parentId: sharedParent,
                oldName: "",
                newName: colFolderName,
                destParentId: sharedParent,
                destRef: nil,
                kind: "folder",
                mediaKind: "collection",
                tmdbId: cid,
                season: nil,
                episode: nil,
                artworkUrl: nil,
                selected: true,
                done: false,
                error: nil,
                note: "创建电影系列合集目录"
            ))
            var addedColIds: [String] = [mkId]
            for mv in list {
                guard let fid = mv.folderId else { continue }
                let mvId = "mvcol-\(UUID().uuidString.prefix(8).lowercased())"
                addedColIds.append(mvId)
                out.actions.append(PlanAction(
                    id: mvId,
                    op: "move",
                    groupId: primaryGroupId,
                    fileId: fid,
                    parentId: sharedParent,
                    oldName: mv.folderName,
                    newName: mv.folderName,
                    destParentId: nil,
                    destRef: mkId,
                    kind: "folder",
                    mediaKind: "movie",
                    tmdbId: mv.tmdbId,
                    season: nil,
                    episode: nil,
                    artworkUrl: nil,
                    selected: true,
                    done: false,
                    error: nil,
                    note: "归并至系列合集「\(colFolderName)」"
                ))
            }
            if let pIdx = out.groups.firstIndex(where: { $0.id == primaryGroupId }) {
                out.groups[pIdx].actionIds.append(contentsOf: addedColIds)
            }
            out.flags.append("同系列电影归并：已将 \(list.count) 部《\(colName)》电影规划归入「\(colFolderName)」")
        }

        return mergeSplitTvSeasons(out, mergeMovies: doMovies, mergeTv: doTv)
    }

    /// 跨文件夹合并同剧多季与同系列电影合集为同一张作品卡（即使文件分散在不同目录）。
    public static func mergeSplitTvSeasons(_ plan: ScrapePlan, mergeMovies: Bool = true, mergeTv: Bool = true) -> ScrapePlan {
        var remap: [String: String] = [:]
        var upgradedCollectionTitle: [String: String] = [:]
        var droppedDuplicateFolderRenameIds = Set<String>()
        var extraFlags: [String] = []

        // 1. 同一 TMDB 剧集（即使分散在不同目录）统一合并到主作品卡
        let tvGroups = mergeTv ? plan.groups.filter { $0.kind == "tv" && ($0.tmdbId ?? 0) > 0 } : []
        let byShow = Dictionary(grouping: tvGroups) { $0.tmdbId ?? -1 }
        for (_, bucket) in byShow where bucket.count >= 2 {
            let primary = bucket[0]
            for extra in bucket.dropFirst() {
                remap[extra.id] = primary.id
                // 避免副目录与主目录重命名为相同剧集目录名，并去重副目录重复的整剧级素材
                let dupArtNames: Set<String> = ["tvshow.nfo", "poster.jpg", "fanart.jpg", "backdrop.jpg", "clearlogo.png"]
                for act in plan.actions where act.groupId == extra.id {
                    if let fid = extra.folderId, act.op == "rename", act.kind == "folder", act.fileId == fid {
                        droppedDuplicateFolderRenameIds.insert(act.id)
                    } else if act.kind == AdaptiveDirectoryPlanner.kindAdaptiveMove {
                        droppedDuplicateFolderRenameIds.insert(act.id)
                    } else if act.op == "artwork", dupArtNames.contains(act.newName.lowercased()) {
                        droppedDuplicateFolderRenameIds.insert(act.id)
                    }
                }
            }
            extraFlags.append("已合并《\(primary.title)》跨目录 \(bucket.count) 组剧集为同一作品卡")
        }

        // 2. 同一 TMDB 系列电影合集（即使分散在不同目录）统一合并为一张合集作品卡
        let movieGroups = mergeMovies ? plan.groups.filter { $0.kind == "movie" && ($0.collectionId ?? 0) > 0 } : []
        let byCollection = Dictionary(grouping: movieGroups) { $0.collectionId ?? -1 }
        for (_, bucket) in byCollection where bucket.count >= 2 {
            let primary = bucket[0]
            let colName = bucket.compactMap(\.collectionName).first(where: { !$0.isEmpty }) ?? primary.title
            upgradedCollectionTitle[primary.id] = colName
            for extra in bucket.dropFirst() {
                remap[extra.id] = primary.id
            }
            extraFlags.append("已合并《\(colName)》系列 \(bucket.count) 部电影为同一作品卡")
        }

        guard !remap.isEmpty else { return plan }
        let newActions = plan.actions.compactMap { a -> PlanAction? in
            if droppedDuplicateFolderRenameIds.contains(a.id) { return nil }
            guard let targetGid = remap[a.groupId] else { return a }
            return PlanAction(
                id: a.id, op: a.op, groupId: targetGid, fileId: a.fileId, parentId: a.parentId,
                oldName: a.oldName, newName: a.newName, destParentId: a.destParentId, destRef: a.destRef,
                destLabel: a.destLabel, kind: a.kind, mediaKind: a.mediaKind, tmdbId: a.tmdbId,
                season: a.season, episode: a.episode, artworkUrl: a.artworkUrl,
                selected: a.selected, enabled: a.enabled, blocked: a.blocked,
                done: a.done, error: a.error, note: a.note,
                metadataSeason: a.metadataSeason, metadataEpisode: a.metadataEpisode,
                replaceExisting: a.replaceExisting, folderPath: a.folderPath
            )
        }
        let newGroups = plan.groups.filter { remap[$0.id] == nil }.map { g -> PlanGroup in
            var copy = g
            if let colTitle = upgradedCollectionTitle[copy.id] {
                copy.kind = "collection"
                copy.title = colTitle
            }
            copy.actionIds = newActions.filter { $0.groupId == copy.id }.map { $0.id }
            return copy
        }
        var out = plan
        out.actions = newActions
        out.groups = newGroups
        out.flags.append(contentsOf: extraFlags)
        return out
    }
}

/// 命名冲突检测器（对标 Android 扫描冲突保护）。
public enum ConflictDetector {
    public struct Conflict: Identifiable, Sendable {
        public let id = UUID()
        public let parentId: String
        public let targetName: String
        public let actionIds: [String]

        public init(parentId: String, targetName: String, actionIds: [String]) {
            self.parentId = parentId
            self.targetName = targetName
            self.actionIds = actionIds
        }
    }

    public static func detect(in actions: [PlanAction]) -> [Conflict] {
        let grouped = Dictionary(grouping: actions.filter { $0.selected && !$0.done && !$0.newName.isEmpty }) { act -> String in
            let p = act.destRef ?? act.destParentId ?? act.parentId ?? "root"
            return "\(p)|\(act.newName.lowercased())"
        }
        return grouped.compactMap { (_, list) in
            guard list.count > 1 else { return nil }
            let first = list[0]
            return Conflict(parentId: first.destParentId ?? first.parentId ?? "root", targetName: first.newName, actionIds: list.map(\.id))
        }
    }
}

/// 保留区项（对标 Android RetentionZone：用于暂存待人工确认删除/洗版/隔离的文件，避免误删）。
public struct RetentionItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let accountId: String
    public let provider: String
    public let fileId: String
    public let fileName: String
    public let originalParentId: String
    public let reason: String
    public let parkedAt: Date

    public init(id: String = String(UUID().uuidString.prefix(8)), accountId: String, provider: String, fileId: String, fileName: String, originalParentId: String, reason: String, parkedAt: Date = Date()) {
        self.id = id
        self.accountId = accountId
        self.provider = provider
        self.fileId = fileId
        self.fileName = fileName
        self.originalParentId = originalParentId
        self.reason = reason
        self.parkedAt = parkedAt
    }
}

@MainActor
@Observable
public final class RetentionZoneStore {
    public static let shared = RetentionZoneStore()

    public private(set) var items: [RetentionItem] = []
    private let fileUrl: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("MediaMindAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileUrl = folder.appendingPathComponent("retention_zone.json")
        if let data = try? Data(contentsOf: fileUrl), let list = try? JSONDecoder().decode([RetentionItem].self, from: data) {
            self.items = list
        }
    }

    public func add(_ item: RetentionItem) {
        if !items.contains(where: { $0.accountId == item.accountId && $0.fileId == item.fileId }) {
            items.insert(item, at: 0)
            persist()
        }
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        items.removeAll()
        try? FileManager.default.removeItem(at: fileUrl)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileUrl, options: .atomic)
        }
    }
}
