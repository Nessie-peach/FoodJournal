import Foundation
import CryptoKit

// MARK: - Garmin 常量（照 E2S 刺探验证过的值）

/// Garmin 中国区端点 / UA / client 常量（来源：docs/E2S-登录流程规格.md，已实测调通）
enum GarminAPI {
    static let clientId = "GCM_ANDROID_DARK"
    static let serviceURL = "https://mobile.integration.garmin.cn/gcm/android"
    static let ssoBase = "https://sso.garmin.cn"
    static let connectAPIBase = "https://connectapi.garmin.cn"

    /// SSO 页面用 iPhone WebView UA（避免 Cloudflare 挑战）
    static let uaSSO = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    /// OAuth 接口 UA（须与 S3 里的 Android consumer key 匹配）
    static let uaOAuth = "com.garmin.android.apps.connectmobile"
    /// 数据接口 UA
    static let uaData = "GCM-iOS-5.22.1.4"

    /// 登录场景 exchange 的 audience
    static let oauthAudience = "GARMIN_CONNECT_MOBILE_ANDROID_DI"

    /// OAuth2 access_token 兜底有效期（实测 expires_in≈81944s ≈ 22.7h）
    static let defaultExpiresIn = 81944
}

// MARK: - 错误分类（中文可读）

/// Garmin 登录/刷新错误
enum GarminAuthError: Error, LocalizedError, Equatable {
    /// 网络失败（超时、断网、DNS 等）
    case network(String)
    /// 账号或密码错误（SSO 返回非 SUCCESSFUL/MFA 的失败标志）
    case invalidCredentials(String)
    /// 被风控或需验证码（MFA_REQUIRED / Cloudflare 拦截等），建议稍后再试或先用浏览器登录一次
    case challenge(String)
    /// 尚未登录（Keychain 中无 token）
    case notLoggedIn
    /// 其它未归类错误
    case other(String)

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "网络连接失败，请检查网络后重试。（\(detail)）"
        case .invalidCredentials(let detail):
            return "邮箱或密码不正确，请检查后重试。（\(detail)）"
        case .challenge:
            return "登录被临时限制或需要验证码，请稍后再试；若多次失败，可先用浏览器登录一次 Garmin 官网再回来重试。"
        case .notLoggedIn:
            return "尚未登录 Garmin 账号。"
        case .other(let detail):
            return "Garmin 请求遇到未知问题。（\(detail)）"
        }
    }
}

// MARK: - Token 模型

/// 完整 token 集合：OAuth1（长期有效，可无密码换新 OAuth2）+ OAuth2（约 22.7h）
struct GarminTokens: Codable, Equatable, Sendable {
    var oauth1Token: String
    var oauth1Secret: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

// MARK: - Consumer 凭据（运行时从 garth 社区镜像 S3 拉取，进程内缓存）

struct GarminConsumerCredentials: Codable, Equatable, Sendable {
    let consumerKey: String
    let consumerSecret: String

    private enum CodingKeys: String, CodingKey {
        case consumerKey = "consumer_key"
        case consumerSecret = "consumer_secret"
    }
}

actor GarminConsumerStore {
    static let shared = GarminConsumerStore()

    private var cached: GarminConsumerCredentials?

    func credentials() async throws -> GarminConsumerCredentials {
        if let cached { return cached }
        var request = URLRequest(url: URL(string: "https://thegarth.s3.amazonaws.com/oauth_consumer.json")!)
        request.setValue(GarminAPI.uaData, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GarminAuthError.other("获取 consumer 凭据失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）")
            }
            let credentials = try JSONDecoder().decode(GarminConsumerCredentials.self, from: data)
            cached = credentials
            return credentials
        } catch let error as GarminAuthError {
            throw error
        } catch {
            throw GarminAuthError.network(error.localizedDescription)
        }
    }
}

// MARK: - OAuth2 兑换抽象（测试可注入假实现）

struct GarminOAuth2ExchangeResult: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

protocol GarminOAuth2Exchanging: Sendable {
    /// 用 OAuth1 token 走 exchange 换新 OAuth2；登录场景带 audience，刷新场景不带
    func exchange(oauth1Token: String, oauth1Secret: String, mfaToken: String?, includeAudience: Bool) async throws -> GarminOAuth2ExchangeResult
}

