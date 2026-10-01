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
    /// 按日期范围查询（含边界当天的全天范围）
    func fetch(from: Date, to: Date) throws -> [Meal]
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

    /// 全部记录天数（去重）：历史入口「共 N 天」用。
    /// propertiesToFetch 仅取 date 列，避免加载照片大字段
    func recordedDayCount() -> Int {
        var descriptor = FetchDescriptor<Meal>()
        descriptor.propertiesToFetch = [\.date]
        let dates = (try? context.fetch(descriptor).map(\.date)) ?? []
        return HistoryGrouping.recordedDayCount(dates: dates)
    }
}
