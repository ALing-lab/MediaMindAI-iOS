import Foundation

/// 1:1 复刻自 Android `ConflictPolicy.kt`：
/// 区分「可挂起业务冲突（目标已存在 / 409）」与「致命安全/网络异常（401/403/429/5xx/超时/凭据）」，
/// 并通过 BFS 计算受影响的下游依赖动作，挂起冲突链同时允许独立项继续执行。
public enum ConflictPolicy {
    private static let fatalKeywords = [
        "待核实", "uncertain",
        "账号不匹配", "账号已变化", "账号已删除", "账号凭据", "凭据",
        "找不到待操作对象", "已被修改", "超时", "timeout", "timed out",
    ]
    private static let conflictKeywords = [
        "目标名称已存在",
        "目标目录已有同名对象",
        "目录名称已被文件占用",
        "素材目标被目录占用",
        "目标有多个同名对象",
        "同名对象",
        "已存在同名文件或目录",
        "已存在，未覆盖",
        "already exists",
    ]
    private static let fatalStatusCodes = ["401", "403", "429", "500", "502", "503", "504"]
    private static let conflictStatusCodes = ["409"]

    private static func containsStatusCode(_ msg: String, codes: [String]) -> Bool {
        for code in codes {
            if let rx = try? NSRegularExpression(pattern: #"(?<!\d)\#(code)(?!\d)"#),
               rx.firstMatch(in: msg, range: NSRange(msg.startIndex..<msg.endIndex, in: msg)) != nil {
                return true
            }
        }
        return false
    }

    public static func isDeferrableConflict(_ errorMessage: String?) -> Bool {
        let msg = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !msg.isEmpty else { return false }
        if fatalKeywords.contains(where: { msg.localizedCaseInsensitiveContains($0) }) { return false }
        if containsStatusCode(msg, codes: fatalStatusCodes) { return false }
        if conflictKeywords.contains(where: { msg.localizedCaseInsensitiveContains($0) }) { return true }
        return containsStatusCode(msg, codes: conflictStatusCodes)
    }

    /// BFS 计算因 `conflictAction` 挂起而必须一并挂起的未完成下游依赖动作 ID（不影响其他独立项）。
    public static func dependentActionIds(conflictAction: PlanAction, allActions: [PlanAction]) -> Set<String> {
        var out: Set<String> = []
        var queue: [String] = [conflictAction.id]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            for a in allActions where a.id != conflictAction.id && !out.contains(a.id) && !a.done {
                let dependsOnRef = (a.destRef == cur)
                let sameFileMove = (conflictAction.op == "rename" && a.op == "move" && conflictAction.fileId != nil && a.fileId == conflictAction.fileId)
                let deleteDepends = (a.op == "delete" || a.op == "trash") && PlanSelection.deleteNeeds(a, all: allActions).contains { $0.id == cur }
                if dependsOnRef || sameFileMove || deleteDepends {
                    out.insert(a.id)
                    queue.append(a.id)
                }
            }
        }
        return out
    }
}

/// 1:1 复刻自 Android `ExistingAssets.kt`：识别云端目录已存在的标准海报/背景图/Logo/NFO，在「补全缺失」模式下自动跳过重复下载。
public enum ExistingAssets {
    private static let imageExtensions: Set<String> = [".jpg", ".jpeg", ".png", ".webp"]

    public static func imageRole(of fileName: String) -> String? {
        let (stem, ext) = MediaParser.splitNameExt(fileName.lowercased())
        guard imageExtensions.contains(ext) else { return nil }
        if ["poster", "folder", "cover", "show", "movie", "season-poster"].contains(stem) || stem.hasSuffix("-poster") {
            return "poster"
        }
        if ["fanart", "backdrop", "background"].contains(stem) || stem.hasSuffix("-fanart") || stem.hasSuffix("-backdrop") {
            return "background"
        }
        if ["logo", "clearlogo"].contains(stem) || stem.hasSuffix("-clearlogo") || stem.hasSuffix("-logo") {
            return "logo"
        }
        return nil
    }

