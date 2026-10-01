import XCTest
@testable import FoodJournal

/// 业务日（04:00 分界）口径：边界、跨月/跨年、区间、凌晨窗口、
/// 缺口卡消耗取数分支（方案 A）、近三天趋势组装、历史分组归属
final class LogicalDayTests: XCTestCase {

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

    private func anchor(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.startOfDay(for: date(year, month, day, hour: 12))
    }

    private func meal(_ date: Date, calories: Double) -> Meal {
        let item = FoodItem(name: "菜品", calories: calories, protein: 0, carbs: 0, fat: 0)
        return Meal(date: date, mealType: .lunch, name: "测试餐", items: [item])
    }

    private func snapshot(_ date: Date, active: Double, resting: Double = 0) -> DailyHealthSnapshot {
        DailyHealthSnapshot(date: date, activeKcal: active, restingKcal: resting, sleepMinutes: 300, avgHR: 60)
    }

    // MARK: 业务日边界

    /// 03:59 仍属前一业务日
    func test0359BelongsToPreviousBusinessDay() {
        let moment = date(2026, 10, 2, hour: 3, minute: 59)
        XCTAssertEqual(LogicalDay.businessDay(of: moment), anchor(2026, 10, 1))
    }

    /// 04:00 起属当天业务日
    func test0400BelongsToCurrentBusinessDay() {
        let moment = date(2026, 10, 2, hour: 4, minute: 0)
        XCTAssertEqual(LogicalDay.businessDay(of: moment), anchor(2026, 10, 2))
    }

    /// 跨月：10/1 01:00 → 9/30 业务日
    func testCrossMonthLateNightBelongsToPreviousMonthDay() {
        let moment = date(2026, 10, 1, hour: 1)
        XCTAssertEqual(LogicalDay.businessDay(of: moment), anchor(2026, 9, 30))
    }

    /// 跨年：1/1 02:00 → 上年 12/31 业务日
    func testCrossYearLateNightBelongsToPreviousYear() {
        let moment = date(2027, 1, 1, hour: 2)
        XCTAssertEqual(LogicalDay.businessDay(of: moment), anchor(2026, 12, 31))
    }

    // MARK: 业务日区间

    /// 区间：start = 锚点日 04:00，end = 次日 04:00；end 不含（半开 [start, end)）
    func testBusinessDayRangeBoundariesAndHalfOpenEnd() {
        let range = LogicalDay.businessDayRange(of: date(2026, 10, 2, hour: 12))
        XCTAssertEqual(range.start, date(2026, 10, 2, hour: 4))
        XCTAssertEqual(range.end, date(2026, 10, 3, hour: 4))
        // 区间内时刻：04:00 起、次日 03:59 止
        XCTAssertTrue(date(2026, 10, 2, hour: 4) >= range.start && date(2026, 10, 2, hour: 4) < range.end)
        XCTAssertTrue(date(2026, 10, 3, hour: 3, minute: 59) >= range.start && date(2026, 10, 3, hour: 3, minute: 59) < range.end)
        // end 不含：次日 04:00 不属于本业务日
        XCTAssertFalse(date(2026, 10, 3, hour: 4) < range.end)
    }

    /// 凌晨时刻的业务日区间：回退到前一自然日 04:00 → 当天 04:00
    func testBusinessDayRangeForLateNightMoment() {
        let range = LogicalDay.businessDayRange(of: date(2026, 10, 2, hour: 1))
        XCTAssertEqual(range.start, date(2026, 10, 1, hour: 4))
        XCTAssertEqual(range.end, date(2026, 10, 2, hour: 4))
    }

    // MARK: 凌晨窗口与消耗取数分支（方案 A）

    func testLateNightWindowDetection() {
        XCTAssertTrue(LogicalDay.isInLateNightWindow(now: date(2026, 10, 2, hour: 0)))
        XCTAssertTrue(LogicalDay.isInLateNightWindow(now: date(2026, 10, 2, hour: 3, minute: 59)))
        XCTAssertFalse(LogicalDay.isInLateNightWindow(now: date(2026, 10, 2, hour: 4)))
        XCTAssertFalse(LogicalDay.isInLateNightWindow(now: date(2026, 10, 2, hour: 23)))
    }

