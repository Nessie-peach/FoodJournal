import XCTest
import SwiftData
import UserNotifications
@testable import FoodJournal

/// M4：小记 + AI 建议（journal 渠道）+ 23:30 通知
final class JournalM4Tests: XCTestCase {
    @MainActor
    func makeContext() throws -> ModelContext {
        let container = try TestSupport.makeContainer()
        return ModelContext(container)
    }

    @MainActor
    func insertMeal(_ context: ModelContext, date: Date = .now) throws {
        let meal = Meal(mealType: .breakfast, name: "燕麦粥")
        meal.items = [FoodItem(name: "燕麦粥", calories: 300, protein: 10, carbs: 50, fat: 5)]
        meal.date = date
        context.insert(meal)
        try context.save()
    }

    // MARK: - 小记 upsert（一天一篇）

    /// 同一天二次保存：更新而非新增
    @MainActor
    func testJournalUpsertSameDayUpdates() throws {
        let context = try makeContext()
        let repository = JournalRepository(context: context)
        let date = TestSupport.date(hour: 9)

        let first = try repository.save(text: "今天跑了五公里", for: date)
        let second = try repository.save(text: "补一句：心情不错", for: date)

        XCTAssertEqual(second.id, first.id)
        let all = try context.fetch(FetchDescriptor<DailyJournal>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.text, "补一句：心情不错")

        let loaded = try repository.journal(for: date)
        XCTAssertEqual(loaded?.text, "补一句：心情不错")
    }

    /// 不同日期各存一篇，互不影响
    @MainActor
    func testJournalSeparateDaysKeepsBoth() throws {
        let context = try makeContext()
        let repository = JournalRepository(context: context)
        let today = TestSupport.date(hour: 9)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))

        _ = try repository.save(text: "今天的日记", for: today)
        _ = try repository.save(text: "昨天的日记", for: yesterday)

        XCTAssertEqual(try repository.journal(for: today)?.text, "今天的日记")
        XCTAssertEqual(try repository.journal(for: yesterday)?.text, "昨天的日记")
    }

    // MARK: - 次日补生成判定（纯函数）

    @MainActor
    func testCatchupYesterdayHasAdviceSkips() {
        XCTAssertFalse(JournalCatchup.shouldGenerate(
            yesterdayAdviceExists: true, yesterdayJournalExists: true, yesterdayMealCount: 2
        ))
    }

    @MainActor
    func testCatchupNoAdviceNoDataSkips() {
        XCTAssertFalse(JournalCatchup.shouldGenerate(
            yesterdayAdviceExists: false, yesterdayJournalExists: false, yesterdayMealCount: 0
        ))
    }

    @MainActor
    func testCatchupNoAdviceWithJournalGenerates() {
        XCTAssertTrue(JournalCatchup.shouldGenerate(
            yesterdayAdviceExists: false, yesterdayJournalExists: true, yesterdayMealCount: 0
        ))
    }

    @MainActor
    func testCatchupNoAdviceWithMealsGenerates() {
        XCTAssertTrue(JournalCatchup.shouldGenerate(
            yesterdayAdviceExists: false, yesterdayJournalExists: false, yesterdayMealCount: 1
        ))
    }

    // MARK: - journal 渠道数据打包（含小记）

    /// journal 渠道：打包包含当日小记全文
    @MainActor
    func testPackContextTextJournalIncludesText() {
        let text = AdviceService.packContextText(
            snapshot: nil, meals: [], weights: [],
            includesJournalSection: true,
            journalText: "今天跑了五公里，心情不错"
        )
        XCTAssertTrue(text.contains("【今日小记】"))
        XCTAssertTrue(text.contains("今天跑了五公里，心情不错"))
    }

    /// journal 渠道：无小记标「无数据」，不编造
    @MainActor
    func testPackContextTextJournalMissingMarksNoData() {
        let text = AdviceService.packContextText(
            snapshot: nil, meals: [], weights: [],
            includesJournalSection: true, journalText: nil
        )
        XCTAssertTrue(text.contains("【今日小记】无数据"))
    }

    /// 小记只有空白字符：同样标「无数据」
    @MainActor
    func testPackContextTextJournalBlankMarksNoData() {
        let text = AdviceService.packContextText(
            snapshot: nil, meals: [], weights: [],
            includesJournalSection: true, journalText: "   \n  "
        )
        XCTAssertTrue(text.contains("【今日小记】无数据"))
    }

    /// exercise 渠道路径（generateAdvice 默认）：打包不含小记段
    @MainActor
    func testPackContextTextWithoutJournalOmitsSection() {
        let text = AdviceService.packContextText(snapshot: nil, meals: [], weights: [])
        XCTAssertFalse(text.contains("【今日小记】"))
    }

    // MARK: - 23:30 通知请求构造

    func testDailyReminderRequestConstruction() throws {
        let request = NotificationService.makeDailyReminderRequest()

        XCTAssertEqual(request.identifier, "daily-journal-reminder")
        XCTAssertTrue(request.content.body.contains("记下今天"))
        XCTAssertTrue(request.content.body.contains("健康建议"))
        XCTAssertFalse(request.content.body.isEmpty)

        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 23)
        XCTAssertEqual(trigger.dateComponents.minute, 30)
    }

    // MARK: - 补生成链路（仓库层，不发网络请求）

    /// 昨天有小记、昨天无 journal 建议 → 判定为补；补生成前置（ yesterday 建议/小记/餐数）读取正确
    @MainActor
    func testCatchupPrerequisitesReadFromRepositories() throws {
        let context = try makeContext()
        let today = TestSupport.date(hour: 10)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))

        _ = try JournalRepository(context: context).save(text: "昨天写了小记", for: yesterday)
        try insertMeal(context, date: yesterday)

        let adviceRepository = AdviceRepository(context: context)
        let journalRepository = JournalRepository(context: context)
        let hasAdvice = try adviceRepository.advice(for: yesterday, channel: DailyAdvice.Channel.journal) != nil
        let hasJournal = try journalRepository.journal(for: yesterday) != nil

        XCTAssertFalse(hasAdvice)
        XCTAssertTrue(hasJournal)
        XCTAssertTrue(JournalCatchup.shouldGenerate(
            yesterdayAdviceExists: hasAdvice,
            yesterdayJournalExists: hasJournal,
            yesterdayMealCount: 1
        ))
    }
}
