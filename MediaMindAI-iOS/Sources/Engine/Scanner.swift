import Foundation

/// 默认生产级 TMDB 扫描提供者（1:1 对标 Android `Scanner.RealTmdb`，融合 `TmdbClient` + `HybridRecognitionOrchestrator`）。
public struct RealScannerTmdbProvider: ScannerTmdbProvider {
    public let tmdb: TmdbClient
    public let ai: AiRecognizerClient

    public init(tmdb: TmdbClient = .shared, ai: AiRecognizerClient = .shared) {
        self.tmdb = tmdb
        self.ai = ai
    }

    public func show(names: [String], fixedId: Int?) async -> (MatchInfo?, Int) {
        if let fixedId, let hit = await tmdb.tvDetails(id: fixedId) {
            return (hit, 0)
        }
        for (idx, raw) in names.enumerated() {
            let parsed = MediaParser.parse(raw)
            // 先执行无 AI 的常规解析 + TMDB 检索；仅在最后一个候选名允许触发一次 AI 兜底，避免多候选名重复扣预算
            let allowAi = (idx == names.count - 1)
            if let hit = await HybridRecognitionOrchestrator.resolve(
                rawName: raw,
                folderName: raw,
                expectedKind: "tv",
                allowAiFallback: allowAi,
                tmdb: tmdb,
                ai: ai
            ), hit.kind == "tv" {
                return (hit, idx)
            }
            let candidates = await tmdb.searchTv(query: parsed.cleanTitle, year: parsed.year)
            if let best = HybridRecognitionOrchestrator.rerankCandidates(
                query: parsed.cleanTitle,
                year: parsed.year,
                candidates: candidates
            ).first,
               SequelDisambiguator.scoreCandidate(query: parsed.cleanTitle, queryYear: parsed.year, candidate: best) >= 45 {
                return (best, idx)
            }
        }
        return (nil, -1)
    }

    public func movie(stem: String, fallbackNames: [String], fallbackId: Int?) async -> MatchInfo? {
        if let fallbackId, let hit = await tmdb.movieDetails(id: fallbackId) {
            return hit
        }
        let all = ([stem] + fallbackNames).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (idx, raw) in all.enumerated() {
            let parsed = MediaParser.parse(raw)
            let allowAi = (idx == all.count - 1)
            if let hit = await HybridRecognitionOrchestrator.resolve(
                rawName: raw,
                folderName: fallbackNames.first ?? raw,
                expectedKind: "movie",
                allowAiFallback: allowAi,
                tmdb: tmdb,
                ai: ai
            ), hit.kind == "movie" {
                return hit
            }
            let candidates = await tmdb.searchMovie(query: parsed.cleanTitle, year: parsed.year)
            if let best = HybridRecognitionOrchestrator.rerankCandidates(
                query: parsed.cleanTitle,
                year: parsed.year,
                candidates: candidates
            ).first,
               SequelDisambiguator.scoreCandidate(query: parsed.cleanTitle, queryYear: parsed.year, candidate: best) >= 45 {
                if best.collectionId == nil, let detailed = await tmdb.movieDetails(id: best.id) {
                    return detailed
                }
                return best
            }
        }
        return nil
    }

    public func movieInfo(id: Int) async -> MatchInfo? {
        await tmdb.movieDetails(id: id)
    }

    public func collectionOf(movieId: Int) async -> (Int, String)? {
        guard let detail = await tmdb.movieDetails(id: movieId),
              let cid = detail.collectionId, cid > 0 else { return nil }
        return (cid, detail.collectionName ?? "")
    }

    public func collectionPosterOf(movieId: Int, collectionId: Int) async -> String? {
        if let detail = await tmdb.movieDetails(id: movieId),
           detail.collectionId == collectionId,
           let p = detail.collectionPosterPath, !p.isEmpty {
            return p
        }
        return await tmdb.collectionPoster(collectionId: collectionId)
    }

    public func seasonCounts(showId: Int) async -> [Int: Int] {
        await tmdb.tvSeasonCounts(id: showId)
    }

    public func episodeGroupMap(groupId: String) async -> [EpisodeMapping.Episode: EpisodeMapping.Episode] {
        let subs = await tmdb.tvEpisodeGroupDetails(groupId: groupId)
        return EpisodeStrategyMapper.groupMap(groups: subs)
    }
}

/// 并发云盘目录扫描与刮削规划主入口（1:1 贯通 `ScannerTreeEngine` + `ScannerTvAndBdmv` + `ScannerMovieLooseAndArtwork` + `ScannerReplan` + `PlanStore`）。
public enum Scanner {
    public typealias ProgressHandler = @Sendable (String, Int) -> Void
    public static let maxRecursionDepth = 6

