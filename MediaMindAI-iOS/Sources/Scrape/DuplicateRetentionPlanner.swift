import Foundation

/// 1:1 逐行复刻自 Android `DuplicateRetentionPlanner.kt`（156 行）：
/// 仅对「确定重复」（字节大小一致 > 0 且同算法强格式内容哈希 MD5/SHA-1/SHA-256 完全相同）的多余副本
/// 规划移入「重复保留区/确定重复」（主本保留不动，冗余副本原有 rename/move 自动禁用）；
/// 多版本共存正常保留，疑似重复与命名冲突保留原位并写入提示。
public enum DuplicateRetentionPlanner {
    public static let kindRetentionDuplicate = "retention_duplicate"

    public static func apply(plan: ScrapePlan, policies: DefaultPolicies, drive: any CloudDrive) async -> ScrapePlan {
        let baseActions = plan.actions.filter { $0.kind != kindRetentionDuplicate }
        let baseFlags = plan.flags.filter { !$0.hasPrefix("重复文件：") }
        var stripped = plan
        stripped.actions = baseActions
        stripped.flags = baseFlags
        for i in stripped.groups.indices {
            let gid = stripped.groups[i].id
            stripped.groups[i].actionIds = baseActions.filter { $0.groupId == gid }.map(\.id)
        }
        guard policies.autoMoveConfirmedDuplicates, policies.organizeEnabled else {
            return stripped
        }

        let groupById = Dictionary(stripped.groups.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let videoActions = baseActions.filter { a in
            a.kind == "file" && !a.done && a.fileId != nil && a.parentId != nil
                && ["rename", "move", "skip"].contains(a.op)
                && (groupById[a.groupId].map { ["movie", "tv"].contains($0.kind) && $0.tmdbId != nil } ?? false)
        }
        guard videoActions.count >= 2 else { return stripped }

        // 每个父目录拉一次实时列表获取精确大小与哈希
        var dirCache: [String: [String: CloudEntry]] = [:]
        let parentIds = Array(Set(videoActions.compactMap(\.parentId)))
        for pid in parentIds {
            if let list = try? await drive.list(folderId: pid) {
                dirCache[pid] = Dictionary(list.filter { !$0.isDir }.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
            } else {
                dirCache[pid] = [:]
            }
        }

        let byFileId = Dictionary(grouping: videoActions) { $0.fileId ?? "" }
        var actionMetaByFileId: [String: PlanAction] = [:]
        var candidates: [DuplicateDetector.Candidate] = []

        for (fid, acts) in byFileId where !fid.isEmpty {
            guard let primaryAct = acts.first(where: { $0.op == "rename" }) ?? acts.first,
                  let g = groupById[primaryAct.groupId],
                  let pid = primaryAct.parentId,
                  let entry = dirCache[pid]?[fid] else { continue }
            let moveAct = acts.first(where: { $0.op == "move" })
            actionMetaByFileId[fid] = primaryAct

            let (stem, _) = MediaParser.splitNameExt(primaryAct.oldName.isEmpty ? entry.fileName : primaryAct.oldName)
            let ver = StandardNaming.parseVersion(fileStem: stem, releaseDirName: g.folderName)

            candidates.append(DuplicateDetector.Candidate(
                accountId: stripped.accountId,
                entry: entry,
                sourcePath: g.folderName,
                workKey: "\(g.kind)-\(g.tmdbId ?? 0)",
                workTitle: g.title.isEmpty ? g.folderName : g.title,
                season: primaryAct.season ?? moveAct?.season,
                episode: primaryAct.episode ?? moveAct?.episode,
                versionLabel: ver.label,
                targetDir: moveAct?.destParentId ?? moveAct?.destRef ?? pid,
                targetName: primaryAct.newName.isEmpty ? entry.fileName : primaryAct.newName
            ))
        }

        let dupGroups = DuplicateDetector.analyze(candidates: candidates)
        guard !dupGroups.isEmpty else { return stripped }

        var redundantFileIds: Set<String> = []
        var retentionActions: [PlanAction] = []
        var newFlags = baseFlags

        for dg in dupGroups {
            switch dg.kind {
            case .confirmedDuplicate:
                var resolved = dg
                resolved.resolution = .moveToRetention
                let targets = resolved.retentionTargets()
                for cand in targets {
                    let fid = cand.entry.fileId
                    guard let meta = actionMetaByFileId[fid], let pid = meta.parentId else { continue }
                    redundantFileIds.insert(fid)
                    retentionActions.append(PlanAction(
                        id: "retention-dup-\(fid)",
                        op: "move",
                        groupId: meta.groupId,
                        fileId: fid,
                        parentId: pid,
                        oldName: cand.entry.fileName,
                        newName: cand.entry.fileName,
                        destParentId: nil,
                        destRef: nil,
                        destLabel: "重复保留区/确定重复",
                        kind: kindRetentionDuplicate,
                        mediaKind: meta.mediaKind,
                        tmdbId: meta.tmdbId,
                        season: meta.season,
                        episode: meta.episode,
                        artworkUrl: nil,
                        selected: true,
                        done: false,
                        error: nil,
                        note: dg.evidence
                    ))
                }
                if !targets.isEmpty {
                    newFlags.append("重复文件：「\(dg.workTitle)」检测到 \(targets.count) 个完全重复副本（\(dg.evidence)），将移入重复保留区，主本保留不动")
                }
            case .suspectedDuplicate:
                newFlags.append("重复文件：「\(dg.workTitle)」存在 \(dg.items.count) 个疑似重复文件（\(dg.evidence)），缺少完整哈希校验，已保留原位")
            case .nameConflict:
                newFlags.append("重复文件：「\(dg.workTitle)」存在目标名冲突但内容不同（\(dg.targetName)），已保留原位防止覆盖")
            default:
                break
            }
        }

        let adjustedBase = baseActions.map { a -> PlanAction in
            if let fid = a.fileId, redundantFileIds.contains(fid), ["rename", "move"].contains(a.op) {
                var c = a
                c.enabled = false
                c.selected = false
                c.note = "完全重复副本，改为移入重复保留区"
                return c
            }
            return a
        }
        let finalActions = adjustedBase + retentionActions
        var seenFlags: Set<String> = []
        stripped.actions = finalActions
        stripped.flags = newFlags.filter { seenFlags.insert($0).inserted }
        for i in stripped.groups.indices {
            let gid = stripped.groups[i].id
            stripped.groups[i].actionIds = finalActions.filter { $0.groupId == gid }.map(\.id)
        }
        return stripped
    }
}
