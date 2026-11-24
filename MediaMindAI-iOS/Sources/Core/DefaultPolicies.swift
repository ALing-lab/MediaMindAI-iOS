import Foundation

/// 1:1 复刻自 Android `DefaultPolicies.kt` + `NfoFields.kt`：
/// 完整三级策略覆盖体系（影片/分组级 > 任务/计划级 > 全局默认级）+ 电影/剧集独立命名偏好 + NFO 字段过滤。

public struct MediaDefaults: Codable, Hashable, Sendable {
    public var nfo: Bool
    public var poster: Bool
    public var fanart: Bool
    public var logo: Bool

    public init(nfo: Bool = true, poster: Bool = true, fanart: Bool = true, logo: Bool = true) {
        self.nfo = nfo
        self.poster = poster
        self.fanart = fanart
        self.logo = logo
    }
}

/// 单类影视（电影 / 剧集）的文件与文件夹命名偏好；默认值严格对齐 Android 定版命名规范。
public struct MediaNamingPrefs: Codable, Hashable, Sendable {
    public static let defaultTvQuality = ["HDR", "HDR10", "HDR10+", "HDRVivid", "DV", "EDR", "SDR"]
    public static let defaultMovieQuality = ["HDR", "HDR10", "HDR10+", "HDRVivid", "DV", "EDR", "SDR", "UHD", "BluRay"]

    // 文件名偏好
    public var fileTmdbEnabled: Bool
    public var fileTmdbStyle: String // "{tmdb-id}" | "[tmdb-id]" | "[tmdbid=id]" | "tmdb-id"
    public var fileSeparator: String
    public var fileYearEnabled: Bool
    public var fileYearStyle: String // "(year)" | "[year]" | "year"
    public var fileLanguage: String // "chinese" | "english" | "bilingual" | "none"
    public var keepExtraInfo: Bool
    public var keepResolution: Bool
    public var keepQuality: Bool
    public var keepFps: Bool
    public var keepAudio: Bool
    public var defaultSdrWhenMissing: Bool
    public var qualityTokens: [String]

    // 文件夹命名偏好
    public var folderMatchFileName: Bool
    public var folderTmdbEnabled: Bool
    public var folderTmdbStyle: String
    public var folderSeparator: String
    public var folderYearEnabled: Bool
    public var folderYearStyle: String
    public var folderLanguage: String

    public init(
        fileTmdbEnabled: Bool = true,
        fileTmdbStyle: String = "{tmdb-id}",
        fileSeparator: String = " ",
        fileYearEnabled: Bool = true,
        fileYearStyle: String = "(year)",
        fileLanguage: String = "chinese",
        keepExtraInfo: Bool = true,
        keepResolution: Bool = true,
        keepQuality: Bool = true,
        keepFps: Bool = true,
        keepAudio: Bool = true,
        defaultSdrWhenMissing: Bool = false,
        qualityTokens: [String] = MediaNamingPrefs.defaultMovieQuality,
        folderMatchFileName: Bool = true,
        folderTmdbEnabled: Bool = true,
        folderTmdbStyle: String = "{tmdb-id}",
        folderSeparator: String = " ",
        folderYearEnabled: Bool = true,
        folderYearStyle: String = "(year)",
        folderLanguage: String = "chinese"
    ) {
        self.fileTmdbEnabled = fileTmdbEnabled
        self.fileTmdbStyle = fileTmdbStyle
        self.fileSeparator = fileSeparator
        self.fileYearEnabled = fileYearEnabled
        self.fileYearStyle = fileYearStyle
        self.fileLanguage = fileLanguage
        self.keepExtraInfo = keepExtraInfo
        self.keepResolution = keepResolution
        self.keepQuality = keepQuality
        self.keepFps = keepFps
        self.keepAudio = keepAudio
        self.defaultSdrWhenMissing = defaultSdrWhenMissing
        self.qualityTokens = qualityTokens
        self.folderMatchFileName = folderMatchFileName
        self.folderTmdbEnabled = folderTmdbEnabled
        self.folderTmdbStyle = folderTmdbStyle
        self.folderSeparator = folderSeparator
        self.folderYearEnabled = folderYearEnabled
        self.folderYearStyle = folderYearStyle
        self.folderLanguage = folderLanguage
    }

