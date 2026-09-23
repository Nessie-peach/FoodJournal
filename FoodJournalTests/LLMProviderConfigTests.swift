import XCTest
@testable import FoodJournal

final class LLMProviderConfigTests: XCTestCase {
    func testDefaultConfig() {
        let config = LLMProviderConfig.default
        XCTAssertEqual(config.preset, .custom)
        XCTAssertTrue(config.baseURL.isEmpty)
        XCTAssertTrue(config.modelID.isEmpty)
        XCTAssertFalse(config.isEndpointConfigured)
        XCTAssertFalse(config.isModelConfigured)
    }

    /// JSON 字符串（asJSON / init?(json:)）round-trip，@AppStorage 持久化依赖此能力
    func testRawValueRoundTrip() {
        let config = LLMProviderConfig(
            preset: .aliyun,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            modelID: "qwen3-vl-plus"
        )
        let raw = config.asJSON
        let restored = LLMProviderConfig(json: raw)
        XCTAssertEqual(restored, config)
    }

    /// 损坏的 JSON 应返回 nil（回退到默认值）
    func testInvalidRawValueReturnsNil() {
        XCTAssertNil(LLMProviderConfig(json: ""))
        XCTAssertNil(LLMProviderConfig(json: "not-a-json"))
    }

    /// 切换预设自动带出 BaseURL；模型 ID 不在快捷选项中时自动选中第一个
    func testApplyPresetFillsBaseURLAndModel() {
        var config = LLMProviderConfig.default
        config.applyPreset(.deepseek)
        XCTAssertEqual(config.preset, .deepseek)
        XCTAssertEqual(config.baseURL, LLMPreset.deepseek.baseURL)
        XCTAssertEqual(config.modelID, "deepseek-v4-flash")

        // 模型 ID 已在快捷选项中时保持不变
        config.modelID = "deepseek-v4-pro"
        config.applyPreset(.deepseek)
        XCTAssertEqual(config.modelID, "deepseek-v4-pro")
    }

    /// 切到 custom 清空 BaseURL、保留模型 ID 待手填
    func testApplyCustomPreset() {
        var config = LLMProviderConfig.default
        config.applyPreset(.tencent)
        config.applyPreset(.custom)
        XCTAssertEqual(config.baseURL, "")
        XCTAssertEqual(config.modelID, "hunyuan-turbos-latest")
    }

    func testIsConfiguredFlags() {
        var config = LLMProviderConfig(preset: .custom, baseURL: "  ", modelID: "")
        XCTAssertFalse(config.isEndpointConfigured)
        XCTAssertFalse(config.isModelConfigured)

        config.baseURL = "https://api.example.com"
        config.modelID = "some-model"
        XCTAssertTrue(config.isEndpointConfigured)
        XCTAssertTrue(config.isModelConfigured)
    }

    /// Codable round-trip
    func testCodableRoundTrip() throws {
        let config = LLMProviderConfig(
            preset: .volcengine,
            baseURL: LLMPreset.volcengine.baseURL,
            modelID: "doubao-seed-2.0-mini"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LLMProviderConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}
