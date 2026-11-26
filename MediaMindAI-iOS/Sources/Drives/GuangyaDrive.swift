import Foundation
import CryptoKit

/// 光鸭云盘登录后保存的凭据（1:1 复刻 Android `GyCreds`，`description` 自动脱敏绝不泄露令牌）。
public struct GyCreds: Codable, Hashable, Sendable, CustomStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    /// 过期时间，毫秒时间戳；0 表示未知。
    public var expiresAt: Int64
    /// 设备 ID：优先取网页 `swangpan_web_device_id`，没有则随机 32 位十六进制。
    public var deviceId: String
    public var sub: String

    public init(accessToken: String, refreshToken: String = "", expiresAt: Int64 = 0, deviceId: String = "", sub: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.deviceId = deviceId
        self.sub = sub
    }

    public var description: String {
        "GyCreds(accessToken=***, refreshToken=\(refreshToken.isEmpty ? "" : "***"), expiresAt=\(expiresAt), sub=\(sub))"
    }
}

/// 原生短信登录挑战上下文（发送验证码后保存，用于下一步校验换取凭据）。
public struct GySmsChallenge: Sendable, Equatable {
    public let verificationId: String
    public let deviceId: String
    public let captchaToken: String
    public let phone: String

    public init(verificationId: String, deviceId: String, captchaToken: String = "", phone: String = "") {
        self.verificationId = verificationId
        self.deviceId = deviceId
        self.captchaToken = captchaToken
        self.phone = phone
    }
}

/// 光鸭风控要求人机验证（`captcha_token`）时抛出，前端据此展示验证凭证输入框。
public struct GyCaptchaRequiredError: LocalizedError, Sendable {
    public let captchaUrl: String?
    public let message: String

