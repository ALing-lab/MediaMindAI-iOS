import Foundation

/// 1:1 逐行复刻自 Android `Scanner.kt`（L165–L650）：
/// 群组手动重新匹配（含旧刮削产物 `_刮削旧文件` 回收、剧集转电影 Season 拆包防重名、保留目标库/分集资产/禁用类别/未勾选状态）、
/// 单文件与多文件批量重规划（同作品自动归并为单张作品卡）、多分组独立季/年/系列分部重规划（`replanTargetGroups`）、
/// 系列电影单文件 5 级优先分配器（`pickSeriesMovieForFile`）以及散文件重规划共享 `mkdir` 保留逻辑。
public struct GroupMatchOverride: Identifiable, Codable, Hashable, Sendable {
    public let key: String
    public let actionIds: [String]
    public let season: Int?
    public let episode: Int?
    public let year: String
    public let seriesIndex: Int?
    public let fileSeriesIndices: [String: Int]

    public var id: String { key }

    public init(
        key: String,
        actionIds: [String],
        season: Int? = nil,
        episode: Int? = nil,
        year: String = "",
        seriesIndex: Int? = nil,
        fileSeriesIndices: [String: Int] = [:]
    ) {
        self.key = key
        self.actionIds = actionIds
        self.season = season
        self.episode = episode
        self.year = year
        self.seriesIndex = seriesIndex
        self.fileSeriesIndices = fileSeriesIndices
    }
}

public enum ScannerReplanError: LocalizedError {
    case groupNotFound
    case alreadyExecuted
    case looseStrategyUnsupported
    case accountMismatch
    case fileAlreadyProcessed
    case missingSourceInfo
    case invalidSeasonEpisode
    case missingSourceVideo
    case sourceVideoChanged
    case duplicateInOtherAction
    case emptyReplan
    case mixedMovieAndTvDirectory

    public var errorDescription: String? {
        switch self {
        case .groupNotFound: return "找不到分组"
        case .alreadyExecuted: return "该分组包含已提交或完成的操作，请只识别剩余文件，或重新扫描后再匹配"
        case .looseStrategyUnsupported: return "散文件请先按剧集文件夹重新扫描，再切换剧集策略"
        case .accountMismatch: return "网盘账号与计划不一致"
        case .fileAlreadyProcessed: return "该文件已被处理，请刷新预览"
        case .missingSourceInfo: return "缺少来源文件信息，请重新扫描"
        case .invalidSeasonEpisode: return "季集编号无效"
        case .missingSourceVideo: return "找不到源视频，请重新扫描"
        case .sourceVideoChanged: return "源视频已变化，请重新扫描"
        case .duplicateInOtherAction: return "文件已包含在其他整理操作中，请重新扫描"
        case .emptyReplan: return "重新匹配未生成计划"
        case .mixedMovieAndTvDirectory: return "该目录包含独立电影分组，请将剧集与电影分开后重新扫描，再调整单片策略"
        }
    }
}

/// 标题目录 / 散文件规划回调签名（供 Batch 1.3/1.4 注入真实 1:1 规划器或单测注入）。
public struct ScannerReplanHooks: Sendable {
    public let planTitleFolder: @Sendable (
        _ folder: CloudEntry,
        _ items: [CloudEntry],
        _ forced: MatchInfo,
        _ strategy: EpisodeStrategy,
        _ episodeGroupId: String?,
        _ episodeGroupName: String?,
        _ actions: inout [PlanAction],
        _ groups: inout [PlanGroup],
        _ flags: inout [String]
    ) async throws -> Void

    public let planLooseFile: @Sendable (
        _ dir: CloudEntry,
        _ items: [CloudEntry],
        _ sourceFileId: String,
        _ info: MatchInfo,
        _ existingMkdirs: [PlanAction],
        _ episodeOverride: (Int, Int)?,
        _ actions: inout [PlanAction],
        _ groups: inout [PlanGroup],
        _ flags: inout [String]
    ) async throws -> Void

    public init(
        planTitleFolder: @escaping @Sendable (
            CloudEntry, [CloudEntry], MatchInfo, EpisodeStrategy, String?, String?,
            inout [PlanAction], inout [PlanGroup], inout [String]
        ) async throws -> Void,
        planLooseFile: @escaping @Sendable (
            CloudEntry, [CloudEntry], String, MatchInfo, [PlanAction], (Int, Int)?,
            inout [PlanAction], inout [PlanGroup], inout [String]
        ) async throws -> Void
    ) {
        self.planTitleFolder = planTitleFolder
        self.planLooseFile = planLooseFile
    }
}

