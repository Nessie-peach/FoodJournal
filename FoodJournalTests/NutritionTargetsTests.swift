import Testing
import Foundation
@testable import FoodJournal

@Suite struct NutritionTargetsTests {

    private var calendar: Calendar { .current }

    /// 某自然日中午（避开业务日 04:00 分界）
    private func noon(_ offsetDays: Int, from anchor: Date) -> Date {
        let day = calendar.date(byAdding: .day, value: offsetDays, to: anchor)!
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
    }

    private func snapshot(_ burn: Double, on date: Date) -> DailyHealthSnapshot {
        DailyHealthSnapshot(date: date, activeKcal: burn, restingKcal: 0, sleepMinutes: 400, avgHR: 60)
    }

    // MARK: 公式校验

    @Test("公式校验：104kg / 2400 / 300 → 2100 / 187 / 58 / 208")
    func formulaValidation() {
        let t = makeTargets(
            latestWeightKg: 104, avgBurn7d: 2400, deficitTarget: 300,
            proteinFactor: 1.8, fatRatio: 0.25
        )
        #expect(abs((t.calories ?? 0) - 2100) < 0.5)
        #expect(abs((t.proteinG ?? 0) - 187) < 0.5)
        #expect(abs((t.fatG ?? 0) - 58) < 0.5)
        #expect(abs((t.carbsG ?? 0) - 208) < 0.5)
    }

    // MARK: 缺失处理（逐行独立）

    @Test("无体重：蛋白与碳水缺失，热量/脂肪照常（碳水公式依赖蛋白）")
    func noWeight() {
        let t = makeTargets(
            latestWeightKg: nil, avgBurn7d: 2400, deficitTarget: 300,
            proteinFactor: 1.8, fatRatio: 0.25
        )
        #expect(t.proteinG == nil)
        #expect(t.calories == 2100)
        #expect(t.fatG == 58)
        // (热量 − 蛋白×4 − 脂肪×9) ÷ 4：蛋白缺失则碳水无法折算 → nil
        #expect(t.carbsG == nil)
    }

    @Test("无快照：热量/脂肪/碳水缺失，蛋白照常")
    func noSnapshots() {
        let t = makeTargets(
            latestWeightKg: 104, avgBurn7d: nil, deficitTarget: 300,
            proteinFactor: 1.8, fatRatio: 0.25
        )
        #expect(t.calories == nil)
        #expect(t.fatG == nil)
        #expect(t.carbsG == nil)
        #expect(t.proteinG == 187)
    }

    @Test("体重与快照都缺：四项全 nil")
    func bothMissing() {
        let t = makeTargets(
            latestWeightKg: nil, avgBurn7d: nil, deficitTarget: 300,
            proteinFactor: 1.8, fatRatio: 0.25
        )
        #expect(t == NutritionTargets(calories: nil, proteinG: nil, fatG: nil, carbsG: nil))
    }

    // MARK: 参数变化

    @Test("蛋白系数 2.0 / 脂肪供能比 30% 时结果正确变化")
    func changedParams() {
        let t = makeTargets(
            latestWeightKg: 104, avgBurn7d: 2400, deficitTarget: 300,
            proteinFactor: 2.0, fatRatio: 0.30
        )
        #expect(t.calories == 2100)
        #expect(t.proteinG == 208)
        #expect(t.fatG == 70)
        // (2100 − 208×4 − 70×9) ÷ 4 = 159.5 → 160
        #expect(abs((t.carbsG ?? 0) - 160) < 0.5)
    }

    // MARK: averageBurn

    @Test("averageBurn：8 天数据只统计最近 7 个业务日，最早一天不计入")
    func averageBurnLastSevenDays() {
        let anchor = calendar.startOfDay(for: .now)
        // 第 i 天（0 = 锚点日，负数往前）消耗 1000 + i×100；i=7（最早）不计入
        let snapshots = (0...7).map { i in
            snapshot(Double(1000 + i * 100), on: noon(-i, from: anchor))
        }
        let avg = averageBurn(snapshots: snapshots, anchorDay: anchor)
        // (1000+1100+…+1600) / 7 = 1300
        #expect(abs((avg ?? 0) - 1300) < 0.001)
    }

    @Test("averageBurn：不足 7 天用实际有数据的天数")
    func averageBurnPartialDays() {
        let anchor = calendar.startOfDay(for: .now)
        let snapshots = [
            snapshot(1200, on: noon(0, from: anchor)),
            snapshot(1500, on: noon(-2, from: anchor)),
        ]
        let avg = averageBurn(snapshots: snapshots, anchorDay: anchor)
        #expect(avg == 1350)
    }

    @Test("averageBurn：无任何快照返回 nil")
    func averageBurnEmpty() {
        let anchor = calendar.startOfDay(for: .now)
        #expect(averageBurn(snapshots: [], anchorDay: anchor) == nil)
    }

    // MARK: 超额判定

    @Test("超额判定：今日 2200 vs 目标 2100 → true")
    func overTarget() {
        #expect(isOverTarget(today: 2200, target: 2100) == true)
        #expect(isOverTarget(today: 2100, target: 2100) == false)
        #expect(isOverTarget(today: 2200, target: nil) == false)
    }
}
