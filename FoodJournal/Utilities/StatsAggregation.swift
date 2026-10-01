import Foundation
import HealthKit
import SwiftData

/// 统计页时间粒度
enum StatsGranularity: String, CaseIterable, Identifiable {
    case day = "日"
    case week = "周"
    case month = "月"

    var id: String { rawValue }
}

/// 统计页聚合逻辑：区间计算、逐日取数、运动聚合与文案（纯函数，无副作用，便于单测）
enum StatsAggregation {
    // MARK: - 区间

    /// 统计区间：半开 [start, end) + 区间内逐业务日锚点列表。
    /// 日粒度的 [start, end) 为业务日区间（锚点日 04:00 → 次日 04:00）；
    /// 周/月粒度 start/end 保持自然边界（00:00），数据归属由 dailyPoints 按业务日判定。
    struct DayRange {
        let start: Date
        let end: Date
        let days: [Date]
    }

    /// 统计区间：日=当天业务日（04:00 分界）；周=周一至周日；月=1 日至月末
    static func dateRange(
        for granularity: StatsGranularity, anchor: Date, calendar: Calendar = .current
    ) -> DayRange {
        var calendar = calendar
        calendar.firstWeekday = 2 // 周一为一周起点
        switch granularity {
        case .day:
            // 业务日区间：锚点日 04:00 至次日 04:00
            let businessDay = LogicalDay.businessDay(of: anchor, calendar: calendar)
            let businessRange = LogicalDay.businessDayRange(of: anchor, calendar: calendar)
            return DayRange(
                start: businessRange.start, end: businessRange.end, days: [businessDay]
            )
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start
                ?? calendar.startOfDay(for: anchor)
            return range(from: start, days: 7, calendar: calendar)
        case .month:
            let start = calendar.dateInterval(of: .month, for: anchor)?.start
                ?? calendar.startOfDay(for: anchor)
            let days = calendar.range(of: .day, in: .month, for: anchor)?.count ?? 30
            return range(from: start, days: days, calendar: calendar)
        }
    }

    private static func range(from start: Date, days: Int, calendar: Calendar) -> DayRange {
        let dayDates = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        return DayRange(start: start, end: end, days: dayDates)
    }

    /// 日期步进：日 ±1 天，周 ±7 天（保持周一锚点），月 ±1 月
    static func steppedDate(
        _ date: Date, granularity: StatsGranularity, delta: Int, calendar: Calendar = .current
    ) -> Date {
        var calendar = calendar
        calendar.firstWeekday = 2
        switch granularity {
        case .day:
            return calendar.date(byAdding: .day, value: delta, to: date) ?? date
        case .week:
            return calendar.date(byAdding: .day, value: delta * 7, to: date) ?? date
        case .month:
            return calendar.date(byAdding: .month, value: delta, to: date) ?? date
        }
    }

    /// 「›」是否可用：下一区间的业务日不得超过当前业务日（今天所在区间仍可查看）
    static func canStepForward(
        from anchor: Date, granularity: StatsGranularity, calendar: Calendar = .current, now: Date = .now
    ) -> Bool {
        let next = steppedDate(anchor, granularity: granularity, delta: 1, calendar: calendar)
        let nextDay = LogicalDay.businessDay(of: next, calendar: calendar)
        let todayDay = LogicalDay.businessDay(of: now, calendar: calendar)
        return nextDay <= todayDay
    }

    /// 导航行区间文字：日「10月1日 周三」（业务日锚点）；周「9月28日–10月4日」；月「2026年10月」
    static func rangeDisplayText(
        for granularity: StatsGranularity, anchor: Date, calendar: Calendar = .current
    ) -> String {
        var calendar = calendar
        calendar.firstWeekday = 2
        switch granularity {
        case .day:
            return formatted(
                LogicalDay.businessDay(of: anchor, calendar: calendar),
                format: "M月d日 EEE", calendar: calendar
            )
        case .week:
            let range = dateRange(for: .week, anchor: anchor, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 6, to: range.start) ?? range.start
            return "\(formatted(range.start, format: "M月d日", calendar: calendar))–\(formatted(end, format: "M月d日", calendar: calendar))"
        case .month:
            return formatted(anchor, format: "yyyy年M月", calendar: calendar)
        }
    }

