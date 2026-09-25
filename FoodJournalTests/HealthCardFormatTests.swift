import XCTest
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
