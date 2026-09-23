import Foundation

/// LLM 厂商预设（OpenAI 兼容端点）
enum LLMPreset: String, CaseIterable, Codable, Identifiable, Hashable {
    case deepseek
    case tencent
    case aliyun
    case volcengine
    case custom

    var id: String { rawValue }

    /// 界面展示名称
    var displayName: String {
        switch self {
        case .deepseek: "DeepSeek 官方"
        case .tencent: "腾讯云混元"
        case .aliyun: "阿里云百炼"
        case .volcengine: "火山引擎方舟"
        case .custom: "自定义"
        }
    }

    /// OpenAI 兼容 API 的 BaseURL（custom 为空，需手填）
    var baseURL: String {
        switch self {
        case .deepseek: "https://api.deepseek.com"
        case .tencent: "https://api.hunyuan.cloud.tencent.com/v1"
        case .aliyun: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .volcengine: "https://ark.cn-beijing.volces.com/api/plan/v3"
        case .custom: ""
        }
    }

    /// 模型 ID 快捷选项（custom 为空）
    var quickModels: [String] {
        switch self {
        case .deepseek: ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .tencent: ["hunyuan-turbos-latest", "hunyuan-t1-latest", "hunyuan-vision"]
        case .aliyun: ["qwen3-vl-plus", "qwen3-vl-flash", "qwen3.8-max", "qwen-plus"]
        case .volcengine: ["doubao-seed-2.0-mini", "deepseek-v4-pro"]
        case .custom: []
        }
    }
}
