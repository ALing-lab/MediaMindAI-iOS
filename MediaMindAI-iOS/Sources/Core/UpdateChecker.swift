import Foundation

/// 1:1 对标 Android `UpdateChecker.kt`（iOS 适用部分：语义化版本比较、GitHub Release 检查、中文友好网络错误提示与手动更新兜底，不含 Android APK 下载/安装）。
public struct ReleaseInfo: Codable, Hashable, Sendable {
    public let tagName: String
    public let version: String
    public let title: String
    public let releaseNotes: String
    public let htmlUrl: String
    public let publishedAt: String

    public init(
        tagName: String,
        version: String,
        title: String = "",
        releaseNotes: String,
        htmlUrl: String,
        publishedAt: String
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title.isEmpty ? tagName : title
        self.releaseNotes = releaseNotes
        self.htmlUrl = htmlUrl
        self.publishedAt = publishedAt
    }
}

public enum UpdateResult: Equatable, Sendable {
    case available(ReleaseInfo)
    case upToDate(String)
    case error(String)
}

public enum UpdateChecker {
    public static let currentVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.5.79"
    public static let releasesPageUrl = "https://github.com/tamu-dev/MediaMind-AI/releases"
    public static let defaultLatestUrl = "https://api.github.com/repos/tamu-dev/MediaMind-AI/releases/latest"

    /// 1:1 复刻 Android `UpdateChecker.compare`：`1.2.10 > 1.2.9`，自动忽略 `v`/`V` 前缀及 `-beta`/`+build` 后缀。
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] {
            var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
            if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
            return s.split(separator: ".").map { seg in
                Int(seg.filter(\.isNumber)) ?? 0
            }
        }
        let x = parts(a)
        let y = parts(b)
        let count = max(x.count, y.count)
        for i in 0..<count {
            let xv = i < x.count ? x[i] : 0
            let yv = i < y.count ? y[i] : 0
            if xv != yv { return xv < yv ? -1 : 1 }
        }
        return 0
    }

    /// 语义化版本比较（支持带 `v` 前缀，如 `v0.5.91` > `0.5.90`）。
    public static func isNewer(_ remote: String, than current: String) -> Bool {
        compare(remote, current) > 0
    }

    /// 1:1 复刻 Android `UpdateChecker.friendly`：将网络超时、DNS、TLS 错误转为中文友好提示。
    public static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return "连接 GitHub 超时（大陆网络访问 GitHub 往往较慢）。可以稍后再试，或点「手动更新」在浏览器里打开发布页。"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "无法解析 GitHub 地址，请检查网络 / 代理后重试，或点「手动更新」。"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "与 GitHub 的安全连接失败（网络可能被干扰），请换个网络或开代理后重试。"
            default:
                break
            }
        }
        return "检查更新失败：\(error.localizedDescription)"
    }

    public static func parse(data: Data) throws -> ReleaseInfo {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DriveError.api(code: -1, message: "GitHub 返回了无法解析的数据")
        }
        let rawTag = (obj["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tag = rawTag.isEmpty ? rawName : rawTag
        guard !tag.isEmpty else {
            throw DriveError.api(code: -1, message: "发布信息缺少版本号")
        }
        var ver = tag
        if ver.hasPrefix("v") || ver.hasPrefix("V") { ver.removeFirst() }
        let html = (obj["html_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReleaseInfo(
            tagName: tag,
            version: ver,
            title: rawName.isEmpty ? tag : rawName,
            releaseNotes: ((obj["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            htmlUrl: (html?.isEmpty == false) ? html! : releasesPageUrl,
            publishedAt: (obj["published_at"] as? String) ?? ""
        )
    }

    /// 1:1 复刻 Android `UpdateChecker.check()`：返回结构化 `.available` / `.upToDate` / `.error`。
    public static func check(
        urlStr: String = defaultLatestUrl,
        current: String = currentVersion,
        session: URLSession = .shared
    ) async -> UpdateResult {
        guard let url = URL(string: urlStr) else {
            return .error("无效的更新检查地址")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MediaMindAI-iOS/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                return .error("还没有发布任何版本（或仓库尚未公开）。")
            }
            if code == 403 || code == 429 {
                return .error("GitHub 接口访问次数暂时超限，请过一会儿再试，或点「手动更新」。")
            }
            guard (200...299).contains(code) else {
                return .error("GitHub 返回 HTTP \(code)，请稍后再试。")
            }
            let info = try parse(data: data)
            return compare(info.version, current) > 0 ? .available(info) : .upToDate(info.version)
        } catch is CancellationError {
            return .error("已取消检查更新")
        } catch {
            return .error(friendly(error))
        }
    }

    public static func checkLatest(urlStr: String = defaultLatestUrl, session: URLSession = .shared) async throws -> ReleaseInfo? {
        guard let url = URL(string: urlStr) else { throw DriveError.invalidInput("无效的更新检查地址") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MediaMindAI-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw DriveError.api(code: code, message: "检查更新失败（HTTP \(code)）")
        }
        return try parse(data: data)
    }
}
