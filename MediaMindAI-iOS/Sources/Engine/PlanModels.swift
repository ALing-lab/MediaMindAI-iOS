import Foundation
import Observation

public struct PlanRoot: Codable, Hashable, Sendable {
    public let folderId: String
    public let name: String
    public let parentId: String?

    public init(folderId: String, name: String, parentId: String? = nil) {
        self.folderId = folderId
        self.name = name
        self.parentId = parentId
    }
}

public struct PlanStats: Codable, Hashable, Sendable {
    public let totalGroups: Int
    public let matchedGroups: Int
    public let unmatchedGroups: Int
    public let confirmGroups: Int
    public let totalActions: Int
    public let selectedActions: Int
    public let doneActions: Int

    public init(totalGroups: Int = 0, matchedGroups: Int = 0, unmatchedGroups: Int = 0, confirmGroups: Int = 0, totalActions: Int = 0, selectedActions: Int = 0, doneActions: Int = 0) {
        self.totalGroups = totalGroups
        self.matchedGroups = matchedGroups
        self.unmatchedGroups = unmatchedGroups
        self.confirmGroups = confirmGroups
        self.totalActions = totalActions
        self.selectedActions = selectedActions
        self.doneActions = doneActions
    }

    public static func compute(groups: [PlanGroup], actions: [PlanAction]) -> PlanStats {
        let matched = groups.filter { $0.kind != "unmatched" }.count
        let unmatched = groups.filter { $0.kind == "unmatched" }.count
        let confirm = groups.filter { $0.confirmRequired }.count
        let selected = actions.filter { $0.selected && $0.enabled && $0.blocked == nil && !$0.done }.count
        let done = actions.filter { $0.done }.count
        return PlanStats(
            totalGroups: groups.count,
            matchedGroups: matched,
            unmatchedGroups: unmatched,
            confirmGroups: confirm,
            totalActions: actions.count,
            selectedActions: selected,
            doneActions: done
        )
    }
}

