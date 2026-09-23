import Foundation
import SwiftData

/// 每日健康快照（来自 Apple Watch / 健康同步）
@Model
final class DailyHealthSnapshot {
    @Attribute(.unique) var id: UUID
    var date: Date
    /// 活动能量（kcal）
    var activeKcal: Double
    /// 睡眠时长（分钟）
    var sleepMinutes: Double
    /// 平均心率（bpm）
    var avgHR: Double
    /// 心率变异性（ms，可能缺失）
    var hrvMS: Double?
    /// 最近一次同步时间
    var syncedAt: Date

    init(
        id: UUID = UUID(),
        date: Date = .now,
        activeKcal: Double,
        sleepMinutes: Double,
        avgHR: Double,
        hrvMS: Double? = nil,
        syncedAt: Date = .now
    ) {
        self.id = id
        self.date = date
        self.activeKcal = activeKcal
        self.sleepMinutes = sleepMinutes
        self.avgHR = avgHR
        self.hrvMS = hrvMS
        self.syncedAt = syncedAt
    }
}
