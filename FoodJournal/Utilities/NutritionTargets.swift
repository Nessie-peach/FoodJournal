import Foundation

/// 「我的-目标」营养素参数的 @AppStorage key 与默认值
enum NutritionTargetSettings {
    /// 蛋白系数（g/kg）key
    static let proteinFactorKey = "dailyProteinFactorPerKg"
    /// 蛋白系数默认值
    static let defaultProteinFactor: Double = 1.8
    /// 脂肪供能比（0-1）key
    static let fatRatioKey = "dailyFatEnergyRatio"
    /// 脂肪供能比默认值
    static let defaultFatRatio: Double = 0.25
}

/// 今日汇总卡的每日营养素目标（各项独立可缺：nil = 依据缺失，显示「—」）
struct NutritionTargets: Equatable {
    let calories: Double?
    let proteinG: Double?
    let fatG: Double?
    let carbsG: Double?
}

/// 每日三大营养素目标（纯函数）：
/// - 热量目标 = 近 7 个业务日平均总消耗（activeKcal + restingKcal）− 缺口目标
/// - 蛋白目标 = 最新体重(kg) × 蛋白系数
/// - 脂肪目标 = 热量目标 × 脂肪供能比 ÷ 9
/// - 碳水目标 = (热量目标 − 蛋白×4 − 脂肪×9) ÷ 4
/// 各项逐行独立：体重缺失只影响蛋白；快照缺失只影响热量/脂肪/碳水。
/// 结果取整数（校验口径：104 kg / 2400 / 300 → 2100 / 187 / 58 / 208）。
func makeTargets(
    latestWeightKg: Double?, avgBurn7d: Double?, deficitTarget: Double,
    proteinFactor: Double, fatRatio: Double
) -> NutritionTargets {
    let calories = avgBurn7d.map { ($0 - deficitTarget).rounded() }
    let protein = latestWeightKg.map { ($0 * proteinFactor).rounded() }
    let fat = calories.map { ($0 * fatRatio / 9).rounded() }
    let carbs: Double?
    if let calories, let protein, let fat {
        carbs = ((calories - protein * 4 - fat * 9) / 4).rounded()
    } else {
        carbs = nil
    }
    return NutritionTargets(calories: calories, proteinG: protein, fatG: fat, carbsG: carbs)
}

/// 近 7 个业务日（含 anchorDay 所在业务日）的日均总消耗（activeKcal + restingKcal）。
/// 快照按自然日 key 与业务日锚点匹配；无任何数据返回 nil；不足 7 天用实际有数据的天数。
/// 注意：入参为业务日锚点（LogicalDay.businessDay(of:) 的返回值），
/// 勿把含时刻的锚点再喂给分界函数（会二次前移一天）。
func averageBurn(
    snapshots: [DailyHealthSnapshot], anchorDay: Date, calendar: Calendar = .current
) -> Double? {
    let anchors = (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: anchorDay) }
    let burns: [Double] = anchors.compactMap { anchor in
        snapshots
            .first { calendar.isDate($0.date, inSameDayAs: anchor) }
            .map { $0.activeKcal + $0.restingKcal }
    }
    return burns.isEmpty ? nil : burns.reduce(0, +) / Double(burns.count)
}

/// 超额判定：今日值 > 目标值 → true；目标缺失 → false（不标红）
func isOverTarget(today: Double, target: Double?) -> Bool {
    guard let target else { return false }
    return today > target
}
