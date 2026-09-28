import XCTest
@testable import FoodJournal

// MARK: - OAuth1 签名 / percent 编码

final class GarminOAuth1SignerTests: XCTestCase {
    /// RFC 3986 percent 编码边界：空格、~、中文、: /、保留字符集
    func testRFC3986EncodeEdgeCases() {
        XCTAssertEqual(GarminOAuth1Signer.rfc3986Encode("Hello Ladies + Gentlemen"), "Hello%20Ladies%20%2B%20Gentlemen")
        XCTAssertEqual(GarminOAuth1Signer.rfc3986Encode("~"), "~")
        XCTAssertEqual(GarminOAuth1Signer.rfc3986Encode("-._~09AZaz"), "-._~09AZaz")
        XCTAssertEqual(GarminOAuth1Signer.rfc3986Encode("中文"), "%E4%B8%AD%E6%96%87")
        XCTAssertEqual(GarminOAuth1Signer.rfc3986Encode("a/b:c"), "a%2Fb%3Ac")
    }

    /// OAuth 1.0a HMAC-SHA1 确定性签名：RFC 5849 官方文档风格的固定测试向量
    /// （Twitter 官方 OAuth 文档的经典用例，与刺探实现同一套构造规则）
    func testOAuth1SignatureKnownVector() {
        let consumerKey = "xvz1evFS4wEEPTGEFPHBog"
        let consumerSecret = "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw"
        let token = "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb"
        let tokenSecret = "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE"
        let nonce = "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg"
        let timestamp = "1318622958"
        let url = "https://api.twitter.com/1.1/statuses/update.json"
        let params = [
            "include_entities": "true",
            "status": "Hello Ladies + Gentlemen, a signed OAuth request!",
        ]

        var oauth: [String: String] = [
            "oauth_consumer_key": consumerKey,
            "oauth_nonce": nonce,
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": timestamp,
            "oauth_version": "1.0",
            "oauth_token": token,
        ]
        let all = params.merging(oauth) { current, _ in current }
        let base = GarminOAuth1Signer.baseString(
            method: "POST", url: url, paramString: GarminOAuth1Signer.normalizedParamString(all)
        )
        let signature = GarminOAuth1Signer.signature(baseString: base, consumerSecret: consumerSecret, tokenSecret: tokenSecret)
        XCTAssertEqual(signature, "hCtSmYh+iHYCEqBWrE7C7hYmtUk=")

        // authorizationHeader 同输入应产出含同一签名的确定性头
        let header = GarminOAuth1Signer.authorizationHeader(
            method: "POST", url: url, requestParams: params,
            consumerKey: consumerKey, consumerSecret: consumerSecret,
            token: token, tokenSecret: tokenSecret,
            timestamp: timestamp, nonce: nonce
        )
        XCTAssertTrue(header.hasPrefix("OAuth "))
        XCTAssertTrue(header.contains("oauth_signature=\"\(GarminOAuth1Signer.rfc3986Encode(signature))\""))
        // 同输入再次生成，结果完全一致（确定性）
        let header2 = GarminOAuth1Signer.authorizationHeader(
            method: "POST", url: url, requestParams: params,
            consumerKey: consumerKey, consumerSecret: consumerSecret,
            token: token, tokenSecret: tokenSecret,
            timestamp: timestamp, nonce: nonce
        )
        XCTAssertEqual(header, header2)
    }

    /// base string 构造：URL 不含 query；method 大写；三层编码
    func testBaseStringConstruction() {
        let base = GarminOAuth1Signer.baseString(
            method: "get", url: "https://api.example.com/path?x=1", paramString: "a=b"
        )
        XCTAssertEqual(base, "GET&https%3A%2F%2Fapi.example.com%2Fpath&a%3Db")
    }
}

// MARK: - OAuth2 刷新判定

/// OAuth2 兑换假实现（记录调用次数，不打真实网络）
private final class MockExchanger: GarminOAuth2Exchanging, @unchecked Sendable {
    var callCount = 0
    func exchange(oauth1Token: String, oauth1Secret: String, mfaToken: String?, includeAudience: Bool) async throws -> GarminOAuth2ExchangeResult {
        callCount += 1
        return GarminOAuth2ExchangeResult(accessToken: "refreshed-access", refreshToken: "refreshed-refresh", expiresIn: 81944)
    }
}

@MainActor
final class GarminRefreshTests: XCTestCase {
    /// 测试用独立 service 名，不触碰真实 token
    private let store = GarminTokenStore(service: "com.pigeon.foodjournal.garmin.test")

    private func makeTokens(expiresIn: TimeInterval, now: Date) -> GarminTokens {
        GarminTokens(
            oauth1Token: "oauth1-token", oauth1Secret: "oauth1-secret",
            accessToken: "access", refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(expiresIn)
        )
    }

