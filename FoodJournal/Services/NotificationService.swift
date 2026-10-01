import Foundation
import UserNotifications

/// 每日 23:30 小记提醒：权限申请、定时通知构造与调度。
/// 权限被拒时静默失败（不弹窗、不报错），提示引导由小记页 UI 负责。
enum NotificationService {
    /// 定时通知固定标识（重复调度时覆盖同一条）
    static let reminderIdentifier = "daily-journal-reminder"
    static let reminderTitle = "今天吃什么"
    static let reminderBody = "今天过得怎么样？花一分钟记下今天，AI 会给你一份专属于今天的健康建议"

    /// 构造每日 23:30 提醒请求（纯函数，可单测验证时间 / repeats / identifier）
    static func makeDailyReminderRequest() -> UNNotificationRequest {
        var components = DateComponents()
        components.hour = 23
        components.minute = 30
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let content = UNMutableNotificationContent()
        content.title = reminderTitle
        content.body = reminderBody
        content.sound = .default
        return UNNotificationRequest(identifier: reminderIdentifier, content: content, trigger: trigger)
    }

    /// 查询当前授权状态
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 未决定时请求授权（已授权/已拒绝则不重复弹窗），返回是否获得授权
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        )) ?? false
    }

    /// 调度每日 23:30 提醒；仅在已获授权时调度（幂等）。
    /// 未决定不主动弹窗（由小记页「开启」按钮负责申请），被拒静默返回，绝不打扰。
    static func scheduleDailyReminder() async {
        let status = await authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            try? await UNUserNotificationCenter.current().add(makeDailyReminderRequest())
        default:
            return
        }
    }
}

// MARK: - 通知路由（跨页共享状态）

/// 通知点击 → 页面跳转的桥接：@Observable 共享状态，ContentView / JournalView 各自监听。
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    /// 通知点击后置 true；ContentView 据此切到小记 tab，JournalView 消费后自动生成建议并清除
    var pendingJournalGeneration = false
    /// 次日补生成成功后的提示文案（小记页顶部横幅），nil 表示无需展示
    var catchupMessage: String?
}

// MARK: - 通知委托

/// 前台展示 + 点击响应：点击 23:30 提醒 → 置待生成标记（切 tab + 自动生成建议）。
/// 无可变状态（仅桥接 MainActor 共享路由），可安全跨并发域共享。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == NotificationService.reminderIdentifier else { return }
        await MainActor.run {
            NotificationRouter.shared.pendingJournalGeneration = true
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
