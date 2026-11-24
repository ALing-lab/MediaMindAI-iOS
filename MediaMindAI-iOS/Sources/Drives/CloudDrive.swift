import Foundation
import CryptoKit
import Observation

public enum ProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case p123 = "123"
    case guangya = "guangya"
    case webdav = "webdav"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .p123: return "123云盘"
        case .guangya: return "光鸭云盘"
        case .webdav: return "WebDAV"
        }
    }

    public var idsArePaths: Bool { self == .webdav }

    public var rootId: String {
        switch self {
        case .p123: return "0"
        case .guangya: return ""
        case .webdav: return "/"
        }
    }

    public var loginHint: String {
        switch self {
        case .p123: return "账号密码或短信 / 扫码验证"
        case .guangya: return "手机号 + 短信验证码登录"
        case .webdav: return "服务器地址 + 用户名 + 密码"
        }
    }

    public static func ofOrNull(_ raw: String?) -> ProviderKind? {
        guard let raw else { return nil }
        return ProviderKind(rawValue: raw)
    }
}

public enum TrashSupport: String, Sendable {
    case recycle = "删除后进入网盘回收站，可恢复"
    case permanent = "WebDAV 没有回收站，删除后不可恢复"
    case none = "当前网盘不支持由本应用删除"

    public static func noneHint(_ kind: ProviderKind) -> String {
        "\(kind.label) 当前的登录方式 / 接口不允许删除，请到 \(kind.label) App 或网页里手动删除"
    }

    /// 执行时的删除错误：权限类错误给出明确中文提示（1:1 对标 Android `TrashSupport.explain`）。
    public static func explain(_ kind: ProviderKind, raw: String) -> String {
        let lower = raw.lowercased()
        let permTokens = [
            "permission", "forbidden", "denied", "unauthorized", "not allowed",
            "权限", "无权", "禁止", "不允许", " 401", " 403", "(401", "(403", "http 401", "http 403",
        ]
        if permTokens.contains(where: { lower.contains($0) }) || raw.hasPrefix("401") || raw.hasPrefix("403") {
            return "没有删除权限：\(raw)。\(noneHint(kind))"
        }
        return raw
    }
}

public struct CloudEntry: Identifiable, Hashable, Codable, Sendable {
    public let fileId: String
    public let fileName: String
    public let isDir: Bool
    public let size: Int64
    public let parentFileId: String?
    public let etag: String?
    public let contentHash: String?
    public let hashAlgorithm: String?

    public var id: String { fileId }

    public init(fileId: String, fileName: String, isDir: Bool, size: Int64 = 0, parentFileId: String? = nil, etag: String? = nil, contentHash: String? = nil, hashAlgorithm: String? = nil) {
        self.fileId = fileId
        self.fileName = fileName
        self.isDir = isDir
        self.size = size
        self.parentFileId = parentFileId
        self.etag = etag
        self.contentHash = contentHash
        self.hashAlgorithm = hashAlgorithm
    }
}

public struct DriveAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: ProviderKind
    public var label: String
    public var extra: [String: String]
    public var createdAt: TimeInterval

    public init(id: String = String(UUID().uuidString.prefix(12)).lowercased(), provider: ProviderKind, label: String, extra: [String: String] = [:], createdAt: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id
        self.provider = provider
        self.label = label
        self.extra = extra
        self.createdAt = createdAt
    }
}

public enum DriveError: LocalizedError, Sendable {
    case unauthorized(String)
    case rateLimited(code: Int, message: String)
    case api(code: Int, message: String)
    case unsupported(String)
    case invalidInput(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let m), .rateLimited(_, let m), .api(_, let m),
             .unsupported(let m), .invalidInput(let m), .network(let m):
            return m
        }
    }
}

/// 统一网盘读写协议（对标 Android CloudDrive）。
public protocol CloudDrive: Sendable {
    var kind: ProviderKind { get }
    var accountId: String { get }
    /// 本地密钥 HMAC 绑定的账号凭据/端点指纹，防止扫描确认后凭据被替换（对标 Android `approvalBinding`）。
    var approvalBinding: String { get }
    var rootId: String { get }
    var writeIntervalMs: UInt64 { get }
    var isLanEndpoint: Bool { get }
    var trashSupport: TrashSupport { get }

