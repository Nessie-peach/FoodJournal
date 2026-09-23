import Foundation
import SwiftData

/// 一餐：可包含多个菜品/食物条目
@Model
final class Meal {
    @Attribute(.unique) var id: UUID
    /// 用餐日期时间
    var date: Date
    /// 餐次（存 MealType rawValue）
    var mealType: String
    /// 餐名（如「麦当劳巨无霸套餐」）
    var name: String
    /// 照片数据（可选）
    var photoData: Data?
    /// 包含的食物条目（级联删除）
    @Relationship(deleteRule: .cascade, inverse: \FoodItem.meal)
    var items: [FoodItem]

    var type: MealType? {
        MealType(rawValue: mealType)
    }

    init(
        id: UUID = UUID(),
        date: Date = .now,
        mealType: MealType,
        name: String,
        photoData: Data? = nil,
        items: [FoodItem] = []
    ) {
        self.id = id
        self.date = date
        self.mealType = mealType.rawValue
        self.name = name
        self.photoData = photoData
        self.items = items
    }
}

extension Meal {
    /// 本餐总热量（kcal）
    var totalCalories: Double {
        items.reduce(0) { $0 + $1.calories }
    }

    /// 总蛋白质（g）
    var totalProtein: Double {
        items.reduce(0) { $0 + $1.protein }
    }

    /// 总碳水（g）
    var totalCarbs: Double {
        items.reduce(0) { $0 + $1.carbs }
    }

    /// 总脂肪（g）
    var totalFat: Double {
        items.reduce(0) { $0 + $1.fat }
    }
}
