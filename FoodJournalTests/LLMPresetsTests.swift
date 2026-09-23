import XCTest
@testable import FoodJournal

final class LLMPresetsTests: XCTestCase {
    func testAllCasesOrder() {
        XCTAssertEqual(
            LLMPreset.allCases.map(\.rawValue),
            ["deepseek", "tencent", "aliyun", "volcengine", "custom"]
        )
    }

    func testDisplayNames() {
        XCTAssertEqual(LLMPreset.deepseek.displayName, "DeepSeek 官方")
        XCTAssertEqual(LLMPreset.tencent.displayName, "腾讯云混元")
        XCTAssertEqual(LLMPreset.aliyun.displayName, "阿里云百炼")
        XCTAssertEqual(LLMPreset.volcengine.displayName, "火山引擎方舟")
        XCTAssertEqual(LLMPreset.custom.displayName, "自定义")
    }

    func testBaseURLs() {
        XCTAssertEqual(LLMPreset.deepseek.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(LLMPreset.tencent.baseURL, "https://api.hunyuan.cloud.tencent.com/v1")
        XCTAssertEqual(LLMPreset.aliyun.baseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(LLMPreset.volcengine.baseURL, "https://ark.cn-beijing.volces.com/api/plan/v3")
        XCTAssertTrue(LLMPreset.custom.baseURL.isEmpty)
    }

    func testQuickModels() {
        XCTAssertEqual(LLMPreset.deepseek.quickModels, ["deepseek-v4-flash", "deepseek-v4-pro"])
        XCTAssertEqual(
            LLMPreset.tencent.quickModels,
            ["hunyuan-turbos-latest", "hunyuan-t1-latest", "hunyuan-vision"]
        )
        XCTAssertEqual(
            LLMPreset.aliyun.quickModels,
            ["qwen3-vl-plus", "qwen3-vl-flash", "qwen3.8-max", "qwen-plus"]
        )
        XCTAssertEqual(LLMPreset.volcengine.quickModels, ["doubao-seed-2.0-mini", "deepseek-v4-pro"])
        XCTAssertTrue(LLMPreset.custom.quickModels.isEmpty)
    }

    /// 快捷选项完整性：非 custom 预设至少 2 个、无重复、无空白项
    func testQuickModelsIntegrity() {
        for preset in LLMPreset.allCases where preset != .custom {
            XCTAssertGreaterThanOrEqual(preset.quickModels.count, 2, "\(preset.displayName) 快捷选项过少")
            XCTAssertEqual(Set(preset.quickModels).count, preset.quickModels.count,
                           "\(preset.displayName) 快捷选项重复")
            for model in preset.quickModels {
                XCTAssertFalse(model.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(preset.displayName) 存在空白模型 ID")
            }
        }
    }

    /// 非自定义预设的 BaseURL 必须是 https 开头且以版本路径或域名结尾的合法形式
    func testNonCustomBaseURLsAreHTTPS() {
        for preset in LLMPreset.allCases where preset != .custom {
            XCTAssertTrue(preset.baseURL.hasPrefix("https://"), preset.rawValue)
            XCTAssertFalse(preset.baseURL.hasSuffix("/"), preset.rawValue)
        }
    }
}
