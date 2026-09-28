import Foundation
import SwiftData

/// 每日 AI 建议仓库协议
@MainActor
protocol AdviceRepositoryProtocol {
    /// 取某天的最新一条建议
    func advice(for date: Date) throws -> DailyAdvice?
    /// 取某天指定渠道的最新一条建议
    func advice(for date: Date, channel: String) throws -> DailyAdvice?
    /// 按日期+渠道 upsert：同日同渠道覆盖正文，不同渠道各存一条
    func upsert(date: Date, channel: String, content: String, modelTag: String) throws -> DailyAdvice
    /// 保存建议（追加，同一天可多条历史）
    func save(_ advice: DailyAdvice) throws
    /// 按日期范围查询
    func fetch(from: Date, to: Date) throws -> [DailyAdvice]
    func delete(_ advice: DailyAdvice) throws
}

@MainActor
final class AdviceRepository: AdviceRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    private static func dayRange(for date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    func advice(for date: Date) throws -> DailyAdvice? {
        guard let range = Self.dayRange(for: date, calendar: .current) else { return nil }
        let start = range.start
        let end = range.end
        let predicate = #Predicate<DailyAdvice> { advice in
            advice.date >= start && advice.date < end
        }
        let descriptor = FetchDescriptor<DailyAdvice>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first
    }

    func advice(for date: Date, channel: String) throws -> DailyAdvice? {
        guard let range = Self.dayRange(for: date, calendar: .current) else { return nil }
        let start = range.start
        let end = range.end
        let predicate = #Predicate<DailyAdvice> { advice in
            advice.date >= start && advice.date < end && advice.channel == channel
        }
        let descriptor = FetchDescriptor<DailyAdvice>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first
    }

    func upsert(date: Date, channel: String, content: String, modelTag: String) throws -> DailyAdvice {
        if let existing = try advice(for: date, channel: channel) {
            existing.content = content
            existing.generatedAt = .now
            existing.modelTag = modelTag
            try context.save()
            return existing
        }
        let advice = DailyAdvice(date: date, content: content, modelTag: modelTag, channel: channel)
        context.insert(advice)
        try context.save()
        return advice
    }

    func save(_ advice: DailyAdvice) throws {
        context.insert(advice)
        try context.save()
    }

    func fetch(from startDate: Date, to endDate: Date) throws -> [DailyAdvice] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) else {
            return []
        }
        let predicate = #Predicate<DailyAdvice> { advice in
            advice.date >= start && advice.date < end
        }
        let descriptor = FetchDescriptor<DailyAdvice>(predicate: predicate, sortBy: [SortDescriptor(\.date)])
        return try context.fetch(descriptor)
    }

    func delete(_ advice: DailyAdvice) throws {
        context.delete(advice)
        try context.save()
    }
}