    public static func scan(
        roots: [PlanRoot],
        drive: any CloudDrive,
        tmdb: TmdbClient = .shared,
        ai: AiRecognizerClient = .shared,
        tmdbProvider: (any ScannerTmdbProvider)? = nil,
        organizedKeys: Set<String> = [],
        taskPolicy: PolicyOverride? = nil,
        globalPolicies: DefaultPolicies? = nil,
        fullDrive: Bool = false,
        preflightTmdb: Bool = false,
        persistResult: Bool = true,
        onProgress: ProgressHandler? = nil
    ) async throws -> ScrapePlan {
        HybridRecognitionOrchestrator.resetScanBudget()
        let profile = DriveRateProfile.forDrive(drive)
        let prefetchWidth = max(2, min(8, profile.maxConcurrentReads))
        let settings = AppSettings.shared
        let global = globalPolicies ?? settings.policies
        let effMoviePrefs = PolicyResolver.resolve(isTv: false, global: global, task: taskPolicy).naming
        let effTvPrefs = PolicyResolver.resolve(isTv: true, global: global, task: taskPolicy).naming
        let defaultTvStrategy = EpisodeStrategy(rawValue: global.episodeStrategy) ?? .original
        return try await StandardNaming.$scopedMoviePrefs.withValue(effMoviePrefs) {
            try await StandardNaming.$scopedTvPrefs.withValue(effTvPrefs) {
        let fullScrape = global.fullScrape
        let provider: any ScannerTmdbProvider = tmdbProvider ?? RealScannerTmdbProvider(tmdb: tmdb, ai: ai)
        if preflightTmdb {
            onProgress?("检查 TMDB 连接…", 0)
            if case .failure(let err) = await tmdb.test() {
                throw err
            }
        }
        let tvHooks = ScannerMovieLooseAndArtwork.makeTvAndBdmvHooks(
            drive: drive,
            tmdb: provider,
            fullScrape: fullScrape
        )

        var groups: [PlanGroup] = []
        var actions: [PlanAction] = []
        var flags: [String] = []
        var visited: Set<String> = []
        var dirPathMap: [String: String] = [:]
        var scannedCount = 0

        var effectiveRoots: [PlanRoot] = {
            if fullDrive || roots.isEmpty {
                return [PlanRoot(folderId: drive.rootId, name: "根目录", parentId: nil)]
            }
            return roots
        }()
        // 根作品目录不在子列表中，必须把已知／查询到的父目录传给外层改名规划。
        for index in effectiveRoots.indices where effectiveRoots[index].parentId == nil && effectiveRoots[index].folderId != drive.rootId {
            let root = effectiveRoots[index]
            if let parent = try await drive.parentIdOf(fileId: root.folderId) {
                effectiveRoots[index] = PlanRoot(folderId: root.folderId, name: root.name, parentId: parent)
            }
        }

        func walkContainer(dir: CloudEntry, items: [CloudEntry], depth: Int) async throws -> Int {
            try Task.checkCancellation()
            guard visited.insert(dir.fileId).inserted else { return 0 }
            var seen = 0
            var taken = Set(items.map { $0.fileName.lowercased() })

            if items.contains(where: { ScannerTreeEngine.isVideo($0) }) {
                onProgress?("匹配散文件：\(dir.fileName)", scannedCount)
                seen += await ScannerMovieLooseAndArtwork.planLooseFiles(
                    dir: dir,
                    items: items,
                    tmdb: provider,
                    fullScrape: fullScrape,
                    actions: &actions,
                    groups: &groups,
                    flags: &flags,
                    taken: &taken
                )
            }

            let childDirs = items.filter { $0.isDir && !ScannerTreeEngine.ignoredDir($0.fileName) }
            for chunkStart in stride(from: 0, to: childDirs.count, by: prefetchWidth) {
                try Task.checkCancellation()
                let slice = Array(childDirs[chunkStart..<min(chunkStart + prefetchWidth, childDirs.count)])
                var prefetchedMap: [String: [CloudEntry]] = [:]
                if slice.count > 1 {
                    onProgress?("并发读取 \(slice.count) 个目录…", scannedCount + seen)
                    let fetched = try await withThrowingTaskGroup(of: (String, [CloudEntry]).self) { tg in
                        for d in slice {
                            tg.addTask { (d.fileId, try await drive.list(folderId: d.fileId)) }
                        }
                        var pairs: [(String, [CloudEntry])] = []
                        for try await pair in tg { pairs.append(pair) }
                        return pairs
                    }
                    for (fid, kids) in fetched { prefetchedMap[fid] = kids }
                }

                for d0 in slice {
                    try Task.checkCancellation()
                    var rememberedHint: MatchInfo? = nil
                    if settings.rememberHistory {
                        let pathMode = drive.kind.idsArePaths
                        let rememberedGroup = await MainActor.run {
                            HistoryStore.shared.remembered(
                                accountId: drive.accountId,
                                pathIds: pathMode,
                                folderId: d0.fileId,
                                folderName: d0.fileName
                            )
                        }
                        if let hg = rememberedGroup {
                            rememberedHint = MatchInfo(
                                kind: hg.kind,
                                id: hg.tmdbId,
                                title: hg.title,
                                year: hg.year,
                                posterPath: hg.posterPath,
                                backdropPath: nil,
                                originalTitle: nil,
                                overview: "",
                                rating: nil
                            )
                            flags.append("「\(d0.fileName)」已复用历史匹配身份（TMDB \(hg.tmdbId)），仅核验缺失操作")
                        } else if organizedKeys.contains("\(drive.accountId)|\(d0.fileId)") {
                            if let rec = await MainActor.run(body: { HistoryStore.shared.records.first { $0.accountId == drive.accountId && $0.folderId == d0.fileId } }),
                               let hint = MediaParser.tmdbHint(d0.fileName),
                               let kind = hint.kind {
                                let parsedYear = MediaParser.parse(d0.fileName).year.map(String.init) ?? ""
                                rememberedHint = MatchInfo(kind: kind, id: hint.id, title: rec.matchedTitle, year: parsedYear, posterPath: nil, backdropPath: nil, originalTitle: nil, overview: "", rating: nil)
                                flags.append("「\(d0.fileName)」已复用历史匹配身份，仅核验缺失操作")
                            } else {
                                flags.append("「\(d0.fileName)」已在历史记录中整理过，自动跳过")
                                continue
                            }
                        }
                    }
                    let d = d0.parentFileId == nil
                        ? CloudEntry(fileId: d0.fileId, fileName: d0.fileName, isDir: true, size: d0.size, parentFileId: dir.fileId)
                        : d0
                    dirPathMap[d.fileId] = ScannerTreeEngine.joinDirPath(parent: dirPathMap[dir.fileId] ?? dir.fileName, name: d.fileName)
                    onProgress?("读取目录：\(d.fileName)", scannedCount + seen)
                    let kids: [CloudEntry]
                    if let cached = prefetchedMap[d.fileId] {
                        kids = cached
                    } else {
                        kids = try await drive.list(folderId: d.fileId)
                    }

                    if let seasonNum = ScannerTreeEngine.seasonOfDir(d.fileName) {
                        onProgress?("匹配季目录：\(d.fileName)", scannedCount + seen)
                        seen += await ScannerMovieLooseAndArtwork.planDirAsShowOrMovie(
                            folder: d,
                            items: kids,
                            defaultSeason: seasonNum,
                            tmdb: provider,
                            visited: &visited,
                            actions: &actions,
                            groups: &groups,
                            flags: &flags,
                            parentFolderName: dir.fileName
                        )
                        continue
                    }

                    let role = try await ScannerTreeEngine.classify(
                        dir: d,
                        kids: kids,
                        list: { fid in try await drive.list(folderId: fid) }
                    )
                    switch role {
                    case .title:
                        onProgress?("匹配 TMDB：\(d.fileName)", scannedCount + seen)
                        seen += try await ScannerTvAndBdmv.planTitleFolder(
                            folder: d,
                            items: kids,
                            drive: drive,
                            tmdb: provider,
                            visited: &visited,
                            dirPathMap: &dirPathMap,
                            actions: &actions,
                            groups: &groups,
                            flags: &flags,
                            rootTaken: &taken,
                            remembered: rememberedHint,
                            strategy: defaultTvStrategy,
                            hooks: tvHooks
                        )
                    case .container:
                        if depth < maxRecursionDepth {
                            seen += try await walkContainer(dir: d, items: kids, depth: depth + 1)
                        } else {
                            flags.append("「\(d.fileName)」目录层级太深，未继续扫描")
                        }
                    }
                }
            }
            return seen
        }

        for root in effectiveRoots {
            try Task.checkCancellation()
            onProgress?("扫描：\(root.name)", scannedCount)
            let groupStart = groups.count
            let items = try await drive.list(folderId: root.folderId)
            let cleanName = root.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last ?? root.name
            let rootEntry = CloudEntry(fileId: root.folderId, fileName: cleanName.isEmpty ? "根目录" : cleanName, isDir: true, parentFileId: root.parentId)
            if root.name.hasPrefix("/") {
                let trimmed = root.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                dirPathMap[root.folderId] = trimmed.isEmpty ? "/" : "/\(trimmed)"
            } else if root.name == "根目录" {
                dirPathMap[root.folderId] = "/"
            } else {
                dirPathMap[root.folderId] = "/\(root.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            }

            let role: ScannerRole
            if fullDrive || root.folderId == drive.rootId {
                role = .container
            } else {
                role = try await ScannerTreeEngine.classify(
                    dir: rootEntry,
                    kids: items,
                    list: { fid in try await drive.list(folderId: fid) }
                )
            }

            if role == .container {
                scannedCount += try await walkContainer(dir: rootEntry, items: items, depth: 0)
            } else {
                var rootTaken = Set<String>()
                scannedCount += try await ScannerTvAndBdmv.planTitleFolder(
                    folder: rootEntry,
                    items: items,
                    drive: drive,
                    tmdb: provider,
                    visited: &visited,
                    dirPathMap: &dirPathMap,
                    actions: &actions,
                    groups: &groups,
                    flags: &flags,
                    rootTaken: &rootTaken,
                    strategy: defaultTvStrategy,
                    hooks: tvHooks
                )
            }

            for i in groupStart..<groups.count {
                groups[i].sourceRootId = root.folderId
            }
        }

        // 回填 folderPath 到每个 PlanGroup 与 PlanAction
        let rootNameById = Dictionary(effectiveRoots.map { ($0.folderId, dirPathMap[$0.folderId] ?? $0.name) }, uniquingKeysWith: { _, last in last })
        for i in groups.indices where (groups[i].folderPath ?? "").isEmpty {
            let g = groups[i]
            let resolved = g.folderId.flatMap { dirPathMap[$0] }
                ?? g.sourceRootId.map { ScannerTreeEngine.joinDirPath(parent: rootNameById[$0], name: g.folderName) }
                ?? (g.folderName.isEmpty ? nil : "/\(g.folderName)")
            groups[i].folderPath = resolved
        }
        let groupPathById = Dictionary(groups.map { ($0.id, $0.folderPath) }, uniquingKeysWith: { _, last in last })
        for i in actions.indices where (actions[i].folderPath ?? "").isEmpty {
            actions[i].folderPath = actions[i].parentId.flatMap { dirPathMap[$0] } ?? groupPathById[actions[i].groupId] ?? nil
        }

        if groups.isEmpty {
            flags.append("所选目录未发现可识别的视频文件")
        }

        var plan = ScrapePlan(
            id: String(UUID().uuidString.prefix(8).lowercased()),
            accountId: drive.accountId,
            provider: drive.kind.rawValue,
            createdAt: Date(),
            roots: effectiveRoots,
            groups: groups,
            actions: actions,
            flags: flags,
            taskPolicy: taskPolicy
        )

        let mergeEnabled = taskPolicy?.mergeSeries ?? global.mergeSeries
        let mergeMovies = taskPolicy?.mergeMovieSeries ?? global.mergeMovieSeries
        let mergeTv = taskPolicy?.mergeTvSeries ?? global.mergeTvSeries
        let appendTag = (taskPolicy?.movieNaming ?? global.movieNaming).folderTmdbEnabled
        plan = SeriesMerger.mergeIfEnabled(plan, enabled: mergeEnabled, appendTag: appendTag, mergeMovies: mergeMovies, mergeTv: mergeTv)
        plan = await AdaptiveDirectoryPlanner.apply(plan: plan, policies: global, drive: drive)
        plan = await DuplicateRetentionPlanner.apply(plan: plan, policies: global, drive: drive)
        plan = ManualConfirmation.applyGate(to: plan, standardSpec: false)

        let conflicts = ConflictDetector.detect(in: plan.actions)
        for c in conflicts {
            plan.flags.append("⚠️ 命名冲突：目标文件「\(c.targetName)」存在 \(c.actionIds.count) 处重复，请在预览页检查勾选")
        }

        // 按全局/任务策略开关同步动作启用状态（1:1 对标 Android DefaultPolicies.apply）
        var disableIds: [String] = []
        for a in plan.actions {
            let grp = plan.groups.first(where: { $0.id == a.groupId })
            let eff = PolicyResolver.resolve(isTv: grp?.kind == "tv", global: global, task: taskPolicy, film: grp?.policyOverride)
            if a.op == "rename" && a.kind == "file" && (!eff.organizeEnabled || !eff.renameFiles) {
                disableIds.append(a.id)
            } else if a.op == "rename" && a.kind == "folder" && (!eff.organizeEnabled || !eff.renameFolders) {
                disableIds.append(a.id)
            } else if (!eff.organizeEnabled || !eff.seasonFolders) && a.season != nil && ((a.op == "mkdir" && a.kind == "folder") || (a.op == "rename" && a.kind == "folder") || (a.op == "move" && a.kind != "folder")) {
                disableIds.append(a.id)
            } else if a.op == "artwork" {
                if !eff.scrapeEnabled {
                    disableIds.append(a.id)
                } else if a.kind == "movie_nfo" || a.kind == "tvshow_nfo" {
                    if !eff.writeNfo { disableIds.append(a.id) }
                } else if a.kind == "episode_nfo" {
                    if !eff.episodeNfo { disableIds.append(a.id) }
                } else if a.kind == "clearlogo" {
                    if !eff.downloadClearlogo { disableIds.append(a.id) }
                } else if a.kind == "image" {
                    let low = a.newName.lowercased()
                    if (low.contains("fanart") || low.contains("backdrop")) && !eff.downloadFanart {
                        disableIds.append(a.id)
                    } else if a.episode != nil && low.hasSuffix("-thumb.jpg") && !eff.downloadEpisodeThumb {
                        disableIds.append(a.id)
                    } else if low.contains("season") && low.contains("poster") && !eff.seasonPoster {
                        disableIds.append(a.id)
                    } else if low.contains("poster") && !eff.downloadPoster {
                        disableIds.append(a.id)
                    }
                }
            }
        }
        if !disableIds.isEmpty {
            plan = PlanSelection.setEnabled(plan: plan, ids: disableIds, enabled: false)
        }

        // 原子持久化至独立 PlanStore
        if persistResult { _ = try? PlanStore.shared.save(plan) }
        return plan
            }
        }
    }

    // MARK: - 手动重规划快捷入口（1:1 委托 ScannerReplan + ScannerMovieLooseAndArtwork）

    public static func replanGroup(
        plan: ScrapePlan,
        groupId: String,
        info: MatchInfo,
        drive: any CloudDrive,
        strategy: EpisodeStrategy? = nil,
        episodeGroupId: String? = nil,
        episodeGroupName: String? = nil,
        policyOverride: PolicyOverride? = nil,
        tmdbProvider: (any ScannerTmdbProvider)? = nil
    ) async throws -> ScrapePlan {
        let global = AppSettings.shared.policies
        let oldGroup = plan.groups.first(where: { $0.id == groupId })
        let filmOv = policyOverride ?? oldGroup?.policyOverride
        let effMovie = PolicyResolver.resolve(isTv: false, global: global, task: plan.taskPolicy, film: filmOv).naming
        let effTv = PolicyResolver.resolve(isTv: true, global: global, task: plan.taskPolicy, film: filmOv).naming
        let provider = tmdbProvider ?? RealScannerTmdbProvider()
        let hooks = ScannerMovieLooseAndArtwork.makeReplanHooks(drive: drive, tmdb: provider, fullScrape: global.fullScrape)
        let mergeEnabled = plan.taskPolicy?.mergeSeries ?? global.mergeSeries
        let mergeMovies = plan.taskPolicy?.mergeMovieSeries ?? global.mergeMovieSeries
        let mergeTv = plan.taskPolicy?.mergeTvSeries ?? global.mergeTvSeries
        let appendTag = (plan.taskPolicy?.movieNaming ?? global.movieNaming).folderTmdbEnabled
        return try await StandardNaming.$scopedMoviePrefs.withValue(effMovie) {
            try await StandardNaming.$scopedTvPrefs.withValue(effTv) {
                let updated = try await ScannerReplan.replanGroup(
                    plan: plan, groupId: groupId, info: info, cloud: drive,
                    strategy: strategy, episodeGroupId: episodeGroupId, episodeGroupName: episodeGroupName,
                    policyOverride: policyOverride, hooks: hooks
                )
                return SeriesMerger.mergeIfEnabled(updated, enabled: mergeEnabled, appendTag: appendTag, mergeMovies: mergeMovies, mergeTv: mergeTv)
            }
        }
    }

    public static func replanFiles(
        plan: ScrapePlan,
        actionIds: [String],
        info: MatchInfo,
        drive: any CloudDrive,
        tmdbProvider: (any ScannerTmdbProvider)? = nil
    ) async throws -> ScrapePlan {
        let global = AppSettings.shared.policies
        let effMovie = PolicyResolver.resolve(isTv: false, global: global, task: plan.taskPolicy).naming
        let effTv = PolicyResolver.resolve(isTv: true, global: global, task: plan.taskPolicy).naming
        let provider = tmdbProvider ?? RealScannerTmdbProvider()
        let hooks = ScannerMovieLooseAndArtwork.makeReplanHooks(drive: drive, tmdb: provider, fullScrape: global.fullScrape)
        let mergeEnabled = plan.taskPolicy?.mergeSeries ?? global.mergeSeries
        let mergeMovies = plan.taskPolicy?.mergeMovieSeries ?? global.mergeMovieSeries
        let mergeTv = plan.taskPolicy?.mergeTvSeries ?? global.mergeTvSeries
        let appendTag = (plan.taskPolicy?.movieNaming ?? global.movieNaming).folderTmdbEnabled
        return try await StandardNaming.$scopedMoviePrefs.withValue(effMovie) {
            try await StandardNaming.$scopedTvPrefs.withValue(effTv) {
                let updated = try await ScannerReplan.replanFiles(
                    plan: plan, actionIds: actionIds, info: info, cloud: drive, hooks: hooks
                )
                return SeriesMerger.mergeIfEnabled(updated, enabled: mergeEnabled, appendTag: appendTag, mergeMovies: mergeMovies, mergeTv: mergeTv)
            }
        }
    }

    public static func replanTargetGroups(
        plan: ScrapePlan,
        targets: [GroupMatchOverride],
        info: MatchInfo,
        drive: any CloudDrive,
        tmdbProvider: (any ScannerTmdbProvider)? = nil
    ) async throws -> ScrapePlan {
        let global = AppSettings.shared.policies
        let effMovie = PolicyResolver.resolve(isTv: false, global: global, task: plan.taskPolicy).naming
        let effTv = PolicyResolver.resolve(isTv: true, global: global, task: plan.taskPolicy).naming
        let provider = tmdbProvider ?? RealScannerTmdbProvider()
        let hooks = ScannerMovieLooseAndArtwork.makeReplanHooks(drive: drive, tmdb: provider, fullScrape: global.fullScrape)
        let mergeEnabled = plan.taskPolicy?.mergeSeries ?? global.mergeSeries
        let mergeMovies = plan.taskPolicy?.mergeMovieSeries ?? global.mergeMovieSeries
        let mergeTv = plan.taskPolicy?.mergeTvSeries ?? global.mergeTvSeries
        let appendTag = (plan.taskPolicy?.movieNaming ?? global.movieNaming).folderTmdbEnabled
        return try await StandardNaming.$scopedMoviePrefs.withValue(effMovie) {
            try await StandardNaming.$scopedTvPrefs.withValue(effTv) {
                let updated = try await ScannerReplan.replanTargetGroups(
                    plan: plan, targets: targets, info: info, cloud: drive, tmdb: provider, hooks: hooks
                )
                return SeriesMerger.mergeIfEnabled(updated, enabled: mergeEnabled, appendTag: appendTag, mergeMovies: mergeMovies, mergeTv: mergeTv)
            }
        }
    }
}

// MARK: - 待执行扫描的范围更新（仅本地提交）
public struct ScanPolicyOption: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let policy: PolicyOverride?
}
public struct ScanPolicyConflict: Error, Sendable {
    public let options: [ScanPolicyOption]
}

