import Foundation
import CryptoKit

/// 123 云盘驱动（1:1 逐行复刻自 Android `Pan123Client.kt` + `Pan123Drive.kt` + `Models.kt`）。
/// - 根目录 ID 为 `"0"`，ID 为十进制整型字符串且稳定（改名/移动不变）。
/// - 统一请求头 `platform: open_platform`、`app-version: 3`、桌面端 UA。
/// - `list` 支持自动翻页（每页间隔 500ms）、`firstPageOnly` 探测、`ContentDigest.parseMd5OrNull` 强格式 MD5 识别。
/// - `mkdir` 支持 `Info.FileId` / `FileId` 双路径提取与 `code == 5060` 已存在回查。
/// - `moveBatch` 按 100 项分片提交 `file/mod_pid`（`FileId` + `event: fileMove`）。
/// - `upload` 支持 `Reuse` 秒传、小文件直传 `s3_upload_object/auth` 与大文件 `SliceSize` 分片 `s3_repare_upload_parts_batch` + `upload_complete/v2`（含 `isMultipart` 标记，存储节点 PUT 不携带 Authorization）。
/// - `trash` 移入回收站（`file/trash` + `operation: true` + `event: intoRecycle`）。
public final class Pan123Drive: CloudDrive, @unchecked Sendable {
    public let kind: ProviderKind = .p123
    public let accountId: String
    public let rootId: String = "0"
    public let isLanEndpoint: Bool = false
    public let trashSupport: TrashSupport = .recycle
    public let writeIntervalMs: UInt64 = 200

    public static let tag = "123"
    public static let apiBase = "https://123pan.com/b/api/"
    public static let loginUrl = "https://login.123pan.com/api/user/sign_in"
    public static let listSleepMs: UInt64 = 500
    public static let userAgent = "Mozilla/5.0 AppleWebKit/600 Safari/600 Chrome/124.0.0.0 Edg/124.0.0.0"
    public static let webLoginUrls = [
        "https://user.123pan.cn/centerlogin",
        "https://www.123pan.com/",
        "https://www.123pan.cn/",
        "https://yun.123pan.cn/",
    ]

    private let token: String
    private let session: URLSession
    private let configuredApiBase: String
    private let pageSleepMs: UInt64

    public init(
        accountId: String,
        token: String,
        session: URLSession = .shared,
        apiBase: String = Pan123Drive.apiBase,
        pageSleepMs: UInt64 = Pan123Drive.listSleepMs
    ) {
        self.accountId = accountId
        self.token = token
        self.session = session
        self.configuredApiBase = apiBase.hasSuffix("/") ? apiBase : "\(apiBase)/"
        self.pageSleepMs = pageSleepMs
    }

    // MARK: - 1. 静态账号密码登录与风控提示

    public static func explainLogin(code: Int, message: String) -> String {
        let lower = message.lowercased()
        let captchaWords = ["验证码", "短信", "安全验证", "滑块", "人机"]
        let credWords = ["密码", "账号", "用户不存在", "不正确"]
        let hint: String
        if captchaWords.contains(where: { message.contains($0) }) || lower.contains("captcha") {
            hint = "123 要求短信/图形验证码。请改用「网页登录」完成验证，或先在官网登录一次后再试。"
        } else if credWords.contains(where: { message.contains($0) }) {
            hint = "账号或密码不对（手机号不要带 +86）。"
        } else if message.contains("频繁") || message.contains("稍后") || code == 429 {
            hint = "登录太频繁，请隔一段时间再试。"
        } else if code == 7012 {
            hint = "登录被风控（海外 IP 常见）。请改用「网页登录」，或在中国大陆网络环境下用密码登录。"
        } else {
            hint = "如果网页登录正常而这里失败，可能是账号开启了额外验证，请改用网页登录。"
        }
        return "登录失败（code=\(code)）：\(message)\n\(hint)"
    }