    public static func movieDefault() -> MediaNamingPrefs {
        MediaNamingPrefs(
            fileTmdbEnabled: true, fileTmdbStyle: "{tmdb-id}", fileSeparator: " ",
            fileYearEnabled: true, fileYearStyle: "(year)", fileLanguage: "chinese",
            keepExtraInfo: true, keepResolution: true, keepQuality: true, keepFps: true, keepAudio: true,
            defaultSdrWhenMissing: false, qualityTokens: defaultMovieQuality,
            folderMatchFileName: true, folderTmdbEnabled: true, folderTmdbStyle: "{tmdb-id}",
            folderSeparator: " ", folderYearEnabled: true, folderYearStyle: "(year)", folderLanguage: "chinese"
        )
    }

    public static func tvDefault() -> MediaNamingPrefs {
        MediaNamingPrefs(
            fileTmdbEnabled: true, fileTmdbStyle: "{tmdb-id}", fileSeparator: " ",
            fileYearEnabled: false, fileYearStyle: "(year)", fileLanguage: "chinese",
            keepExtraInfo: true, keepResolution: true, keepQuality: true, keepFps: true, keepAudio: true,
            defaultSdrWhenMissing: false, qualityTokens: defaultTvQuality,
            folderMatchFileName: true, folderTmdbEnabled: true, folderTmdbStyle: "{tmdb-id}",
            folderSeparator: " ", folderYearEnabled: true, folderYearStyle: "(year)", folderLanguage: "chinese"
        )
    }

    public func effectiveFolderLanguage() -> String {
        folderMatchFileName ? fileLanguage : folderLanguage
    }

    public func fileOptions() -> StandardNaming.FileOptions {
        StandardNaming.FileOptions(
            keepExtraInfo: keepExtraInfo,
            keepResolution: keepResolution,
            keepQuality: keepQuality,
            keepFps: keepFps,
            keepAudio: keepAudio,
            defaultSdrWhenMissing: defaultSdrWhenMissing,
            qualityTokens: qualityTokens,
            tmdbEnabled: fileTmdbEnabled,
            tmdbStyle: fileTmdbStyle,
            separator: fileSeparator,
            yearEnabled: fileYearEnabled,
            yearStyle: fileYearStyle
        )
    }

    public func resolveTitle(lang: String, zh: String, en: String, orig: String) -> String {
        switch lang {
        case "english": return en.isEmpty ? zh : en
        case "bilingual": return (en.isEmpty || en == zh) ? zh : "\(zh) \(en)"
        case "none": return orig.isEmpty ? zh : orig
        default: return zh
        }
    }

    public func previewFolder(isTv: Bool, renameFolders: Bool) -> String {
        let origFolder = isTv ? "iPartment.5.S05.2160p.HDRVivid" : "The.Wandering.Earth.2019.2160p.UHD.Blu-ray"
        guard renameFolders else { return origFolder }
        let title = resolveTitle(
            lang: effectiveFolderLanguage(),
            zh: isTv ? "爱情公寓5" : "流浪地球",
            en: isTv ? "iPartment 5" : "The Wandering Earth",
            orig: isTv ? "iPartment 5" : "The.Wandering.Earth"
        )
        return StandardNaming.folderName(title: title, year: isTv ? "2020" : "2019", tmdbId: isTv ? 68809 : 535167, prefs: self)
    }