    public static func hasExistingAsset(in entries: [CloudEntry], kind: String, targetName: String) -> Bool {
        let lowTarget = targetName.lowercased()
        let files = entries.filter { !$0.isDir }
        if files.contains(where: { $0.fileName.lowercased() == lowTarget }) { return true }
        switch kind {
        case "image":
            if lowTarget.hasPrefix("poster") {
                return files.contains { imageRole(of: $0.fileName) == "poster" }
            }
            if lowTarget.hasPrefix("fanart") || lowTarget.hasPrefix("backdrop") {
                return files.contains { imageRole(of: $0.fileName) == "background" }
            }
        case "clearlogo":
            return files.contains { imageRole(of: $0.fileName) == "logo" }
        default:
            break
        }
        return false
    }
}

/// 1:1 复刻自 Android `LooseSeriesGrouping.kt`：
/// 同一目录内未识别的散落剧集，去掉集数标记后文件名模板一致且集数互不重复时自动聚为候选组，支持一次整组匹配。
public enum LooseSeriesGrouping {
    public struct Candidate: Identifiable, Sendable {
        public let id: String
        public let files: [PlanAction]

        public init(id: String, files: [PlanAction]) {
            self.id = id
            self.files = files
        }
    }

    private static let epTokenRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:s\d{1,2}\s*[._-]?\s*e\d{1,3}(?:\s*-\s*e?\d{1,3})?|第\s*\d{1,3}\s*[集话話]|(?:^|[\s._-])(?:ep?|#)\s*\d{1,3}(?=[\s._\-\[\(]|$)|(?:^|\s)-\s*\d{1,3}(?=\s|\[|\(|$))"#
    )

    public static func templateOf(_ stem: String) -> String {
        var cut = stem
        if let rx = epTokenRegex,
           let m = rx.firstMatch(in: stem, range: NSRange(stem.startIndex..<stem.endIndex, in: stem)),
           let r = Range(m.range, in: stem) {
            cut.removeSubrange(r)
        }
        return cut.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\p{Han}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func candidates(from actions: [PlanAction]) -> [Candidate] {
        struct Parsed {
            let file: PlanAction
            let season: Int
            let episode: Int
            let key: String
        }
        let parsed: [Parsed] = actions.compactMap { act in
            let (stem, _) = MediaParser.splitNameExt(act.oldName)
            let pm = MediaParser.parse(act.oldName)
            guard let ep = pm.episode else { return nil }
            let key = "\(act.parentId ?? act.groupId)|\(templateOf(stem))"
            return Parsed(file: act, season: pm.season ?? 1, episode: ep, key: key)
        }
        let grouped = Dictionary(grouping: parsed, by: \.key)
        return grouped.values.compactMap { members -> Candidate? in
            guard members.count >= 2 else { return nil }
            let eps = members.map { "\($0.season)-\($0.episode)" }
            guard Set(eps).count == eps.count else { return nil } // 集数重复视为歧义，绝不自动合并
            let sorted = members.map(\.file).sorted { $0.oldName < $1.oldName }
            return Candidate(id: members[0].key, files: sorted)
        }.sorted { ($0.files.first?.oldName ?? "") < ($1.files.first?.oldName ?? "") }
    }
}

/// 1:1 复刻自 Android `AdaptiveDirectoryPlanner.kt`：
/// 开启「自适应目标库」后按「电影 / 剧集」自动规划分类子目录并移入；目标目录已存在同名作品时留在原地绝不覆盖。
public enum AdaptiveDirectoryPlanner {
    public static let kindCategoryMkdir = "adaptive_category_mkdir"
    public static let kindAdaptiveMove = "adaptive_library_move"
    public static var kindManualDestination: String { LibraryDestination.kind }
    private static let autoKinds: Set<String> = [kindCategoryMkdir, kindAdaptiveMove]

    public static func categoryDir(for group: PlanGroup) -> String {
        group.kind == "movie" ? "电影" : "剧集"
    }

