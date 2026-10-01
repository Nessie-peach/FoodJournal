import XCTest
import SwiftData
@testable import FoodJournal

/// 历史回看分组聚合纯函数：跨月边界、单日多餐、空月、月度汇总、workoutsJSON 解析、运动汇总
final class HistoryGroupingTests: XCTestCase {

    private var calendar: Calendar { Calendar.current }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func meal(
        _ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0,
        type: MealType = .lunch, name: String = "测试餐",
        calories: Double = 0, photoData: Data? = nil, additionalPhotos: [Data] = []
    ) -> Meal {
        let item = FoodItem(name: "菜品", calories: calories, protein: 0, carbs: 0, fat: 0)
        return Meal(
            date: date(year, month, day, hour: hour, minute: minute),
            mealType: type, name: name,
            photoData: photoData, additionalPhotos: additionalPhotos,
            items: [item]
        )
    }

    private func snapshot(_ day: Date, workouts: [WorkoutRecord]) -> DailyHealthSnapshot {
        DailyHealthSnapshot(
            date: day,
            activeKcal: 200,
            sleepMinutes: 300,
            avgHR: 60,
            workoutsJSON: HealthKitService.workoutsJSONString(workouts)
        )
    }

    private func workout(_ type: String, minutes: Double, kcal: Double? = 100) -> WorkoutRecord {
        WorkoutRecord(
            uuid: UUID().uuidString,
            activityType: type,
            durationMinutes: minutes,
            energyKcal: kcal,
            startDate: .now
        )
    }

    // MARK: 月份区间

    func testMonthRangeCoversWholeMonth() {
        let range = HistoryGrouping.monthRange(for: date(2026, 9, 15))
        XCTAssertTrue(calendar.isDate(range.start, inSameDayAs: date(2026, 9, 1)))
        XCTAssertTrue(calendar.isDate(range.end, inSameDayAs: date(2026, 10, 1)))
        // 半开区间：9/30 深夜 23:59 落在 9 月区间内
        XCTAssertTrue(date(2026, 9, 30, hour: 23, minute: 59) >= range.start && date(2026, 9, 30, hour: 23, minute: 59) < range.end)
    }

    // MARK: 饮食按日分组

    func testGroupMealsCrossMonthBoundaryNotMixed() {
        // 业务日口径（04:00 分界）：9/30 深夜 23:30 与 10/1 凌晨 00:30 同属 9/30 业务日
        let meals = [
            meal(2026, 9, 30, hour: 23, minute: 30, name: "夜宵"),
            meal(2026, 10, 1, hour: 0, minute: 30, name: "凌晨加餐"),
        ]
        let groups = HistoryGrouping.groupMealsByDay(meals)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(calendar.isDate(groups[0].date, inSameDayAs: date(2026, 9, 30)))
        XCTAssertEqual(groups[0].meals.count, 2)
        // 业务日边界 04:00 才切分：9/30 03:00 归 9/29 业务日，与 9/30 晚餐不混
        let boundaryMeals = [
            meal(2026, 9, 30, hour: 3, name: "凌晨（归 9/29）"),
            meal(2026, 9, 30, hour: 22, name: "晚餐（归 9/30）"),
        ]
        let boundaryGroups = HistoryGrouping.groupMealsByDay(boundaryMeals)
        XCTAssertEqual(boundaryGroups.count, 2)
        XCTAssertTrue(calendar.isDate(boundaryGroups[0].date, inSameDayAs: date(2026, 9, 30)))
        XCTAssertEqual(boundaryGroups[0].meals.first?.name, "晚餐（归 9/30）")
        XCTAssertTrue(calendar.isDate(boundaryGroups[1].date, inSameDayAs: date(2026, 9, 29)))
        XCTAssertEqual(boundaryGroups[1].meals.first?.name, "凌晨（归 9/29）")
    }

