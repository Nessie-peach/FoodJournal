import SwiftUI
import SwiftData
import UserNotifications

/// App 入口：设置通知委托（点击 23:30 提醒直达小记并自动生成建议）
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }
}

@main
struct FoodJournalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: [
                    Meal.self,
                    FoodItem.self,
                    WeightRecord.self,
                    DailyJournal.self,
                    DailyAdvice.self,
                    DailyHealthSnapshot.self,
                ])
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    handleSceneActive()
                }
        }
    }

    /// 变为 active 时后台同步最近 7 天健康数据（fire-and-forget，不阻塞启动）。
    /// HealthKit 不告知读取授权结果，故先探测请求状态；仅在尚未请求时弹一次授权，
    /// 随后同步——是否真能读到数据由查询结果决定。
    /// 同时：确保 23:30 提醒已调度（幂等，权限被拒静默返回）；执行次日建议补生成检查。
    private func handleSceneActive() {
        let context = modelContext
        Task { @MainActor in
            let service = HealthKitService()
            let state = await service.authorizationState()
            if state == .notDetermined {
                try? await service.requestAuthorization()
            }
            await service.syncRecent(days: 7, context: context)
        }
        Task {
            await NotificationService.scheduleDailyReminder()
        }
        Task { @MainActor in
            await JournalCatchup.runIfNeeded(context: context)
        }
    }
}