    public static func apply(plan: ScrapePlan, policies: DefaultPolicies, drive: any CloudDrive) async -> ScrapePlan {
        let baseActions = plan.actions.filter { !autoKinds.contains($0.kind) }
        let baseFlags = plan.flags.filter { !$0.hasPrefix("自适应目录：") }
        var stripped = plan
        stripped.actions = baseActions
        stripped.flags = baseFlags
        for i in stripped.groups.indices {
            let gid = stripped.groups[i].id
            stripped.groups[i].actionIds = baseActions.filter { $0.groupId == gid }.map(\.id)
        }

        let targetRootId = policies.adaptiveTargetDirId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard policies.adaptiveDirectory, policies.organizeEnabled, !targetRootId.isEmpty else {
            return stripped
        }

        let targetRootPath = policies.adaptiveTargetDirPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootLabel = targetRootPath.isEmpty ? "目标影视库" : targetRootPath
        let rootEntries = (try? await drive.list(folderId: targetRootId)) ?? []
        let existingCatDirs = Dictionary(rootEntries.filter(\.isDir).map { ($0.fileName.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var catChildrenCache: [String: Set<String>] = [:]

        var newActions = baseActions
        var prependedCatMkdirs: [PlanAction] = []
        var newFlags = baseFlags
        var createdCatMkdir: [String: String] = [:]

        for g in stripped.groups {
            // 拆开归档：多部电影合集/系列大文件夹不移动外层目录，改为将每部电影独立建子文件夹放到 目标库/电影/ 根目录
            if g.kind == "collection" || (g.kind == "movie" && g.tmdbId == nil) {
                let perMovieMkIndices = newActions.indices.filter { idx in
                    let a = newActions[idx]
                    return a.groupId == g.id && a.op == "mkdir" && a.kind == "folder" && a.mediaKind == "movie" && !a.done
                }
                guard !perMovieMkIndices.isEmpty else { continue }
                let catName = "电影"
                let catKey = catName.lowercased()
                let catPath = "\(rootLabel)/\(catName)"
                let existingCat = existingCatDirs[catKey]
                if catChildrenCache[catKey] == nil {
                    if let existingCat {
                        let kids = (try? await drive.list(folderId: existingCat.fileId)) ?? []
                        catChildrenCache[catKey] = Set(kids.map { $0.fileName.lowercased() })
                    } else {
                        catChildrenCache[catKey] = []
                    }
                }
                var redirectedCount = 0
                var catMkdirId: String? = nil
                for idx in perMovieMkIndices {
                    let mk = newActions[idx]
                    let targetName = mk.newName
                    guard !targetName.isEmpty else { continue }
                    if catChildrenCache[catKey]?.contains(targetName.lowercased()) == true {
                        newFlags.append("自适应目录：目标「\(catPath)」已存在同名目录「\(targetName)」，已留在原地")
                        continue
                    }
                    if existingCat == nil && catMkdirId == nil {
                        if let existingMk = createdCatMkdir[catName] {
                            catMkdirId = existingMk
                        } else {
                            let mid = "adaptive-mkdir-\(catName)"
                            createdCatMkdir[catName] = mid
                            catMkdirId = mid
                            prependedCatMkdirs.append(PlanAction(
                                id: mid, op: "mkdir", groupId: "", fileId: nil, parentId: targetRootId,
                                oldName: "", newName: catName, destParentId: targetRootId, destRef: nil,
                                kind: kindCategoryMkdir, mediaKind: nil, tmdbId: nil, season: nil, episode: nil,
                                artworkUrl: nil, selected: true, enabled: true, blocked: nil, done: false, error: nil,
                                note: "自适应目录：创建分类子目录 \(catName)"
                            ))
                        }
                    }
                    catChildrenCache[catKey]?.insert(targetName.lowercased())
                    newActions[idx] = PlanAction(
                        id: mk.id, op: mk.op, groupId: mk.groupId, fileId: mk.fileId,
                        parentId: existingCat?.fileId ?? targetRootId,
                        oldName: mk.oldName, newName: mk.newName,
                        destParentId: existingCat?.fileId,
                        destRef: catMkdirId,
                        destLabel: catPath,
                        kind: mk.kind, mediaKind: mk.mediaKind, tmdbId: mk.tmdbId,
                        season: mk.season, episode: mk.episode, artworkUrl: mk.artworkUrl,
                        selected: mk.selected, enabled: mk.enabled, blocked: mk.blocked,
                        done: mk.done, error: mk.error,
                        note: "自适应目录：在 \(catPath) 下为每部电影单独建文件夹",
                        metadataSeason: mk.metadataSeason, metadataEpisode: mk.metadataEpisode,
                        replaceExisting: mk.replaceExisting, folderPath: mk.folderPath
                    )
                    redirectedCount += 1
                }
                if redirectedCount > 0 {
                    if let outerFid = g.folderId {
                        newActions.removeAll { a in
                            a.groupId == g.id && a.op == "rename" && a.kind == "folder" && a.fileId == outerFid && !a.done
                        }
                    }
                    if let gIdx = stripped.groups.firstIndex(where: { $0.id == g.id }) {
                        stripped.groups[gIdx].folderNewName = nil
                    }
                    newFlags.append("自适应目录：已将「\(g.title)」内 \(redirectedCount) 部电影拆开独立建文件夹归档至「\(catPath)」")
                }
                continue
            }

            guard (g.kind == "movie" || g.kind == "tv"), g.tmdbId != nil, let folderId = g.folderId else { continue }
            let gActions = baseActions.filter { $0.groupId == g.id }
            if gActions.contains(where: { $0.kind == kindManualDestination || $0.done }) { continue }

            let parent = gActions.first(where: { $0.fileId == folderId && $0.kind == "folder" && !($0.parentId ?? "").isEmpty })?.parentId
                ?? stripped.roots.first(where: { $0.folderId == folderId })?.parentId
                ?? (folderId.hasPrefix("/") && folderId != "/" ? DrivePaths.parentOf(folderId) : nil)
            guard let parent, !parent.isEmpty else { continue }

            // 防止移入自身或子目录
            let normFolder = "/" + folderId.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            if folderId == targetRootId || (folderId.hasPrefix("/") && targetRootId.hasPrefix(normFolder)) {
                newFlags.append("自适应目录：「\(g.folderName)」与目标目录存在包含关系，已留在原地")
                continue
            }

            let catName = categoryDir(for: g)
            let catKey = catName.lowercased()
            let catPath = "\(rootLabel)/\(catName)"
            let existingCat = existingCatDirs[catKey]
            if let existingCat, parent == existingCat.fileId { continue }

            let folderFinalName = (g.folderNewName ?? g.folderName).isEmpty ? g.title : (g.folderNewName ?? g.folderName)
            guard !folderFinalName.isEmpty else { continue }

            if catChildrenCache[catKey] == nil {
                if let existingCat {
                    let kids = (try? await drive.list(folderId: existingCat.fileId)) ?? []
                    catChildrenCache[catKey] = Set(kids.map { $0.fileName.lowercased() })
                } else {
                    catChildrenCache[catKey] = []
                }
            }
            if catChildrenCache[catKey]?.contains(folderFinalName.lowercased()) == true {
                newFlags.append("自适应目录：目标「\(catPath)」已存在同名目录「\(folderFinalName)」，已留在原地")
                continue
            }
            catChildrenCache[catKey]?.insert(folderFinalName.lowercased())

            var catMkdirId: String? = nil
            if existingCat == nil {
                if let existingMk = createdCatMkdir[catName] {
                    catMkdirId = existingMk
                } else {
                    let mid = "adaptive-mkdir-\(catName)"
                    createdCatMkdir[catName] = mid
                    catMkdirId = mid
                    prependedCatMkdirs.append(PlanAction(
                        id: mid, op: "mkdir", groupId: "", fileId: nil, parentId: targetRootId,
                        oldName: "", newName: catName, destParentId: targetRootId, destRef: nil,
                        kind: kindCategoryMkdir, mediaKind: nil, tmdbId: nil, season: nil, episode: nil,
                        artworkUrl: nil, selected: true, done: false, error: nil,
                        note: "自适应目录：创建分类子目录 \(catName)"
                    ))
                }
            }

            newActions.append(PlanAction(
                id: "adaptive-move-\(g.id)", op: "move", groupId: g.id, fileId: folderId, parentId: parent,
                oldName: folderFinalName, newName: folderFinalName, destParentId: existingCat?.fileId, destRef: catMkdirId,
                kind: kindAdaptiveMove, mediaKind: g.kind, tmdbId: g.tmdbId, season: nil, episode: nil,
                artworkUrl: nil, selected: true, done: false, error: nil,
                note: "自适应归档至 \(catPath)"
            ))
        }

        stripped.actions = prependedCatMkdirs + newActions
        var seenFlags: Set<String> = []
        stripped.flags = newFlags.filter { seenFlags.insert($0).inserted }
        for i in stripped.groups.indices {
            let gid = stripped.groups[i].id
            stripped.groups[i].actionIds = newActions.filter { $0.groupId == gid }.map(\.id)
        }
        return stripped
    }
}
