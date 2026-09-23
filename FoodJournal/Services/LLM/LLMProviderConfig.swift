import Foundation

/// 一份 LLM 接入配置：厂商预设 + BaseURL + 模型 ID。
/// 通过 `asJSON` / `init?(json:)` 配合 @AppStorage（String）持久化，
/// 仅保存非敏感信息；API Key 一律走 Keychain，绝不落入 UserDefaults。
struct LLMProviderConfig: Codable, Equatable, Hashable {
    var preset: LLMPreset
    var baseURL: String
    var modelID: String

    /// 默认配置：未选择厂商，等待用户填写
    static let `default` = LLMProviderConfig(preset: .custom, baseURL: "", modelID: "")

    /// @AppStorage 存储键（识图 / 建议各一份）
    static let visionStorageKey = "llm.config.vision"
    static let adviceStorageKey = "llm.config.advice"

    var isEndpointConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isModelConfigured: Bool {
        !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 切换预设时自动带出 BaseURL；若当前模型 ID 不在新预设的快捷选项中，
    /// 自动选中第一个快捷选项（custom 保留原值待手填）。
    mutating func applyPreset(_ newPreset: LLMPreset) {
        preset = newPreset
        baseURL = newPreset.baseURL
        if !newPreset.quickModels.isEmpty && !newPreset.quickModels.contains(modelID) {
            modelID = newPreset.quickModels[0]
        }
    }
}

// MARK: - 显式 Codable 实现

// 必须显式实现：不依赖合成，避免协议见证解析歧义。
extension LLMProviderConfig {
    private enum CodingKeys: String, CodingKey {
        case preset, baseURL, modelID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(modelID, forKey: .modelID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decode(LLMPreset.self, forKey: .preset)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        modelID = try container.decode(String.self, forKey: .modelID)
    }
}

// MARK: - @AppStorage 持久化支持（显式 JSON 桥接，不使用 RawRepresentable）

extension LLMProviderConfig {
    /// JSON 编码后的字符串，供 @AppStorage 存入 UserDefaults（不含 API Key）
    var asJSON: String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// 从 JSON 字符串解码；失败返回 nil（调用方可回退到默认值）
    init?(json: String) {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LLMProviderConfig.self, from: data) else {
            return nil
        }
        self = decoded
    }
}
