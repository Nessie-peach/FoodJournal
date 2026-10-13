import XCTest
import SwiftData
@testable import FoodJournal

/// 迈开腿健康卡片格式化纯函数
final class HealthCardFormatTests: XCTestCase {
    func testSleepTextMixedHoursMinutes() {
        XCTAssertEqual(HealthCardFormat.sleepText(minutes: 450), "7 小时 30 分")
    }

    func testSleepTextWholeHourAndSubHour() {
        XCTAssertEqual(HealthCardFormat.sleepText(minutes: 120), "2 小时")
        XCTAssertEqual(HealthCardFormat.sleepText(minutes: 45), "45 分")
        XCTAssertEqual(HealthCardFormat.sleepText(minutes: 0), "0 分")
    }

    func testHeartTextRoundsAndHandlesZero() {
        XCTAssertEqual(HealthCardFormat.heartText(bpm: 72.4), "72")
        XCTAssertEqual(HealthCardFormat.heartText(bpm: 72.6), "73")
        XCTAssertEqual(HealthCardFormat.heartText(bpm: 0), "—")
    }

    func testHRVTextRoundsAndHandlesNil() {
        XCTAssertEqual(HealthCardFormat.hrvText(ms: 58.6), "59")
        XCTAssertNil(HealthCardFormat.hrvText(ms: nil))
    }

    func testClockTextPadsHourAndMinute() {
        var components = DateComponents()
        components.hour = 7
        components.minute = 5
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(HealthCardFormat.clockText(date), "07:05")
    }
}

/// HRV 度量口径标注：来源映射、格式化文案、落库持久化与卡片展示
final class HRVSourceLabelTests: XCTestCase {

    // MARK: - 来源映射

    func testHRVSourceLabelMapping() {
        XCTAssertEqual(HealthCardFormat.hrvSourceLabel(HRVSource.appleSDNN.rawValue), "SDNN")
        XCTAssertEqual(HealthCardFormat.hrvSourceLabel(HRVSource.garmin.rawValue), "佳明")
        XCTAssertNil(HealthCardFormat.hrvSourceLabel(nil))
        XCTAssertNil(HealthCardFormat.hrvSourceLabel("unknown"))
    }

    // MARK: - 格式化文案（含 nil）

    func testHRVDisplayTextWithSourceAndNil() {
        XCTAssertEqual(HealthCardFormat.hrvDisplayText(ms: 42, source: HRVSource.appleSDNN.rawValue), "42 ms（SDNN）")
        XCTAssertEqual(HealthCardFormat.hrvDisplayText(ms: 42, source: HRVSource.garmin.rawValue), "42 ms（佳明）")
        XCTAssertEqual(HealthCardFormat.hrvDisplayText(ms: 42, source: nil), "42 ms")
        XCTAssertEqual(HealthCardFormat.hrvDisplayText(ms: 58.6, source: nil), "59 ms")
        XCTAssertNil(HealthCardFormat.hrvDisplayText(ms: nil, source: HRVSource.appleSDNN.rawValue))
    }

    // MARK: - 卡片展示

    func testHRVCardAnnotatesHealthKitSource() {
        let withSource = DailyHealthSnapshot(
            date: .now, activeKcal: 0, sleepMinutes: 0, avgHR: 0,
            hrvMS: 45, hrvSource: HRVSource.appleSDNN.rawValue
        )
        let card = ExerciseCardLogic.hrvCard(from: withSource)
        XCTAssertEqual(card.value, "45")
        XCTAssertEqual(card.unit, "ms")
        XCTAssertEqual(card.footnote, "SDNN")

        // 来源未知：不加口径标注
        let unknown = DailyHealthSnapshot(date: .now, activeKcal: 0, sleepMinutes: 0, avgHR: 0, hrvMS: 45)
        XCTAssertNil(ExerciseCardLogic.hrvCard(from: unknown).footnote)
    }

    // MARK: - 落库持久化

    @MainActor
    func testRepositoryPersistsAndSwitchesHRVSource() throws {
        let container = try TestSupport.makeContainer()
        let repository = HealthSnapshotRepository(context: ModelContext(container))
        let day = TestSupport.date(y: 9, d: 22, hour: 15)

        // HealthKit 写入 → apple-sdnn
        let hk = try repository.upsert(
            date: day, activeKcal: 100, sleepMinutes: 400, avgHR: 60,
            hrvMS: 45, hrvSource: HRVSource.appleSDNN.rawValue, syncedAt: day
        )
        XCTAssertEqual(hk.hrvSource, "apple-sdnn")

        // Garmin 字段级合并写入带 HRV → 口径切换为 garmin-hrv
        _ = try repository.upsertGarmin(
            date: day, fields: GarminSnapshotFields(hrvLastNightAvg: 36), syncedAt: day
        )
        XCTAssertEqual(try repository.snapshot(for: day)?.hrvSource, "garmin-hrv")
    }

    @MainActor
    func testUpsertNilSourceDoesNotWipeExistingLabel() throws {
        let container = try TestSupport.makeContainer()
        let repository = HealthSnapshotRepository(context: ModelContext(container))
        let day = TestSupport.date(y: 9, d: 23, hour: 15)

        _ = try repository.upsertGarmin(
            date: day, fields: GarminSnapshotFields(hrvLastNightAvg: 36), syncedAt: day
        )
        XCTAssertEqual(try repository.snapshot(for: day)?.hrvSource, "garmin-hrv")

        // HealthKit 无 HRV（hrvSource 默认 nil）的 upsert 不应抹掉已有口径
        _ = try repository.upsert(
            date: day, activeKcal: 200, sleepMinutes: 410, avgHR: 58, hrvMS: nil, syncedAt: day
        )
        XCTAssertEqual(try repository.snapshot(for: day)?.hrvSource, "garmin-hrv")
    }
}
