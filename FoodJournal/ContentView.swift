import SwiftUI

/// App 顶部 Tab
enum AppTab: Hashable {
    case home
    case journal
    case stats
    case settings
}

struct ContentView: View {
    // selectedTab 提升于此：备份提醒横幅（今日页）点击可跳转「我的」
    @State private var selectedTab: AppTab = .home
    /// 通知点击路由：点击 23:30 提醒直达小记 tab
    @State private var router = NotificationRouter.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label("今日", systemImage: "house.fill") }
                .tag(AppTab.home)
            JournalView(selectedTab: $selectedTab)
                .tabItem { Label("小记", systemImage: "pencil.and.list.clipboard") }
                .tag(AppTab.journal)
            StatsView()
                .tabItem { Label("统计", systemImage: "chart.bar.fill") }
                .tag(AppTab.stats)
            SettingsView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(AppTab.settings)
        }
        .onChange(of: router.pendingJournalGeneration) { _, pending in
            if pending { selectedTab = .journal }
        }
    }
}

#Preview {
    ContentView()
}
