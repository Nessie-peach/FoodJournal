import Foundation
import SwiftData

/// 单条运动记录（轻量 JSON 存储于 DailyHealthSnapshot.workoutsJSON）
/// 支撑后续统计页按 activityType 聚合；uuid 用于重复同步去重
struct WorkoutRecord: Codable, Equatable, Hashable {
    /// HKWorkout.uuid 的 uuidString
    var uuid: String
    /// HKWorkoutActivityType 名称，如 "running"、"functionalStrengthTraining"
    var activityType: String
    /// 时长（分钟）
    var durationMinutes: Double
    /// 活动消耗（kcal），可能缺失
    var energyKcal: Double?
    /// 运动开始时间
    var startDate: Date
}

/// 每日健康快照（来自 Apple Watch / 健康同步）
@Model
final class DailyHealthSnapshot {
    @Attribute(.unique) var id: UUID
    var date: Date
    /// 活动能量（kcal）
    var activeKcal: Double
    /// 睡眠时长（分钟）
    var sleepMinutes: Double
    /// 当日最早入睡时间（可能缺失）
    var sleepStart: Date?
    /// 当日最晚起床时间（可能缺失）
    var sleepEnd: Date?
    /// 平均心率（bpm）
    var avgHR: Double
    /// 心率变异性（ms，可能缺失）
    var hrvMS: Double?
    /// 当日运动记录 JSON（[WorkoutRecord]），空为无数据
    var workoutsJSON: String?
    /// 最近一次同步时间
    var syncedAt: Date

    init(
        id: UUID = UUID(),
        date: Date = .now,
        activeKcal: Double,
        sleepMinutes: Double,
        sleepStart: Date? = nil,
        sleepEnd: Date? = nil,
        avgHR: Double,
        hrvMS: Double? = nil,
        workoutsJSON: String? = nil,
        syncedAt: Date = .now
    ) {
        self.id = id
        self.date = date
        self.activeKcal = activeKcal
        self.sleepMinutes = sleepMinutes
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.avgHR = avgHR
        self.hrvMS = hrvMS
        self.workoutsJSON = workoutsJSON
        self.syncedAt = syncedAt
    }
}