/// 先完整读取源目录，再让规划器在固定快照上工作，绝不通过此代理执行写请求。
public actor ScanSnapshotDrive: CloudDrive {
    public nonisolated let kind: ProviderKind
    public nonisolated let accountId: String
    public nonisolated let rootId: String
    public nonisolated let approvalBinding: String
    public nonisolated let isLanEndpoint: Bool
    public nonisolated let trashSupport: TrashSupport
    private let base: any CloudDrive
    private var listings: [String: [CloudEntry]] = [:]
    private var parents: [String: String] = [:]
    public init(_ base: any CloudDrive) {
        self.base = base; kind = base.kind; accountId = base.accountId; rootId = base.rootId
        approvalBinding = base.approvalBinding; isLanEndpoint = base.isLanEndpoint; trashSupport = base.trashSupport
    }
    public func list(folderId: String) async throws -> [CloudEntry] {
        if let cached = listings[folderId] { return cached }
        let entries = try await base.list(folderId: folderId)
        listings[folderId] = entries
        for entry in entries { parents[entry.fileId] = folderId }
        return entries
    }
    public func parentIdOf(fileId: String) async throws -> String? {
        if let parent = parents[fileId] { return parent }
        return try await base.parentIdOf(fileId: fileId)
    }
    public func read(roots: [PlanRoot]) async throws {
        var visited = Set<String>(), queue = roots.map { ($0.folderId, 0) }, count = 0
        for root in roots {
            if let parent = root.parentId { parents[root.folderId] = parent }
            var current = root.folderId, seen = Set<String>()
            while current != rootId && seen.insert(current).inserted {
                guard seen.count <= 128 else { throw DriveError.invalidInput("目录祖先链异常，旧计划未更新") }
                guard let parent = try await parentIdOf(fileId: current), parent != current else { break }
                parents[current] = parent; current = parent
            }
        }
        while !queue.isEmpty {
            try Task.checkCancellation()
            let (folder, depth) = queue.removeFirst()
            guard visited.insert(folder).inserted else { continue }
            guard visited.count <= 2000 && depth <= 64 else { throw DriveError.invalidInput("扫描范围过大，请拆分目录；旧计划未更新") }
            let entries = try await list(folderId: folder)
            count += entries.count
            guard count <= 200_000 else { throw DriveError.invalidInput("扫描文件过多，请拆分目录；旧计划未更新") }
            // 原盘由既有规划器整体保护，不读取其中的 Extras 等附属视频子树。
            if StandardNaming.isBdmvRoot(directChildDirNames: entries.filter(\.isDir).map(\.fileName)) { continue }
            queue += entries.filter { $0.isDir && !ScannerTreeEngine.ignoredDir($0.fileName) && !["BDMV", "CERTIFICATE"].contains($0.fileName.uppercased()) }.map { ($0.fileId, depth + 1) }
        }
    }
    public func captured() -> (listings: [String: [CloudEntry]], parents: [String: String]) { (listings, parents) }
    public func overlay(_ historical: [String: [CloudEntry]], outside roots: [PlanRoot], graph: [String: String]) {
        let observedParents = parents
        for (folder, entries) in historical where !roots.contains(where: { ScanPlanUpdater.contains(folder, root: $0.folderId, parents: graph, paths: kind.idsArePaths) }) {
            // 不在本次读取范围内的子树保留旧快照，避免子目录扫描覆盖其他部分。
            if listings[folder] == nil {
                listings[folder] = entries.filter { entry in observedParents[entry.fileId].map { $0 == folder } ?? true }
            }
        }
        for (folder, entries) in listings { for entry in entries { parents[entry.fileId] = folder } }
        parents.merge(observedParents, uniquingKeysWith: { _, observed in observed })
    }
    public func rename(fileId: String, newName: String) async throws -> String { throw DriveError.unsupported("扫描快照禁止写入") }
    public func mkdir(parentId: String, name: String) async throws -> String { throw DriveError.unsupported("扫描快照禁止写入") }
    public func move(fileId: String, destParentId: String) async throws -> String { throw DriveError.unsupported("扫描快照禁止写入") }
    public func upload(parentId: String, name: String, data: Data) async throws -> String { throw DriveError.unsupported("扫描快照禁止写入") }
}

