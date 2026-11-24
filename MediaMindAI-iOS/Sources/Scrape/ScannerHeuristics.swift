import Foundation

/// 1:1 复刻自 Android `Scanner.kt` 核心启发式算法集：
/// - `computeStats`: 计划汇总统计
/// - `seasonOfDir`: 季文件夹编号解析（Season 01 / S02 / 第3季 / Specials / OVA -> 0）
/// - `classify`: 目录角色判定（TITLE 单作品目录 vs CONTAINER 分类容器目录）
/// - `folderTitleMismatch`: 文件夹原名与 TMDB 匹配片名一致性校验（防止低质量误匹配）
/// - `staleArtifacts`: 重新匹配或切换 movie/tv 类型时识别旧残留 NFO/海报
/// - `looksLikeTitleFolder`: 快速判断是否像单部作品目录
public enum ScannerHeuristics {
    public enum FolderRole: String, Sendable {
        case title = "TITLE"
        case container = "CONTAINER"
    }

    public static let maxTreeNodes = 500
    public static let trashDir = "_MediaMind保留区"

    private static let seasonNumRegex = try? NSRegularExpression(
        pattern: #"(?i)^(?:season[\s._-]*|s|第\s*)0*(\d{1,2})\s*(?:季|部)?$"#
    )
    private static let specialDirNames: Set<String> = [
        "specials", "special", "sp", "ova", "oad", "extras", "extra", "特别篇", "番外", "特典", "花絮"
    ]

    public static func computeStats(actions: [PlanAction], groups: [PlanGroup]) -> PlanStats {
        let matched = groups.filter { $0.kind != "unmatched" && !$0.confirmRequired }.count
        let unmatched = groups.filter { $0.kind == "unmatched" }.count
        let confirm = groups.filter { $0.confirmRequired && $0.kind != "unmatched" }.count
        let execActs = actions.filter { PlanSelection.execOps.contains($0.op) }
        return PlanStats(
            totalGroups: groups.count,
            matchedGroups: matched,
            unmatchedGroups: unmatched,
            confirmGroups: confirm,
            totalActions: execActs.count,
            selectedActions: execActs.filter { $0.selected && !$0.done && $0.enabled }.count,
            doneActions: execActs.filter(\.done).count
        )
    }

    /// 解析季目录名（如 `Season 01`、`S2`、`第3季` -> 1/2/3；`Specials`/`SP`/`特别篇` -> 0）。
    public static func seasonOfDir(_ name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if specialDirNames.contains(trimmed.lowercased()) { return 0 }
        guard let rx = seasonNumRegex,
              let m = rx.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
              let r = Range(m.range(at: 1), in: trimmed) else {
            return nil
        }
        return Int(trimmed[r])
    }

    private static let ignoredDirsLower: Set<String> = Set(MediaParser.ignoredDirs.map { $0.lowercased() })

    public static func ignoredDir(_ name: String) -> Bool {
        let low = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == trashDir || name == ScannerTreeEngine.trashDir || ignoredDirsLower.contains(low) || low.hasPrefix(".") || low == "@eadir" || low == "#recycle"
    }

    /// 判定目录角色：TITLE（单部电影或整部剧集根目录）vs CONTAINER（如「电影」「剧集」「2024新片」等分类容器）。
    public static func classify(folderName: String, kids: [CloudEntry]) -> FolderRole {
        let allSubDirs = kids.filter { $0.isDir }
        if StandardNaming.isBdmvRoot(directChildDirNames: allSubDirs.map(\.fileName)) { return .title }
        let subDirs = allSubDirs.filter { !ignoredDir($0.fileName) }
        let videos = kids.filter { !$0.isDir && MediaParser.isVideo($0.fileName) }
        if FolderContextResolver.isGenericContainer(folderName) { return .container }

        // 若子目录全部是 Season XX / Specials 季目录，则当前目录必为剧集 TITLE 目录
        if !subDirs.isEmpty && subDirs.allSatisfy({ seasonOfDir($0.fileName) != nil }) {
            return .title
        }
        // 若直接含视频且无非季子目录，属于 TITLE 目录
        if !videos.isEmpty && subDirs.allSatisfy({ seasonOfDir($0.fileName) != nil }) {
            return .title
        }
        // 含多个独立片名子目录 → 容器目录
        if subDirs.count >= 2 { return .container }
        return !videos.isEmpty ? .title : .container
    }

    public static func looksLikeTitleFolder(items: [CloudEntry]) -> Bool {
        let videos = items.filter { !$0.isDir && MediaParser.isVideo($0.fileName) }
        if !videos.isEmpty { return true }
        let subDirs = items.filter { $0.isDir && !ignoredDir($0.fileName) }
        return !subDirs.isEmpty && subDirs.allSatisfy { seasonOfDir($0.fileName) != nil }
    }

    /// 检测目录原名与 TMDB 匹配片名是否存在严重偏差（对标 Android `Scanner.folderTitleMismatch`）。
    public static func folderTitleMismatch(folderName: String, matchedTitle: String, matchedOriginal: String? = nil) -> Bool {
        let cleanFolder = TitleDeobfuscator.clean(folderName)
        guard cleanFolder.count >= 2, !FolderContextResolver.isGenericContainer(cleanFolder) else { return false }
        let s1 = MediaParser.titleSimilarityScore(cleanFolder, matchedTitle)
        let s2 = matchedOriginal.map { MediaParser.titleSimilarityScore(cleanFolder, $0) } ?? 0
        return max(s1, s2) < 28
    }

    /// 切换作品类型（如电影误识别为剧集，重新匹配回电影）或更换 TMDB ID 时，找出目录内已过期的旧 NFO / 海报。
    public static func staleArtifacts(items: [CloudEntry], newKind: String, matchChanged: Bool) -> [CloudEntry] {
        guard matchChanged else { return [] }
        return items.filter { e in
            guard !e.isDir else { return false }
            let low = e.fileName.lowercased()
            if newKind == "movie" && (low == "tvshow.nfo" || low == "season.nfo") { return true }
            if newKind == "tv" && low == "movie.nfo" { return true }
            if low == "movie.nfo" || low == "tvshow.nfo" || low == "poster.jpg" || low == "fanart.jpg" || low == "clearlogo.png" {
                return true
            }
            return false
        }
    }

    public static func truncatedFlag(folder: String) -> String {
        "「\(folder)」文件太多，只扫描了前 \(maxTreeNodes) 项（其余子文件夹没有处理，可以分开选择这些子文件夹再扫描）"
    }
}
