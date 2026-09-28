import XCTest
import SwiftData
@testable import FoodJournal

/// R5-4：AI 健康建议服务测试（数据打包 + DailyAdvice channel upsert）
final class AdviceServiceTests: XCTestCase {
    @MainActor
    func makeContext() throws -> ModelContext {
        let container = try TestSupport.makeContainer()
        return ModelContext(container)
    }

    @MainActor
    func insertMeal(
        _ context: ModelContext,
        name: String,
        type: MealType,
        calories: Double,
        protein: Double = 0,
        carbs: Double = 0,
        fat: Double = 0
    ) throws {
        let meal = Meal(mealType: type, name: name)
        meal.items = [FoodItem(name: name, calories: calories, protein: protein, carbs: carbs, fat: fat)]
        context.insert(meal)
        try context.save()
    }

    // MARK: - 打包文本

    /// 有快照 + 有饮食 + 有体重：关键数值齐全，不 crash
    @MainActor
    func testPackContextTextWithFullData() throws {
        let context = try makeContext()
        let workouts = [WorkoutRecord(
            uuid: UUID().uuidString,
            activityType: "running",
            durationMinutes: 30,
            energyKcal: 250,
            startDate: TestSupport.date(hour: 8)
        )]
        let workoutsJSON = String(data: try JSONEncoder().encode(workouts), encoding: .utf8)
        let snapshot = DailyHealthSnapshot(
            date: .now,
            activeKcal: 320,
            restingKcal: 1500,
            sleepMinutes: 450,
            sleepStart: TestSupport.date(hour: 23, minute: 10),
            sleepEnd: TestSupport.date(hour: 7),
            avgHR: 62,
            hrvMS: 45,
            workoutsJSON: workoutsJSON
        )
        context.insert(snapshot)
        try insertMeal(context, name: "燕麦粥", type: .breakfast, calories: 300, protein: 10, carbs: 50, fat: 5)

        let weight = WeightRecord(date: TestSupport.date(hour: 7), weightKg: 70.5)
        context.insert(weight)

        let text = AdviceService.packContextText(
            snapshot: snapshot,
            meals: try context.fetch(FetchDescriptor<Meal>()),
            weights: [weight]
        )

        XCTAssertTrue(text.contains("活动消耗：320 千卡"))
        XCTAssertTrue(text.contains("静息消耗：1500 千卡"))
        XCTAssertTrue(text.contains("7 小时 30 分"))
        XCTAssertTrue(text.contains("跑步 30 分钟"))
        XCTAssertTrue(text.contains("燕麦粥"))
        XCTAssertTrue(text.contains("热量 300 千卡"))
        XCTAssertTrue(text.contains("70.5 千克"))
        XCTAssertFalse(text.contains("无数据"))
    }

    /// 无快照：健康数据整段标注无数据，不 crash
    @MainActor
    func testPackContextTextWithoutSnapshot() throws {
        let text = AdviceService.packContextText(snapshot: nil, meals: [], weights: [])
        XCTAssertTrue(text.contains("【当日健康数据】无数据"))
        XCTAssertTrue(text.contains("无饮食记录"))
        XCTAssertTrue(text.contains("无体重数据"))
    }

    /// 有快照但睡眠/HRV/运动缺失：逐项标注无数据
    @MainActor
    func testPackContextTextWithPartialSnapshot() throws {
        let snapshot = DailyHealthSnapshot(
            date: .now,
            activeKcal: 100,
            sleepMinutes: 0,
            avgHR: 0,
            hrvMS: nil,
            workoutsJSON: nil
        )
        let text = AdviceService.packContextText(snapshot: snapshot, meals: [], weights: [])
        XCTAssertTrue(text.contains("睡眠：无数据"))
        XCTAssertTrue(text.contains("平均心率：无数据"))
        XCTAssertTrue(text.contains("HRV：无数据"))
        XCTAssertTrue(text.contains("运动记录：无数据"))
        XCTAssertTrue(text.contains("无饮食记录"))
    }

    /// 无体重记录：体重段标注无数据，不 crash
    @MainActor
    func testPackContextTextWithoutWeights() throws {
        let snapshot = DailyHealthSnapshot(date: .now, activeKcal: 100, sleepMinutes: 400, avgHR: 60)
        let text = AdviceService.packContextText(snapshot: snapshot, meals: [], weights: [])
        XCTAssertTrue(text.contains("【近 7 日体重】无体重数据"))
    }

    // MARK: - DailyAdvice channel upsert

    /// 同日同 channel upsert：覆盖为一条，正文与时间更新
    @MainActor
    func testUpsertSameDaySameChannelUpdates() throws {
        let context = try makeContext()
        let repository = AdviceRepository(context: context)
        let date = TestSupport.date(hour: 9)

        let first = try repository.upsert(date: date, channel: DailyAdvice.Channel.exercise, content: "第一版", modelTag: "m1")
        let second = try repository.upsert(date: date, channel: DailyAdvice.Channel.exercise, content: "第二版", modelTag: "m2")

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.content, "第二版")
        XCTAssertEqual(second.modelTag, "m2")

        let all = try context.fetch(FetchDescriptor<DailyAdvice>())
        XCTAssertEqual(all.count, 1)

        let loaded = try repository.advice(for: date, channel: DailyAdvice.Channel.exercise)
        XCTAssertEqual(loaded?.content, "第二版")
    }

    /// 同日不同 channel：各存一条，互不影响
    @MainActor
    func testUpsertDifferentChannelsKeepsBoth() throws {
        let context = try makeContext()
        let repository = AdviceRepository(context: context)
        let date = TestSupport.date(hour: 9)

        _ = try repository.upsert(date: date, channel: DailyAdvice.Channel.exercise, content: "迈开腿建议", modelTag: "m1")
        _ = try repository.upsert(date: date, channel: DailyAdvice.Channel.journal, content: "小记建议", modelTag: "m1")

        let all = try context.fetch(FetchDescriptor<DailyAdvice>())
        XCTAssertEqual(all.count, 2)

        let exercise = try repository.advice(for: date, channel: DailyAdvice.Channel.exercise)
        XCTAssertEqual(exercise?.content, "迈开腿建议")
        let journal = try repository.advice(for: date, channel: DailyAdvice.Channel.journal)
        XCTAssertEqual(journal?.content, "小记建议")

        // 旧接口（不区分 channel）取最新一条
        let any = try repository.advice(for: date)
        XCTAssertNotNil(any)
    }
}