/// 默认实现：connectapi.garmin.cn/oauth-service/oauth/exchange/user/2.0（OAuth1 签名）
final class GarminOAuth2Exchanger: GarminOAuth2Exchanging {
    private let session: URLSession
    private let consumerStore: GarminConsumerStore

    init(session: URLSession = GarminOAuth2Exchanger.makeSession(), consumerStore: GarminConsumerStore = .shared) {
        self.session = session
        self.consumerStore = consumerStore
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }

    func exchange(oauth1Token: String, oauth1Secret: String, mfaToken: String?, includeAudience: Bool) async throws -> GarminOAuth2ExchangeResult {
        let consumer = try await consumerStore.credentials()
        let url = "\(GarminAPI.connectAPIBase)/oauth-service/oauth/exchange/user/2.0"
        var params: [String: String] = [:]
        if includeAudience { params["audience"] = GarminAPI.oauthAudience }
        if let mfaToken, !mfaToken.isEmpty { params["mfa_token"] = mfaToken }
        let body = params
            .map { "\(GarminOAuth1Signer.rfc3986Encode($0.key))=\(GarminOAuth1Signer.rfc3986Encode($0.value))" }
            .joined(separator: "&")
        let authorization = GarminOAuth1Signer.authorizationHeader(
            method: "POST", url: url, requestParams: params,
            consumerKey: consumer.consumerKey, consumerSecret: consumer.consumerSecret,
            token: oauth1Token, tokenSecret: oauth1Secret
        )
        let response = try await GarminAuthService.http(
            method: "POST", url: url,
            headers: [
                "Authorization": authorization,
                "User-Agent": GarminAPI.uaOAuth,
                "Content-Type": "application/x-www-form-urlencoded",
            ],
            body: Data(body.utf8), session: session
        )
        guard response.status == 200 else {
            throw GarminAuthError.other("OAuth2 兑换失败（HTTP \(response.status)）")
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw GarminAuthError.other("OAuth2 兑换响应解析失败")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.intValue ?? GarminAPI.defaultExpiresIn
        return GarminOAuth2ExchangeResult(accessToken: access, refreshToken: refresh, expiresIn: expiresIn)
    }
}

// MARK: - 认证服务

/// Garmin 登录 / token 刷新服务（照 E2S 刺探验证过的 5 步 SSO 流程移植）。
/// Cookie 全程共享 HTTPCookieStorage（URLSessionConfiguration.default 的默认行为）。
@MainActor
final class GarminAuthService {
    private let tokenStore: GarminTokenStore
    private let session: URLSession
    private let exchanger: any GarminOAuth2Exchanging
    private let consumerStore: GarminConsumerStore

    init(tokenStore: GarminTokenStore = .shared, exchanger: (any GarminOAuth2Exchanging)? = nil) {
        self.tokenStore = tokenStore
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: config)
        self.exchanger = exchanger ?? GarminOAuth2Exchanger()
        self.consumerStore = .shared
    }

    /// 是否已登录（Keychain 中同时有 OAuth1 与 OAuth2 token）
    var isLoggedIn: Bool { tokenStore.loadTokens() != nil }

    /// 退出登录（清除 Keychain 中的全部 Garmin token）
    func logout() { tokenStore.deleteAll() }

    // MARK: 登录（5 步 SSO）

