import XCTest
import SwiftData
import HealthKit
@testable import FoodJournal

/// 统计页聚合纯函数：区间、消耗口径、运动聚合、缺失日补零、差值文案
final class StatsAggregationTests: XCTestCase {
    /// 固定周一为一周起点，与 StatsAggregation 内部口径一致
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    private func snapshot(
        _ day: Date,
        activeKcal: Double = 0,
        restingKcal: Double = 0,
        sleepMinutes: Double = 0,
        workoutsJSON: String? = nil
    ) -> DailyHealthSnapshot {
        DailyHealthSnapshot(
            date: day,
            activeKcal: activeKcal,
            restingKcal: restingKcal,
            sleepMinutes: sleepMinutes,
            avgHR: 0,
            workoutsJSON: workoutsJSON
        )
    }

    // MARK: 区间计算

    func testWeekRangeCrossesMonthBoundary() throws {
        // 2026-10-01 为周四，所在周为 9月28日（周一）– 10月4日（周日）
        let range = StatsAggregation.dateRange(for: .week, anchor: date(2026, 10, 1), calendar: calendar)
        XCTAssertTrue(calendar.isDate(range.start, inSameDayAs: date(2026, 9, 28)))
        // 半开区间：end 为 10月5日 0 点
        XCTAssertTrue(calendar.isDate(range.end, inSameDayAs: date(2026, 10, 5)))
        XCTAssertEqual(range.days.count, 7)
        XCTAssertEqual(calendar.component(.weekday, from: range.start), 2) // 周一
    }

    func testMonthRangeLeapFebruaryAndMonthLengths() {
        // 闰月：2024 年 2 月 29 天
        let leap = StatsAggregation.dateRange(for: .month, anchor: date(2024, 2, 10), calendar: calendar)
        XCTAssertEqual(leap.days.count, 29)
        XCTAssertTrue(calendar.isDate(leap.start, inSameDayAs: date(2024, 2, 1)))
        XCTAssertTrue(calendar.isDate(leap.end, inSameDayAs: date(2024, 3, 1)))

        // 平年 2 月 28 天、1 月 31 天
        XCTAssertEqual(
            StatsAggregation.dateRange(for: .month, anchor: date(2026, 2, 15), calendar: calendar).days.count,
            28
        )
        XCTAssertEqual(
            StatsAggregation.dateRange(for: .month, anchor: date(2026, 1, 31), calendar: calendar).days.count,
            31
        )
    }

    func testDayRangeAndStepForwardLimit() {
        let anchor = date(2026, 10, 1)
        let range = StatsAggregation.dateRange(for: .day, anchor: anchor, calendar: calendar)
        XCTAssertTrue(calendar.isDate(range.start, inSameDayAs: anchor))
        XCTAssertEqual(range.days.count, 1)

        // 今天可看，再往后不可看；昨天可步进到今天
        let today = calendar.startOfDay(for: Date())
        XCTAssertFalse(StatsAggregation.canStepForward(from: today, granularity: .day, calendar: calendar, now: today))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        XCTAssertTrue(StatsAggregation.canStepForward(from: yesterday, granularity: .day, calendar: calendar, now: today))
    }

    // MARK: 消耗口径

    func testBurnCombinesActiveAndRestingKcal() {
        let days = rangeDays(.week, anchor: date(2026, 10, 1))
        let snapshots = [
            snapshot(date(2026, 9, 28), activeKcal: 300, restingKcal: 1200),
            snapshot(date(2026, 10, 1), activeKcal: 480, restingKcal: 1300),
        ]
        let points = StatsAggregation.dailyPoints(meals: [], snapshots: snapshots, days: days, calendar: calendar)

        XCTAssertEqual(points[0].burnKcal, 1500) // active + resting
        XCTAssertNil(points[1].burnKcal) // 9/29 无快照
        XCTAssertEqual(points[3].burnKcal, 1780)
        XCTAssertEqual(StatsAggregation.totalBurn(points), 3280) // 只合计有快照的日子
        XCTAssertNil(StatsAggregation.totalBurn(StatsAggregation.dailyPoints(meals: [], snapshots: [], days: days)))
    }

    // MARK: 缺失日补零

    func testMissingDaysPaddedToKeepAxisContinuous() {
        let days = rangeDays(.week, anchor: date(2026, 10, 1))
        let meals = [
            Meal(date: date(2026, 9, 29, hour: 8), mealType: .breakfast, name: "早餐",
                 items: [FoodItem(name: "鸡蛋", calories: 200, protein: 12, carbs: 2, fat: 15)]),
        ]
        let snapshots = [snapshot(date(2026, 10, 2), sleepMinutes: 420)]

        let points = StatsAggregation.dailyPoints(meals: meals, snapshots: snapshots, days: days, calendar: calendar)
        XCTAssertEqual(points.count, 7) // 不跳日期
        XCTAssertEqual(points[1].intakeKcal, 200) // 9/29 有餐
        XCTAssertEqual(points[0].intakeKcal, 0) // 缺失日摄入补 0
        XCTAssertNil(points[1].burnKcal)
        XCTAssertNil(points[1].sleepMinutes)
        XCTAssertEqual(points[4].sleepMinutes, 420) // 10/2
    }

