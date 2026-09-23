import Foundation
import SwiftData

/// 餐次：早餐 / 午餐 / 晚餐 / 加餐
enum MealType: String, CaseIterable, Identifiable, Codable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack

    var id: String { rawValue }

    /// 中文显示名
    var displayName: String {
        switch self {
        case .breakfast: return "早餐"
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        case .snack: return "加餐"
        }
    }

    /// 图标名（供 UI 使用）
    var systemImageName: String {
        switch self {
        case .breakfast: return "sun.horizon.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.stars.fill"
        case .snack: return "cup.and.saucer.fill"
        }
    }

    /// 按时间推断餐次：
    /// 5:00–10:29 早餐；10:30–15:29 午餐；15:30–18:29 加餐；18:30–4:59 晚餐（含夜宵并入晚餐桶）
    static func from(date: Date) -> MealType {
        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)
        let totalMinutes = hour * 60 + minute

        switch totalMinutes {
        case 5 * 60 ..< (10 * 60 + 30):
            return .breakfast
        case (10 * 60 + 30) ..< (15 * 60 + 30):
            return .lunch
        case (15 * 60 + 30) ..< (18 * 60 + 30):
            return .snack
        default:
            // 18:30–23:59 与 0:00–4:59 均归入晚餐（夜宵并入）
            return .dinner
        }
    }
}