    /// 缺口卡消耗取数：03:00 → 取前一自然日快照；05:00 → 取当日
    func testBurnSnapshotDayBranches() {
        XCTAssertEqual(
            LogicalDay.burnSnapshotDay(for: date(2026, 10, 2, hour: 3)),
            anchor(2026, 10, 1)
        )
        XCTAssertEqual(
            LogicalDay.burnSnapshotDay(for: date(2026, 10, 2, hour: 5)),
            anchor(2026, 10, 2)
        )
    }

    /// previousCalendarDay：返回前一自然日 00:00 锚点
    func testPreviousCalendarDay() {
        XCTAssertEqual(
            LogicalDay.previousCalendarDay(of: date(2026, 10, 2, hour: 15)),
            anchor(2026, 10, 1)
        )
    }

    // MARK: 近三天趋势按业务日组装

    /// 凌晨 01:00 入参：00:30 的餐归「今天」（前一自然日业务日），
    /// 消耗取前一自然日快照（方案 A），「昨天」= 再前一自然日
    func testTrendPreviewAssemblesByBusinessDayAtLateNight() {
        let now = date(2026, 10, 2, hour: 1)
        let meals = [
            meal(date(2026, 10, 2, hour: 0, minute: 30), calories: 300), // 凌晨 → 业务日 10/1
            meal(date(2026, 10, 1, hour: 19), calories: 400),            // 业务日 10/1
            meal(date(2026, 9, 30, hour: 12), calories: 500),            // 业务日 9/30 = 昨天
            meal(date(2026, 9, 28, hour: 12), calories: 999),            // 业务日 9/28，不在三天内
        ]
        let snapshots = [
            snapshot(date(2026, 10, 1), active: 800, resting: 200), // 10/1 快照 → 今天消耗
        ]
        let rows = TrendPreview.recentThreeDayTrend(meals: meals, snapshots: snapshots, now: now)

        XCTAssertEqual(rows.map(\.label), ["今天", "昨天", "前天"])
        // 今天（业务日 10/1）：凌晨 300 + 晚餐 400；消耗 = 10/1 快照（截至 24:00）
        XCTAssertEqual(rows[0].intake, 700, accuracy: 0.01)
        XCTAssertEqual(rows[0].burn ?? .infinity, 1000, accuracy: 0.01)
        XCTAssertTrue(rows[0].isToday)
        XCTAssertTrue(calendar.isDate(rows[0].date, inSameDayAs: date(2026, 10, 1)))
        // 昨天（业务日 9/30）
        XCTAssertEqual(rows[1].intake, 500, accuracy: 0.01)
        XCTAssertNil(rows[1].burn)
        XCTAssertTrue(calendar.isDate(rows[1].date, inSameDayAs: date(2026, 9, 30)))
        // 前天（业务日 9/29）：无餐无快照
        XCTAssertEqual(rows[2].intake, 0, accuracy: 0.01)
        XCTAssertNil(rows[2].burn)
        XCTAssertTrue(calendar.isDate(rows[2].date, inSameDayAs: date(2026, 9, 29)))
    }

    /// 04:00 整切分：04:00 前的餐归前一业务日，04:00 起归当天业务日
    func testTrendPreviewBoundaryMealsSplitAt0400() {
        let now = date(2026, 10, 2, hour: 12)
        let meals = [
            meal(date(2026, 10, 2, hour: 3, minute: 59), calories: 100), // 业务日 10/1 = 昨天
            meal(date(2026, 10, 2, hour: 4, minute: 0), calories: 200),  // 业务日 10/2 = 今天
        ]
        let rows = TrendPreview.recentThreeDayTrend(meals: meals, snapshots: [], now: now)
        XCTAssertEqual(rows[0].intake, 200, accuracy: 0.01)
        XCTAssertEqual(rows[1].intake, 100, accuracy: 0.01)
    }

