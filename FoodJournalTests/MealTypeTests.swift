import XCTest
@testable import FoodJournal

/// MealType.from(date:) 边界推断
final class MealTypeTests: XCTestCase {
    private func assertMealType(_ hour: Int, _ minute: Int, _ expected: MealType,
                                file: StaticString = #filePath, line: UInt = #line) {
        let date = TestSupport.date(hour: hour, minute: minute)
        XCTAssertEqual(MealType.from(date: date), expected, file: file, line: line)
    }

    func testDisplayName() {
        XCTAssertEqual(MealType.breakfast.displayName, "早餐")
        XCTAssertEqual(MealType.lunch.displayName, "午餐")
        XCTAssertEqual(MealType.dinner.displayName, "晚餐")
        XCTAssertEqual(MealType.snack.displayName, "加餐")
        XCTAssertEqual(MealType.allCases.count, 4)
    }

    func testBoundaryBreakfast() {
        assertMealType(5, 0, .breakfast)      // 下边界 5:00
        assertMealType(10, 29, .breakfast)    // 上边界 10:29
        assertMealType(8, 0, .breakfast)
    }

    func testBoundaryLunch() {
        assertMealType(10, 30, .lunch)         // 下边界 10:30
        assertMealType(15, 29, .lunch)         // 上边界 15:29
        assertMealType(12, 0, .lunch)
    }

    func testBoundarySnack() {
        assertMealType(15, 30, .snack)         // 下边界 15:30
        assertMealType(18, 29, .snack)         // 上边界 18:29
        assertMealType(16, 0, .snack)
    }

    func testBoundaryDinner() {
        assertMealType(18, 30, .dinner)        // 下边界 18:30
        assertMealType(23, 59, .dinner)        // 当天最晚
        assertMealType(0, 0, .dinner)          // 凌晨 0:00 并入晚餐（夜宵）
        assertMealType(4, 59, .dinner)         // 凌晨 4:59
    }

    func testRawValueRoundTrip() {
        for type in MealType.allCases {
            XCTAssertEqual(MealType(rawValue: type.rawValue), type)
        }
    }
}
