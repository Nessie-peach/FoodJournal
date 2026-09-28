import XCTest
@testable import FoodJournal

final class AIEditServiceTests: XCTestCase {
    // MARK: - diffMealDrafts

    private func item(
        _ name: String,
        calories: Double,
        protein: Double = 10,
        carbs: Double = 20,
        fat: Double = 5,
        source: String? = "estimate"
    ) -> FoodItemDraft {
        FoodItemDraft(name: name, calories: calories, protein: protein, carbs: carbs, fat: fat, source: source)
    }

    func testDiffDetectsNutrientChange() {
        let old = [item("奶茶", calories: 150)]
        let new = [item("奶茶", calories: 300)]
        let changes = MealDraftDiff.diffMealDrafts(old: old, new: new)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .modified)
        XCTAssertEqual(changes[0].oldItem?.calories, 150)
        XCTAssertEqual(changes[0].newItem?.calories, 300)
    }

    func testDiffDetectsNameChange() {
        let old = [item("杨枝甘露(半杯)", calories: 150)]
        let new = [item("杨枝甘露(一整杯)", calories: 150)]
        let changes = MealDraftDiff.diffMealDrafts(old: old, new: new)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .modified)
        XCTAssertEqual(changes[0].oldItem?.name, "杨枝甘露(半杯)")
        XCTAssertEqual(changes[0].newItem?.name, "杨枝甘露(一整杯)")
    }

    func testDiffDetectsAddedAndRemoved() {
        let old = [item("米饭", calories: 200), item("鸡腿", calories: 360)]
        let new = [item("米饭", calories: 200), item("青菜", calories: 30), item("汤", calories: 50)]
        let changes = MealDraftDiff.diffMealDrafts(old: old, new: new)
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes[0].kind, .removed)
        XCTAssertEqual(changes[0].oldItem?.name, "鸡腿")
        XCTAssertEqual(changes[1].kind, .added)
        XCTAssertEqual(changes[1].newItem?.name, "青菜")
        XCTAssertEqual(changes[2].kind, .added)
        XCTAssertEqual(changes[2].newItem?.name, "汤")
    }

    func testDiffNoChangeReturnsEmpty() {
        let old = [item("米饭", calories: 200), item("鸡腿", calories: 360)]
        let new = [item("米饭", calories: 200), item("鸡腿", calories: 360)]
        XCTAssertTrue(MealDraftDiff.diffMealDrafts(old: old, new: new).isEmpty)
    }

    func testDiffEmptyToItemsAllAdded() {
        let changes = MealDraftDiff.diffMealDrafts(old: [], new: [item("米饭", calories: 200)])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .added)
    }

    // MARK: - 摘要文本

    func testChangeSummaryTextListsOnlyChangedFields() {
        let change = MealItemChange(
            kind: .modified,
            oldItem: item("奶茶", calories: 150, protein: 2, carbs: 25, fat: 3),
            newItem: item("奶茶", calories: 300, protein: 2, carbs: 50, fat: 3)
        )
        let text = change.summaryText
        XCTAssertTrue(text.contains("奶茶"))
        XCTAssertTrue(text.contains("150 → 300"))
        XCTAssertTrue(text.contains("25 → 50"))
        XCTAssertFalse(text.contains("蛋白"))
        XCTAssertFalse(text.contains("脂肪"))
    }

    // MARK: - 请求体构造（不发真实网络请求）

    func testMakeRequestBodyMessagesStructure() throws {
        let config = LLMProviderConfig(preset: .custom, baseURL: "https://example.com/v1", modelID: "test-model")
        let body = AIEditService.makeRequestBody(
            config: config,
            currentJSON: "{\"mealName\":\"午餐\",\"items\":[]}",
            instruction: "米饭只吃了一半",
            history: [
                (instruction: "这一整杯都是我喝的", resultJSON: "{\"mealName\":\"奶茶\",\"items\":[]}")
            ]
        )

        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, false)

        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 4) // system + 历轮 user/assistant + 本轮 user
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], AIEditService.systemPrompt)
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertTrue(messages[1]["content"]?.contains("这一整杯都是我喝的") == true)
        XCTAssertEqual(messages[2]["role"], "assistant")
        XCTAssertTrue(messages[2]["content"]?.contains("奶茶") == true)
        XCTAssertEqual(messages[3]["role"], "user")
        XCTAssertTrue(messages[3]["content"]?.contains("米饭只吃了一半") == true)
        XCTAssertTrue(messages[3]["content"]?.contains("午餐") == true)
    }

    // MARK: - 结果 JSON 编码（多轮 history 用）

    func testEncodeJSONRoundTripsThroughParser() throws {
        let result = MealRecognitionResult(
            mealName: "下午茶",
            items: [item("蛋糕", calories: 280.5, source: "official")]
        )
        let json = AIEditService.encodeJSON(result)
        let parsed = try VisionResponseParser.parse(json)
        XCTAssertEqual(parsed, result)
    }
}
