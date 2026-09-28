import XCTest
import SwiftData
@testable import FoodJournal

// MARK: - E2-2：Garmin UI 与数据落库衔接

@MainActor
final class GarminUIIntegrationTests: XCTestCase {
    private var container: ModelContainer!
    private var repository: HealthSnapshotRepository!

    override func setUp() {
        super.setUp()
        container = try! TestSupport.makeContainer()
        repository = HealthSnapshotRepository(context: ModelContext(container))
    }

    override func tearDown() {
        container = nil
        repository = nil
        super.tearDown()
    }

    // MARK: 快照字段级合并

    /// Garmin 同步不覆盖 HealthKit 写入的 activeKcal/sleepMinutes/avgHR 等既有字段，两类字段共存
    func testGarminMergeDoesNotOverwriteHealthKitFields() throws {
        let day = TestSupport.date(y: 9, d: 22, hour: 15)

        // HealthKit 先写入
        _ = try repository.upsert(
            date: day,
            activeKcal: 500,
            restingKcal: 1280,
            sleepMinutes: 420,
            sleepStart: TestSupport.date(y: 9, d: 21, hour: 23),
            sleepEnd: TestSupport.date(y: 9, d: 22, hour: 7),
            avgHR: 62,
            hrvMS: 45,
            syncedAt: day
        )

        // Garmin 同步（同一行，字段级合并）
        let garminFields = GarminSnapshotFields(
            hrvLastNightAvg: 36,
            hrvWeeklyAvg: 49,
            hrvBaselineLow: 41,
            hrvBaselineHigh: 58,
            bodyBatteryCurrent: 11,
            stressAvg: 34,
            deepSleepMin: 98,
            remSleepMin: 16,
            sleepScore: 45
        )
        let merged = try repository.upsertGarmin(date: day, fields: garminFields, syncedAt: day)

        // 仍是一行
        XCTAssertEqual(try repository.fetchAll().count, 1)
        // HealthKit 字段未被覆盖
        XCTAssertEqual(merged.activeKcal, 500, accuracy: 0.001)
        XCTAssertEqual(merged.restingKcal, 1280, accuracy: 0.001)
        XCTAssertEqual(merged.sleepMinutes, 420, accuracy: 0.001)
        XCTAssertEqual(merged.avgHR, 62, accuracy: 0.001)
        XCTAssertEqual(merged.hrvMS ?? -1, 45, accuracy: 0.001)
        XCTAssertNotNil(merged.sleepStart)
        XCTAssertNotNil(merged.sleepEnd)
        // Garmin 字段已写入
        XCTAssertEqual(merged.hrvLastNightAvg ?? -1, 36, accuracy: 0.001)
        XCTAssertEqual(merged.hrvWeeklyAvg ?? -1, 49, accuracy: 0.001)
        XCTAssertEqual(merged.hrvBaselineLow ?? -1, 41, accuracy: 0.001)
        XCTAssertEqual(merged.hrvBaselineHigh ?? -1, 58, accuracy: 0.001)
        XCTAssertEqual(merged.bodyBatteryCurrent, 11)
        XCTAssertEqual(merged.stressAvg, 34)
        XCTAssertEqual(merged.deepSleepMin ?? -1, 98, accuracy: 0.001)
        XCTAssertEqual(merged.remSleepMin ?? -1, 16, accuracy: 0.001)
        XCTAssertEqual(merged.sleepScore, 45)
    }

    /// 当日无快照时 Garmin upsert 新建行；HealthKit 字段落 0，Garmin 字段完整
    func testGarminUpsertCreatesRowWhenMissing() throws {
        let day = TestSupport.date(y: 9, d: 23, hour: 10)
        let fields = GarminSnapshotFields(bodyBatteryCurrent: 66, stressAvg: 20)
        let snapshot = try repository.upsertGarmin(date: day, fields: fields, syncedAt: day)
        XCTAssertEqual(try repository.fetchAll().count, 1)
        XCTAssertEqual(snapshot.activeKcal, 0)
        XCTAssertEqual(snapshot.bodyBatteryCurrent, 66)
        XCTAssertEqual(snapshot.stressAvg, 20)
    }

