import Foundation

/// 1:1 复刻自 Android `EditionParser.kt`（v0.5.45–v0.5.78）：
/// 14 级 Kometa 权重多版本/剪辑版（Edition）、3D 标记、多段分盘（CD/Disc/Part/上下部）与原盘结构（BDMV/VIDEO_TS/ISO）解析器。
public enum EditionParser {
    public struct EditionInfo: Hashable, Sendable {
        public let editions: [String]
        public let threeD: String?

        public init(editions: [String], threeD: String? = nil) {
            self.editions = editions
            self.threeD = threeD
        }

        public var displayLabel: String {
            (editions + (threeD.map { [$0] } ?? [])).joined(separator: " ")
        }
    }

    public struct StackPart: Hashable, Sendable {
        public let type: String // "CD" | "Disc" | "Part" | "UpperLower"
        public let index: Int
        public let rawToken: String

        public init(type: String, index: Int, rawToken: String) {
            self.type = type
            self.index = index
            self.rawToken = rawToken
        }
    }

    public enum DiscType: String, Sendable {
        case singleFile = "SINGLE_FILE"
        case bdmv = "BDMV"
        case videoTs = "VIDEO_TS"
        case iso = "ISO"
    }

    private struct EditionRule {
        let label: String
        let weight: Int
        let regex: NSRegularExpression
    }