    func testNeedsRefreshBoundaries() {
        let now = Date()
        // 未过期（1h / 距过期 10 分 1 秒）不刷新
        XCTAssertFalse(GarminAuthService.needsRefresh(expiresAt: now.addingTimeInterval(3600), now: now))
        XCTAssertFalse(GarminAuthService.needsRefresh(expiresAt: now.addingTimeInterval(601), now: now))
        // 距过期 9 分钟 → 刷新；已过期 → 刷新
        XCTAssertTrue(GarminAuthService.needsRefresh(expiresAt: now.addingTimeInterval(540), now: now))
        XCTAssertTrue(GarminAuthService.needsRefresh(expiresAt: now.addingTimeInterval(-1), now: now))
    }

    func testRefreshSkippedWhenFresh() async throws {
        let exchanger = MockExchanger()
        let service = GarminAuthService(tokenStore: store, exchanger: exchanger)
        let tokens = makeTokens(expiresIn: 3600, now: Date())
        let result = try await service.refreshOAuth2IfNeeded(tokens: tokens)
        XCTAssertEqual(result, tokens)
        XCTAssertEqual(exchanger.callCount, 0)
    }

    func testRefreshTriggeredWhenExpiringIn9Minutes() async throws {
        let exchanger = MockExchanger()
        let service = GarminAuthService(tokenStore: store, exchanger: exchanger)
        let tokens = makeTokens(expiresIn: 540, now: Date())
        let result = try await service.refreshOAuth2IfNeeded(tokens: tokens)
        XCTAssertEqual(exchanger.callCount, 1)
        XCTAssertEqual(result.accessToken, "refreshed-access")
        XCTAssertEqual(result.refreshToken, "refreshed-refresh")
        // OAuth1 token/secret 保持不变（长期有效，可无密码换新 OAuth2）
        XCTAssertEqual(result.oauth1Token, tokens.oauth1Token)
        XCTAssertEqual(result.oauth1Secret, tokens.oauth1Secret)
    }

    func testRefreshTriggeredWhenExpired() async throws {
        let exchanger = MockExchanger()
        let service = GarminAuthService(tokenStore: store, exchanger: exchanger)
        let tokens = makeTokens(expiresIn: -10, now: Date())
        _ = try await service.refreshOAuth2IfNeeded(tokens: tokens)
        XCTAssertEqual(exchanger.callCount, 1)
    }

    func testIsLoggedInAndLogout() async throws {
        let service = GarminAuthService(tokenStore: store, exchanger: MockExchanger())
        store.deleteAll()
        XCTAssertFalse(service.isLoggedIn)
        store.deleteAll()
        defer { store.deleteAll() }
        // 只存一半不算登录
        try store.saveOAuth1(.init(token: "t", secret: "s"))
        XCTAssertFalse(service.isLoggedIn)
        try store.saveOAuth2(.init(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)))
        XCTAssertTrue(service.isLoggedIn)
        service.logout()
        XCTAssertFalse(service.isLoggedIn)
        XCTAssertNil(store.loadOAuth1())
        XCTAssertNil(store.loadOAuth2())
    }
}

// MARK: - Keychain round-trip

final class GarminTokenStoreTests: XCTestCase {
    private let store = GarminTokenStore(service: "com.pigeon.foodjournal.garmin.test")

    override func setUp() {
        super.setUp()
        store.deleteAll()
    }

    override func tearDown() {
        store.deleteAll()
        super.tearDown()
    }

    func testRoundTrip() throws {
        XCTAssertNil(store.loadOAuth1())
        XCTAssertNil(store.loadOAuth2())

        // OAuth1 存取与覆盖
        try store.saveOAuth1(.init(token: "oauth1-token", secret: "oauth1-secret"))
        XCTAssertEqual(store.loadOAuth1(), .init(token: "oauth1-token", secret: "oauth1-secret"))
        try store.saveOAuth1(.init(token: "oauth1-token-2", secret: "oauth1-secret-2"))
        XCTAssertEqual(store.loadOAuth1()?.token, "oauth1-token-2")

        // OAuth2 存取与覆盖（expiresAt 经 JSON Data round-trip 保留精度）
        let expiresAt = Date(timeIntervalSince1970: 1_790_000_000.125)
        try store.saveOAuth2(.init(accessToken: "access", refreshToken: "refresh", expiresAt: expiresAt))
        XCTAssertEqual(store.loadOAuth2(), .init(accessToken: "access", refreshToken: "refresh", expiresAt: expiresAt))
        try store.saveOAuth2(.init(accessToken: "access-2", refreshToken: "refresh-2", expiresAt: expiresAt))
        XCTAssertEqual(store.loadOAuth2()?.accessToken, "access-2")

        // 组合读取
        let combined = store.loadTokens()
        XCTAssertEqual(combined?.oauth1Token, "oauth1-token-2")
        XCTAssertEqual(combined?.accessToken, "access-2")

        // 清除
        store.deleteAll()
        XCTAssertNil(store.loadOAuth1())
        XCTAssertNil(store.loadOAuth2())
        XCTAssertNil(store.loadTokens())
    }

