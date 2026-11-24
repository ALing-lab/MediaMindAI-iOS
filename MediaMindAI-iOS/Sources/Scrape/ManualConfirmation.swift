import Foundation

/// 1:1 逐行复刻自 Android `ManualConfirmation.kt`（67 行）：
/// 统一收口「待手动确认」安全门禁：
/// - 识别失败（unmatched）
/// - 原名称中的年份 / TMDB ID 与匹配结果矛盾
/// - 启用标准命名规范时，缺少分辨率来源依据或分辨率/HDR 标注矛盾
/// 待手动确认的作品自动取消执行勾选，禁止未经确认写入云盘。
public enum ManualConfirmation {
    private static let yearRegex = try? NSRegularExpression(pattern: #"(?<!\d)(19\d{2}|20\d{2})(?!\d)"#)

    public static func evaluateGroup(
        _ group: PlanGroup,
        actions: [PlanAction],
        standardSpec: Bool = false
    ) -> [String] {
        if group.kind == "unmatched" { return ["未能自动识别影视信息"] }
        var reasons: [String] = []
        let sourceHint = !group.folderName.isEmpty
            ? group.folderName
            : (actions.first(where: { $0.kind == "file" })?.oldName ?? "")

        let embeddedId = MediaParser.parse(sourceHint).tmdbId
        if let embeddedId, let tmdbId = group.tmdbId, embeddedId != tmdbId {
            reasons.append("原名称包含 TMDB \(embeddedId)，与当前匹配 TMDB \(tmdbId) 矛盾")
        }

        if let rx = yearRegex, let matchedYear = Int(group.year) {
            let matches = rx.matches(in: sourceHint, range: NSRange(sourceHint.startIndex..<sourceHint.endIndex, in: sourceHint))
            let sourceYears = Array(Set(matches.compactMap { m -> Int? in
                guard let r = Range(m.range(at: 1), in: sourceHint) else { return nil }
                return Int(sourceHint[r])
            })).sorted()
            if !sourceYears.isEmpty && !sourceYears.contains(where: { abs($0 - matchedYear) <= 1 }) {
                let yText = sourceYears.map(String.init).joined(separator: "/")
                reasons.append("原名称年份（\(yText)）与 TMDB 年份（\(matchedYear)）不符")
            }
        }

        if standardSpec {
            let fileActions = actions.filter { $0.kind == "file" && $0.op == "rename" && !$0.done }
            for a in fileActions {
                let (stem, _) = MediaParser.splitNameExt(a.oldName)
                let v = StandardNaming.parseVersion(fileStem: stem, releaseDirName: group.folderName.isEmpty ? nil : group.folderName)
                if v.needsConfirm, let r = v.confirmReason {
                    reasons.append("\(a.oldName)：\(r)")
                }
            }
        }

        var seen: Set<String> = []
        return reasons.filter { seen.insert($0).inserted }
    }

    public static func isPendingConfirmation(_ group: PlanGroup, actions: [PlanAction]) -> Bool {
        group.kind == "unmatched"
            || group.confirmRequired
            || actions.contains(where: { !$0.done && $0.op == "unmatched" })
    }

    /// 为计划写入确认标记并自动取消待确认分组的执行勾选，阻止未经确认写入云盘。
    public static func applyGate(to plan: ScrapePlan, standardSpec: Bool = false) -> ScrapePlan {
        let byGroup = Dictionary(grouping: plan.actions, by: \.groupId)
        var blockedGroups: Set<String> = []
        var nextGroups: [PlanGroup] = []

        for g in plan.groups {
            let acts = byGroup[g.id] ?? []
            let detected = evaluateGroup(g, actions: acts, standardSpec: standardSpec)
            var seen: Set<String> = []
            let allReasons = (g.confirmReasons + detected).filter { seen.insert($0).inserted }
            let needConfirm = g.kind == "unmatched" || g.confirmRequired || !allReasons.isEmpty
            if needConfirm { blockedGroups.insert(g.id) }
            var copy = g
            copy.confirmRequired = needConfirm && g.kind != "unmatched"
            copy.confirmReasons = allReasons
            if copy.warn == nil, let firstReason = allReasons.first { copy.warn = firstReason }
            nextGroups.append(copy)
        }

        var out = plan
        out.groups = nextGroups
        guard !blockedGroups.isEmpty else { return out }
        out.actions = plan.actions.map { a in
            guard blockedGroups.contains(a.groupId) && !a.done && a.selected else { return a }
            var c = a
            c.selected = false
            return c
        }
        return out
    }
}
