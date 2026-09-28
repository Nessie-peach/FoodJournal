// E2S spike — Garmin 中国区 SSO 登录（纯 Swift / URLSession / macOS 单文件）
// 依据：docs/E2S-登录流程规格.md（garth 0.8.0 源码阅读产物）
// 密码仅从 macOS Keychain 读取，绝不打印、绝不落盘。

import Foundation
import CryptoKit

// MARK: - 常量（抄自规格 §0.1）

let ACCOUNT = "tonytao81@outlook.com"
let CLIENT_ID = "GCM_ANDROID_DARK"
let SERVICE_URL = "https://mobile.integration.garmin.cn/gcm/android"
let UA_SSO = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
let UA_OAUTH = "com.garmin.android.apps.connectmobile"
let UA_DATA = "GCM-iOS-5.22.1.4"

func ssoPageHeaders(site: String? = nil, referer: String? = nil) -> [String: String] {
    var h: [String: String] = [
        "User-Agent": UA_SSO,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Dest": "document",
    ]
    if let s = site { h["Sec-Fetch-Site"] = s }
    if let r = referer { h["Referer"] = r }
    return h
}

// MARK: - 工具

func rfc3986Encode(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

func formDecode(_ s: String) -> String {
    s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
}

func mask(_ s: String) -> String {
    s.count <= 8 ? "<len=\(s.count)>" : "\(String(s.prefix(8)))…(len=\(s.count))"
}

func bodyPrefix(_ d: Data, _ n: Int = 300) -> String {
    let t = String(data: d.prefix(n * 4), encoding: .utf8) ?? "<非文本>"
    return String(t.prefix(n)).replacingOccurrences(of: "\n", with: " ")
}

func isCFSuspect(_ status: Int, _ headers: [String: String], _ body: Data) -> Bool {
    if let v = headers["cf-mitigated"], v.lowercased().contains("challenge") { return true }
    if status == 403 { return true }
    if status == 503, let t = String(data: body, encoding: .utf8), t.lowercased().contains("cloudflare") { return true }
    return false
}

// MARK: - Keychain 密码（subprocess，stderr 吞掉，失败即退出）

func keychainPassword() -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", "dietapp-r5-garmin", "-w"]
    let out = Pipe(), err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do { try proc.run() } catch { print("FATAL: keychain subprocess 启动失败"); exit(1) }
    proc.waitUntilExit()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    _ = errData // 丢弃 stderr，避免任何回显
    guard proc.terminationStatus == 0,
          let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
        print("FATAL: keychain 读取失败（security 退出码 \(proc.terminationStatus)），不回显任何内容")
        exit(1)
    }
    return s
}

// MARK: - HTTP（禁自动重定向 + 手动跟随 + 记录 Location 链）

final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // 拦下自动重定向
    }
}

let session: URLSession = {
    let c = URLSessionConfiguration.default
    c.httpCookieStorage = HTTPCookieStorage.shared
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 90
    return URLSession(configuration: c, delegate: RedirectBlocker(), delegateQueue: nil)
}()

struct Resp {
    let status: Int
    let headers: [String: String] // key 小写
    let body: Data
    let finalURL: String
    var text: String { String(data: body, encoding: .utf8) ?? "" }
}

func rawOnce(_ method: String, _ urlStr: String, headers: [String: String], body: Data?) async -> (Resp?, String) {
    guard let url = URL(string: urlStr) else { return (nil, "URL 构造失败") }
    var req = URLRequest(url: url)
    req.httpMethod = method
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body
    do {
        let (data, urlResp) = try await session.data(for: req)
        guard let http = urlResp as? HTTPURLResponse else { return (nil, "非 HTTP 响应") }
        var hd: [String: String] = [:]
        for (k, v) in http.allHeaderFields { hd["\(k)".lowercased()] = "\(v)" }
        let resp = Resp(status: http.statusCode, headers: hd, body: data,
                        finalURL: http.url?.absoluteString ?? urlStr)
        return (resp, "")
    } catch {
        return (nil, "网络错误: \(error.localizedDescription)")
    }
}

/// 返回 (最终响应或 nil, 重定向/错误链)
func request(_ method: String, _ urlStr: String, headers: [String: String], body: Data?) async -> (Resp?, [String]) {
    var url = urlStr, m = method, b = body
    var chain: [String] = []
    for _ in 0...5 {
        let (respOpt, errMsg) = await rawOnce(m, url, headers: headers, body: b)
        guard let r = respOpt else {
            chain.append("ERROR: \(errMsg)")
            return (nil, chain)
        }
        if [301, 302, 303, 307, 308].contains(r.status), let loc = r.headers["location"] {
            chain.append("\(r.status) -> \(loc)")
            guard let abs = URL(string: loc, relativeTo: URL(string: url))?.absoluteString else {
                chain.append("Location 解析失败")
                return (nil, chain)
            }
            if r.status != 307 && r.status != 308 { m = "GET"; b = nil }
            url = abs
            continue
        }
        return (r, chain)
    }
    chain.append("重定向次数超限")
    return (nil, chain)
}

