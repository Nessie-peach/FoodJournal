import Foundation
import SwiftData

/// 体重记录
@Model
final class WeightRecord {
    @Attribute(.unique) var id: UUID
    var date: Date
    /// 体重（kg）
    var weightKg: Double

    init(
        id: UUID = UUID(),
        date: Date = .now,
        weightKg: Double
    ) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
    }
}
