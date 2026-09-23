import Foundation
import SwiftData

/// 每日小记仓库协议：一天一篇，按 date 取/存
@MainActor
protocol JournalRepositoryProtocol {
    /// 取某天的日记（不存在返回 nil）
    func journal(for date: Date) throws -> DailyJournal?
    /// 保存某天的日记：存在则更新文本，不存在则新建
    @discardableResult
    func save(text: String, for date: Date) throws -> DailyJournal
    func delete(_ journal: DailyJournal) throws
}

@MainActor
final class JournalRepository: JournalRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    private static func dayRange(for date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    func journal(for date: Date) throws -> DailyJournal? {
        guard let range = Self.dayRange(for: date, calendar: .current) else { return nil }
        let start = range.start
        let end = range.end
        let predicate = #Predicate<DailyJournal> { journal in
            journal.date >= start && journal.date < end
        }
        var descriptor = FetchDescriptor<DailyJournal>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func save(text: String, for date: Date) throws -> DailyJournal {
        if let existing = try journal(for: date) {
            existing.text = text
            try context.save()
            return existing
        }
        let journal = DailyJournal(date: date, text: text)
        context.insert(journal)
        try context.save()
        return journal
    }

    func delete(_ journal: DailyJournal) throws {
        context.delete(journal)
        try context.save()
    }
}
