import Foundation

/// 历史回看（饮食/锻炼）的按月、按日分组聚合纯函数（无副作用，便于单测）
/// 复用 StatsAggregation 的月份区间、运动类型中文名与 HealthKitService 的 workoutsJSON 解析
enum HistoryGrouping {

    // MARK: - 饮食

    /// 按日分组的饮食卡片：date 为当日 startOfDay，meals 按用餐时间升序
    struct DayMeals: Identifiable {
        let date: Date
        let meals: [Meal]

        var id: Date { date }

        /// 当日合计热量（kcal）
        var totalCalories: Double {
            meals.reduce(0) { $0 + $1.totalCalories }
        }

        var mealCount: Int { meals.count }

        /// 当日全部照片（首图在前），供卡片头部缩略图取用
        var allPhotos: [Data] {
            meals.flatMap(\.allPhotos)
        }

        /// 头部缩略图：最多 3 张
        var photoThumbnails: [Data] {
            Array(allPhotos.prefix(3))
        }

        /// 超出 3 张的附加图数量（显示「+N」）
        var photoExtraCount: Int {
            max(0, allPhotos.count - 3)
        }
    }

    /// 月份半开区间 [start, end)：复用统计页的月份口径（1 日 0 点至次月 1 日 0 点）
    static func monthRange(for date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let range = StatsAggregation.dateRange(for: .month, anchor: date, calendar: calendar)
        return (range.start, range.end)
    }

    /// 按日分组（倒序）；同日内按用餐时间升序
    static func groupMealsByDay(_ meals: [Meal], calendar: Calendar = .current) -> [DayMeals] {
        Dictionary(grouping: meals) { calendar.startOfDay(for: $0.date) }
            .map { day, dayMeals in
                DayMeals(date: day, meals: dayMeals.sorted { $0.date < $1.date })
            }
            .sorted { $0.date > $1.date }
    }

    /// 月度饮食汇总：记录天数去重 + 日均热量（千卡）；无记录返回 (0, 0)
    static func monthlyDietSummary(
        _ meals: [Meal], calendar: Calendar = .current
    ) -> (recordedDays: Int, avgDailyKcal: Double) {
        guard !meals.isEmpty else { return (0, 0) }
        let days = Set(meals.map { calendar.startOfDay(for: $0.date) })
        let total = meals.reduce(0) { $0 + $1.totalCalories }
        return (days.count, total / Double(days.count))
    }

    /// 全量记录天数去重计数（入口「共 N 天」用；只看日期不看营养）
    static func recordedDayCount(dates: [Date], calendar: Calendar = .current) -> Int {
        Set(dates.map { calendar.startOfDay(for: $0) }).count
    }

    // MARK: - 锻炼

    /// 按日分组的锻炼卡片：来自当日快照 + workoutsJSON 解析出的运动记录（只读）
    struct DayExercise: Identifiable {
        let date: Date
        /// 当日健康快照（活动消耗/心率/睡眠展示字段来源）
        let snapshot: DailyHealthSnapshot
        let workouts: [WorkoutRecord]

        var id: Date { date }

        var totalMinutes: Double {
            workouts.reduce(0) { $0 + $1.durationMinutes }
        }

        var totalKcal: Double {
            workouts.reduce(0) { $0 + ($1.energyKcal ?? 0) }
        }
    }

    /// 深睡占比（0-100，Int）；深睡或总睡眠时长缺失返回 nil
    static func deepSleepPercent(_ snapshot: DailyHealthSnapshot) -> Int? {
        guard let deep = snapshot.deepSleepMin, snapshot.sleepMinutes > 0 else { return nil }
        return Int((deep / snapshot.sleepMinutes * 100).rounded())
    }

    /// 按日分组（倒序）；复用 HealthKitService.decodeWorkouts 解析 workoutsJSON。
    /// 无 workout 记录的日子不产生卡片（纯快照日不属于锻炼历史）
    static func groupWorkoutsByDay(
        snapshots: [DailyHealthSnapshot], calendar: Calendar = .current
    ) -> [DayExercise] {
        snapshots.compactMap { snapshot in
            let workouts = HealthKitService.decodeWorkouts(snapshot.workoutsJSON)
            guard !workouts.isEmpty else { return nil }
            return DayExercise(
                date: calendar.startOfDay(for: snapshot.date),
                snapshot: snapshot,
                workouts: workouts.sorted { $0.startDate < $1.startDate }
            )
        }
        .sorted { $0.date > $1.date }
    }

    /// 月度锻炼汇总：有运动天数 + 运动总时长（分钟，取整）
    static func monthlyExerciseSummary(
        snapshots: [DailyHealthSnapshot]
    ) -> (activeDays: Int, totalMinutes: Int) {
        let days = groupWorkoutsByDay(snapshots: snapshots)
        let minutes = days.reduce(0) { $0 + $1.totalMinutes }
        return (days.count, Int(minutes.rounded()))
    }
}
