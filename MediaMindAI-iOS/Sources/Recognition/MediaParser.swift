import Foundation

public struct ParsedMedia: Sendable, Equatable {
    public let rawName: String
    public let cleanTitle: String
    public let year: Int?
    public let season: Int?
    public let episode: Int?
    public let episodeEnd: Int?
    public let isTvHint: Bool
    public let imdbId: String?
    public let tmdbId: Int?
    public let tvdbId: Int?
    public let resolution: String?
    public let edition: String?

    public init(
        rawName: String, cleanTitle: String, year: Int? = nil, season: Int? = nil,
        episode: Int? = nil, episodeEnd: Int? = nil, isTvHint: Bool = false,
        imdbId: String? = nil, tmdbId: Int? = nil, tvdbId: Int? = nil,
        resolution: String? = nil, edition: String? = nil
    ) {
        self.rawName = rawName; self.cleanTitle = cleanTitle; self.year = year
        self.season = season; self.episode = episode; self.episodeEnd = episodeEnd
        self.isTvHint = isTvHint; self.imdbId = imdbId; self.tmdbId = tmdbId
        self.tvdbId = tvdbId; self.resolution = resolution; self.edition = edition
    }
}

/// 影视名称去混淆、分词、番剧集数/多集范围、外链 ID、版本标签与相似度评分管线（对标 Android TitleDeobfuscator + ReleaseTokenizer + AnimeEpisodeParser + EpisodeRangeParser + ExternalIdExtractor + EditionParser + TitleScorer + Naming）。
public enum MediaParser {
    public static let videoExts: Set<String> = ["mkv", "mp4", "avi", "mov", "wmv", "flv", "ts", "m2ts", "rmvb", "webm", "m4v", "iso"]
    public static let subtitleExts: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup"]
    public static let ignoredDirs: Set<String> = ["eaDir", "@eaDir", "#recycle", ".Trashes", "BDMV", "CERTIFICATE", "Subs", "Subtitles", "Featurettes", "Extras"]

