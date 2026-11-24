import Foundation
import Observation

/// 1:1 逐行复刻自 Android `LibraryDestination.kt`（24 行）：为单部影视分组指定独立目标输出目录（不触碰远端云盘）。
public enum LibraryDestination {
    public static let kind = "library_folder_move"

    public static func set(plan: ScrapePlan, groupId: String, targetId: String, targetPath: String) throws -> ScrapePlan {
        guard let group = plan.groups.first(where: { $0.id == groupId }) else {
            throw DriveError.invalidInput("影片已不在当前计划中")
        }
        guard let folder = group.folderId, !folder.isEmpty else {
            throw DriveError.invalidInput("散文件请先按影视文件夹重新扫描")
        }
        guard !plan.actions.contains(where: { $0.groupId == groupId && $0.done }) else {
            throw DriveError.invalidInput("该影片已有完成的操作，请重新扫描")
        }
        let normPrefix = "/" + folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        guard folder != targetId && !(folder.hasPrefix("/") && targetId.hasPrefix(normPrefix)) else {
            throw DriveError.invalidInput("不能移入自身或子目录")
        }
        let oldMove = plan.actions.first(where: { $0.groupId == groupId && $0.kind == kind })
        let parent = oldMove?.parentId
            ?? plan.actions.first(where: { $0.groupId == groupId && $0.fileId == folder && $0.kind == "folder" && !($0.parentId ?? "").isEmpty })?.parentId
            ?? (folder.hasPrefix("/") && folder != "/" ? DrivePaths.parentOf(folder) : nil)
        guard let parent, !parent.isEmpty else {
            throw DriveError.invalidInput("缺少来源上级目录信息，请重新扫描")
        }
        let name = group.folderNewName ?? group.folderName
        let kept = plan.actions.filter { !($0.groupId == groupId && $0.kind == kind) }
        var actions = kept
        if parent != targetId {
            actions.append(PlanAction(
                id: oldMove?.id ?? "destination-\(UUID().uuidString.prefix(8).lowercased())",
                op: "move",
                groupId: groupId,
                fileId: folder,
                parentId: parent,
                oldName: name,
                newName: name,
                destParentId: targetId,
                destRef: nil,
                destLabel: targetPath,
                kind: kind,
                mediaKind: group.kind,
                tmdbId: group.tmdbId,
                season: nil,
                episode: nil,
                artworkUrl: nil,
                selected: true,
                done: false,
                error: nil,
                note: "影视文件夹移至 \(targetPath)"
            ))
        }
        var out = plan
        out.actions = actions
        for i in out.groups.indices where out.groups[i].id == groupId {
            out.groups[i].actionIds = actions.filter { $0.groupId == groupId }.map(\.id)
        }
        return out
    }
}

/// 1:1 逐行复刻自 Android `LibraryTargets.kt`（48 行）：跨账号待扫描目标目录持久化选择与包含重叠冲突检测。
public struct LibraryTarget: Identifiable, Codable, Hashable, Sendable {
    public let accountId: String
    public let folderId: String
    public let path: String
    public let parentId: String?
    public let ancestors: [String]

    public var id: String { "\(accountId)|\(folderId)" }

    public init(accountId: String, folderId: String, path: String, parentId: String? = nil, ancestors: [String] = []) {
        self.accountId = accountId
        self.folderId = folderId
        self.path = path
        self.parentId = parentId
        self.ancestors = ancestors
    }
}

@MainActor
@Observable
public final class LibraryTargets {
    public static let shared = LibraryTargets()
    public private(set) var items: [LibraryTarget] = []
    private let key = "library.targets.v1"

    public init(initial: [LibraryTarget]? = nil) {
        if let initial {
            self.items = initial
        } else if let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([LibraryTarget].self, from: data) {
            self.items = decoded
        }
    }

    public func toggle(_ target: LibraryTarget) {
        if items.contains(where: { $0.accountId == target.accountId && $0.folderId == target.folderId }) {
            items.removeAll { $0.accountId == target.accountId && $0.folderId == target.folderId }
        } else {
            items.append(target)
        }
        persist()
    }

    public func clear(accountId: String) {
        items.removeAll { $0.accountId == accountId }
        persist()
    }

    public func consume(plan: ScrapePlan) {
        let ids = Set(plan.roots.map(\.folderId))
        items.removeAll { $0.accountId == plan.accountId && ids.contains($0.folderId) }
        persist()
    }