    /// 日志脱敏：只露前 8 位 + 长度
    func testMasked() {
        XCTAssertEqual(GarminTokenStore.masked("short"), "<len=5>")
        XCTAssertEqual(GarminTokenStore.masked("123456789ABC"), "12345678…(len=12)")
    }
}

// MARK: - DTO 解析（样例结构对照 docs/r55_garmin_results.json 的数值字段，不含任何个人信息）

final class GarminDTOTests: XCTestCase {
    func testDailyDataParsing() throws {
        let decoder = JSONDecoder()

        let hrvJSON = #"{"hrvSummary":{"lastNightAvg":36,"weeklyAvg":49,"baseline":{"balancedLow":44,"balancedUpper":58},"status":"BALANCED"}}"#
        let batteryJSON = #"[{"charged":33,"drained":30,"bodyBatteryValuesArray":[[1790530200000,5],[1790545140000,11]]}]"#
        let stressJSON = #"{"avgStressLevel":34,"maxStressLevel":98}"#
        let sleepJSON = #"{"dailySleepDTO":{"sleepTimeSeconds":12840,"deepSleepSeconds":5880,"lightSleepSeconds":6000,"remSleepSeconds":960,"avgSleepStress":21.0,"sleepScores":{"overall":{"value":45}}}}"#
        let summaryJSON = #"{"totalSteps":3938,"activeKilocalories":248.0,"bmrKilocalories":1748.0,"restingHeartRate":57}"#

        var data = GarminDailyData()
        data.applyHRV(try decoder.decode(GarminHRVResponse.self, from: Data(hrvJSON.utf8)))
        data.applyBodyBattery(try decoder.decode([GarminBodyBatteryDay].self, from: Data(batteryJSON.utf8)))
        data.applyStress(try decoder.decode(GarminStressResponse.self, from: Data(stressJSON.utf8)))
        data.applySleep(try decoder.decode(GarminSleepResponse.self, from: Data(sleepJSON.utf8)))
        data.applySummary(try decoder.decode(GarminSummaryResponse.self, from: Data(summaryJSON.utf8)))

        // HRV
        XCTAssertEqual(data.hrvLastNightAvg, 36)
        XCTAssertEqual(data.hrvWeeklyAvg, 49)
        XCTAssertEqual(data.hrvBaselineLow, 44)
        XCTAssertEqual(data.hrvBaselineHigh, 58)
        XCTAssertEqual(data.hrvStatus, "BALANCED")
        // 身体电量（current 取当日最新值 = 数组最后一个）
        XCTAssertEqual(data.bodyBatteryCharged, 33)
        XCTAssertEqual(data.bodyBatteryDrained, 30)
        XCTAssertEqual(data.bodyBatteryCurrent, 11)
        // 压力
        XCTAssertEqual(data.stressAvg, 34)
        XCTAssertEqual(data.stressMax, 98)
        // 睡眠（秒 → 分钟）
        XCTAssertEqual(data.sleepTotalMin, 214)
        XCTAssertEqual(data.deepSleepMin, 98)
        XCTAssertEqual(data.lightSleepMin, 100)
        XCTAssertEqual(data.remSleepMin, 16)
        XCTAssertEqual(data.sleepScore, 45)
        XCTAssertEqual(data.avgSleepStress, 21.0)
        // 摘要
        XCTAssertEqual(data.restingHeartRate, 57)
        XCTAssertEqual(data.steps, 3938)
        XCTAssertEqual(data.activeKcal, 248.0)
        XCTAssertEqual(data.restingKcal, 1748.0)
        XCTAssertNil(data.errors)

        // Codable round-trip
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(GarminDailyData.self, from: encoded)
        XCTAssertEqual(decoded, data)
    }

    /// 日期格式化：yyyy-MM-dd（本地日历）
    func testDateString() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = Date(timeIntervalSince1970: 1_790_524_800) // 2026-09-28 00:00 UTC → 上海 08:00
        XCTAssertEqual(GarminDataClient.dateString(for: date, calendar: calendar), "2026-09-28")
    }

    /// 端点路径
    func testEndpointPaths() {
        XCTAssertEqual(GarminDataClient.hrvPath("2026-09-28"), "/wellness-service/wellness/hrv/2026-09-28")
        XCTAssertEqual(GarminDataClient.bodyBatteryPath("2026-09-28"), "/wellness-service/wellness/bodyBattery/2026-09-28")
        XCTAssertEqual(GarminDataClient.stressPath("2026-09-28"), "/wellness-service/wellness/stress/2026-09-28")
        XCTAssertEqual(GarminDataClient.sleepPath("2026-09-28"), "/wellness-service/wellness/nightlySleep/2026-09-28")
        XCTAssertEqual(GarminDataClient.summaryPath("2026-09-28"), "/usersummary-service/usersummary/daily/2026-09-28")
    }
}