    /// 5 步 SSO 登录：种 cookie → POST 拿 ticket → embed 种 CF cookie → ticket 换 OAuth1 → OAuth1 换 OAuth2
    @discardableResult
    func login(email: String, password: String) async throws -> GarminTokens {
        let consumer = try await consumerStore.credentials()

        // Step 1：SSO 登录页（唯一目的是种 cookie，不解析 HTML）
        let step1URL = "\(GarminAPI.ssoBase)/mobile/sso/en/sign-in?clientId=\(GarminAPI.clientId)"
        let step1 = try await Self.http(method: "GET", url: step1URL, headers: Self.ssoPageHeaders(site: "none"), body: nil, session: session)
        if Self.isCFSuspect(step1) { throw GarminAuthError.challenge("SSO 页面被拦截") }
        guard (200..<300).contains(step1.status) else {
            throw GarminAuthError.other("SSO 登录页请求失败（HTTP \(step1.status)）")
        }

        // 人类化延迟（GET→POST 间隔过短易被 CF 判定为机器人）
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Step 2：登录 POST → serviceTicketId
        let encodedService = GarminOAuth1Signer.rfc3986Encode(GarminAPI.serviceURL)
        let loginURL = "\(GarminAPI.ssoBase)/mobile/api/login?clientId=\(GarminAPI.clientId)&locale=en-US&service=\(encodedService)"
        let loginBody = try JSONSerialization.data(withJSONObject: [
            "username": email, "password": password, "rememberMe": false, "captchaToken": "",
        ])
        var step2Headers = Self.ssoPageHeaders()
        step2Headers["Content-Type"] = "application/json"
        var step2 = try await Self.http(method: "POST", url: loginURL, headers: step2Headers, body: loginBody, session: session)
        if Self.isCFSuspect(step2) {
            // 疑似 Cloudflare 拦截：换数据接口 UA 重试一次
            step2Headers["User-Agent"] = GarminAPI.uaData
            step2 = try await Self.http(method: "POST", url: loginURL, headers: step2Headers, body: loginBody, session: session)
        }
        guard let json2 = try? JSONSerialization.jsonObject(with: step2.body) as? [String: Any] else {
            throw GarminAuthError.other("登录响应格式异常（HTTP \(step2.status)）")
        }
        let status2 = json2["responseStatus"] as? [String: Any]
        let type2 = status2?["type"] as? String ?? "UNKNOWN"
        let message2 = status2?["message"] as? String ?? ""
        guard type2 == "SUCCESSFUL", let ticket = json2["serviceTicketId"] as? String else {
            if type2 == "MFA_REQUIRED" { throw GarminAuthError.challenge("MFA_REQUIRED") }
            throw GarminAuthError.invalidCredentials("\(type2): \(message2)")
        }

        // Step 2c：embed 页种 Cloudflare LB cookie（best-effort，失败不阻断）
        var embedHeaders = Self.ssoPageHeaders(site: "same-origin")
        if let referer = step2.finalURL?.absoluteString { embedHeaders["Referer"] = referer }
        _ = try? await Self.http(method: "GET", url: "\(GarminAPI.ssoBase)/portal/sso/embed", headers: embedHeaders, body: nil, session: session)

        // Step 3：ticket → OAuth1（preauthorized，OAuth1 无 token 签名，响应为 text/plain urlencoded kv）
        let preParams = ["ticket": ticket, "login-url": GarminAPI.serviceURL, "accepts-mfa-tokens": "true"]
        let preQS = preParams
            .map { "\(GarminOAuth1Signer.rfc3986Encode($0.key))=\(GarminOAuth1Signer.rfc3986Encode($0.value))" }
            .joined(separator: "&")
        let preURL = "\(GarminAPI.connectAPIBase)/oauth-service/oauth/preauthorized?\(preQS)"
        let preAuth = GarminOAuth1Signer.authorizationHeader(
            method: "GET", url: preURL, requestParams: preParams,
            consumerKey: consumer.consumerKey, consumerSecret: consumer.consumerSecret,
            token: nil, tokenSecret: ""
        )
        let step3 = try await Self.http(method: "GET", url: preURL, headers: ["Authorization": preAuth, "User-Agent": GarminAPI.uaOAuth], body: nil, session: session)
        guard step3.status == 200 else {
            throw GarminAuthError.other("OAuth1 token 获取失败（HTTP \(step3.status)）")
        }
        var oauth1Token = "", oauth1Secret = "", mfaToken = ""
        let step3Text = String(data: step3.body, encoding: .utf8) ?? ""
        for pair in step3Text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[0]
            let value = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
            switch key {
            case "oauth_token": oauth1Token = value
            case "oauth_token_secret": oauth1Secret = value
            case "mfa_token": mfaToken = value
            default: break
            }
        }
        guard !oauth1Token.isEmpty, !oauth1Secret.isEmpty else {
            throw GarminAuthError.other("OAuth1 响应缺少 token 字段")
        }

        // Step 4：OAuth1 → OAuth2（登录场景带 audience）
        let result = try await exchanger.exchange(
            oauth1Token: oauth1Token, oauth1Secret: oauth1Secret,
            mfaToken: mfaToken.isEmpty ? nil : mfaToken, includeAudience: true
        )