    func testGroupMealsSingleDayMultipleMealsWithTotal() {
        let meals = [
            meal(2026, 10, 1, hour: 8, type: .breakfast, name: "早餐", calories: 320),
            meal(2026, 10, 1, hour: 12, type: .lunch, name: "午餐", calories: 640),
            meal(2026, 10, 1, hour: 19, type: .dinner, name: "晚餐", calories: 659),
        ]
        let groups = HistoryGrouping.groupMealsByDay(meals)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].mealCount, 3)
        XCTAssertEqual(groups[0].totalCalories, 1619, accuracy: 0.01)
        // 同日内按时间升序
        XCTAssertEqual(groups[0].meals.map(\.name), ["早餐", "午餐", "晚餐"])
    }

    func testGroupMealsEmptyArrayReturnsEmpty() {
        XCTAssertTrue(HistoryGrouping.groupMealsByDay([]).isEmpty)
    }

    func testPhotoThumbnailsLimitedToThreeWithExtraCount() {
        let photos = [Data([1]), Data([2]), Data([3]), Data([4]), Data([5])]
        let first = meal(2026, 10, 1, photoData: photos[0], additionalPhotos: [photos[1]])
        let second = meal(2026, 10, 1, photoData: photos[2], additionalPhotos: [photos[3], photos[4]])
        let groups = HistoryGrouping.groupMealsByDay([first, second])
        XCTAssertEqual(groups[0].photoThumbnails.count, 3)
        XCTAssertEqual(groups[0].photoExtraCount, 2)
    }

    // MARK: 月度饮食汇总

    func testMonthlyDietSummaryDeduplicatesDaysAndAverages() {
        let meals = [
            meal(2026, 10, 1, hour: 8, calories: 300),
            meal(2026, 10, 1, hour: 19, calories: 500),
            meal(2026, 10, 2, calories: 400),
            meal(2026, 10, 3, calories: 600),
        ]
        let summary = HistoryGrouping.monthlyDietSummary(meals)
        XCTAssertEqual(summary.recordedDays, 3) // 10/1 两条只算一天
        XCTAssertEqual(summary.avgDailyKcal, 1800.0 / 3.0, accuracy: 0.01)
    }

    func testMonthlyDietSummaryEmptyMonthReturnsZero() {
        let summary = HistoryGrouping.monthlyDietSummary([])
        XCTAssertEqual(summary.recordedDays, 0)
        XCTAssertEqual(summary.avgDailyKcal, 0)
    }

    // MARK: 锻炼按日分组

    func testGroupWorkoutsByDayParsesWorkoutsJSON() throws {
        let day = date(2026, 10, 1)
        let snapshot = snapshot(day, workouts: [
            workout("running", minutes: 32, kcal: 286),
            workout("walking", minutes: 45, kcal: 120),
        ])
        let groups = HistoryGrouping.groupWorkoutsByDay(snapshots: [snapshot])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].workouts.count, 2)
        XCTAssertEqual(groups[0].totalMinutes, 77, accuracy: 0.01)
        XCTAssertEqual(groups[0].totalKcal, 406, accuracy: 0.01)
        // 快照展示字段透传
        XCTAssertEqual(groups[0].snapshot.activeKcal, 200)
    }

    func testGroupWorkoutsByDaySkipsDaysWithoutWorkouts() {
        let withWorkout = snapshot(date(2026, 10, 1), workouts: [workout("running", minutes: 30)])
        // 无 workoutsJSON 的纯快照日、以及空数组 JSON 均不产生卡片
        let noJSON = DailyHealthSnapshot(date: date(2026, 10, 2), activeKcal: 100, sleepMinutes: 0, avgHR: 0)
        let emptyJSON = DailyHealthSnapshot(
            date: date(2026, 10, 3), activeKcal: 100, sleepMinutes: 0, avgHR: 0, workoutsJSON: "[]"
        )
        let groups = HistoryGrouping.groupWorkoutsByDay(snapshots: [noJSON, withWorkout, emptyJSON])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(calendar.isDate(groups[0].date, inSameDayAs: date(2026, 10, 1)))
    }

    func testWorkoutDisplayNameMappedToChinese() {
        XCTAssertEqual(StatsAggregation.workoutDisplayName("running"), "跑步")
        XCTAssertEqual(StatsAggregation.workoutDisplayName("walking"), "步行")
    }

    // MARK: 月度锻炼汇总

    func testMonthlyExerciseSummaryCountsDaysAndTotalMinutes() {
        let snapshots = [
            snapshot(date(2026, 10, 1), workouts: [workout("running", minutes: 32)]),
            snapshot(date(2026, 10, 2), workouts: [
                workout("walking", minutes: 45),
                workout("cycling", minutes: 15, kcal: nil),
            ]),
            // 有快照但无运动：不计天数
            snapshot(date(2026, 10, 3), workouts: []),
        ]
        let summary = HistoryGrouping.monthlyExerciseSummary(snapshots: snapshots)
        XCTAssertEqual(summary.activeDays, 2)
        XCTAssertEqual(summary.totalMinutes, 92)
    }

    func testMonthlyExerciseSummaryEmptyMonthReturnsZero() {
        let summary = HistoryGrouping.monthlyExerciseSummary(snapshots: [])
        XCTAssertEqual(summary.activeDays, 0)
        XCTAssertEqual(summary.totalMinutes, 0)
    }

    // MARK: 记录天数计数（入口「共 N 天」）

    func testRecordedDayCountDeduplicatesSameDayDates() {
        let dates = [
            date(2026, 10, 1, hour: 8),
            date(2026, 10, 1, hour: 19),
            date(2026, 9, 30, hour: 23),
            date(2026, 10, 2),
        ]
        XCTAssertEqual(HistoryGrouping.recordedDayCount(dates: dates), 3)
        XCTAssertEqual(HistoryGrouping.recordedDayCount(dates: []), 0)
    }
}
