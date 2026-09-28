import XCTest
@testable import FoodJournal

final class VisionResponseParserTests: XCTestCase {
    private let cleanJSON = """
    {"mealName":"午餐","items":[{"name":"鸡腿","calories":360,"protein":28,"carbs":4,"fat":22}]}
    """

    // MARK: - 正常解析

    func testParseCleanJSON() throws {
        let result = try VisionResponseParser.parse(cleanJSON)
        XCTAssertEqual(result.mealName, "午餐")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].name, "鸡腿")
        XCTAssertEqual(result.items[0].calories, 360)
        XCTAssertEqual(result.items[0].protein, 28)
        XCTAssertEqual(result.items[0].carbs, 4)
        XCTAssertEqual(result.items[0].fat, 22)
    }

    // MARK: - 代码围栏

    func testParseWithJSONCodeFence() throws {
        let reply = """
        ```json
        {"mealName":"晚餐","items":[{"name":"米饭","calories":200,"protein":4,"carbs":46,"fat":1}]}
        ```
        """
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.mealName, "晚餐")
        XCTAssertEqual(result.items[0].name, "米饭")
    }

    func testParseWithPlainCodeFence() throws {
        let reply = "```\n{\"mealName\":\"A\",\"items\":[]}\n```"
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.mealName, "A")
        XCTAssertTrue(result.items.isEmpty)
    }

    // MARK: - 前后废话文字

    func testParseWithSurroundingChatter() throws {
        let reply = "好的，识别结果如下：\(cleanJSON)希望对你有帮助！"
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.mealName, "午餐")
        XCTAssertEqual(result.items.count, 1)
    }

    // MARK: - 字符串数字

    func testParseStringNumbers() throws {
        let reply = """
        {"mealName":"早餐","items":[{"name":"鸡蛋","calories":"155","protein":"13","carbs":"1.1","fat":"11"}]}
        """
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.items[0].calories, 155)
        XCTAssertEqual(result.items[0].protein, 13)
        XCTAssertEqual(result.items[0].carbs, 1.1, accuracy: 0.0001)
        XCTAssertEqual(result.items[0].fat, 11)
    }

    // MARK: - 带单位数字

    func testParseNumbersWithUnits() throws {
        let reply = """
        {"mealName":"下午茶","items":[{"name":"拿铁","calories":"180kcal","protein":"9g","carbs":"15g","fat":"8g"}]}
        """
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.items[0].calories, 180)
        XCTAssertEqual(result.items[0].protein, 9)
        XCTAssertEqual(result.items[0].carbs, 15)
        XCTAssertEqual(result.items[0].fat, 8)
    }

    // MARK: - 字段缺失容错

    func testParseMissingFieldsDefaultsToZero() throws {
        let reply = """
        {"mealName":"宵夜","items":[{"name":"苹果"}]}
        """
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.items[0].calories, 0)
        XCTAssertEqual(result.items[0].protein, 0)
        XCTAssertEqual(result.items[0].carbs, 0)
        XCTAssertEqual(result.items[0].fat, 0)
    }

    // MARK: - 非法 JSON

    func testParseInvalidJSONThrowsParseFailed() {
        XCTAssertThrowsError(try VisionResponseParser.parse("这不是 JSON")) { error in
            guard case let VisionError.parseFailed(prefix) = error else {
                return XCTFail("期望 parseFailed，实际 \(error)")
            }
            XCTAssertEqual(prefix, "这不是 JSON")
        }
    }

    func testParseFailedPrefixLimitedTo200Chars() {
        let longReply = String(repeating: "杂", count: 500)
        XCTAssertThrowsError(try VisionResponseParser.parse(longReply)) { error in
            guard case let VisionError.parseFailed(prefix) = error else {
                return XCTFail("期望 parseFailed")
            }
            XCTAssertEqual(prefix.count, 200)
        }
    }

    // MARK: - 尾随多余 } 容错（M2-0 实测偶发）

    func testParseTrailingExtraBrace() throws {
        let reply = cleanJSON + "}"
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.mealName, "午餐")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].name, "鸡腿")
    }

    func testParseTrailingExtraBraceWithFence() throws {
        let reply = "```json\n\(cleanJSON)}}\n```"
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.mealName, "午餐")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].calories, 360)
    }

    // MARK: - source 字段（R5-1 官方数据优先）

    func testParseWithSourceOfficial() throws {
        let reply = """
        {"mealName":"下午茶","items":[{"name":"茉莉奶绿","calories":180,"protein":3,"carbs":28,"fat":6,"source":"official"}]}
        """
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.items[0].source, "official")
    }

    func testParseMissingSourceDefaultsToNil() throws {
        let result = try VisionResponseParser.parse(cleanJSON)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertNil(result.items[0].source, "模型漏输出 source 时应为 nil")
    }

    func testParseUnknownSourceValueTolerated() throws {
        let reply = """
        {"mealName":"午餐","items":[{"name":"汉堡","calories":550,"protein":25,"carbs":45,"fat":30,"source":"brand-data"}]}
        """
        let result = try VisionResponseParser.parse(reply)
        XCTAssertEqual(result.items[0].source, "brand-data", "未知 source 值应原样保留不丢信息")
    }

    // MARK: - extractJSON 单测

    func testExtractJSONStripsFenceAndChatter() {
        let extracted = VisionResponseParser.extractJSON(from: "前文```json\n\(cleanJSON)\n```后文")
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.hasPrefix("{") == true)
        XCTAssertTrue(extracted?.hasSuffix("}") == true)
    }

    // MARK: - FlexibleDouble 数字提取

    func testFlexibleDoubleExtractNumber() throws {
        XCTAssertEqual(FlexibleDouble.extractNumber(from: "360kcal"), 360)
        let value = try XCTUnwrap(FlexibleDouble.extractNumber(from: "1.5克"))
        XCTAssertEqual(value, 1.5, accuracy: 0.0001)
        XCTAssertNil(FlexibleDouble.extractNumber(from: "无数字"))
    }
}