    public func previewFile(isTv: Bool, renameFiles: Bool) -> String {
        let origFile = isTv
            ? "iPartment.5.S05E01.2160p.60fps.HDRVivid.DDP.5.1.mkv"
            : "The.Wandering.Earth.2019.2160p.24fps.UHD.Blu-ray.TrueHD.7.1.mkv"
        guard renameFiles else { return origFile }
        let (stem, ext) = MediaParser.splitNameExt(origFile)
        let title = resolveTitle(
            lang: fileLanguage,
            zh: isTv ? "爱情公寓5" : "流浪地球",
            en: isTv ? "iPartment 5" : "The Wandering Earth",
            orig: isTv ? "iPartment 5" : "The.Wandering.Earth"
        )
        if isTv {
            return StandardNaming.episodeFileBase(
                title: title, season: 5, episode: 1, tmdbId: 68809,
                fileStem: stem, options: fileOptions(), year: "2020"
            ) + ext
        } else {
            return StandardNaming.movieFileBase(
                title: title, year: "2019", tmdbId: 535167,
                fileStem: stem, options: fileOptions()
            ) + ext
        }
    }
}

/// 第 1 层：全局默认策略（对标 Android `DefaultPolicies`）。
public struct DefaultPolicies: Codable, Hashable, Sendable {
    public var organizeEnabled: Bool = true
    public var scrapeEnabled: Bool = true
    public var renameFiles: Bool = true
    public var renameFolders: Bool = true
    public var seasonFolders: Bool = true
    public var mergeSeries: Bool = true
    public var episodeStrategy: String = EpisodeStrategy.original.rawValue
    public var fullScrape: Bool = false
    public var imageQuality: ImageQualityOption = .standard
    public var movieNaming: MediaNamingPrefs = .movieDefault()
    public var tvNaming: MediaNamingPrefs = .tvDefault()
    public var movie: MediaDefaults = MediaDefaults(nfo: true, poster: true, fanart: false, logo: false)
    public var tv: MediaDefaults = MediaDefaults(nfo: true, poster: true, fanart: false, logo: false)
    public var seasonPoster: Bool = true
    public var episodeNfo: Bool = true
    public var episodeThumb: Bool = false
    public var adaptiveDirectory: Bool = false
    public var adaptiveTargetDirId: String = ""
    public var adaptiveTargetDirPath: String = ""
    public var autoMoveConfirmedDuplicates: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case organizeEnabled, scrapeEnabled, renameFiles, renameFolders, seasonFolders
        case mergeSeries, episodeStrategy, fullScrape, imageQuality
        case movieNaming, tvNaming, movie, tv
        case seasonPoster, episodeNfo, episodeThumb
        case adaptiveDirectory, adaptiveTargetDirId, adaptiveTargetDirPath, autoMoveConfirmedDuplicates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.organizeEnabled = try c.decodeIfPresent(Bool.self, forKey: .organizeEnabled) ?? true
        self.scrapeEnabled = try c.decodeIfPresent(Bool.self, forKey: .scrapeEnabled) ?? true
        self.renameFiles = try c.decodeIfPresent(Bool.self, forKey: .renameFiles) ?? true
        self.renameFolders = try c.decodeIfPresent(Bool.self, forKey: .renameFolders) ?? true
        self.seasonFolders = try c.decodeIfPresent(Bool.self, forKey: .seasonFolders) ?? true
        self.mergeSeries = try c.decodeIfPresent(Bool.self, forKey: .mergeSeries) ?? true
        self.episodeStrategy = try c.decodeIfPresent(String.self, forKey: .episodeStrategy) ?? EpisodeStrategy.original.rawValue
        self.fullScrape = try c.decodeIfPresent(Bool.self, forKey: .fullScrape) ?? false
        self.imageQuality = try c.decodeIfPresent(ImageQualityOption.self, forKey: .imageQuality) ?? .standard
        self.movieNaming = try c.decodeIfPresent(MediaNamingPrefs.self, forKey: .movieNaming) ?? .movieDefault()
        self.tvNaming = try c.decodeIfPresent(MediaNamingPrefs.self, forKey: .tvNaming) ?? .tvDefault()
        self.movie = try c.decodeIfPresent(MediaDefaults.self, forKey: .movie) ?? MediaDefaults(nfo: true, poster: true, fanart: false, logo: false)
        self.tv = try c.decodeIfPresent(MediaDefaults.self, forKey: .tv) ?? MediaDefaults(nfo: true, poster: true, fanart: false, logo: false)
        self.seasonPoster = try c.decodeIfPresent(Bool.self, forKey: .seasonPoster) ?? true
        self.episodeNfo = try c.decodeIfPresent(Bool.self, forKey: .episodeNfo) ?? true
        self.episodeThumb = try c.decodeIfPresent(Bool.self, forKey: .episodeThumb) ?? false
        self.adaptiveDirectory = try c.decodeIfPresent(Bool.self, forKey: .adaptiveDirectory) ?? false
        self.adaptiveTargetDirId = try c.decodeIfPresent(String.self, forKey: .adaptiveTargetDirId) ?? ""
        self.adaptiveTargetDirPath = try c.decodeIfPresent(String.self, forKey: .adaptiveTargetDirPath) ?? ""
        self.autoMoveConfirmedDuplicates = try c.decodeIfPresent(Bool.self, forKey: .autoMoveConfirmedDuplicates) ?? false
    }
}

