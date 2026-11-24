import Foundation

/// 1:1 逐行复刻自 Android `PlanSelection.kt`（153 行）：
/// - 只有可执行的操作（rename / mkdir / move / artwork / delete）可以勾选；
/// - 勾选「移动」自动勾上它依赖的「新建文件夹」；取消「新建文件夹」同时取消依赖它的「移动」与「素材」；
/// - 勾选「删除多余文件夹」自动勾上清空该目录所必需的「移动」及其依赖的「新建文件夹」；
/// - 共享分类目录 mkdir（groupId 为空）随已勾选移动自动联动。
public enum PlanSelection {
    public static let execOps: Set<String> = ["rename", "mkdir", "move", "artwork", "delete"]

    public enum Tri: String, Sendable {
        case all, some, none, empty
    }

    public static func configurable(_ a: PlanAction) -> Bool {
        execOps.contains(a.op) && !a.done && a.blocked == nil
    }

    public static func executable(_ a: PlanAction) -> Bool {
        configurable(a) && a.enabled
    }

    /// 策略禁用项在重新勾选卡片时保持禁用（1:1 对标 Android `PlanSelection.setEnabled`）。
    public static func setEnabled(plan: ScrapePlan, ids: [String], enabled: Bool) -> ScrapePlan {
        var scratch = plan
        scratch.actions = plan.actions.map { act in
            var c = act
            c.enabled = true
            c.selected = !enabled
            return c
        }
        let expanded = set(plan: scratch, ids: ids, on: enabled)
        let affected = Set(expanded.actions.filter { $0.selected == enabled && configurable($0) }.map(\.id))
        var out = plan
        out.actions = plan.actions.map { act in
            guard affected.contains(act.id) else { return act }
            var c = act
            c.enabled = enabled
            c.selected = enabled
            return c
        }
        return out
    }

    /// 删除多余文件夹前必须先完成的移动（把视频/字幕从这个文件夹移走）。
    public static func deleteNeeds(_ del: PlanAction, all: [PlanAction]) -> [PlanAction] {
        guard del.op == "delete", let delFileId = del.fileId else { return [] }
        let delPrefix = "/" + delFileId.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        return all.filter { m in
            guard m.op == "move", m.kind != "cleanup" else { return false }
            var parent = m.parentId
            var seen: Set<String> = []
            while let p = parent, seen.insert(p).inserted {
                if p == delFileId || (delFileId.hasPrefix("/") && p.hasPrefix(delPrefix)) {
                    return true
                }
                parent = all.first(where: { $0.fileId == p && ($0.kind == "folder" || $0.op == "delete") })?.parentId
            }
            return false
        }
    }

    /// move 依赖的 mkdir（先按 `destRef`，再按同分组同父目录 `destLabel`）。
    public static func dependencyOf(_ move: PlanAction, all: [PlanAction]) -> PlanAction? {
        if let ref = move.destRef {
            return all.first(where: { $0.id == ref && $0.op == "mkdir" })
        }
        guard move.op == "move", move.destParentId == nil, let label = move.destLabel, !label.isEmpty else {
            return nil
        }
        return all.first(where: { $0.op == "mkdir" && $0.newName == label && $0.parentId == move.parentId && $0.groupId == move.groupId })
            ?? all.first(where: { $0.op == "mkdir" && $0.newName == label && $0.parentId == move.parentId })
    }

