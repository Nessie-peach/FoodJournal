import XCTest
@testable import FoodJournal

/// 热量缺口卡（R5-3）：缺口/剩余额度计算、当量选择、达标/超目标文案分支
final class CalorieGapCardTests: XCTestCase {

    // MARK: 缺口 / 剩余额度计算

    func testGapAndAllowanceCalculation() {
        // 消耗 2000，摄入 1200，目标 300：缺口 800，超出 500 → 当量最大 ≤500 为中杯奶茶
        let result = CalorieGap.evaluate(totalBurnedKcal: 2000, consumedKcal: 1200, goalKcal: 300)
        XCTAssertEqual(result?.goalStatus, .aboveGoal(excess: 500))
        XCTAssertEqual(result?.hint, .surplus(name: "中杯奶茶"))
    }

    func testPendingSyncReturnsNil() {
        // 未同步（无当日快照）→ nil，UI 走「待同步」空态
        XCTAssertNil(CalorieGap.evaluate(totalBurnedKcal: nil, consumedKcal: 800, goalKcal: 300))
    }

    // MARK: 当量选择

    func testEquivalentSelection() {
        XCTAssertEqual(FoodEquivalents.equivalent(forKcal: 550)?.name, "汉堡")
        XCTAssertEqual(FoodEquivalents.equivalent(forKcal: 400)?.name, "中杯奶茶")
        XCTAssertEqual(FoodEquivalents.equivalent(forKcal: 230)?.name, "一碗米饭")
        // 不足最小项（苹果 95）→ 不显示当量
        XCTAssertNil(FoodEquivalents.equivalent(forKcal: 90))
        // 额度落在两档之间取较小档
        XCTAssertEqual(FoodEquivalents.equivalent(forKcal: 549)?.name, "中杯奶茶")
        XCTAssertEqual(FoodEquivalents.equivalent(forKcal: 239)?.name, "一碗米饭")
        XCTAssertEqual(FoodEquivalents.equivalent(forKcal: 229)?.name, "苹果")
    }

    // MARK: 达标 / 超目标文案分支

    func testBelowGoalStatusAndHiddenHint() {
        // 消耗 1800，摄入 1700，目标 300：缺口 100，还差 200 达标，当量行不显示
        let result = CalorieGap.evaluate(totalBurnedKcal: 1800, consumedKcal: 1700, goalKcal: 300)
        XCTAssertEqual(result?.goalStatus, .belowGoal(remaining: 200))
        XCTAssertEqual(result?.hint, .hidden)
    }

    func testGoalReachedWithTinyExcessShowsGoalReachedHint() {
        // 消耗 2000，摄入 1650，目标 300：缺口 350 达标，超出 50 不足最小当量 → 已达目标提示
        let result = CalorieGap.evaluate(totalBurnedKcal: 2000, consumedKcal: 1650, goalKcal: 300)
        XCTAssertEqual(result?.goalStatus, .aboveGoal(excess: 50))
        XCTAssertEqual(result?.hint, .goalReached)
    }

    func testSurplusEquivalentBoundaries() {
        // 超出 230 → 一碗米饭；超出 95 → 苹果
        let rice = CalorieGap.evaluate(totalBurnedKcal: 2530, consumedKcal: 2000, goalKcal: 300)
        XCTAssertEqual(rice?.goalStatus, .aboveGoal(excess: 230))
        XCTAssertEqual(rice?.hint, .surplus(name: "一碗米饭"))

        let apple = CalorieGap.evaluate(totalBurnedKcal: 2395, consumedKcal: 2000, goalKcal: 300)
        XCTAssertEqual(apple?.hint, .surplus(name: "苹果"))
    }
}