    private static let editionRules: [EditionRule] = {
        let raw: [(String, Int, String)] = [
            ("Extended", 190, #"(?i)(?<![A-Za-z])Extended(?:\s+(?:Cut|Edition|Version))?(?![A-Za-z])|加长版"#),
            ("Uncut", 180, #"(?i)(?<![A-Za-z])Uncut(?![A-Za-z])|未删减版?"#),
            ("Unrated", 170, #"(?i)(?<![A-Za-z])Unrated(?![A-Za-z])|未分级版?"#),
            ("Special Edition", 160, #"(?i)(?<![A-Za-z])Special[ ._-]+Edition(?![A-Za-z])|特别版"#),
            ("Director's Cut", 110, #"(?i)(?<![A-Za-z])Director'?s?[ ._-]+Cut(?![A-Za-z])|导演剪辑版|导剪版"#),
            ("Final Cut", 100, #"(?i)(?<![A-Za-z])Final[ ._-]+Cut(?![A-Za-z])|最终剪辑版"#),
            ("Theatrical", 80, #"(?i)(?<![A-Za-z])Theatrical(?:[ ._-]+Cut)?(?![A-Za-z])|公映版|院线版"#),
            ("Ultimate Cut", 70, #"(?i)(?<![A-Za-z])Ultimate[ ._-]+(?:Cut|Edition)(?![A-Za-z])|终极版"#),
            ("IMAX Enhanced", 40, #"(?i)(?<![A-Za-z])IMAX[ ._-]+Enhanced(?![A-Za-z])"#),
            ("IMAX", 30, #"(?i)(?<![A-Za-z])(?<!NON[ ._-])IMAX(?![A-Za-z])"#),
            ("4K Remastered", 25, #"(?i)(?<![A-Za-z])4K[ ._-]+Remaster(?:ed)?(?![A-Za-z])|4K修复版"#),
            ("Remastered", 20, #"(?i)(?<![A-Za-z])Remaster(?:ed)?(?![A-Za-z])|修复版|重制版"#),
            ("Criterion", 10, #"(?i)(?<![A-Za-z])(?:Criterion[ ._-]+Collection|CC标准收藏版)(?![A-Za-z])"#),
            ("Open Matte", 6, #"(?i)(?<![A-Za-z])Open[ ._-]+Matte(?![A-Za-z])|满屏版"#),
        ]
        return raw.compactMap { (lbl, w, pat) in
            guard let rx = try? NSRegularExpression(pattern: pat) else { return nil }
            return EditionRule(label: lbl, weight: w, regex: rx)
        }
    }()

    private static let threeDRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:^|[\s._\-\[\(])(?:(BluRay3D|BD3D)|3D[\s._\-]?(HSBS|FSBS|HTAB|FTAB|SBS|TAB|HOU|MVC)?)(?:$|[\s._\-\]\)])"#
    )
    private static let stackEnRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9])(cd|dvd|dis[ck]|part|pt)[ ._-]*([1-9]|[a-d])(?![A-Za-z0-9])"#
    )
    private static let stackCnRegex = try? NSRegularExpression(
        pattern: #"(?<=[\p{Han}\s._\-\(\[])([上下])[部集]?(?=$|[\s._\-\)\]])"#
    )

    public static func parseEditions(_ stem: String) -> EditionInfo {
        let full = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        var found: [(String, Int)] = []
        var foundNames: Set<String> = []

        for rule in editionRules {
            guard let m = rule.regex.firstMatch(in: stem, range: full),
                  let r = Range(m.range, in: stem) else { continue }
            if m.range.location == 0 && stem.count <= stem[r].count + 2 { continue }
            if rule.label == "IMAX" && foundNames.contains("IMAX Enhanced") { continue }
            if rule.label == "Remastered" && foundNames.contains("4K Remastered") { continue }
            if foundNames.insert(rule.label).inserted {
                found.append((rule.label, rule.weight))
            }
        }
        let sorted = found.sorted { $0.1 > $1.1 }.map(\.0)

        var threeD: String? = nil
        if let m = threeDRegex?.firstMatch(in: stem, range: full) {
            if m.numberOfRanges > 2, m.range(at: 2).location != NSNotFound,
               let subR = Range(m.range(at: 2), in: stem) {
                let sub = String(stem[subR]).uppercased()
                threeD = sub.isEmpty ? "3D" : "3D \(sub)"
            } else {
                threeD = "3D"
            }
        }
        return EditionInfo(editions: sorted, threeD: threeD)
    }

    public static func parseStackPart(_ stem: String) -> StackPart? {
        let full = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        if let m = stackEnRegex?.firstMatch(in: stem, range: full),
           let r0 = Range(m.range, in: stem),
           let r1 = Range(m.range(at: 1), in: stem),
           let r2 = Range(m.range(at: 2), in: stem) {
            let kindRaw = stem[r1].lowercased()
            let kind: String
            if kindRaw == "cd" { kind = "CD" }
            else if kindRaw.hasPrefix("dis") || kindRaw == "dvd" { kind = "Disc" }
            else { kind = "Part" }
            let idxRaw = stem[r2].lowercased()
            let idx: Int
            if let n = Int(idxRaw) {
                idx = n
            } else if let scalar = idxRaw.unicodeScalars.first {
                idx = Int(scalar.value) - Int(UnicodeScalar("a").value) + 1
            } else {
                idx = 1
            }
            return StackPart(type: kind, index: idx, rawToken: String(stem[r0]).trimmingCharacters(in: .whitespaces))
        }
        if let m = stackCnRegex?.firstMatch(in: stem, range: full),
           let r0 = Range(m.range, in: stem),
           let r1 = Range(m.range(at: 1), in: stem) {
            let ch = String(stem[r1])
            return StackPart(type: "UpperLower", index: ch == "上" ? 1 : 2, rawToken: String(stem[r0]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    public static func detectDiscType(fileName: String, childDirNames: [String] = []) -> DiscType {
        if childDirNames.contains(where: { $0.caseInsensitiveCompare("BDMV") == .orderedSame }) { return .bdmv }
        if childDirNames.contains(where: { $0.caseInsensitiveCompare("VIDEO_TS") == .orderedSame }) { return .videoTs }
        if fileName.lowercased().hasSuffix(".iso") { return .iso }
        return .singleFile
    }
}

/// 1:1 复刻自 Android `StandardNaming.kt`（严格对齐《云盘影视库命名规范》）：
/// - 电影目录：`片名 (年份) {tmdb-ID}`
/// - 电影文件：`片名 (年份) {tmdb-ID} - 版本标签`
/// - 剧集目录：`剧名 (首播年份) {tmdb-ID}`
/// - 季目录：`Season 01` / `Season 00`（特别篇）
/// - 剧集文件：`剧名 - S01E01 {tmdb-ID} - 版本标签`（不重复年份，多集连号支持 `S01E01-E03`）
/// - 版本顺序：`分辨率 [帧率] [UHD] [画质格式（DV→HDR10+→HDR10→HDRVivid→HDR→HLG / EDR / SDR）] [来源 BluRay] [音轨]`
public enum StandardNaming {
    private static let b = #"(?<![A-Za-z0-9])"#
    private static let e = #"(?![A-Za-z0-9])"#

    private static let tmdbMarkRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:\{|\[|\()?(?:tmdb|tmdbid)[-_:\s=]\d{1,8}(?:\}|\]|\))?"#
    )

    private static let resPatterns: [(NSRegularExpression, String)] = [
        (#"(?i)\#(b)(?:2160[pi]|4K|UHD|3840x2160)\#(e)"#, "2160p"),
        (#"(?i)\#(b)(?:1080[pi]|1920x1080)\#(e)"#, "1080p"),
        (#"(?i)\#(b)(?:720[pi]|1280x720)\#(e)"#, "720p"),
        (#"(?i)\#(b)480[pi]\#(e)"#, "480p"),
    ].compactMap { (pat, norm) in
        guard let rx = try? NSRegularExpression(pattern: pat) else { return nil }
        return (rx, norm)
    }

    private static let fpsRegex = try? NSRegularExpression(pattern: #"(?i)(?<![0-9])(?<![0-9]\.)(\d{2,3}(?:\.\d{1,3})?)\s?(?:fps|帧)"#)
    private static let uhdRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)UHD\#(e)"#)
    private static let dvRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)(?:DV|DoVi)\#(e)|Dolby[ ._-]?Vision|杜比视界|杜比世界"#)
    private static let hdr10pRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)HDR10(?:\+|Plus|P\#(e))"#)
    private static let hdr10Regex = try? NSRegularExpression(pattern: #"(?i)\#(b)HDR10(?![0-9+])"#)
    private static let hlgRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)HLG\#(e)"#)
    private static let hdrVividRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)HDR[ ._-]?Vivid\#(e)"#)
    private static let edrRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)EDR\#(e)"#)
    private static let sdrRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)SDR\#(e)"#)
    private static let blurayRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)(?:Blu[- ]?Ray|BDRemux)\#(e)"#)
    private static let hdrGenericRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)HDR(?![A-Za-z0-9])"#)
    private static let atmosRegex = try? NSRegularExpression(pattern: #"(?i)\#(b)(?:Dolby[ ._-]?)?Atmos\#(e)|全景声"#)

    private static let audioRegex = try? NSRegularExpression(
        pattern: #"(?i)\#(b)(?:(TrueHD)|(DTS[-. ]?HD[-. ]?MA)|(DTS[-:. ]?X)(?![A-Za-z0-9])|(DTS[-. ]?HD)|(DTS)|(DDP|DD\+|E-?AC-?3)|(DD)(?=[ .]?[1-9]\.[0-2]|[^A-Za-z0-9+]|$)|(AC-?3)|(AAC)|(FLAC)|(L?PCM)|(OPUS))(?:[ .]?([1-9]\.[0-2])(?![0-9]))?(?![A-Za-z])"#
    )

    public struct VersionInfo: Hashable, Sendable {
        public let resolution: String
        public let fps: String
        public let hdr: String
        public let audio: String
        public let needsConfirm: Bool
        public let confirmReason: String?
        public let source: String
        public let uhd: String

        public init(
            resolution: String = "",
            fps: String = "",
            hdr: String = "",
            audio: String = "",
            needsConfirm: Bool = false,
            confirmReason: String? = nil,
            source: String = "",
            uhd: String = ""
        ) {
            self.resolution = resolution
            self.fps = fps
            self.hdr = hdr
            self.audio = audio
            self.needsConfirm = needsConfirm
            self.confirmReason = confirmReason
            self.source = source
            self.uhd = uhd
        }

        public var label: String {
            [resolution, fps, uhd, hdr, source, audio].filter { !$0.isEmpty }.joined(separator: " ")
        }

        /// 按文件级命名偏好过滤版本标签（keep* 开关 + 缺失画质补 SDR + 画质 token 白名单）。
        public func filteredBy(_ o: FileOptions) -> VersionInfo {
            guard o.keepExtraInfo else {
                return VersionInfo(needsConfirm: needsConfirm, confirmReason: confirmReason)
            }
            let allowed = Set(o.qualityTokens.map { $0.uppercased() })
            func tokenOk(_ t: String) -> Bool {
                o.qualityTokens.isEmpty || allowed.contains(t.uppercased()) || t == "HLG"
            }
            var h = o.keepQuality
                ? hdr.split(separator: " ").map(String.init).filter { !$0.isEmpty && tokenOk($0) }.joined(separator: " ")
                : ""
            let u = (o.keepQuality && tokenOk("UHD")) ? uhd : ""
            let src = (o.keepQuality && tokenOk("BLURAY")) ? source : ""
            if o.keepQuality && h.isEmpty && u.isEmpty && src.isEmpty && o.defaultSdrWhenMissing {
                h = "SDR"
            }
            return VersionInfo(
                resolution: o.keepResolution ? resolution : "",
                fps: o.keepFps ? fps : "",
                hdr: h,
                audio: o.keepAudio ? audio : "",
                needsConfirm: needsConfirm,
                confirmReason: confirmReason,
                source: src,
                uhd: u
            )
        }
    }

    public struct FileOptions: Codable, Hashable, Sendable {
        public var keepExtraInfo: Bool
        public var keepResolution: Bool
        public var keepQuality: Bool
        public var keepFps: Bool
        public var keepAudio: Bool
        public var defaultSdrWhenMissing: Bool
        public var qualityTokens: [String]
        public var tmdbEnabled: Bool
        public var tmdbStyle: String
        public var separator: String
        public var yearEnabled: Bool
        public var yearStyle: String

        public init(
            keepExtraInfo: Bool = true,
            keepResolution: Bool = true,
            keepQuality: Bool = true,
            keepFps: Bool = true,
            keepAudio: Bool = true,
            defaultSdrWhenMissing: Bool = false,
            qualityTokens: [String] = [],
            tmdbEnabled: Bool = true,
            tmdbStyle: String = "{tmdb-id}",
            separator: String = " ",
            yearEnabled: Bool = true,
            yearStyle: String = "(year)"
        ) {
            self.keepExtraInfo = keepExtraInfo
            self.keepResolution = keepResolution
            self.keepQuality = keepQuality
            self.keepFps = keepFps
            self.keepAudio = keepAudio
            self.defaultSdrWhenMissing = defaultSdrWhenMissing
            self.qualityTokens = qualityTokens
            self.tmdbEnabled = tmdbEnabled
            self.tmdbStyle = tmdbStyle
            self.separator = separator
            self.yearEnabled = yearEnabled
            self.yearStyle = yearStyle
        }
    }

    public static func stripTmdbMark(_ text: String) -> String {
        guard let rx = tmdbMarkRegex else { return text }
        let r = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = rx.stringByReplacingMatches(in: text, range: r, withTemplate: " ")
        return stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ rx: NSRegularExpression?, in text: String) -> Bool {
        guard let rx else { return false }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func extractResolutions(_ text: String) -> Set<String> {
        let clean = stripTmdbMark(text)
        var out: Set<String> = []
        for (rx, norm) in resPatterns where matches(rx, in: clean) {
            out.insert(norm)
        }
        return out
    }

    private static func extractFps(_ text: String) -> String {
        let clean = stripTmdbMark(text)
        guard let rx = fpsRegex,
              let m = rx.firstMatch(in: clean, range: NSRange(clean.startIndex..<clean.endIndex, in: clean)),
              let r = Range(m.range(at: 1), in: clean) else { return "" }
        var num = String(clean[r])
        if num.hasSuffix(".0") { num = String(num.dropLast(2)) }
        return "\(num)fps"
    }

    private static func extractHdr(_ text: String) -> (String, Bool) {
        let clean = stripTmdbMark(text)
        let hasDv = matches(dvRegex, in: clean)
        let hasHlg = matches(hlgRegex, in: clean)
        let hasHdr10p = matches(hdr10pRegex, in: clean)
        let hasHdr10 = !hasHdr10p && matches(hdr10Regex, in: clean)
        let hasVivid = matches(hdrVividRegex, in: clean)
        let hasHdr = matches(hdrGenericRegex, in: clean)
        let hasEdr = matches(edrRegex, in: clean)
        let hasSdr = matches(sdrRegex, in: clean)
        if hasHlg && (hasDv || hasHdr10p || hasHdr10 || hasVivid) { return ("", true) }

        var tokens: [String] = []
        if hasDv { tokens.append("DV") }
        if hasHdr10p { tokens.append("HDR10+") }
        if hasHdr10 { tokens.append("HDR10") }
        if hasVivid { tokens.append("HDRVivid") }
        if hasHdr && !hasHdr10p && !hasHdr10 && !hasVivid { tokens.append("HDR") }
        if hasHlg { tokens.append("HLG") }
        if tokens.isEmpty {
            if hasEdr { tokens.append("EDR") }
            else if hasSdr { tokens.append("SDR") }
        }
        return (tokens.joined(separator: " "), false)
    }

    private static func extractAudio(_ text: String) -> String {
        let clean = stripTmdbMark(text)
        let hasAtmos = matches(atmosRegex, in: clean)
        guard let rx = audioRegex,
              let m = rx.firstMatch(in: clean, range: NSRange(clean.startIndex..<clean.endIndex, in: clean)) else {
            return hasAtmos ? "Atmos" : ""
        }
        func hasGroup(_ idx: Int) -> Bool {
            idx < m.numberOfRanges && m.range(at: idx).location != NSNotFound
        }
        let ch: String
        if hasGroup(13), let r = Range(m.range(at: 13), in: clean) {
            ch = String(clean[r])
        } else {
            ch = ""
        }

        let base: String
        if hasGroup(1) { base = ch.isEmpty ? "TrueHD" : "TrueHD \(ch)" }
        else if hasGroup(2) { base = ch.isEmpty ? "DTS-HD MA" : "DTS-HD MA \(ch)" }
        else if hasGroup(3) { base = ch.isEmpty ? "DTS-X" : "DTS-X \(ch)" }
        else if hasGroup(4) { base = ch.isEmpty ? "DTS-HD" : "DTS-HD \(ch)" }
        else if hasGroup(5) { base = ch.isEmpty ? "DTS" : "DTS \(ch)" }
        else if hasGroup(6) { base = "DDP\(ch)" }
        else if hasGroup(7) { base = "DD\(ch)" }
        else if hasGroup(8) { base = ch.isEmpty ? "AC3" : "DD\(ch)" }
        else if hasGroup(9) { base = "AAC\(ch)" }
        else if hasGroup(10) { base = ch.isEmpty ? "FLAC" : "FLAC \(ch)" }
        else if hasGroup(11) { base = ch.isEmpty ? "LPCM" : "LPCM \(ch)" }
        else if hasGroup(12) { base = ch.isEmpty ? "OPUS" : "OPUS \(ch)" }
        else { base = "" }

        if base.isEmpty { return hasAtmos ? "Atmos" : "" }
        return (hasAtmos && !base.localizedCaseInsensitiveContains("Atmos")) ? "\(base) Atmos" : base
    }

    /// 解析版本标签：当前文件名优先；仅在当前文件缺少对应维度时从所属发布目录继承。
    public static func parseVersion(fileStem: String, releaseDirName: String? = nil) -> VersionInfo {
        let dir = (releaseDirName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? releaseDirName : nil
        let fileRes = extractResolutions(fileStem)
        let dirRes = (fileRes.isEmpty && dir != nil) ? extractResolutions(dir ?? "") : []
        let chosenResSet = !fileRes.isEmpty ? fileRes : dirRes
        let resConflict = chosenResSet.count > 1
        let res = chosenResSet.count == 1 ? (chosenResSet.first ?? "") : ""

        let fFps = extractFps(fileStem)
        let fps = !fFps.isEmpty ? fFps : (dir.map { extractFps($0) } ?? "")

        let uhd: String
        if matches(uhdRegex, in: stripTmdbMark(fileStem)) {
            uhd = "UHD"
        } else if let dir, matches(uhdRegex, in: stripTmdbMark(dir)) {
            uhd = "UHD"
        } else {
            uhd = ""
        }

        let (fileHdr, fileHdrConflict) = extractHdr(fileStem)
        let (hdr, hdrConflict): (String, Bool)
        if !fileHdr.isEmpty || fileHdrConflict {
            (hdr, hdrConflict) = (fileHdr, fileHdrConflict)
        } else if let dir {
            (hdr, hdrConflict) = extractHdr(dir)
        } else {
            (hdr, hdrConflict) = ("", false)
        }

        let fAudio = extractAudio(fileStem)
        let audio = !fAudio.isEmpty ? fAudio : (dir.map { extractAudio($0) } ?? "")

        let source: String
        if matches(blurayRegex, in: stripTmdbMark(fileStem)) {
            source = "BluRay"
        } else if let dir, matches(blurayRegex, in: stripTmdbMark(dir)) {
            source = "BluRay"
        } else {
            source = ""
        }

        let reason: String?
        if resConflict { reason = "分辨率标注互相矛盾" }
        else if res.isEmpty { reason = "缺少分辨率来源依据" }
        else if hdrConflict { reason = "HDR 标注互相矛盾" }
        else { reason = nil }

        return VersionInfo(
            resolution: res,
            fps: fps,
            hdr: hdr,
            audio: audio,
            needsConfirm: reason != nil,
            confirmReason: reason,
            source: source,
            uhd: uhd
        )
    }

    public static func cleanTitle(_ title: String) -> String {
        MediaParser.sanitizeFileName(title)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func tmdbTag(_ tmdbId: Int?, style: String = "{tmdb-id}") -> String {
        guard let id = tmdbId, id > 0 else { return "" }
        switch style {
        case "[tmdb-id]": return "[tmdb-\(id)]"
        case "[tmdbid=id]": return "[tmdbid=\(id)]"
        case "tmdb-id": return "tmdb-\(id)"
        default: return "{tmdb-\(id)}"
        }
    }

    public static func formatYear(_ year: String, style: String = "(year)") -> String {
        let y = year.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !y.isEmpty else { return "" }
        switch style {
        case "[year]": return "[\(y)]"
        case "year": return y
        default: return "(\(y))"
        }
    }

    public static func seasonDirName(_ season: Int) -> String {
        String(format: "Season %02d", max(0, season))
    }

    /// 任务级命名偏好作用域（1:1 对标 Android `Naming.withSnapshot`），确保 `Scanner.scan` / `replan*` 全程读取用户配置。
    @TaskLocal public static var scopedMoviePrefs: MediaNamingPrefs? = nil
    @TaskLocal public static var scopedTvPrefs: MediaNamingPrefs? = nil

    public static func folderName(
        title: String,
        year: String,
        tmdbId: Int?,
        prefs: MediaNamingPrefs? = nil,
        isTv: Bool = false
    ) -> String {
        let effPrefs = prefs ?? (isTv ? Self.scopedTvPrefs : Self.scopedMoviePrefs)
        let clean = cleanTitle(title)
        let sep = effPrefs?.folderSeparator ?? " "
        let yEnabled = effPrefs?.folderYearEnabled ?? true
        let yStyle = effPrefs?.folderYearStyle ?? "(year)"
        let tEnabled = effPrefs?.folderTmdbEnabled ?? true
        let tStyle = effPrefs?.folderTmdbStyle ?? "{tmdb-id}"

        let y = yEnabled ? formatYear(year, style: yStyle) : ""
        let tag = tEnabled ? tmdbTag(tmdbId, style: tStyle) : ""
        return [clean, y, tag].filter { !$0.isEmpty }.joined(separator: sep)
    }

    /// 电影文件名主干：`片名 (年份) {tmdb-ID} - 2160p 24fps UHD DV BluRay TrueHD 7.1 Atmos Extended`
    public static func movieFileBase(
        title: String,
        year: String,
        tmdbId: Int?,
        fileStem: String,
        releaseDirName: String? = nil,
        options: FileOptions? = nil
    ) -> String {
        let effOpts = options ?? Self.scopedMoviePrefs?.fileOptions()
        let clean = cleanTitle(title)
        let sep = effOpts?.separator ?? " "
        let y = (effOpts?.yearEnabled ?? true) ? formatYear(year, style: effOpts?.yearStyle ?? "(year)") : ""
        let tag: String
        if let effOpts {
            tag = effOpts.tmdbEnabled ? tmdbTag(tmdbId, style: effOpts.tmdbStyle) : ""
        } else {
            tag = tmdbTag(tmdbId)
        }
        let head = [clean, y, tag].filter { !$0.isEmpty }.joined(separator: sep)
        let parsed = parseVersion(fileStem: fileStem, releaseDirName: releaseDirName)
        let baseVersion = (effOpts.map { parsed.filteredBy($0) } ?? parsed).label
        let editionLabel = (effOpts?.keepExtraInfo ?? true) ? EditionParser.parseEditions(fileStem).displayLabel : "" 

        let combinedVersion: String
        if !baseVersion.isEmpty && !editionLabel.isEmpty {
            if baseVersion.localizedCaseInsensitiveContains(editionLabel) {
                combinedVersion = baseVersion
            } else {
                combinedVersion = "\(baseVersion) \(editionLabel)"
            }
        } else {
            combinedVersion = !baseVersion.isEmpty ? baseVersion : editionLabel
        }
        return combinedVersion.isEmpty ? head : "\(head) - \(combinedVersion)"
    }

    /// 剧集文件名主干：`剧名 - S01E01 {tmdb-ID} - 2160p 60fps HDRVivid DDP5.1`（多集连号支持 `S01E01-E03`）
    public static func episodeFileBase(
        title: String,
        season: Int,
        episode: Int,
        episodeEnd: Int? = nil,
        tmdbId: Int?,
        fileStem: String,
        releaseDirName: String? = nil,
        options: FileOptions? = nil,
        year: String = ""
    ) -> String {
        let effOpts = options ?? Self.scopedTvPrefs?.fileOptions()
        let clean = cleanTitle(title)
        let s = max(0, season)
        let ep = max(0, episode)
        let tail = episodeEnd.map { String(format: "-E%02d", max(ep, $0)) } ?? ""
        let se = String(format: "S%02dE%02d", s, ep) + tail
        let tag: String
        if let effOpts {
            tag = effOpts.tmdbEnabled ? tmdbTag(tmdbId, style: effOpts.tmdbStyle) : ""
        } else {
            tag = tmdbTag(tmdbId)
        }
        let sep = effOpts?.separator ?? " "
        let seAndTag = [se, tag].filter { !$0.isEmpty }.joined(separator: sep)
        let titlePart: String
        if effOpts?.yearEnabled == true && !year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titlePart = "\(clean)\(sep)\(formatYear(year, style: effOpts?.yearStyle ?? "(year)"))"
        } else {
            titlePart = clean
        }
        let head = "\(titlePart) - \(seAndTag)"
        let parsed = parseVersion(fileStem: fileStem, releaseDirName: releaseDirName)
        let version = (effOpts.map { parsed.filteredBy($0) } ?? parsed).label
        return version.isEmpty ? head : "\(head) - \(version)"
    }

    /// 判定是否为 BDMV 蓝光原盘根目录（仅命名外层目录，保护内部 BDMV/CERTIFICATE 结构不动）。
    public static func isBdmvRoot(directChildDirNames: [String]) -> Bool {
        directChildDirNames.contains { $0.caseInsensitiveCompare("BDMV") == .orderedSame }
    }

    public static func isBdmvInternalPath(_ path: String) -> Bool {
        path.split { $0 == "/" || $0 == "\\" }.contains {
            $0.caseInsensitiveCompare("BDMV") == .orderedSame || $0.caseInsensitiveCompare("CERTIFICATE") == .orderedSame
        }
    }
}
