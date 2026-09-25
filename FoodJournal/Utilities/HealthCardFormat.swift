import Foundation

/// 迈开腿健康卡片的纯格式化函数（无副作用，便于单测）
enum HealthCardFormat {
    /// 睡眠分钟数 →「x 小时 y 分」；不足 1 小时只显示分，整小时不带分
    static func sleepText(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let hours = total / 60
        let mins = total % 60
        switch (hours > 0, mins > 0) {
        case (true, true): return "\(hours) 小时 \(mins) 分"
        case (true, false): return "\(hours) 小时"
        default: return "\(mins) 分"
        }
    }

    /// 心率均值 → 整数次/分；0 视为无数据
    static func heartText(bpm: Double) -> String {
        bpm > 0 ? String(Int(bpm.rounded())) : "—"
    }

    /// HRV 均值 → 整数毫秒；nil 视为无数据（卡片显示空态文案）
    static func hrvText(ms: Double?) -> String? {
        ms.map { String(Int($0.rounded())) }
    }

    /// 时刻 →「HH:mm」（固定 locale，24 小时制，结果稳定）
    static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}
