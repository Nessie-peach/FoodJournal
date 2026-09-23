import XCTest
@testable import FoodJournal

/// 营养合计计算属性
final class MealNutritionTests: XCTestCase {
    @MainActor
    func testTotalsWithMultipleItems() throws {
        let rice = FoodItem(name: "米饭", calories: 232, protein: 4.8, carbs: 51.0, fat: 0.5)
        let chicken = FoodItem(name: "鸡胸肉", calories: 133, protein: 27.0, carbs: 0.0, fat: 1.2)
        let broccoli = FoodItem(name: "西兰花", calories: 35, protein: 2.8, carbs: 7.2, fat: 0.4)
        let meal = Meal(mealType: .lunch, name: "健康午餐", items: [rice, chicken, broccoli])

        XCTAssertEqual(meal.totalCalories, 400, accuracy: 0.001)
        XCTAssertEqual(meal.totalProtein, 34.6, accuracy: 0.001)
        XCTAssertEqual(meal.totalCarbs, 58.2, accuracy: 0.001)
        XCTAssertEqual(meal.totalFat, 2.1, accuracy: 0.001)
    }

    @MainActor
    func testTotalsWithEmptyItems() throws {
        let meal = Meal(mealType: .snack, name: "空餐", items: [])
        XCTAssertEqual(meal.totalCalories, 0)
        XCTAssertEqual(meal.totalProtein, 0)
        XCTAssertEqual(meal.totalCarbs, 0)
        XCTAssertEqual(meal.totalFat, 0)
    }

    @MainActor
    func testTotalsWithSingleItem() throws {
        let egg = FoodItem(name: "鸡蛋", calories: 78, protein: 6.3, carbs: 0.6, fat: 5.3)
        let meal = Meal(mealType: .breakfast, name: "早餐", items: [egg])
        XCTAssertEqual(meal.totalCalories, 78, accuracy: 0.001)
        XCTAssertEqual(meal.totalProtein, 6.3, accuracy: 0.001)
        XCTAssertEqual(meal.totalCarbs, 0.6, accuracy: 0.001)
        XCTAssertEqual(meal.totalFat, 5.3, accuracy: 0.001)
    }
}
