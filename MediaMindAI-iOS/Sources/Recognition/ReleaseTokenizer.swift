import Foundation

/// 1:1 逐行复刻自 Android `ReleaseTokenizer.kt`（85 行）：
/// 基于跨度占用掩码（Span-Occupancy Masking）的 Release 分词与技术标签清洗器，
/// 先定位并掩码不可变技术跨度（CRC32、分辨率、编码、音轨声道、流媒体平台、字幕组前缀、全集总数），
/// 从结构上杜绝 `1080`/`264`/`265`/`5.1`/`全32集` 被误判为集数或年份。
public enum ReleaseTokenizer {
    public struct MaskedResult: Sendable {
        public let original: String
        public let mask: [Bool]
        public let releaseGroup: String?
        public let streamingSource: String?
        public let totalEpisodesHint: Int?

        public init(original: String, mask: [Bool], releaseGroup: String?, streamingSource: String?, totalEpisodesHint: Int?) {
            self.original = original
            self.mask = mask
            self.releaseGroup = releaseGroup
            self.streamingSource = streamingSource
            self.totalEpisodesHint = totalEpisodesHint
        }

        public func unmaskedText() -> String {
            let chars = Array(original)
            var out = ""
            out.reserveCapacity(chars.count)
            for i in chars.indices {
                out.append((i < mask.count && mask[i]) ? " " : chars[i])
            }
            return out
        }
    }

    private static let crc32Regex = try? NSRegularExpression(pattern: #"[\[\(]([0-9A-Fa-f]{8})[\]\)]"#)
    private static let resRegex = try? NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9])(?:(?:480|576|720|1080|1440|2160|4320)[pi]|4K|8K|\d{3,4}[xX×]\d{3,4})(?![A-Za-z0-9])"#)
    private static let codecBitRegex = try? NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9])(?:[xh]\.?26[45]|HEVC|AVC|AV1|VP9|XviD|DivX|Hi10P?|10-?bit|8-?bit|Main10|HDR10\+?|HDR10|HDR|DoVi|DV)(?![A-Za-z0-9])"#)
    private static let audioChRegex = try? NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9])(?:TrueHD|Atmos|DTS[-. ]?HD[-. ]?MA|DTS[-:. ]?X|DTS[-. ]?HD|DTS|E-?AC-?3|EAC3|DDP|DD\+|DD|AC-?3|AAC|FLAC|L?PCM|OPUS|MP3)(?:[ .]?[1-9]\.[0-2])?(?![A-Za-z0-9])|(?<![0-9])[1-9]\.[0-2](?:ch)?(?![0-9])"#)
    private static let totalPackRegex = try? NSRegularExpression(pattern: #"(?i)(?:全|共)\s*(\d{1,4})\s*[集话話期]|(?<![A-Za-z])Complete(?:\s+Series)?(?![A-Za-z])"#)
    private static let streamingRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9])(NF|Netflix|AMZN|Amazon|DSNP|Disney\+|ATVP|AppleTV\+?|HMAX|MAX|HULU|Baha|Bahamut|Bilibili|B-Global|CR|Crunchyroll|iQIYI|IQ|Youku|WeTV|Tencent|MGTV|MangoTV|CCTV|KKTV|Viu|MYTV|FriDay|Hami)(?![A-Za-z0-9])"#
    )
    private static let subgroupBracketRegex = try? NSRegularExpression(pattern: #"^[\[\【]([^\]\】]{2,36})[\]\】]"#)
    private static let subgroupKeywordsRegex = try? NSRegularExpression(
        pattern: #"(?i)raws|sub|subs|studio|fansub|字幕|压制|搬运|汉化|动漫|番剧|官译|简繁|繁简|中字|人人|YYeTs|ANi|LoliHouse|VCB|Lilith|NC-Raws|SweetSub|Nekomoe|Sakurato|Kitauji|BeanSub|KTXP|DMHY|漫猫|澄空|幻樱|喵萌|桜都|诸神|极影|轻之国度|雪飘|天香|千夏|悠哈"#
    )
    private static let qualityBracketRegex = try? NSRegularExpression(
        pattern: #"[\[\【][^\]\】]*(?:1080|2160|720|4K|WEB|Blu-?Ray|REMUX|HEVC|AVC|H\.?26[45]|AAC|FLAC|DDP|HDR|DoVi|杜比|蓝光|原盘|国语|粤语|国英|简繁|中字|双语|多音轨|内封|外挂|特效|高码|无水印|完结|全\d+[集话期])[^\]\】]*[\]\】]"#,
        options: [.caseInsensitive]
    )

    public static func maskTechnicalSpans(_ stem: String) -> MaskedResult {
        let chars = Array(stem)
        var mask = Array(repeating: false, count: chars.count)
        let full = NSRange(stem.startIndex..<stem.endIndex, in: stem)

        func markNSRange(_ r: NSRange) {
            guard r.location != NSNotFound, let sr = Range(r, in: stem) else { return }
            let lo = stem.distance(from: stem.startIndex, to: sr.lowerBound)
            let hi = stem.distance(from: stem.startIndex, to: sr.upperBound)
            for i in max(0, lo)..<min(chars.count, hi) { mask[i] = true }
        }

        var totalHint: Int? = nil
        if let rx = totalPackRegex {
            for m in rx.matches(in: stem, range: full) {
                markNSRange(m.range)
                if totalHint == nil, m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound,
                   let r1 = Range(m.range(at: 1), in: stem) {
                    totalHint = Int(stem[r1])
                }
            }
        }
        for rx in [crc32Regex, resRegex, codecBitRegex, audioChRegex].compactMap({ $0 }) {
            for m in rx.matches(in: stem, range: full) { markNSRange(m.range) }
        }

        var source: String? = nil
        if let rx = streamingRegex {
            for m in rx.matches(in: stem, range: full) {
                if source == nil, let r1 = Range(m.range(at: 1), in: stem) {
                    source = String(stem[r1])
                }
                if m.range.location > 0 { markNSRange(m.range) }
            }
        }

        var group: String? = nil
        if let rx = subgroupBracketRegex, let m = rx.firstMatch(in: stem, range: full),
           let r0 = Range(m.range, in: stem), let r1 = Range(m.range(at: 1), in: stem) {
            let inside = String(stem[r1]).trimmingCharacters(in: .whitespaces)
            let rest = String(stem[r0.upperBound...]).trimmingCharacters(in: .whitespaces)
            let hasKw = subgroupKeywordsRegex?.firstMatch(in: inside, range: NSRange(inside.startIndex..<inside.endIndex, in: inside)) != nil
            if hasKw || ((2...20).contains(inside.count) && !inside.allSatisfy(\.isNumber) && !rest.isEmpty) {
                group = inside
                markNSRange(m.range)
            }
        }
        if let rx = qualityBracketRegex {
            for m in rx.matches(in: stem, range: full) { markNSRange(m.range) }
        }

        return MaskedResult(original: stem, mask: mask, releaseGroup: group, streamingSource: source, totalEpisodesHint: totalHint)
    }

    public static func stripNoiseForTitle(_ stem: String) -> String {
        maskTechnicalSpans(stem).unmaskedText()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
    }
}