public extension DefaultPolicies {
    /// 设置首页「整理与命名策略」右侧状态摘要：重命名与整理 / 只重命名 / 只整理 / 已关闭。
    var organizeSummaryLabel: String {
        guard organizeEnabled else { return "已关闭" }
        let hasRename = renameFiles || renameFolders
        let hasOrganize = seasonFolders || adaptiveDirectory
        switch (hasRename, hasOrganize) {
        case (true, true): return "重命名与整理"
        case (true, false): return "只重命名"
        case (false, true): return "只整理"
        case (false, false): return "已关闭"
        }
    }

    /// 将第 2 层（任务策略）或第 3 层（影片策略）覆写合并到当前基准策略副本，供完整策略页展示与实时编辑。
    func applying(_ override: PolicyOverride?) -> DefaultPolicies {
        guard let ov = override else { return self }
        var out = self
        if let v = ov.organizeEnabled { out.organizeEnabled = v }
        if let v = ov.scrapeEnabled { out.scrapeEnabled = v }
        if let v = ov.renameFiles { out.renameFiles = v }
        if let v = ov.renameFolders { out.renameFolders = v }
        if let v = ov.seasonFolders { out.seasonFolders = v }
        if let v = ov.mergeSeries { out.mergeSeries = v }
        if let v = ov.episodeStrategy { out.episodeStrategy = v }
        if let v = ov.fullScrape { out.fullScrape = v }
        if let v = ov.imageQuality { out.imageQuality = v }
        if let v = ov.movieNaming { out.movieNaming = v }
        if let v = ov.tvNaming { out.tvNaming = v }
        if let v = ov.writeNfo { out.movie.nfo = v; out.tv.nfo = v }
        if let v = ov.downloadPoster { out.movie.poster = v; out.tv.poster = v }
        if let v = ov.downloadFanart { out.movie.fanart = v; out.tv.fanart = v }
        if let v = ov.downloadClearlogo { out.movie.logo = v; out.tv.logo = v }
        if let v = ov.seasonPoster { out.seasonPoster = v }
        if let v = ov.episodeNfo { out.episodeNfo = v }
        if let v = ov.downloadEpisodeThumb { out.episodeThumb = v }
        if let v = ov.adaptiveDirectory { out.adaptiveDirectory = v }
        if let v = ov.adaptiveTargetDirId { out.adaptiveTargetDirId = v }
        if let v = ov.adaptiveTargetDirPath { out.adaptiveTargetDirPath = v }
        if let v = ov.autoMoveConfirmedDuplicates { out.autoMoveConfirmedDuplicates = v }
        return out
    }

