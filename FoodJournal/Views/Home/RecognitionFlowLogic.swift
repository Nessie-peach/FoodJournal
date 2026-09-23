import Foundation

/// 拍照识图流程的纯逻辑判定（独立可测，不触 UI 与网络）。
enum RecognitionFlowLogic {
    /// 识图配置是否完整：BaseURL、模型 ID、API Key 三者均非空。
    /// 任一缺失时应在发起请求前引导用户前往设置页，而不是白白浪费一次请求。
    static func isConfigComplete(config: LLMProviderConfig, apiKey: String?) -> Bool {
        let hasKey = !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return config.isEndpointConfigured && config.isModelConfigured && hasKey
    }
}