public struct PlanGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var kind: String // "movie" | "tv" | "collection" | "unmatched"
    public var tmdbId: Int?
    public var collectionId: Int?
    public var collectionName: String?
    public var title: String
    public var year: String
    public var posterPath: String?
    public var folderId: String?
    public var folderName: String
    public var folderNewName: String?
    public var rating: Double?
    public var confidence: String?
    public var note: String?
    public var warn: String?
    public var actionIds: [String]
    public var policyOverride: PolicyOverride?
    public var sourceRootId: String?
    public var confirmRequired: Bool
    public var confirmReasons: [String]
    public var episodeStrategy: String
    public var episodeGroupId: String?
    public var episodeGroupName: String?
    public var folderPath: String?
    public var genreIds: [Int]
    public var originalTitle: String?
    public var originalLanguage: String?

    public init(
        id: String,
        kind: String,
        tmdbId: Int?,
        collectionId: Int? = nil,
        collectionName: String? = nil,
        title: String,
        year: String,
        posterPath: String?,
        folderId: String?,
        folderName: String,
        folderNewName: String?,
        rating: Double?,
        confidence: String?,
        note: String?,
        warn: String?,
        actionIds: [String],
        policyOverride: PolicyOverride? = nil,
        sourceRootId: String? = nil,
        confirmRequired: Bool = false,
        confirmReasons: [String] = [],
        episodeStrategy: String = "original",
        episodeGroupId: String? = nil,
        episodeGroupName: String? = nil,
        folderPath: String? = nil,
        genreIds: [Int] = [],
        originalTitle: String? = nil,
        originalLanguage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.tmdbId = tmdbId
        self.collectionId = collectionId
        self.collectionName = collectionName
        self.title = title
        self.year = year
        self.posterPath = posterPath
        self.folderId = folderId
        self.folderName = folderName
        self.folderNewName = folderNewName
        self.rating = rating
        self.confidence = confidence
        self.note = note
        self.warn = warn
        self.actionIds = actionIds
        self.policyOverride = policyOverride
        self.sourceRootId = sourceRootId
        self.confirmRequired = confirmRequired
        self.confirmReasons = confirmReasons
        self.episodeStrategy = episodeStrategy
        self.episodeGroupId = episodeGroupId
        self.episodeGroupName = episodeGroupName
        self.folderPath = folderPath
        self.genreIds = genreIds
        self.originalTitle = originalTitle
        self.originalLanguage = originalLanguage
    }
    private enum CodingKeys: String, CodingKey {
        case id, kind, tmdbId, collectionId, collectionName, title, year, posterPath
        case folderId, folderName, folderNewName, rating, confidence, note, warn, actionIds
        case policyOverride, sourceRootId, confirmRequired, confirmReasons
        case episodeStrategy, episodeGroupId, episodeGroupName, folderPath, genreIds, originalTitle, originalLanguage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId)
        self.collectionId = try c.decodeIfPresent(Int.self, forKey: .collectionId)
        self.collectionName = try c.decodeIfPresent(String.self, forKey: .collectionName)
        self.title = try c.decode(String.self, forKey: .title)
        self.year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
        self.posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        self.folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        self.folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        self.folderNewName = try c.decodeIfPresent(String.self, forKey: .folderNewName)
        self.rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        self.confidence = try c.decodeIfPresent(String.self, forKey: .confidence)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
        self.warn = try c.decodeIfPresent(String.self, forKey: .warn)
        self.actionIds = try c.decodeIfPresent([String].self, forKey: .actionIds) ?? []
        self.policyOverride = try c.decodeIfPresent(PolicyOverride.self, forKey: .policyOverride)
        self.sourceRootId = try c.decodeIfPresent(String.self, forKey: .sourceRootId)
        self.confirmRequired = try c.decodeIfPresent(Bool.self, forKey: .confirmRequired) ?? false
        self.confirmReasons = try c.decodeIfPresent([String].self, forKey: .confirmReasons) ?? []
        self.episodeStrategy = try c.decodeIfPresent(String.self, forKey: .episodeStrategy) ?? "original"
        self.episodeGroupId = try c.decodeIfPresent(String.self, forKey: .episodeGroupId)
        self.episodeGroupName = try c.decodeIfPresent(String.self, forKey: .episodeGroupName)
        self.folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        self.genreIds = try c.decodeIfPresent([Int].self, forKey: .genreIds) ?? []
        self.originalTitle = try c.decodeIfPresent(String.self, forKey: .originalTitle)
        self.originalLanguage = try c.decodeIfPresent(String.self, forKey: .originalLanguage)
    }

}

