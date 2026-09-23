import Foundation
import SwiftData

/// 食物/菜品条目：一份食物的营养信息
@Model
final class FoodItem {
    @Attribute(.unique) var id: UUID
    var name: String
    /// 热量（kcal）
    var calories: Double
    /// 蛋白质（g）
    var protein: Double
    /// 碳水（g）
    var carbs: Double
    /// 脂肪（g）
    var fat: Double
    /// 所属餐次
    var meal: Meal?

    init(
        id: UUID = UUID(),
        name: String,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        meal: Meal? = nil
    ) {
        self.id = id
        self.name = name
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.meal = meal
    }
}
