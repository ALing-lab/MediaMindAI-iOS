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

        let effectiveRoots: [PlanRoot] = {
            if fullDrive || roots.isEmpty {
                return [PlanRoot(folderId: drive.rootId, name: "根目录", parentId: nil)]
            }
            return roots
        }()

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
        let appendTag = (taskPolicy?.movieNaming ?? global.movieNaming).folderTmdbEnabled
        plan = SeriesMerger.mergeIfEnabled(plan, enabled: mergeEnabled, appendTag: appendTag)
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
        _ = try? PlanStore.shared.save(plan)
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
        return try await StandardNaming.$scopedMoviePrefs.withValue(effMovie) {
            try await StandardNaming.$scopedTvPrefs.withValue(effTv) {
                try await ScannerReplan.replanGroup(
                    plan: plan, groupId: groupId, info: info, cloud: drive,
                    strategy: strategy, episodeGroupId: episodeGroupId, episodeGroupName: episodeGroupName,
                    policyOverride: policyOverride, hooks: hooks
                )
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
        return try await StandardNaming.$scopedMoviePrefs.withValue(effMovie) {
            try await StandardNaming.$scopedTvPrefs.withValue(effTv) {
                try await ScannerReplan.replanFiles(
                    plan: plan, actionIds: actionIds, info: info, cloud: drive, hooks: hooks
                )
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
        return try await StandardNaming.$scopedMoviePrefs.withValue(effMovie) {
            try await StandardNaming.$scopedTvPrefs.withValue(effTv) {
                try await ScannerReplan.replanTargetGroups(
                    plan: plan, targets: targets, info: info, cloud: drive, tmdb: provider, hooks: hooks
                )
            }
        }
    }
}
