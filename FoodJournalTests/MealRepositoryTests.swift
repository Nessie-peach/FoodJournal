import XCTest
import SwiftData
@testable import FoodJournal

/// Meal CRUD round-trip：插入 → 回读字段与关系 → 日期范围查询 → 删除级联
@MainActor
final class MealRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var repository: MealRepository!

    override func setUp() {
        container = try! TestSupport.makeContainer()
        context = ModelContext(container)
        repository = MealRepository(context: context)
    }

    override func tearDown() {
        container = nil
        repository = nil
    }

    func testCRUDRoundTripAndCascadeDelete() throws {
        // 1. 插入含 items 的 Meal
        let mealID = UUID()
        let mealDate = TestSupport.date(y: 9, d: 23, hour: 12, minute: 30)
        let photo = Data("fake-photo-bytes".utf8)
        let rice = FoodItem(name: "米饭", calories: 232, protein: 4.8, carbs: 51.0, fat: 0.5)
        let beef = FoodItem(name: "牛肉", calories: 250, protein: 26.0, carbs: 2.0, fat: 15.0)
        let meal = Meal(
            id: mealID,
            date: mealDate,
            mealType: .lunch,
            name: "午市套餐",
            photoData: photo,
            items: [rice, beef]
        )
        try repository.insert(meal)

        // 2. 按 id 回读，校验字段与关系
        let fetched = try repository.fetch(byID: mealID)
        XCTAssertNotNil(fetched)
        let loaded = try XCTUnwrap(fetched)
        XCTAssertEqual(loaded.name, "午市套餐")
        XCTAssertEqual(loaded.mealType, MealType.lunch.rawValue)
        XCTAssertEqual(loaded.date, mealDate)
        XCTAssertEqual(loaded.photoData, photo)
        XCTAssertEqual(loaded.items.count, 2)
        let itemNames = Set(loaded.items.map(\.name))
        XCTAssertEqual(itemNames, ["米饭", "牛肉"])
        XCTAssertEqual(loaded.totalCalories, 482, accuracy: 0.001)
        XCTAssertEqual(loaded.totalProtein, 30.8, accuracy: 0.001)
        XCTAssertEqual(loaded.totalCarbs, 53.0, accuracy: 0.001)
        XCTAssertEqual(loaded.totalFat, 15.5, accuracy: 0.001)
        // 反向关系
        for item in loaded.items {
            XCTAssertEqual(item.meal?.id, mealID)
        }

        // 3. 日期范围查询：包含当天 / 排除其他天
        let sameDay = try repository.fetch(from: mealDate, to: mealDate)
        XCTAssertEqual(sameDay.count, 1)
        let otherDay = TestSupport.date(y: 9, d: 24, hour: 8)
        let none = try repository.fetch(from: otherDay, to: otherDay)
        XCTAssertEqual(none.count, 0)

        // 4. 更新
        loaded.name = "改名套餐"
        try repository.update(loaded)
        let refetched = try repository.fetch(byID: mealID)
        XCTAssertEqual(refetched?.name, "改名套餐")

        // 5. 删除级联验证：删 Meal 后 FoodItem 应一并删除
        try repository.delete(loaded)
        XCTAssertEqual(try repository.fetchAll().count, 0)
        let remainingItems = try context.fetch(FetchDescriptor<FoodItem>())
        XCTAssertEqual(remainingItems.count, 0)
    }

    func testInsertMultipleMealsSortedByDate() throws {
        let morning = Meal(
            date: TestSupport.date(y: 9, d: 23, hour: 8),
            mealType: .breakfast, name: "豆浆油条", items: []
        )
        let noon = Meal(
            date: TestSupport.date(y: 9, d: 23, hour: 12),
            mealType: .lunch, name: "食堂", items: []
        )
        let night = Meal(
            date: TestSupport.date(y: 9, d: 23, hour: 19),
            mealType: .dinner, name: "火锅", items: []
        )
        try repository.insert(noon)
        try repository.insert(night)
        try repository.insert(morning)

        let all = try repository.fetchAll()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.name), ["豆浆油条", "食堂", "火锅"]) // 按时间升序
    }
}
