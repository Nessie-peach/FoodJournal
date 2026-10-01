import Foundation

/// 「近三天」趋势表卡的组装纯函数（无副作用，便于单测）
enum TrendPreview {

    /// 单行趋势数据
    struct TrendRow: Identifiable, Equatable {
        /// 相对日期文案：今天 / 昨天 / 前天
        let label: String
        /// 业务日锚点（该业务日的日历日 00:00）
        let date: Date
        /// 当日摄入合计（kcal）；当日无餐记 0
        let intake: Double
        /// 当日消耗合计（kcal，活动+静息）；无快照为 nil
        let burn: Double?
        /// 摄入 − 消耗；消耗缺失为 nil
        let diff: Double?
        /// 是否今天行（UI 高亮用）
        let isToday: Bool

        var id: Date { date }
    }

    /// 最近三个业务日（今天/昨天/前天）的摄入-消耗-差值行，顺序固定今天在前。
    /// 餐按业务日归属（凌晨 04:00 前算前一天）；快照按自然日 key 取数
    /// （业务日锚点与快照自然日 key 一一对应，凌晨窗口下「今天」业务日的
    /// 消耗即方案 A 的前一自然日快照）。
    static func recentThreeDayTrend(
        meals: [Meal],
        snapshots: [DailyHealthSnapshot],
        now: Date,
        calendar: Calendar = .current
    ) -> [TrendRow] {
        let today = LogicalDay.businessDay(of: now, calendar: calendar)
        let intakeByDay = Dictionary(grouping: meals) {
            LogicalDay.businessDay(of: $0.date, calendar: calendar)
        }
            .mapValues { dayMeals in dayMeals.reduce(0) { $0 + $1.totalCalories } }
        let burnByDay = Dictionary(grouping: snapshots) { calendar.startOfDay(for: $0.date) }
            .mapValues { daySnapshots in
                daySnapshots.reduce(0) { $0 + $1.activeKcal + $1.restingKcal }
            }
        let labels = ["今天", "昨天", "前天"]
        return (0..<3).map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let intake = intakeByDay[day] ?? 0
            let burn = burnByDay[day]
            return TrendRow(
                label: labels[offset],
                date: day,
                intake: intake,
                burn: burn,
                diff: burn.map { intake - $0 },
                isToday: offset == 0
            )
        }
    }

    /// 三天全部没有消耗数据 → 卡片底部提示「消耗数据待同步」
    static func showsBurnPendingNotice(_ rows: [TrendRow]) -> Bool {
        rows.allSatisfy { $0.burn == nil }
    }
}