    /// 账号密码直连登录 123 云盘，返回 Bearer token。
    public static func loginPassport(
        _ passport: String,
        password: String,
        session: URLSession = .shared,
        loginEndpoint: String = loginUrl
    ) async throws -> String {
        let p = passport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !password.isEmpty else {
            throw DriveError.invalidInput("请填写手机号/邮箱和密码")
        }
        guard let url = URL(string: loginEndpoint) else {
            throw DriveError.invalidInput("无效的登录地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "content-type")
        req.setValue("open_platform", forHTTPHeaderField: "platform")
        req.setValue("3", forHTTPHeaderField: "app-version")
        req.setValue(userAgent, forHTTPHeaderField: "user-agent")
        let body: [String: Any] = ["passport": p, "password": password, "remember": true]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DriveError.api(code: httpStatus, message: "登录返回无法识别（HTTP \(httpStatus)）")
        }
        let code = jsonInt(obj, "code") ?? -1
        let d = obj["data"] as? [String: Any]
        let tok = (jsonStr(d, "token") ?? "").isEmpty ? (jsonStr(d, "Token") ?? "") : (jsonStr(d, "token") ?? "")
        if (code != 0 && code != 200) || tok.isEmpty {
            let rawMsg = nonEmpty(jsonStr(obj, "message"), jsonStr(obj, "msg")) ?? "未知错误"
            throw DriveError.api(code: code, message: explainLogin(code: code, message: rawMsg))
        }
        return tok
    }

    // MARK: - 2. 基础 JSON 解析与鉴权请求

    private static func jsonInt64(_ obj: [String: Any]?, _ key: String) -> Int64? {
        guard let raw = obj?[key] else { return nil }
        if let n = raw as? Int64 { return n }
        if let n = raw as? Int { return Int64(n) }
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String { return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func jsonInt(_ obj: [String: Any]?, _ key: String) -> Int? {
        jsonInt64(obj, key).map { Int($0) }
    }

    private static func jsonStr(_ obj: [String: Any]?, _ key: String) -> String? {
        guard let raw = obj?[key], !(raw is NSNull) else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    private static func nonEmpty(_ values: String?...) -> String? {
        for v in values {
            if let s = v?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    private func requireId(_ raw: String, fallback: String? = nil) throws -> Int64 {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = s.isEmpty ? (fallback ?? "") : s
        guard let v = Int64(target) else {
            throw DriveError.invalidInput("无效的 123 文件 ID：\(raw)")
        }
        return v
    }

    private struct ApiResult {
        let code: Int
        let message: String
        let data: Any?
        var ok: Bool { code == 0 || code == 200 }
        var errText: String { "code=\(code) \(message)".trimmingCharacters(in: .whitespaces) }
    }

    private func request(
        path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        allowFailure: Bool = false
    ) async throws -> ApiResult {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DriveError.unauthorized("未登录 123 云盘")
        }
        guard var comps = URLComponents(string: configuredApiBase + path) else {
            throw DriveError.invalidInput("无效的接口路径")
        }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            throw DriveError.invalidInput("无效的请求地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("open_platform", forHTTPHeaderField: "platform")
        req.setValue("3", forHTTPHeaderField: "app-version")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "user-agent")
        if let body {
            req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            await NetLog.shared.error(Self.tag, "\(path) HTTP \(status)")
            throw DriveError.unauthorized("123 云盘登录已失效（HTTP \(status)），请重新登录")
        }
        if status == 429 || status == 405 {
            await NetLog.shared.error(Self.tag, "\(path) HTTP \(status)")
            throw DriveError.rateLimited(code: status, message: "123 云盘触发限流（HTTP \(status)）")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let msg = "响应解析失败 HTTP \(status)"
            await NetLog.shared.error(Self.tag, "\(path) \(msg)")
            if allowFailure { return ApiResult(code: status, message: msg, data: nil) }
            throw DriveError.api(code: status, message: "123 \(msg)")
        }
        let apiCode = Self.jsonInt(obj, "code") ?? -1
        let msg = Self.nonEmpty(Self.jsonStr(obj, "message"), Self.jsonStr(obj, "msg")) ?? ""
        let res = ApiResult(code: apiCode, message: msg, data: obj["data"])
        if !res.ok && !allowFailure {
            await NetLog.shared.error(Self.tag, "\(path) \(res.errText)")
            if apiCode == 401 {
                throw DriveError.unauthorized("123 云盘登录已失效：\(res.errText)")
            }
            if apiCode == 429 {
                throw DriveError.rateLimited(code: 429, message: "123 云盘触发限流：\(res.errText)")
            }
            throw DriveError.api(code: apiCode, message: "123 云盘错误：\(res.errText)")
        }
        return res
    }

    // MARK: - 3. CloudDrive 读写协议（1:1 对齐 Android Pan123Client + Pan123Drive）

    public func listFiles(folderId: String, pageSize: Int = 100, firstPageOnly: Bool = false) async throws -> [CloudEntry] {
        let fid = try requireId(folderId, fallback: "0")
        var out: [CloudEntry] = []
        var page = 1
        let maxPages = 300
        if pageSleepMs > 0 {
            try await Task.sleep(nanoseconds: pageSleepMs * 1_000_000)
        }
        while true {
            try Task.checkCancellation()
            if page > maxPages {
                await NetLog.shared.error(Self.tag, "list parent=\(fid) 超过 \(maxPages) 页，停止")
                throw DriveError.api(code: -5, message: "123 目录分页异常：超过 \(maxPages) 页仍未结束，已停止")
            }
            let res = try await request(
                path: "file/list/new",
                method: "GET",
                query: [
                    "driveId": "0",
                    "parentFileId": "\(fid)",
                    "limit": "\(pageSize)",
                    "Page": "\(page)",
                    "orderBy": "file_name",
                    "orderDirection": "asc",
                    "trashed": "false",
                    "inDirectSpace": "false",
                    "event": "homeListFile",
                    "OnlyLookAbnormalFile": "0",
                ]
            )
            let data = res.data as? [String: Any]
            let items = (data?["InfoList"] as? [[String: Any]]) ?? []
            for item in items {
                let trashed = (Self.jsonInt(item, "Trashed") ?? 0) != 0
                if trashed { continue }
                guard let itemId = Self.jsonInt64(item, "FileId") else { continue }
                let name = Self.jsonStr(item, "FileName") ?? ""
                guard !name.isEmpty else { continue }
                let isDir = (Self.jsonInt(item, "Type") ?? 0) == 1
                let size = Self.jsonInt64(item, "Size") ?? 0
                let etag = Self.jsonStr(item, "Etag")
                let md5 = ContentDigest.parseMd5OrNull(etag)
                out.append(CloudEntry(
                    fileId: "\(itemId)",
                    fileName: name,
                    isDir: isDir,
                    size: size,
                    parentFileId: "\(fid)",
                    etag: etag,
                    contentHash: md5?.digest,
                    hashAlgorithm: md5?.algorithm
                ))
            }
            let next = Self.jsonStr(data, "Next") ?? ""
            if firstPageOnly || items.isEmpty || items.count < pageSize || next == "-1" {
                break
            }
            page += 1
            if pageSleepMs > 0 {
                try await Task.sleep(nanoseconds: pageSleepMs * 1_000_000)
            }
        }
        return out
    }

    public func list(folderId: String) async throws -> [CloudEntry] {
        try await listFiles(folderId: folderId)
    }

    public func ping() async -> Bool {
        do {
            _ = try await listFiles(folderId: "0", pageSize: 1, firstPageOnly: true)
            return true
        } catch {
            return false
        }
    }

    public func rename(fileId: String, newName: String) async throws -> String {
        let fid = try requireId(fileId)
        _ = try await request(
            path: "file/rename",
            method: "POST",
            body: [
                "driveId": 0,
                "FileId": fid,
                "fileName": newName,
                "duplicate": 0,
                "event": "fileRename",
            ]
        )
        return fileId
    }

    public func mkdir(parentId: String, name: String) async throws -> String {
        let pid = try requireId(parentId, fallback: "0")
        let res = try await request(
            path: "file/upload_request",
            method: "POST",
            body: [
                "driveId": 0,
                "duplicate": 0,
                "etag": "",
                "fileName": name,
                "parentFileId": pid,
                "size": 0,
                "type": 1,
                "NotReuse": true,
            ],
            allowFailure: true
        )
        var fid: Int64?
        if let d = res.data as? [String: Any] {
            if let info = d["Info"] as? [String: Any], let id = Self.jsonInt64(info, "FileId") {
                fid = id
            } else if let id = Self.jsonInt64(d, "FileId") {
                fid = id
            }
        }
        if fid == nil && res.code == 5060 {
            if let existing = try await list(folderId: "\(pid)").first(where: { $0.isDir && $0.fileName == name }) {
                return existing.fileId
            }
        }
        if !res.ok && fid == nil {
            throw DriveError.api(code: res.code, message: "123 新建文件夹失败：\(res.errText)")
        }
        guard let createdId = fid else {
            throw DriveError.api(code: -1, message: "mkdir 未返回 FileId：\(res.errText)")
        }
        return "\(createdId)"
    }

    public func move(fileId: String, destParentId: String) async throws -> String {
        _ = try await moveBatch(fileIds: [fileId], destParentId: destParentId)
        return fileId
    }

    public func moveBatch(fileIds: [String], destParentId: String) async throws -> [String: String] {
        guard !fileIds.isEmpty else { return [:] }
        let dest = try requireId(destParentId, fallback: "0")
        let numericIds = try fileIds.map { try requireId($0) }
        var idx = 0
        while idx < numericIds.count {
            let end = min(idx + 100, numericIds.count)
            let chunk = Array(numericIds[idx..<end])
            _ = try await request(
                path: "file/mod_pid",
                method: "POST",
                body: [
                    "fileIdList": chunk.map { ["FileId": $0] },
                    "parentFileId": dest,
                    "event": "fileMove",
                ]
            )
            idx = end
        }
        return Dictionary(fileIds.map { ($0, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// 移入回收站（123 网页端「删除」同款接口，可在回收站恢复）。
    public func trash(fileId: String) async throws -> String {
        let fid = try requireId(fileId)
        _ = try await request(
            path: "file/trash",
            method: "POST",
            body: [
                "driveId": 0,
                "fileTrashInfoList": [["FileId": fid]],
                "operation": true,
                "event": "intoRecycle",
            ]
        )
        return "已移入回收站"
    }

    public func upload(parentId: String, name: String, data: Data) async throws -> String {
        let pid = try requireId(parentId, fallback: "0")
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reqRes = try await request(
            path: "file/upload_request",
            method: "POST",
            body: [
                "driveId": 0,
                "duplicate": 0,
                "etag": md5,
                "fileName": name,
                "parentFileId": pid,
                "size": data.count,
                "type": 0,
            ]
        )
        guard let ud = reqRes.data as? [String: Any] else {
            throw DriveError.api(code: -1, message: "123 上传初始化返回为空")
        }
        if (ud["Reuse"] as? Bool) == true {
            return "秒传"
        }
        guard let bucket = Self.jsonStr(ud, "Bucket"), !bucket.isEmpty,
              let key = Self.jsonStr(ud, "Key"), !key.isEmpty,
              let node = Self.jsonStr(ud, "StorageNode"), !node.isEmpty,
              let uploadId = Self.jsonStr(ud, "UploadId"), !uploadId.isEmpty,
              let fileId = Self.jsonInt64(ud, "FileId") else {
            throw DriveError.api(code: -1, message: "123 上传初始化缺少必要存储字段")
        }

        let sliceSize = max(1, Self.jsonInt64(ud, "SliceSize") ?? Int64(data.count))
        if Int64(data.count) > sliceSize {
            // 多分片上传：逐片申请 s3_repare_upload_parts_batch 并 PUT 到存储节点
            let step = Int(min(sliceSize, Int64(Int.max)))
            var offset = 0
            var part = 1
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + step, data.count)
                let chunk = data.subdata(in: offset..<end)
                let prep = try await request(
                    path: "file/s3_repare_upload_parts_batch",
                    method: "POST",
                    body: [
                        "bucket": bucket,
                        "key": key,
                        "storageNode": node,
                        "uploadId": uploadId,
                        "partNumberStart": part,
                        "partNumberEnd": part + 1,
                    ]
                )
                guard let pd = prep.data as? [String: Any],
                      let urls = pd["presignedUrls"] as? [String: Any],
                      let putUrlStr = urls["\(part)"] as? String, !putUrlStr.isEmpty else {
                    throw DriveError.api(code: -1, message: "123 返回的分片上传地址为空")
                }
                try await putToStorage(url: putUrlStr, data: chunk)
                offset = end
                part += 1
            }
            try await completeUpload(fileId: fileId, bucket: bucket, key: key, node: node, uploadId: uploadId, multipart: true)
        } else {
            let auth = try await request(
                path: "file/s3_upload_object/auth",
                method: "POST",
                body: [
                    "bucket": bucket,
                    "key": key,
                    "storageNode": node,
                    "uploadId": uploadId,
                ]
            )
            guard let ad = auth.data as? [String: Any],
                  let urls = ad["presignedUrls"] as? [String: Any],
                  let putUrlStr = (urls["1"] as? String) ?? (urls.values.first as? String),
                  !putUrlStr.isEmpty else {
                throw DriveError.api(code: -1, message: "123 返回的上传地址为空")
            }
            try await putToStorage(url: putUrlStr, data: data)
            try await completeUpload(fileId: fileId, bucket: bucket, key: key, node: node, uploadId: uploadId, multipart: false)
        }
        return "ok"
    }

    private func putToStorage(url: String, data: Data) async throws {
        guard let putUrl = URL(string: url) else {
            throw DriveError.invalidInput("无效的 123 存储节点上传地址")
        }
        var req = URLRequest(url: putUrl)
        req.httpMethod = "PUT"
        req.timeoutInterval = 60
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // 存储节点 PUT 不要带 authorization
        req.setValue("", forHTTPHeaderField: "authorization")
        req.httpBody = data
        let (_, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 || status == 204 else {
            await NetLog.shared.error(Self.tag, "storage PUT HTTP \(status)")
            throw DriveError.api(code: status, message: "上传存储节点失败 HTTP \(status)（本机网络可能连不上 123 存储服务器）")
        }
    }

    private func completeUpload(
        fileId: Int64,
        bucket: String,
        key: String,
        node: String,
        uploadId: String,
        multipart: Bool
    ) async throws {
        _ = try await request(
            path: "file/upload_complete/v2",
            method: "POST",
            body: [
                "fileId": fileId,
                "bucket": bucket,
                "key": key,
                "storageNode": node,
                "uploadId": uploadId,
                "isMultipart": multipart,
            ]
        )
    }
}