    public init(captchaUrl: String?, message: String) {
        self.captchaUrl = captchaUrl
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 阿里云 OSS 分片上传目标参数（1:1 对标 Android `GuangyaDrive.OssTarget`）。
public struct GuangyaOssTarget: Equatable, Sendable {
    public let bucket: String
    public let endpoint: String
    public let objectPath: String
    public let ak: String
    public let sk: String
    public let sts: String

    public init(bucket: String, endpoint: String, objectPath: String, ak: String, sk: String, sts: String) {
        self.bucket = bucket
        self.endpoint = endpoint
        self.objectPath = objectPath
        self.ak = ak
        self.sk = sk
        self.sts = sts
    }
}

/// 1:1 逐行复刻自 Android `GuangyaDrive.kt`（792 行 / 39.7 KB）：
/// - 根目录 ID 为 `""`，ID 稳定（改名/移动不变）
/// - `/userres` 主接口 + HTTP 404 自动回退 `/nd.bizuserres.s`（`/v2/` → `/v1/`）
/// - 同接口最小间隔限频（`pace(path)` 500ms）+ W3C `traceparent` + 幂等请求 `[2s, 5s]` 退避重试 + 完整中文错误码表
/// - 分页死循环签名检测（`maxPages = 300` + `prevSig` + `added == 0`）
/// - 100 项分片 `moveBatch` + `get_task_status` 异步轮询（2 完成 / 3,-1 失败）
/// - `get_res_center_token` 秒传（156）+ 阿里云 OSS V1 HMAC-SHA1 分片上传（含 `uploadId` URL 编码守卫）+ `get_info_by_task_id` 轮询
/// - E.164 国际手机号精准切分 + 原生两步短信登录 + `refresh_token` 并发单次刷新
public actor GuangyaDrive: CloudDrive {
    public nonisolated let kind: ProviderKind = .guangya
    public nonisolated let accountId: String
    public nonisolated let rootId: String = ""
    public nonisolated let isLanEndpoint: Bool = false
    public nonisolated let trashSupport: TrashSupport = .none
    public nonisolated var writeIntervalMs: UInt64 { pathIntervalMs }

    public static let tag = "光鸭"
    public static let apiBase = "https://api.guangyapan.com"
    public static let accountBase = "https://account.guangyapan.com"
    public static let clientId = "aMe-8VSlkrbQXpUR"
    public static let pageSize = 100
    public static let codeTokenInvalid = 117
    public static let codeUploadDone = 156
    public static let uploadProcessingCodes: Set<Int> = [145, 146, 147, 155, 163]
    private static let defaultDevice = String(repeating: "0", count: 32)

    private var creds: GyCreds
    private let session: URLSession
    private let onCredsUpdated: (@Sendable (GyCreds) -> Void)?
    private let configuredApiBase: String
    private let configuredAccountBase: String
    private let pathIntervalMs: UInt64
    private let pollIntervalMs: UInt64
    private let maxPolls: Int
    private let ossUrlOverride: String?
    private let maxPages: Int
    private let retryDelaysMs: [UInt64]
    private var lastCallMs: [String: UInt64] = [:]

    private struct NotFoundError: Error {}

    public init(
        accountId: String,
        initialCreds: GyCreds,
        session: URLSession = .shared,
        apiBase: String = GuangyaDrive.apiBase,
        accountBase: String = GuangyaDrive.accountBase,
        pathIntervalMs: UInt64 = 500,
        pollIntervalMs: UInt64 = 1000,
        maxPolls: Int = 60,
        ossUrlOverride: String? = nil,
        maxPages: Int = 300,
        retryDelaysMs: [UInt64] = [2_000, 5_000],
        onCredsUpdated: (@Sendable (GyCreds) -> Void)? = nil
    ) {
        self.accountId = accountId
        self.creds = initialCreds
        self.session = session
        self.configuredApiBase = apiBase
        self.configuredAccountBase = accountBase
        self.pathIntervalMs = pathIntervalMs
        self.pollIntervalMs = pollIntervalMs
        self.maxPolls = maxPolls
        self.ossUrlOverride = ossUrlOverride
        self.maxPages = maxPages
        self.retryDelaysMs = retryDelaysMs
        self.onCredsUpdated = onCredsUpdated
    }

    // MARK: - 1. 静态认证、手机号规范化、错误码与 OSS V1 签名

    private static let knownCallingCodes: [String] = [
        "1", "7",
        "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49",
        "51", "52", "53", "54", "55", "56", "57", "58", "60", "61", "62", "63", "64", "65", "66",
        "81", "82", "84", "86", "90", "91", "92", "93", "94", "95", "98",
        "852", "853", "886", "855", "856", "880", "960", "966", "971", "972",
    ]
    private static let explicitIntlRegex = try! NSRegularExpression(pattern: #"^\+(\d{1,3})\s+([\d\s()-]{6,})$"#)
    private static let uploadIdRegex = try! NSRegularExpression(pattern: #"<UploadId>([^<]+)</UploadId>"#)
    private static let ossCodeRegex = try! NSRegularExpression(pattern: #"<Code>([^<]+)</Code>"#)

    public static func randomDeviceId() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public static func traceparent() -> String {
        let traceId = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let spanId = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return "00-\(traceId)-\(spanId)-01"
    }

    public static func encodeCreds(_ c: GyCreds) -> String {
        (try? JSONEncoder().encode(c)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public static func decodeCreds(_ s: String?) -> GyCreds? {
        guard let data = s?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GyCreds.self, from: data)
    }

    public static func accountHeaders(deviceId: String) -> [String: String] {
        [
            "X-Client-Id": clientId,
            "X-Client-Version": "0.0.1",
            "X-Device-Id": deviceId,
            "X-Device-Model": "chrome%2F147.0.0.0",
            "X-Device-Name": "PC-Chrome",
            "X-Device-Sign": "wdi10.\(deviceId)",
            "X-Net-Work-Type": "NONE",
            "X-OS-Version": "MacIntel",
            "X-Platform-Version": "1",
            "X-Protocol-Version": "301",
            "X-Provider-Name": "NONE",
            "X-SDK-Version": "9.0.2",
        ]
    }

    /// 标准化手机号：中国大陆 11 位自动补 `"+86 "`；国际号保留显式区号空格或按 E.164 前缀表切分。
    public static func normalizePhone(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        if let m = explicitIntlRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            let cc = ns.substring(with: m.range(at: 1))
            let sub = ns.substring(with: m.range(at: 2)).filter(\.isNumber)
            if sub.count >= 6 { return "+\(cc) \(sub)" }
        }
        let cleaned = trimmed
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        if cleaned.hasPrefix("+") {
            let digits = String(cleaned.dropFirst())
            guard digits.allSatisfy(\.isNumber), digits.count >= 7 else { return trimmed }
            if let matched = knownCallingCodes.first(where: { digits.hasPrefix($0) && digits.count - $0.count >= 6 }) {
                return "+\(matched) \(digits.dropFirst(matched.count))"
            }
            return trimmed
        }
        if cleaned.count == 11 && cleaned.hasPrefix("1") && cleaned.allSatisfy(\.isNumber) {
            return "+86 \(cleaned)"
        }
        return trimmed
    }

    /// 业务码 → 中文提示（1:1 复刻 Android `GuangyaDrive.errorText` 码表）。
    public static func errorText(code: Int, msg: String?) -> String {
        let base: String
        switch code {
        case codeTokenInvalid, 110, 118: base = "光鸭登录已失效，请重新登录"
        case 111, 123: base = "光鸭拒绝访问（无权限）"
        case 112: base = "光鸭请求参数不合法"
        case 142: base = "光鸭远端目录不存在"
        case 143, 146: base = "光鸭文件不存在或已被删除"
        case 145: base = "光鸭任务不存在"
        case 149: base = "文件已在回收站"
        case 152: base = "光鸭上传任务不存在"
        case 154: base = "光鸭目标对象不是目录"
        case 160: base = "光鸭远端已存在同名文件或目录"
        case 163: base = "光鸭上传任务已过期"
        case 430: base = "该操作需要光鸭会员"
        default: base = "光鸭云盘返回错误"
        }
        let m = (msg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty || m.caseInsensitiveCompare("success") == .orderedSame {
            return "\(base)（code \(code)）"
        }
        return "\(base)：\(m)（code \(code)）"
    }

    /// 阿里云 OSS V1 HMAC-SHA1 签名（1:1 对标 Android `GuangyaDrive.ossSignV1`）。
    public static func ossSignV1(
        secret: String,
        verb: String,
        contentMd5: String,
        contentType: String,
        date: String,
        ossHeaders: [String: String],
        resource: String
    ) -> String {
        let canonHeaders = ossHeaders
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
        let stringToSign = "\(verb)\n\(contentMd5)\n\(contentType)\n\(date)\n\(canonHeaders)\(resource)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    public static func httpDate(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return df.string(from: date)
    }

    private static func isConnectFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
        ].contains(ns.code)
    }

    private static func netReason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "无法解析光鸭服务器地址，请检查网络 / DNS"
            case NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet:
                return "网络无法连接光鸭服务器，请检查 Wi-Fi、VPN 或代理设置后重试"
            case NSURLErrorTimedOut:
                return "请求超时（60 秒内无完整响应）"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func postAccountJson(
        url: String,
        body: [String: Any],
        deviceId: String,
        captchaToken: String = "",
        session: URLSession = .shared
    ) async throws -> (Int, [String: Any]?) {
        guard let reqUrl = URL(string: url) else { throw DriveError.invalidInput("无效的账号服务地址") }
        var req = URLRequest(url: reqUrl)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in accountHeaders(deviceId: deviceId) { req.setValue(v, forHTTPHeaderField: k) }
        if !captchaToken.isEmpty { req.setValue(captchaToken, forHTTPHeaderField: "X-Captcha-Token") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status, obj)
    }

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

    private static func accountErrorDesc(_ obj: [String: Any]?, fallback: String) -> String {
        for key in ["error_description", "error", "msg"] {
            if let s = obj?[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return fallback
    }

    /// 原生短信登录第一步：自动获取无感 `captcha_token`（若需滑块则抛 `GyCaptchaRequiredError`），并发送短信验证码。
    public static func sendSmsCode(
        rawPhone: String,
        deviceId: String = randomDeviceId(),
        captchaToken: String = "",
        base: String = accountBase,
        session: URLSession = .shared
    ) async throws -> GySmsChallenge {
        let phone = normalizePhone(rawPhone)
        guard phone.count >= 7 else { throw DriveError.invalidInput("请输入有效的手机号") }
        let trimmedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var token = captchaToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if token.isEmpty {
            let initBody: [String: Any] = [
                "client_id": clientId,
                "action": "POST:/v1/auth/verification",
                "device_id": deviceId,
                "meta": ["phone_number": phone],
            ]
            let (initCode, initObj) = try await postAccountJson(
                url: "\(trimmedBase)/v1/shield/captcha/init",
                body: initBody,
                deviceId: deviceId,
                session: session
            )
            if (200...299).contains(initCode), let initObj {
                let ct = (initObj["captcha_token"] as? String) ?? ""
                let challengeUrl = (initObj["url"] as? String) ?? ""
                if !ct.isEmpty {
                    token = ct
                } else if !challengeUrl.isEmpty {
                    throw GyCaptchaRequiredError(captchaUrl: challengeUrl, message: "光鸭风控要求人机验证，请稍后重试或填写 captcha_token")
                }
            }
        }

        var sendBody: [String: Any] = [
            "client_id": clientId,
            "phone_number": phone,
        ]
        if !token.isEmpty { sendBody["captcha_token"] = token }
        let (code, obj) = try await postAccountJson(
            url: "\(trimmedBase)/v1/auth/verification",
            body: sendBody,
            deviceId: deviceId,
            captchaToken: token,
            session: session
        )
        guard (200...299).contains(code), let obj else {
            let err = accountErrorDesc(obj, fallback: "HTTP \(code)")
            if err.localizedCaseInsensitiveContains("captcha") || err.contains("验证") || err.contains("滑块") {
                throw GyCaptchaRequiredError(captchaUrl: nil, message: "光鸭风控要求人机验证（\(err)），请稍后重试或填写 captcha_token")
            }
            throw DriveError.api(code: code, message: "发送验证码失败：\(err)")
        }
        guard let vid = obj["verification_id"] as? String, !vid.isEmpty else {
            throw DriveError.api(code: -1, message: "光鸭未返回 verification_id：\(accountErrorDesc(obj, fallback: "请重试"))")
        }
        return GySmsChallenge(verificationId: vid, deviceId: deviceId, captchaToken: token, phone: phone)
    }

    /// 原生短信登录第二步：校验短信验证码并换取 `access_token` / `refresh_token`。
    public static func verifySmsLogin(
        challenge: GySmsChallenge,
        code: String,
        base: String = accountBase,
        session: URLSession = .shared
    ) async throws -> GyCreds {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { throw DriveError.invalidInput("请输入完整的短信验证码") }
        let trimmedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let verifyBody: [String: Any] = [
            "client_id": clientId,
            "verification_id": challenge.verificationId,
            "verification_code": trimmed,
        ]
        let (vCode, vObj) = try await postAccountJson(
            url: "\(trimmedBase)/v1/auth/verification/verify",
            body: verifyBody,
            deviceId: challenge.deviceId,
            captchaToken: challenge.captchaToken,
            session: session
        )
        guard (200...299).contains(vCode), let vObj else {
            throw DriveError.api(code: vCode, message: "验证码校验失败：\(accountErrorDesc(vObj, fallback: "HTTP \(vCode)"))")
        }

        let tokenObj: [String: Any]
        if let at = vObj["access_token"] as? String, !at.isEmpty {
            tokenObj = vObj
        } else {
            guard let vToken = vObj["verification_token"] as? String, !vToken.isEmpty else {
                throw DriveError.api(code: -1, message: "验证码校验未返回 verification_token")
            }
            // 步骤 1：优先不带发码旧 captcha_token 直接用 verification_token 换取登录凭据
            let plainSignBody: [String: Any] = [
                "client_id": clientId,
                "verification_token": vToken,
            ]
            var (sCode, sObj) = try await postAccountJson(
                url: "\(trimmedBase)/v1/auth/signin",
                body: plainSignBody,
                deviceId: challenge.deviceId,
                captchaToken: "",
                session: session
            )

            // 步骤 2：若服务端要求 /v1/auth/signin 必须携带 captcha_token，按 meta.username 精确对齐重试
            if !(200...299).contains(sCode) {
                let firstErr = accountErrorDesc(sObj, fallback: "").lowercased()
                if firstErr.contains("captcha") || firstErr.contains("username") || sCode == 400 {
                    let metaCandidates: [([String: Any], String?)] = challenge.phone.isEmpty
                        ? [(["username": ""], nil)]
                        : [(["username": challenge.phone], challenge.phone), (["username": ""], nil)]

                    for (metaDict, bodyUsername) in metaCandidates {
                        let initBody: [String: Any] = [
                            "client_id": clientId,
                            "action": "POST:/v1/auth/signin",
                            "device_id": challenge.deviceId,
                            "meta": metaDict,
                        ]
                        guard let (iCode, iObj) = try? await postAccountJson(
                            url: "\(trimmedBase)/v1/shield/captcha/init",
                            body: initBody,
                            deviceId: challenge.deviceId,
                            session: session
                        ), (200...299).contains(iCode), let iObj,
                           let ct = iObj["captcha_token"] as? String, !ct.isEmpty else {
                            continue
                        }
                        var retryBody: [String: Any] = [
                            "client_id": clientId,
                            "verification_token": vToken,
                            "captcha_token": ct,
                        ]
                        if let u = bodyUsername { retryBody["username"] = u }
                        let (rCode, rObj) = try await postAccountJson(
                            url: "\(trimmedBase)/v1/auth/signin",
                            body: retryBody,
                            deviceId: challenge.deviceId,
                            captchaToken: ct,
                            session: session
                        )
                        sCode = rCode
                        sObj = rObj
                        if (200...299).contains(sCode) { break }
                    }
                }
            }
            guard (200...299).contains(sCode), let sObj else {
                throw DriveError.api(code: sCode, message: "光鸭登录失败：\(accountErrorDesc(sObj, fallback: "HTTP \(sCode)"))")
            }
            tokenObj = sObj
        }

        guard let at = tokenObj["access_token"] as? String, !at.isEmpty else {
            throw DriveError.api(code: -1, message: "光鸭登录响应缺少 access_token")
        }
        let rt = (tokenObj["refresh_token"] as? String) ?? ""
        let exIn = jsonInt64(tokenObj, "expires_in") ?? 0
        let expAt: Int64 = exIn > 0 ? Int64(Date().timeIntervalSince1970 * 1000) + exIn * 1000 : 0
        let sub = (tokenObj["sub"] as? String) ?? ""
        return GyCreds(accessToken: at, refreshToken: rt, expiresAt: expAt, deviceId: challenge.deviceId, sub: sub)
    }

    // MARK: - 2. 凭据刷新、同路径限频与 404 回退业务请求

    private func activeDeviceId() -> String {
        creds.deviceId.isEmpty ? Self.defaultDevice : creds.deviceId
    }

    private var refreshInFlight: Task<Void, Error>?

    private func refreshTokenIfNeeded(staleAccessToken: String? = nil, force: Bool = false) async throws {
        if let inflight = refreshInFlight {
            try await inflight.value
            return
        }
        guard !creds.accessToken.isEmpty else {
            throw DriveError.unauthorized("光鸭云盘未登录，请在「网盘账号」里重新登录")
        }
        if let stale = staleAccessToken, creds.accessToken != stale { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if !force && (creds.expiresAt == 0 || creds.expiresAt - nowMs > 60_000) { return }
        guard !creds.refreshToken.isEmpty else {
            throw DriveError.unauthorized("光鸭登录已过期，请重新登录")
        }
        let task = Task { try await self.performTokenRefresh() }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        try await task.value
    }

    private func performTokenRefresh() async throws {

        let body: [String: Any] = [
            "client_id": Self.clientId,
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
        ]
        let trimmedAccount = configuredAccountBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let (code, obj): (Int, [String: Any]?)
        do {
            (code, obj) = try await Self.postAccountJson(
                url: "\(trimmedAccount)/v1/auth/token",
                body: body,
                deviceId: activeDeviceId(),
                session: session
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let why = Self.netReason(error)
            await NetLog.shared.error(Self.tag, "refresh \(why)")
            throw DriveError.network("刷新光鸭登录失败：\(why)")
        }

        guard (200...299).contains(code) else {
            if (400...499).contains(code) {
                creds.expiresAt = 1
                onCredsUpdated?(creds)
            }
            await NetLog.shared.error(Self.tag, "refresh HTTP \(code)")
            throw DriveError.unauthorized("光鸭登录已过期，请重新登录（刷新失败 HTTP \(code)）")
        }
        guard let obj, let at = obj["access_token"] as? String, !at.isEmpty else {
            throw DriveError.unauthorized("光鸭刷新登录返回异常，请重新登录")
        }
        let exIn = Self.jsonInt64(obj, "expires_in") ?? 0
        creds.accessToken = at
        if let rt = obj["refresh_token"] as? String, !rt.isEmpty { creds.refreshToken = rt }
        creds.expiresAt = exIn > 0 ? (Int64(Date().timeIntervalSince1970 * 1000) + exIn * 1000) : 0
        if let sub = obj["sub"] as? String, !sub.isEmpty { creds.sub = sub }
        onCredsUpdated?(creds)
    }

    private func pace(path: String) async throws {
        guard pathIntervalMs > 0 else { return }
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let last = lastCallMs[path] ?? 0
        let waitMs = (last + pathIntervalMs > nowMs) ? (last + pathIntervalMs - nowMs) : 0
        lastCallMs[path] = nowMs + waitMs
        if waitMs > 0 {
            try await Task.sleep(nanoseconds: waitMs * 1_000_000)
        }
    }

    private func api(_ path: String, body: [String: Any], allowCodes: Set<Int> = [], idempotent: Bool = false) async throws -> [String: Any] {
        do {
            return try await call(fullPath: "/userres\(path)", body: body, allowCodes: allowCodes, idempotent: idempotent)
        } catch is NotFoundError {
            let fallbackPath = "/nd.bizuserres.s\(path)".replacingOccurrences(of: "/v2/", with: "/v1/")
            return try await call(fullPath: fallbackPath, body: body, allowCodes: allowCodes, idempotent: idempotent)
        }
    }

    private func call(fullPath: String, body: [String: Any], allowCodes: Set<Int>, idempotent: Bool) async throws -> [String: Any] {
        try await refreshTokenIfNeeded()
        var retriedAuth = false
        var attempt = 0
        let trimmedBase = configuredApiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        while true {
            try Task.checkCancellation()
            try await pace(path: fullPath)
            guard let reqUrl = URL(string: "\(trimmedBase)\(fullPath)") else {
                throw DriveError.invalidInput("无效的接口路径")
            }
            let usedToken = creds.accessToken
            var req = URLRequest(url: reqUrl)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("Bearer \(usedToken)", forHTTPHeaderField: "Authorization")
            req.setValue(activeDeviceId(), forHTTPHeaderField: "did")
            req.setValue("4", forHTTPHeaderField: "dt")
            req.setValue(Self.traceparent(), forHTTPHeaderField: "traceparent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let why = Self.netReason(error)
                if Self.isConnectFailure(error) {
                    await NetLog.shared.error(Self.tag, "\(fullPath) \(why)")
                    throw DriveError.network(why)
                }
                if idempotent && attempt < retryDelaysMs.count {
                    let waitMs = retryDelaysMs[attempt]
                    attempt += 1
                    try await Task.sleep(nanoseconds: waitMs * 1_000_000)
                    continue
                }
                await NetLog.shared.error(Self.tag, "\(fullPath) \(why)")
                throw DriveError.network("连接光鸭云盘失败：\(why)")
            }

            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { throw NotFoundError() }
            if status == 401 || status == 403 {
                if !retriedAuth {
                    try await refreshTokenIfNeeded(staleAccessToken: usedToken, force: true)
                    retriedAuth = true
                    continue
                }
                throw DriveError.unauthorized("光鸭登录凭据已失效（HTTP \(status)），请重新登录")
            }
            if status == 429 || status >= 500 {
                if idempotent && attempt < retryDelaysMs.count {
                    let waitMs = retryDelaysMs[attempt]
                    attempt += 1
                    try await Task.sleep(nanoseconds: waitMs * 1_000_000)
                    continue
                }
                if status == 429 {
                    throw DriveError.rateLimited(code: 429, message: "光鸭云盘请求太频繁，请稍后再试")
                }
            }
            guard (200...299).contains(status) else {
                throw DriveError.api(code: status, message: "光鸭云盘服务异常（HTTP \(status)）")
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw DriveError.api(code: -1, message: "光鸭云盘返回了无法解析的数据")
            }
            let code = Self.jsonInt(obj, "code") ?? 0
            if allowCodes.contains(code) { return obj }
            if (code == Self.codeTokenInvalid || code == 110 || code == 118) && !retriedAuth {
                try await refreshTokenIfNeeded(staleAccessToken: usedToken, force: true)
                retriedAuth = true
                continue
            }
            if code != 0 {
                let msg = Self.errorText(code: code, msg: obj["msg"] as? String)
                if code == Self.codeTokenInvalid || code == 110 || code == 118 {
                    throw DriveError.unauthorized(msg)
                }
                throw DriveError.api(code: code, message: msg)
            }
            return obj
        }
    }

    // MARK: - 3. 读操作（分页死循环检测 + parentIdOf + ping）

    public func list(folderId: String) async throws -> [CloudEntry] {
        var out: [CloudEntry] = []
        var seen = Set<String>()
        var page = 0
        var prevSig: String? = nil

        while true {
            try Task.checkCancellation()
            if page >= maxPages {
                await NetLog.shared.error(Self.tag, "list parent=\(folderId) 超过 \(maxPages) 页，停止")
                throw DriveError.api(code: -5, message: "光鸭目录分页异常：超过 \(maxPages) 页仍未结束，已停止")
            }
            let o = try await api("/v1/file/get_file_list", body: [
                "parentId": folderId,
                "page": page,
                "pageSize": Self.pageSize,
                "orderBy": 0,
                "sortType": 0,
            ], idempotent: true)

            guard let data = o["data"] as? [String: Any] else { break }
            let items = (data["list"] as? [[String: Any]]) ?? []
            var added = 0
            var pageIds: [String] = []
            pageIds.reserveCapacity(items.count)

            for item in items {
                guard let id = Self.jsonStr(item, "fileId"), !id.isEmpty else { continue }
                pageIds.append(id)
                guard seen.insert(id).inserted else { continue }
                added += 1
                let resType = Self.jsonInt64(item, "resType") ?? 0
                let fileSize = Self.jsonInt64(item, "fileSize") ?? 0
                let parent = (item["parentId"] as? String) ?? folderId
                let md5 = Self.jsonStr(item, "md5")
                let parsedMd5 = ContentDigest.parseMd5OrNull(md5)
                out.append(CloudEntry(
                    fileId: id,
                    fileName: (item["fileName"] as? String) ?? "",
                    isDir: resType == 2,
                    size: fileSize,
                    parentFileId: parent,
                    etag: md5,
                    contentHash: parsedMd5?.digest,
                    hashAlgorithm: parsedMd5?.algorithm
                ))
            }

            let total = Self.jsonInt(data, "total") ?? 0
            page += 1
            if items.isEmpty || items.count < Self.pageSize || (total > 0 && out.count >= total) { break }
            let sig = pageIds.joined(separator: ",")
            if sig == prevSig || added == 0 {
                await NetLog.shared.error(Self.tag, "list parent=\(folderId) page=\(page - 1) 与上一页重复，停止翻页")
                break
            }
            prevSig = sig
        }
        return out
    }

    public func ping() async -> Bool {
        (try? await list(folderId: rootId)) != nil
    }

    public func parentIdOf(fileId: String) async throws -> String? {
        guard !fileId.isEmpty else { return nil }
        let o = try await api("/v1/file/get_info_by_file_id", body: ["fileId": fileId], idempotent: true)
        guard let d = o["data"] as? [String: Any] else { return nil }
        let info = (d["fileInfo"] as? [String: Any]) ?? d
        return Self.jsonStr(info, "parentId")
    }

    // MARK: - 4. 写操作（改名、建目录竞态回退、100项分片移动与任务轮询、秒传+OSS分片上传、回收站）

    public func rename(fileId: String, newName: String) async throws -> String {
        _ = try await api("/v1/file/rename", body: ["fileId": fileId, "newName": newName])
        return fileId
    }

    public func mkdir(parentId: String, name: String) async throws -> String {
        if let existing = try await list(folderId: parentId).first(where: { $0.isDir && $0.fileName.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing.fileId
        }
        let o: [String: Any]
        do {
            o = try await api("/v1/file/create_dir", body: [
                "parentId": parentId,
                "dirName": name,
                "failIfNameExist": false,
            ])
        } catch {
            // 并发/竞态下目录已存在：再查一次
            if let existing = try? await list(folderId: parentId).first(where: { $0.isDir && $0.fileName.caseInsensitiveCompare(name) == .orderedSame }) {
                return existing.fileId
            }
            throw error
        }
        if let fid = (o["data"] as? [String: Any])?["fileId"] as? String, !fid.isEmpty {
            return fid
        }
        if let existing = try await list(folderId: parentId).first(where: { $0.isDir && $0.fileName == name }) {
            return existing.fileId
        }
        throw DriveError.api(code: -1, message: "光鸭新建文件夹「\(name)」后没有拿到文件夹 ID")
    }

    public func move(fileId: String, destParentId: String) async throws -> String {
        _ = try await moveBatch(fileIds: [fileId], destParentId: destParentId)
        return fileId
    }

    public func moveBatch(fileIds: [String], destParentId: String) async throws -> [String: String] {
        guard !fileIds.isEmpty else { return [:] }
        var idx = 0
        while idx < fileIds.count {
            let end = min(idx + 100, fileIds.count)
            let chunk = Array(fileIds[idx..<end])
            let o = try await api("/v1/file/move_file", body: [
                "fileIds": chunk,
                "parentId": destParentId,
            ])
            if let taskId = (o["data"] as? [String: Any])?["taskId"] as? String, !taskId.isEmpty {
                try await waitTask(taskId: taskId, what: chunk.count > 1 ? "批量移动" : "移动")
            }
            idx = end
        }
        return Dictionary(fileIds.map { ($0, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func waitTask(taskId: String, what: String) async throws {
        for i in 0..<maxPolls {
            try Task.checkCancellation()
            if i > 0 || pollIntervalMs > 0 {
                try await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
            }
            let o = try await api("/v1/get_task_status", body: ["taskId": taskId], idempotent: true)
            let status = Self.jsonInt(o["data"] as? [String: Any], "status")
            if status == 2 { return }
            if status == 3 || status == -1 {
                throw DriveError.api(code: -2, message: "光鸭后台\(what)任务失败")
            }
        }
        throw DriveError.api(code: -3, message: "光鸭后台\(what)任务超时（仍在处理中，可稍后在网页端确认）")
    }

    public func upload(parentId: String, name: String, data: Data) async throws -> String {
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let o = try await api("/v2/get_res_center_token", body: [
            "capacity": 2,
            "name": name,
            "parentId": parentId,
            "res": ["fileSize": data.count, "md5": md5],
        ], allowCodes: [Self.codeUploadDone])

        guard let d = o["data"] as? [String: Any] else {
            throw DriveError.api(code: -1, message: "光鸭上传凭证为空")
        }
        guard let taskId = d["taskId"] as? String, !taskId.isEmpty else {
            throw DriveError.api(code: -1, message: "光鸭上传凭证缺少 taskId")
        }
        let code = Self.jsonInt(o, "code") ?? 0
        let msg = (o["msg"] as? String) ?? ""
        if code == Self.codeUploadDone || msg.contains("秒传") || msg.contains("上传已完成") {
            return try await waitUploaded(taskId: taskId)
        }

        let dKeys = d.keys.sorted().joined(separator: ",")
        let cKeys = (d["creds"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "无"
        await NetLog.shared.line(Self.tag, "上传凭证字段：\(dKeys) · creds=\(cKeys)")
        guard let ossCreds = d["creds"] as? [String: Any] else {
            throw DriveError.api(code: -1, message: "光鸭上传凭证缺少 STS")
        }
        let target = GuangyaOssTarget(
            bucket: (d["bucketName"] as? String) ?? "",
            endpoint: (d["endPoint"] as? String) ?? "",
            objectPath: (d["objectPath"] as? String) ?? "",
            ak: (ossCreds["accessKeyID"] as? String) ?? "",
            sk: (ossCreds["secretAccessKey"] as? String) ?? "",
            sts: (ossCreds["sessionToken"] as? String) ?? ""
        )
        guard !target.bucket.isEmpty, !target.objectPath.isEmpty, !target.ak.isEmpty else {
            throw DriveError.api(code: -1, message: "光鸭上传凭证不完整")
        }
        try await ossMultipartUpload(target: target, data: data)
        return try await waitUploaded(taskId: taskId)
    }

    private func waitUploaded(taskId: String) async throws -> String {
        for i in 0..<maxPolls {
            try Task.checkCancellation()
            if i > 0 || pollIntervalMs > 0 {
                try await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
            }
            do {
                let o = try await api("/v1/file/get_info_by_task_id", body: ["taskId": taskId], idempotent: true)
                if let fid = (o["data"] as? [String: Any])?["fileId"] as? String, !fid.isEmpty {
                    return fid
                }
            } catch let DriveError.api(code, _) where Self.uploadProcessingCodes.contains(code) {
                continue
            }
        }
        throw DriveError.api(code: -3, message: "光鸭上传后处理超时（文件可能稍后出现）")
    }

    public func trash(fileId: String) async throws -> String {
        throw DriveError.unsupported("光鸭云盘 当前的登录方式 / 接口不允许删除，请到 光鸭云盘 App 或网页里手动删除")
    }

    // MARK: - 5. 阿里云 OSS 分片上传（1:1 复刻 ossBase / ossMultipartUpload / ossCall）

    public func ossBase(for target: GuangyaOssTarget) -> String {
        if let override = ossUrlOverride {
            return override.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        var ep = target.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if ep.hasPrefix("https://") { ep.removeFirst(8) }
        else if ep.hasPrefix("http://") { ep.removeFirst(7) }
        ep = ep.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !ep.hasPrefix("\(target.bucket).") {
            ep = "\(target.bucket).\(ep)"
        }
        return "https://\(ep)"
    }

    private static func encodeOssQueryValue(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private func ossMultipartUpload(target: GuangyaOssTarget, data: Data) async throws {
        let base = ossBase(for: target)
        let key = target.objectPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encKey = key.split(separator: "/").map { Self.encodeOssQueryValue(String($0)) }.joined(separator: "/")

        // 1. Initiate Multipart Upload
        let initXml = try await ossCall(
            target: target,
            method: "POST",
            url: "\(base)/\(encKey)?uploads",
            resource: "/\(target.bucket)/\(key)?uploads",
            body: Data(),
            contentType: ""
        )
        let nsInit = initXml as NSString
        guard let m = Self.uploadIdRegex.firstMatch(in: initXml, range: NSRange(location: 0, length: nsInit.length)) else {
            throw DriveError.api(code: -4, message: "光鸭存储初始化上传失败")
        }
        let uploadId = nsInit.substring(with: m.range(at: 1))
        // UploadId 可能含 + / =，放进 URL 前必须编码；签名用的 CanonicalizedResource 仍用原值
        let encId = Self.encodeOssQueryValue(uploadId)

        // 2. Upload Part 1
        let partUrl = "\(base)/\(encKey)?partNumber=1&uploadId=\(encId)"
        let etag = try await ossCall(
            target: target,
            method: "PUT",
            url: partUrl,
            resource: "/\(target.bucket)/\(key)?partNumber=1&uploadId=\(uploadId)",
            body: data,
            contentType: "",
            wantEtag: true
        )

        // 3. Complete Multipart Upload
        let completeXml = "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\(etag)</ETag></Part></CompleteMultipartUpload>"
        _ = try await ossCall(
            target: target,
            method: "POST",
            url: "\(base)/\(encKey)?uploadId=\(encId)",
            resource: "/\(target.bucket)/\(key)?uploadId=\(uploadId)",
            body: Data(completeXml.utf8),
            contentType: "application/xml"
        )
    }

    private func ossCall(
        target: GuangyaOssTarget,
        method: String,
        url: String,
        resource: String,
        body: Data,
        contentType: String,
        wantEtag: Bool = false
    ) async throws -> String {
        guard let reqUrl = URL(string: url) else {
            throw DriveError.invalidInput("无效的 OSS 上传地址")
        }
        let date = Self.httpDate()
        var ossHeaders: [String: String] = [:]
        if !target.sts.isEmpty { ossHeaders["x-oss-security-token"] = target.sts }
        let sig = Self.ossSignV1(
            secret: target.sk,
            verb: method,
            contentMd5: "",
            contentType: contentType,
            date: date,
            ossHeaders: ossHeaders,
            resource: resource
        )
        var req = URLRequest(url: reqUrl)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue(date, forHTTPHeaderField: "Date")
        req.setValue("OSS \(target.ak):\(sig)", forHTTPHeaderField: "Authorization")
        for (k, v) in ossHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if !contentType.isEmpty { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body.isEmpty ? nil : body

        let (respData, resp) = try await session.data(for: req)
        let httpResp = resp as? HTTPURLResponse
        let status = httpResp?.statusCode ?? 0
        let text = String(data: respData, encoding: .utf8) ?? ""
        guard (200...299).contains(status) else {
            let nsText = text as NSString
            let errCode: String
            if let cm = Self.ossCodeRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                errCode = nsText.substring(with: cm.range(at: 1))
            } else {
                errCode = "HTTP \(status)"
            }
            throw DriveError.api(code: -4, message: "光鸭存储上传失败：\(errCode)")
        }
        if wantEtag {
            let etag = httpResp?.value(forHTTPHeaderField: "ETag") ?? httpResp?.value(forHTTPHeaderField: "etag")
            guard let etag, !etag.isEmpty else {
                throw DriveError.api(code: -4, message: "光鸭存储没有返回 ETag")
            }
            return etag
        }
        return text
    }
}
