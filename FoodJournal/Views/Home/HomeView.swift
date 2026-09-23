import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            Text("首页")
                .navigationTitle("今天吃什么")
        }
    }
}

#Preview {
    HomeView()
}
