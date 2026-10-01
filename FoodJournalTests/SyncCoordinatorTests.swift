import XCTest
@testable import FoodJournal

// MARK: - SyncCoordinator 纯函数（防抖 / 熔断 / 天数）

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: 防抖 shouldSkip

    /// 距上次同步 15 分钟内 → 非 manual 触发跳过
    func testShouldSkipWithin15Minutes() {
        let last = now.addingTimeInterval(-14 * 60)
        XCTAssertTrue(SyncCoordinator.shouldSkip(trigger: .foreground, lastSyncAt: last, now: now))
        XCTAssertTrue(SyncCoordinator.shouldSkip(trigger: .background, lastSyncAt: last, now: now))
    }

    /// 超过 15 分钟 或 从未同步 → 不跳过
    func testShouldNotSkipBeyond15MinutesOrNeverSynced() {
        let last = now.addingTimeInterval(-16 * 60)
        XCTAssertFalse(SyncCoordinator.shouldSkip(trigger: .foreground, lastSyncAt: last, now: now))
        XCTAssertFalse(SyncCoordinator.shouldSkip(trigger: .foreground, lastSyncAt: nil, now: now))
    }

    /// manual 永不跳过（哪怕 1 分钟前刚同步过）
    func testManualNeverSkips() {
        let last = now.addingTimeInterval(-60)
        XCTAssertFalse(SyncCoordinator.shouldSkip(trigger: .manual, lastSyncAt: last, now: now))
        XCTAssertFalse(SyncCoordinator.shouldSkip(trigger: .manual, lastSyncAt: nil, now: now))
    }

    // MARK: 熔断

    /// 连续失败 2 次不熔断，第 3 次起熔断
    func testCircuitBreakThreshold() {
        XCTAssertFalse(SyncCoordinator.shouldCircuitBreak(failureCount: 0))
        XCTAssertFalse(SyncCoordinator.shouldCircuitBreak(failureCount: 2))
        XCTAssertTrue(SyncCoordinator.shouldCircuitBreak(failureCount: 3))
        XCTAssertTrue(SyncCoordinator.shouldCircuitBreak(failureCount: 4))
    }

    /// 失败计数持久化：连续记 3 次失败 → 熔断命中；重置计数后解除（manual 重置场景）
    func testFailureCountPersistenceAndManualReset() {
        let coordinator = SyncCoordinator(
            statusStore: SyncStatusStore(defaults: makeDefaults()),
            defaults: makeDefaults()
        )
        coordinator.recordFailure(for: .garmin)
        coordinator.recordFailure(for: .garmin)
        XCTAssertFalse(coordinator.shouldCircuitBreak(source: .garmin))
        coordinator.recordFailure(for: .garmin)
        XCTAssertTrue(coordinator.shouldCircuitBreak(source: .garmin))

        // 成功即清零
        coordinator.recordSuccess(for: .garmin)
        XCTAssertFalse(coordinator.shouldCircuitBreak(source: .garmin))

        // manual 强制尝试前重置全部计数
        coordinator.recordFailure(for: .garmin)
        coordinator.recordFailure(for: .garmin)
        coordinator.recordFailure(for: .garmin)
        coordinator.resetAllFailureCounts()
        XCTAssertFalse(coordinator.shouldCircuitBreak(source: .garmin))
        XCTAssertFalse(coordinator.shouldCircuitBreak(source: .healthkit))
    }

    // MARK: 回看天数

    /// foreground / manual = 7 天，background = 2 天
    func testRecentDaysPerTrigger() {
        XCTAssertEqual(SyncCoordinator.recentDays(for: .foreground), 7)
        XCTAssertEqual(SyncCoordinator.recentDays(for: .manual), 7)
        XCTAssertEqual(SyncCoordinator.recentDays(for: .background), 2)
    }
}

// MARK: - BackgroundRefreshScheduler 参数