public struct PlanAction: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let op: String // "mkdir" | "rename" | "move" | "artwork" | "trash" | "delete" | "skip" | "unmatched"
    public let groupId: String
    public let fileId: String?
    public let parentId: String?
    public let oldName: String
    public var newName: String
    public var destParentId: String?
    public var destRef: String?
    public var destLabel: String?
    public let kind: String // "file" | "folder" | "subtitle" | "image" | "clearlogo" | "movie_nfo" | "tvshow_nfo" | "season_nfo" | "episode_nfo" | "cleanup" | ...
    public let mediaKind: String?
    public let tmdbId: Int?
    public let season: Int?
    public let episode: Int?
    public let artworkUrl: String?
    public var selected: Bool
    public var enabled: Bool
    public var blocked: String?
    public var done: Bool
    public var error: String?
    public var note: String?
    public let metadataSeason: Int?
    public let metadataEpisode: Int?
    public let replaceExisting: Bool
    public var folderPath: String?

    public init(
        id: String,
        op: String,
        groupId: String,
        fileId: String?,
        parentId: String?,
        oldName: String,
        newName: String,
        destParentId: String?,
        destRef: String?,
        destLabel: String? = nil,
        kind: String,
        mediaKind: String?,
        tmdbId: Int?,
        season: Int?,
        episode: Int?,
        artworkUrl: String?,
        selected: Bool,
        enabled: Bool = true,
        blocked: String? = nil,
        done: Bool,
        error: String?,
        note: String?,
        metadataSeason: Int? = nil,
        metadataEpisode: Int? = nil,
        replaceExisting: Bool = false,
        folderPath: String? = nil
    ) {
        self.id = id
        self.op = op
        self.groupId = groupId
        self.fileId = fileId
        self.parentId = parentId
        self.oldName = oldName
        self.newName = newName
        self.destParentId = destParentId
        self.destRef = destRef
        self.destLabel = destLabel
        self.kind = kind
        self.mediaKind = mediaKind
        self.tmdbId = tmdbId
        self.season = season
        self.episode = episode
        self.artworkUrl = artworkUrl
        self.selected = selected
        self.enabled = enabled
        self.blocked = blocked
        self.done = done
        self.error = error
        self.note = note
        self.metadataSeason = metadataSeason
        self.metadataEpisode = metadataEpisode
        self.replaceExisting = replaceExisting
        self.folderPath = folderPath
    }
    private enum CodingKeys: String, CodingKey {
        case id, op, groupId, fileId, parentId, oldName, newName, destParentId, destRef, destLabel
        case kind, mediaKind, tmdbId, season, episode, artworkUrl, selected, enabled, blocked, done, error, note
        case metadataSeason, metadataEpisode, replaceExisting, folderPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.op = try c.decode(String.self, forKey: .op)
        self.groupId = try c.decode(String.self, forKey: .groupId)
        self.fileId = try c.decodeIfPresent(String.self, forKey: .fileId)
        self.parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        self.oldName = try c.decodeIfPresent(String.self, forKey: .oldName) ?? ""
        self.newName = try c.decodeIfPresent(String.self, forKey: .newName) ?? ""
        self.destParentId = try c.decodeIfPresent(String.self, forKey: .destParentId)
        self.destRef = try c.decodeIfPresent(String.self, forKey: .destRef)
        self.destLabel = try c.decodeIfPresent(String.self, forKey: .destLabel)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "file"
        self.mediaKind = try c.decodeIfPresent(String.self, forKey: .mediaKind)
        self.tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId)
        self.season = try c.decodeIfPresent(Int.self, forKey: .season)
        self.episode = try c.decodeIfPresent(Int.self, forKey: .episode)
        self.artworkUrl = try c.decodeIfPresent(String.self, forKey: .artworkUrl)
        self.selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? true
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.blocked = try c.decodeIfPresent(String.self, forKey: .blocked)
        self.done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
        self.metadataSeason = try c.decodeIfPresent(Int.self, forKey: .metadataSeason)
        self.metadataEpisode = try c.decodeIfPresent(Int.self, forKey: .metadataEpisode)
        self.replaceExisting = try c.decodeIfPresent(Bool.self, forKey: .replaceExisting) ?? false
        self.folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
    }

}

public struct ScrapePlan: Identifiable, Codable, Sendable {
    public let id: String
    public let accountId: String
    public let provider: String
    public let createdAt: Date
    public let roots: [PlanRoot]
    public var groups: [PlanGroup]
    public var actions: [PlanAction]
    public var flags: [String]
    public var taskPolicy: PolicyOverride?
    /// nil 为旧版计划；新扫描明确记为 pending，执行/取消后分别为 started/cancelled。
    public var reviewDisposition: String? = nil
    /// 完整只读扫描的目录快照；旧版本缺少快照时不可静默继承人工设置。
    public var scanListings: [String: [CloudEntry]]? = nil
    public var scanParents: [String: String]? = nil
    public var scanBinding: String? = nil
    public var submittedActionIds: [String]? = nil
    public var executionRunIds: [String]? = nil
    public var scanPriorRunIds: [String]? = nil

    /// 历史范围仍保留在计划中供依赖与日志使用，不能作为新的手动识别目标。
    public var submittedSourceIds: Set<String> {
        let submitted = Set(submittedActionIds ?? [])
        return Set(actions.filter { submitted.contains($0.id) }.compactMap(\.fileId))
    }