    // MARK: JournalCatchup「昨天」定义

    /// 凌晨 01:00 打开 App：当前业务日 = 前一自然日，补生成的「昨天」= 前一业务日
    /// = 当前自然日的前两天（按定义断言 runIfNeeded 的推导）
    func testCatchupYesterdayAtLateNightIsTwoCalendarDaysBack() {
        let now = date(2026, 10, 2, hour: 1)
        let today = LogicalDay.businessDay(of: now, calendar: calendar)
        XCTAssertEqual(today, anchor(2026, 10, 1))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        XCTAssertEqual(yesterday, anchor(2026, 9, 30))
        // 与自然日「昨天」区分：不是当前自然日的前一天（10/1）
        XCTAssertNotEqual(yesterday, LogicalDay.previousCalendarDay(of: now, calendar: calendar))
    }

    /// 05:00 打开 App：当前业务日 = 当天，「昨天」= 前一自然日
    func testCatchupYesterdayAfterBoundaryIsPreviousCalendarDay() {
        let now = date(2026, 10, 2, hour: 5)
        let today = LogicalDay.businessDay(of: now, calendar: calendar)
        XCTAssertEqual(today, anchor(2026, 10, 2))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        XCTAssertEqual(yesterday, anchor(2026, 10, 1))
    }

    // MARK: 历史分组按业务日归并

    /// 同一业务日内的 01:00 与 23:00 两条记录归同一天
    func testHistoryGroupingMergesLateNightAndEveningIntoSameBusinessDay() {
        let meals = [
            meal(date(2026, 10, 2, hour: 1), calories: 100),  // 业务日 10/1
            meal(date(2026, 10, 1, hour: 23), calories: 200), // 业务日 10/1
        ]
        let groups = HistoryGrouping.groupMealsByDay(meals)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(calendar.isDate(groups[0].date, inSameDayAs: date(2026, 10, 1)))
        XCTAssertEqual(groups[0].mealCount, 2)
        XCTAssertEqual(groups[0].totalCalories, 300, accuracy: 0.01)
        // 组内按用餐时间升序：23:00 在 01:00 前
        XCTAssertEqual(groups[0].meals.map(\.date), [date(2026, 10, 1, hour: 23), date(2026, 10, 2, hour: 1)])
    }

    /// 记录业务日去重：凌晨时刻并入前一业务日
    func testRecordedDayCountUsesBusinessDay() {
        let dates = [
            date(2026, 10, 2, hour: 1),  // 业务日 10/1
            date(2026, 10, 1, hour: 12), // 业务日 10/1
            date(2026, 10, 1, hour: 5),  // 业务日 10/1
        ]
        XCTAssertEqual(HistoryGrouping.recordedDayCount(dates: dates), 1)
    }

    // MARK: 统计日粒度区间

    /// 日粒度：区间为业务日 04:00 → 次日 04:00，days 为业务日锚点
    func testStatsDayGranularityUsesBusinessDayRange() {
        let range = StatsAggregation.dateRange(
            for: .day, anchor: date(2026, 10, 2, hour: 1), calendar: calendar
        )
        XCTAssertEqual(range.start, date(2026, 10, 1, hour: 4))
        XCTAssertEqual(range.end, date(2026, 10, 2, hour: 4))
        XCTAssertEqual(range.days, [anchor(2026, 10, 1)])
    }

    /// 日粒度逐日取数：凌晨 00:30 的餐计入前一业务日的摄入
    func testStatsDailyPointsAssignLateNightMealToPreviousBusinessDay() {
        let days = [anchor(2026, 10, 1)]
        let meals = [meal(date(2026, 10, 2, hour: 0, minute: 30), calories: 250)]
        let points = StatsAggregation.dailyPoints(meals: meals, snapshots: [], days: days, calendar: calendar)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].intakeKcal, 250, accuracy: 0.01)
    }
}
