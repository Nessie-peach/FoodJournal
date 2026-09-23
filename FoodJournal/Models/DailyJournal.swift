import Foundation
import SwiftData

/// 每日小记：一天一篇
@Model
final class DailyJournal {
    @Attribute(.unique) var id: UUID
    var date: Date
    var text: String

    init(
        id: UUID = UUID(),
        date: Date = .now,
        text: String
    ) {
        self.id = id
        self.date = date
        self.text = text
    }
}
