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

    /// 指定日期时间插餐（取餐口径测试用）
    @MainActor
    @discardableResult
    func insertMeal(
        _ context: ModelContext,
        name: String,
        date: Date,
        calories: Double
    ) throws -> Meal {
        let meal = Meal(date: date, mealType: .lunch, name: name)
        meal.items = [FoodItem(name: name, calories: calories, protein: 0, carbs: 0, fat: 0)]
        context.insert(meal)
        try context.save()
        return meal
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
        // 健康核心字段齐全：不标注无数据
        XCTAssertFalse(text.contains("睡眠：无数据"))
        XCTAssertFalse(text.contains("平均心率：无数据"))
        XCTAssertFalse(text.contains("HRV：无数据"))
        XCTAssertFalse(text.contains("运动记录：无数据"))
        // Garmin 专有字段本快照未同步：逐项标注无数据（E2-2）
        XCTAssertTrue(text.contains("身体电量：无数据"))
        XCTAssertTrue(text.contains("压力：无数据"))
        XCTAssertTrue(text.contains("睡眠分期：无数据"))
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

    // MARK: - 业务日取餐口径（B2 回归）

    /// 凌晨 02:00 生成建议：取餐区间 = 生成时刻所属业务日（锚点为前一天），
    /// 与近三天表口径一致；不得对锚点二次减一天取到前前一业务日。
    @MainActor
    func testFetchMealsLateNightUsesGenerationBusinessDay() throws {
        let context = try makeContext()
        // 10/1 业务日的餐：白天一餐 + 次日凌晨一餐
        try insertMeal(context, name: "10/1午餐", date: TestSupport.date(y: 10, d: 1, hour: 12), calories: 300)
        try insertMeal(context, name: "10/2凌晨", date: TestSupport.date(y: 10, d: 2, hour: 1, minute: 30), calories: 200)
        // 干扰项：9/30 业务日、10/2 业务日各一餐
        try insertMeal(context, name: "9/30午餐", date: TestSupport.date(y: 9, d: 30, hour: 12), calories: 999)
        try insertMeal(context, name: "10/2午餐", date: TestSupport.date(y: 10, d: 2, hour: 12), calories: 500)

        // 生成时刻 10/2 02:00 → 业务日锚点 = 10/1 00:00
        let now = TestSupport.date(y: 10, d: 2, hour: 2)
        let anchor = LogicalDay.businessDay(of: now)
        let meals = AdviceService.fetchMeals(businessDay: anchor, in: context)

        XCTAssertEqual(meals.map(\.name), ["10/1午餐", "10/2凌晨"])
        XCTAssertEqual(meals.reduce(0) { $0 + $1.totalCalories }, 500)
    }

    /// 白天 14:00 生成建议：取餐区间 = 当日业务日 [04:00, 次日 04:00)
    @MainActor
    func testFetchMealsDaytimeUsesSameDayBusinessDay() throws {
        let context = try makeContext()
        try insertMeal(context, name: "10/2午餐", date: TestSupport.date(y: 10, d: 2, hour: 12), calories: 500)
        try insertMeal(context, name: "10/3凌晨", date: TestSupport.date(y: 10, d: 3, hour: 1), calories: 100)
        try insertMeal(context, name: "10/1午餐", date: TestSupport.date(y: 10, d: 1, hour: 12), calories: 999)

        // 生成时刻 10/2 14:00 → 业务日锚点 = 10/2 00:00
        let now = TestSupport.date(y: 10, d: 2, hour: 14)
        let anchor = LogicalDay.businessDay(of: now)
        let meals = AdviceService.fetchMeals(businessDay: anchor, in: context)

        XCTAssertEqual(meals.map(\.name), ["10/2午餐", "10/3凌晨"])
    }

    /// 回归：同一生成时刻，AdviceService 取到的餐集合与近三天表
    /// （按 businessDay(of: meal.date) 归属）完全一致
    @MainActor
    func testFetchMealsMatchesTrendTableGrouping() throws {
        let context = try makeContext()
        let dates = [
            TestSupport.date(y: 10, d: 1, hour: 8),
            TestSupport.date(y: 10, d: 1, hour: 19),
            TestSupport.date(y: 10, d: 2, hour: 0, minute: 30),  // 凌晨 → 10/1 业务日
            TestSupport.date(y: 10, d: 2, hour: 2),              // 凌晨 → 10/1 业务日
            TestSupport.date(y: 10, d: 2, hour: 9),
            TestSupport.date(y: 9, d: 30, hour: 21),
        ]
        for (index, date) in dates.enumerated() {
            try insertMeal(context, name: "餐\(index)", date: date, calories: 100)
        }

        let now = TestSupport.date(y: 10, d: 2, hour: 2)  // 凌晨生成
        let anchor = LogicalDay.businessDay(of: now)
        let fetched = AdviceService.fetchMeals(businessDay: anchor, in: context)
        let allMeals = try context.fetch(FetchDescriptor<Meal>())
        let trendGrouped = allMeals.filter { LogicalDay.businessDay(of: $0.date) == anchor }

        XCTAssertEqual(Set(fetched.map(\.id)), Set(trendGrouped.map(\.id)))
        XCTAssertEqual(fetched.count, 4)  // 10/1 全天 2 餐 + 10/2 凌晨 2 餐
    }

    /// 打包文本带锚点时，睡眠 / 活动消耗 / 饮食行含明确日期与时间段标注
    @MainActor
    func testPackContextTextAnnotatesDatesWithAnchor() throws {
        let snapshot = DailyHealthSnapshot(
            date: TestSupport.date(y: 10, d: 1, hour: 15),
            activeKcal: 502,
            sleepMinutes: 388,  // 6 小时 28 分
            sleepStart: TestSupport.date(y: 10, d: 1, hour: 2, minute: 33),
            sleepEnd: TestSupport.date(y: 10, d: 1, hour: 9, minute: 1),
            avgHR: 60
        )
        snapshot.hrvLastNightAvg = 41
        let meal = Meal(
            date: TestSupport.date(y: 10, d: 1, hour: 12),
            mealType: .lunch,
            name: "鸡腿饭"
        )
        meal.items = [FoodItem(name: "鸡腿饭", calories: 2249, protein: 0, carbs: 0, fat: 0)]

        let text = AdviceService.packContextText(
            snapshot: snapshot,
            meals: [meal],
            weights: [],
            businessDayAnchor: TestSupport.date(y: 10, d: 1, hour: 0)
        )

        XCTAssertTrue(text.contains("（10/1 02:33 入睡，10/1 09:01 起床）"))
        XCTAssertTrue(text.contains("活动消耗：502 千卡（10/1 全天）"))
        XCTAssertTrue(text.contains("HRV：10/1 夜间平均 41 ms（佳明）"))
        XCTAssertTrue(text.contains("【10/1 饮食（业务日 04:00–次日 03:59）】"))
        XCTAssertTrue(text.contains("热量 2249 千卡"))
    }

    /// system prompt 含相对表述禁令（逐字增补，四段式结构不变）
    func testSystemPromptRequiresExplicitDates() {
        XCTAssertTrue(AdviceService.systemPrompt.contains(
            "数据行均已标注日期与时间段，请严格按标注措辞，不要使用『昨晚』『今天』等相对表述替代具体日期（例如应写『10/1 凌晨 02:33 入睡』）。"
        ))
        // 原四段式结构仍在
        XCTAssertTrue(AdviceService.systemPrompt.contains("一、当日概况"))
        XCTAssertTrue(AdviceService.systemPrompt.contains("四、心理关怀"))
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