    public nonisolated static func overlap(_ targets: [LibraryTarget]) -> Bool {
        for a in targets {
            let aPrefix = "/" + a.folderId.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            for b in targets where a != b && a.accountId == b.accountId {
                if b.ancestors.contains(a.folderId) { return true }
                if a.folderId.hasPrefix("/") && b.folderId.hasPrefix(aPrefix) { return true }
            }
        }
        return false
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// 1:1 逐行复刻自 Android `EpisodeAssets.kt`（40 行）：动态开关剧集单集 NFO 与单集剧照（保留已有 companion 侧车文件）。
public enum EpisodeAssets {
    private static func isSidecar(_ a: PlanAction) -> Bool {
        a.kind == "episode_nfo" || (a.kind == "image" && a.episode != nil && a.newName.hasSuffix("-thumb.jpg"))
    }

    public static func configure(plan: ScrapePlan, groupId: String, nfo: Bool, thumbnails: Bool, fullScrape: Bool = false) throws -> ScrapePlan {
        guard let group = plan.groups.first(where: { $0.id == groupId }) else {
            throw DriveError.invalidInput("影片已不在计划中")
        }
        guard group.kind == "tv", let tmdbId = group.tmdbId else {
            throw DriveError.invalidInput("请先匹配剧集信息")
        }
        guard !plan.actions.contains(where: { $0.groupId == groupId && $0.done }) else {
            throw DriveError.invalidInput("该影片已有完成操作，请重新扫描后设置单集素材")
        }

        let existing = plan.actions.filter { $0.groupId == groupId && isSidecar($0) }
        let fileActs = plan.actions.filter { $0.groupId == groupId && $0.kind == "file" && $0.fileId != nil && $0.season != nil && ($0.episode ?? 0) > 0 }
        let byFile = Dictionary(grouping: fileActs) { $0.fileId ?? "" }
        let candidates: [PlanAction] = byFile.values.compactMap { list in
            list.first(where: { $0.op == "rename" }) ?? list.first(where: { $0.op == "skip" }) ?? list.first
        }
        guard !candidates.isEmpty || (!nfo && !thumbnails) else {
            throw DriveError.invalidInput("没有可识别的单集，请先纠错")
        }

        var output = plan.actions.filter { !($0.groupId == groupId && isSidecar($0)) }
        for file in candidates {
            let move = plan.actions.first(where: { $0.groupId == groupId && $0.fileId == file.fileId && $0.op == "move" && $0.kind == "file" })
            let parent = move?.destParentId ?? (move?.destRef == nil ? file.parentId : nil)
            let name = MediaParser.splitNameExt((file.op == "rename" && file.enabled) ? file.newName : file.oldName).0
            let specs: [(Bool, String, String)] = [(nfo, ".nfo", "episode_nfo"), (thumbnails, "-thumb.jpg", "image")]
            for (enabled, suffix, kind) in specs {
                let targetName = name + suffix
                let old = existing.first(where: { $0.newName == targetName && $0.parentId == parent && $0.destRef == move?.destRef })
                if !enabled && old == nil { continue }
                output.append(PlanAction(
                    id: old?.id ?? "episode-\(UUID().uuidString.prefix(8).lowercased())",
                    op: "artwork",
                    groupId: groupId,
                    fileId: nil,
                    parentId: parent,
                    oldName: "",
                    newName: targetName,
                    destParentId: parent,
                    destRef: move?.destRef,
                    destLabel: move?.destLabel,
                    kind: kind,
                    mediaKind: "tv",
                    tmdbId: tmdbId,
                    season: file.season,
                    episode: file.episode,
                    artworkUrl: nil,
                    selected: enabled && (old?.enabled == true ? (old?.selected ?? true) : true),
                    enabled: enabled,
                    done: false,
                    error: nil,
                    note: kind == "episode_nfo" ? "写入单集 NFO" : "下载单集剧照",
                    metadataSeason: file.metadataSeason,
                    metadataEpisode: file.metadataEpisode,
                    replaceExisting: fullScrape
                ))
            }
        }
        var out = plan
        out.actions = output
        for i in out.groups.indices where out.groups[i].id == groupId {
            out.groups[i].actionIds = output.filter { $0.groupId == groupId }.map(\.id)
        }
        return out
    }
}


/// 1:1 复刻 Android `LibraryScan.kt`：管理多目标库后台扫描任务，支持 `cancel()` 与 `awaitCompletion()`。
@MainActor
public final class LibraryScanRunner {
    public static let shared = LibraryScanRunner()
    private var currentTask: Task<ScrapePlan, Error>?

    public var isRunning: Bool { currentTask != nil }

    public func start(
        roots: [PlanRoot],
        drive: any CloudDrive,
        fullDrive: Bool = false,
        preflightTmdb: Bool = false,
        onProgress: Scanner.ProgressHandler? = nil
    ) -> Task<ScrapePlan, Error> {
        currentTask?.cancel()
        let t = Task {
            defer { Task { @MainActor in self.currentTask = nil } }
            return try await Scanner.scan(
                roots: roots,
                drive: drive,
                fullDrive: fullDrive,
                preflightTmdb: preflightTmdb,
                onProgress: onProgress
            )
        }
        currentTask = t
        return t
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    public func awaitCompletion() async throws -> ScrapePlan? {
        guard let t = currentTask else { return nil }
        return try await t.value
    }
}
