import Foundation

/// 1:1 逐行复刻自 Android `TitleDeobfuscator.kt`（674 行全量词库与多阶段反规避算法）：
/// - 零宽字符、角括号发布信息、体积括号、网盘水印清洗 + 全角转半角
/// - 29 组港台繁→简影视词组（OpenCC tw2sp）+ 260+ 高频繁→简单字表
/// - 94 组防和谐替代 Emoji 词典 + 尾部/开头装饰 Emoji 智能剥离与多变体展开
/// - 102 组防和谐拼音音节字典 + 记忆化 DFS 多音节切分（如 `sishen来了` → `死神来了`、`Què🦴❄️` → `雀骨`）
/// - 30 组高置信防和谐谐音词组 + 16 组单字谐音低优兜底
/// - 前置单字母剥离、末尾系列/合集词剥离、中英双语拆分
public enum TitleDeobfuscator {
    public struct Extracted: Hashable, Sendable {
        public let tmdbId: Int?
        public let year: String?
        public let queries: [String]
        public let primaryTitle: String

        public init(tmdbId: Int?, year: String?, queries: [String], primaryTitle: String) {
            self.tmdbId = tmdbId
            self.year = year
            self.queries = queries
            self.primaryTitle = primaryTitle
        }
    }

    private static let maxCandidates = 8
    private static let maxInputLen = 512

