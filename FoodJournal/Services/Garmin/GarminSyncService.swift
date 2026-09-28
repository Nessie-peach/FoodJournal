import Foundation
import SwiftData

// MARK: - 邮箱脱敏

/// 展示用邮箱脱敏：本地部分保留前 7 位（不足全保留）+ "***" + 域名。
/// 例：tonytao81@outlook.com → tonytao***@outlook.com
enum GarminAccountMasker {
    static func mask(_ email: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@") else { return "***" }
        let local = String(trimmed[trimmed.startIndex..<at])
        let domain = String(trimmed[at...])
        guard !local.isEmpty else { return "***" + domain }
        let prefix = String(local.prefix(7))
        return prefix + "***" + domain
    }
}

// MARK: - 同步结果

/// 近 N 天 Garmin 同步结果：成功写入天数 + 各天失败原因清单（中文）
struct GarminSyncOutcome: Equatable, Sendable {
    var daysWritten: Int
    /// 失败条目「MM-dd：原因」；全部成功时为空
    var failures: [String]

    var summaryText: String {
        if failures.isEmpty {
            return daysWritten > 0 ? "已同步 \(daysWritten) 天 Garmin 数据" : "Garmin 暂无可同步的数据"
        }
        return "同步完成 \(daysWritten) 天，部分失败：" + failures.joined(separator: "；")
    }
}

// MARK: - 同步服务

/// Garmin 数据落库衔接：拉取近 N 天 GarminDailyData → GarminSnapshotFields → 字段级合并写入快照。
/// 仅写 Garmin 专有字段，不覆盖 HealthKit 同步的既有字段。
@MainActor
final class GarminSyncService {
    private let auth: GarminAuthService
    private let dataClient: GarminDataClient
    private let tokenStore: GarminTokenStore

    init(auth: GarminAuthService? = nil, tokenStore: GarminTokenStore = .shared) {
        let authService = auth ?? GarminAuthService(tokenStore: tokenStore)
        self.auth = authService
        self.dataClient = GarminDataClient(auth: authService)
        self.tokenStore = tokenStore
    }

    /// 拉取最近 N 天（含今天）Garmin 数据并逐日落库。
    /// 单天失败不影响其余天；token 失效且本机存有登录凭据时尝试免密重登一次。
    @discardableResult
    func syncRecent(days: Int = 7, context: ModelContext) async -> GarminSyncOutcome {
        guard auth.isLoggedIn else { return GarminSyncOutcome(daysWritten: 0, failures: []) }

        let repository = HealthSnapshotRepository(context: context)
        let calendar = Calendar.current
        let now = Date()
        var daysWritten = 0
        var failures: [String] = []
        var retried = false

        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            do {
                let data = try await dataClient.fetchDaily(date: day)
                try repository.upsertGarmin(
                    date: day,
                    fields: GarminSnapshotFields(from: data),
                    syncedAt: now
                )
                daysWritten += 1
            } catch {
                // 全部天首次失败且存有凭据 → 令牌可能已失效，免密重登一次后继续
                if !retried, daysWritten == 0, let credentials = tokenStore.loadCredentials() {
                    retried = true
                    if (try? await auth.login(email: credentials.email, password: credentials.password)) != nil {
                        do {
                            let data = try await dataClient.fetchDaily(date: day)
                            try repository.upsertGarmin(
                                date: day,
                                fields: GarminSnapshotFields(from: data),
                                syncedAt: now
                            )
                            daysWritten += 1
                            continue
                        } catch {
                            failures.append("\(Self.dayText(day))：\(GarminDataClient.errorSummary(error))")
                            continue
                        }
                    }
                }
                failures.append("\(Self.dayText(day))：\(GarminDataClient.errorSummary(error))")
            }
        }
        return GarminSyncOutcome(daysWritten: daysWritten, failures: failures)
    }

    /// 日期 →「MM-dd」（固定 locale，结果稳定）
    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}
