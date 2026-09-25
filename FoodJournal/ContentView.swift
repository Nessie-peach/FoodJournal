import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("今日", systemImage: "house.fill") }
            JournalView()
                .tabItem { Label("小记", systemImage: "pencil.and.list.clipboard") }
            StatsView()
                .tabItem { Label("统计", systemImage: "chart.bar.fill") }
            SettingsView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
    }
}

#Preview {
    ContentView()
}
