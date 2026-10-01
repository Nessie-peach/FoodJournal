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

    /// 显式创建容器：SyncCoordinator 后台同步（BGTask 场景拿不到环境 modelContext）需要复用同一容器
    private let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: Meal.self, FoodItem.self, WeightRecord.self,
                DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self
            )
        } catch {
            fatalError("无法创建数据容器：\(error)")
        }
    }()

    init() {
        // BGTaskScheduler.register 须在 App 完成启动前调用：注册后台刷新 handler 并提交第一次请求
        SyncCoordinator.shared.configure(container: modelContainer)
        BackgroundRefreshScheduler.shared.registerHandlerAndSchedule()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    handleSceneActive()
                }
        }
    }

    /// 变为 active 时经 SyncCoordinator 触发前台同步（15 分钟防抖；HealthKit 未授权时先弹授权；
    /// Garmin 未登录自动跳过），同时确保 23:30 提醒已调度（幂等）、执行次日建议补生成检查。
    private func handleSceneActive() {
        Task { @MainActor in
            await SyncCoordinator.shared.sync(trigger: .foreground)
        }
        Task {
            await NotificationService.scheduleDailyReminder()
        }
        Task { @MainActor in
            await JournalCatchup.runIfNeeded(context: modelContext)
        }
    }
}
