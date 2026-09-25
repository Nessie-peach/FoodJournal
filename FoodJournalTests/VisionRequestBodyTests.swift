import XCTest
@testable import FoodJournal

/// VisionService 多图请求体构造单测（不发起真实网络请求）
final class VisionRequestBodyTests: XCTestCase {
    private let config = LLMProviderConfig(
        preset: .custom,
        baseURL: "https://example.com/v1",
        modelID: "test-model"
    )

    private func userContentEntries(of body: [String: Any]) -> [[String: Any]] {
        guard let messages = body["messages"] as? [[String: Any]],
              let user = messages.first(where: { ($0["role"] as? String) == "user" }),
              let content = user["content"] as? [[String: Any]] else {
            return []
        }
        return content
    }

    // MARK: - 多图请求体

    func testMakeRequestBodyWithTwoImagesProducesTwoImageURLEntries() throws {
        let image1 = Data("fake-jpeg-1".utf8)
        let image2 = Data("fake-jpeg-2".utf8)

        let body = VisionService.makeRequestBody(config: config, imageDatas: [image1, image2])
        let content = userContentEntries(of: body)

        let imageEntries = content.filter { ($0["type"] as? String) == "image_url" }
        XCTAssertEqual(imageEntries.count, 2, "2 张图应产生 2 个 image_url 条目")

        // 每个条目的 data URI 与传入图片一一对应（顺序一致）
        let urls = imageEntries.compactMap {
            (($0["image_url"] as? [String: Any])?["url"] as? String)
        }
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].hasPrefix("data:image/jpeg;base64,"))
        XCTAssertTrue(urls[0].hasSuffix(image1.base64EncodedString()))
        XCTAssertTrue(urls[1].hasSuffix(image2.base64EncodedString()))
        XCTAssertNotEqual(urls[0], urls[1], "两张不同的图应产生不同的 data URI")

        // 文本指令在图片之后
        XCTAssertEqual(content.last?["type"] as? String, "text")
    }

    func testMakeRequestBodyWithSingleImageProducesOneImageURLEntry() throws {
        let body = VisionService.makeRequestBody(config: config, imageDatas: [Data("only".utf8)])
        let content = userContentEntries(of: body)

        let imageEntries = content.filter { ($0["type"] as? String) == "image_url" }
        XCTAssertEqual(imageEntries.count, 1)
        XCTAssertEqual(content.count, 2, "1 张图 + 1 条文本指令")
    }

    // MARK: - system prompt 多图口径

    func testSystemPromptCoversMultiPhotoAndNutritionLabel() {
        XCTAssertTrue(VisionService.systemPrompt.contains("一张或多张照片"))
        XCTAssertTrue(VisionService.systemPrompt.contains("营养成分表"))
        XCTAssertTrue(VisionService.systemPrompt.contains("每100克"))
        XCTAssertTrue(VisionService.systemPrompt.contains("每份"))
        XCTAssertTrue(VisionService.systemPrompt.contains("只输出 JSON"))
    }
}