    public func manualMatchActions(groupId: String) -> [PlanAction] {
        let submitted = Set(submittedActionIds ?? [])
        let sources = submittedSourceIds
        var seen = Set<String>()
        return actions.filter { action in
            guard action.groupId == groupId, !action.done,
                  action.kind == "file" || action.op == "unmatched",
                  !submitted.contains(action.id),
                  action.fileId.map({ !sources.contains($0) }) ?? true else { return false }
            return seen.insert(action.fileId ?? action.id).inserted
        }
    }

    public var uniqueMediaCount: Int {
        var keys = Set<String>()
        for group in groups {
            if group.kind == "collection" {
                let members = actions.filter { $0.groupId == group.id && $0.kind == "file" && $0.tmdbId != nil }
                if !members.isEmpty {
                    for member in members { keys.insert("movie-\(member.tmdbId!)") }
                    continue
                }
            }
            keys.insert(group.tmdbId.map { "\(group.kind)-\($0)" } ?? "folder-\(group.folderId ?? group.id)")
        }
        return keys.count
    }

    /// 固定当次执行范围；后续重新识别或勾选不会改变历史记录。
    public func executionSnapshot(actionIds: [String]) -> ScrapePlan {
        let ids = Set(actionIds)
        var copy = self
        copy.actions = actions.filter { ids.contains($0.id) }.map {
            var action = $0
            action.selected = true
            return action
        }
        let groupIds = Set(copy.actions.map(\.groupId))
        copy.groups = groups.filter { groupIds.contains($0.id) }.map {
            var group = $0
            group.actionIds = group.actionIds.filter { ids.contains($0) }
            return group
        }
        return copy
    }

    public init(
        id: String,
        accountId: String,
        provider: String,
        createdAt: Date,
        roots: [PlanRoot],
        groups: [PlanGroup],
        actions: [PlanAction],
        flags: [String],
        taskPolicy: PolicyOverride? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.provider = provider
        self.createdAt = createdAt
        self.roots = roots
        self.groups = groups
        self.actions = actions
        self.flags = flags
        self.taskPolicy = taskPolicy
    }
}

public struct TaskRun: Identifiable, Codable, Sendable {
    public let id: String
    public let planId: String
    public let accountId: String
    public let provider: String
    public let sourceLabel: String
    public var status: String // "running" | "paused" | "done" | "failed" | "stopped"
    public var total: Int
    public var completed: Int
    public var succeeded: Int
    public var failed: Int
    public var message: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var errors: [String]
    public var executionSnapshot: ScrapePlan? = nil

    public var isSuccessful: Bool {
        status == "done" && total > 0 && completed == total && succeeded > 0 && failed == 0
    }

    public var hasNoEffectiveOperations: Bool {
        (status == "done" || status == "no_changes") && failed == 0 && succeeded == 0
    }

    public init(id: String, planId: String, accountId: String, provider: String, sourceLabel: String, status: String, total: Int, completed: Int, succeeded: Int, failed: Int, message: String, startedAt: Date, finishedAt: Date?, errors: [String]) {
        self.id = id
        self.planId = planId
        self.accountId = accountId
        self.provider = provider
        self.sourceLabel = sourceLabel
        self.status = status
        self.total = total
        self.completed = completed
        self.succeeded = succeeded
        self.failed = failed
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errors = errors
    }
}

/// 本地计划、任务与已整理目录历史持久化存储（主线程隔离，避免 SwiftUI 并发数据竞争）。
@MainActor
@Observable
public final class PlanAndTaskStore {
    public static let shared = PlanAndTaskStore()

    public private(set) var plans: [ScrapePlan] = []
    public private(set) var tasks: [TaskRun] = []
    public private(set) var organizedFolderKeys: Set<String> = []

    private let baseDir: URL

