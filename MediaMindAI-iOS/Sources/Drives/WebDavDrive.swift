import Foundation

/// WebDAV 地址填写说明与实时解析（1:1 复刻 Android `WebDavAddress.kt`）。
public enum WebDavAddress {
    public struct Info: Equatable, Sendable {
        public let text: String
        public let error: Bool

        public init(text: String, error: Bool) {
            self.text = text
            self.error = error
        }
    }

    public static let help: String = """
    服务器地址是一个完整的网址：协议://主机:端口/路径。
    • 协议：http:// 或 https://，必须写。
    • 主机：NAS 的局域网 IP（如 192.168.1.5）或域名。
    • 端口：写在主机后面、用冒号隔开，如 :5005。只有用默认端口（http 是 80，https 是 443）时才能省略；没有单独的端口栏。
    • 路径：WebDAV 服务的路径，如 /dav；服务开在根目录时可以不写。
    • 用户名 / 密码：WebDAV 服务自己的账号（如 NAS 用户、Alist 用户），不是网盘账号。
    • 注意：http:// 是明文传输，密码和文件名在网络上不加密，只建议在家里的局域网使用；从外网访问请用 https://。
    """

    public static let examples: [(label: String, url: String)] = [
        ("群晖 NAS", "http://192.168.1.5:5005"),
        ("群晖 HTTPS", "https://192.168.1.5:5006"),
        ("威联通 NAS", "http://192.168.1.6:8080/share"),
        ("Alist / OpenList", "http://192.168.1.7:5244/dav"),
        ("域名 + 默认端口", "https://dav.example.com/dav"),
    ]

    public static func describe(_ raw: String) -> Info {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty || u == "https://" || u == "http://" {
            return Info(text: "格式：http://IP:端口/路径，例如 http://192.168.1.5:5005/dav", error: false)
        }
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") {
            return Info(text: "要以 http:// 或 https:// 开头", error: true)
        }
        guard let comps = URLComponents(string: u), !u.contains(" ") else {
            return Info(text: "地址格式不对（不要有空格或中文标点）", error: true)
        }
        guard let host = comps.host, !host.isEmpty else {
            return Info(text: "缺少主机（IP 或域名）", error: true)
        }
        let isHttps = u.hasPrefix("https://")
        let portText = comps.port.map { "端口 \($0)" } ?? "端口 \(isHttps ? 443 : 80)（默认）"
        let rawPath = comps.percentEncodedPath
        let pathText = (!rawPath.isEmpty && rawPath != "/") ? rawPath : "/（根目录）"
        return Info(text: "主机 \(host) · \(portText) · 路径 \(pathText)", error: false)
    }
}

/// 1:1 逐行复刻自 Android `WebDavDrive.kt`（RFC 4918）：
/// - ID = 相对于服务器地址的路径，以 "/" 开头，未编码（如 "/电影/盗梦空间 (2010)"）。
/// - 列目录 PROPFIND Depth:1（含 `oc:checksums` 扩展、XXE/DOCTYPE 拦截、8 MB 上限、2xx propstat 过滤）；
/// - 改名 / 移动 MOVE（Overwrite: F + stat 预检绝不覆盖）；建目录 MKCOL（stat 复用 + 405 复查）；
/// - 上传 PUT（If-None-Match: * + MIME 类型 + 412 幂等）；删除 DELETE（禁删根目录 + stat 预检）；
/// - 禁用自动重定向（防止 MOVE/PUT 被转为 GET），仅对 PROPFIND 301/302/307/308 自动补尾斜杠重试；
/// - TOFU 证书指纹固定（`CertPinning.makeSession(pinnedFingerprint:followRedirects: false)`）。
public final class WebDavDrive: CloudDrive, @unchecked Sendable {
    public let kind: ProviderKind = .webdav
    public let accountId: String
    public let rootId: String = "/"
    public let isLanEndpoint: Bool
    public let trashSupport: TrashSupport = .permanent
    public let writeIntervalMs: UInt64 = 100

