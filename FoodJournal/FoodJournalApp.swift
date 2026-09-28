import SwiftUI
import SwiftData

@main
struct FoodJournalApp: App {
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
    }
}
