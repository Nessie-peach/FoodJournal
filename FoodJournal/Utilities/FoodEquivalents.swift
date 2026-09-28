import Foundation

/// 热量缺口卡的本地规则：内置食物当量表 + 纯计算逻辑（无副作用，便于单测）
enum FoodEquivalents {
    struct FoodEquivalent: Equatable {
        let name: String
        let kcal: Double
    }

    /// 内置当量表（kcal）
    static let table: [FoodEquivalent] = [
        .init(name: "汉堡", kcal: 550),
        .init(name: "中杯奶茶", kcal: 400),
        .init(name: "鸡腿", kcal: 250),
        .init(name: "一碗米饭", kcal: 230),
        .init(name: "苹果", kcal: 95),
    ]

    /// 最小当量热量；剩余额度不足它时不显示当量行
    static var minKcal: Double { table.map(\.kcal).min() ?? 0 }

    /// 在 kcal 额度内找能对应的最大当量项；不足最小项返回 nil（不显示当量行）
    static func equivalent(forKcal kcal: Double) -> FoodEquivalent? {
        table
            .filter { $0.kcal <= kcal }
            .max { $0.kcal < $1.kcal }
    }
}

/// 热量缺口口径（纯函数）：
/// - 缺口 = 总消耗（活动 + 静息）− 已摄入
/// - 剩余可吃额度 = 总消耗 − 目标缺口 − 已摄入（即缺口超出目标的部分）
/// - 达标 = 缺口 ≥ 目标
enum CalorieGap {
    /// 「每日热量缺口目标」的 @AppStorage key（千卡）
    static let goalStorageKey = "dailyCalorieGapGoalKcal"
    /// 缺口目标默认值（千卡）
    static let defaultGoalKcal: Double = 300

    /// 距目标文案分支
    enum GoalStatus: Equatable {
        /// 「还差 x 千卡达标」
        case belowGoal(remaining: Double)
        /// 「已超出目标 x 千卡」（达标，显示语义绿）
        case aboveGoal(excess: Double)
    }

    /// 当量提示行分支
    enum EquivalentHint: Equatable {
        /// 「已多留出约{name}的缺口」（超出部分 ≥ 最小当量）
        case surplus(name: String)
        /// 「已达今日缺口目标，再吃将增加盈余」（达标但超出不足最小当量）
        case goalReached
        /// 不显示当量行（未达标，或剩余额度不足最小当量）
        case hidden
    }

    struct Result: Equatable {
        let goalStatus: GoalStatus
        let hint: EquivalentHint
    }

    /// - Parameter totalBurnedKcal: 当日总消耗（活动+静息）；nil = 未同步/无数据 → 待同步空态
    static func evaluate(
        totalBurnedKcal: Double?, consumedKcal: Double, goalKcal: Double
    ) -> Result? {
        guard let burned = totalBurnedKcal else { return nil }
        let gap = burned - consumedKcal
        let allowance = gap - goalKcal
        let goalStatus: GoalStatus = gap < goalKcal
            ? .belowGoal(remaining: goalKcal - gap)
            : .aboveGoal(excess: allowance)
        let hint: EquivalentHint
        if gap < goalKcal {
            // 未达标：额度已用尽（吃更多只会缩小缺口），当量行不显示
            hint = .hidden
        } else if let eq = FoodEquivalents.equivalent(forKcal: allowance) {
            hint = .surplus(name: eq.name)
        } else {
            // 达标但超出不足一个最小当量
            hint = .goalReached
        }
        return Result(goalStatus: goalStatus, hint: hint)
    }
}