    /// 不动点依赖传播勾选/取消勾选（1:1 复刻 Android `PlanSelection.set`）。
    public static func set(plan: ScrapePlan, ids: [String], on: Bool) -> ScrapePlan {
        var target = Set(ids)
        let byId = Dictionary(plan.actions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var prevSize = -1
        while target.count != prevSize {
            prevSize = target.count
            if on {
                for id in Array(target) {
                    guard let a = byId[id] else { continue }
                    if let dep = dependencyOf(a, all: plan.actions) {
                        target.insert(dep.id)
                    }
                    for m in deleteNeeds(a, all: plan.actions) {
                        target.insert(m.id)
                        if let dep = dependencyOf(m, all: plan.actions) {
                            target.insert(dep.id)
                        }
                    }
                }
            } else {
                let mkdirIds = Set(target.compactMap { byId[$0] }.filter { $0.op == "mkdir" }.map(\.id))
                if !mkdirIds.isEmpty {
                    for m in plan.actions where m.op == "move" {
                        if let dep = dependencyOf(m, all: plan.actions), mkdirIds.contains(dep.id) {
                            target.insert(m.id)
                        }
                    }
                    for a in plan.actions where a.op == "artwork" && a.destRef != nil {
                        if let ref = a.destRef, mkdirIds.contains(ref) {
                            target.insert(a.id)
                        }
                    }
                }
                let moveIds = Set(target.compactMap { byId[$0] }.filter { $0.op == "move" }.map(\.id))
                if !moveIds.isEmpty {
                    for d in plan.actions where d.op == "delete" {
                        if deleteNeeds(d, all: plan.actions).contains(where: { moveIds.contains($0.id) }) {
                            target.insert(d.id)
                        }
                    }
                }
            }
        }

        var updated = plan.actions.map { act -> PlanAction in
            guard target.contains(act.id) && executable(act) else { return act }
            var c = act
            c.selected = on
            return c
        }

        // 共享分类目录 mkdir（groupId 为空）：只要仍有已勾选移动依赖它就保持勾选，全部取消时一并取消
        if updated.contains(where: { $0.kind == AdaptiveDirectoryPlanner.kindCategoryMkdir }) {
            let activeRefs = Set(updated.filter { $0.selected && $0.op == "move" }.compactMap(\.destRef))
            updated = updated.map { a in
                guard a.kind == AdaptiveDirectoryPlanner.kindCategoryMkdir && executable(a) else { return a }
                var c = a
                c.selected = activeRefs.contains(a.id)
                return c
            }
        }

        var out = plan
        out.actions = updated
        return out
    }

    public static func setAll(plan: ScrapePlan, on: Bool, filter: (PlanAction) -> Bool = { _ in true }) -> ScrapePlan {
        let ids = plan.actions.filter { executable($0) && filter($0) }.map(\.id)
        return set(plan: plan, ids: ids, on: on)
    }

    public static func groupIds(plan: ScrapePlan, groupId: String) -> [String] {
        plan.actions.filter {
            $0.groupId == groupId && $0.kind != "cleanup" && $0.op != "delete" && executable($0)
        }.map(\.id)
    }

    public static func groupState(plan: ScrapePlan, groupId: String) -> Tri {
        let ids = Set(groupIds(plan: plan, groupId: groupId))
        let acts = plan.actions.filter { ids.contains($0.id) }
        if acts.isEmpty { return .empty }
        let n = acts.filter(\.selected).count
        if n == 0 { return .none }
        return n == acts.count ? .all : .some
    }

    /// 要执行的 ID（按计划顺序，已补齐依赖）。
    public static func selectedIds(plan: ScrapePlan) -> [String] {
        var sel = Set(plan.actions.filter { executable($0) && $0.selected }.map(\.id))
        for a in plan.actions where sel.contains(a.id) {
            if let dep = dependencyOf(a, all: plan.actions), executable(dep) {
                sel.insert(dep.id)
            }
            for m in deleteNeeds(a, all: plan.actions) where executable(m) {
                sel.insert(m.id)
                if let dep = dependencyOf(m, all: plan.actions), executable(dep) {
                    sel.insert(dep.id)
                }
            }
        }
        return plan.actions.filter { sel.contains($0.id) }.map(\.id)
    }

    public static func summary(plan: ScrapePlan, ids: [String]) -> String {
        let set = Set(ids)
        let acts = plan.actions.filter { set.contains($0.id) }
        let renameCount = acts.filter { $0.op == "rename" }.count
        let mkdirCount = acts.filter { $0.op == "mkdir" && $0.kind != "cleanup" }.count
        let moveCount = acts.filter { $0.op == "move" && $0.kind != "cleanup" }.count
        let artworkCount = acts.filter { $0.op == "artwork" }.count
        let cleanupCount = acts.filter { $0.kind == "cleanup" && $0.op == "move" }.count
        let deleteCount = acts.filter { $0.op == "delete" }.count
        let parts: [(String, Int)] = [
            ("命名", renameCount),
            ("新建", mkdirCount),
            ("移动", moveCount),
            ("海报", artworkCount),
            ("清理", cleanupCount),
            ("删除", deleteCount),
        ].filter { $0.1 > 0 }
        return parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}
