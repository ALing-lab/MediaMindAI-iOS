import Foundation

/// 1:1 逐行复刻自 Android `NfoXml.kt`（49 行）：
/// XML 1.0 控制字符清洗、属性/文本安全转义、CDATA `]]>` 安全拆段，以及图片字节头与 15MB 上限校验。
public enum NfoXml {
    /// 元素文本与属性值安全转义（含引号）；剔除 XML 1.0 不允许的控制字符。
    public static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x26: out.append("&amp;")
            case 0x3C: out.append("&lt;")
            case 0x3E: out.append("&gt;")
            case 0x22: out.append("&quot;")
            case 0x27: out.append("&apos;")
            case 0x09, 0x0A, 0x0D: out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// CDATA：剥离非法控制字符，并将内容中的 `]]>` 拆成两段 CDATA，保证解析后与原文完全一致。
    public static func cdata(name: String, value: String) -> String {
        let clean = String(value.unicodeScalars.filter { $0.value >= 0x20 || $0.value == 0x09 || $0.value == 0x0A || $0.value == 0x0D })
        let safe = clean.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
        return "  <\(name)><![CDATA[\(safe)]]></\(name)>"
    }

    public static func tag(name: String, value: CustomStringConvertible) -> String {
        "  <\(name)>\(esc(value.description))</\(name)>"
    }

    public static func flat(_ text: String?) -> String {
        (text ?? "")
            .replacingOccurrences(of: #"\s*[\r\n]+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ImageBytes {
    public static let maxBytes: Int = 15 * 1024 * 1024
    private static let allowedExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]

    public static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 12, data.count <= maxBytes else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true } // JPEG
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true } // PNG
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true } // WebP
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return true } // GIF8
        return false
    }

    public static func safeExt(url: String) -> String {
        let stripped = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let noFrag = stripped.split(separator: "#", maxSplits: 1).first.map(String.init) ?? stripped
        let lastSeg = noFrag.split(separator: "/").last.map(String.init) ?? ""
        guard let dot = lastSeg.lastIndex(of: ".") else { return "jpg" }
        let ext = String(lastSeg[lastSeg.index(after: dot)...]).lowercased()
        return allowedExts.contains(ext) ? ext : "jpg"
    }
}
