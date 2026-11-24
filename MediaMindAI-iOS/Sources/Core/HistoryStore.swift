import Foundation
import Observation

/// 1:1 复刻自 Android `HistoryStore.kt`：单条已执行操作记录（仅存名称与 ID，不存海报/NFO 字节）。
public struct HistoryItem: Codable, Hashable, Sendable {
    public let op: String
    public let folder: String
    public let from: String
    public let to: String
    public let tmdbId: Int?
    public let at: Int64

    public init(op: String, folder: String = "", from: String = "", to: String = "", tmdbId: Int? = nil, at: Int64 = 0) {
        self.op = op
        self.folder = folder
        self.from = from
        self.to = to
        self.tmdbId = tmdbId
        self.at = at
    }
}

/// 1:1 复刻自 Android `HistoryGroup`：已整理作品文件夹记忆（下次扫描直接复用 TMDB ID，已整理视频全部命中则跳过）。
public struct HistoryGroup: Codable, Hashable, Sendable {
    public let folderId: String
    public let folderName: String
    public let kind: String
    public let tmdbId: Int
    public let title: String
    public let year: String
    public let files: [String]
    public let posterPath: String?

    public init(
        folderId: String,
        folderName: String,
        kind: String,
        tmdbId: Int,
        title: String,
        year: String = "",
        files: [String] = [],
        posterPath: String? = nil
    ) {
        self.folderId = folderId
        self.folderName = folderName
        self.kind = kind
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.files = files
        self.posterPath = posterPath
    }
}

/// 1:1 复刻自 Android `HistoryRecord`：一次完整整理任务的历史快照。
public struct HistoryRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let at: Int64
    public let accountId: String
    public let provider: String
    public let dir: String
    public let title: String
    public let items: [HistoryItem]
    public let groups: [HistoryGroup]

    public init(
        id: String = String(UUID().uuidString.prefix(8)).lowercased(),
        at: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        accountId: String,
        provider: String,
        dir: String = "",
        title: String = "",
        items: [HistoryItem] = [],
        groups: [HistoryGroup] = []
    ) {
        self.id = id
        self.at = at
        self.accountId = accountId
        self.provider = provider
        self.dir = dir
        self.title = title
        self.items = items
        self.groups = groups
    }
}

/// 兼容轻量目录历史记录（供 UI 列表与历史扫描快速检索使用）。
public struct OrganizedRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let accountId: String
    public let provider: String
    public let folderId: String
    public let folderName: String
    public let matchedTitle: String
    public let actionCount: Int
    public let organizedAt: Date

    public init(
        id: String = String(UUID().uuidString.prefix(10).lowercased()),
        accountId: String,
        provider: String,
        folderId: String,
        folderName: String,
        matchedTitle: String,
        actionCount: Int,
        organizedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.provider = provider
        self.folderId = folderId
        self.folderName = folderName
        self.matchedTitle = matchedTitle
        self.actionCount = actionCount
        self.organizedAt = organizedAt
    }
}

private struct HistoryStoreEnvelope: Codable {
    var enabled: Bool = true
    var records: [OrganizedRecord] = []
    var runs: [HistoryRecord] = []
}

/// 独立化历史记忆仓库（1:1 对标 Android `HistoryStore.kt`，原子写盘、上限 300 条任务记录、支持开关与跨次合并 `remembered`）。
@MainActor
@Observable
public final class HistoryStore {
    public static let shared = HistoryStore()
    private static let maxRuns = 300
    private static let maxRecords = 1000