    init(storageURL: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.baseDir = storageURL ?? appSupport.appendingPathComponent("MediaMindAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        load()
    }

    private var plansFile: URL { baseDir.appendingPathComponent("plans.json") }
    private var tasksFile: URL { baseDir.appendingPathComponent("tasks.json") }
    private var historyFile: URL { baseDir.appendingPathComponent("organized_history.json") }

    public func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: plansFile), let list = try? dec.decode([ScrapePlan].self, from: d) {
            plans = list
        }
        if let d = try? Data(contentsOf: tasksFile), let list = try? dec.decode([TaskRun].self, from: d) {
            tasks = list
        }
        if let d = try? Data(contentsOf: historyFile), let list = try? dec.decode([String].self, from: d) {
            organizedFolderKeys = Set(list)
        }
    }

    public func savePlan(_ plan: ScrapePlan) {
        var plan = plan
        if let previous = plans.first(where: { $0.id == plan.id }) {
            let visible = Set(plan.groups.map(\.id))
            let stillReferenced = Set(plan.actions.map(\.groupId))
            plan.groups += previous.groups.filter { !visible.contains($0.id) && stillReferenced.contains($0.id) }
        }
        if let idx = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[idx] = plan
        } else {
            plans.insert(plan, at: 0)
        }

        if let d = try? JSONEncoder().encode(plans) { try? d.write(to: plansFile, options: .atomic) }
    }

    public func deletePlan(id: String) {
        plans.removeAll { $0.id == id }
        if let d = try? JSONEncoder().encode(plans) { try? d.write(to: plansFile, options: .atomic) }
    }

    public func reservedActionIds(planId: String) -> Set<String> {
        Set(tasks.filter { $0.planId == planId }.flatMap { $0.executionSnapshot?.actions.map(\.id) ?? [] })
            .union(plans.first(where: { $0.id == planId })?.submittedActionIds ?? [])
    }

    private func remainingGroupIds(in plan: ScrapePlan, reserved: Set<String>) -> Set<String> {
        let submittedActions = plan.actions.filter { reserved.contains($0.id) }
        let submittedGroups = Set(submittedActions.map(\.groupId))
        let submittedSources = Set(submittedActions.compactMap(\.fileId))
        let pending = Set(plan.actions.filter { action in
            guard !action.done && !reserved.contains(action.id) else { return false }
            let untouchedSource = action.fileId.map { !submittedSources.contains($0) } ?? false
            if action.op == "unmatched" { return action.fileId == nil || untouchedSource }
            // 尚未提交的作品允许调整策略；已提交作品的禁用残留不能生成空卡片。
            return ExecutionEngine.execOps.contains(action.op)
                && (action.enabled || !submittedGroups.contains(action.groupId) || (action.kind == "file" && untouchedSource))
        }.map(\.groupId))
        return Set(plan.groups.filter { pending.contains($0.id) || $0.kind == "unmatched" }.map(\.id))
    }

    public func pendingProjection(_ plan: ScrapePlan) -> ScrapePlan {
        var copy = plan
        let reserved = reservedActionIds(planId: plan.id)
        copy.submittedActionIds = reserved.sorted()
        let pending = remainingGroupIds(in: plan, reserved: reserved)
        copy.groups = plan.groups.filter { pending.contains($0.id) }
        for index in copy.actions.indices where reserved.contains(copy.actions[index].id) { copy.actions[index].selected = false }
        return copy
    }

    public func saveEditedPlan(_ edited: ScrapePlan, original: ScrapePlan) throws {
        guard let current = plans.first(where: { $0.id == original.id }),
              pendingPlans.contains(where: { $0.id == original.id }) else { throw DriveError.invalidInput("计划已被合并或开始执行，请重新打开预览") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(pendingProjection(current)) == encoder.encode(original) else { throw DriveError.invalidInput("计划已更新，本次旧识别结果未覆盖新计划，请重新打开预览") }
        guard !reintroducesSubmittedSource(edited, current: current) else { throw DriveError.invalidInput("识别结果包含已提交的源文件，请从历史任务重试该文件，或重新打开预览识别剩余文件") }
        savePendingPlan(edited)
    }

    private func reintroducesSubmittedSource(_ edited: ScrapePlan, current: ScrapePlan) -> Bool {
        let reserved = reservedActionIds(planId: current.id)
        let sources = Set(current.actions.filter { reserved.contains($0.id) }.compactMap(\.fileId))
        let existingIds = Set(current.actions.map(\.id))
        return edited.actions.contains { action in
            !existingIds.contains(action.id) && action.fileId.map { sources.contains($0) } == true
        }
    }

    public func savePendingPlan(_ edited: ScrapePlan) {
        guard let current = plans.first(where: { $0.id == edited.id }), pendingPlans.contains(where: { $0.id == edited.id }) else { return }
        guard !reintroducesSubmittedSource(edited, current: current) else { return }
        let reserved = reservedActionIds(planId: edited.id)
        var next = edited
        next.actions = edited.actions.filter { !reserved.contains($0.id) } + current.actions.filter { reserved.contains($0.id) }
        next.submittedActionIds = current.submittedActionIds
        next.executionRunIds = current.executionRunIds
        next.scanPriorRunIds = current.scanPriorRunIds
        next.scanListings = current.scanListings; next.scanParents = current.scanParents; next.scanBinding = current.scanBinding
        savePlan(next)
    }

    public var pendingPlans: [ScrapePlan] {
        plans.compactMap { plan in
            guard plan.reviewDisposition != "cancelled" && plan.reviewDisposition != "started" else { return nil }
            guard !tasks.contains(where: { $0.planId == plan.id && ($0.status == "running" || $0.status == "paused") }),
                  !TaskQueue.shared.items.contains(where: { $0.planId == plan.id }) else { return nil }
            if plan.reviewDisposition == nil && tasks.contains(where: { $0.planId == plan.id && !$0.hasNoEffectiveOperations }) { return nil }
            let projected = pendingProjection(plan)
            return projected.groups.isEmpty ? nil : projected
        }
    }

    public func markExecutionStarted(_ plan: ScrapePlan, requested: [String], runId: String) -> ScrapePlan {
        var copy = plan
        let reserved = reservedActionIds(planId: plan.id).union(requested)
        let remaining = !remainingGroupIds(in: plan, reserved: reserved).isEmpty
        copy.reviewDisposition = remaining ? "pending" : "started"
        copy.submittedActionIds = reserved.sorted()
        copy.executionRunIds = Array(Set(plan.executionRunIds ?? []).union([runId])).sorted()
        savePlan(copy)
        return copy
    }

    /// 持久化成功后才发布一次合并结果，失败时不丢失旧卡片。
    public func commitScan(_ plan: ScrapePlan, replacing ids: Set<String>) throws {
        guard !plans.contains(where: { ($0.id == plan.id || ids.contains($0.id)) && $0.accountId != plan.accountId }) else {
            throw DriveError.invalidInput("计划标识或替换范围与其他账号冲突，旧数据未更新")
        }
        var next = plans.filter { !ids.contains($0.id) && $0.id != plan.id }
        next.insert(plan, at: 0)
        try JSONEncoder().encode(next).write(to: plansFile, options: .atomic)
        plans = next
    }

    public func scanRevision(accountId: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(plans.filter { $0.accountId == accountId })
    }

    public func cancelPendingPlan(id: String) {
        guard var plan = pendingPlans.first(where: { $0.id == id }) else { return }
        plan.reviewDisposition = "cancelled"
        savePlan(plan)
    }

    public func saveTask(_ run: TaskRun) {
        if let idx = tasks.firstIndex(where: { $0.id == run.id }) {
            tasks[idx] = run
        } else {
            tasks.insert(run, at: 0)
        }
        if tasks.count > 50 { tasks = Array(tasks.prefix(50)) }
        if let d = try? JSONEncoder().encode(tasks) { try? d.write(to: tasksFile, options: .atomic) }
    }

    public func deleteTask(id: String, allowPaused: Bool = false) {
        guard let target = tasks.first(where: { $0.id == id }),
              target.status != "running",
              (allowPaused || target.status != "paused") else { return }
        tasks.removeAll { $0.id == id }
        if let d = try? JSONEncoder().encode(tasks) { try? d.write(to: tasksFile, options: .atomic) }
    }

    public func historyKey(accountId: String, folderId: String) -> String { "\(accountId)|\(folderId)" }

    public func isFolderOrganized(accountId: String, folderId: String) -> Bool {
        organizedFolderKeys.contains(historyKey(accountId: accountId, folderId: folderId))
    }

    public func markFoldersOrganized(accountId: String, folderIds: [String]) {
        guard !folderIds.isEmpty else { return }
        for fid in folderIds where !fid.isEmpty {
            organizedFolderKeys.insert(historyKey(accountId: accountId, folderId: fid))
        }
        if let d = try? JSONEncoder().encode(Array(organizedFolderKeys)) {
            try? d.write(to: historyFile, options: .atomic)
        }
    }

    public func clearOrganizedFolders() {
        organizedFolderKeys.removeAll()
        try? FileManager.default.removeItem(at: historyFile)
    }

    public func clearAllCache() {
        plans.removeAll()
        tasks.removeAll()
        organizedFolderKeys.removeAll()
        try? FileManager.default.removeItem(at: plansFile)
        try? FileManager.default.removeItem(at: tasksFile)
        try? FileManager.default.removeItem(at: historyFile)
    }
}

