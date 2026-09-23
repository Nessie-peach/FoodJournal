import XCTest
@testable import FoodJournal

/// NumberParsing 数字输入容错解析
final class NumberParsingTests: XCTestCase {
    func testParseNormalValues() {
        XCTAssertEqual(NumberParsing.parse("12.5"), 12.5)
        XCTAssertEqual(NumberParsing.parse("  3.4  "), 3.4)
        XCTAssertEqual(NumberParsing.parse("0"), 0)
        XCTAssertEqual(NumberParsing.parse("-2.5"), -2.5)
    }

    func testParseCommaAsDecimalSeparator() {
        XCTAssertEqual(NumberParsing.parse("12,5"), 12.5)
        XCTAssertEqual(NumberParsing.parse("0,75"), 0.75)
    }

    func testParseThousandSeparatorWhenDotPresent() {
        // 同时含 "." 与 "," 时，逗号视为千分位
        XCTAssertEqual(NumberParsing.parse("1,234.5"), 1234.5)
    }

    func testParseInvalidReturnsNil() {
        XCTAssertNil(NumberParsing.parse(""))
        XCTAssertNil(NumberParsing.parse("   "))
        XCTAssertNil(NumberParsing.parse("abc"))
        XCTAssertNil(NumberParsing.parse("1.2.3"))
    }

    func testParseOrZeroFallback() {
        XCTAssertEqual(NumberParsing.parseOrZero(""), 0)
        XCTAssertEqual(NumberParsing.parseOrZero("xyz"), 0)
        XCTAssertEqual(NumberParsing.parseOrZero("7.25"), 7.25)
    }

    func testInputTextFormatting() {
        XCTAssertEqual(NumberFormatting.inputText(0), "0")
        XCTAssertEqual(NumberFormatting.inputText(12), "12")
        XCTAssertEqual(NumberFormatting.inputText(12.0), "12")
        XCTAssertEqual(NumberFormatting.inputText(12.5), "12.5")
    }
}
