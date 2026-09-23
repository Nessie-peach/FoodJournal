import Foundation
import Security

/// iOS Keychain 封装（kSecClassGenericPassword），仅用于存储 LLM API Key。
/// 注意：Key 只进 Keychain，不写 UserDefaults、不打日志、不落任何文件。
struct KeychainStore {
    /// Keychain 条目中的账号字段（固定值）
    private static let account = "apiKey"

    /// 识图模型的 Keychain 服务名
    static let vision = KeychainStore(service: "com.pigeon.foodjournal.llm.vision")

    /// 建议模型的 Keychain 服务名
    static let advice = KeychainStore(service: "com.pigeon.foodjournal.llm.advice")

    let service: String

    init(service: String) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    /// 写入 Key（若已存在则覆盖）
    func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.writeFailed(status)
        }
    }

    /// 读取 Key；不存在时返回 nil
    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 删除已存储的 Key（不存在时静默成功）
    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// 是否已存储 Key
    var hasStoredKey: Bool {
        load() != nil
    }

    enum KeychainError: Error, CustomStringConvertible {
        case writeFailed(OSStatus)

        var description: String {
            switch self {
            case .writeFailed(let status):
                return "Keychain 写入失败（状态码 \(Int(status))）"
            }
        }
    }
}
