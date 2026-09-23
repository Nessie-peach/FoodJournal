import XCTest
import SwiftData
@testable import FoodJournal

/// DailyHealthSnapshot upsert：同一天二次写入应更新而非新增
@MainActor
final class HealthSnapshotRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repository: HealthSnapshotRepository!

    override func setUp() {
        container = try! TestSupport.makeContainer()
        repository = HealthSnapshotRepository(context: ModelContext(container))
    }

    override func tearDown() {
        container = nil
        repository = nil
    }

    func testUpsertSameDayUpdatesInsteadOfInserting() throws {
        let day = TestSupport.date(y: 9, d: 22, hour: 15)

        // 第一次写入
        let first = try repository.upsert(
            date: day,
            activeKcal: 500,
            sleepMinutes: 420,
            avgHR: 62,
            hrvMS: 45,
            syncedAt: day
        )
        XCTAssertEqual(try repository.fetchAll().count, 1)
        XCTAssertEqual(first.activeKcal, 500)

        // 同一天再次写入（不同的时刻也属于同一天）
        let laterTime = TestSupport.date(y: 9, d: 22, hour: 22)
        let second = try repository.upsert(
            date: laterTime,
            activeKcal: 680,
            sleepMinutes: 450,
            avgHR: 58,
            hrvMS: nil,
            syncedAt: laterTime
        )
        XCTAssertEqual(try repository.fetchAll().count, 1, "同一天 upsert 不应新增记录")

        let loaded = try XCTUnwrap(try repository.snapshot(for: day))
        XCTAssertEqual(loaded.id, second.id)
        XCTAssertEqual(loaded.activeKcal, 680, accuracy: 0.001)
        XCTAssertEqual(loaded.sleepMinutes, 450, accuracy: 0.001)
        XCTAssertEqual(loaded.avgHR, 58, accuracy: 0.001)
        XCTAssertNil(loaded.hrvMS)
        XCTAssertEqual(loaded.syncedAt, laterTime)

        // 第三次写入（用当天 0 点附近的时刻验证按天归并）
        let earlyTime = TestSupport.date(y: 9, d: 22, hour: 0, minute: 5)
        _ = try repository.upsert(
            date: earlyTime,
            activeKcal: 700,
            sleepMinutes: 460,
            avgHR: 60,
            hrvMS: 50,
            syncedAt: earlyTime
        )
        XCTAssertEqual(try repository.fetchAll().count, 1)
        XCTAssertEqual(try repository.snapshot(for: day)?.activeKcal, 700)
    }

    func testUpsertDifferentDaysInsertSeparately() throws {
        let day1 = TestSupport.date(y: 9, d: 22, hour: 10)
        let day2 = TestSupport.date(y: 9, d: 23, hour: 10)

        _ = try repository.upsert(date: day1, activeKcal: 100, sleepMinutes: 400, avgHR: 60, hrvMS: 40, syncedAt: day1)
        _ = try repository.upsert(date: day2, activeKcal: 200, sleepMinutes: 410, avgHR: 65, hrvMS: 42, syncedAt: day2)

        XCTAssertEqual(try repository.fetchAll().count, 2)
        XCTAssertNotNil(try repository.snapshot(for: day1))
        XCTAssertNotNil(try repository.snapshot(for: day2))
        XCTAssertNil(try repository.snapshot(for: TestSupport.date(y: 9, d: 24, hour: 10)))
    }
}
