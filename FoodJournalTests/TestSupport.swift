import XCTest
import SwiftData
@testable import FoodJournal

/// 测试辅助：构建 in-memory 容器与指定时刻的日期
enum TestSupport {
    static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Meal.self, FoodItem.self, WeightRecord.self,
                DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self,
            configurations: config
        )
    }

    /// 用当天日期 + 指定 时:分 构造 Date（与 MealType 内部同用 Calendar.current）
    static func date(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: Date()
        )!
    }

    /// 指定年月日 + 时分
    static func date(y m: Int, d: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = m
        components.day = d
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
}
