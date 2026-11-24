import Foundation

/// 1:1 逐行复刻自 Android `PreviewFilter.kt`（166 行）与 `PreviewGrouping.kt`（44 行）：
/// 两排联动筛选（状态：全部/已匹配/未匹配/跳过 × 操作：命名/新建/移动/海报/清理/删除），
/// 单次遍历聚合 `Summary` 缓存所有计数与每组摘要，以及按类型/来源目录分组的中文拼音排序。
public enum PreviewTwoRowFilter {
    public enum Status: String, CaseIterable, Identifiable, Sendable {
        case all = "全部"
        case matched = "已匹配"
        case unmatched = "未匹配"
        case skipped = "跳过"

        public var id: String { rawValue }
        public var label: String { rawValue }
    }

    public struct OpTile: Identifiable, Hashable, Sendable {
        public let key: String
        public let label: String
        public var id: String { key }

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    public static let baseOps: [OpTile] = [
        OpTile(key: "rename", label: "命名"),
        OpTile(key: "mkdir", label: "新建"),
        OpTile(key: "move", label: "移动"),
        OpTile(key: "artwork", label: "海报"),
        OpTile(key: "cleanup", label: "清理"),
    ]
    private static let deleteOp = OpTile(key: "delete", label: "删除")

    public struct State: Hashable, Sendable {
        public var status: Status
        public var op: String?

        public init(status: Status = .all, op: String? = nil) {
            self.status = status
            self.op = op
        }

        public var active: Bool { status != .all || op != nil }
    }

    public struct OpCount: Hashable, Sendable {
        public let selected: Int
        public let total: Int
        public var label: String { "\(selected)/\(total)" }

        public init(selected: Int, total: Int) {
            self.selected = selected
            self.total = total
        }
    }

    public struct GroupAgg: Sendable {
        public var hasActions = false
        public var hasPending = false
        public var matched = 0
        public var exec = 0
        public var execSelected = 0
        public var unmatched = 0
        public var skipped = 0
        public init() {}
    }

    public struct Summary: Sendable {
        private let statusCounts: [Status: Int]
        private let opCounts: [String: OpCount]
        public let tiles: [OpTile]
        public let matchCount: Int
        public let visibleGroupIds: [String]
        public let doneGroupCount: Int
        public let chipText: String?
        private let groups: [String: GroupAgg]

        public init(
            statusCounts: [Status: Int],
            opCounts: [String: OpCount],
            tiles: [OpTile],
            matchCount: Int,
            visibleGroupIds: [String],
            doneGroupCount: Int,
            chipText: String?,
            groups: [String: GroupAgg]
        ) {
            self.statusCounts = statusCounts
            self.opCounts = opCounts
            self.tiles = tiles
            self.matchCount = matchCount
            self.visibleGroupIds = visibleGroupIds
            self.doneGroupCount = doneGroupCount
            self.chipText = chipText
            self.groups = groups
        }

        public func statusCount(_ s: Status) -> Int { statusCounts[s] ?? 0 }
        public func opCount(_ op: String) -> OpCount { opCounts[op] ?? OpCount(selected: 0, total: 0) }

        public func groupSummary(_ groupId: String) -> String {
            guard let g = groups[groupId] else { return "没有操作" }
            if g.exec > 0 { return "\(g.exec) 项 · 已选 \(g.execSelected)" }
            var parts: [String] = []
            if g.unmatched > 0 { parts.append("\(g.unmatched) 个未匹配") }
            if g.skipped > 0 { parts.append("\(g.skipped) 个跳过") }
            return parts.isEmpty ? "没有操作" : parts.joined(separator: " · ")
        }
    }

    public static func opMatches(_ a: PlanAction, op: String) -> Bool {
        guard !a.done else { return false }
        return op == "cleanup" ? a.kind == "cleanup" : (a.kind != "cleanup" && a.op == op)
    }

    public static func statusOf(_ a: PlanAction) -> Status {
        switch a.op {
        case "unmatched": return .unmatched
        case "skip": return .skipped
        default: return .matched
        }
    }

    public static func opsEnabled(_ s: Status) -> Bool { s == .all || s == .matched }

    public static func selectStatus(_ st: State, _ s: Status) -> State {
        State(status: s, op: opsEnabled(s) ? st.op : nil)
    }