    private static func formatted(_ date: Date, format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: - 逐日取数

    /// 逐日数据点：摄入真实 0 表示未记录（无餐）；消耗/睡眠无快照为 nil
    struct DailyPoint {
        let day: Date
        let intakeKcal: Double
        let burnKcal: Double?
        let sleepMinutes: Double?
        let sleepStart: Date?
        let sleepEnd: Date?
        let deepSleepMin: Double?
        let remSleepMin: Double?
    }

    /// 逐日摄入/消耗/睡眠，与 days 一一对应（缺失日补零/nil，x 轴连续不跳日期）。
    /// 餐按业务日归属（凌晨 04:00 前算前一业务日）；快照按自然日 key 匹配
    static func dailyPoints(
        meals: [Meal], snapshots: [DailyHealthSnapshot], days: [Date], calendar: Calendar = .current
    ) -> [DailyPoint] {
        days.map { day in
            let dayMeals = meals.filter {
                LogicalDay.businessDay(of: $0.date, calendar: calendar) == day
            }
            let intake = dayMeals.reduce(0) { $0 + $1.totalCalories }
            let snapshot = snapshots.first { calendar.isDate($0.date, inSameDayAs: day) }
            return DailyPoint(
                day: day,
                intakeKcal: intake,
                burnKcal: snapshot.map { $0.activeKcal + $0.restingKcal },
                sleepMinutes: snapshot.map { $0.sleepMinutes },
                sleepStart: snapshot?.sleepStart,
                sleepEnd: snapshot?.sleepEnd,
                deepSleepMin: snapshot?.deepSleepMin,
                remSleepMin: snapshot?.remSleepMin
            )
        }
    }

    /// 区间摄入合计（千卡）
    static func totalIntake(_ points: [DailyPoint]) -> Double {
        points.reduce(0) { $0 + $1.intakeKcal }
    }

    /// 区间消耗合计（仅统计有快照的日子）；无任何快照为 nil
    static func totalBurn(_ points: [DailyPoint]) -> Double? {
        let burns = points.compactMap(\.burnKcal)
        return burns.isEmpty ? nil : burns.reduce(0, +)
    }

    /// 有数据日的均值
    static func mean(of values: [Double?]) -> Double? {
        let valid = values.compactMap { $0 }
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    // MARK: - 差值

    /// 摄入 − 消耗 的正负结论（消耗无数据时无法评估）
    enum CalorieBalance: Equatable {
        /// 缺口：消耗 > 摄入（正值=缺口大小）
        case deficit(Double)
        /// 盈余：摄入 > 消耗（正值=盈余大小）
        case surplus(Double)
        case even

        static func evaluate(intake: Double, burn: Double?) -> CalorieBalance? {
            guard let burn else { return nil }
            let delta = intake - burn
            if delta < -0.5 { return .deficit(-delta) }
            if delta > 0.5 { return .surplus(delta) }
            return .even
        }
    }

    /// 整数千卡（千分位逗号）
    static func kcalText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US") // 保证 "," 分组稳定（POSIX locale 不做分组）
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    /// 日差值标注：缺口「−240 千卡」（绿）/ 盈余「+320 千卡」（红），颜色由调用方按 case 取
    static func balanceText(_ balance: CalorieBalance) -> String {
        switch balance {
        case .deficit(let value): return "−\(kcalText(value)) 千卡"
        case .surplus(let value): return "+\(kcalText(value)) 千卡"
        case .even: return "±0 千卡"
        }
    }

    /// 周期总差值文字：「本周合计缺口 1,240 千卡」；消耗无数据返回 nil
    static func periodBalanceText(
        intakeTotal: Double, burnTotal: Double?, granularity: StatsGranularity
    ) -> String? {
        guard let burnTotal,
              let balance = CalorieBalance.evaluate(intake: intakeTotal, burn: burnTotal) else { return nil }
        let unit: String
        switch granularity {
        case .day: unit = "今日"
        case .week: unit = "本周"
        case .month: unit = "本月"
        }
        switch balance {
        case .deficit(let value): return "\(unit)合计缺口 \(kcalText(value)) 千卡"
        case .surplus(let value): return "\(unit)合计盈余 \(kcalText(value)) 千卡"
        case .even: return "\(unit)收支持平"
        }
    }

    // MARK: - 睡眠

    /// Garmin 分期摘要「深睡 x% · REM y%」（基准为快照睡眠时长）；任一数据缺失返回 nil
    static func sleepStageSummary(deep: Double?, rem: Double?, totalMinutes: Double) -> String? {
        guard let deep, let rem, totalMinutes > 0 else { return nil }
        let deepPct = Int((deep / totalMinutes * 100).rounded())
        let remPct = Int((rem / totalMinutes * 100).rounded())
        return "深睡 \(deepPct)% · REM \(remPct)%"
    }

    // MARK: - 运动

    /// 运动类型聚合（周/月视图）：按类型汇总次数/时长/热量，按总热量降序
    struct WorkoutTypeSummary: Equatable, Identifiable {
        let identifier: String
        let displayName: String
        let count: Int
        let totalMinutes: Double
        let totalKcal: Double

        var id: String { identifier }
    }

    static func aggregateWorkouts(
        snapshots: [DailyHealthSnapshot], days: [Date], calendar: Calendar = .current
    ) -> [WorkoutTypeSummary] {
        var byType: [String: (count: Int, minutes: Double, kcal: Double)] = [:]
        for snapshot in snapshots {
            guard days.contains(where: { calendar.isDate(snapshot.date, inSameDayAs: $0) }),
                  snapshot.workoutsJSON != nil else { continue }
            for workout in HealthKitService.decodeWorkouts(snapshot.workoutsJSON) {
                var summary = byType[workout.activityType] ?? (0, 0, 0)
                summary.count += 1
                summary.minutes += workout.durationMinutes
                summary.kcal += workout.energyKcal ?? 0
                byType[workout.activityType] = summary
            }
        }
        return byType
            .map { identifier, summary in
                WorkoutTypeSummary(
                    identifier: identifier,
                    displayName: workoutDisplayName(identifier),
                    count: summary.count,
                    totalMinutes: summary.minutes,
                    totalKcal: summary.kcal
                )
            }
            .sorted {
                $0.totalKcal != $1.totalKcal ? $0.totalKcal > $1.totalKcal : $0.displayName < $1.displayName
            }
    }

    /// 区间内全部运动记录（日视图列表，按开始时间升序）
    static func workouts(
        in snapshots: [DailyHealthSnapshot], days: [Date], calendar: Calendar = .current
    ) -> [WorkoutRecord] {
        snapshots
            .filter { snapshot in days.contains { calendar.isDate(snapshot.date, inSameDayAs: $0) } }
            .flatMap { HealthKitService.decodeWorkouts($0.workoutsJSON) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// 运动类型英文/数值标识 → 中文分类名（跑步/步行/骑行/力量训练/游泳/瑜伽/球类/其他）；未知显示原文
    static func workoutDisplayName(_ identifier: String) -> String {
        let type: HKWorkoutActivityType?
        if let raw = UInt(identifier) {
            type = HKWorkoutActivityType(rawValue: raw)
        } else {
            type = namedActivityTypes[identifier.lowercased()]
        }
        guard let type else { return identifier }
        for (category, types) in categoryTable where types.contains(type) {
            return category
        }
        return identifier
    }

    private static let categoryTable: [(String, Set<HKWorkoutActivityType>)] = [
        ("跑步", [.running]),
        ("步行", [.walking, .hiking]),
        ("骑行", [.cycling, .handCycling]),
        ("力量训练", [.traditionalStrengthTraining, .functionalStrengthTraining, .crossTraining, .coreTraining]),
        ("游泳", [.swimming]),
        ("瑜伽", [.yoga]),
        ("球类", [
            .basketball, .soccer, .tennis, .volleyball, .badminton, .tableTennis,
            .baseball, .softball, .rugby, .cricket, .golf, .handball, .hockey,
            .lacrosse, .bowling, .curling, .americanFootball, .australianFootball,
        ]),
    ]

    /// 兼容历史数据里可能存的英文标识
    private static let namedActivityTypes: [String: HKWorkoutActivityType] = [
        "running": .running,
        "walking": .walking, "hiking": .hiking,
        "cycling": .cycling, "handcycling": .handCycling,
        "swimming": .swimming, "yoga": .yoga,
        "traditionalstrengthtraining": .traditionalStrengthTraining,
        "functionalstrengthtraining": .functionalStrengthTraining,
        "crosstraining": .crossTraining, "coretraining": .coreTraining,
        "basketball": .basketball, "soccer": .soccer, "tennis": .tennis,
        "volleyball": .volleyball, "badminton": .badminton, "tabletennis": .tableTennis,
    ]
}
