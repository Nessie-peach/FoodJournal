import Foundation

// MARK: - 上游接口 DTO（只解析需要的字段；结构对照 docs/r55_garmin_results.json）

/// GET /wellness-service/wellness/hrv/{date}
struct GarminHRVResponse: Codable, Equatable, Sendable {
    let hrvSummary: Summary?
    struct Summary: Codable, Equatable, Sendable {
        let lastNightAvg: Double?
        let weeklyAvg: Double?
        let status: String?
        let baseline: Baseline?
        struct Baseline: Codable, Equatable, Sendable {
            let balancedLow: Double?
            let balancedUpper: Double?
        }
    }
}

/// GET /wellness-service/wellness/bodyBattery/{date}（返回数组）
struct GarminBodyBatteryDay: Codable, Equatable, Sendable {
    let charged: Int?
    let drained: Int?
    let bodyBatteryValuesArray: [[Int?]]?
}

/// GET /wellness-service/wellness/stress/{date}
struct GarminStressResponse: Codable, Equatable, Sendable {
    let avgStressLevel: Double?
    let maxStressLevel: Double?
}

/// GET /wellness-service/wellness/nightlySleep/{date}
struct GarminSleepResponse: Codable, Equatable, Sendable {
    let dailySleepDTO: DailySleep?
    struct DailySleep: Codable, Equatable, Sendable {
        let sleepTimeSeconds: Int?
        let deepSleepSeconds: Int?
        let lightSleepSeconds: Int?
        let remSleepSeconds: Int?
        let avgSleepStress: Double?
        let sleepScores: Scores?
        struct Scores: Codable, Equatable, Sendable {
            let overall: Overall?
            struct Overall: Codable, Equatable, Sendable {
                let value: Int?
            }
        }
    }
}

/// GET /usersummary-service/usersummary/daily/{date}
struct GarminSummaryResponse: Codable, Equatable, Sendable {
    let totalSteps: Int?
    let activeKilocalories: Double?
    let bmrKilocalories: Double?
    let restingHeartRate: Int?
}

// MARK: - 每日汇总 DTO

/// 单日 Garmin 数据汇总；任一项拉取失败时对应字段为 nil，错误摘要记入 errors
struct GarminDailyData: Codable, Equatable, Sendable {
    // HRV
    var hrvLastNightAvg: Double? = nil
    var hrvWeeklyAvg: Double? = nil
    var hrvBaselineLow: Double? = nil
    var hrvBaselineHigh: Double? = nil
    var hrvStatus: String? = nil
    // 身体电量
    var bodyBatteryCharged: Int? = nil
    var bodyBatteryDrained: Int? = nil
    var bodyBatteryCurrent: Int? = nil
    // 压力
    var stressAvg: Double? = nil
    var stressMax: Double? = nil
    // 睡眠（分钟）
    var sleepTotalMin: Double? = nil
    var deepSleepMin: Double? = nil
    var lightSleepMin: Double? = nil
    var remSleepMin: Double? = nil
    var sleepScore: Int? = nil
    var avgSleepStress: Double? = nil
    // 每日摘要（用于与 HealthKit 交叉校验）
    var restingHeartRate: Int? = nil
    var steps: Int? = nil
    var activeKcal: Double? = nil
    var restingKcal: Double? = nil
    /// 各项拉取失败的错误摘要（全部成功时为 nil）
    var errors: [String]? = nil

    mutating func applyHRV(_ response: GarminHRVResponse) {
        guard let summary = response.hrvSummary else { return }
        hrvLastNightAvg = summary.lastNightAvg
        hrvWeeklyAvg = summary.weeklyAvg
        hrvBaselineLow = summary.baseline?.balancedLow
        hrvBaselineHigh = summary.baseline?.balancedUpper
        hrvStatus = summary.status
    }

    mutating func applyBodyBattery(_ days: [GarminBodyBatteryDay]) {
        guard let day = days.first else { return }
        bodyBatteryCharged = day.charged
        bodyBatteryDrained = day.drained
        if let series = day.bodyBatteryValuesArray, let last = series.last {
            bodyBatteryCurrent = last.last ?? nil // 当日最新值
        }
    }

    mutating func applyStress(_ response: GarminStressResponse) {
        stressAvg = response.avgStressLevel
        stressMax = response.maxStressLevel
    }

    mutating func applySleep(_ response: GarminSleepResponse) {
        guard let sleep = response.dailySleepDTO else { return }
        if let seconds = sleep.sleepTimeSeconds { sleepTotalMin = Double(seconds) / 60 }
        if let seconds = sleep.deepSleepSeconds { deepSleepMin = Double(seconds) / 60 }
        if let seconds = sleep.lightSleepSeconds { lightSleepMin = Double(seconds) / 60 }
        if let seconds = sleep.remSleepSeconds { remSleepMin = Double(seconds) / 60 }
        sleepScore = sleep.sleepScores?.overall?.value
        avgSleepStress = sleep.avgSleepStress
    }

