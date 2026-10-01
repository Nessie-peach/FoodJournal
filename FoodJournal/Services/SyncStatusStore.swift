import Foundation
import Observation

// MARK: - 同步来源

/// 数据同步来源：HealthKit（苹果健康）/ Garmin（佳明）
enum SyncSource: String, CaseIterable, Sendable {
    case healthkit
    case garmin

    var displayName: String {
        switch self {
        case .healthkit: return "健康"
        case .garmin: return "佳明"
        }
    }
}

// MARK: - 同步状态存储

/// 全局共享的同步状态（@Observable）：UI 三处转圈/文案的唯一数据源。
/// lastSyncAt 经 UserDefaults 持久化，重启后防抖与「上次同步」仍生效。
@MainActor
@Observable
final class SyncStatusStore {
    /// 全局共享实例（UI 与协调器统一读这一份）
    static let shared = SyncStatusStore()

    /// lastSyncAt 持久化键（timeIntervalSince1970，0 = 无）
    static let lastSyncAtKey = "syncStatus.lastSyncAt"

    private(set) var isSyncing = false
    private(set) var currentSources: Set<SyncSource> = []
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var lastResultSummary: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let timestamp = defaults.double(forKey: Self.lastSyncAtKey)
        lastSyncAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    /// 同步开始：记录本轮涉及的来源，清空上一轮错误/结果
    func begin(sources: Set<SyncSource>) {
        isSyncing = true
        currentSources = sources
        lastError = nil
        lastResultSummary = nil
    }

    /// 同步结束（含部分失败）：更新 lastSyncAt 并持久化；error 非空时同时记录错误
    func finish(at date: Date = .now, summary: String? = nil, error: String? = nil) {
        isSyncing = false
        currentSources = []
        lastSyncAt = date
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastSyncAtKey)
        lastResultSummary = summary
        lastError = error
    }

    /// 同步整体失败：不更新 lastSyncAt（允许尽快重试），仅记录错误
    func fail(_ message: String) {
        isSyncing = false
        currentSources = []
        lastError = message
    }
}