public enum ScannerReplan {
    private static let trailingDigitsRx = try! NSRegularExpression(pattern: #"[\s:：\-]*\d+.*$"#)
    private static let year4Rx = try! NSRegularExpression(pattern: #"(?<!\d)(19\d{2}|20\d{2})(?!\d)"#)
    private static let subtitleRx = try! NSRegularExpression(pattern: #"[：:]\s*(.+)$"#)
    private static let endNumRx = try! NSRegularExpression(pattern: #"(\d{1,2})\s*$"#)

    private static func aid() -> String { String(UUID().uuidString.prefix(8)) }

    // MARK: - 1. 群组手动重规划（1:1 对标 Scanner.replanGroupLocked）

    public static func replanGroup(
        plan: ScrapePlan,
        groupId: String,
        info: MatchInfo,
        cloud: any CloudDrive,
        strategy: EpisodeStrategy? = nil,
        episodeGroupId: String? = nil,
        episodeGroupName: String? = nil,
        policyOverride: PolicyOverride? = nil,
        hooks: ScannerReplanHooks
    ) async throws -> ScrapePlan {
        guard let old = plan.groups.first(where: { $0.id == groupId }) else {
            throw ScannerReplanError.groupNotFound
        }
        let submitted = Set(plan.submittedActionIds ?? [])
        guard !plan.actions.contains(where: { $0.groupId == groupId && ($0.done || submitted.contains($0.id)) }) else {
            throw ScannerReplanError.alreadyExecuted
        }
        let sameShowForStrategy = (old.tmdbId == info.id && old.kind == "tv")
        let policy = info.kind == "tv" ? (strategy ?? (sameShowForStrategy ? EpisodeStrategy.fromId(old.episodeStrategy) : .original)) : .original
        guard old.folderId != nil || policy == .original else {
            throw ScannerReplanError.looseStrategyUnsupported
        }

        if old.id.hasPrefix("unmatched-dir-") {
            let ids = plan.actions.filter { $0.groupId == groupId && $0.op == "unmatched" && !$0.done }.map(\.id)
            if !ids.isEmpty {
                return try await replanFiles(plan: plan, actionIds: ids, info: info, cloud: cloud, hooks: hooks)
            }
        }

        guard let folderId = old.folderId else {
            var loose = try await replanLoose(
                plan: plan,
                groupId: groupId,
                info: info,
                cloud: cloud,
                episodeOverride: nil,
                hooks: hooks
            )
            loose.groups = loose.groups.map { candidate in
                guard candidate.tmdbId == info.id && candidate.kind == info.kind && candidate.folderId == nil else {
                    return candidate
                }
                var copy = candidate
                copy.policyOverride = policyOverride ?? old.policyOverride
                copy.sourceRootId = old.sourceRootId
                return copy
            }
            return loose
        }

        let oldActions = plan.actions.filter { $0.groupId == groupId }
        let parentId = oldActions.first(where: { $0.fileId == folderId && $0.kind == "folder" })?.parentId
        let items = try await cloud.list(folderId: folderId)
        let folder = CloudEntry(fileId: folderId, fileName: old.folderName, isDir: true, parentFileId: parentId)
        let toMovie = info.kind == "movie"
        let seasonDirs = toMovie ? items.filter { $0.isDir && ScannerTreeEngine.seasonOfDir($0.fileName) != nil } : []
        var seasonKids: [(CloudEntry, [CloudEntry])] = []
        for sd in seasonDirs {
            let kids = try await cloud.list(folderId: sd.fileId)
            seasonKids.append((sd, kids))
        }

        // 旧匹配留下的刮削产物：ID 或类型变了就视为过期
        let prevId = MediaParser.tmdbHint(folder.fileName)?.id ?? old.tmdbId
        let prevKind = old.kind
        let changed = prevId != info.id || ((prevKind == "tv" || prevKind == "movie") && prevKind != info.kind)
        let stale = ScannerTreeEngine.staleArtifacts(items: items, newKind: info.kind, matchChanged: changed)
        let staleNames = Set(stale.map { $0.fileName.lowercased() })
        let seasonDirIds = Set(seasonDirs.map { $0.fileId })

        // 规划用条目：去掉过期产物；改成电影时把 Season 目录内的视频/字幕纳入改名
        var planItems = items.filter { !staleNames.contains($0.fileName.lowercased()) && !(toMovie && seasonDirIds.contains($0.fileId)) }
        for (sd, kids) in seasonKids {
            let fixedKids = kids
                .filter { !$0.isDir && (ScannerTreeEngine.isVideo($0) || ScannerTreeEngine.isSub($0)) }
                .map { k in
                    k.parentFileId != nil ? k : CloudEntry(
                        fileId: k.fileId, fileName: k.fileName, isDir: k.isDir, size: k.size,
                        parentFileId: sd.fileId, etag: k.etag, contentHash: k.contentHash, hashAlgorithm: k.hashAlgorithm
                    )
                }
            planItems.append(contentsOf: fixedKids)
        }

        var actions: [PlanAction] = []
        var groups: [PlanGroup] = []
        var flags: [String] = []
        let gidHint = "\(info.kind)-\(info.id)-\(folderId)"
        let trash = items.first(where: { $0.isDir && $0.fileName == ScannerTreeEngine.trashDir })
        var pre: [PlanAction] = []
        var post: [PlanAction] = []
        let needsCleanup = !stale.isEmpty || !seasonDirs.isEmpty
        var trashMk: String? = nil

        if needsCleanup && trash == nil {
            trashMk = aid()
            pre.append(PlanAction(
                id: trashMk!,
                op: "mkdir",
                groupId: gidHint,
                fileId: nil,
                parentId: folderId,
                oldName: "",
                newName: ScannerTreeEngine.trashDir,
                destParentId: nil,
                destRef: nil,
                destLabel: nil,
                kind: "cleanup",
                mediaKind: nil,
                tmdbId: nil,
                season: nil,
                episode: nil,
                artworkUrl: nil,
                selected: false,
                enabled: true,
                blocked: nil,
                done: false,
                error: nil,
                note: "清理旧刮削文件：回收目录（不会删除任何文件）"
            ))
        }

        func makeToTrash(_ e: CloudEntry, note: String) -> PlanAction {
            PlanAction(
                id: aid(),
                op: "move",
                groupId: gidHint,
                fileId: e.fileId,
                parentId: folderId,
                oldName: e.fileName,
                newName: e.fileName,
                destParentId: trash?.fileId,
                destRef: trash == nil ? trashMk : nil,
                destLabel: ScannerTreeEngine.trashDir,
                kind: "cleanup",
                mediaKind: nil,
                tmdbId: nil,
                season: nil,
                episode: nil,
                artworkUrl: nil,
                selected: false,
                enabled: true,
                blocked: nil,
                done: false,
                error: nil,
                note: note
            )
        }

        for s in stale {
            pre.append(makeToTrash(s, note: "清理旧刮削文件：旧匹配的 \(s.fileName)，移进 \(ScannerTreeEngine.trashDir)"))
        }

        let sameShow = (old.tmdbId == info.id && old.kind == "tv")
        let effectiveGroupId = info.kind == "tv" ? (episodeGroupId ?? (sameShow && strategy == nil ? old.episodeGroupId : nil)) : nil
        let effectiveGroupName = info.kind == "tv" ? (episodeGroupName ?? (sameShow && effectiveGroupId != nil && effectiveGroupId == old.episodeGroupId ? old.episodeGroupName : nil)) : nil
        try await hooks.planTitleFolder(folder, planItems, info, policy, effectiveGroupId, effectiveGroupName, &actions, &groups, &flags)
        flags.removeAll { $0.contains("没有视频文件") || $0.contains("不是季文件夹") }

        var taken = Set(items.map { $0.fileName.lowercased() })
        for (sd, kids) in seasonKids {
            for k in kids where !k.isDir {
                guard ScannerTreeEngine.isVideo(k) || ScannerTreeEngine.isSub(k) else { continue }
                let renamed = actions.first(where: { $0.fileId == k.fileId && $0.op == "rename" })?.newName ?? k.fileName
                if taken.contains(renamed.lowercased()) {
                    flags.append("清理：「\(sd.fileName)/\(k.fileName)」与上层文件重名，未移出")
                    continue
                }
                taken.insert(renamed.lowercased())
                post.append(PlanAction(
                    id: aid(),
                    op: "move",
                    groupId: gidHint,
                    fileId: k.fileId,
                    parentId: sd.fileId,
                    oldName: renamed,
                    newName: renamed,
                    destParentId: folderId,
                    destRef: nil,
                    destLabel: folder.fileName,
                    kind: "cleanup",
                    mediaKind: nil,
                    tmdbId: nil,
                    season: nil,
                    episode: nil,
                    artworkUrl: nil,
                    selected: false,
                    enabled: true,
                    blocked: nil,
                    done: false,
                    error: nil,
                    note: "清理旧刮削文件：把电影文件从 \(sd.fileName) 移回上层"
                ))
            }
            post.append(makeToTrash(sd, note: "清理旧刮削文件：旧的 \(sd.fileName) 文件夹（季海报 / season.nfo）移进 \(ScannerTreeEngine.trashDir)"))
        }

        if strategy != nil || policyOverride != nil, groups.count > 1 {
            throw ScannerReplanError.mixedMovieAndTvDirectory
        }

        var g = groups.first
        let gid = g?.id ?? gidHint
        if g == nil {
            var ids: [String] = []
            let target = StandardNaming.folderName(title: info.title, year: info.year, tmdbId: info.id, isTv: info.kind == "tv")
            if target != folder.fileName {
                let id = aid()
                actions.append(PlanAction(
                    id: id,
                    op: "rename",
                    groupId: gid,
                    fileId: folderId,
                    parentId: parentId,
                    oldName: folder.fileName,
                    newName: target,
                    destParentId: nil,
                    destRef: nil,
                    destLabel: nil,
                    kind: "folder",
                    mediaKind: info.kind,
                    tmdbId: info.id,
                    season: nil,
                    episode: nil,
                    artworkUrl: nil,
                    selected: true,
                    enabled: true,
                    blocked: nil,
                    done: false,
                    error: nil,
                    note: nil
                ))
                ids.append(id)
            }
            g = PlanGroup(
                id: gid,
                kind: info.kind,
                tmdbId: info.id,
                collectionId: info.collectionId,
                collectionName: info.collectionName,
                title: info.title,
                year: info.year,
                posterPath: info.posterPath,
                folderId: folderId,
                folderName: folder.fileName,
                folderNewName: target != folder.fileName ? target : nil,
                rating: info.rating,
                confidence: "手动",
                note: nil,
                warn: nil,
                actionIds: ids,
                policyOverride: policyOverride ?? old.policyOverride,
                sourceRootId: old.sourceRootId
            )
        }

        // 顺序：先清理过期产物（腾出 poster.jpg 等名字），再正常操作，最后把 Season 里的电影移回、旧 Season 收进回收目录
        let all: [PlanAction] = (pre + actions + post).map { a in
            PlanAction(
                id: a.id,
                op: a.op,
                groupId: gid,
                fileId: a.fileId,
                parentId: a.parentId,
                oldName: a.oldName,
                newName: a.newName,
                destParentId: a.destParentId,
                destRef: a.destRef,
                destLabel: a.destLabel,
                kind: a.kind,
                mediaKind: a.mediaKind,
                tmdbId: a.tmdbId,
                season: a.season,
                episode: a.episode,
                artworkUrl: a.artworkUrl,
                selected: a.selected,
                enabled: a.enabled,
                blocked: a.blocked,
                done: a.done,
                error: a.error,
                note: a.note,
                metadataSeason: a.metadataSeason, metadataEpisode: a.metadataEpisode,
                replaceExisting: a.replaceExisting, folderPath: a.folderPath
            )
        }

        var finalGroup = g!
        finalGroup.actionIds = all.map { $0.id }
        finalGroup.note = "已手动匹配" + (needsCleanup ? " · 发现旧刮削文件，可勾选「清理」" : "")
        finalGroup.confidence = (strategy != nil || policyOverride != nil) ? old.confidence : "手动"
        finalGroup.warn = nil
        finalGroup.policyOverride = policyOverride ?? old.policyOverride
        finalGroup.sourceRootId = old.sourceRootId
        if (finalGroup.folderPath ?? "").isEmpty { finalGroup.folderPath = old.folderPath }
        if needsCleanup {
            flags.append("「\(folder.fileName)」有旧匹配留下的刮削文件：已列出可选的「清理旧刮削文件」操作（默认不勾选，只移进 \(ScannerTreeEngine.trashDir)，不删除）")
        }

        guard !actions.isEmpty || needsCleanup || finalGroup.folderNewName == nil else {
            throw ScannerReplanError.emptyReplan
        }

        let folderTag = "「\(old.folderName)」"
        let keptFlags = plan.flags.filter { !$0.contains(folderTag) }
        let newActions = plan.actions.filter { $0.groupId != groupId } + all
        let newGroups = plan.groups.map { $0.id == groupId ? finalGroup : $0 }

        var result = plan
        result.groups = newGroups
        result.actions = newActions
        result.flags = keptFlags + flags

        if let move = oldActions.first(where: { $0.kind == LibraryDestination.kind }),
           let destId = move.destParentId {
            result = (try? LibraryDestination.set(plan: result, groupId: gid, targetId: destId, targetPath: move.destLabel ?? "")) ?? result
        }
        if info.kind == "tv" {
            let episodeNfo = oldActions.contains(where: { $0.kind == "episode_nfo" && $0.enabled })
            let thumbnails = oldActions.contains(where: { $0.kind == "image" && $0.episode != nil && $0.enabled })
            if episodeNfo || thumbnails {
                result = (try? EpisodeAssets.configure(plan: result, groupId: gid, nfo: episodeNfo, thumbnails: thumbnails, fullScrape: AppSettings.shared.policies.fullScrape)) ?? result
            }
        }

        // 保留此前被禁用的操作类别
        let configurableOld = oldActions.filter { PlanSelection.configurable($0) }
        let byCat = Dictionary(grouping: configurableOld, by: { "\($0.op)|\($0.kind)" })
        for (catKey, previous) in byCat where previous.allSatisfy({ !$0.enabled }) {
            let ids = result.actions.filter { $0.groupId == gid && "\($0.op)|\($0.kind)" == catKey }.map { $0.id }
            result = PlanSelection.setEnabled(plan: result, ids: ids, enabled: false)
        }

        // AI 规则蒸馏：记录人工纠错映射
        if strategy == nil && policyOverride == nil && AppSettings.shared.aiConfig.enableRuleDistillation {
            await AiRuleDistiller.shared.distill(
                pattern: old.folderName,
                targetTitle: info.title,
                mediaType: info.kind,
                tmdbId: info.id
            )
        }

        // 若此前该作品所有常规可执行项都未勾选，重规划后继续保持未勾选
        let regularBefore = oldActions.filter { PlanSelection.executable($0) && $0.kind != "cleanup" && $0.op != "delete" }
        if !regularBefore.isEmpty && regularBefore.allSatisfy({ !$0.selected }) {
            let ids = result.actions.filter { $0.groupId == gid && $0.kind != "cleanup" && $0.op != "delete" }.map { $0.id }
            result = PlanSelection.set(plan: result, ids: ids, on: false)
        }

        return result
    }

    // MARK: - 2. 单文件与多文件批量重规划（1:1 对标 replanFile / replanFiles）

    public static func replanFile(
        plan: ScrapePlan,
        actionId: String,
        info: MatchInfo,
        cloud: any CloudDrive,
        episodeOverride: (Int, Int)? = nil,
        hooks: ScannerReplanHooks
    ) async throws -> ScrapePlan {
        guard cloud.accountId == plan.accountId else { throw ScannerReplanError.accountMismatch }
        guard let source = plan.actions.first(where: { $0.id == actionId && !$0.done && ($0.op == "unmatched" || $0.kind == "file") }) else {
            throw ScannerReplanError.fileAlreadyProcessed
        }
        guard !(plan.submittedActionIds ?? []).contains(source.id),
              source.fileId.map({ !plan.submittedSourceIds.contains($0) }) ?? true else {
            throw ScannerReplanError.fileAlreadyProcessed
        }
        guard source.fileId != nil && source.parentId != nil else {
            throw ScannerReplanError.missingSourceInfo
        }
        if let ov = episodeOverride {
            guard (0...99).contains(ov.0) && ov.1 > 0 else {
                throw ScannerReplanError.invalidSeasonEpisode
            }
        }
        let temporaryId = "manual-\(UUID().uuidString.lowercased())"
        let origGroup = plan.groups.first(where: { $0.id == source.groupId })
        var detachedIds: Set<String> = [actionId]
        if source.op != "unmatched" {
            let ls0 = MediaParser.splitNameExt(source.oldName).0.lowercased()
            for a in plan.actions where a.groupId == source.groupId && !a.done {
                if let fid = source.fileId, a.fileId == fid {
                    detachedIds.insert(a.id)
                } else if a.op == "artwork", source.season != nil, source.episode != nil,
                          a.season == source.season, a.episode == source.episode {
                    detachedIds.insert(a.id)
                } else if (a.kind == "subtitle" || a.kind == "companion"),
                          a.parentId == source.parentId, !ls0.isEmpty {
                    let lc = MediaParser.splitNameExt(a.oldName).0.lowercased()
                    if lc == ls0 || lc.hasPrefix("\(ls0).") || lc.hasPrefix("\(ls0)-") || lc.hasPrefix("\(ls0)_") {
                        detachedIds.insert(a.id)
                    }
                }
            }
        }
        var working = plan
        working.actions = plan.actions.compactMap { a -> PlanAction? in
            if a.id == actionId {
                return PlanAction(
                    id: a.id, op: a.op, groupId: temporaryId, fileId: a.fileId, parentId: a.parentId,
                    oldName: a.oldName, newName: a.newName, destParentId: a.destParentId, destRef: a.destRef,
                    destLabel: a.destLabel, kind: a.kind, mediaKind: a.mediaKind, tmdbId: a.tmdbId,
                    season: a.season, episode: a.episode, artworkUrl: a.artworkUrl,
                    selected: a.selected, enabled: a.enabled, blocked: a.blocked, done: a.done, error: a.error, note: a.note,
                    metadataSeason: a.metadataSeason, metadataEpisode: a.metadataEpisode,
                    replaceExisting: a.replaceExisting, folderPath: a.folderPath
                )
            }
            if detachedIds.contains(a.id) { return nil }
            return a
        }
        working.groups.append(PlanGroup(
            id: temporaryId,
            kind: "unmatched",
            tmdbId: nil,
            title: source.oldName,
            year: "",
            posterPath: nil,
            folderId: origGroup?.folderId ?? source.parentId,
            folderName: origGroup?.folderName ?? "",
            folderNewName: nil,
            rating: nil,
            confidence: nil,
            note: nil,
            warn: nil,
            actionIds: [actionId],
            policyOverride: nil,
            sourceRootId: origGroup?.sourceRootId
        ))

        var result = try await replanLoose(
            plan: working,
            groupId: temporaryId,
            info: info,
            cloud: cloud,
            episodeOverride: episodeOverride,
            hooks: hooks
        )
        let sourceGroup = source.groupId
        if let srcSeason = source.season {
            let stillHasSeasonVideo = result.actions.contains {
                $0.groupId == sourceGroup && $0.kind == "file" && $0.season == srcSeason
            }
            if !stillHasSeasonVideo {
                result.actions.removeAll { a in
                    a.groupId == sourceGroup && !a.done && a.season == srcSeason && (a.op == "mkdir" || a.op == "artwork")
                }
            }
        }
        if let sgIdx = result.groups.firstIndex(where: { $0.id == sourceGroup }) {
            result.groups[sgIdx].actionIds = result.actions.filter { $0.groupId == sourceGroup }.map(\.id)
        }
        result.groups = result.groups.filter { $0.id != sourceGroup || result.actions.contains(where: { a in a.groupId == sourceGroup }) }
        let oldGroupIds = Set(plan.groups.map { $0.id })
        let freshFiles = Set(result.actions.filter { !oldGroupIds.contains($0.groupId) }.compactMap { $0.fileId })
        if plan.actions.contains(where: { !detachedIds.contains($0.id) && $0.fileId.map { freshFiles.contains($0) } == true && PlanSelection.executable($0) }) {
            throw ScannerReplanError.duplicateInOtherAction
        }
        return result
    }

    public static func replanFiles(
        plan: ScrapePlan,
        actionIds: [String],
        info: MatchInfo,
        cloud: any CloudDrive,
        hooks: ScannerReplanHooks
    ) async throws -> ScrapePlan {
        guard cloud.accountId == plan.accountId else { throw ScannerReplanError.accountMismatch }
        let existingGroupIds = Set(plan.groups.map { $0.id })
        var cur = plan
        var failures: [String] = []
        for id in actionIds {
            let name = cur.actions.first(where: { $0.id == id })?.oldName ?? id
            do {
                cur = try await replanFile(plan: cur, actionId: id, info: info, cloud: cloud, episodeOverride: nil, hooks: hooks)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(name)：\(error.localizedDescription)")
            }
        }
        cur = mergeAddedGroups(cur, existingGroupIds: existingGroupIds, bySourceRoot: true)
        if !failures.isEmpty {
            let appended = failures.map { "批量识别未完成 — \($0)" }
            for flag in appended where !cur.flags.contains(flag) {
                cur.flags.append(flag)
            }
        }
        return cur
    }

    // MARK: - 3. 多分组独立季/年/系列分部重规划（1:1 对标 replanTargetGroups）

    public static func replanTargetGroups(
        plan: ScrapePlan,
        targets: [GroupMatchOverride],
        info: MatchInfo,
        cloud: any CloudDrive,
        tmdb: any ScannerTmdbProvider,
        hooks: ScannerReplanHooks
    ) async throws -> ScrapePlan {
        guard cloud.accountId == plan.accountId else { throw ScannerReplanError.accountMismatch }
        let existingGroupIds = Set(plan.groups.map { $0.id })
        let totalFiles = targets.reduce(0) { $0 + $1.actionIds.count }
        var cur = plan
        var failures: [String] = []
        var cachedSeriesParts: [MatchInfo]? = nil

        func loadSeriesParts(seed: MatchInfo) async -> [MatchInfo] {
            if let cached = cachedSeriesParts { return cached }
            var parts: [Int: MatchInfo] = [seed.id: seed]
            if let detail = await TmdbClient.shared.movieDetails(id: seed.id) {
                parts[detail.id] = detail
                if let colId = detail.collectionId, colId > 0 {
                    let colParts = await TmdbClient.shared.collectionParts(collectionId: colId)
                    for p in colParts { parts[p.id] = p }
                }
            }
            if parts.count < 2 {
                let ns = seed.title as NSString
                let stripped = trailingDigitsRx.stringByReplacingMatches(
                    in: seed.title,
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let baseTitle = stripped.isEmpty ? seed.title : stripped
                let searched = await TmdbClient.shared.searchMovie(query: baseTitle, year: nil)
                for item in searched.prefix(12) {
                    if item.title.localizedCaseInsensitiveContains(baseTitle) || baseTitle.localizedCaseInsensitiveContains(item.title) {
                        parts[item.id] = item
                    }
                }
            }
            let sorted = parts.values.sorted { (Int($0.year) ?? 9999) < (Int($1.year) ?? 9999) }
            cachedSeriesParts = sorted
            return sorted
        }

        if AppSettings.shared.aiConfig.enabled {
            HybridRecognitionOrchestrator.resetScanBudget()
        }
        for target in targets where !target.actionIds.isEmpty {
            let groupInfo = await resolveGroupMatchInfo(base: info, target: target, tmdb: tmdb, warnings: &failures)
            let hasPerFileIndex = !target.fileSeriesIndices.isEmpty
            let useSeriesAutoMatch = groupInfo.kind == "movie" && (hasPerFileIndex || (target.actionIds.count > 1 && target.seriesIndex == nil && target.year.isEmpty))
            let seriesParts = useSeriesAutoMatch ? await loadSeriesParts(seed: groupInfo) : []
            var aiFranchiseByActionId: [String: MatchInfo] = [:]
            if useSeriesAutoMatch && seriesParts.count >= 2 && AppSettings.shared.aiEnabled {
                let unindexed = target.actionIds.filter { target.fileSeriesIndices[$0] == nil }
                if !unindexed.isEmpty {
                    let fNames = unindexed.map { aid in cur.actions.first(where: { $0.id == aid })?.oldName ?? aid }
                    let mapped = await AiFranchiseResolver.mapFilesToParts(
                        folderName: target.key,
                        fileNames: fNames,
                        parts: seriesParts
                    )
                    for (idx, match) in mapped where idx < unindexed.count {
                        aiFranchiseByActionId[unindexed[idx]] = match
                    }
                }
            }

            for actionId in target.actionIds {
                let action = cur.actions.first(where: { $0.id == actionId })
                let name = action?.oldName ?? actionId
                let (stem, _) = MediaParser.splitNameExt(name)
                let explicitIdx = target.fileSeriesIndices[actionId]
                let fileInfo: MatchInfo
                if useSeriesAutoMatch && !seriesParts.isEmpty {
                    let aiPicked = aiFranchiseByActionId[actionId]
                    fileInfo = aiPicked ?? pickSeriesMovieForFile(fileName: stem, base: groupInfo, parts: seriesParts, explicitIndex: explicitIdx)
                } else {
                    fileInfo = groupInfo
                }
                if AppSettings.shared.aiConfig.enableRuleDistillation {
                    await AiRuleDistiller.shared.distill(
                        pattern: name,
                        targetTitle: fileInfo.title,
                        mediaType: fileInfo.kind,
                        tmdbId: fileInfo.id
                    )
                }
                let parsed = MediaParser.parse(stem)
                let allowEpisode = totalFiles == 1 && target.actionIds.count == 1 && fileInfo.kind == "tv"
                let epOverride: (Int, Int)?
                if fileInfo.kind != "tv" {
                    epOverride = nil
                } else if allowEpisode, let ep = target.episode {
                    epOverride = (target.season ?? parsed.season ?? 1, ep)
                } else if let s = target.season, let epNum = parsed.episode {
                    epOverride = (s, epNum)
                } else {
                    epOverride = nil
                }

                do {
                    cur = try await replanFile(plan: cur, actionId: actionId, info: fileInfo, cloud: cloud, episodeOverride: epOverride, hooks: hooks)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append("\(name)：\(error.localizedDescription)")
                }
            }
        }

        cur = mergeAddedGroups(cur, existingGroupIds: existingGroupIds, bySourceRoot: false)
        if !failures.isEmpty {
            let appended = failures.map { "批量识别未完成 — \($0)" }
            for flag in appended where !cur.flags.contains(flag) {
                cur.flags.append(flag)
            }
        }
        return cur
    }

    public static func resolveGroupMatchInfo(
        base: MatchInfo,
        target: GroupMatchOverride,
        tmdb: any ScannerTmdbProvider,
        warnings: inout [String]
    ) async -> MatchInfo {
        let rawYear = String(target.year.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0.isNumber })
        let customYear = rawYear.count == 4 ? rawYear : ""
        if base.kind == "movie" && (target.seriesIndex != nil || (!customYear.isEmpty && customYear != base.year)) {
            let query = (target.seriesIndex ?? 0) > 1 ? "\(base.title) \(target.seriesIndex!)" : base.title
            let resolved: MatchInfo?
            if !customYear.isEmpty {
                resolved = await TmdbClient.shared.searchMovie(query: query, year: Int(customYear)).first
            } else {
                resolved = await tmdb.movie(stem: query, fallbackNames: [], fallbackId: nil)
            }
            if let resolved { return resolved }
            let yrHint = customYear.isEmpty ? "" : " (\(customYear))"
            warnings.append("未在 TMDB 找到「\(query)\(yrHint)」对应电影，已保留主选条目")
            return base
        }
        if base.kind == "tv" && !customYear.isEmpty {
            return MatchInfo(
                kind: base.kind, id: base.id, title: base.title, year: customYear,
                posterPath: base.posterPath, backdropPath: base.backdropPath,
                originalTitle: base.originalTitle, overview: base.overview, rating: base.rating,
                collectionId: base.collectionId, collectionName: base.collectionName,
                collectionPosterPath: base.collectionPosterPath
            )
        }
        return base
    }

    // MARK: - 4. 系列电影单文件 5 级优先分配器（1:1 对标 pickSeriesMovieForFile）

    public static func pickSeriesMovieForFile(
        fileName: String,
        base: MatchInfo,
        parts: [MatchInfo],
        explicitIndex: Int? = nil
    ) -> MatchInfo {
        guard !parts.isEmpty else { return base }
        let sorted = parts.sorted { (Int($0.year) ?? 9999) < (Int($1.year) ?? 9999) }

        // 1. 用户显式指定第几部（1-based）
        if let idx = explicitIndex, idx > 0 {
            if idx == 1 { return sorted[0] }
            let numRx = try? NSRegularExpression(pattern: "(?<!\\d)\(idx)(?!\\d)")
            if let hit = sorted.first(where: { p in
                let ns = p.title as NSString
                return numRx?.firstMatch(in: p.title, range: NSRange(location: 0, length: ns.length)) != nil
            }) {
                return hit
            }
            if idx <= sorted.count { return sorted[idx - 1] }
        }

        // 2. 文件名精确年份匹配
        let nsFile = fileName as NSString
        let years = year4Rx.matches(in: fileName, range: NSRange(location: 0, length: nsFile.length))
            .map { nsFile.substring(with: $0.range(at: 1)) }
        for y in years {
            let hits = sorted.filter { $0.year == y }
            if hits.count == 1 { return hits[0] }
        }

        // 3. 副标题匹配（区分「xxxx」与「xxxx：yyyy」）
        let head = fileName
            .components(separatedBy: "[").first?
            .components(separatedBy: "(").first?
            .components(separatedBy: ".").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? fileName
        let nsHead = head as NSString
        var subPart = ""
        if let m = subtitleRx.firstMatch(in: head, range: NSRange(location: 0, length: nsHead.length)) {
            subPart = nsHead.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if subPart.count >= 2 {
            let normSub = TitleScorer.normalizeTitle(subPart)
            if !normSub.isEmpty, let bySub = sorted.first(where: { TitleScorer.normalizeTitle($0.title).contains(normSub) }) {
                return bySub
            }
        }

        // 4. 片名末尾续集序号匹配（罗马数字 II–XII、中文「第X部」与阿拉伯数字）
        var trailingNum = SequelDisambiguator.extractSequelNumber(fileName)
        if trailingNum == nil, let m = endNumRx.firstMatch(in: head, range: NSRange(location: 0, length: nsHead.length)) {
            trailingNum = Int(nsHead.substring(with: m.range(at: 1)))
        }
        if let num = trailingNum, num > 0 {
            let numRx = try? NSRegularExpression(pattern: "(?<!\\d)\(num)(?!\\d)")
            if let byTitle = sorted.first(where: { p in
                let normTitle = SequelDisambiguator.normalizeNumerals(p.title)
                let ns = normTitle as NSString
                return numRx?.firstMatch(in: normTitle, range: NSRange(location: 0, length: ns.length)) != nil
            }) {
                return byTitle
            }
            if num <= sorted.count { return sorted[num - 1] }
        }

        // 5. 无副标题且无续集数字：优先匹配无副标题/最早的第 1 部
        if subPart.isEmpty && trailingNum == nil {
            return sorted.first(where: { !$0.title.contains("：") && !$0.title.contains(":") }) ?? sorted[0]
        }
        return base
    }

    // MARK: - 5. 散文件重规划（1:1 对标 replanLooseLocked）

    public static func replanLoose(
        plan: ScrapePlan,
        groupId: String,
        info: MatchInfo,
        cloud: any CloudDrive,
        episodeOverride: (Int, Int)? = nil,
        hooks: ScannerReplanHooks
    ) async throws -> ScrapePlan {
        let oldActions = plan.actions.filter { $0.groupId == groupId }
        guard let source = oldActions.first(where: { $0.kind == "file" && $0.fileId != nil }),
              let sourceFileId = source.fileId else {
            throw ScannerReplanError.missingSourceVideo
        }
        guard let parent = source.parentId else {
            throw ScannerReplanError.missingSourceInfo
        }
        let items = try await cloud.list(folderId: parent)
        guard items.contains(where: { $0.fileId == sourceFileId && ScannerTreeEngine.isVideo($0) }) else {
            throw ScannerReplanError.sourceVideoChanged
        }

        var kept = plan.actions.filter { $0.groupId != groupId }
        // 原分组的 mkdir 可能被别的散电影共用，保留并交给实际依赖的分组
        for mkdir in oldActions where mkdir.op == "mkdir" {
            if let dependent = kept.first(where: { PlanSelection.dependencyOf($0, all: plan.actions)?.id == mkdir.id }) {
                kept.append(PlanAction(
                    id: mkdir.id, op: mkdir.op, groupId: dependent.groupId, fileId: mkdir.fileId,
                    parentId: mkdir.parentId, oldName: mkdir.oldName, newName: mkdir.newName,
                    destParentId: mkdir.destParentId, destRef: mkdir.destRef, destLabel: mkdir.destLabel,
                    kind: mkdir.kind, mediaKind: mkdir.mediaKind, tmdbId: mkdir.tmdbId,
                    season: mkdir.season, episode: mkdir.episode, artworkUrl: mkdir.artworkUrl,
                    selected: mkdir.selected, enabled: mkdir.enabled, blocked: mkdir.blocked,
                    done: mkdir.done, error: mkdir.error, note: mkdir.note,
                metadataSeason: mkdir.metadataSeason, metadataEpisode: mkdir.metadataEpisode,
                replaceExisting: mkdir.replaceExisting, folderPath: mkdir.folderPath
            ))
            }
        }

        let oldGroup = plan.groups.first(where: { $0.id == groupId })
        let parentLabel: String = {
            if let fn = oldGroup?.folderName, !fn.isEmpty { return fn }
            return plan.roots.first(where: { $0.folderId == oldGroup?.sourceRootId })?.name ?? ""
        }()

        var actions: [PlanAction] = []
        var groups: [PlanGroup] = []
        var flags: [String] = []
        try await hooks.planLooseFile(
            CloudEntry(fileId: parent, fileName: parentLabel, isDir: true),
            items,
            sourceFileId,
            info,
            kept.filter { $0.op == "mkdir" },
            episodeOverride,
            &actions,
            &groups,
            &flags
        )
        guard !groups.isEmpty else { throw ScannerReplanError.emptyReplan }

        let enrichedGroups = groups.map { g -> PlanGroup in
            var copy = g
            if copy.folderName.isEmpty { copy.folderName = parentLabel }
            copy.sourceRootId = copy.sourceRootId ?? oldGroup?.sourceRootId
            if (copy.folderPath ?? "").isEmpty { copy.folderPath = oldGroup?.folderPath }
            return copy
        }
        let combined = kept + actions
        let allGroups = (plan.groups.filter { $0.id != groupId } + enrichedGroups).map { g -> PlanGroup in
            var copy = g
            copy.actionIds = combined.filter { $0.groupId == copy.id }.map { $0.id }
            return copy
        }
        var updated = plan
        updated.actions = combined
        updated.groups = allGroups
        updated.flags = plan.flags + flags
        return updated
    }

    // MARK: - Helper: 合并同作品新增卡片

    private static func mergeAddedGroups(_ plan: ScrapePlan, existingGroupIds: Set<String>, bySourceRoot: Bool) -> ScrapePlan {
        let added = plan.groups.filter { !existingGroupIds.contains($0.id) && $0.tmdbId != nil && $0.kind != "unmatched" }
        guard added.count > 1 else { return plan }

        let buckets = Dictionary(grouping: added) { g -> String in
            if bySourceRoot {
                return "\(g.kind)|\(g.tmdbId ?? 0)|\(g.sourceRootId ?? g.folderId ?? "")"
            }
            return "\(g.kind)|\(g.tmdbId ?? 0)"
        }
        var remap: [String: String] = [:]
        var mergedPrimary: [String: PlanGroup] = [:]
        for (_, bucket) in buckets where bucket.count > 1 {
            var primary = bucket[0]
            if primary.note?.contains("剧集单集") == true { primary.note = nil }
            mergedPrimary[primary.id] = primary
            for extra in bucket.dropFirst() {
                remap[extra.id] = primary.id
            }
        }
        guard !remap.isEmpty else { return plan }

        let newActions = plan.actions.map { a -> PlanAction in
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
            var base = mergedPrimary[g.id] ?? g
            base.actionIds = newActions.filter { $0.groupId == base.id }.map { $0.id }
            return base
        }
        var out = plan
        out.actions = newActions
        out.groups = newGroups
        return out
    }
}
