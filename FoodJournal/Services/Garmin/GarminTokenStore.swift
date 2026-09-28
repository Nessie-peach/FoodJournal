import Foundation
import Security

/// Garmin token 的 iOS Keychain 存取（kSecClassGenericPassword）。
/// - service "com.pigeon.foodjournal.garmin"，账号 "oauth" 存 OAuth1 token/secret，
///   账号 "oauth2" 存 access/refresh/expiresAt（JSON 编码为 Data）。
/// - 不得写入 UserDefaults；日志不打印 token（如需展示只打印前 8 位 + 长度）。
struct GarminTokenStore: Sendable {
    static let shared = GarminTokenStore(service: "com.pigeon.foodjournal.garmin")

    let service: String

    struct OAuth1Tokens: Codable, Equatable, Sendable {
        var token: String
        var secret: String
    }

    struct OAuth2Tokens: Codable, Equatable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private static let oauth1Account = "oauth"
    private static let oauth2Account = "oauth2"

    init(service: String) {
        self.service = service
    }

    // MARK: - 存取

    func saveOAuth1(_ tokens: OAuth1Tokens) throws {
        try save(tokens, account: Self.oauth1Account)
    }

    func saveOAuth2(_ tokens: OAuth2Tokens) throws {
        try save(tokens, account: Self.oauth2Account)
    }

    func loadOAuth1() -> OAuth1Tokens? {
        load(OAuth1Tokens.self, account: Self.oauth1Account)
    }

    func loadOAuth2() -> OAuth2Tokens? {
        load(OAuth2Tokens.self, account: Self.oauth2Account)
    }

    /// OAuth1 + OAuth2 组合成完整 token；任一缺失返回 nil
    func loadTokens() -> GarminTokens? {
        guard let oauth1 = loadOAuth1(), let oauth2 = loadOAuth2() else { return nil }
        return GarminTokens(
            oauth1Token: oauth1.token, oauth1Secret: oauth1.secret,
            accessToken: oauth2.accessToken, refreshToken: oauth2.refreshToken,
            expiresAt: oauth2.expiresAt
        )
    }

    /// 清除全部 Garmin token（不存在时静默成功）
    func deleteAll() {
        SecItemDelete(baseQuery(account: Self.oauth1Account) as CFDictionary)
        SecItemDelete(baseQuery(account: Self.oauth2Account) as CFDictionary)
    }

    /// 日志脱敏：只打印前 8 位 + 长度（绝不打印完整 token）
    static func masked(_ value: String) -> String {
        value.count <= 8 ? "<len=\(value.count)>" : "\(value.prefix(8))…(len=\(value.count))"
    }

    // MARK: - Keychain 底层

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStore.KeychainError.writeFailed(status)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