/// 失败项勾选依赖闭包计算器（1:1 复刻自 Android `TaskModels.kt` 的 `FailedRetry`）：
/// 勾选失败的 move/artwork 时自动连带勾选未完成的上游 mkdir；取消勾选 mkdir 时自动连带取消依赖它的下游项。
public enum FailedRetry {
    private static func deps(id: String, plan: ScrapePlan) -> [String] {
        guard let a = plan.actions.first(where: { $0.id == id }),
              let d = PlanSelection.dependencyOf(a, all: plan.actions),
              !d.done else {
            return []
        }
        return [d.id]
    }

    private static func dependents(id: String, plan: ScrapePlan) -> [String] {
        plan.actions
            .filter { PlanSelection.dependencyOf($0, all: plan.actions)?.id == id }
            .map(\.id)
    }

    public static func toggle(
        selected: Set<String>,
        ids: [String],
        on: Bool,
        failed: Set<String>,
        plan: ScrapePlan?
    ) -> Set<String> {
        var out = selected
        if on {
            for id in ids { out.insert(id) }
            if let plan {
                for id in ids {
                    for depId in deps(id: id, plan: plan) where failed.contains(depId) {
                        out.insert(depId)
                    }
                }
            }
        } else {
            for id in ids { out.remove(id) }
            if let plan {
                for id in ids {
                    for depId in dependents(id: id, plan: plan) {
                        out.remove(depId)
                    }
                }
            }
        }
        return out.intersection(failed)
    }

    /// 实际要执行的 actionId 列表：包含所选项及它们依赖的、尚未完成的前置新建文件夹（即使不在失败列表里）。
    public static func retryIds(selected: [String], plan: ScrapePlan?) -> [String] {
        guard let plan else { return selected }
        var seen = Set<String>()
        var ordered: [String] = []
        for id in selected {
            for depId in deps(id: id, plan: plan) {
                if seen.insert(depId).inserted { ordered.append(depId) }
            }
        }
        for id in selected {
            if seen.insert(id).inserted { ordered.append(id) }
        }
        return ordered
    }
}

public extension PlanAction {
    func withId(_ id: String) -> PlanAction {
        PlanAction(id: id, op: op, groupId: groupId, fileId: fileId, parentId: parentId, oldName: oldName,
            newName: newName, destParentId: destParentId, destRef: destRef, destLabel: destLabel, kind: kind,
            mediaKind: mediaKind, tmdbId: tmdbId, season: season, episode: episode, artworkUrl: artworkUrl,
            selected: selected, enabled: enabled, blocked: blocked, done: done, error: error, note: note,
            metadataSeason: metadataSeason, metadataEpisode: metadataEpisode, replaceExisting: replaceExisting, folderPath: folderPath)
    }
}