/// 带一次 CF 疑似拦截重试（换 Garmin Connect iOS 移动 UA）
func requestWithCFRetry(_ method: String, _ urlStr: String, headers: [String: String], body: Data?) async -> (Resp?, [String], String) {
    let (r1, c1) = await request(method, urlStr, headers: headers, body: body)
    var note = ""
    if let r1, isCFSuspect(r1.status, r1.headers, r1.body) {
        note += "疑似 CF 拦截(status=\(r1.status))，换 UA=\(UA_DATA) 重试一次；"
        var h2 = headers
        h2["User-Agent"] = UA_DATA
        let (r2, c2) = await request(method, urlStr, headers: h2, body: body)
        if let r2, !isCFSuspect(r2.status, r2.headers, r2.body) {
            note += "重试后 status=\(r2.status)（采用重试结果）"
            return (r2, c1 + ["[CF重试]"] + c2, note)
        }
        note += "重试后仍被拦截或失败"
    }
    return (r1, c1, note)
}

// MARK: - OAuth 1.0a HMAC-SHA1（规格 §8）

func oauthAuthHeader(method: String, urlStr: String, reqParams: [String: String],
                     consumerKey: String, consumerSecret: String,
                     token: String?, tokenSecret: String) -> String {
    let ts = String(Int(Date().timeIntervalSince1970))
    let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    var oauth: [String: String] = [
        "oauth_consumer_key": consumerKey,
        "oauth_nonce": nonce,
        "oauth_signature_method": "HMAC-SHA1",
        "oauth_timestamp": ts,
        "oauth_version": "1.0",
    ]
    if let t = token { oauth["oauth_token"] = t } else { oauth["oauth_callback"] = "oob" }
    let all = reqParams.merging(oauth) { a, _ in a }
    let pairs = all.map { (rfc3986Encode($0.key), rfc3986Encode($0.value)) }
        .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    let joined = pairs.map { "\($0.0)=\($0.1)" }
    let paramStr = joined.joined(separator: "&")
    let u = URL(string: urlStr)!
    let base = (u.scheme?.lowercased() ?? "https") + "://" + (u.host ?? "") + u.path
    let baseString = [method.uppercased(), rfc3986Encode(base), rfc3986Encode(paramStr)].joined(separator: "&")
    let keyStr = rfc3986Encode(consumerSecret) + "&" + rfc3986Encode(tokenSecret)
    let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(baseString.utf8),
                                                     using: SymmetricKey(data: Data(keyStr.utf8)))
    let sig = Data(mac).base64EncodedString()
    oauth["oauth_signature"] = sig
    let header = oauth.sorted { $0.key < $1.key }
        .map { "\(rfc3986Encode($0.key))=\"\(rfc3986Encode($0.value))\"" }
        .joined(separator: ", ")
    return "OAuth \(header)"
}

// MARK: - 主流程

func log(_ s: String) { print(s); fflush(stdout) }

func garminCookieCount() -> Int {
    HTTPCookieStorage.shared.cookies?.filter { $0.domain.contains("garmin") }.count ?? 0
}