        let tokens = GarminTokens(
            oauth1Token: oauth1Token, oauth1Secret: oauth1Secret,
            accessToken: result.accessToken, refreshToken: result.refreshToken,
            expiresAt: Date().addingTimeInterval(Double(result.expiresIn > 0 ? result.expiresIn : GarminAPI.defaultExpiresIn))
        )
        try tokenStore.saveOAuth1(GarminTokenStore.OAuth1Tokens(token: tokens.oauth1Token, secret: tokens.oauth1Secret))
        try tokenStore.saveOAuth2(GarminTokenStore.OAuth2Tokens(
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt
        ))
        return tokens
    }

    // MARK: OAuth2 刷新

    /// access_token 过期判定：距过期不足 margin（默认 10 分钟）即需刷新
    nonisolated static func needsRefresh(expiresAt: Date, now: Date = Date(), margin: TimeInterval = 600) -> Bool {
        expiresAt.timeIntervalSince(now) < margin
    }

    /// access_token 过期（或距过期 <10 分钟）时用 OAuth1 走 exchange 换新；未过期直接返回
    @discardableResult
    func refreshOAuth2IfNeeded(tokens: GarminTokens, now: Date = Date()) async throws -> GarminTokens {
        guard Self.needsRefresh(expiresAt: tokens.expiresAt, now: now) else { return tokens }
        return try await exchangeAndPersist(tokens)
    }

    /// 返回当前可用的 access_token（必要时先刷新）；供数据客户端使用
    func currentAccessToken() async throws -> String {
        guard let tokens = tokenStore.loadTokens() else { throw GarminAuthError.notLoggedIn }
        let refreshed = try await refreshOAuth2IfNeeded(tokens: tokens)
        return refreshed.accessToken
    }

    /// 强制刷新一次 access_token（数据请求 401 重试前调用）
    func forceRefreshAccessToken() async throws -> String {
        guard let tokens = tokenStore.loadTokens() else { throw GarminAuthError.notLoggedIn }
        return try await exchangeAndPersist(tokens).accessToken
    }

    private func exchangeAndPersist(_ tokens: GarminTokens) async throws -> GarminTokens {
        let result = try await exchanger.exchange(
            oauth1Token: tokens.oauth1Token, oauth1Secret: tokens.oauth1Secret,
            mfaToken: nil, includeAudience: false
        )
        var updated = tokens
        updated.accessToken = result.accessToken
        updated.refreshToken = result.refreshToken
        updated.expiresAt = Date().addingTimeInterval(Double(result.expiresIn > 0 ? result.expiresIn : GarminAPI.defaultExpiresIn))
        try? tokenStore.saveOAuth2(GarminTokenStore.OAuth2Tokens(
            accessToken: updated.accessToken, refreshToken: updated.refreshToken, expiresAt: updated.expiresAt
        ))
        return updated
    }

    // MARK: HTTP 基础设施（nonisolated 纯函数，便于复用）

    struct HTTPResponse: Sendable {
        let status: Int
        let headers: [String: String] // key 已小写
        let body: Data
        let finalURL: URL?
    }

    /// SSO 页面浏览器式请求头（避免 Cloudflare 挑战）
    nonisolated static func ssoPageHeaders(site: String? = nil, referer: String? = nil) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": GarminAPI.uaSSO,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Dest": "document",
        ]
        if let site { headers["Sec-Fetch-Site"] = site }
        if let referer { headers["Referer"] = referer }
        return headers
    }

    /// Cloudflare 拦截特征判断
    nonisolated static func isCFSuspect(_ response: HTTPResponse) -> Bool {
        if let value = response.headers["cf-mitigated"], value.lowercased().contains("challenge") { return true }
        if response.status == 403 { return true }
        if response.status == 503, let text = String(data: response.body, encoding: .utf8),
           text.lowercased().contains("cloudflare") { return true }
        return false
    }

    nonisolated static func http(method: String, url: String, headers: [String: String], body: Data?, session: URLSession) async throws -> HTTPResponse {
        guard let requestURL = URL(string: url) else { throw GarminAuthError.other("URL 构造失败") }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        do {
            let (data, urlResponse) = try await session.data(for: request)
            let http = urlResponse as? HTTPURLResponse
            var lowered: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] { lowered["\(key)".lowercased()] = "\(value)" }
            return HTTPResponse(status: http?.statusCode ?? -1, headers: lowered, body: data, finalURL: http?.url)
        } catch {
            throw GarminAuthError.network(error.localizedDescription)
        }
    }
}