    mutating func applySummary(_ response: GarminSummaryResponse) {
        restingHeartRate = response.restingHeartRate
        steps = response.totalSteps
        activeKcal = response.activeKilocalories
        restingKcal = response.bmrKilocalories
    }
}

// MARK: - 数据客户端

/// Garmin 中国区数据客户端（connectapi.garmin.cn，Bearer 认证）。
/// 单次 fetchDaily 共 5 个数据请求 + 可能的 1 次 token 刷新；每项独立容错。
@MainActor
final class GarminDataClient {
    private let auth: GarminAuthService
    private let session: URLSession

    init(auth: GarminAuthService, session: URLSession = GarminDataClient.makeSession()) {
        self.auth = auth
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }

    // MARK: 端点路径

    nonisolated static func hrvPath(_ day: String) -> String { "/wellness-service/wellness/hrv/\(day)" }
    nonisolated static func bodyBatteryPath(_ day: String) -> String { "/wellness-service/wellness/bodyBattery/\(day)" }
    nonisolated static func stressPath(_ day: String) -> String { "/wellness-service/wellness/stress/\(day)" }
    nonisolated static func sleepPath(_ day: String) -> String { "/wellness-service/wellness/nightlySleep/\(day)" }
    nonisolated static func summaryPath(_ day: String) -> String { "/usersummary-service/usersummary/daily/\(day)" }

    /// 本地日历下的 yyyy-MM-dd
    nonisolated static func dateString(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    // MARK: 拉取

    /// 依次拉取 HRV / 身体电量 / 压力 / 睡眠 / 每日摘要，每项独立容错（失败字段置 nil 并记录错误摘要）
    @discardableResult
    func fetchDaily(date: Date) async throws -> GarminDailyData {
        let day = Self.dateString(for: date)
        var data = GarminDailyData()
        var errors: [String] = []
        let decoder = JSONDecoder()

        do {
            let payload = try await fetchJSON(path: Self.hrvPath(day))
            data.applyHRV(try decoder.decode(GarminHRVResponse.self, from: payload))
        } catch { errors.append("HRV: \(Self.errorSummary(error))") }

        do {
            let payload = try await fetchJSON(path: Self.bodyBatteryPath(day))
            data.applyBodyBattery(try decoder.decode([GarminBodyBatteryDay].self, from: payload))
        } catch { errors.append("身体电量: \(Self.errorSummary(error))") }

        do {
            let payload = try await fetchJSON(path: Self.stressPath(day))
            data.applyStress(try decoder.decode(GarminStressResponse.self, from: payload))
        } catch { errors.append("压力: \(Self.errorSummary(error))") }

        do {
            let payload = try await fetchJSON(path: Self.sleepPath(day))
            data.applySleep(try decoder.decode(GarminSleepResponse.self, from: payload))
        } catch { errors.append("睡眠: \(Self.errorSummary(error))") }

        do {
            let payload = try await fetchJSON(path: Self.summaryPath(day))
            data.applySummary(try decoder.decode(GarminSummaryResponse.self, from: payload))
        } catch { errors.append("每日摘要: \(Self.errorSummary(error))") }

        if !errors.isEmpty { data.errors = errors }
        return data
    }

    /// 带认证的 GET；401 时刷新一次 token 并重试该请求（只重试一次）
    private func fetchJSON(path: String) async throws -> Data {
        let token = try await auth.currentAccessToken()
        var response = try await Self.authorizedGet(path: path, token: token, session: session)
        if response.status == 401 {
            let refreshed = try await auth.forceRefreshAccessToken()
            response = try await Self.authorizedGet(path: path, token: refreshed, session: session)
        }
        guard response.status == 200 else {
            throw GarminAuthError.other("数据请求失败（HTTP \(response.status)）")
        }
        return response.body
    }

    nonisolated static func authorizedGet(path: String, token: String, session: URLSession) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: GarminAPI.connectAPIBase + path) else {
            throw GarminAuthError.other("URL 构造失败")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(GarminAPI.uaData, forHTTPHeaderField: "User-Agent")
        do {
            let (data, urlResponse) = try await session.data(for: request)
            return ((urlResponse as? HTTPURLResponse)?.statusCode ?? -1, data)
        } catch {
            throw GarminAuthError.network(error.localizedDescription)
        }
    }

    /// 错误摘要（截断到 120 字符）
    nonisolated static func errorSummary(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return raw.count > 120 ? String(raw.prefix(120)) + "…" : raw
    }
}