    func list(folderId: String) async throws -> [CloudEntry]
    func rename(fileId: String, newName: String) async throws -> String
    func mkdir(parentId: String, name: String) async throws -> String
    func move(fileId: String, destParentId: String) async throws -> String
    func moveBatch(fileIds: [String], destParentId: String) async throws -> [String: String]
    func upload(parentId: String, name: String, data: Data) async throws -> String
    func trash(fileId: String) async throws -> String
    func parentIdOf(fileId: String) async throws -> String?
    func exists(parentId: String, name: String) async throws -> Bool
    func ping() async -> Bool
}

public extension CloudDrive {
    var approvalBinding: String { "" }
    var rootId: String { kind.rootId }
    var writeIntervalMs: UInt64 { 200 }
    var isLanEndpoint: Bool { false }
    var trashSupport: TrashSupport { .none }

    func moveBatch(fileIds: [String], destParentId: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        for fid in fileIds {
            out[fid] = try await move(fileId: fid, destParentId: destParentId)
        }
        return out
    }

    func trash(fileId: String) async throws -> String {
        throw DriveError.unsupported(TrashSupport.noneHint(kind))
    }

    func parentIdOf(fileId: String) async throws -> String? { nil }

    func exists(parentId: String, name: String) async throws -> Bool {
        try await list(folderId: parentId).contains { $0.fileName.caseInsensitiveCompare(name) == .orderedSame }
    }

    func ping() async -> Bool {
        do { _ = try await list(folderId: rootId); return true } catch { return false }
    }
}

/// 1:1 复刻 Android `AccountBinding.kt`：使用本地 Keychain 密钥对账号端点与凭据做 HMAC-SHA256 绑定，不暴露密码哈希。
public enum AccountBinding {
    private static let keyName = "task-binding-key-v1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedKey: Data? = nil

    private static func bindingKey() -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey, cachedKey.count == 32 {
            return cachedKey
        }
        if let encoded = KeychainStore.load(forKey: keyName), let data = Data(base64Encoded: encoded), data.count == 32 {
            cachedKey = data
            return data
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
        let data = Data(bytes)
        _ = KeychainStore.save(data.base64EncodedString(), forKey: keyName)
        cachedKey = data
        return data
    }

    public static func stamp(account: DriveAccount, secret: String) -> String {
        var parts: [String] = [account.id, account.provider.rawValue]
        for key in account.extra.keys.sorted() {
            parts.append(key)
            parts.append(account.extra[key] ?? "")
        }
        // 光鸭云盘 accessToken / expiresAt / refreshToken 会在长任务中途正常自动刷新，仅在具备唯一用户 sub 时按稳定身份签名（避免空 sub 时仅凭 deviceId 绕过换号校验）
        if account.provider == .guangya,
           let creds = GuangyaDrive.decodeCreds(secret),
           !creds.sub.isEmpty {
            parts.append("gy:\(creds.sub)|\(creds.deviceId)")
        } else {
            parts.append(secret)
        }
        let material = parts.map { "\($0.count):\($0)" }.joined()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(material.utf8), using: SymmetricKey(data: bindingKey()))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public static func requireUnchanged(account: DriveAccount, secret: String, expected: String) throws {
        guard !expected.isEmpty else { return }
        guard stamp(account: account, secret: secret) == expected else {
            throw DriveError.unauthorized("网盘登录或服务器设置已改变，请重新扫描并确认，未继续操作")
        }
    }
}

public enum DrivePaths {
    public static func join(parent: String, name: String) -> String {
        let trimmed = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "/\(name)" }
        return "/\(trimmed)/\(name)"
    }

    public static func parentOf(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let idx = trimmed.lastIndex(of: "/") else { return "/" }
        return "/" + trimmed[..<idx]
    }

    public static func nameOf(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let idx = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: idx)...])
    }
}

/// 多网盘账号管理（对标 Android AccountStore）。
@MainActor
@Observable
public final class AccountStore {
    public static let shared = AccountStore()

    private let defaults = UserDefaults.standard
    private let listKey = "mm_drive_accounts_v1"
    private let activeKey = "mm_active_account_id"