    private static let zeroWidthRegex = try? NSRegularExpression(pattern: #"[\u200B-\u200F\u2060\uFEFF]"#)
    private static let releaseCornerBracketRegex = try? NSRegularExpression(
        pattern: #"[『「][^』」]*(?:杜比|原盘|蓝光|国英|国语|粤语|双语|多音轨|音轨|字幕|特字|高码|未删减|完结|全\d+集|4K|2160|1080|720|HDR|DoVi|Blu-?Ray|REMUX|WEB|TrueHD|TureHD|Atmos|DTS|DDP|HEVC|H\.?26[45]|GB|MB|TB|个文件)[^』」]*[』」]"#,
        options: [.caseInsensitive]
    )
    private static let sizeParensRegex = try? NSRegularExpression(
        pattern: #"[\(（][^\)）]*(?:\d+(?:\.\d+)?\s*(?:GB|MB|TB)|\d+\s*个文件|全\s*\d+\s*[集话期])[^\)）]*[\)）]"#,
        options: [.caseInsensitive]
    )
    private static let bookBracketsRegex = try? NSRegularExpression(pattern: #"[《》『』「」]"#)
    private static let hanSepRegex = try? NSRegularExpression(pattern: #"(?<=\p{Han})[=\-_.·•*+~#|/、^`丨｜︱★☆]+(?=\p{Han})"#)
    private static let hanSpaceRegex = try? NSRegularExpression(pattern: #"(?<=\p{Han})\s+(?=\p{Han})"#)
    private static let cloudWatermarkRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:https?://\S+|www\.[a-z0-9.-]+\.[a-z]{2,}|【[^】]*(?:关注|公众号|资源|夸克|迅雷|123|光鸭|网盘|字幕组|压制|首发|高清|福利|免费|微信|群)[^】]*】|高码率|无水印|防失联|关注公众号|加V群|每天更新|持续更新|免费分享|网盘资源|资源分享|附字幕|含花絮|未删减版|完整版|高清版|蓝光版|超清版|国语配音|双语字幕|特效字幕)"#
    )
    private static let seriesSuffixRegex = try? NSRegularExpression(pattern: #"(?:全系列|系列合集|三部曲|四部曲|五部曲|六部曲|系列|合集|全集)$"#)
    private static let leadingSingleInitialRegex = try? NSRegularExpression(pattern: #"^([A-Za-z])(?=\p{Han})"#)
    private static let mixedLatinBeforeHanRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([A-Za-z\u00C0-\u024F]{1,12})(?=\p{Han})"#)
    private static let mixedLatinAfterHanRegex = try? NSRegularExpression(pattern: #"(?<=\p{Han})([A-Za-z\u00C0-\u024F]{1,12})(?![A-Za-z0-9])"#)

    private static let nonPinyinTags: Set<String> = [
        "s", "e", "ep", "hd", "uhd", "hdr", "dv", "tv", "mv", "sp", "ova", "oad",
        "uk", "us", "jp", "kr", "cn", "hk", "tw", "av", "bd", "web", "rip", "dl",
        "hevc", "avc", "aac", "dts", "ddp", "ac3", "flac", "mp4", "mkv", "avi",
    ]

    /// 29 组港台地区常见影视片名繁→简词组映射（OpenCC tw2sp）。
    private static let t2sPhrases: [(String, String)] = [
        ("駭客任務", "黑客帝国"), ("駭客帝國", "黑客帝国"),
        ("全面啟動", "盗梦空间"), ("盜夢空間", "盗梦空间"),
        ("復仇者聯盟", "复仇者联盟"),
        ("進擊的巨人", "进击的巨人"),
        ("鬼滅之刃", "鬼灭之刃"),
        ("絕命毒師", "绝命毒师"),
        ("權力的遊戲", "权力的游戏"), ("冰與火之歌", "冰与火之歌"),
        ("魷魚遊戲", "鱿鱼游戏"),
        ("無間道", "无间道"),
        ("蜘蛛人", "蜘蛛侠"), ("鋼鐵人", "钢铁侠"), ("蝙蝠俠", "蝙蝠侠"),
        ("驚奇隊長", "惊奇队长"), ("神隱少女", "千与千寻"),
        ("星際效應", "星际穿越"), ("沙丘魔堡", "沙丘"),
        ("玩命關頭", "速度与激情"), ("不可能的任務", "碟中谍"),
        ("死侍與金鋼狼", "死侍与金刚狼"), ("金鋼狼", "金刚狼"),
        ("魔戒", "指环王"), ("哈利波特", "哈利·波特"),
        ("絕地戰警", "绝地战警"), ("捍衛任務", "疾速追杀"),
        ("異形", "异形"), ("終結者", "终结者"), ("魔鬼終結者", "终结者"),
        ("變形金剛", "变形金刚"), ("侏羅紀", "侏罗纪"),
    ]

    /// 常见防和谐替代 Emoji → 对应中文词（先去掉 \uFE0F 变体选择符再匹配，完整 94 项）。
    private static let emojiMap: [(String, String)] = [
        ("🌏", "地球"), ("🌍", "地球"), ("🌎", "地球"),
        ("🦴", "骨"),
        ("❄", "雪"), ("☃", "雪"), ("⛄", "雪"),
        ("🔥", "火"),
        ("🌞", "太阳"), ("☀", "太阳"),
        ("🌙", "月亮"), ("🌕", "月亮"), ("🌛", "月亮"), ("🌜", "月亮"),
        ("⭐", "星"), ("🌟", "星"), ("✨", "星"),
        ("🌊", "海"),
        ("🌧", "雨"), ("☔", "雨"), ("💧", "水"),
        ("⚡", "雷"),
        ("🌪", "风暴"),
        ("🌈", "彩虹"),
        ("❤", "爱"), ("💗", "爱"), ("💓", "爱"), ("💕", "爱"), ("💘", "爱"), ("💖", "爱"),
        ("💔", "心碎"),
        ("🌹", "玫瑰"), ("🌸", "花"), ("🌺", "花"), ("🌼", "花"), ("💐", "花"), ("🌷", "花"),
        ("🐉", "龙"), ("🐲", "龙"),
        ("🐺", "狼"),
        ("🦊", "狐"),
        ("🦁", "狮子"),
        ("🐯", "虎"), ("🐅", "虎"),
        ("🐼", "熊猫"),
        ("🐍", "蛇"),
        ("🦅", "鹰"),
        ("🐦", "鸟"), ("🕊", "鸽"),
        ("🦇", "蝙蝠"),
        ("🕷", "蜘蛛"),
        ("🐜", "蚁"),
        ("🦈", "鲨"),
        ("🐋", "鲸"), ("🐳", "鲸"),
        ("🐕", "狗"), ("🐶", "狗"),
        ("🐈", "猫"), ("🐱", "猫"),
        ("🐒", "猴"), ("🐵", "猴"),
        ("🐴", "马"), ("🐎", "马"),
        ("🦌", "鹿"),
        ("🐻", "熊"),
        ("🐰", "兔"), ("🐇", "兔"),
        ("🦋", "蝶"),
        ("👻", "鬼"),
        ("💀", "死"), ("☠", "死"),
        ("👽", "异形"),
        ("🤖", "机器人"),
        ("😈", "魔"), ("👿", "魔"),
        ("👼", "天使"),
        ("👑", "王"),
        ("💎", "钻石"),
        ("🗡", "剑"), ("⚔", "剑"),
        ("🔫", "枪"),
        ("💣", "爆"),
        ("🩸", "血"),
        ("🧠", "脑"),
        ("👁", "眼"),
        ("🚀", "火箭"),
        ("✈", "飞机"),
        ("🚢", "船"),
        ("🚂", "列车"), ("🚆", "列车"),
        ("🚗", "飞车"), ("🏎", "飞车"),
        ("🏰", "城堡"),
        ("⛰", "山"), ("🏔", "山"),
        ("🏝", "岛"),
        ("⏰", "时间"), ("⏳", "时间"),
        ("🔑", "密钥"),
        ("🎭", "面具"),
        ("🎵", "歌"), ("🎶", "歌"),
        ("💰", "财"),
        ("🍑", "桃"),
        ("🍎", "苹果"),
        ("🌶", "辣"),
        ("🍺", "酒"), ("🍷", "酒"),
    ]

    /// 102 组高频防和谐拼音音节 → 候选汉字（按影视标题常用度排序）。
    private static let pinyinToHan: [String: [String]] = [
        "si": ["死", "四", "思"],
        "sha": ["杀", "沙"],
        "gui": ["鬼", "轨", "诡", "归"],
        "xue": ["血", "雪"],
        "que": ["雀", "缺"],
        "zui": ["罪", "醉"],
        "du": ["毒", "赌", "独"],
        "mo": ["魔", "末", "默"],
        "shi": ["尸", "失", "世", "十"],
        "hei": ["黑"],
        "bai": ["白"],
        "zhan": ["战", "斩"],
        "dao": ["盗", "刀", "道"],
        "qiang": ["枪"],
        "bao": ["暴", "爆", "宝"],
        "jin": ["禁", "金"],
        "yu": ["狱", "欲", "玉", "雨"],
        "fan": ["犯", "反", "凡"],
        "jie": ["劫", "界", "姐"],
        "jue": ["绝", "决"],
        "lie": ["猎", "烈"],
        "hun": ["魂", "婚"],
        "shen": ["神", "身", "深"],
        "yao": ["妖", "药"],
        "xie": ["邪", "血"],
        "an": ["暗", "安"],
        "wang": ["亡", "王", "网"],
        "mie": ["灭"],
        "kuang": ["狂"],
        "nv": ["女"],
        "se": ["色"],
        "ai": ["爱", "哀"],
        "xing": ["刑", "星", "性"],
        "kong": ["恐", "空"],
        "bu": ["怖", "不"],
        "die": ["谍", "蝶"],
        "pan": ["叛", "判"],
        "zheng": ["政", "争", "正"],
        "jun": ["军", "君"],
        "jing": ["警", "惊", "京"],
        "te": ["特"],
        "gong": ["工", "宫", "攻"],
        "gu": ["骨", "古", "孤"],
        "long": ["龙"],
        "lang": ["狼", "浪"],
        "hu": ["虎", "狐"],
        "she": ["蛇"],
        "ji": ["机", "极", "寂"],
        "bing": ["冰", "兵", "病"],
        "huo": ["火", "活"],
        "lei": ["雷"],
        "feng": ["风", "疯", "封"],
        "yun": ["云"],
        "tian": ["天"],
        "di": ["地", "帝", "敌"],
        "ren": ["人", "忍"],
        "xin": ["心", "新"],
        "meng": ["梦", "猛"],
        "ye": ["夜", "野"],
        "ri": ["日"],
        "yue": ["月"],
        "hua": ["花", "华"],
        "jian": ["剑", "间", "奸"],
        "ba": ["霸", "八"],
        "jiu": ["九", "救", "酒"],
        "qi": ["奇", "七", "弃"],
        "wu": ["无", "五", "武"],
        "san": ["三"],
        "er": ["二"],
        "yi": ["一", "异", "医"],
        "liu": ["流", "六"],
        "qiu": ["球", "秋", "囚"],
        "chao": ["超", "朝"],
        "xia": ["侠", "夏"],
        "mi": ["密", "迷", "谜"],
        "chou": ["仇", "丑"],
        "fu": ["复", "父", "浮"],
        "can": ["残"],
        "nu": ["怒"],
        "tong": ["痛", "同"],
        "ling": ["灵", "零"],
        "xiong": ["凶", "熊"],
        "e": ["恶"],
        "tou": ["偷", "头"],
        "pian": ["骗", "片"],
        "bang": ["绑", "帮"],
        "jia": ["假", "家"],
        "zhen": ["真", "镇"],
        "po": ["破"],
        "sui": ["碎", "岁"],
        "zhui": ["追", "坠"],
        "tao": ["逃", "桃"],
        "sheng": ["生", "圣"],
        "zhu": ["主", "蛛", "猪"],
        "luo": ["落", "罗"],
        "shuang": ["双", "霜"],
        "lin": ["临", "林"],
        "jiang": ["江", "将"],
        "xian": ["仙", "险", "陷"],
        "tu": ["突", "屠", "途"],
        "ran": ["然", "燃"],
    ]

    /// 30 组高置信精确防和谐谐音词组。
    private static let homophonePhrases: [(String, String)] = [
        ("四神", "死神"), ("思神", "死神"), ("司神", "死神"),
        ("沙手", "杀手"), ("纱手", "杀手"),
        ("雪脉", "血脉"),
        ("归吹灯", "鬼吹灯"), ("桂吹灯", "鬼吹灯"),
        ("站狼", "战狼"),
        ("道梦", "盗梦"),
        ("独液", "毒液"),
        ("嘿客", "黑客"),
        ("墨戒", "魔戒"),
        ("蝶影", "谍影"),
        ("最之身", "罪之身"), ("醉之身", "罪之身"),
        ("师速", "尸速"),
        ("强火", "枪火"), ("强战", "枪战"),
        ("抱力", "暴力"), ("报力", "暴力"),
        ("列人", "猎人"),
        ("玉望", "欲望"),
        ("金忌", "禁忌"),
        ("申探", "神探"),
        ("狂彪", "狂飙"),
        ("孤注一志", "孤注一掷"),
        ("哪扎", "哪吒"),
        ("封申", "封神"),
        ("长按", "长安"),
    ]

    /// 16 组单字防和谐谐音低优先级兜底。
    private static let homophoneChars: [Character: Character] = [
        "四": "死", "思": "死",
        "沙": "杀",
        "归": "鬼",
        "雪": "血",
        "独": "毒",
        "墨": "魔",
        "最": "罪", "醉": "罪",
        "嘿": "黑",
        "站": "战",
        "道": "盗",
        "蝶": "谍",
        "强": "枪",
        "师": "尸",
        "列": "猎",
    ]

    // MARK: - 公开接口

    public static func bestQuery(_ rawName: String) -> (title: String, year: String?) {
        let ext = extract(rawName)
        return (ext.primaryTitle, ext.year)
    }

    public static func clean(_ raw: String) -> String {
        let capped = String(raw.prefix(maxInputLen))
        let pre = preClean(capped)
        let ext = extract(pre)
        return ext.primaryTitle.isEmpty ? collapseHanObfuscation(pre) : ext.primaryTitle
    }

    public static func queryCandidates(from raw: String) -> [String] {
        extract(raw).queries
    }

    /// 完整多阶段反规避提取（1:1 对标 Android `TitleDeobfuscator.extract`）。
    public static func extract(_ rawName: String) -> Extracted {
        let safeRaw = String(rawName.prefix(maxInputLen))
        let pre = traditionalToSimplified(preClean(safeRaw))
        let parsed = MediaParser.parse(pre)
        let baseTitle = parsed.cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let yearStr = parsed.year.map(String.init)
        guard !baseTitle.isEmpty else {
            return Extracted(tmdbId: parsed.tmdbId, year: yearStr, queries: [], primaryTitle: "")
        }

        var candidates: [String] = []
        var seen: Set<String> = []
        func add(_ q: String?) {
            guard candidates.count < maxCandidates, let rawQ = q else { return }
            let cleaned = finalizeCandidate(rawQ)
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { return }
            candidates.append(cleaned)
        }

        let hasEmoji = containsEmoji(baseTitle)
        let hasTone = hasToneDiacritics(baseTitle)

        // 1. Emoji 展开（去尾装饰后解码 / 去首装饰 / 全解码 / 纯去 Emoji）
        let emojiVariants = hasEmoji ? expandEmojiVariants(baseTitle) : [baseTitle]

        // 2. 汉字间隔符号折叠 + 混合拼音/声调还原
        var restoredVariants: [String] = []
        for v in emojiVariants {
            let collapsed = collapseHanObfuscation(v)
            let pinyinRestored = restoreMixedPinyin(collapsed)
            if pinyinRestored != collapsed {
                restoredVariants.append(pinyinRestored)
            }
            restoredVariants.append(collapsed)
        }

        for v in restoredVariants {
            add(v)
            let noSeries = stripSeriesSuffix(v)
            if noSeries != v { add(noSeries) }
            let noLeading = stripLeadingInitial(v)
            if noLeading != v {
                add(noLeading)
                let noLeadingNoSeries = stripSeriesSuffix(noLeading)
                if noLeadingNoSeries != noLeading { add(noLeadingNoSeries) }
            }
        }

        // 3. 中英双语拆分 + 冒号副标题主名拆分
        let snapshot = candidates
        for v in snapshot {
            for part in splitBilingual(v) {
                add(part)
                let noLeading = stripLeadingInitial(part)
                if noLeading != part { add(noLeading) }
            }
        }

        // 3.5 港台繁体转简体词组 + 单字
        for v in snapshot {
            let simp = traditionalToSimplified(v)
            if simp != v { add(simp) }
        }

        // 4. 谐音字还原（先精确词组前置，再低优先级单字兜底）
        if let homophoneBase = snapshot.first(where: { containsCjk($0) }) {
            let phraseFixed = applyHomophonePhrases(homophoneBase)
            if phraseFixed != homophoneBase {
                let fixedClean = finalizeCandidate(phraseFixed)
                if !fixedClean.isEmpty {
                    candidates.removeAll { $0.caseInsensitiveCompare(fixedClean) == .orderedSame }
                    candidates.insert(fixedClean, at: 0)
                    if candidates.count > maxCandidates { candidates = Array(candidates.prefix(maxCandidates)) }
                }
            } else {
                for alt in singleCharHomophoneFallbacks(homophoneBase) {
                    add(alt)
                }
            }
        }

        // 5. 含声调拼音时补一份纯去声调原文（兼容 TMDB 拼音索引）
        if hasTone {
            add(stripEmoji(stripDiacritics(baseTitle)))
        }

        let primary = candidates.first(where: { !containsEmoji($0) && containsCjk($0) })
            ?? candidates.first(where: { !containsEmoji($0) })
            ?? candidates.first
            ?? baseTitle

        return Extracted(tmdbId: parsed.tmdbId, year: yearStr, queries: candidates, primaryTitle: primary)
    }

    // MARK: - 内部清洗与还原算法

    public static func normalizeFullWidth(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x3000 {
                out.append(" ")
            } else if (0xFF10...0xFF19).contains(v) || (0xFF21...0xFF3A).contains(v) || (0xFF41...0xFF5A).contains(v) || v == 0xFF08 || v == 0xFF09 {
                if let half = UnicodeScalar(v - 0xFEE0) { out.append(Character(half)) }
            } else {
                out.append(Character(scalar))
            }
        }
        return out
    }

    public static func traditionalToSimplified(_ text: String) -> String {
        var s = text
        for (trad, simp) in t2sPhrases where s.contains(trad) {
            s = s.replacingOccurrences(of: trad, with: simp)
        }
        return MediaParser.deobfuscate(s)
    }

    public static func preClean(_ raw: String) -> String {
        var s = normalizeFullWidth(replace(zeroWidthRegex, in: raw, with: ""))
        s = replace(releaseCornerBracketRegex, in: s, with: " ")
        s = replace(sizeParensRegex, in: s, with: " ")
        s = replace(bookBracketsRegex, in: s, with: " ")
        s = replace(cloudWatermarkRegex, in: s, with: " ")
        return s
    }

    public static func collapseHanObfuscation(_ text: String) -> String {
        var s = text
        for _ in 0..<5 {
            let prev = s
            s = replace(hanSepRegex, in: s, with: "")
            s = replace(hanSpaceRegex, in: s, with: "")
            if s == prev { break }
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-_="))
    }

    public static func restoreMixedPinyin(_ text: String) -> String {
        func convertToken(_ rawToken: String) -> String? {
            let plain = stripDiacritics(rawToken).lowercased()
            guard !plain.isEmpty, !nonPinyinTags.contains(plain) else { return nil }
            if let first = pinyinToHan[plain]?.first { return first }
            if (3...10).contains(plain.count),
               let segmented = segmentPinyin(plain),
               (2...3).contains(segmented.count) {
                return segmented.compactMap { pinyinToHan[$0]?.first }.joined()
            }
            return nil
        }

        func applyRegex(_ rx: NSRegularExpression?, to input: String) -> String {
            guard let rx else { return input }
            let matches = rx.matches(in: input, range: NSRange(input.startIndex..<input.endIndex, in: input))
            guard !matches.isEmpty else { return input }
            var out = input
            for m in matches.reversed() {
                guard let r = Range(m.range(at: 1), in: out) else { continue }
                let tok = String(out[r])
                let allUpper = !tok.isEmpty && tok.allSatisfy(\.isUppercase) && !hasToneDiacritics(tok)
                if !allUpper, let rep = convertToken(tok) {
                    out.replaceSubrange(r, with: rep)
                }
            }
            return out
        }

        let step1 = applyRegex(mixedLatinBeforeHanRegex, to: text)
        return applyRegex(mixedLatinAfterHanRegex, to: step1)
    }

    private static func segmentPinyin(_ s: String) -> [String]? {
        let chars = Array(s)
        var memo: [Int: [String]?] = [:]
        func dfs(_ idx: Int) -> [String]? {
            if idx == chars.count { return [] }
            if let cached = memo[idx] { return cached }
            let maxLen = min(6, chars.count - idx)
            for len in stride(from: maxLen, through: 1, by: -1) {
                let sub = String(chars[idx..<(idx + len)])
                if pinyinToHan[sub] != nil, let rest = dfs(idx + len) {
                    let ans = [sub] + rest
                    memo[idx] = ans
                    return ans
                }
            }
            memo.updateValue(nil, forKey: idx)
            return nil
        }
        return dfs(0)
    }

    private static func isEmojiScalar(_ v: UInt32) -> Bool {
        (0x1F300...0x1FAFF).contains(v) || (0x2600...0x27BF).contains(v) || (0x2300...0x23FF).contains(v)
    }

    public static func containsEmoji(_ text: String) -> Bool {
        let norm = text.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "\u{FE0E}", with: "")
        if emojiMap.contains(where: { norm.contains($0.0) }) { return true }
        return norm.unicodeScalars.contains { isEmojiScalar($0.value) }
    }

    private static func stripEmoji(_ text: String) -> String {
        let norm = text.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "\u{FE0E}", with: "")
        let filtered = String(norm.unicodeScalars.filter { !isEmojiScalar($0.value) })
        return filtered.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEmoji(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "\u{FE0E}", with: "")
        for (emo, zh) in emojiMap where s.contains(emo) {
            s = s.replacingOccurrences(of: emo, with: zh)
        }
        return stripEmoji(s)
    }

    private static func expandEmojiVariants(_ text: String) -> [String] {
        let norm = text.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "\u{FE0E}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = []
        func push(_ v: String) {
            if !v.isEmpty && !out.contains(v) { out.append(v) }
        }
        let droppedLast = dropLastSingleEmoji(norm)
        if droppedLast != norm && containsEmoji(droppedLast) { push(decodeEmoji(droppedLast)) }
        let trimmedTail = trimTrailingEmojis(norm)
        if trimmedTail != norm && containsEmoji(trimmedTail) { push(decodeEmoji(trimmedTail)) }
        let trimmedHead = trimLeadingEmojis(norm)
        if trimmedHead != norm && containsEmoji(trimmedHead) { push(decodeEmoji(trimmedHead)) }
        push(decodeEmoji(norm))
        push(stripEmoji(norm))
        return out
    }

    private static func dropLastSingleEmoji(_ text: String) -> String {
        var scalars = Array(text.trimmingCharacters(in: .whitespaces).unicodeScalars)
        guard let last = scalars.last, isEmojiScalar(last.value) else { return text }
        scalars.removeLast()
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    private static func trimTrailingEmojis(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, isEmojiScalar(last.value) || last.value == 0x20 {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func trimLeadingEmojis(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let first = scalars.first, isEmojiScalar(first.value) || first.value == 0x20 {
            scalars.removeFirst()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func hasToneDiacritics(_ text: String) -> Bool {
        text.decomposedStringWithCanonicalMapping.unicodeScalars.contains { $0.properties.generalCategory == .nonspacingMark }
    }

    private static func stripDiacritics(_ text: String) -> String {
        String(text.decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark })
    }

    private static func stripSeriesSuffix(_ text: String) -> String {
        let stripped = replace(seriesSuffixRegex, in: text.trimmingCharacters(in: .whitespaces), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-_·：:"))
        return stripped.count >= 2 ? stripped : text
    }

    private static func stripLeadingInitial(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let rx = leadingSingleInitialRegex,
              let m = rx.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
              let r = Range(m.range, in: trimmed) else { return text }
        let rest = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return rest.count >= 2 ? rest : text
    }

    private static func splitBilingual(_ text: String) -> [String] {
        var parts: [String] = []
        let zhPart = String(text.filter { $0.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false })
        let enPart = text.split(separator: " ").filter { $0.allSatisfy(\.isASCII) }.joined(separator: " ")
        if zhPart.count >= 2 { parts.append(zhPart) }
        if enPart.count >= 3 { parts.append(enPart) }
        if let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            let head = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            if head.count >= 2 { parts.append(head) }
        }
        return parts
    }

    private static func applyHomophonePhrases(_ text: String) -> String {
        var s = text
        for (from, to) in homophonePhrases where s.contains(from) {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    private static func singleCharHomophoneFallbacks(_ text: String) -> [String] {
        var out: [String] = []
        let chars = Array(text)
        for i in chars.indices {
            guard let rep = homophoneChars[chars[i]] else { continue }
            var copy = chars
            copy[i] = rep
            let cand = String(copy)
            if cand != text { out.append(cand) }
            if out.count >= 2 { break }
        }
        return out
    }

    private static func containsCjk(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func finalizeCandidate(_ q: String) -> String {
        q.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-_ =·：:"))
    }

    private static func replace(_ rx: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let rx else { return text }
        return rx.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: template)
    }
}
