import Foundation

/// 业务日（逻辑日）口径：全 App 唯一的「某日」时间边界来源。
///
/// 定义：**业务日 D** = 自然日 D 的 04:00 至 D+1 的 03:59（半开区间 [D 04:00, D+1 04:00)）。
/// 用户常在凌晨进食，因此 00:00–04:00 的记录/小记/建议归属**前一个业务日**：
/// - 10/1 00:30 吃的一餐 → 归属 9/30 业务日
/// - 04:00 之后「今天」切换到新业务日
///
/// 口径约定：
/// - 饮食记录、小记、AI 建议：按业务日归属（`businessDay` / `businessDayRange`）
/// - 健康快照（DailyHealthSnapshot）：Garmin/HealthKit 按自然日聚合，无法按 04:00 切分，
///   因此快照仍以自然日为 key 存取；业务日与快照的换算用 `burnSnapshotDay`（方案 A：
///   凌晨窗口取前一自然日消耗，卡片注明「消耗截至 24:00」）
/// - 全部经由 `Calendar.current` 计算，跟随用户时区与夏令时
enum LogicalDay {
    /// 业务日分界小时：每天 04:00 切换到新业务日
    static let boundaryHour = 4

    /// 该时刻所属业务日的**日历日锚点**（当天 00:00）。
    /// 04:00 之前 → 前一自然日锚点；04:00 起 → 当天锚点。
    /// 分组、显示日期均使用此锚点。
    static func businessDay(of date: Date, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        guard hour < boundaryHour else { return dayStart }
        return calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
    }

    /// 业务日半开区间 [start, end)：start = 锚点日 04:00，end = 次日 04:00（不含）。
    static func businessDayRange(
        of date: Date, calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let anchor = businessDay(of: date, calendar: calendar)
        let start = calendar.date(
            byAdding: .hour, value: boundaryHour, to: calendar.startOfDay(for: anchor)
        ) ?? calendar.startOfDay(for: anchor)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return (start, end)
    }

    /// 当前是否处于凌晨窗口（自然日 00:00–04:00，即业务日尚未切换）。
    static func isInLateNightWindow(now: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: now) < boundaryHour
    }

    /// 前一自然日的 00:00 锚点（凌晨消耗口径用）。
    static func previousCalendarDay(of date: Date, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
    }

    /// 缺口卡「今日消耗」应取哪个自然日的快照（方案 A，纯函数便于单测）：
    /// 凌晨窗口（00:00–04:00）取**前一自然日**（消耗数据截至 24:00，与当前显示的
    /// 业务日饮食归属一致）；04:00 之后取当日。
    /// 返回值为自然日 00:00 锚点（快照按此 key 存取）。
    static func burnSnapshotDay(for date: Date, calendar: Calendar = .current) -> Date {
        guard isInLateNightWindow(now: date, calendar: calendar) else {
            return calendar.startOfDay(for: date)
        }
        return previousCalendarDay(of: date, calendar: calendar)
    }
}
