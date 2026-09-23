import Foundation
import SwiftData

/// 体重记录仓库协议
@MainActor
protocol WeightRepositoryProtocol {
    func insert(_ record: WeightRecord) throws
    func delete(_ record: WeightRecord) throws
    func fetchAll() throws -> [WeightRecord]
    /// 按日期范围查询
    func fetch(from: Date, to: Date) throws -> [WeightRecord]
}

@MainActor
final class WeightRepository: WeightRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func insert(_ record: WeightRecord) throws {
        context.insert(record)
        try context.save()
    }

    func delete(_ record: WeightRecord) throws {
        context.delete(record)
        try context.save()
    }

    func fetchAll() throws -> [WeightRecord] {
        let descriptor = FetchDescriptor<WeightRecord>(sortBy: [SortDescriptor(\.date)])
        return try context.fetch(descriptor)
    }

    func fetch(from startDate: Date, to endDate: Date) throws -> [WeightRecord] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) else {
            return []
        }
        let predicate = #Predicate<WeightRecord> { record in
            record.date >= start && record.date < end
        }
        let descriptor = FetchDescriptor<WeightRecord>(predicate: predicate, sortBy: [SortDescriptor(\.date)])
        return try context.fetch(descriptor)
    }
}
