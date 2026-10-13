import Foundation
import SwiftData

/// 每日小记仓库协议：一天一篇，按**业务日锚点**存取（04:00 分界，凌晨 04:00 前归前一业务日）
@MainActor
protocol JournalRepositoryProtocol {
    /// 取某业务日的小记（不存在返回 nil）
    /// - Parameter date: 业务日内**任一时刻**；内部归一到该时刻所属业务日锚点
    func journal(for date: Date) throws -> DailyJournal?
    /// 取某业务日的小记；`anchor` 为业务日**锚点**（该业务日日历日 00:00）
    func journal(forBusinessDay anchor: Date) throws -> DailyJournal?
    /// 保存某业务日的小记：存在则更新文本，不存在则新建。落库 `date` = 业务日锚点
    /// - Parameter date: 业务日内**任一时刻**；内部归一到该时刻所属业务日锚点
    @discardableResult
    func save(text: String, for date: Date) throws -> DailyJournal
    /// 保存某业务日的小记；`anchor` 为业务日**锚点**（该业务日日历日 00:00）
    @discardableResult
    func save(text: String, forBusinessDay anchor: Date) throws -> DailyJournal
    func delete(_ journal: DailyJournal) throws
}

@MainActor
final class JournalRepository: JournalRepositoryProtocol {
    private let context: ModelContext
    private let calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .current) {
        self.context = context
        self.calendar = calendar
    }

    /// 业务日锚点 → 该锚点所在**自然日**半开区间 [锚点 00:00, 次日 00:00)。
    /// 落库的 `date` 即业务日锚点（00:00），必然落在本区间内；区间上界为下一业务日锚点，
    /// 半开不含，保证相邻业务日不串。
    private func anchorDayRange(forAnchor anchor: Date) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: anchor)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return (start, end)
    }

    func journal(for date: Date) throws -> DailyJournal? {
        try journal(forBusinessDay: LogicalDay.businessDay(of: date, calendar: calendar))
    }

    func journal(forBusinessDay anchor: Date) throws -> DailyJournal? {
        let range = anchorDayRange(forAnchor: anchor)
        let start = range.start
        let end = range.end
        let predicate = #Predicate<DailyJournal> { journal in
            journal.date >= start && journal.date < end
        }
        var descriptor = FetchDescriptor<DailyJournal>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @discardableResult
    func save(text: String, for date: Date) throws -> DailyJournal {
        try save(text: text, forBusinessDay: LogicalDay.businessDay(of: date, calendar: calendar))
    }

    @discardableResult
    func save(text: String, forBusinessDay anchor: Date) throws -> DailyJournal {
        // 锚点语义兜底：即使传入带时分的时刻，也归一到日历日 00:00
        let normalizedAnchor = calendar.startOfDay(for: anchor)
        if let existing = try journal(forBusinessDay: normalizedAnchor) {
            existing.text = text
            try context.save()
            return existing
        }
        let journal = DailyJournal(date: normalizedAnchor, text: text)
        context.insert(journal)
        try context.save()
        return journal
    }

    func delete(_ journal: DailyJournal) throws {
        context.delete(journal)
        try context.save()
    }
}
