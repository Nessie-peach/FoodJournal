import Foundation
import HealthKit
import SwiftData

/// HealthKit 读取授权状态。
/// 注意：HealthKit 出于隐私不暴露「读取授权成功」——读取类型的
/// authorizationStatus 只会是 notDetermined 或 sharingDenied。
/// 因此用「是否已请求过授权」辅助判断：已请求且未被拒绝即视为已授权。
enum HealthAuthorizationState {
    case notDetermined
    case denied
    case authorized
}

/// HealthKit 服务层：授权请求、最近 N 天逐日聚合并写入 DailyHealthSnapshot。
/// 只读（不写入任何数据）。所有 HealthKit 查询以 async 包装。
@MainActor
final class HealthKitService {
    /// @AppStorage 标记：是否已弹出过授权请求（只弹一次）
    static let authRequestedStorageKey = "hasRequestedHealthKitAuthorization"

    private let store = HKHealthStore()

    /// 读取类型：活动热量、睡眠、心率、HRV(SDNN)、运动记录
    static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.activeEnergyBurned),
        HKCategoryType(.sleepAnalysis),
        HKQuantityType(.heartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKWorkoutType.workoutType(),
    ]

    /// HKCategoryValueSleepAnalysis 中表示「睡着」的取值
    ///（asleepUnspecified=1 / asleepCore=3 / asleepDeep=4 / asleepREM=5）
    private static let asleepValues: Set<Int> = [1, 3, 4, 5]

    // MARK: - 授权

    func authorizationState(hasRequestedBefore: Bool) -> HealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable() else { return .notDetermined }
        let statuses = Self.readTypes.map { store.authorizationStatus(for: $0) }
        if statuses.contains(.sharingDenied) { return .denied }
        if !hasRequestedBefore, statuses.allSatisfy({ $0 == .notDetermined }) {
            return .notDetermined
        }
        return .authorized
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(
                domain: "HealthKitService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "此设备不支持健康数据"]
            )
        }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    // MARK: - 同步

    /// 对最近 N 天（含今天）逐日聚合并 upsert 到 DailyHealthSnapshot。
    /// 未授权时直接跳过。全天所有数据均缺失时不创建/更新该天快照。
    func syncRecent(days: Int = 7, context: ModelContext) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let hasRequested = UserDefaults.standard.bool(forKey: Self.authRequestedStorageKey)
        guard authorizationState(hasRequestedBefore: hasRequested) == .authorized else { return }

        let repository = HealthSnapshotRepository(context: context)
        let calendar = Calendar.current
        let now = Date()
        let syncedAt = now

        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            else { continue }
            let dayStart = calendar.startOfDay(for: day)

            // 活动热量：当日累计和；无数据为 nil（落库 0）
            let activeKcal = await quantitySum(
                HKQuantityType(.activeEnergyBurned), unit: .kilocalorie(),
                start: dayStart, end: dayEnd
            )

            // 心率均值 / HRV(SDNN) 均值；nil = 当日无样本
            let avgHR = await quantityAverage(
                HKQuantityType(.heartRate), unit: HKUnit.count().unitDivided(by: .minute()),
                start: dayStart, end: dayEnd
            )
            let hrvMS = await quantityAverage(
                HKQuantityType(.heartRateVariabilitySDNN), unit: HKUnit(from: "ms"),
                start: dayStart, end: dayEnd
            )

            // 睡眠：查询窗口向前多取一天，覆盖「昨晚入睡今晨醒来」的跨天样本，
            // 归属口径见 attributeSleep 注释
            let sleepSamples = (try? await samples(
                of: HKCategoryType(.sleepAnalysis),
                start: dayStart.addingTimeInterval(-86_400), end: dayEnd
            )) ?? []
            let asleepIntervals = sleepSamples
                .compactMap { $0 as? HKCategorySample }
                .filter { Self.asleepValues.contains($0.value) }
                .map { SleepInterval(start: $0.startDate, end: $0.endDate) }
            let sleep = Self.attributeSleep(
                asleepIntervals: asleepIntervals, dayStart: dayStart, dayEnd: dayEnd
            )

            // 运动记录：当日样本，与已有记录按 uuid 去重合并
            let workoutSamples = (try? await samples(
                of: HKWorkoutType.workoutType(), start: dayStart, end: dayEnd
            )) ?? []
            let incoming = workoutSamples.compactMap { $0 as? HKWorkout }.map { workout in
                WorkoutRecord(
                    uuid: workout.uuid.uuidString,
                    activityType: String(workout.workoutActivityType.rawValue),
                    durationMinutes: workout.duration / 60,
                    energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                    startDate: workout.startDate
                )
            }
            let existingWorkouts = Self.decodeWorkouts(
                try? repository.snapshot(for: day)?.workoutsJSON
            )
            let merged = Self.mergeWorkouts(existing: existingWorkouts, incoming: incoming)
            let workoutsJSON = Self.workoutsJSONString(merged)

            // 全天无任何数据：跳过，避免制造全零快照
            let hasAnyData = activeKcal != nil || sleep.minutes > 0
                || avgHR != nil || hrvMS != nil || !merged.isEmpty
            guard hasAnyData else { continue }

            do {
                try repository.upsert(
                    date: day,
                    activeKcal: activeKcal ?? 0,
                    sleepMinutes: sleep.minutes,
                    sleepStart: sleep.earliestStart,
                    sleepEnd: sleep.latestEnd,
                    avgHR: avgHR ?? 0,
                    hrvMS: hrvMS,
                    workoutsJSON: workoutsJSON,
                    syncedAt: syncedAt
                )
            } catch {
                continue // 单天失败不影响其余天
            }
        }
    }

    // MARK: - 可测试的纯函数

    struct SleepInterval {
        let start: Date
        let end: Date
    }

    /// 睡眠归属口径（简单方案）：睡眠样本按「与当天的区间交集」累计分钟数。
    /// 例如 23:00–07:00 的整段睡眠，贡献 60 分钟给前一天、420 分钟给当天。
    /// sleepStart/sleepEnd 取与当天有交集的样本中最早的入睡时刻 / 最晚的醒来时刻（原始时间，不裁剪）。
    nonisolated static func attributeSleep(
        asleepIntervals: [SleepInterval], dayStart: Date, dayEnd: Date
    ) -> (minutes: Double, earliestStart: Date?, latestEnd: Date?) {
        var minutes: Double = 0
        var earliestStart: Date?
        var latestEnd: Date?
        for interval in asleepIntervals where interval.end > dayStart && interval.start < dayEnd {
            let overlapStart = max(interval.start, dayStart)
            let overlapEnd = min(interval.end, dayEnd)
            if overlapEnd > overlapStart {
                minutes += overlapEnd.timeIntervalSince(overlapStart) / 60
            }
            if earliestStart == nil || interval.start < earliestStart! {
                earliestStart = interval.start
            }
            if latestEnd == nil || interval.end > latestEnd! {
                latestEnd = interval.end
            }
        }
        return (minutes, earliestStart, latestEnd)
    }

    /// 运动记录去重合并：以 uuid 为准，同一 uuid 保留已有记录，不产生重复
    nonisolated static func mergeWorkouts(existing: [WorkoutRecord], incoming: [WorkoutRecord]) -> [WorkoutRecord] {
        var byUUID = Dictionary(uniqueKeysWithValues: existing.map { ($0.uuid, $0) })
        for workout in incoming where byUUID[workout.uuid] == nil {
            byUUID[workout.uuid] = workout
        }
        return byUUID.values.sorted { $0.startDate < $1.startDate }
    }

    nonisolated static func workoutsJSONString(_ workouts: [WorkoutRecord]) -> String? {
        guard !workouts.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(workouts) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeWorkouts(_ json: String?) -> [WorkoutRecord] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WorkoutRecord].self, from: data)) ?? []
    }

    // MARK: - HealthKit async 包装

    /// 当日 [start, end) 内某数值类型的累计和；无数据返回 nil
    private func quantitySum(
        _ type: HKQuantityType, unit: HKUnit, start: Date, end: Date
    ) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: .cumulativeSum
            ) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// 当日 [start, end) 内某数值类型的均值；无数据返回 nil
    private func quantityAverage(
        _ type: HKQuantityType, unit: HKUnit, start: Date, end: Date
    ) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: .discreteAverage
            ) { _, statistics, _ in
                continuation.resume(returning: statistics?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// [start, end) 区间内的样本列表
    private func samples(
        of type: HKSampleType, start: Date, end: Date
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }
}
