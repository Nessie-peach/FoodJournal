import Foundation
import SwiftData

/// 每日 AI 建议
@Model
final class DailyAdvice {
    /// 建议来源渠道
    enum Channel {
        /// 迈开腿页（数据驱动，无需小记文本）
        static let exercise = "exercise"
        /// 小记页（默认，兼容旧数据）
        static let journal = "journal"
    }

    @Attribute(.unique) var id: UUID
    var date: Date
    /// 建议正文
    var content: String
    /// 生成时间
    var generatedAt: Date
    /// 生成模型标识（如 glm-4.7）
    var modelTag: String
    /// 建议渠道（"exercise"=迈开腿 / "journal"=小记；旧数据轻量迁移默认 journal）
    var channel: String = Channel.journal

    init(
        id: UUID = UUID(),
        date: Date = .now,
        content: String,
        generatedAt: Date = .now,
        modelTag: String,
        channel: String = Channel.journal
    ) {
        self.id = id
        self.date = date
        self.content = content
        self.generatedAt = generatedAt
        self.modelTag = modelTag
        self.channel = channel
    }
}
