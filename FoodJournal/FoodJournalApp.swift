import SwiftUI
import SwiftData

@main
struct FoodJournalApp: App {
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
        }
    }
}