    // MARK: HRV 卡数据源选择

    /// HRV 卡：Garmin 优先 → HealthKit 回落 → 空
    func testHRVCardDataSourcePriority() {
        func makeSnapshot(hrvLastNightAvg: Double?, hrvMS: Double?) -> DailyHealthSnapshot {
            let snapshot = DailyHealthSnapshot(date: .now, activeKcal: 0, sleepMinutes: 0, avgHR: 0)
            snapshot.hrvLastNightAvg = hrvLastNightAvg
            snapshot.hrvMS = hrvMS
            return snapshot
        }

        // 1. Garmin 优先（含基线文案 + 佳明标注）
        var snapshot = makeSnapshot(hrvLastNightAvg: 36, hrvMS: 50)
        snapshot.hrvBaselineLow = 41
        snapshot.hrvBaselineHigh = 58
        var card = ExerciseCardLogic.hrvCard(from: snapshot)
        XCTAssertEqual(card.value, "36")
        XCTAssertEqual(card.unit, "ms")
        XCTAssertEqual(card.footnote, "36 ms · 基线 41-58，偏低 · 佳明")

        // 基线内 → 「平衡」
        snapshot.hrvLastNightAvg = 50
        card = ExerciseCardLogic.hrvCard(from: snapshot)
        XCTAssertEqual(card.footnote, "50 ms · 基线 41-58，平衡 · 佳明")

        // 2. HealthKit 回落（无 Garmin 数据）
        card = ExerciseCardLogic.hrvCard(from: makeSnapshot(hrvLastNightAvg: nil, hrvMS: 45))
        XCTAssertEqual(card.value, "45")
        XCTAssertEqual(card.unit, "ms")
        XCTAssertNil(card.footnote)

        // 3. 都没有 → 未同步
        card = ExerciseCardLogic.hrvCard(from: makeSnapshot(hrvLastNightAvg: nil, hrvMS: nil))
        XCTAssertEqual(card.value, "—")
        XCTAssertEqual(card.footnote, "未同步")

        // 无快照同样未同步
        card = ExerciseCardLogic.hrvCard(from: nil)
        XCTAssertEqual(card.value, "—")
        XCTAssertEqual(card.footnote, "未同步")
    }

    /// 身体电量 / 压力 / 睡眠分期卡逻辑
    func testBatteryStressSleepStagesCards() {
        // 身体电量：当前值 + 较昨日充/放
        XCTAssertEqual(ExerciseCardLogic.batteryCard(current: 40, yesterday: 20).footnote, "较昨日充电 +20")
        XCTAssertEqual(ExerciseCardLogic.batteryCard(current: 20, yesterday: 40).footnote, "较昨日放电 −20")
        XCTAssertEqual(ExerciseCardLogic.batteryCard(current: 40, yesterday: 40).footnote, "与昨日持平")
        XCTAssertEqual(ExerciseCardLogic.batteryCard(current: nil, yesterday: nil).value, "—")

        // 压力分级
        XCTAssertEqual(ExerciseCardLogic.stressCard(avg: 34).footnote, "中等压力")
        XCTAssertEqual(ExerciseCardLogic.stressCard(avg: 80).footnote, "极高压力")
        XCTAssertEqual(ExerciseCardLogic.stressCard(avg: nil).value, "—")

        // 睡眠分期：有睡眠时长 → 百分比
        let snapshot = DailyHealthSnapshot(date: .now, activeKcal: 0, sleepMinutes: 420, avgHR: 0)
        snapshot.deepSleepMin = 98
        snapshot.remSleepMin = 84
        snapshot.sleepScore = 45
        XCTAssertEqual(ExerciseCardLogic.sleepStagesText(snapshot), "深睡 23% · REM 20% · 睡眠分 45")

        // 无时长 → 分钟展示
        let snapshotNoTotal = DailyHealthSnapshot(date: .now, activeKcal: 0, sleepMinutes: 0, avgHR: 0)
        snapshotNoTotal.deepSleepMin = 98
        snapshotNoTotal.remSleepMin = 84
        XCTAssertEqual(ExerciseCardLogic.sleepStagesText(snapshotNoTotal), "深睡 98 分 · REM 84 分")

        // 缺分期 → nil
        let snapshotNoStages = DailyHealthSnapshot(date: .now, activeKcal: 0, sleepMinutes: 420, avgHR: 0)
        XCTAssertNil(ExerciseCardLogic.sleepStagesText(snapshotNoStages))
    }

