import Foundation

/// 1:1 逐行复刻自 Android `TitleScorer.kt`（119 行）：
/// 零外部依赖的多信号模糊标题评分引擎（Levenshtein 0.35 + Jaro-Winkler 0.25 + Sørensen-Dice 0.20 + token_sort_ratio 0.20）。
public enum TitleScorer {
    public static func normalizedLevenshtein(_ a0: String, _ b0: String) -> Double {
        let a = Array(a0.prefix(256))
        let b = Array(b0.prefix(256))
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                curr[j] = min(min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
            }
            prev = curr
        }
        return 1.0 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }

    public static func jaroWinkler(_ s1Raw: String, _ s2Raw: String, prefixScale: Double = 0.1) -> Double {
        let s1 = Array(s1Raw.prefix(256))
        let s2 = Array(s2Raw.prefix(256))
        if s1 == s2 { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }
        let matchDist = max(0, max(s1.count, s2.count) / 2 - 1)
        var m1 = Array(repeating: false, count: s1.count)
        var m2 = Array(repeating: false, count: s2.count)
        var matches = 0
        for i in s1.indices {
            let start = max(0, i - matchDist)
            let end = min(i + matchDist + 1, s2.count)
            guard start < end else { continue }
            for j in start..<end where !m2[j] && s1[i] == s2[j] {
                m1[i] = true
                m2[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0.0 }
        var t = 0
        var k = 0
        for i in s1.indices where m1[i] {
            while !m2[k] { k += 1 }
            if s1[i] != s2[k] { t += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s1.count) + m / Double(s2.count) + (m - Double(t) / 2.0) / m) / 3.0
        var prefix = 0
        for i in 0..<min(4, min(s1.count, s2.count)) {
            if s1[i] == s2[i] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * prefixScale * (1.0 - jaro)
    }

    public static func diceCoefficient(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let ca = Array(a)
        let cb = Array(b)
        if ca.count < 2 || cb.count < 2 { return 0.0 }
        func bigrams(_ chars: [Character]) -> [String: Int] {
            var map: [String: Int] = [:]
            for i in 0..<(chars.count - 1) {
                let bg = String([chars[i], chars[i + 1]])
                map[bg, default: 0] += 1
            }
            return map
        }
        let ba = bigrams(ca)
        let bb = bigrams(cb)
        var inter = 0
        for (bg, cnt) in ba {
            if let cbCnt = bb[bg] { inter += min(cnt, cbCnt) }
        }
        return 2.0 * Double(inter) / Double((ca.count - 1) + (cb.count - 1))
    }

    public static func tokenSortRatio(_ rawA: String, _ rawB: String) -> Double {
        func sortedTokens(_ s: String) -> String {
            s.lowercased()
                .components(separatedBy: CharacterSet(charactersIn: " ._-:：·/\t\n"))
                .filter { !$0.isEmpty }
                .sorted()
                .joined(separator: " ")
        }
        let a = sortedTokens(rawA)
        let b = sortedTokens(rawB)
        if a.isEmpty || b.isEmpty { return 0.0 }
        return normalizedLevenshtein(a, b)
    }

    public static func normalizeTitle(_ s: String) -> String { norm(s) }

    private static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 综合标题相似度（0.0...100.0 分）。
    public static func titleSimilarityScore(_ queryRaw: String, _ candidateRaw: String) -> Double {
        let qSimp = TitleDeobfuscator.traditionalToSimplified(queryRaw)
        let cSimp = TitleDeobfuscator.traditionalToSimplified(candidateRaw)
        let q = norm(qSimp)
        let c = norm(cSimp)
        if q.isEmpty || c.isEmpty { return 0.0 }
        if q == c { return 100.0 }
        let ratioLen = Double(min(q.count, c.count)) / Double(max(q.count, c.count))
        if (c.contains(q) || q.contains(c)) && ratioLen >= 0.8 {
            return 82.0 + 10.0 * ratioLen
        }
        let lev = normalizedLevenshtein(q, c)
        let jw = jaroWinkler(q, c)
        let dice = diceCoefficient(q, c)
        let tsr = tokenSortRatio(qSimp, cSimp)
        let blended = 0.35 * lev + 0.25 * jw + 0.20 * dice + 0.20 * tsr
        return min(95.0, max(0.0, blended * 80.0))
    }
}