    public static func toggleOp(_ st: State, _ op: String) -> State {
        guard opsEnabled(st.status) else { return st }
        return State(status: st.status, op: st.op == op ? nil : op)
    }

    public static func opLabel(_ op: String) -> String {
        (baseOps + [deleteOp]).first(where: { $0.key == op })?.label ?? op
    }

    public static func aggregate(plan: ScrapePlan, state st: State) -> Summary {
        var statusCounts: [Status: Int] = [.all: 0, .matched: 0, .unmatched: 0, .skipped: 0]
        let allOpKeys = Set((baseOps + [deleteOp]).map(\.key))
        var opTotal: [String: Int] = [:]
        var opSel: [String: Int] = [:]
        var groups: [String: GroupAgg] = [:]
        var match = 0

        for a in plan.actions {
            var g = groups[a.groupId] ?? GroupAgg()
            g.hasActions = true
            if a.done {
                groups[a.groupId] = g
                continue
            }
            g.hasPending = true
            let s = statusOf(a)
            statusCounts[.all, default: 0] += 1
            statusCounts[s, default: 0] += 1

            let selected = PlanSelection.executable(a) && a.selected
            let key = a.kind == "cleanup" ? "cleanup" : a.op
            if allOpKeys.contains(key) {
                opTotal[key, default: 0] += 1
                if selected { opSel[key, default: 0] += 1 }
            }

            if (st.status == .all || s == st.status) && (st.op == nil || st.op == key) {
                match += 1
                g.matched += 1
                switch s {
                case .matched:
                    g.exec += 1
                    if selected { g.execSelected += 1 }
                case .unmatched: g.unmatched += 1
                case .skipped: g.skipped += 1
                case .all: break
                }
            }
            groups[a.groupId] = g
        }

        let opCounts = Dictionary(uniqueKeysWithValues: allOpKeys.map { k in
            (k, OpCount(selected: opSel[k] ?? 0, total: opTotal[k] ?? 0))
        })
        let tiles = (opTotal["delete"] ?? 0) > 0 ? (baseOps + [deleteOp]) : baseOps

        let orderedGroups: [PlanGroup]
        if st.status == .unmatched {
            orderedGroups = plan.groups.sorted { ($0.kind == "unmatched" ? 0 : 1) < ($1.kind == "unmatched" ? 0 : 1) }
        } else {
            orderedGroups = plan.groups
        }
        let visible = orderedGroups.filter { pg in
            let g = groups[pg.id]
            return !st.active ? (g == nil || g?.hasPending == true) : (g != nil && (g?.matched ?? 0) > 0)
        }.map(\.id)
        let doneCount = plan.groups.filter { pg in
            if let g = groups[pg.id] { return g.hasActions && !g.hasPending }
            return false
        }.count

        var chip: String? = nil
        if st.active {
            var parts: [String] = []
            if st.status != .all { parts.append(st.status.label) }
            if let op = st.op { parts.append(opLabel(op)) }
            chip = "正在筛选：\(parts.joined(separator: " · ")) · \(match) 项"
        }
        return Summary(
            statusCounts: statusCounts,
            opCounts: opCounts,
            tiles: tiles,
            matchCount: match,
            visibleGroupIds: visible,
            doneGroupCount: doneCount,
            chipText: chip,
            groups: groups
        )
    }
}

/// 1:1 复刻自 Android `PreviewGrouping.kt`：按来源目录或影视分类（电影/剧集/综艺/纪录片/演唱会/待手动确认）分区并按简体中文排序。
public enum PreviewSectionGrouping {
    public struct Section: Identifiable, Sendable {
        public let key: String
        public let title: String
        public let groups: [PlanGroup]
        public var id: String { key }
    }

    public static func source(plan: ScrapePlan, group: PlanGroup) -> PlanRoot? {
        if let sid = group.sourceRootId, let hit = plan.roots.first(where: { $0.folderId == sid }) {
            return hit
        }
        let groupPaths: [String] = (group.folderId.map { [$0] } ?? []) + plan.actions.filter { $0.groupId == group.id }.flatMap { a in
            [a.fileId, a.parentId].compactMap { $0 }
        }
        let matched = plan.roots.filter { root in
            let prefix = "/" + root.folderId.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            return groupPaths.contains { p in
                p == root.folderId || (root.folderId.hasPrefix("/") && p.hasPrefix(prefix))
            }
        }
        return matched.max(by: { $0.folderId.count < $1.folderId.count }) ?? (plan.roots.count == 1 ? plan.roots[0] : nil)
    }

