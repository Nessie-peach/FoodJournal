import XCTest
@testable import FoodJournal

/// 「近三天」趋势表卡组装纯函数：三日行顺序/汇总、无快照日、差值符号、全无消耗标记
final class TrendPreviewTests: XCTestCase {

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

    private func meal(_ day: Date, hour: Int = 12, calories: Double) -> Meal {
        let item = FoodItem(name: "菜品", calories: calories, protein: 0, carbs: 0, fat: 0)
        return Meal(date: day, mealType: .lunch, name: "测试餐", items: [item])
    }

    private func snapshot(_ day: Date, active: Double, resting: Double = 0) -> DailyHealthSnapshot {
        DailyHealthSnapshot(date: day, activeKcal: active, restingKcal: resting, sleepMinutes: 300, avgHR: 60)
    }

    // MARK: 三日行组装

    func testThreeDayRowsAssembledWithTotalsAndOrder() {
        let now = date(2026, 10, 1, hour: 15)
        let meals = [
            meal(date(2026, 10, 1), hour: 8, calories: 300),
            meal(date(2026, 10, 1), hour: 19, calories: 500),
            meal(date(2026, 9, 30), calories: 400),
            meal(date(2026, 9, 29, hour: 23, minute: 59), calories: 200),
        ]
        let snapshots = [
            snapshot(date(2026, 10, 1), active: 800, resting: 1500),
            snapshot(date(2026, 9, 30), active: 300),
        ]
        let rows = TrendPreview.recentThreeDayTrend(meals: meals, snapshots: snapshots, now: now)

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.label), ["今天", "昨天", "前天"])
        // 今天：两餐合计 800，消耗 800+1500=2300，差值 −1500
        XCTAssertEqual(rows[0].intake, 800, accuracy: 0.01)
        XCTAssertEqual(rows[0].burn ?? .infinity, 2300, accuracy: 0.01)
        XCTAssertEqual(rows[0].diff ?? .infinity, -1500, accuracy: 0.01)
        XCTAssertTrue(rows[0].isToday)
        // 昨天：单餐 400，消耗 300，差值 +100
        XCTAssertEqual(rows[1].intake, 400, accuracy: 0.01)
        XCTAssertEqual(rows[1].burn ?? .infinity, 300, accuracy: 0.01)
        XCTAssertEqual(rows[1].diff ?? .infinity, 100, accuracy: 0.01)
        XCTAssertFalse(rows[1].isToday)
        // 前天：有餐 200 但无快照 → 消耗与差值缺失
        XCTAssertEqual(rows[2].intake, 200, accuracy: 0.01)
        XCTAssertNil(rows[2].burn)
        XCTAssertNil(rows[2].diff)
        XCTAssertTrue(calendar.isDate(rows[2].date, inSameDayAs: date(2026, 9, 29)))
    }

    // MARK: 无快照日

    func testDayWithoutSnapshotHasNilBurnAndDiff() {
        let now = date(2026, 10, 1, hour: 15)
        let rows = TrendPreview.recentThreeDayTrend(
            meals: [meal(now, calories: 600)], snapshots: [], now: now
        )
        XCTAssertEqual(rows[0].intake, 600, accuracy: 0.01)
        XCTAssertNil(rows[0].burn)
        XCTAssertNil(rows[0].diff)
        // 无餐日摄入记 0（有数据格），无快照日消耗为 nil
        XCTAssertEqual(rows[1].intake, 0, accuracy: 0.01)
        XCTAssertNil(rows[1].burn)
    }

    // MARK: 差值符号

    func testDiffSignMatchesIntakeVsBurn() {
        let now = date(2026, 10, 1)
        // 缺口：摄入 1000 < 消耗 1334 → 负
        let gap = TrendPreview.recentThreeDayTrend(
            meals: [meal(now, calories: 1000)],
            snapshots: [snapshot(now, active: 334, resting: 1000)],
            now: now
        )
        XCTAssertEqual(gap[0].diff ?? .infinity, -334, accuracy: 0.01)
        XCTAssertLessThan(gap[0].diff ?? 0, 0)
        // 盈余：摄入 1000 > 消耗 740 → 正
        let surplus = TrendPreview.recentThreeDayTrend(
            meals: [meal(now, calories: 1000)],
            snapshots: [snapshot(now, active: 0, resting: 740)],
            now: now
        )
        XCTAssertEqual(surplus[0].diff ?? .infinity, 260, accuracy: 0.01)
        XCTAssertGreaterThan(surplus[0].diff ?? 0, 0)
    }

    // MARK: 全无消耗标记

    func testShowsBurnPendingNoticeOnlyWhenAllThreeDaysLackBurn() {
        let now = date(2026, 10, 1)
        let allEmpty = TrendPreview.recentThreeDayTrend(meals: [], snapshots: [], now: now)
        XCTAssertTrue(TrendPreview.showsBurnPendingNotice(allEmpty))

        // 任一天有快照 → 不提示
        let partial = TrendPreview.recentThreeDayTrend(
            meals: [], snapshots: [snapshot(date(2026, 9, 29), active: 100)], now: now
        )
        XCTAssertFalse(TrendPreview.showsBurnPendingNotice(partial))
    }
}