    public private(set) var enabled: Bool = true
    public private(set) var records: [OrganizedRecord] = []
    public private(set) var runs: [HistoryRecord] = []
    private let fileUrl: URL

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.fileUrl = storageURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let folder = dir.appendingPathComponent("MediaMindAI/history", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileUrl = folder.appendingPathComponent("history.json")
        }
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard let d = try? Data(contentsOf: fileUrl) else { return }
        if let env = try? JSONDecoder().decode(HistoryStoreEnvelope.self, from: d) {
            self.enabled = env.enabled
            self.records = env.records
            self.runs = env.runs.sorted { $0.at > $1.at }
        } else if let legacy = try? JSONDecoder().decode([OrganizedRecord].self, from: d) {
            self.enabled = true
            self.records = legacy
            self.runs = []
        }
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        persist()
    }

    public func record(accountId: String, provider: String, folderId: String, folderName: String, matchedTitle: String, actionCount: Int) {
        guard enabled else { return }
        records.removeAll { $0.accountId == accountId && $0.folderId == folderId }
        records.insert(
            OrganizedRecord(
                accountId: accountId,
                provider: provider,
                folderId: folderId,
                folderName: folderName,
                matchedTitle: matchedTitle,
                actionCount: actionCount
            ),
            at: 0
        )
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        persist()
    }

    public func addRun(_ run: HistoryRecord) {
        runs.insert(run, at: 0)
        runs = Array(runs.sorted { $0.at > $1.at }.prefix(Self.maxRuns))
        persist()
    }

    /// 1:1 复刻 Android `HistoryStore.remembered`：查询文件夹是否已整理过（关闭历史记忆时恒返回 nil；同一文件夹多次执行自动合并已整理文件列表）。
    public func remembered(accountId: String, pathIds: Bool, folderId: String, folderName: String) -> HistoryGroup? {
        guard enabled else { return nil }
        for r in runs where r.accountId == accountId {
            guard let g = r.groups.first(where: { $0.folderId == folderId && $0.folderName == folderName }) else {
                continue
            }
            var seen = Set<String>()
            var mergedFiles: [String] = []
            var poster: String? = g.posterPath
            for rr in runs where rr.accountId == accountId {
                for gg in rr.groups where gg.folderId == folderId && gg.folderName == folderName && gg.tmdbId == g.tmdbId {
                    for f in gg.files where seen.insert(f).inserted {
                        mergedFiles.append(f)
                    }
                    if poster == nil, let p = gg.posterPath, !p.isEmpty {
                        poster = p
                    }
                }
            }
            return HistoryGroup(
                folderId: g.folderId,
                folderName: g.folderName,
                kind: g.kind,
                tmdbId: g.tmdbId,
                title: g.title,
                year: g.year,
                files: mergedFiles,
                posterPath: poster
            )
        }
        return nil
    }

    /// 1:1 复刻 Android `HistoryStore.recordRun`：由执行引擎在任务结束时调用，仅记录本次成功执行的动作与作品组。
    @discardableResult
    public func recordRun(
        plan: ScrapePlan,
        actions: [String: PlanAction],
        okIds: [String],
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        idRemap: [String: String] = [:],
        pathIds: Bool = false
    ) -> HistoryRecord? {
        guard enabled, !okIds.isEmpty else { return nil }
        let okSet = Set(okIds)
        let okActions = okIds.compactMap { actions[$0] }
        let groupsById = Dictionary(plan.groups.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        let items = okActions.map { a -> HistoryItem in
            let g = groupsById[a.groupId]
            let folder = (g?.folderNewName?.isEmpty == false ? g?.folderNewName : g?.folderName) ?? ""
            let to = a.op == "move" ? (a.destLabel ?? a.newName) : a.newName
            return HistoryItem(op: a.op, folder: folder, from: a.oldName, to: to, tmdbId: a.tmdbId ?? g?.tmdbId, at: nowMs)
        }

        let remap = IdRemap(initial: idRemap, pathMode: pathIds)
        let touched = Set(okActions.map(\.groupId))
        var historyGroups: [HistoryGroup] = []
        for gid in touched {
            guard let g = groupsById[gid],
                  let fid = g.folderId, !fid.isEmpty,
                  let tid = g.tmdbId,
                  (g.kind == "tv" || g.kind == "movie") else { continue }
            let acts = actions.values.filter { $0.groupId == gid }
            let renamed = acts.first { $0.op == "rename" && $0.kind == "folder" && $0.fileId == fid }
            let finalName: String
            if let r = renamed, (r.done || okSet.contains(r.id)) {
                finalName = r.newName
            } else {
                finalName = g.folderName
            }
            let videos = acts.filter {
                ($0.op == "rename" || $0.op == "skip") && $0.kind == "file" && $0.tmdbId == tid && ($0.op == "skip" || $0.done || okSet.contains($0.id))
            }.map { $0.newName.isEmpty ? $0.oldName : $0.newName }
            let resolvedFid = remap.resolveOrSelf(fid)
            historyGroups.append(HistoryGroup(
                folderId: resolvedFid,
                folderName: finalName,
                kind: g.kind,
                tmdbId: tid,
                title: g.title,
                year: g.year,
                files: videos,
                posterPath: g.posterPath
            ))
        }

        let distinctTitles = Array(Set(plan.groups.filter { touched.contains($0.id) && !$0.title.isEmpty }.map(\.title))).sorted()
        let summaryTitle: String
        switch distinctTitles.count {
        case 0: summaryTitle = "执行了 \(okActions.count) 项"
        case 1: summaryTitle = distinctTitles[0]
        default: summaryTitle = "\(distinctTitles[0]) 等 \(distinctTitles.count) 部"
        }

        let rec = HistoryRecord(
            at: nowMs,
            accountId: plan.accountId,
            provider: plan.provider,
            dir: plan.roots.map(\.name).joined(separator: "、"),
            title: summaryTitle,
            items: items,
            groups: historyGroups
        )
        addRun(rec)
        return rec
    }

    public func remove(id: String) {
        records.removeAll { $0.id == id }
        runs.removeAll { $0.id == id }
        persist()
    }

    public func deleteRun(id: String) {
        runs.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        records.removeAll()
        runs.removeAll()
        persist()
    }

    private func persist() {
        let env = HistoryStoreEnvelope(enabled: enabled, records: records, runs: runs)
        if let d = try? JSONEncoder().encode(env), let text = String(data: d, encoding: .utf8) {
            try? FileManager.default.createDirectory(at: fileUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? AtomicFileIO.writeText(text, to: fileUrl)
        }
    }
}