    /// 计算相对上层基准策略的差量覆写，仅记录本层级修改过的差异项。
    func diffOverride(from base: DefaultPolicies) -> PolicyOverride {
        var ov = PolicyOverride()
        if organizeEnabled != base.organizeEnabled { ov.organizeEnabled = organizeEnabled }
        if scrapeEnabled != base.scrapeEnabled { ov.scrapeEnabled = scrapeEnabled }
        if renameFiles != base.renameFiles { ov.renameFiles = renameFiles }
        if renameFolders != base.renameFolders { ov.renameFolders = renameFolders }
        if seasonFolders != base.seasonFolders { ov.seasonFolders = seasonFolders }
        if mergeSeries != base.mergeSeries { ov.mergeSeries = mergeSeries }
        if episodeStrategy != base.episodeStrategy { ov.episodeStrategy = episodeStrategy }
        if fullScrape != base.fullScrape { ov.fullScrape = fullScrape }
        if imageQuality != base.imageQuality { ov.imageQuality = imageQuality }
        if movieNaming != base.movieNaming { ov.movieNaming = movieNaming }
        if tvNaming != base.tvNaming { ov.tvNaming = tvNaming }
        if movie.nfo != base.movie.nfo { ov.writeNfo = movie.nfo }
        else if tv.nfo != base.tv.nfo { ov.writeNfo = tv.nfo }
        if movie.poster != base.movie.poster { ov.downloadPoster = movie.poster }
        else if tv.poster != base.tv.poster { ov.downloadPoster = tv.poster }
        if movie.fanart != base.movie.fanart { ov.downloadFanart = movie.fanart }
        else if tv.fanart != base.tv.fanart { ov.downloadFanart = tv.fanart }
        if movie.logo != base.movie.logo { ov.downloadClearlogo = movie.logo }
        else if tv.logo != base.tv.logo { ov.downloadClearlogo = tv.logo }
        if seasonPoster != base.seasonPoster { ov.seasonPoster = seasonPoster }
        if episodeNfo != base.episodeNfo { ov.episodeNfo = episodeNfo }
        if episodeThumb != base.episodeThumb { ov.downloadEpisodeThumb = episodeThumb }
        if adaptiveDirectory != base.adaptiveDirectory { ov.adaptiveDirectory = adaptiveDirectory }
        if adaptiveTargetDirId != base.adaptiveTargetDirId { ov.adaptiveTargetDirId = adaptiveTargetDirId }
        if adaptiveTargetDirPath != base.adaptiveTargetDirPath { ov.adaptiveTargetDirPath = adaptiveTargetDirPath }
        if autoMoveConfirmedDuplicates != base.autoMoveConfirmedDuplicates { ov.autoMoveConfirmedDuplicates = autoMoveConfirmedDuplicates }
        return ov
    }
}

/// 第 2 层（任务/计划级）与第 3 层（影片/分组级）可覆写策略切片。
/// 非 nil 字段优先生效，nil 字段自动向下继承上一层策略。
public struct PolicyOverride: Codable, Hashable, Sendable {
    public var organizeEnabled: Bool?
    public var scrapeEnabled: Bool?
    public var renameFiles: Bool?
    public var renameFolders: Bool?
    public var seasonFolders: Bool?
    public var mergeSeries: Bool?
    public var episodeStrategy: String?
    public var fullScrape: Bool?
    public var imageQuality: ImageQualityOption?
    public var movieNaming: MediaNamingPrefs?
    public var tvNaming: MediaNamingPrefs?
    public var writeNfo: Bool?
    public var downloadPoster: Bool?
    public var downloadFanart: Bool?
    public var downloadClearlogo: Bool?
    public var seasonPoster: Bool?
    public var episodeNfo: Bool?
    public var downloadEpisodeThumb: Bool?
    public var adaptiveDirectory: Bool?
    public var adaptiveTargetDirId: String?
    public var adaptiveTargetDirPath: String?
    public var autoMoveConfirmedDuplicates: Bool?