    public static let tag = "WebDAV"
    private static let maxPropfindBytes = 8 * 1024 * 1024
    private static let doctypeRegex = try! NSRegularExpression(pattern: #"<!DOCTYPE|<!ENTITY"#, options: [.caseInsensitive])
    private static let http2xxRegex = try! NSRegularExpression(pattern: #"^HTTP/[^ ]+ 2[0-9]{2}(?: .*|$)"#)

    private static let propBody: Data = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/><d:displayname/><oc:checksums/></d:prop></d:propfind>
    """.utf8)

    private let baseUrl: URL
    private let baseScheme: String
    private let baseHost: String
    private let basePort: Int
    private let basePathSegments: [String]
    private let authHeader: String?
    private let session: URLSession
    private let certDelegate: CertPinning.PinningSessionDelegate?
    private let ownsSession: Bool

    public static func normalizeBase(_ rawUrl: String) throws -> URL {
        var u = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.lowercased().hasPrefix("http://") && !u.lowercased().hasPrefix("https://") {
            u = "https://\(u)"
        }
        if !u.hasSuffix("/") { u += "/" }
        guard let url = URL(string: u),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            throw DriveError.invalidInput("WebDAV 地址格式不正确（需 http:// 或 https://）")
        }
        return url
    }

    public init(
        accountId: String,
        baseUrl: String,
        username: String,
        password: String,
        pinnedFingerprint: String? = nil,
        session: URLSession? = nil
    ) throws {
        let normalized = try Self.normalizeBase(baseUrl)
        let scheme = (normalized.scheme ?? "https").lowercased()
        let host = normalized.host ?? ""
        self.accountId = accountId
        self.baseUrl = normalized
        self.baseScheme = scheme
        self.baseHost = host.lowercased()
        self.basePort = normalized.port ?? (scheme == "https" ? 443 : 80)
        self.basePathSegments = normalized.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        self.isLanEndpoint = DriveRateProfile.isLanHost(host)
        if !username.isEmpty || !password.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            self.authHeader = "Basic \(token)"
        } else {
            self.authHeader = nil
        }
        // followRedirects: false — 避免 MOVE/PUT/PROPFIND 被重定向转成 GET
        if let provided = session {
            self.session = provided
            self.certDelegate = nil
            self.ownsSession = false
        } else {
            let built = CertPinning.makeSessionWithDelegate(pinnedFingerprint: pinnedFingerprint, followRedirects: false)
            self.session = built.session
            self.certDelegate = built.delegate
            self.ownsSession = true
        }
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    // MARK: - 1. 路径安全校验与 URL / href 编解码

    private func safeSegments(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        for part in parts {
            if part == "." || part == ".." || part.contains("\\") ||
                part.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
                throw DriveError.invalidInput("WebDAV 路径不合法")
            }
        }
        return parts
    }

    private func norm(_ path: String) throws -> String {
        "/" + (try safeSegments(path)).joined(separator: "/")
    }

    private static func validateExecName(_ name: String) throws {
        let cleaned = name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }
        let s = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s == name, s != ".", s != "..", !s.contains("/"), !s.contains("\\"), s.utf8.count <= 255 else {
            throw DriveError.invalidInput("名称不合法：\(name)")
        }
    }

    private static func encodePathSegment(_ seg: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?;#%")
        return seg.addingPercentEncoding(withAllowedCharacters: allowed) ?? seg
    }

    public func urlFor(_ path: String, isDir: Bool) throws -> URL {
        let segs = try safeSegments(path)
        let allSegs = basePathSegments + segs
        var comps = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false) ?? URLComponents()
        let encodedPath: String
        if allSegs.isEmpty {
            encodedPath = "/"
        } else {
            let joined = allSegs.map { Self.encodePathSegment($0) }.joined(separator: "/")
            encodedPath = isDir ? "/\(joined)/" : "/\(joined)"
        }
        comps.percentEncodedPath = encodedPath
        guard let url = comps.url else {
            throw DriveError.invalidInput("无法构造 WebDAV 请求地址")
        }
        let uScheme = (url.scheme ?? "").lowercased()
        let uHost = (url.host ?? "").lowercased()
        let uPort = url.port ?? (uScheme == "https" ? 443 : 80)
        let uSegs = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard uScheme == baseScheme,
              uHost == baseHost,
              uPort == basePort,
              uSegs.count >= basePathSegments.count,
              Array(uSegs.prefix(basePathSegments.count)) == basePathSegments else {
            throw DriveError.invalidInput("WebDAV 路径越出配置目录")
        }
        return url
    }

    /// 把服务器返回的 href 转为 ID（相对路径，已解码）。不在 base 下的返回 nil。
    public func idFromHref(_ href: String) -> String? {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathPart: String
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            guard let u = URL(string: raw),
                  let scheme = u.scheme?.lowercased(),
                  let host = u.host?.lowercased() else { return nil }
            let port = u.port ?? (scheme == "https" ? 443 : 80)
            guard scheme == baseScheme, host == baseHost, port == basePort else { return nil }
            pathPart = URLComponents(url: u, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? u.path
        } else {
            pathPart = raw.split(separator: "?", maxSplits: 1).first.map(String.init) ?? raw
        }
        let segs = pathPart
            .split(separator: "/")
            .filter { !$0.isEmpty }
            .map { decodeSeg(String($0)) }
        for seg in segs {
            if seg == "." || seg == ".." || seg.contains("/") || seg.contains("\\") ||
                seg.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
                return nil
            }
        }
        guard segs.count >= basePathSegments.count,
              Array(segs.prefix(basePathSegments.count)) == basePathSegments else {
            return nil
        }
        let rel = Array(segs.dropFirst(basePathSegments.count))
        return "/" + rel.joined(separator: "/")
    }

    private func decodeSeg(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    // MARK: - 2. HTTP 与 PROPFIND 多状态解析

    private func makeRequest(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("123Scraper/0.2 WebDAV", forHTTPHeaderField: "User-Agent")
        if let auth = authHeader { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        return req
    }

    private func fail(_ op: String, status: Int) async throws -> Never {
        let hint: String
        switch status {
        case 401: hint = "用户名或密码不对（或服务器要求 Digest 认证）"
        case 403: hint = "没有权限"
        case 404: hint = "路径不存在"
        case 405: hint = "服务器不允许该操作"
        case 409: hint = "上级目录不存在"
        case 412: hint = "目标已存在（不会覆盖）"
        case 423: hint = "文件被锁定"
        case 507: hint = "服务器空间不足"
        default: hint = "HTTP \(status)"
        }
        let msg = "WebDAV \(op)失败：\(hint)"
        await NetLog.shared.error(Self.tag, msg)
        if status == 401 || status == 403 {
            throw DriveError.unauthorized(msg)
        }
        if status == 429 {
            throw DriveError.rateLimited(code: 429, message: msg)
        }
        throw DriveError.api(code: status, message: msg)
    }

    fileprivate struct Prop {
        let id: String
        let isDir: Bool
        let size: Int64
        let etag: String?
        let contentHash: String?
        let hashAlgorithm: String?
    }

    private func propfind(path: String, depth: Int, asDir: Bool) async throws -> (Int, [Prop]) {
        let url = try urlFor(path, isDir: asDir)
        var req = makeRequest(url, method: "PROPFIND")
        req.setValue("\(depth)", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.propBody

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 部分服务器对不带尾斜杠的目录返回 301/302/307/308：改用目录形式重试
        if [301, 302, 307, 308].contains(status) && !asDir {
            return try await propfind(path: path, depth: depth, asDir: true)
        }
        if status == 404 { return (404, []) }
        if status != 207 && status != 200 {
            try await fail("列目录", status: status)
        }
        if data.count > Self.maxPropfindBytes {
            throw DriveError.api(code: -1, message: "WebDAV 列表过大，未完整读取")
        }
        guard let xml = String(data: data, encoding: .utf8), !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DriveError.api(code: -1, message: "WebDAV 返回空响应")
        }
        let nsXml = xml as NSString
        if Self.doctypeRegex.firstMatch(in: xml, range: NSRange(location: 0, length: nsXml.length)) != nil {
            throw DriveError.api(code: -1, message: "WebDAV XML 为空或包含不允许的声明")
        }

        let props = try parseMultistatus(data: data)
        let targetNorm = try norm(path)
        guard props.contains(where: { (try? norm($0.id)) == targetNorm }) else {
            throw DriveError.api(code: -1, message: "WebDAV 未确认目标资源状态")
        }
        return (status, props)
    }

    private func parseMultistatus(data: Data) throws -> [Prop] {
        let parser = WebDavMultistatusParser(
            idFromHref: { [self] href in self.idFromHref(href) },
            is2xxStatus: { status in
                let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
                let ns = trimmed as NSString
                return Self.http2xxRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
            }
        )
        return try parser.parse(data: data)
    }

    /// 查单个路径：nil = 不存在；true/false = 是否目录。
    private func stat(_ path: String) async throws -> Bool? {
        let (code, props) = try await propfind(path: path, depth: 0, asDir: false)
        if code == 404 { return nil }
        let targetNorm = try norm(path)
        guard let found = props.first(where: { (try? norm($0.id)) == targetNorm }) else {
            throw DriveError.api(code: -1, message: "WebDAV 无法确认资源类型")
        }
        return found.isDir
    }

    private func moveTo(from: String, to: String) async throws -> String {
        guard let isDir = try await stat(from) else {
            throw DriveError.api(code: 404, message: "WebDAV 移动失败：源不存在 \(from)")
        }
        if try await stat(to) != nil {
            throw DriveError.api(code: 412, message: "WebDAV 移动失败：目标已存在（不会覆盖）\(DrivePaths.nameOf(to))")
        }
        var req = makeRequest(try urlFor(from, isDir: isDir), method: "MOVE")
        req.setValue(try urlFor(to, isDir: isDir).absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 201 && status != 204 {
            try await fail("移动/改名", status: status)
        }
        return to
    }

    // MARK: - 3. CloudDrive 协议方法

    public func list(folderId: String) async throws -> [CloudEntry] {
        let folder = try norm(folderId)
        let (code, props) = try await propfind(path: folder, depth: 1, asDir: true)
        if code == 404 {
            throw DriveError.api(code: 404, message: "WebDAV 列目录失败：路径不存在 \(folder)")
        }
        var seen = Set<String>()
        var out: [CloudEntry] = []
        for p in props {
            guard let id = try? norm(p.id), id != folder else { continue }
            guard seen.insert(id).inserted else { continue }
            out.append(CloudEntry(
                fileId: id,
                fileName: DrivePaths.nameOf(id),
                isDir: p.isDir,
                size: p.size,
                parentFileId: folder,
                etag: p.etag,
                contentHash: p.contentHash,
                hashAlgorithm: p.hashAlgorithm
            ))
        }
        return out.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.fileName.lowercased() < $1.fileName.lowercased()
        }
    }

    public func rename(fileId: String, newName: String) async throws -> String {
        try Self.validateExecName(newName)
        let from = try norm(fileId)
        let to = DrivePaths.join(parent: DrivePaths.parentOf(from), name: newName)
        return to == from ? from : try await moveTo(from: from, to: to)
    }

    public func move(fileId: String, destParentId: String) async throws -> String {
        let from = try norm(fileId)
        let dest = try norm(destParentId)
        guard try await stat(dest) == true else {
            throw DriveError.api(code: 404, message: "WebDAV 移动失败：目标文件夹不存在 \(dest)")
        }
        let to = DrivePaths.join(parent: dest, name: DrivePaths.nameOf(from))
        return to == from ? from : try await moveTo(from: from, to: to)
    }

    public func mkdir(parentId: String, name: String) async throws -> String {
        try Self.validateExecName(name)
        let path = DrivePaths.join(parent: try norm(parentId), name: name)
        if let existingIsDir = try await stat(path) {
            if existingIsDir { return path }
            throw DriveError.api(code: 409, message: "WebDAV 建文件夹失败：同名文件已存在 \(name)")
        }
        let req = makeRequest(try urlFor(path, isDir: true), method: "MKCOL")
        let (_, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 201, 204:
            return path
        case 405:
            if try await stat(path) == true { return path }
            try await fail("建文件夹", status: status)
        default:
            try await fail("建文件夹", status: status)
        }
    }

    public func upload(parentId: String, name: String, data: Data) async throws -> String {
        try Self.validateExecName(name)
        let path = DrivePaths.join(parent: try norm(parentId), name: name)
        if try await stat(path) != nil {
            return "已存在"
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "jpg", "jpeg": contentType = "image/jpeg"
        case "png": contentType = "image/png"
        case "nfo", "xml": contentType = "text/xml; charset=utf-8"
        default: contentType = "application/octet-stream"
        }
        var req = makeRequest(try urlFor(path, isDir: false), method: "PUT")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("*", forHTTPHeaderField: "If-None-Match")
        req.httpBody = data
        let (_, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 201, 204:
            return path
        case 412:
            return "已存在"
        default:
            try await fail("上传", status: status)
        }
    }

    /// WebDAV DELETE（没有回收站）。执行引擎会先确认文件夹里没有视频才调用。
    public func trash(fileId: String) async throws -> String {
        let path = try norm(fileId)
        guard path != "/" && !path.isEmpty else {
            throw DriveError.invalidInput("不能删除根目录")
        }
        guard let isDir = try await stat(path) else {
            return "已不存在"
        }
        let req = makeRequest(try urlFor(path, isDir: isDir), method: "DELETE")
        let (_, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 202, 204, 404:
            return "已删除"
        default:
            try await fail("删除", status: status)
        }
    }

    public func exists(parentId: String, name: String) async throws -> Bool {
        let path = DrivePaths.join(parent: try norm(parentId), name: name)
        if try await stat(path) != nil { return true }
        return try await list(folderId: parentId).contains { $0.fileName.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func parentIdOf(fileId: String) async throws -> String? {
        DrivePaths.parentOf(fileId)
    }

    public func ping() async -> Bool {
        guard let (code, _) = try? await propfind(path: "/", depth: 0, asDir: true) else { return false }
        return code == 200 || code == 207
    }

    /// 带错误信息的连通性测试（给「测试连接」按钮用），返回根目录子项数；若遇自签名未信任证书则抛出 `CertPinning.UntrustedCertError`。
    public func check() async throws -> Int {
        certDelegate?.clearLastRejectedCert()
        do {
            let (code, props) = try await propfind(path: "/", depth: 1, asDir: true)
            if code == 404 {
                throw DriveError.api(code: 404, message: "服务器地址的路径不存在")
            }
            return max(0, props.count - 1)
        } catch {
            if let rejected = certDelegate?.lastRejectedCert {
                throw CertPinning.UntrustedCertError(fingerprint: rejected.fingerprint, host: rejected.host)
            }
            if let pinReason = certDelegate?.lastPinFailureReason {
                throw DriveError.network("已固定的服务器证书校验失败（可能已过期或无效）：\(pinReason)")
            }
            throw error
        }
    }
}

// MARK: - RFC 4918 Multistatus XML 严格解析器

private final class WebDavMultistatusParser: NSObject, XMLParserDelegate {
    private let idFromHref: (String) -> String?
    private let is2xxStatus: (String) -> Bool

    private var props: [WebDavDrive.Prop] = []
    private var parseError: Error?

    // 响应层级状态
    private var elementStack: [String] = []
    private var inResponse = false
    private var inPropstat = false
    private var currentText = ""

    // 当前 <d:response> 字段
    private var respHref: String?
    private var respDirectStatus: String?
    private var respHasGoodProps = false
    private var respIsDir = false
    private var respSize: Int64 = 0
    private var respEtag: String?
    private var respDigest: (algorithm: String, digest: String)?

    // 当前 <d:propstat> 字段（需待 propstat 结束确认 2xx 后再合并）
    private var psStatus = ""
    private var psIsDir = false
    private var psSize: Int64?
    private var psEtag: String?
    private var psChecksums: String?

    init(idFromHref: @escaping (String) -> String?, is2xxStatus: @escaping (String) -> Bool) {
        self.idFromHref = idFromHref
        self.is2xxStatus = is2xxStatus
    }

    func parse(data: Data) throws -> [WebDavDrive.Prop] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let ok = parser.parse()
        if let err = parseError { throw err }
        if !ok {
            throw DriveError.api(code: -1, message: "WebDAV XML 解析失败：\(parser.parserError?.localizedDescription ?? "格式异常")")
        }
        return props
    }

    private func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        elementStack.append(local)
        currentText = ""

        if local == "response" {
            inResponse = true
            respHref = nil
            respDirectStatus = nil
            respHasGoodProps = false
            respIsDir = false
            respSize = 0
            respEtag = nil
            respDigest = nil
        } else if local == "propstat" && inResponse {
            inPropstat = true
            psStatus = ""
            psIsDir = false
            psSize = nil
            psEtag = nil
            psChecksums = nil
        } else if local == "collection" && inPropstat {
            psIsDir = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inResponse else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        let parent = elementStack.count >= 2 ? elementStack[elementStack.count - 2] : ""

        if inResponse {
            if local == "href" && parent == "response" {
                respHref = currentText
            } else if local == "status" && parent == "response" {
                respDirectStatus = currentText
            } else if inPropstat {
                switch local {
                case "status" where parent == "propstat":
                    psStatus = currentText
                case "getcontentlength":
                    if let v = Int64(currentText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        psSize = v
                    }
                case "getetag":
                    let t = currentText.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !t.isEmpty { psEtag = t }
                case "checksums", "checksum":
                    let t = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        psChecksums = (psChecksums == nil) ? t : "\(psChecksums!) \(t)"
                    }
                case "propstat":
                    inPropstat = false
                    let st = psStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                    if st.isEmpty || is2xxStatus(st) {
                        respHasGoodProps = true
                        if psIsDir { respIsDir = true }
                        if let s = psSize { respSize = s }
                        if let e = psEtag { respEtag = e }
                        if let parsed = ContentDigest.parseWebDavChecksums(psChecksums) {
                            respDigest = parsed
                        }
                    }
                default:
                    break
                }
            }

            if local == "response" {
                inResponse = false
                if let direct = respDirectStatus, !is2xxStatus(direct) {
                    parseError = DriveError.api(code: -1, message: "WebDAV 资源读取失败")
                    parser.abortParsing()
                } else if let href = respHref {
                    guard let id = idFromHref(href) else {
                        parseError = DriveError.api(code: -1, message: "WebDAV 返回越界或无效路径")
                        parser.abortParsing()
                        return
                    }
                    if !respHasGoodProps {
                        parseError = DriveError.api(code: -1, message: "WebDAV 未返回有效属性，无法确认目录内容")
                        parser.abortParsing()
                        return
                    }
                    let isDir = respIsDir || href.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
                    props.append(WebDavDrive.Prop(
                        id: id,
                        isDir: isDir,
                        size: respSize,
                        etag: respEtag,
                        contentHash: respDigest?.digest,
                        hashAlgorithm: respDigest?.algorithm
                    ))
                }
            }
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
        currentText = ""
    }
}
