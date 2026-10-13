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
    /// 按**自然日**区间查询
    /// - Warning: 自然日口径；业务日（04:00 分界）场景请改用 `fetch(businessDaysFrom:to:)`
    @available(*, deprecated, message: "自然日口径；业务日场景请用 fetch(businessDaysFrom:to:)")
    func fetch(from: Date, to: Date) throws -> [DailyAdvice]
    /// 按**业务日**口径区间查询：`startAnchor` / `endAnchor` 为业务日**锚点**（该业务日日历日 00:00），
    /// 返回归属业务日 ∈ [startAnchor, endAnchor) 的建议（半开区间）。
    /// 实际取数区间为 [startAnchor 04:00, endAnchor 04:00)。
    func fetch(businessDaysFrom startAnchor: Date, to endAnchor: Date) throws -> [DailyAdvice]
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

    @available(*, deprecated, message: "自然日口径；业务日场景请用 fetch(businessDaysFrom:to:)")
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

    /// 业务日口径区间查询：入参为**业务日锚点**（00:00），
    /// 经 `LogicalDay.businessDayRange(forAnchor:)` 换算为 [锚点日 04:00, 次日 04:00)，
    /// 不可再走 `businessDayRange(of:)`（锚点 hour < 4 会被二次减一天）。
    func fetch(businessDaysFrom startAnchor: Date, to endAnchor: Date) throws -> [DailyAdvice] {
        let calendar = Calendar.current
        let start = LogicalDay.businessDayRange(forAnchor: startAnchor, calendar: calendar).start
        let end = LogicalDay.businessDayRange(forAnchor: endAnchor, calendar: calendar).start
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