    public init(
        organizeEnabled: Bool? = nil,
        scrapeEnabled: Bool? = nil,
        renameFiles: Bool? = nil,
        renameFolders: Bool? = nil,
        seasonFolders: Bool? = nil,
        mergeSeries: Bool? = nil,
        episodeStrategy: String? = nil,
        fullScrape: Bool? = nil,
        imageQuality: ImageQualityOption? = nil,
        movieNaming: MediaNamingPrefs? = nil,
        tvNaming: MediaNamingPrefs? = nil,
        writeNfo: Bool? = nil,
        downloadPoster: Bool? = nil,
        downloadFanart: Bool? = nil,
        downloadClearlogo: Bool? = nil,
        seasonPoster: Bool? = nil,
        episodeNfo: Bool? = nil,
        downloadEpisodeThumb: Bool? = nil,
        adaptiveDirectory: Bool? = nil,
        adaptiveTargetDirId: String? = nil,
        adaptiveTargetDirPath: String? = nil,
        autoMoveConfirmedDuplicates: Bool? = nil
    ) {
        self.organizeEnabled = organizeEnabled
        self.scrapeEnabled = scrapeEnabled
        self.renameFiles = renameFiles
        self.renameFolders = renameFolders
        self.seasonFolders = seasonFolders
        self.mergeSeries = mergeSeries
        self.episodeStrategy = episodeStrategy
        self.fullScrape = fullScrape
        self.imageQuality = imageQuality
        self.movieNaming = movieNaming
        self.tvNaming = tvNaming
        self.writeNfo = writeNfo
        self.downloadPoster = downloadPoster
        self.downloadFanart = downloadFanart
        self.downloadClearlogo = downloadClearlogo
        self.seasonPoster = seasonPoster
        self.episodeNfo = episodeNfo
        self.downloadEpisodeThumb = downloadEpisodeThumb
        self.adaptiveDirectory = adaptiveDirectory
        self.adaptiveTargetDirId = adaptiveTargetDirId
        self.adaptiveTargetDirPath = adaptiveTargetDirPath
        self.autoMoveConfirmedDuplicates = autoMoveConfirmedDuplicates
    }
}

/// 合并后的生效策略快照（由 `PolicyResolver` 按 影片级 > 任务级 > 全局级 解析生成）。
public struct EffectivePolicy: Hashable, Sendable {
    public let organizeEnabled: Bool
    public let scrapeEnabled: Bool
    public let renameFiles: Bool
    public let renameFolders: Bool
    public let seasonFolders: Bool
    public let mergeSeries: Bool
    public let fullScrape: Bool
    public let imageQuality: ImageQualityOption
    public let naming: MediaNamingPrefs
    public let writeNfo: Bool
    public let downloadPoster: Bool
    public let downloadFanart: Bool
    public let downloadClearlogo: Bool
    public let downloadEpisodeThumb: Bool
    public let seasonPoster: Bool
    public let episodeNfo: Bool
    public let sourceLayer: String // "影片策略" | "任务策略" | "全局策略"
}

