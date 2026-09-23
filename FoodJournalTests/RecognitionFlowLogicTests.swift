import XCTest
@testable import FoodJournal

/// 拍照识图流程纯逻辑测试：配置完整性判定
final class RecognitionFlowLogicTests: XCTestCase {
    func testConfigCompleteWhenAllFieldsPresent() {
        let config = LLMProviderConfig(preset: .custom, baseURL: "https://api.example.com", modelID: "gpt-test")
        XCTAssertTrue(RecognitionFlowLogic.isConfigComplete(config: config, apiKey: "sk-test"))
    }

    func testIncompleteWhenKeyMissingOrBlank() {
        let config = LLMProviderConfig(preset: .custom, baseURL: "https://api.example.com", modelID: "gpt-test")
        XCTAssertFalse(RecognitionFlowLogic.isConfigComplete(config: config, apiKey: nil))
        XCTAssertFalse(RecognitionFlowLogic.isConfigComplete(config: config, apiKey: "   "))
    }

    func testIncompleteWhenBaseURLOrModelMissing() {
        let noURL = LLMProviderConfig(preset: .custom, baseURL: "", modelID: "gpt-test")
        XCTAssertFalse(RecognitionFlowLogic.isConfigComplete(config: noURL, apiKey: "sk-test"))

        let noModel = LLMProviderConfig(preset: .custom, baseURL: "https://api.example.com", modelID: "  ")
        XCTAssertFalse(RecognitionFlowLogic.isConfigComplete(config: noModel, apiKey: "sk-test"))
    }
}
