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
    /// Garmin 专有字段字段级合并 upsert（不覆盖 HealthKit 字段）
    @discardableResult
    func upsertGarmin(date: Date, fields: GarminSnapshotFields, syncedAt: Date) throws -> DailyHealthSnapshot
    func delete(_ snapshot: DailyHealthSnapshot) throws
}

/// Garmin 快照字段（字段级合并写入，不触碰 HealthKit 写入的既有字段）
struct GarminSnapshotFields {
    var hrvLastNightAvg: Double?
    var hrvWeeklyAvg: Double?
    var hrvBaselineLow: Double?
    var hrvBaselineHigh: Double?
    var bodyBatteryCurrent: Int?
    var stressAvg: Int?
    var deepSleepMin: Double?
    var remSleepMin: Double?
    var sleepScore: Int?

    init(from data: GarminDailyData) {
        hrvLastNightAvg = data.hrvLastNightAvg
        hrvWeeklyAvg = data.hrvWeeklyAvg
        hrvBaselineLow = data.hrvBaselineLow
        hrvBaselineHigh = data.hrvBaselineHigh
        bodyBatteryCurrent = data.bodyBatteryCurrent
        stressAvg = data.stressAvg.map { Int($0.rounded()) }
        deepSleepMin = data.deepSleepMin
        remSleepMin = data.remSleepMin
        sleepScore = data.sleepScore
    }

    init(
        hrvLastNightAvg: Double? = nil,
        hrvWeeklyAvg: Double? = nil,
        hrvBaselineLow: Double? = nil,
        hrvBaselineHigh: Double? = nil,
        bodyBatteryCurrent: Int? = nil,
        stressAvg: Int? = nil,
        deepSleepMin: Double? = nil,
        remSleepMin: Double? = nil,
        sleepScore: Int? = nil
    ) {
        self.hrvLastNightAvg = hrvLastNightAvg
        self.hrvWeeklyAvg = hrvWeeklyAvg
        self.hrvBaselineLow = hrvBaselineLow
        self.hrvBaselineHigh = hrvBaselineHigh
        self.bodyBatteryCurrent = bodyBatteryCurrent
        self.stressAvg = stressAvg
        self.deepSleepMin = deepSleepMin
        self.remSleepMin = remSleepMin
        self.sleepScore = sleepScore
    }
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

    /// Garmin 专有字段的字段级合并 upsert：只写 Garmin 字段，
    /// 不覆盖 HealthKit 写入的 activeKcal / sleepMinutes / avgHR 等。
    /// 同日已有快照则原行合并；否则新建一行（HealthKit 字段落 0/nil，等待 HealthKit 同步补齐）。
    @discardableResult
    func upsertGarmin(date: Date, fields: GarminSnapshotFields, syncedAt: Date) throws -> DailyHealthSnapshot {
        if let existing = try snapshot(for: date) {
            existing.hrvLastNightAvg = fields.hrvLastNightAvg
            existing.hrvWeeklyAvg = fields.hrvWeeklyAvg
            existing.hrvBaselineLow = fields.hrvBaselineLow
            existing.hrvBaselineHigh = fields.hrvBaselineHigh
            existing.bodyBatteryCurrent = fields.bodyBatteryCurrent
            existing.stressAvg = fields.stressAvg
            existing.deepSleepMin = fields.deepSleepMin
            existing.remSleepMin = fields.remSleepMin
            existing.sleepScore = fields.sleepScore
            existing.syncedAt = syncedAt
            try context.save()
            return existing
        }
        let snapshot = DailyHealthSnapshot(
            date: date,
            activeKcal: 0,
            sleepMinutes: 0,
            avgHR: 0,
            syncedAt: syncedAt
        )
        snapshot.hrvLastNightAvg = fields.hrvLastNightAvg
        snapshot.hrvWeeklyAvg = fields.hrvWeeklyAvg
        snapshot.hrvBaselineLow = fields.hrvBaselineLow
        snapshot.hrvBaselineHigh = fields.hrvBaselineHigh
        snapshot.bodyBatteryCurrent = fields.bodyBatteryCurrent
        snapshot.stressAvg = fields.stressAvg
        snapshot.deepSleepMin = fields.deepSleepMin
        snapshot.remSleepMin = fields.remSleepMin
        snapshot.sleepScore = fields.sleepScore
        context.insert(snapshot)
        try context.save()
        return snapshot
    }

    func delete(_ snapshot: DailyHealthSnapshot) throws {
        context.delete(snapshot)
        try context.save()
    }
}