/// 三级策略优先级解析器：影片/分组策略（Layer 3） > 任务/计划策略（Layer 2） > 全局默认策略（Layer 1）。
public enum PolicyResolver {
    public static func resolve(
        isTv: Bool,
        global: DefaultPolicies,
        task: PolicyOverride? = nil,
        film: PolicyOverride? = nil
    ) -> EffectivePolicy {
        let baseMedia = isTv ? global.tv : global.movie
        let baseNaming = isTv ? global.tvNaming : global.movieNaming
        let taskNaming = isTv ? task?.tvNaming : task?.movieNaming
        let filmNaming = isTv ? film?.tvNaming : film?.movieNaming

        let sourceLayer: String
        if film != nil { sourceLayer = "影片策略" }
        else if task != nil { sourceLayer = "任务策略" }
        else { sourceLayer = "全局策略" }

        return EffectivePolicy(
            organizeEnabled: film?.organizeEnabled ?? task?.organizeEnabled ?? global.organizeEnabled,
            scrapeEnabled: film?.scrapeEnabled ?? task?.scrapeEnabled ?? global.scrapeEnabled,
            renameFiles: film?.renameFiles ?? task?.renameFiles ?? global.renameFiles,
            renameFolders: film?.renameFolders ?? task?.renameFolders ?? global.renameFolders,
            seasonFolders: film?.seasonFolders ?? task?.seasonFolders ?? global.seasonFolders,
            mergeSeries: film?.mergeSeries ?? task?.mergeSeries ?? global.mergeSeries,
            fullScrape: film?.fullScrape ?? task?.fullScrape ?? global.fullScrape,
            imageQuality: film?.imageQuality ?? task?.imageQuality ?? global.imageQuality,
            naming: filmNaming ?? taskNaming ?? baseNaming,
            writeNfo: film?.writeNfo ?? task?.writeNfo ?? baseMedia.nfo,
            downloadPoster: film?.downloadPoster ?? task?.downloadPoster ?? baseMedia.poster,
            downloadFanart: film?.downloadFanart ?? task?.downloadFanart ?? baseMedia.fanart,
            downloadClearlogo: film?.downloadClearlogo ?? task?.downloadClearlogo ?? baseMedia.logo,
            downloadEpisodeThumb: film?.downloadEpisodeThumb ?? task?.downloadEpisodeThumb ?? global.episodeThumb,
            seasonPoster: film?.seasonPoster ?? task?.seasonPoster ?? global.seasonPoster,
            episodeNfo: film?.episodeNfo ?? task?.episodeNfo ?? global.episodeNfo,
            sourceLayer: sourceLayer
        )
    }

