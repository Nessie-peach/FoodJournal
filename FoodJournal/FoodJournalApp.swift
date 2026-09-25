import SwiftUI
import SwiftData

@main
struct FoodJournalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    /// 首次启动（scenePhase 首次 active）时弹一次 HealthKit 授权请求
    @AppStorage(HealthKitService.authRequestedStorageKey) private var hasRequestedHealthAuth = false

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

    /// 变为 active 时后台同步最近 7 天健康数据（fire-and-forget，不阻塞启动）
    private func handleSceneActive() {
        let context = modelContext
        let wasRequested = hasRequestedHealthAuth
        Task { @MainActor in
            let service = HealthKitService()
            if !wasRequested {
                // 首次启动：弹一次授权请求；无论结果如何只弹这一次
                hasRequestedHealthAuth = true
                try? await service.requestAuthorization()
            }
            await service.syncRecent(days: 7, context: context)
        }
    }
}