@MainActor
final class BackgroundRefreshSchedulerTests: XCTestCase {
    /// 任务标识与 project.yml 中 BGTaskSchedulerPermittedIdentifiers 一致
    func testTaskIdentifier() {
        XCTAssertEqual(
            BackgroundRefreshScheduler.taskIdentifier,
            "com.pigeon.foodjournal.garmin-refresh"
        )
    }

    /// earliestBeginDate ≈ now + 2 小时（容差 ±60s）
    func testEarliestBeginDateIsNowPlusTwoHours() {
        let now = Date()
        let expected = now.addingTimeInterval(2 * 3600)
        let actual = BackgroundRefreshScheduler.earliestBeginDate(from: now)
        XCTAssertEqual(actual.timeIntervalSince(expected), 0, accuracy: 60)
    }
}

// MARK: - SyncStatusStore 状态流转

@MainActor
final class SyncStatusStoreTests: XCTestCase {
    /// begin → finish：isSyncing / 来源 / lastSyncAt（持久化）/ 摘要字段正确
    func testBeginThenFinishUpdatesAllFields() {
        let defaults = makeDefaults()
        let store = SyncStatusStore(defaults: defaults)

        store.begin(sources: [.healthkit, .garmin])
        XCTAssertTrue(store.isSyncing)
        XCTAssertEqual(store.currentSources, [.healthkit, .garmin])
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.lastResultSummary)

        let finishAt = Date(timeIntervalSince1970: 1_800_000_000)
        store.finish(at: finishAt, summary: "健康 7 天，佳明 7 天")
        XCTAssertFalse(store.isSyncing)
        XCTAssertTrue(store.currentSources.isEmpty)
        XCTAssertEqual(store.lastSyncAt, finishAt)
        XCTAssertEqual(store.lastResultSummary, "健康 7 天，佳明 7 天")
        // lastSyncAt 已持久化（±1s 内），新实例可恢复
        let persisted = defaults.double(forKey: SyncStatusStore.lastSyncAtKey)
        XCTAssertEqual(persisted, finishAt.timeIntervalSince1970, accuracy: 1)
    }

    /// begin → fail：lastError 记录、isSyncing 复位；整体失败不更新 lastSyncAt（不触发防抖窗口）
    func testFailRecordsErrorWithoutTouchingLastSyncAt() {
        let store = SyncStatusStore(defaults: makeDefaults())
        XCTAssertNil(store.lastSyncAt)

        store.begin(sources: [.healthkit])
        store.fail("健康数据：网络连接中断")
        XCTAssertFalse(store.isSyncing)
        XCTAssertTrue(store.currentSources.isEmpty)
        XCTAssertEqual(store.lastError, "健康数据：网络连接中断")
        XCTAssertNil(store.lastSyncAt)
    }

    /// 部分失败：finish 携带 error 时同时保留摘要与错误
    func testPartialFailureKeepsSummaryAndError() {
        let store = SyncStatusStore(defaults: makeDefaults())
        store.begin(sources: [.healthkit, .garmin])
        store.finish(summary: "健康 7 天", error: "佳明：10-01：登录已过期")
        XCTAssertEqual(store.lastResultSummary, "健康 7 天")
        XCTAssertEqual(store.lastError, "佳明：10-01：登录已过期")
        XCTAssertFalse(store.isSyncing)
    }

    /// 初始化时从 UserDefaults 恢复 lastSyncAt
    func testRestoresLastSyncAtFromDefaults() {
        let defaults = makeDefaults()
        let timestamp = Date(timeIntervalSince1970: 1_799_900_000)
        defaults.set(timestamp.timeIntervalSince1970, forKey: SyncStatusStore.lastSyncAtKey)
        let store = SyncStatusStore(defaults: defaults)
        XCTAssertEqual(store.lastSyncAt?.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 0.5)
        XCTAssertFalse(store.isSyncing)
    }
}

// MARK: - 辅助

/// 每条测试用独立的 UserDefaults suite，避免共享状态互相污染
@MainActor
private func makeDefaults() -> UserDefaults {
    let suite = "sync-test-\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}