    private static let t2sMap: [Character: Character] = [
        "劇": "剧", "國": "国", "語": "语", "雙": "双", "簡": "简", "體": "体", "藍": "蓝", "盤": "盘",
        "無": "无", "刪": "删", "減": "减", "導": "导", "輯": "辑", "終": "终", "極": "极", "傳": "传",
        "說": "说", "記": "记", "錄": "录", "龍": "龙", "鳳": "凤", "風": "风", "雲": "云", "愛": "爱",
        "夢": "梦", "戰": "战", "爭": "争", "滅": "灭", "絕": "绝", "聖": "圣", "靈": "灵", "劍": "剑",
        "俠": "侠", "盜": "盗", "賊": "贼", "際": "际", "機": "机", "關": "关", "門": "门", "開": "开",
        "見": "见", "車": "车", "馬": "马", "魚": "鱼", "鳥": "鸟", "點": "点", "線": "线", "網": "网",
        "鐵": "铁", "銀": "银", "銅": "铜", "鐘": "钟", "鏡": "镜", "長": "长", "閃": "闪", "電": "电",
        "飛": "飞", "頭": "头", "顏": "颜", "題": "题", "館": "馆", "餘": "余", "驅": "驱", "萬": "万",
        "與": "与", "專": "专", "業": "业", "東": "东", "絲": "丝", "兩": "两", "嚴": "严", "喪": "丧",
        "個": "个", "豐": "丰", "臨": "临", "為": "为", "麗": "丽", "舉": "举", "義": "义", "樂": "乐",
        "書": "书", "買": "买", "亂": "乱", "亞": "亚", "產": "产", "親": "亲", "億": "亿", "從": "从",
        "優": "优", "會": "会", "偉": "伟", "傷": "伤", "價": "价", "兒": "儿", "黨": "党", "蘭": "兰",
        "興": "兴", "軍": "军", "農": "农", "決": "决", "況": "况", "凍": "冻", "淨": "净", "劉": "刘",
        "則": "则", "創": "创", "動": "动", "務": "务", "勝": "胜", "勢": "势", "華": "华", "協": "协",
        "單": "单", "賣": "卖", "衛": "卫", "卻": "却", "廠": "厂", "廳": "厅", "歷": "历", "厲": "厉",
        "壓": "压", "厭": "厌", "參": "参", "發": "发", "變": "变", "號": "号", "聽": "听", "啟": "启",
        "吳": "吴", "員": "员", "響": "响", "啞": "哑", "團": "团", "園": "园", "圍": "围", "圖": "图",
        "圓": "圆", "場": "场", "壞": "坏", "塊": "块", "堅": "坚", "報": "报", "聲": "声", "處": "处",
        "備": "备", "復": "复", "夠": "够", "奪": "夺", "獎": "奖", "奧": "奥", "婦": "妇", "媽": "妈",
        "學": "学", "實": "实", "審": "审", "寫": "写", "寬": "宽", "寶": "宝", "將": "将", "尋": "寻",
        "對": "对", "層": "层", "歲": "岁", "島": "岛", "嶺": "岭", "幣": "币", "師": "师", "帳": "帐",
        "帶": "带", "幫": "帮", "廣": "广", "莊": "庄", "慶": "庆", "庫": "库", "應": "应", "張": "张",
        "強": "强", "彈": "弹", "歸": "归", "當": "当", "後": "后", "徵": "征", "徹": "彻", "憶": "忆",
        "憂": "忧", "懷": "怀", "態": "态", "總": "总", "戀": "恋", "惡": "恶", "驚": "惊", "戲": "戏",
        "戶": "户", "護": "护", "擬": "拟", "擁": "拥", "擇": "择", "擊": "击", "擔": "担", "據": "据",
        "擠": "挤", "換": "换", "損": "损", "搖": "摇", "敵": "敌", "數": "数", "斷": "断", "時": "时",
        "術": "术", "殺": "杀", "雜": "杂", "權": "权", "條": "条", "來": "来", "楊": "杨", "傑": "杰",
        "構": "构", "槍": "枪", "樣": "样", "檔": "档", "橋": "桥", "檢": "检", "歡": "欢", "歐": "欧",
        "殲": "歼", "殘": "残", "毀": "毁", "畢": "毕", "氣": "气", "漢": "汉", "湯": "汤", "溫": "温",
        "滿": "满", "澤": "泽", "濟": "济", "濤": "涛", "濱": "滨", "灘": "滩", "灣": "湾", "災": "灾",
        "煉": "炼", "熱": "热", "營": "营", "爺": "爷", "爾": "尔", "牆": "墙", "猶": "犹", "獄": "狱",
        "獅": "狮", "獨": "独", "獵": "猎", "獸": "兽", "獻": "献", "環": "环", "現": "现", "畫": "画",
        "異": "异", "瘋": "疯", "盡": "尽", "監": "监", "盧": "卢", "眾": "众", "確": "确", "碼": "码",
        "禮": "礼", "離": "离", "種": "种", "稱": "称", "穩": "稳", "窮": "穷", "竊": "窃", "競": "竞",
        "筆": "笔", "築": "筑", "籌": "筹", "紅": "红", "約": "约", "級": "级", "紀": "纪", "純": "纯",
        "紙": "纸", "紛": "纷", "細": "细", "組": "组", "結": "结", "統": "统", "經": "经", "綜": "综",
        "綠": "绿", "維": "维", "緊": "紧", "練": "练", "織": "织", "繞": "绕", "繪": "绘", "繼": "继",
        "續": "续", "羅": "罗", "罰": "罚", "罵": "骂", "罷": "罢", "習": "习", "聯": "联", "職": "职",
        "肅": "肃", "腦": "脑", "脫": "脱", "臉": "脸", "臘": "腊", "臺": "台", "舊": "旧", "艦": "舰",
        "艙": "舱", "藝": "艺", "節": "节", "範": "范", "榮": "荣", "藥": "药", "葉": "叶", "著": "着",
        "蘇": "苏", "虧": "亏", "蟲": "虫", "蝕": "蚀", "補": "补", "裝": "装", "裏": "里", "製": "制",
        "複": "复", "襲": "袭", "觀": "观", "規": "规", "視": "视", "覽": "览", "覺": "觉", "觸": "触",
        "計": "计", "訂": "订", "認": "认", "討": "讨", "讓": "让", "訓": "训", "議": "议", "講": "讲",
        "許": "许", "論": "论", "設": "设", "訪": "访", "證": "证", "評": "评", "識": "识", "訴": "诉",
        "詞": "词", "譯": "译", "試": "试", "詩": "诗", "話": "话", "該": "该", "詳": "详", "誤": "误",
        "請": "请", "諸": "诸", "諾": "诺", "讀": "读", "課": "课", "誰": "谁", "調": "调", "談": "谈",
        "謀": "谋", "謎": "谜", "謝": "谢", "謹": "谨", "譜": "谱", "譽": "誉", "讚": "赞", "負": "负",
        "財": "财", "貢": "贡", "貧": "贫", "貨": "货", "販": "贩", "貪": "贪", "貫": "贯", "責": "责",
        "貴": "贵", "貸": "贷", "費": "费", "貼": "贴", "賀": "贺", "賈": "贾", "資": "资", "賞": "赏",
        "賜": "赐", "賠": "赔", "賴": "赖", "賺": "赚", "賽": "赛", "贊": "赞", "贏": "赢", "趕": "赶",
        "趙": "赵", "趨": "趋", "跡": "迹", "躍": "跃", "軒": "轩", "軟": "软", "較": "较", "載": "载",
        "輔": "辅", "輕": "轻", "輛": "辆", "輝": "辉", "輩": "辈", "輪": "轮", "輸": "输", "轉": "转",
        "轟": "轰", "辭": "辞", "辯": "辩", "邊": "边", "達": "达", "違": "违", "遙": "遥", "遜": "逊",
        "遠": "远", "適": "适", "遲": "迟", "遷": "迁", "選": "选", "遺": "遗", "還": "还", "邁": "迈",
        "鄧": "邓", "鄭": "郑", "鄰": "邻", "醫": "医", "醬": "酱", "釋": "释", "裡": "里", "針": "针",
        "釣": "钓", "鈴": "铃", "鉛": "铅", "銘": "铭", "銷": "销", "鋒": "锋", "錯": "错", "錢": "钱",
        "錦": "锦", "錫": "锡", "鍋": "锅", "鍵": "键", "鍾": "钟", "鎮": "镇", "鏈": "链", "鎖": "锁",
        "鑄": "铸", "鑑": "鉴", "鑽": "钻", "閉": "闭", "問": "问", "閒": "闲", "間": "间", "悶": "闷",
        "鬧": "闹", "聞": "闻", "閩": "闽", "閣": "阁", "閱": "阅", "闆": "板", "闊": "阔", "闡": "阐",
        "隊": "队", "陽": "阳", "陰": "阴", "陣": "阵", "階": "阶", "陸": "陆", "陳": "陈", "險": "险",
        "隨": "随", "隱": "隐", "隸": "隶", "隻": "只", "雞": "鸡", "難": "难", "霧": "雾", "靜": "静",
        "韓": "韩", "韻": "韵", "頁": "页", "頂": "顶", "項": "项", "順": "顺", "須": "须", "預": "预",
        "頑": "顽", "頓": "顿", "顧": "顾", "頒": "颁", "頌": "颂", "領": "领", "頗": "颇", "頸": "颈",
        "頻": "频", "顆": "颗", "額": "额", "願": "愿", "顛": "颠", "類": "类", "顯": "显", "飄": "飘",
        "飯": "饭", "飲": "饮", "飾": "饰", "飽": "饱", "餅": "饼", "養": "养", "馳": "驰", "駁": "驳",
        "駐": "驻", "駕": "驾", "駛": "驶", "駝": "驼", "駭": "骇", "駿": "骏", "騎": "骑", "騙": "骗",
        "騷": "骚", "驟": "骤", "驗": "验", "髮": "发", "鬱": "郁", "魯": "鲁", "鮮": "鲜", "鯉": "鲤",
        "鯨": "鲸", "鳴": "鸣", "鴉": "鸦", "鴨": "鸭", "鴻": "鸿", "鵝": "鹅", "鶴": "鹤", "鷹": "鹰",
        "鹽": "盐", "麥": "麦", "麵": "面", "麼": "么", "黃": "黄", "齊": "齐", "齒": "齿", "齡": "龄",
        "龜": "龟",
    ]

