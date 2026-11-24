import Foundation
import Security

/// iOS Keychain 安全存储（对标 Android SecureStore / EncryptedSharedPreferences）。
/// 所有 API Key、网盘令牌与 WebDAV 密码均以 ThisDeviceOnly 级别存入系统钥匙串，绝不写入日志或 UserDefaults。
public enum KeychainStore {
    private static let service = "com.tamu.mediamind.ios"

    @discardableResult
    public static func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func load(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - 业务密钥便捷读写

    public static var tmdbApiKey: String {
        get { load(forKey: "tmdb_api_key") ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(forKey: "tmdb_api_key") } else { save(trimmed, forKey: "tmdb_api_key") }
        }
    }

    public static var aiApiKey: String {
        get { load(forKey: "ai_api_key") ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(forKey: "ai_api_key") } else { save(trimmed, forKey: "ai_api_key") }
        }
    }

    public static func saveAccountSecret(_ secret: String, accountId: String) {
        save(secret, forKey: "acct_secret_\(accountId)")
    }

    public static func loadAccountSecret(accountId: String) -> String? {
        load(forKey: "acct_secret_\(accountId)")
    }

    public static func deleteAccountSecret(accountId: String) {
        delete(forKey: "acct_secret_\(accountId)")
    }
}
