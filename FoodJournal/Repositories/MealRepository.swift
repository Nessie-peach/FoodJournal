import Foundation
import SwiftData

/// 餐次仓库协议：不绑定具体存储
@MainActor
protocol MealRepositoryProtocol {
    func insert(_ meal: Meal) throws
    func delete(_ meal: Meal) throws
    func update(_ meal: Meal) throws
    func fetchAll() throws -> [Meal]
    func fetch(byID id: UUID) throws -> Meal?
    /// 按**自然日**区间查询（含边界当天的全天范围）
    /// - Warning: 自然日口径；业务日（04:00 分界）场景请改用 `fetch(businessDaysFrom:to:)`
    @available(*, deprecated, message: "自然日口径；业务日场景请用 fetch(businessDaysFrom:to:)")
    func fetch(from: Date, to: Date) throws -> [Meal]
    /// 按**业务日**口径区间查询：`startAnchor` / `endAnchor` 为业务日**锚点**（该业务日日历日 00:00），
    /// 返回归属业务日 ∈ [startAnchor, endAnchor) 的餐（半开区间）。
    /// 实际取数区间为 [startAnchor 04:00, endAnchor 04:00)。
    func fetch(businessDaysFrom startAnchor: Date, to endAnchor: Date) throws -> [Meal]
}

/// SwiftData 实现：接收 ModelContext，方便测试用 in-memory 容器
@MainActor
final class MealRepository: MealRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func insert(_ meal: Meal) throws {
        context.insert(meal)
        try context.save()
    }

    func delete(_ meal: Meal) throws {
        context.delete(meal)
        try context.save()
    }

    func update(_ meal: Meal) throws {
        // @Model 对象由 SwiftData 跟踪，直接保存即可
        try context.save()
    }

    func fetchAll() throws -> [Meal] {
        let descriptor = FetchDescriptor<Meal>(sortBy: [SortDescriptor(\.date)])
        return try context.fetch(descriptor)
    }

    func fetch(byID id: UUID) throws -> Meal? {
        var descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @available(*, deprecated, message: "自然日口径；业务日场景请用 fetch(businessDaysFrom:to:)")
    func fetch(from startDate: Date, to endDate: Date) throws -> [Meal] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) else {
            return []
        }
        let predicate = #Predicate<Meal> { meal in
            meal.date >= start && meal.date < end
        }
        let descriptor = FetchDescriptor<Meal>(predicate: predicate, sortBy: [SortDescriptor(\.date)])
        return try context.fetch(descriptor)
    }

    /// 业务日口径区间查询：入参为**业务日锚点**（00:00），
    /// 经 `LogicalDay.businessDayRange(forAnchor:)` 换算为 [锚点日 04:00, 次日 04:00)，
    /// 不可再走 `businessDayRange(of:)`（锚点 hour < 4 会被二次减一天）。
    func fetch(businessDaysFrom startAnchor: Date, to endAnchor: Date) throws -> [Meal] {
        let calendar = Calendar.current
        let start = LogicalDay.businessDayRange(forAnchor: startAnchor, calendar: calendar).start
        let end = LogicalDay.businessDayRange(forAnchor: endAnchor, calendar: calendar).start
        let predicate = #Predicate<Meal> { meal in
            meal.date >= start && meal.date < end
        }
        let descriptor = FetchDescriptor<Meal>(predicate: predicate, sortBy: [SortDescriptor(\.date)])
        return try context.fetch(descriptor)
    }
}