    public static func isVideo(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return videoExts.contains(ext)
    }

    public static func isSubtitle(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return subtitleExts.contains(ext)
    }

    public static func splitNameExt(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// 繁转简 + 全角转半角 + 水印与噪点符号清理。
    public static func deobfuscate(_ raw: String) -> String {
        let capped = String(raw.prefix(512))
        var out = ""
        out.reserveCapacity(capped.count)
        for ch in capped {
            if let mapped = t2sMap[ch] {
                out.append(mapped)
            } else if let scalar = ch.unicodeScalars.first, scalar.value >= 0xFF01 && scalar.value <= 0xFF5E,
                      let half = UnicodeScalar(scalar.value - 0xFEE0) {
                out.append(Character(half))
            } else {
                out.append(ch)
            }
        }
        // 清理常见网盘分享水印、网址广告前缀与技术参数方括号块
        let patterns = [
            #"(?i)https?://[^\s\]】)）]+"#,
            #"(?i)www\.[a-z0-9.-]+\.[a-z]{2,}"#,
            #"(?i)【[^】]*(?:发布|分享|剧集网|电影网|高清|首发|下载|官方|独家|最新|关注|公众号|资源|夸克|迅雷|123|网盘|光鸭|字幕|压制|频道|\.com|\.cn|\.net|\.tv|\.org)[^】]*】"#,
            #"【\s*】"#,
            #"(?i)\[[^\]]*(?:帧率|版本|全\s*\d+\s*[集话期]|更至|更新|国语|粤语|中字|字幕|配音|音轨|双语|多音轨|杜比|视界|高码|无水印|未删减|电影天堂|阳光电影|飘花电影|人人影视|字幕组|蓝光|原盘|WEB-?DL|WEBRip|BluRay|H\.?26[45]|10bit|8bit|\d+fps|2160p|1080p|720p|\b(?:HEVC|AVC|4K|HDR|SDR|DV|DDP|FLAC|AAC|Atmos|TrueHD|DTS|REMUX)\b)[^\]]*\]"#,
            #"\[\s*\]"#,
        ]
        for p in patterns {
            if let rx = try? NSRegularExpression(pattern: p) {
                let r = NSRange(out.startIndex..<out.endIndex, in: out)
                out = rx.stringByReplacingMatches(in: out, range: r, withTemplate: " ")
            }
        }
        // 还原汉字之间用于规避版权的 '=' 穿插分隔符（如 人=鱼 -> 人鱼）
        if let eqRx = try? NSRegularExpression(pattern: #"([\u4e00-\u9fff])=([\u4e00-\u9fff])"#) {
            for _ in 0..<4 {
                let r = NSRange(out.startIndex..<out.endIndex, in: out)
                let next = eqRx.stringByReplacingMatches(in: out, range: r, withTemplate: "$1$2")
                if next == out { break }
                out = next
            }
        }
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let knownMediaExts: Set<String> = videoExts
        .union(subtitleExts)
        .union(["nfo", "jpg", "jpeg", "png", "webp", "tbn", "xml", "txt", "strm", "img"])

    public static func stripKnownMediaExt(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = trimmed.lastIndex(of: "."), dot > trimmed.startIndex else { return trimmed }
        let ext = String(trimmed[trimmed.index(after: dot)...]).lowercased()
        return knownMediaExts.contains(ext) ? String(trimmed[..<dot]) : trimmed
    }

    public static func parse(_ rawName: String, folderHint: String? = nil) -> ParsedMedia {
        let stemRaw = stripKnownMediaExt(rawName)
        let text = deobfuscate(stemRaw)

        // 1. 外链 ID 提取（委托 1:1 ExternalIdExtractor）
        let extIds = ExternalIdExtractor.fromName(stemRaw)
        let imdbId = extIds.imdbId ?? firstMatch(#"(?i)\b(tt\d{7,9})\b"#, in: text, group: 1)?.lowercased()
        let tmdbId = extIds.tmdbId ?? firstMatch(#"(?i)(?:\{|\[|\()?(?:tmdb|tmdbid)[-_:\s=](\d{1,8})(?:\}|\]|\))?"#, in: text, group: 1).flatMap(Int.init)
        let tvdbId = extIds.tvdbId ?? firstMatch(#"(?i)(?:\{|\[|\()?(?:tvdb|tvdbid)[-_:\s=](\d{1,8})(?:\}|\]|\))?"#, in: text, group: 1).flatMap(Int.init)

        // 2. 分辨率与版本标签
        let resolution = firstMatch(#"(?i)\b(2160p|4K|1080p|1080i|720p|480p)\b"#, in: text, group: 1)?.uppercased()
            .replacingOccurrences(of: "2160P", with: "2160p")
            .replacingOccurrences(of: "1080P", with: "1080p")
            .replacingOccurrences(of: "720P", with: "720p")
        let edition = firstMatch(#"(?i)\b(Director'?s\.?\s*Cut|Extended(?:\.?\s*Edition)?|IMAX|Remux|Uncut|Final\.?\s*Cut)\b"#, in: text, group: 1)

        // 3. 季集与多集范围解析（优先 S01E01-E03，其次 S01E01 / 第01集 / 番剧 - 01）
        var season: Int? = nil
        var episode: Int? = nil
        var episodeEnd: Int? = nil

        if let rangeParsed = EpisodeRangeParser.parse(stemRaw), !rangeParsed.episodes.isEmpty {
            season = rangeParsed.season
            episode = rangeParsed.episodes.first
            if rangeParsed.episodes.count >= 2 { episodeEnd = rangeParsed.episodes.last }
        } else if let m = matchGroups(#"(?i)(?<![a-z0-9])S(\d{1,2})[._\s-]*E(\d{1,4})\s*[-~]\s*E?(\d{1,4})\b"#, in: text) {
            season = Int(m[1]); episode = Int(m[2]); episodeEnd = Int(m[3])
        } else if let m = matchGroups(#"(?i)(?<![a-z0-9])S(\d{1,2})[._\s-]*E(\d{1,4})\b"#, in: text) {
            season = Int(m[1]); episode = Int(m[2])
        } else if let m = matchGroups(#"(?i)第\s*(\d{1,2})\s*季.*?第\s*(\d{1,4})\s*[集话話]"#, in: text) {
            season = Int(m[1]); episode = Int(m[2])
        } else if let m = matchGroups(#"(?i)(?<![a-z0-9])(\d{1,2})x(\d{1,3})(?![0-9])"#, in: text),
                  let s = Int(m[1]), let e = Int(m[2]), s <= 50 {
            season = s; episode = e
        } else if let m = matchGroups(#"第\s*(\d{1,4})\s*[集话話期]"#, in: text) {
            episode = Int(m[1])
        } else if let cnEp = firstMatch(#"第\s*([零一二两三四五六七八九十百]+)\s*[集话話期]"#, in: text, group: 1),
                  let parsedEp = parseChineseCardinal(cnEp) {
            episode = parsedEp
        } else if let m = matchGroups(#"(?i)(?<![a-z0-9])EP?\.?\s*(\d{1,4})\b"#, in: text),
                  let ep = Int(m[1]), ep > 0, !(1900...2099).contains(ep) {
            episode = ep
        } else if let anime = AnimeEpisodeParser.parse(stemRaw) {
            season = anime.season
            episode = anime.episode
        } else if let m = matchGroups(#"(?:^|\s)-\s*(0\d{1,2}|\d{2,3})(?:\s|\[|\(|v\d|$)"#, in: text),
                  let ep = Int(m[1]), ep > 0, ep < 1900 {
            episode = ep
        }

        // 若文件名本身只有集数，从父目录尝试提取季号（如 Season 2 / S02 / 第二季）
        if season == nil, let fh = folderHint {
            season = seasonFromName(fh)
        }

        // 4. 年份提取（1900..2035）
        let year = firstMatch(#"(?:^|[\s._(\[（【-])((?:19|20)\d{2})(?:$|[\s._)\]）】-])"#, in: text, group: 1).flatMap(Int.init)

        // 5. 标题裁切（在季集、年份、分辨率、编码标签处截断）
        var title = text
        let cutMarkers = [
            #"(?i)(?<![a-z0-9])S\d{1,2}[._\s-]*E\d{1,4}.*$"#,
            #"(?i)(?<=[\s._\-\u4e00-\u9fff])S\d{1,2}(?:[\s._-]|$).*$"#,
            #"第\s*\d{1,2}\s*季.*$"#,
            #"第\s*\d{1,4}\s*[集话話].*$"#,
            #"(?i)\b(?:2160p|1080p|720p|4K|BluRay|WEB-DL|WEBRip|HDR|SDR|DV|HEVC|H\.?265|H\.?264|x265|x264|10bit|8bit|\d+fps|Remux|AAC|DDP|FLAC)\b.*$"#,
            #"(?:[\s._(\[（【-])(?:19|20)\d{2}(?:[\s._)\]）】-]|$).*$"#,
            #"(?i)\{?(?:(?:tv|movie)[._\s-]+)?tmdb(?:id)?[-_:\s=]?\d+\}?.*$"#,
        ]
        for p in cutMarkers {
            if let rx = try? NSRegularExpression(pattern: p) {
                let r = NSRange(title.startIndex..<title.endIndex, in: title)
                title = rx.stringByReplacingMatches(in: title, range: r, withTemplate: "")
            }
        }
        title = title
            .replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—[]()（）【】")))

        return ParsedMedia(
            rawName: rawName,
            cleanTitle: title.isEmpty ? stemRaw : title,
            year: year,
            season: season,
            episode: episode,
            episodeEnd: episodeEnd,
            isTvHint: season != nil || episode != nil,
            imdbId: imdbId,
            tmdbId: tmdbId,
            tvdbId: tvdbId,
            resolution: resolution,
            edition: edition
        )
    }

    /// 综合相似度评分（Levenshtein + Dice + Token 覆盖率，范围 0...100）。
    public static func titleSimilarityScore(_ a: String, _ b: String) -> Double {
        TitleScorer.titleSimilarityScore(a, b)
    }

    /// 标准 Emby/Plex/Infuse 命名构造。
    public static func sanitizeFileName(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: illegal).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func buildFolderName(title: String, year: String, tmdbId: Int, appendTag: Bool) -> String {
        let clean = sanitizeFileName(title)
        let y = year.isEmpty ? "" : " (\(year))"
        let tag = appendTag ? " {tmdb-\(tmdbId)}" : ""
        return "\(clean)\(y)\(tag)"
    }

    public static func buildCollectionName(name: String, collectionId: Int, appendTag: Bool) -> String {
        let clean = sanitizeFileName(name)
        return appendTag ? "\(clean) {tmdb-collection-\(collectionId)}" : clean
    }

    public static func buildEpisodeFileName(showTitle: String, season: Int, episode: Int, episodeEnd: Int? = nil, ext: String) -> String {
        let clean = sanitizeFileName(showTitle)
        let s = String(format: "%02d", season)
        let e = String(format: "%02d", episode)
        let tail = episodeEnd.map { String(format: "-E%02d", $0) } ?? ""
        return "\(clean) - S\(s)E\(e)\(tail)\(ext)"
    }

    // MARK: - Helpers

    private static func normalizeForScore(_ s: String) -> String {
        deobfuscate(s).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var set: Set<String> = []
        for i in 0..<(chars.count - 1) { set.insert(String([chars[i], chars[i + 1]])) }
        return set
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              group < m.numberOfRanges,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    private static func matchGroups(_ pattern: String, in text: String) -> [String]? {
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
        return (0..<m.numberOfRanges).compactMap { idx -> String? in
            guard let r = Range(m.range(at: idx), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// 1:1 复刻 Android `Naming.seasonFromName`：从文件名或目录名提取季号（支持 S01 / Season 2 / 第3季 / 第二季 / Specials）。
    public static func seasonFromName(_ name: String) -> Int? {
        if let s = firstMatch(#"(?i)(?<![a-z0-9])(?:Season|S)[._\s-]*(\d{1,2})(?![0-9])"#, in: name, group: 1).flatMap(Int.init) {
            return s
        }
        if let s = firstMatch(#"第\s*(\d{1,3})\s*季"#, in: name, group: 1).flatMap(Int.init) {
            return s
        }
        if let cn = firstMatch(#"第\s*([一二两三四五六七八九十百]+)\s*季"#, in: name, group: 1),
           let parsedCn = parseChineseCardinal(cn) {
            return parsedCn
        }
        if firstMatch(#"(?i)(?<![a-z0-9])(Specials?|OVA|OAD|SP)(?![a-z0-9])"#, in: name, group: 1) != nil {
            return 0
        }
        return nil
    }

    private static func parseChineseCardinal(_ cn: String) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        if cn == "十" { return 10 }
        if cn == "百" { return 100 }
        if cn.count == 1, let v = digits[cn.first!] { return v }
        var total = 0
        var current = 0
        for ch in cn {
            if let d = digits[ch] {
                current = d
            } else if ch == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
            } else if ch == "百" {
                total += (current == 0 ? 1 : current) * 100
                current = 0
            } else {
                return nil
            }
        }
        total += current
        return total > 0 ? total : nil
    }

    /// 1:1 复刻 Android `Naming.tmdbHint`：从文件名/目录名提取 `{tmdb-12345}` / `[tmdbid=12345]` / `tmdb-tv-12345` 提示。
    public static func tmdbHint(_ name: String) -> (kind: String?, id: Int)? {
        if let m = matchGroups(#"(?i)[\{\[\(（【]?(tv|movie)[._\s-]+tmdb(?:id)?[-_:\s=]?(\d{1,9})[\}\]\)）】]?"#, in: name),
           let id = Int(m[2]) {
            return (m[1].lowercased(), id)
        }
        if let m = matchGroups(#"(?i)[\{\[\(（【]?tmdb(?:id)?[-_:\s=]+(tv|movie)[-_:\s=]+(\d{1,9})[\}\]\)）】]?"#, in: name),
           let id = Int(m[2]) {
            return (m[1].lowercased(), id)
        }
        if let m = matchGroups(#"(?i)[\{\[\(（【]?tmdb(?:id)?[-_:\s=]?(\d{1,9})[\}\]\)）】]?"#, in: name),
           let id = Int(m[1]) {
            return (nil, id)
        }
        return nil
    }

}
