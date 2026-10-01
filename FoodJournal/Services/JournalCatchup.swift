import Foundation
import SwiftData

/// 次日小记建议补生成：App 启动 / scenePhase 变 active 时静默检查。
/// 判定为纯函数（可单测）；补生成失败仅日志，不打扰用户。
enum JournalCatchup {
    /// 补生成判定：昨天无 journal 建议 且（昨天有小记 或 昨天有餐记录）→ 补
    nonisolated static func shouldGenerate(
        yesterdayAdviceExists: Bool,
        yesterdayJournalExists: Bool,
        yesterdayMealCount: Int
    ) -> Bool {
        !yesterdayAdviceExists && (yesterdayJournalExists || yesterdayMealCount > 0)
    }

    /// 当天已尝试过则跳过（scenePhase 可能一天内多次 active）
    @MainActor
    private static var lastAttemptDay: Date?

    @MainActor
    static func runIfNeeded(context: ModelContext) async {
        let calendar = Calendar.current
        // 业务日口径：今天 = 当前业务日锚点；「昨天」= 前一业务日（凌晨 04:00 前
        // 当前业务日仍是昨天，此时「昨天」= 前天）
        let today = LogicalDay.businessDay(of: .now, calendar: calendar)
        if lastAttemptDay == today { return }
        lastAttemptDay = today

        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return }
        do {
            let adviceRepository = AdviceRepository(context: context)
            let hasAdvice = try adviceRepository.advice(for: yesterday, channel: DailyAdvice.Channel.journal) != nil
            let journal = try JournalRepository(context: context).journal(for: yesterday)
            let mealCount = try mealCount(on: yesterday, in: context)
            guard shouldGenerate(
                yesterdayAdviceExists: hasAdvice,
                yesterdayJournalExists: journal != nil,
                yesterdayMealCount: mealCount
            ) else { return }

            let configJSON = UserDefaults.standard.string(forKey: LLMProviderConfig.adviceStorageKey)
            let config = configJSON.flatMap(LLMProviderConfig.init(json:)) ?? .default
            guard config.isEndpointConfigured, config.isModelConfigured,
                  let apiKey = KeychainStore.advice.load() else { return }

            let content = try await AdviceService().generateAdvice(
                date: yesterday,
                context: context,
                config: config,
                apiKey: apiKey,
                channel: DailyAdvice.Channel.journal,
                journalText: journal?.text
            )
            _ = try adviceRepository.upsert(
                date: yesterday,
                channel: DailyAdvice.Channel.journal,
                content: content,
                modelTag: config.modelID
            )
            NotificationRouter.shared.catchupMessage = "已补生成昨日建议"
        } catch {
            print("[JournalCatchup] 补生成失败（静默忽略）: \(error)")
        }
    }

    /// 某业务日的餐记录数（仅用于判定「有无数据」，count 1 条即止）
    private static func mealCount(on date: Date, in context: ModelContext) throws -> Int {
        let calendar = Calendar.current
        // date 为业务日锚点：按业务日区间 04:00 → 次日 04:00 计数
        let range = LogicalDay.businessDayRange(of: date, calendar: calendar)
        let start = range.start
        let end = range.end
        let startCopy = start
        let endCopy = end
        let predicate = #Predicate<Meal> { meal in
            meal.date >= startCopy && meal.date < endCopy
        }
        var descriptor = FetchDescriptor<Meal>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetchCount(descriptor)
    }
}
