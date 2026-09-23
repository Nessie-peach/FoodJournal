import Foundation
import SwiftData

/// 每日 AI 建议
@Model
final class DailyAdvice {
    @Attribute(.unique) var id: UUID
    var date: Date
    /// 建议正文
    var content: String
    /// 生成时间
    var generatedAt: Date
    /// 生成模型标识（如 glm-4.7）
    var modelTag: String

    init(
        id: UUID = UUID(),
        date: Date = .now,
        content: String,
        generatedAt: Date = .now,
        modelTag: String
    ) {
        self.id = id
        self.date = date
        self.content = content
        self.generatedAt = generatedAt
        self.modelTag = modelTag
    }
}