    /// 当用户在预览页修改「任务策略」或单部「影片策略」后，按三级优先级即时重算计划中对应分组的文件名与开关状态。
    public static func applyOverrides(to plan: ScrapePlan, global: DefaultPolicies) -> ScrapePlan {
        var out = plan
        for gIdx in out.groups.indices {
            let group = out.groups[gIdx]
            guard group.kind == "movie" || group.kind == "tv" || group.kind == "collection" else { continue }
            let isTv = group.kind == "tv"
            let isCollection = group.kind == "collection"
            let eff = resolve(isTv: isTv, global: global, task: out.taskPolicy, film: group.policyOverride)
            let fileOpts = eff.naming.fileOptions()

            let targetFolder: String = {
                if isCollection {
                    let cid = group.collectionId ?? group.tmdbId ?? 0
                    return cid > 0
                        ? MediaParser.buildCollectionName(name: group.title, collectionId: cid, appendTag: eff.naming.folderTmdbEnabled)
                        : group.title
                }
                return StandardNaming.folderName(title: group.title, year: group.year, tmdbId: group.tmdbId, prefs: eff.naming)
            }()
            out.groups[gIdx].folderNewName = (eff.organizeEnabled && eff.renameFolders && targetFolder != group.folderName) ? targetFolder : nil

            let hasCollectionMkdir = isCollection && out.actions.contains(where: {
                $0.groupId == group.id && $0.op == "mkdir" && $0.mediaKind == "collection"
            })
            var disabledMkdirIds: [String] = []
            for aIdx in out.actions.indices where out.actions[aIdx].groupId == group.id && !out.actions[aIdx].done {
                let act = out.actions[aIdx]
                if isCollection && hasCollectionMkdir && act.op == "mkdir" && act.mediaKind == "collection" {
                    out.actions[aIdx].newName = targetFolder
                    let enableFolder = eff.organizeEnabled && eff.renameFolders
                    out.actions[aIdx].enabled = enableFolder
                    out.actions[aIdx].selected = enableFolder
                    if !enableFolder { disabledMkdirIds.append(act.id) }
                } else if act.op == "rename" && act.kind == "folder" {
                    if act.fileId == group.folderId && act.season == nil && (!isCollection || !hasCollectionMkdir) {
                        out.actions[aIdx].newName = targetFolder
                    }
                    let enableFolder = eff.organizeEnabled && eff.renameFolders
                    out.actions[aIdx].enabled = enableFolder
                    out.actions[aIdx].selected = enableFolder
                } else if act.op == "rename" && act.kind == "file" {
                    if !isCollection {
                        let (oldStem, ext) = MediaParser.splitNameExt(act.oldName)
                        let recomputed: String
                        if isTv {
                            let pm = MediaParser.parse(act.oldName, folderHint: group.folderName)
                            recomputed = StandardNaming.episodeFileBase(
                                title: group.title,
                                season: act.season ?? pm.season ?? 1,
                                episode: act.episode ?? pm.episode ?? 1,
                                episodeEnd: pm.episodeEnd,
                                tmdbId: group.tmdbId,
                                fileStem: oldStem,
                                releaseDirName: group.folderName,
                                options: fileOpts,
                                year: group.year
                            ) + ext
                        } else {
                            recomputed = StandardNaming.movieFileBase(
                                title: group.title,
                                year: group.year,
                                tmdbId: group.tmdbId,
                                fileStem: oldStem,
                                releaseDirName: group.folderName,
                                options: fileOpts
                            ) + ext
                        }
                        out.actions[aIdx].newName = recomputed
                    }
                    let enableFile = eff.organizeEnabled && eff.renameFiles
                    out.actions[aIdx].enabled = enableFile
                    out.actions[aIdx].selected = enableFile
                } else if act.op == "artwork" {
                    let enableArt: Bool
                    switch act.kind {
                    case "movie_nfo", "tvshow_nfo":
                        enableArt = eff.scrapeEnabled && eff.writeNfo
                    case "episode_nfo":
                        enableArt = eff.scrapeEnabled && eff.episodeNfo
                    case "clearlogo":
                        enableArt = eff.scrapeEnabled && eff.downloadClearlogo
                    case "image":
                        let low = act.newName.lowercased()
                        if low.hasPrefix("fanart") || low.hasPrefix("backdrop") {
                            enableArt = eff.scrapeEnabled && eff.downloadFanart
                        } else if act.episode != nil {
                            enableArt = eff.scrapeEnabled && eff.downloadEpisodeThumb
                        } else if low.contains("season") && low.contains("poster") {
                            enableArt = eff.scrapeEnabled && eff.seasonPoster
                        } else {
                            enableArt = eff.scrapeEnabled && eff.downloadPoster
                        }
                    default:
                        enableArt = eff.scrapeEnabled
                    }
                    out.actions[aIdx].enabled = enableArt
                    out.actions[aIdx].selected = enableArt
                }
            }
            if !disabledMkdirIds.isEmpty {
                out = PlanSelection.setEnabled(plan: out, ids: disabledMkdirIds, enabled: false)
            }
        }
        return out
    }
}

public struct NfoFieldSelection: Codable, Hashable, Sendable {
    public var title: Bool = true
    public var originalTitle: Bool = true
    public var year: Bool = true
    public var rating: Bool = true
    public var plot: Bool = true
    public var aired: Bool = true
    public var tmdbId: Bool = true
    public var season: Bool = true
    public var episode: Bool = true

    public init() {}
}

public enum NfoFields {
    /// 根据用户勾选的 NFO 字段精细过滤 XML 标签（对标 Android NfoFields.filter）。
    public static func filter(xml: String, selection: NfoFieldSelection) -> String {
        var out = xml
        let rules: [(Bool, String)] = [
            (selection.title, "title"),
            (selection.originalTitle, "originaltitle"),
            (selection.year, "year"),
            (selection.rating, "rating"),
            (selection.plot, "plot"),
            (selection.aired, "aired"),
            (selection.aired, "premiered"),
            (selection.tmdbId, "tmdbid"),
            (selection.season, "season"),
            (selection.episode, "episode"),
        ]
        for (keep, tag) in rules where !keep {
            if let rx = try? NSRegularExpression(pattern: #"\s*<\#(tag)>[\s\S]*?</\#(tag)>"#) {
                let r = NSRange(out.startIndex..<out.endIndex, in: out)
                out = rx.stringByReplacingMatches(in: out, range: r, withTemplate: "")
            }
        }
        return out
    }
}