public enum ScanPlanUpdater {
    public static func contains(_ id: String, root: String, parents: [String: String], paths: Bool) -> Bool {
        if id == root { return true }
        if paths {
            let prefix = root == "/" ? "/" : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if root == "/" { return id.hasPrefix("/") }
            return id.hasPrefix("/" + prefix + "/") || id.hasPrefix(prefix + "/")
        }
        var current = id, seen = Set<String>()
        while seen.insert(current).inserted, let parent = parents[current], parent != current {
            if parent == root { return true }; current = parent
        }
        return false
    }
    public static func overlap(_ a: [PlanRoot], _ b: [PlanRoot], parents: [String: String], paths: Bool) -> Bool {
        a.contains { left in b.contains { right in
            contains(left.folderId, root: right.folderId, parents: parents, paths: paths)
                || contains(right.folderId, root: left.folderId, parents: parents, paths: paths)
        } }
    }
    private static func files(_ listings: [String: [CloudEntry]]) -> [String: CloudEntry] {
        Dictionary(listings.values.flatMap { $0 }.filter { !$0.isDir && ScannerTreeEngine.isVideo($0) }.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private static func fileIds(_ group: PlanGroup, plan: ScrapePlan) -> Set<String> {
        Set(plan.actions.filter { $0.groupId == group.id && $0.kind == "file" }.compactMap(\.fileId))
    }
    public static func sameSource(_ old: CloudEntry, _ new: CloudEntry, paths: Bool) -> Bool {
        guard old.isDir == new.isDir && old.size == new.size else { return false }
        if paths {
            let strong = old.etag.map { !$0.isEmpty && !$0.lowercased().hasPrefix("w/") && $0 == new.etag } ?? false
            let hash = old.contentHash.map { !$0.isEmpty && $0 == new.contentHash && old.hashAlgorithm == new.hashAlgorithm } ?? false
            if !strong && !hash { return false }
        }
        if let etag = old.etag, let other = new.etag, etag != other { return false }
        if let hash = old.contentHash, let other = new.contentHash, hash != other { return false }
        return true
    }
    @MainActor private static func activePlans(_ account: String, store: PlanAndTaskStore) -> [ScrapePlan] {
        let active = store.tasks.filter { $0.accountId == account && ["running", "paused"].contains($0.status) }
        let taskPlans = active.compactMap { run in run.executionSnapshot ?? store.plans.first(where: { $0.id == run.planId }) }
        let queueIds = Set(TaskQueue.shared.items.filter { $0.accountId == account }.map(\.planId))
        return taskPlans + store.plans.filter { queueIds.contains($0.id) }
    }
    /// 返回前完成一次原子本地提交；任意取消、读取失败、修订冲突均不会替换旧卡片。
    @MainActor public static func scan(roots: [PlanRoot], drive: any CloudDrive, policyChoice: String? = nil,
                                      onProgress: Scanner.ProgressHandler? = nil, store injectedStore: PlanAndTaskStore? = nil,
                                      tmdbProvider: (any ScannerTmdbProvider)? = nil, preflightTmdb: Bool = true) async throws -> ScrapePlan {
        let store = injectedStore ?? PlanAndTaskStore.shared
        let roots = roots.isEmpty ? [PlanRoot(folderId: drive.rootId, name: "根目录")] : roots
        let revision = try store.scanRevision(accountId: drive.accountId)
        let oldPlans = store.pendingPlans.filter { $0.accountId == drive.accountId }
        let snapshot = ScanSnapshotDrive(drive)
        onProgress?("核对目录与文件变化…", 0)
        try await snapshot.read(roots: roots)
        let fresh = await snapshot.captured()
        var parents = fresh.parents
        for plan in oldPlans + activePlans(drive.accountId, store: store) {
            parents.merge(plan.scanParents ?? [:], uniquingKeysWith: { current, _ in current })
            for root in plan.roots { if let parent = root.parentId, parents[root.folderId] == nil { parents[root.folderId] = parent } }
        }
        func overlaps(_ plan: ScrapePlan) -> Bool {
            if overlap(roots, plan.roots, parents: parents, paths: drive.kind.idsArePaths) { return true }
            let newIds = Set(files(fresh.listings).keys)
            return plan.actions.contains { $0.fileId.map { newIds.contains($0) } ?? false }
        }
        guard !activePlans(drive.accountId, store: store).contains(where: overlaps) else { throw DriveError.invalidInput("扫描目录与正在执行、暂停或排队的任务重叠，请结束或取消该任务后重新扫描") }
        let affected = oldPlans.filter(overlaps)
        for plan in affected {
            if let binding = plan.scanBinding, !binding.isEmpty && binding != drive.approvalBinding {
                throw DriveError.invalidInput("原计划的账号绑定已变化，请取消旧计划后重新扫描")
            }
        }
        for old in affected {
            for root in roots {
                if let before = old.scanParents?[root.folderId], let after = fresh.parents[root.folderId], before != after {
                    throw DriveError.invalidInput("源目录位置已变化，请扫描新旧位置的共同父目录；旧计划未覆盖")
                }
            }
        }
        let policies = Set(affected.map(\.taskPolicy))
        let selectedPolicy: PolicyOverride?
        if policies.count > 1 {
            let options = affected.map { ScanPolicyOption(id: $0.id, title: "采用任务 \($0.id) 的策略", policy: $0.taskPolicy) }
                + [ScanPolicyOption(id: "defaults", title: "采用当前全局默认策略", policy: nil)]
            guard let choice = options.first(where: { $0.id == policyChoice }) else { throw ScanPolicyConflict(options: options) }
            selectedPolicy = choice.policy
        } else { selectedPolicy = affected.first?.taskPolicy }
        var union = roots + affected.flatMap(\.roots)
        var seen = Set<String>()
        union = union.filter { seen.insert($0.folderId).inserted }
        let allRoots = union
        union = union.filter { candidate in !allRoots.contains { other in other.folderId != candidate.folderId && contains(candidate.folderId, root: other.folderId, parents: parents, paths: drive.kind.idsArePaths) } }
        guard !activePlans(drive.accountId, store: store).contains(where: { overlap(union, $0.roots, parents: parents, paths: drive.kind.idsArePaths) }) else {
            throw DriveError.invalidInput("合并后的范围与执行或排队任务重叠，旧计划未更新")
        }
        for old in affected {
            if !(old.executionRunIds ?? []).isEmpty && !old.roots.allSatisfy({ oldRoot in roots.contains { contains(oldRoot.folderId, root: $0.folderId, parents: parents, paths: drive.kind.idsArePaths) } }) {
                throw DriveError.invalidInput("此计划曾部分执行，请完整重扫原根目录以核实位置；旧卡片未变更")
            }
            guard let listing = old.scanListings else {
                // 对旧版没有目录快照的父计划，无法安全保留未扫描子树。
                if !old.roots.allSatisfy({ oldRoot in roots.contains { contains(oldRoot.folderId, root: $0.folderId, parents: parents, paths: drive.kind.idsArePaths) } }) {
                    throw DriveError.invalidInput("旧计划没有完整文件快照，请重新扫描其根目录后再更新子目录；旧卡片未变更")
                }
                continue
            }
            await snapshot.overlay(listing, outside: roots, graph: parents)
        }
        try await snapshot.read(roots: union)
        var plan = try await Scanner.scan(roots: union, drive: snapshot, tmdbProvider: tmdbProvider, taskPolicy: selectedPolicy, preflightTmdb: preflightTmdb, persistResult: false, onProgress: onProgress)
        guard !plan.flags.contains(where: { $0.contains("只扫描了前") || $0.contains("目录层级太深") }) else {
            throw DriveError.invalidInput("本次扫描未覆盖完整目录，请拆分目录；旧计划未更新")
        }
        let inventory = await snapshot.captured()
        let sourceListings = inventory.listings.filter { folder, _ in
            union.contains { contains(folder, root: $0.folderId, parents: inventory.parents, paths: drive.kind.idsArePaths) }
        }
        let newFiles = files(sourceListings)
        let plannedSources = Set(plan.actions.compactMap(\.fileId))
        // 必须同时有原盘结构和对应作品分组，才认可为规划器有意保护的范围。
        let protectedDiscRoots = plan.groups.compactMap(\.folderId).filter { folder in
            guard let entries = sourceListings[folder] else { return false }
            return StandardNaming.isBdmvRoot(directChildDirNames: entries.filter(\.isDir).map(\.fileName))
        }
        let requiredSources = Set(newFiles.keys.filter { id in
            !protectedDiscRoots.contains { contains(id, root: $0, parents: inventory.parents, paths: drive.kind.idsArePaths) }
        })
        guard requiredSources.isSubset(of: plannedSources) else {
            throw DriveError.invalidInput("部分源视频未进入识别计划，不能安全判断删除或合并；请拆分目录重新扫描，旧计划未更新")
        }
        let allOldFiles = files(affected.reduce(into: [String: [CloudEntry]]()) { result, old in
            result.merge(old.scanListings ?? [:], uniquingKeysWith: { first, _ in first })
        })
        func digestKey(_ file: CloudEntry) -> String? {
            guard file.size > 0, let etag = file.etag, !etag.isEmpty, !etag.lowercased().hasPrefix("w/") else { return nil }
            return "\(file.size)|\(etag)"
        }
        let oldByDigest = Dictionary(grouping: allOldFiles.values.compactMap { file in digestKey(file).map { ($0, file.fileId) } }, by: { $0.0 })
        let newByDigest = Dictionary(grouping: newFiles.values.compactMap { file in digestKey(file).map { ($0, file.fileId) } }, by: { $0.0 })
        var originalIds: [String: String] = [:]
        for (key, old) in oldByDigest where old.count == 1 && newByDigest[key]?.count == 1 {
            if let new = newByDigest[key]?.first?.1 { originalIds[new] = old[0].1 }
        }
        func original(_ id: String) -> String { allOldFiles[id] != nil ? id : (originalIds[id] ?? id) }
        for freshGroup in plan.groups {
            let ids = fileIds(freshGroup, plan: plan)
            let matches = affected.flatMap { old in old.groups.map { (old, $0) } }.filter { old, group in
                !fileIds(group, plan: old).intersection(Set(ids.map(original))).isEmpty || (group.folderId != nil && group.folderId == freshGroup.folderId)
            }
            guard let (_, oldGroup) = matches.first else {
                let ambiguous = ids.contains { id in
                    guard allOldFiles[id] == nil, let file = newFiles[id], let key = digestKey(file) else { return false }
                    return oldByDigest[key] != nil && originalIds[id] == nil
                }
                if ambiguous, let index = plan.groups.firstIndex(where: { $0.id == freshGroup.id }) {
                    plan.groups[index].confirmRequired = true
                    plan.groups[index].confirmReasons.append("同内容文件存在多个副本，不能可靠继承旧匹配，请确认")
                    for index in plan.actions.indices where plan.actions[index].groupId == freshGroup.id { plan.actions[index].selected = false }
                }
                continue
            }
            guard matches.allSatisfy({ _, group in
                group.kind == oldGroup.kind && group.tmdbId == oldGroup.tmdbId && group.policyOverride == oldGroup.policyOverride
                    && group.episodeStrategy == oldGroup.episodeStrategy && group.episodeGroupId == oldGroup.episodeGroupId
            }) else { throw DriveError.invalidInput("多份旧作品的匹配或策略不同，需先在原任务中确认后重新扫描") }
            let common = ids.filter { allOldFiles[original($0)] != nil }
            let verified = !common.isEmpty && common.allSatisfy { id in
                guard let before = allOldFiles[original(id)], let after = newFiles[id] else { return false }
                return sameSource(before, after, paths: drive.kind.idsArePaths)
            }
            guard verified else {
                if let index = plan.groups.firstIndex(where: { $0.id == freshGroup.id }) {
                    plan.groups[index].confirmRequired = true
                    plan.groups[index].confirmReasons.append("源文件变化或旧快照不足，请重新确认识别与编号；原匹配：《\(oldGroup.title)》TMDB \(oldGroup.tmdbId.map(String.init) ?? "未知")，原策略：\(oldGroup.episodeStrategy)")
                    for index in plan.actions.indices where plan.actions[index].groupId == freshGroup.id { plan.actions[index].selected = false }
                }
                continue
            }
            let manual = oldGroup.confidence == "手动"
            if manual || (oldGroup.tmdbId == freshGroup.tmdbId && oldGroup.kind == freshGroup.kind) {
                if let index = plan.groups.firstIndex(where: { $0.id == freshGroup.id }) { plan.groups[index].policyOverride = oldGroup.policyOverride }
                if let id = oldGroup.tmdbId, ["movie", "tv"].contains(oldGroup.kind),
                   manual || oldGroup.policyOverride != nil || oldGroup.episodeStrategy != "original" || oldGroup.episodeGroupId != nil {
                    let info = MatchInfo(kind: oldGroup.kind, id: id, title: oldGroup.title, year: oldGroup.year,
                        posterPath: oldGroup.posterPath, originalTitle: oldGroup.originalTitle, rating: oldGroup.rating, genreIds: oldGroup.genreIds)
                    plan = try await Scanner.replanGroup(plan: plan, groupId: freshGroup.id, info: info, drive: snapshot,
                        strategy: EpisodeStrategy.fromId(oldGroup.episodeStrategy), episodeGroupId: oldGroup.episodeGroupId,
                        episodeGroupName: oldGroup.episodeGroupName, policyOverride: oldGroup.policyOverride, tmdbProvider: tmdbProvider)
                }
                let oldActions = matches.flatMap { old, group in old.actions.filter { $0.groupId == group.id && ExecutionEngine.execOps.contains($0.op) && !$0.done } }
                var numberedFiles = Set<String>()
                let numbering = plan.actions.compactMap { action -> GroupMatchOverride? in
                    guard let file = action.fileId, ids.contains(file), action.kind == "file", ["rename", "skip"].contains(action.op),
                          let old = oldActions.first(where: { $0.fileId == original(file) && $0.kind == "file" && ["rename", "skip"].contains($0.op) }),
                          let season = old.season, let episode = old.episode,
                          (old.season != action.season || old.episode != action.episode), numberedFiles.insert(file).inserted else { return nil }
                    return GroupMatchOverride(key: file, actionIds: [action.id], season: season, episode: episode, year: oldGroup.year)
                }
                if !numbering.isEmpty, let id = oldGroup.tmdbId, oldGroup.kind == "tv" {
                    let info = MatchInfo(kind: "tv", id: id, title: oldGroup.title, year: oldGroup.year, posterPath: oldGroup.posterPath, genreIds: oldGroup.genreIds)
                    plan = try await Scanner.replanTargetGroups(plan: plan, targets: numbering, info: info, drive: snapshot, tmdbProvider: tmdbProvider)
                    if plan.flags.contains(where: { $0.contains("批量识别未完成") }) { throw DriveError.invalidInput("原手动编号无法完整继承，旧任务未覆盖，请在原预览中核实") }
                }
                let wholeDeselected = !oldActions.isEmpty && oldActions.allSatisfy { !$0.selected }
                for index in plan.actions.indices {
                    let action = plan.actions[index]
                    guard let file = action.fileId, ids.contains(file) else { continue }
                    if wholeDeselected || oldActions.contains(where: { $0.fileId == original(file) && $0.op == action.op && !$0.selected }) { plan.actions[index].selected = false }
                }
                if wholeDeselected {
                    let groupIds = Set(plan.actions.filter { $0.fileId.map { ids.contains($0) } ?? false }.map(\.groupId))
                    for index in plan.actions.indices where groupIds.contains(plan.actions[index].groupId) { plan.actions[index].selected = false }
                }
            } else if let index = plan.groups.firstIndex(where: { $0.id == freshGroup.id }) {
                plan.groups[index].confirmRequired = true
                plan.groups[index].confirmReasons.append("新旧作品身份不同，请重新确认")
                for index in plan.actions.indices where plan.actions[index].groupId == freshGroup.id { plan.actions[index].selected = false }
            }
        }
        let unselected = Set(plan.actions.filter { !$0.selected }.map(\.id))
        plan = PolicyResolver.applyOverrides(to: plan, global: AppSettings.shared.policies)
        let requireConfirmation = Set(plan.groups.filter(\.confirmRequired).map(\.id))
        for index in plan.actions.indices where unselected.contains(plan.actions[index].id) || requireConfirmation.contains(plan.actions[index].groupId) {
            plan.actions[index].selected = false
        }
        try Task.checkCancellation()
        guard try store.scanRevision(accountId: drive.accountId) == revision,
              !activePlans(drive.accountId, store: store).contains(where: { overlap(union, $0.roots, parents: parents, paths: drive.kind.idsArePaths) }) else {
            throw DriveError.invalidInput("扫描期间计划或执行状态已变化，旧计划未覆盖，请重新扫描")
        }
        let primary = affected.first
        var committed = ScrapePlan(id: primary?.id ?? plan.id, accountId: plan.accountId, provider: plan.provider,
            createdAt: primary?.createdAt ?? plan.createdAt, roots: plan.roots, groups: plan.groups, actions: plan.actions,
            flags: plan.flags, taskPolicy: plan.taskPolicy)
        committed.reviewDisposition = "pending"
        committed.scanListings = sourceListings; committed.scanParents = inventory.parents; committed.scanBinding = drive.approvalBinding
        let oldFileIds = Set(affected.flatMap { files($0.scanListings ?? [:]).keys })
        committed.flags.append("扫描更新：新增 \(Set(newFiles.keys).subtracting(oldFileIds).count) 个视频，移除 \(oldFileIds.subtracting(newFiles.keys).count) 个视频，合并 \(affected.count) 个计划")
        // 依据源文件与操作角色迁移提交范围，不能依赖重新规划生成的随机动作 ID。
        func operationKey(_ action: PlanAction, oldSource: Bool, context: ScrapePlan) -> String {
            let source = action.fileId.map { oldSource ? $0 : original($0) } ?? "parent:\(action.parentId ?? "")|tmdb:\(action.tmdbId ?? 0)"
            let destination = action.destParentId ?? action.destLabel
                ?? action.destRef.flatMap { ref in context.actions.first(where: { $0.id == ref }).map { "\($0.parentId ?? "")/\($0.newName)" } } ?? ""
            return "\(source)|\(action.op)|\(action.kind)|\(action.newName)|\(destination)"
        }
        var prior: [String: PlanAction] = [:]
        var priorIds = Set<String>()
        for old in affected {
            let reserved = store.reservedActionIds(planId: old.id)
            priorIds.formUnion(reserved)
            for action in old.actions where reserved.contains(action.id) { prior[operationKey(action, oldSource: true, context: old)] = action }
        }
        let reservedFileRoles = Set(prior.values.filter { $0.kind == "file" }.compactMap { action in action.fileId.map { "\($0)|\(action.op)|\(action.kind)" } })
        let unmodifiedPlan = committed
        var remapped: [String: String] = [:]
        var changedIntentGroups = Set<String>()
        for index in committed.actions.indices {
            if let old = prior[operationKey(committed.actions[index], oldSource: false, context: unmodifiedPlan)] {
                remapped[committed.actions[index].id] = old.id
                committed.actions[index] = committed.actions[index].withId(old.id)
                // 当前扫描仍需建目录，保留相同语义的历史 ID 供重试，但不套用旧完成状态。
                committed.actions[index].done = committed.actions[index].op == "mkdir" ? false : old.done
                committed.actions[index].selected = false
            } else {
                // 分类目录等动作使用固定 ID；更换目标库后不能仍命中旧提交范围与旧 WAL。
                if priorIds.contains(committed.actions[index].id) {
                    let oldId = committed.actions[index].id
                    let newId = "scan-\(UUID().uuidString.lowercased())"
                    remapped[oldId] = newId
                    committed.actions[index] = committed.actions[index].withId(newId)
                }
                if let file = committed.actions[index].fileId,
                   reservedFileRoles.contains("\(original(file))|\(committed.actions[index].op)|\(committed.actions[index].kind)") {
                    changedIntentGroups.insert(committed.actions[index].groupId)
                }
            }
        }
        for index in committed.groups.indices where changedIntentGroups.contains(committed.groups[index].id) {
            committed.groups[index].confirmRequired = true
            committed.groups[index].confirmReasons.append("原执行步骤的名称或目标已变化，请确认本次新操作；旧历史不会改写")
        }
        for index in committed.actions.indices where changedIntentGroups.contains(committed.actions[index].groupId) { committed.actions[index].selected = false }
        for index in committed.actions.indices {
            if let ref = committed.actions[index].destRef { committed.actions[index].destRef = remapped[ref] ?? ref }
        }
        for index in committed.groups.indices { committed.groups[index].actionIds = committed.groups[index].actionIds.map { remapped[$0] ?? $0 } }
        committed.submittedActionIds = priorIds.sorted()
        committed.executionRunIds = Array(Set(affected.flatMap { $0.executionRunIds ?? [] }))
        committed.scanPriorRunIds = committed.executionRunIds
        let owners = Dictionary(grouping: committed.actions.filter { $0.kind == "file" && $0.fileId != nil }, by: { $0.fileId! })
        guard owners.values.allSatisfy({ Set($0.map(\.groupId)).count <= 1 }) else {
            throw DriveError.invalidInput("同一源视频被归入多个作品，请核实目录或匹配冲突；旧计划未覆盖")
        }
        guard Set(committed.actions.map(\.id)).count == committed.actions.count else {
            throw DriveError.invalidInput("合并后存在重复操作身份，请先处理原计划的目录冲突；旧卡片未覆盖")
        }
        try store.commitScan(committed, replacing: Set(affected.map(\.id)))
        if injectedStore == nil { _ = try? PlanStore.shared.save(committed) }
        return committed
    }
}
