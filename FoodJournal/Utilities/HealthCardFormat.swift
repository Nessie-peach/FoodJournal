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

    /// HRV 度量口径来源 → 展示标注：apple-sdnn →「SDNN」，garmin-hrv →「佳明」，未知 → nil
    static func hrvSourceLabel(_ source: String?) -> String? {
        switch source {
        case HRVSource.appleSDNN.rawValue: return "SDNN"
        case HRVSource.garmin.rawValue: return "佳明"
        default: return nil
        }
    }

    /// HRV 值 + 口径标注文案：「42 ms（SDNN）」/「42 ms（佳明）」；来源未知只显示「42 ms」；
    /// 无值返回 nil（卡片走空态）
    static func hrvDisplayText(ms: Double?, source: String?) -> String? {
        guard let ms else { return nil }
        let base = "\(Int(ms.rounded())) ms"
        guard let label = hrvSourceLabel(source) else { return base }
        return "\(base)（\(label)）"
    }

    /// 时刻 →「HH:mm」（固定 locale，24 小时制，结果稳定）
    static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}
