import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
            StatsView()
                .tabItem { Label("统计", systemImage: "chart.bar.fill") }
            JournalView()
                .tabItem { Label("小记", systemImage: "book.fill") }
            WeightView()
                .tabItem { Label("体重", systemImage: "scalemass.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}

#Preview {
    ContentView()
}