func runFlow() async {
    log("=== E2S Garmin .cn SSO spike 开始 ===")

    // Step 0：consumer 凭据（运行时拉取，同 garth）
    log("Step 0 | GET https://thegarth.s3.amazonaws.com/oauth_consumer.json")
    let (r0, _) = await request("GET", "https://thegarth.s3.amazonaws.com/oauth_consumer.json",
                                headers: ["User-Agent": UA_DATA], body: nil)
    guard let r0, r0.status == 200,
          let j0 = try? JSONSerialization.jsonObject(with: r0.body) as? [String: String],
          let ck = j0["consumer_key"], let cs = j0["consumer_secret"] else {
        log("Step 0 失败 | status=\(r0?.status ?? -1) | body=\(r0.map { bodyPrefix($0.body) } ?? "nil")")
        exit(1)
    }
    log("Step 0 | \(r0.status) | consumer_key=\(mask(ck)) consumer_secret=\(mask(cs)) 提取成功")

    let password = keychainPassword()
    log("Keychain | 读取成功（内容不回显）")

    // Step 1：SSO 登录页，种 cookie
    log("Step 1 | GET https://sso.garmin.cn/mobile/sso/en/sign-in?clientId=\(CLIENT_ID)")
    let (r1, c1, n1) = await requestWithCFRetry(
        "GET", "https://sso.garmin.cn/mobile/sso/en/sign-in?clientId=\(CLIENT_ID)",
        headers: ssoPageHeaders(site: "none"), body: nil)
    if !n1.isEmpty { log("Step 1 备注 | \(n1)") }
    guard let r1 else { log("Step 1 失败 | chain=\(c1)"); exit(1) }
    log("Step 1 | \(r1.status) | bodyLen=\(r1.body.count) | garmin cookies=\(garminCookieCount()) | final=\(r1.finalURL)")

    // 人类化延迟（规格 §7.4：GET→POST 之间 1-3s 保险）
    try? await Task.sleep(nanoseconds: 1_500_000_000)

    // Step 2：登录 POST，拿 serviceTicketId（尝试 ≤2 次）
    let loginURL = "https://sso.garmin.cn/mobile/api/login?clientId=\(CLIENT_ID)&locale=en-US&service=\(rfc3986Encode(SERVICE_URL))"
    var ticket: String? = nil
    var step2Note = ""
    var attempt = 0
    var step2FinalURL: String? = nil
    while attempt < 2 {
        attempt += 1
        var h = ssoPageHeaders()
        h["Content-Type"] = "application/json"
        if attempt == 2 { h["User-Agent"] = UA_DATA; step2Note += "第 2 次尝试换移动 UA；" }
        let bodyData = try! JSONSerialization.data(withJSONObject:
            ["username": ACCOUNT, "password": password, "rememberMe": false, "captchaToken": ""])
        let (r2, c2) = await request("POST", loginURL, headers: h, body: bodyData)
        guard let r2 else { step2Note += "网络失败 chain=\(c2)；"; break }
        step2FinalURL = r2.finalURL
        log("Step 2 尝试\(attempt)/2 | POST \(loginURL) | \(r2.status) | redirects=\(c2.count)")
        if let j2 = try? JSONSerialization.jsonObject(with: r2.body) as? [String: Any] {
            let type = (j2["responseStatus"] as? [String: Any])?["type"] as? String ?? "UNKNOWN"
            let msg = (j2["responseStatus"] as? [String: Any])?["message"] as? String ?? ""
            if type == "SUCCESSFUL", let t = j2["serviceTicketId"] as? String {
                ticket = t
                log("Step 2 | SUCCESSFUL | serviceTicketId=\(mask(t)) 提取成功")
                break
            } else if type == "MFA_REQUIRED" {
                let mfaMethod = (j2["customerMfaInfo"] as? [String: Any])?["mfaLastMethodUsed"] as? String ?? "email"
                log("Step 2 | MFA_REQUIRED | mfaLastMethodUsed=\(mfaMethod) | 按红线要求如实记录并停止")
                exit(2)
            } else {
                step2Note += "type=\(type) message=\(msg) status=\(r2.status)；"
                if isCFSuspect(r2.status, r2.headers, r2.body) && attempt == 1 { continue }
                log("Step 2 失败 | \(step2Note) | body=\(bodyPrefix(r2.body))")
                break
            }
        } else {
            step2Note += "非 JSON 响应 status=\(r2.status)；"
            if isCFSuspect(r2.status, r2.headers, r2.body) && attempt == 1 { continue }
            log("Step 2 失败 | \(step2Note) | body=\(bodyPrefix(r2.body))")
            break
        }
    }
    guard let ticket else {
        log("Step 2 最终失败 | 尝试次数=\(attempt) | \(step2Note)")
        exit(1)
    }

    // Step 2c：embed 页种 CF LB cookie（best-effort）
    log("Step 2c | GET https://sso.garmin.cn/portal/sso/embed")
    var embedHeaders = ssoPageHeaders(site: "same-origin")
    if let u = step2FinalURL { embedHeaders["Referer"] = u }
    let (r2c, _, n2c) = await requestWithCFRetry("GET", "https://sso.garmin.cn/portal/sso/embed",
                                                 headers: embedHeaders, body: nil)
    if !n2c.isEmpty { log("Step 2c 备注 | \(n2c)") }
    if let r2c {
        log("Step 2c | \(r2c.status) | bodyLen=\(r2c.body.count) | garmin cookies=\(garminCookieCount())（best-effort，失败不阻断）")
    } else {
        log("Step 2c 失败（best-effort，继续）")
    }

    // Step 3：ticket → OAuth1（preauthorized）
    let preParams = ["ticket": ticket, "login-url": SERVICE_URL, "accepts-mfa-tokens": "true"]
    let preQS = preParams.map { "\(rfc3986Encode($0.key))=\(rfc3986Encode($0.value))" }.joined(separator: "&")
    let preURL = "https://connectapi.garmin.cn/oauth-service/oauth/preauthorized?\(preQS)"
    let preAuth = oauthAuthHeader(method: "GET", urlStr: preURL, reqParams: preParams,
                                  consumerKey: ck, consumerSecret: cs, token: nil, tokenSecret: "")
    log("Step 3 | GET connectapi.garmin.cn/oauth-service/oauth/preauthorized（OAuth1 签名，无 token）")
    let (r3, c3, n3) = await requestWithCFRetry("GET", preURL,
        headers: ["Authorization": preAuth, "User-Agent": UA_OAUTH], body: nil)
    if !n3.isEmpty { log("Step 3 备注 | \(n3)") }
    guard let r3, r3.status == 200 else {
        log("Step 3 失败 | status=\(r3?.status ?? -1) | chain=\(c3) | body=\(r3.map { bodyPrefix($0.body) } ?? "nil")")
        exit(1)
    }
    // text/plain 的 urlencoded kv（不是 JSON）
    var oauth1Token = "", oauth1Secret = "", mfaToken = ""
    for pair in r3.text.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        switch formDecode(kv[0]) {
        case "oauth_token": oauth1Token = formDecode(kv[1])
        case "oauth_token_secret": oauth1Secret = formDecode(kv[1])
        case "mfa_token": mfaToken = formDecode(kv[1])
        default: break
        }
    }
    guard !oauth1Token.isEmpty, !oauth1Secret.isEmpty else {
        log("Step 3 失败 | 200 但未解析到 oauth_token/secret | body=\(bodyPrefix(r3.body))")
        exit(1)
    }
    log("Step 3 | \(r3.status) | oauth_token=\(mask(oauth1Token)) oauth_token_secret=\(mask(oauth1Secret))" +
        (mfaToken.isEmpty ? "" : " mfa_token=\(mask(mfaToken))"))

    // Step 4：OAuth1 → OAuth2（exchange）
    let exURL = "https://connectapi.garmin.cn/oauth-service/oauth/exchange/user/2.0"
    var exParams = ["audience": "GARMIN_CONNECT_MOBILE_ANDROID_DI"]
    if !mfaToken.isEmpty { exParams["mfa_token"] = mfaToken }
    let exBody = exParams.map { "\(rfc3986Encode($0.key))=\(rfc3986Encode($0.value))" }.joined(separator: "&")
    let exAuth = oauthAuthHeader(method: "POST", urlStr: exURL, reqParams: exParams,
                                 consumerKey: ck, consumerSecret: cs,
                                 token: oauth1Token, tokenSecret: oauth1Secret)
    log("Step 4 | POST connectapi.garmin.cn/oauth-service/oauth/exchange/user/2.0（OAuth1 签名）")
    let (r4, c4, n4) = await requestWithCFRetry("POST", exURL,
        headers: ["Authorization": exAuth, "User-Agent": UA_OAUTH,
                  "Content-Type": "application/x-www-form-urlencoded"],
        body: exBody.data(using: .utf8))
    if !n4.isEmpty { log("Step 4 备注 | \(n4)") }
    guard let r4, r4.status == 200,
          let j4 = try? JSONSerialization.jsonObject(with: r4.body) as? [String: Any],
          let accessToken = j4["access_token"] as? String,
          let refreshToken = j4["refresh_token"] as? String else {
        log("Step 4 失败 | status=\(r4?.status ?? -1) | chain=\(c4) | body=\(r4.map { bodyPrefix($0.body) } ?? "nil")")
        exit(1)
    }
    let expiresIn = j4["expires_in"] as? Int ?? -1
    let scope = j4["scope"] as? String ?? ""
    log("Step 4 | \(r4.status) | access_token=\(mask(accessToken)) refresh_token=\(mask(refreshToken)) expires_in=\(expiresIn) scope=\(scope)")

    // Step 5：数据接口验证（Bearer）
    let spURL = "https://connectapi.garmin.cn/userprofile-service/socialProfile"
    log("Step 5 | GET \(spURL)")
    let (r5, c5) = await request("GET", spURL,
        headers: ["Authorization": "Bearer \(accessToken)", "User-Agent": UA_DATA], body: nil)
    guard let r5 else { log("Step 5 失败 | chain=\(c5)"); exit(1) }
    var profileOK = ""
    if let j5 = try? JSONSerialization.jsonObject(with: r5.body) as? [String: Any],
       let dn = (j5["displayName"] as? String) ?? (j5["userName"] as? String) {
        profileOK = " displayName=\(dn)"
    }
    log("Step 5 | \(r5.status) | bodyLen=\(r5.body.count)\(profileOK)")
    log(r5.status == 200 ? "=== 结论：登录全流程成功，access_token 可用 ===" : "=== Step 5 非 200，token 换取成功但数据接口待查 ===")
}

let sem = DispatchSemaphore(value: 0)
Task {
    await runFlow()
    sem.signal()
}
sem.wait()