    public static func category(plan: ScrapePlan, group: PlanGroup) -> String {
        if !["movie", "tv", "collection"].contains(group.kind) || group.confirmRequired {
            return "待手动确认"
        }
        let srcName = source(plan: plan, group: group)?.name ?? ""
        let combined = "\(group.title) \(srcName)"
        if combined.contains("纪录片") || combined.localizedCaseInsensitiveContains("documentary") { return "纪录片" }
        if combined.contains("演唱会") || combined.localizedCaseInsensitiveContains("concert") { return "演唱会" }
        if combined.contains("综艺") || combined.localizedCaseInsensitiveContains("variety") { return "综艺" }
        return group.kind == "tv" ? "剧集" : "电影"
    }

    public static func sections(plan: ScrapePlan, groups: [PlanGroup], bySource: Bool) -> [Section] {
        let zhLocale = Locale(identifier: "zh_Hans_CN")
        let sorted = groups.sorted { a, b in
            let ta = a.title.isEmpty ? a.folderName : a.title
            let tb = b.title.isEmpty ? b.folderName : b.title
            let cmp = ta.compare(tb, options: [], range: nil, locale: zhLocale)
            return cmp != .orderedSame ? (cmp == .orderedAscending) : (a.id < b.id)
        }
        if !bySource {
            let order = ["电影", "剧集", "综艺", "纪录片", "演唱会", "待手动确认"]
            return order.compactMap { type in
                let list = sorted.filter { category(plan: plan, group: $0) == type }
                return list.isEmpty ? nil : Section(key: "type:\(type)", title: type, groups: list)
            }
        }
        let grouped = Dictionary(grouping: sorted) { source(plan: plan, group: $0)?.folderId ?? "" }
        var keys = plan.roots.map(\.folderId)
        if !keys.contains("") { keys.append("") }
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }.compactMap { k in
            guard let list = grouped[k], !list.isEmpty else { return nil }
            let title = plan.roots.first(where: { $0.folderId == k })?.name ?? "来源目录未记录"
            return Section(key: "source:\(k)", title: title, groups: list)
        }
    }
}

// MARK: - 快捷分类过滤（合并自旧 PreviewFilterAndGrouping.swift）

/// 1:1 复刻自 Android `PreviewFilter.kt` 与 `PreviewGrouping.kt`：
/// 支持预览页按类型/冲突/策略覆盖筛选与关键词搜索，以及影视库分类归组。
public enum PreviewFilterKind: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case movie = "电影"
    case tv = "剧集"
    case collection = "合集"
    case warning = "需确认"
    case customPolicy = "自定义策略"

    public var id: String { rawValue }
}

public enum PreviewFilter {
    public static func apply(
        groups: [PlanGroup],
        kind: PreviewFilterKind,
        query: String
    ) -> [PlanGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return groups.filter { g in
            let kindOk: Bool
            switch kind {
            case .all: kindOk = true
            case .movie: kindOk = g.kind == "movie"
            case .tv: kindOk = g.kind == "tv"
            case .collection: kindOk = g.kind == "collection"
            case .warning: kindOk = (g.warn != nil && !(g.warn ?? "").isEmpty) || g.kind == "unmatched"
            case .customPolicy: kindOk = g.policyOverride != nil
            }
            guard kindOk else { return false }
            guard !q.isEmpty else { return true }
            return g.title.lowercased().contains(q)
                || g.folderName.lowercased().contains(q)
                || g.year.contains(q)
                || (g.tmdbId.map { "\($0)".contains(q) } ?? false)
        }
    }
}

public enum PreviewGrouping {
    public static func category(for group: PlanGroup) -> String {
        switch group.kind {
        case "movie": return "电影"
        case "tv": return "剧集"
        case "collection": return "合集"
        default: return "待确认"
        }
    }

    public static func groupedByCategory(_ groups: [PlanGroup]) -> [(category: String, items: [PlanGroup])] {
        let order = ["电影", "剧集", "合集", "待确认"]
        let dict = Dictionary(grouping: groups, by: category(for:))
        return order.compactMap { cat in
            guard let list = dict[cat], !list.isEmpty else { return nil }
            return (cat, list)
        }
    }
}
