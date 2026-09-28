import Foundation
import SwiftData

/// 每日健康快照仓库协议：按 date upsert（一天一份，重复写入更新）
@MainActor
protocol HealthSnapshotRepositoryProtocol {
    func snapshot(for date: Date) throws -> DailyHealthSnapshot?
    /// 同一天已存在则更新，否则新建
    @discardableResult
    func upsert(
        date: Date,
        activeKcal: Double,
        restingKcal: Double,
        sleepMinutes: Double,
        sleepStart: Date?,
        sleepEnd: Date?,
        avgHR: Double,
        hrvMS: Double?,
        workoutsJSON: String?,
        syncedAt: Date
    ) throws -> DailyHealthSnapshot
    func fetchAll() throws -> [DailyHealthSnapshot]
    func delete(_ snapshot: DailyHealthSnapshot) throws
}

@MainActor
final class HealthSnapshotRepository: HealthSnapshotRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    private static func dayRange(for date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    func snapshot(for date: Date) throws -> DailyHealthSnapshot? {
        guard let range = Self.dayRange(for: date, calendar: .current) else { return nil }
        let start = range.start
        let end = range.end
        let predicate = #Predicate<DailyHealthSnapshot> { snapshot in
            snapshot.date >= start && snapshot.date < end
        }
        var descriptor = FetchDescriptor<DailyHealthSnapshot>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func upsert(
        date: Date,
        activeKcal: Double,
        restingKcal: Double = 0,
        sleepMinutes: Double,
        sleepStart: Date? = nil,
        sleepEnd: Date? = nil,
        avgHR: Double,
        hrvMS: Double? = nil,
        workoutsJSON: String? = nil,
        syncedAt: Date
    ) throws -> DailyHealthSnapshot {
        if let existing = try snapshot(for: date) {
            existing.activeKcal = activeKcal
            existing.restingKcal = restingKcal
            existing.sleepMinutes = sleepMinutes
            existing.sleepStart = sleepStart
            existing.sleepEnd = sleepEnd
            existing.avgHR = avgHR
            existing.hrvMS = hrvMS
            existing.workoutsJSON = workoutsJSON
            existing.syncedAt = syncedAt
            try context.save()
            return existing
        }
        let snapshot = DailyHealthSnapshot(
            date: date,
            activeKcal: activeKcal,
            restingKcal: restingKcal,
            sleepMinutes: sleepMinutes,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            avgHR: avgHR,
            hrvMS: hrvMS,
            workoutsJSON: workoutsJSON,
            syncedAt: syncedAt
        )
        context.insert(snapshot)
        try context.save()
        return snapshot
    }

    func fetchAll() throws -> [DailyHealthSnapshot] {
        let descriptor = FetchDescriptor<DailyHealthSnapshot>(sortBy: [SortDescriptor(\.date)])
        return try context.fetch(descriptor)
    }

    func delete(_ snapshot: DailyHealthSnapshot) throws {
        context.delete(snapshot)
        try context.save()
    }
}
