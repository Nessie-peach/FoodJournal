import XCTest
@testable import FoodJournal

/// HealthKitService 可测试纯函数：睡眠跨天归属与运动记录去重合并
final class HealthKitAggregationTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var components = DateComponents()
        components.year = y
        components.month = m
        components.day = d
        components.hour = h
        components.minute = min
        return Calendar.current.date(from: components)!
    }

    // MARK: 睡眠归属（口径：与当天区间交集累计，跨天按交集分摊）

    func testSleepAttributionCrossesMidnight() {
        // 9/22 23:00 入睡，9/23 07:00 醒来：分摊给 9/22 六十分钟、9/23 七小时
        let interval = HealthKitService.SleepInterval(
            start: date(2026, 9, 22, 23),
            end: date(2026, 9, 23, 7)
        )

        let forDay22 = HealthKitService.attributeSleep(
            asleepIntervals: [interval],
            dayStart: date(2026, 9, 22, 0),
            dayEnd: date(2026, 9, 23, 0)
        )
        XCTAssertEqual(forDay22.minutes, 60, accuracy: 0.001)
        XCTAssertEqual(forDay22.earliestStart, interval.start)
        XCTAssertEqual(forDay22.latestEnd, interval.end)

        let forDay23 = HealthKitService.attributeSleep(
            asleepIntervals: [interval],
            dayStart: date(2026, 9, 23, 0),
            dayEnd: date(2026, 9, 24, 0)
        )
        XCTAssertEqual(forDay23.minutes, 420, accuracy: 0.001)
        XCTAssertEqual(forDay23.earliestStart, interval.start, "sleepStart 取原始入睡时刻，不裁剪")
        XCTAssertEqual(forDay23.latestEnd, interval.end)
    }

    func testSleepAttributionIgnoresDisjointIntervals() {
        // 与当天完全无交集（睡在 9/20），9/22 不累计、无起止
        let interval = HealthKitService.SleepInterval(
            start: date(2026, 9, 20, 23),
            end: date(2026, 9, 21, 7)
        )
        let result = HealthKitService.attributeSleep(
            asleepIntervals: [interval],
            dayStart: date(2026, 9, 22, 0),
            dayEnd: date(2026, 9, 23, 0)
        )
        XCTAssertEqual(result.minutes, 0)
        XCTAssertNil(result.earliestStart)
        XCTAssertNil(result.latestEnd)
    }

    func testSleepAttributionMultipleIntervalsPicksEarliestAndLatest() {
        // 两段小睡：最早入睡取 14:00，最晚起床取 17:30
        let nap1 = HealthKitService.SleepInterval(
            start: date(2026, 9, 22, 14),
            end: date(2026, 9, 22, 15)
        )
        let nap2 = HealthKitService.SleepInterval(
            start: date(2026, 9, 22, 16, 30),
            end: date(2026, 9, 22, 17, 30)
        )
        let result = HealthKitService.attributeSleep(
            asleepIntervals: [nap2, nap1],
            dayStart: date(2026, 9, 22, 0),
            dayEnd: date(2026, 9, 23, 0)
        )
        XCTAssertEqual(result.minutes, 120, accuracy: 0.001)
        XCTAssertEqual(result.earliestStart, nap1.start)
        XCTAssertEqual(result.latestEnd, nap2.end)
    }

    // MARK: 运动记录去重合并（以 uuid 为准）

    func testMergeWorkoutsDeduplicatesByUUID() {
        let existing = WorkoutRecord(
            uuid: "A", activityType: "1", durationMinutes: 30,
            energyKcal: 200, startDate: date(2026, 9, 22, 8)
        )
        // 同 uuid 再次同步：保留已有记录，不重复
        let incomingDuplicate = WorkoutRecord(
            uuid: "A", activityType: "1", durationMinutes: 31,
            energyKcal: 210, startDate: date(2026, 9, 22, 8)
        )
        let incomingNew = WorkoutRecord(
            uuid: "B", activityType: "37", durationMinutes: 45,
            energyKcal: 500, startDate: date(2026, 9, 22, 18)
        )
        let merged = HealthKitService.mergeWorkouts(
            existing: [existing], incoming: [incomingDuplicate, incomingNew]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.uuid, "A")
        XCTAssertEqual(merged.first?.durationMinutes, 30, "重复 uuid 保留原记录")
    }

    func testWorkoutsJSONRoundTrip() {
        let workouts = [
            WorkoutRecord(
                uuid: "A", activityType: "1", durationMinutes: 30,
                energyKcal: 200, startDate: date(2026, 9, 22, 8)
            ),
            WorkoutRecord(
                uuid: "B", activityType: "37", durationMinutes: 45,
                energyKcal: nil, startDate: date(2026, 9, 22, 18)
            ),
        ]
        let json = HealthKitService.workoutsJSONString(workouts)
        XCTAssertNotNil(json)
        XCTAssertEqual(HealthKitService.decodeWorkouts(json), workouts)

        XCTAssertNil(HealthKitService.workoutsJSONString([]))
        XCTAssertEqual(HealthKitService.decodeWorkouts(nil), [])
        XCTAssertEqual(HealthKitService.decodeWorkouts("invalid json"), [])
    }
}