    public private(set) var accounts: [DriveAccount] = []
    public var activeAccountId: String? {
        didSet { defaults.set(activeAccountId, forKey: activeKey) }
    }

    public var activeAccount: DriveAccount? {
        accounts.first(where: { $0.id == activeAccountId }) ?? accounts.first
    }

    private init() {
        load()
    }

    public func load() {
        if let data = defaults.data(forKey: listKey),
           let decoded = try? JSONDecoder().decode([DriveAccount].self, from: data) {
            accounts = decoded
        }
        activeAccountId = defaults.string(forKey: activeKey) ?? accounts.first?.id
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: listKey)
        }
    }

    @discardableResult
    public func upsert(provider: ProviderKind, label: String, extra: [String: String] = [:], secret: String, targetId: String? = nil, dedupeSub: String? = nil) -> DriveAccount {
        if let tid = targetId, let idx = accounts.firstIndex(where: { $0.id == tid }) {
            accounts[idx].label = label
            accounts[idx].extra.merge(extra) { _, new in new }
            KeychainStore.saveAccountSecret(secret, accountId: tid)
            persist()
            activeAccountId = tid
            return accounts[idx]
        }
        if let sub = dedupeSub, !sub.isEmpty,
           let idx = accounts.firstIndex(where: { $0.provider == provider && $0.extra["sub"] == sub }) {
            accounts[idx].label = label
            accounts[idx].extra.merge(extra) { _, new in new }
            KeychainStore.saveAccountSecret(secret, accountId: accounts[idx].id)
            persist()
            activeAccountId = accounts[idx].id
            return accounts[idx]
        }
        let acct = DriveAccount(provider: provider, label: label, extra: extra)
        accounts.append(acct)
        KeychainStore.saveAccountSecret(secret, accountId: acct.id)
        persist()
        activeAccountId = acct.id
        return acct
    }

    public func get(id: String) -> DriveAccount? {
        accounts.first { $0.id == id }
    }

    public func rename(id: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].label = trimmed
        persist()
    }

    public func secretOf(id: String) -> String? {
        KeychainStore.loadAccountSecret(accountId: id)
    }

    public func saveSecret(_ secret: String, accountId: String) {
        KeychainStore.saveAccountSecret(secret, accountId: accountId)
    }

    public func approvalBinding(for accountId: String) -> String {
        guard let acct = get(id: accountId) else { return "" }
        return AccountBinding.stamp(account: acct, secret: secretOf(id: accountId) ?? "")
    }

    public func remove(id: String) {
        accounts.removeAll { $0.id == id }
        KeychainStore.deleteAccountSecret(accountId: id)
        if activeAccountId == id { activeAccountId = accounts.first?.id }
        persist()
    }

    public func buildDrive(for account: DriveAccount) throws -> any CloudDrive {
        let secret = KeychainStore.loadAccountSecret(accountId: account.id) ?? ""
        let raw: any CloudDrive
        switch account.provider {
        case .p123:
            guard !secret.isEmpty else {
                throw DriveError.unauthorized("账号「\(account.label)」凭据缺失，请重新登录")
            }
            raw = Pan123Drive(accountId: account.id, token: secret)
        case .guangya:
            guard !secret.isEmpty, let creds = GuangyaDrive.decodeCreds(secret) else {
                throw DriveError.unauthorized("光鸭账号凭据缺失或损坏，请重新登录")
            }
            raw = GuangyaDrive(accountId: account.id, initialCreds: creds) { updated in
                KeychainStore.saveAccountSecret(GuangyaDrive.encodeCreds(updated), accountId: account.id)
            }
        case .webdav:
            let baseUrl = account.extra["baseUrl"] ?? account.extra["url"] ?? ""
            let user = account.extra["user"] ?? ""
            let certPin = account.extra["certPin"] ?? account.extra["pin"]
            raw = try WebDavDrive(accountId: account.id, baseUrl: baseUrl, username: user, password: secret, pinnedFingerprint: certPin)
        }
        let binding = AccountBinding.stamp(account: account, secret: secret)
        return PacedDrive(delegate: raw, approvalBinding: binding)
    }
}
