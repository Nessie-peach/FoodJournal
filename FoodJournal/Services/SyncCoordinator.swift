import Foundation
import SwiftData

// MARK: - 同步触发通道

/// 三通道触发：回前台 / 后台定时 / 手动
enum SyncTrigger: Equatable, Sendable {
    case foreground
    case background
    case manual
}

/// 单次同步结果：skipped（防抖/未配置跳过）或 completed（summary = 各来源成功摘要，error = 失败汇总）
enum SyncOutcome: Equatable {
    case skipped
    case completed(summary: String?, error: String?)
}

// MARK: - 同步协调器

/// 三通道统一入口：防抖、熔断、串行执行 HealthKit + Garmin 两条采集，全程驱动 SyncStatusStore。
/// 部分失败时保留成功来源已写入的数据，lastError 汇总。
@MainActor
final class SyncCoordinator {
    static let shared = SyncCoordinator()

    /// 防抖窗口：非手动触发距上次同步不足 15 分钟则跳过
    nonisolated static let debounceInterval: TimeInterval = 15 * 60
    /// 熔断阈值：某来源连续失败达到 3 次后自动触发跳过该来源
    nonisolated static let circuitBreakThreshold = 3

    private let statusStore: SyncStatusStore
    private let defaults: UserDefaults
    /// App 启动时注入；未注入（如部分测试环境）时 sync 直接返回 skipped
    private var container: ModelContainer?

    init(statusStore: SyncStatusStore = .shared, defaults: UserDefaults = .standard) {
        self.statusStore = statusStore
        self.defaults = defaults
    }

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: 纯函数（可单测）

    /// 防抖判定：manual 永不跳过；其余触发距 lastSyncAt 不足 15 分钟跳过
    nonisolated static func shouldSkip(trigger: SyncTrigger, lastSyncAt: Date?, now: Date) -> Bool {
        guard trigger != .manual, let lastSyncAt else { return false }
        return now.timeIntervalSince(lastSyncAt) < debounceInterval
    }

    /// 熔断判定：连续失败次数达到阈值即熔断
    nonisolated static func shouldCircuitBreak(failureCount: Int) -> Bool {
        failureCount >= circuitBreakThreshold
    }

    /// 同步回看天数：回前台/手动拉近 7 天，后台只拉近 2 天（省流量与请求量）
    nonisolated static func recentDays(for trigger: SyncTrigger) -> Int {
        trigger == .background ? 2 : 7
    }

    // MARK: 失败计数（UserDefaults 持久化）

    private func failureKey(_ source: SyncSource) -> String { "sync.failureCount.\(source.rawValue)" }

    func failureCount(for source: SyncSource) -> Int {
        defaults.integer(forKey: failureKey(source))
    }

    func recordSuccess(for source: SyncSource) {
        defaults.set(0, forKey: failureKey(source))
    }

    func recordFailure(for source: SyncSource) {
        defaults.set(failureCount(for: source) + 1, forKey: failureKey(source))
    }

    /// 手动触发时重置全部来源的失败计数（强制尝试）
    func resetAllFailureCounts() {
        for source in SyncSource.allCases {
            defaults.set(0, forKey: failureKey(source))
        }
    }

    /// 某来源当前是否应被熔断
    func shouldCircuitBreak(source: SyncSource) -> Bool {
        Self.shouldCircuitBreak(failureCount: failureCount(for: source))
    }

    // MARK: 同步入口

    /// 执行一轮同步。防抖/熔断命中返回 .skipped，不触碰状态条。
    @discardableResult
    func sync(trigger: SyncTrigger) async -> SyncOutcome {
        guard !Self.shouldSkip(trigger: trigger, lastSyncAt: statusStore.lastSyncAt, now: .now) else {
            return .skipped
        }
        guard let container else { return .skipped }

        if trigger == .manual {
            resetAllFailureCounts()
        }

        // 参与本轮的来源：HealthKit 始终参与；Garmin 已登录且（手动 或 未熔断）才参与
        var sources: Set<SyncSource> = [.healthkit]
        if GarminTokenStore.shared.loadTokens() != nil,
           trigger == .manual || !shouldCircuitBreak(source: .garmin) {
            sources.insert(.garmin)
        }

        statusStore.begin(sources: sources)

        let days = Self.recentDays(for: trigger)
        var summaries: [String] = []
        var errors: [String] = []

        // 串行 1：HealthKit（未请求授权时先弹一次授权）
        do {
            let service = HealthKitService()
            if await service.authorizationState() == .notDetermined {
                try await service.requestAuthorization()
            }
            let outcome = await service.syncRecent(days: days, context: container.mainContext)
            recordSuccess(for: .healthkit)
            summaries.append(outcome.daysWritten > 0 ? "健康 \(outcome.daysWritten) 天" : "健康暂无新数据")
        } catch {
            recordFailure(for: .healthkit)
            errors.append("健康数据：\(error.localizedDescription)")
        }

        // 串行 2：Garmin（未登录已被 sources 过滤，不会发请求）
        if sources.contains(.garmin) {
            let outcome = await GarminSyncService().syncRecent(days: days, context: container.mainContext)
            if outcome.failures.isEmpty {
                recordSuccess(for: .garmin)
                if outcome.daysWritten > 0 {
                    summaries.append("佳明 \(outcome.daysWritten) 天")
                }
            } else {
                recordFailure(for: .garmin)
                errors.append("佳明：" + outcome.failures.joined(separator: "；"))
            }
        }

        let summary = summaries.isEmpty ? nil : summaries.joined(separator: "，")
        let error = errors.isEmpty ? nil : errors.joined(separator: "；")
        statusStore.finish(summary: summary, error: error)
        return .completed(summary: summary, error: error)
    }
}