    // MARK: 运动聚合

    func testWorkoutAggregationGroupsByTypeAndSortsByKcal() throws {
        let days = rangeDays(.week, anchor: date(2026, 10, 1))
        let workouts = [
            WorkoutRecord(uuid: "1", activityType: "37", durationMinutes: 30, energyKcal: 300, startDate: date(2026, 9, 28, hour: 7)),
            WorkoutRecord(uuid: "2", activityType: "37", durationMinutes: 45, energyKcal: 400, startDate: date(2026, 9, 30, hour: 7)),
            WorkoutRecord(uuid: "3", activityType: "20", durationMinutes: 60, energyKcal: 250, startDate: date(2026, 10, 2, hour: 19)),
        ]
        let snapshots = [
            snapshot(date(2026, 9, 28), workoutsJSON: try XCTUnwrap(HealthKitService.workoutsJSONString(workouts))),
        ]

        let summaries = StatsAggregation.aggregateWorkouts(snapshots: snapshots, days: days, calendar: calendar)
        XCTAssertEqual(summaries.count, 2)
        // 按总热量降序：跑步 700 > 力量训练 250
        XCTAssertEqual(summaries[0].displayName, "跑步")
        XCTAssertEqual(summaries[0].count, 2)
        XCTAssertEqual(summaries[0].totalMinutes, 75)
        XCTAssertEqual(summaries[0].totalKcal, 700)
        XCTAssertEqual(summaries[1].displayName, "力量训练")
        XCTAssertEqual(summaries[1].totalKcal, 250)
    }

    func testWorkoutDisplayNameMapsCategoriesAndFallsBackToRaw() {
        XCTAssertEqual(StatsAggregation.workoutDisplayName("37"), "跑步")
        XCTAssertEqual(StatsAggregation.workoutDisplayName("52"), "步行")
        XCTAssertEqual(StatsAggregation.workoutDisplayName("13"), "骑行")
        XCTAssertEqual(StatsAggregation.workoutDisplayName("46"), "游泳")
        XCTAssertEqual(StatsAggregation.workoutDisplayName("57"), "瑜伽")
        XCTAssertEqual(StatsAggregation.workoutDisplayName("6"), "球类")
        XCTAssertEqual(StatsAggregation.workoutDisplayName("running"), "跑步") // 兼容英文名
        XCTAssertEqual(StatsAggregation.workoutDisplayName("9999"), "9999") // 未知显示原文
        XCTAssertEqual(StatsAggregation.workoutDisplayName("unknownType"), "unknownType")
    }

    // MARK: 差值正负与文案

    func testBalanceTextDeficitAndSurplus() {
        // 缺口：消耗 > 摄入 → −240 千卡
        let deficit = StatsAggregation.CalorieBalance.evaluate(intake: 1000, burn: 1240)
        XCTAssertEqual(deficit, .deficit(240))
        XCTAssertEqual(StatsAggregation.balanceText(deficit!), "−240 千卡")

        // 盈余：摄入 > 消耗 → +320 千卡
        let surplus = StatsAggregation.CalorieBalance.evaluate(intake: 1320, burn: 1000)
        XCTAssertEqual(surplus, .surplus(320))
        XCTAssertEqual(StatsAggregation.balanceText(surplus!), "+320 千卡")

        // 消耗无数据无法评估
        XCTAssertNil(StatsAggregation.CalorieBalance.evaluate(intake: 1000, burn: nil))
    }

    func testPeriodBalanceTextUsesThousandsSeparator() {
        let week = StatsAggregation.periodBalanceText(intakeTotal: 8000, burnTotal: 9240, granularity: .week)
        XCTAssertEqual(week, "本周合计缺口 1,240 千卡")

        let month = StatsAggregation.periodBalanceText(intakeTotal: 9000, burnTotal: 8000, granularity: .month)
        XCTAssertEqual(month, "本月合计盈余 1,000 千卡")

        // 消耗无数据无文案
        XCTAssertNil(StatsAggregation.periodBalanceText(intakeTotal: 1000, burnTotal: nil, granularity: .week))
    }

    // MARK: 睡眠分期

    func testSleepStageSummaryPercentages() {
        XCTAssertEqual(
            StatsAggregation.sleepStageSummary(deep: 90, rem: 60, totalMinutes: 450),
            "深睡 20% · REM 13%"
        )
        XCTAssertNil(StatsAggregation.sleepStageSummary(deep: nil, rem: 60, totalMinutes: 450))
        XCTAssertNil(StatsAggregation.sleepStageSummary(deep: 90, rem: 60, totalMinutes: 0))
    }

    // MARK: 辅助

    private func rangeDays(_ granularity: StatsGranularity, anchor: Date) -> [Date] {
        StatsAggregation.dateRange(for: granularity, anchor: anchor, calendar: calendar).days
    }
}