    // MARK: 邮箱脱敏

    func testEmailMasking() {
        XCTAssertEqual(GarminAccountMasker.mask("tonytao81@outlook.com"), "tonytao***@outlook.com")
        XCTAssertEqual(GarminAccountMasker.mask("ab@outlook.com"), "ab***@outlook.com")
        XCTAssertEqual(GarminAccountMasker.mask("longlocalpart@qq.com"), "longloc***@qq.com")
        XCTAssertEqual(GarminAccountMasker.mask("no-at-sign"), "***")
        XCTAssertEqual(GarminAccountMasker.mask(""), "***")
    }

    // MARK: 凭据存取

    func testCredentialsRoundTrip() throws {
        let store = GarminTokenStore(service: "com.pigeon.foodjournal.garmin.test")
        store.deleteCredentials()
        defer { store.deleteCredentials() }
        XCTAssertNil(store.loadCredentials())
        try store.saveCredentials(.init(email: "tonytao81@outlook.com", password: "secret"))
        XCTAssertEqual(store.loadCredentials(), .init(email: "tonytao81@outlook.com", password: "secret"))
        store.deleteCredentials()
        XCTAssertNil(store.loadCredentials())
    }

    // MARK: AdviceService 打包增强

    /// 打包含 Garmin 专有数据行（HRV 基线 / 身体电量 / 压力 / 睡眠分期）
    func testPackContextTextIncludesGarminLines() {
        let snapshot = DailyHealthSnapshot(
            date: TestSupport.date(y: 9, d: 22, hour: 15),
            activeKcal: 500,
            sleepMinutes: 420,
            avgHR: 62,
            syncedAt: TestSupport.date(y: 9, d: 22, hour: 15)
        )
        snapshot.hrvLastNightAvg = 36
        snapshot.hrvBaselineLow = 41
        snapshot.hrvBaselineHigh = 58
        snapshot.bodyBatteryCurrent = 11
        snapshot.stressAvg = 34
        snapshot.deepSleepMin = 98
        snapshot.remSleepMin = 84
        snapshot.sleepScore = 45

        let text = AdviceService.packContextText(snapshot: snapshot, meals: [], weights: [])
        XCTAssertTrue(text.contains("HRV：昨晚平均 36 ms（佳明），基线 41-58 ms（低于基线）"))
        XCTAssertTrue(text.contains("身体电量：11/100"))
        XCTAssertTrue(text.contains("压力：均值 34/100"))
        XCTAssertTrue(text.contains("睡眠分期：深睡 23%，REM 20%，睡眠分 45"))
    }

    /// 缺失 Garmin 数据时标「无数据」；HRV 回落 HealthKit 值
    func testPackContextTextMarksMissingGarminData() {
        let snapshot = DailyHealthSnapshot(
            date: TestSupport.date(y: 9, d: 22, hour: 15),
            activeKcal: 500,
            sleepMinutes: 420,
            avgHR: 62,
            hrvMS: 45,
            syncedAt: TestSupport.date(y: 9, d: 22, hour: 15)
        )
        let text = AdviceService.packContextText(snapshot: snapshot, meals: [], weights: [])
        XCTAssertTrue(text.contains("HRV：45 ms"), "无 Garmin 时应回落 HealthKit 值")
        XCTAssertTrue(text.contains("身体电量：无数据"))
        XCTAssertTrue(text.contains("压力：无数据"))
        XCTAssertTrue(text.contains("睡眠分期：无数据"))
    }
}
