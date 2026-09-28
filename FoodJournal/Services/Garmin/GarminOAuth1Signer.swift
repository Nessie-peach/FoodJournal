import Foundation
import CryptoKit

/// OAuth 1.0a HMAC-SHA1 签名（RFC 5849），照 E2S 刺探验证过的实现移植。
/// 规则（docs/E2S-登录流程规格.md §8）：
/// - percent 编码保留字符仅 A-Za-z0-9-._~（空格 → %20，~ 不编码）；
/// - 参数按 key 字典序（key 相同再按 value）拼为 k=v&…；
/// - base string = METHOD & enc(不含 query 的 URL) & enc(参数串)（三层编码）；
/// - signing key = enc(consumer_secret) & enc(token_secret)（无 token 时以 & 结尾）；
/// - 签名 = base64(HMAC-SHA1(key, base_string))。
enum GarminOAuth1Signer {
    static let allowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// RFC 3986 percent 编码
    static func rfc3986Encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? string
    }

    /// 归一化参数串：key/value 编码后按 key 字典序（key 相同再按 value）排序拼接
    static func normalizedParamString(_ params: [String: String]) -> String {
        params
            .map { (rfc3986Encode($0.key), rfc3986Encode($0.value)) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// 签名 base string：METHOD(大写) & enc(URL 不含 query) & enc(参数串)
    static func baseString(method: String, url: String, paramString: String) -> String {
        let parsed = URL(string: url)
        let base = (parsed?.scheme?.lowercased() ?? "https") + "://" + (parsed?.host ?? "") + (parsed?.path ?? "")
        return [method.uppercased(), rfc3986Encode(base), rfc3986Encode(paramString)].joined(separator: "&")
    }

    /// HMAC-SHA1 签名（base64）
    static func signature(baseString: String, consumerSecret: String, tokenSecret: String) -> String {
        let key = Data((rfc3986Encode(consumerSecret) + "&" + rfc3986Encode(tokenSecret)).utf8)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(baseString.utf8), using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }

    /// 生成 `Authorization: OAuth ...` 头
    static func authorizationHeader(
        method: String, url: String, requestParams: [String: String],
        consumerKey: String, consumerSecret: String,
        token: String?, tokenSecret: String,
        timestamp: String = String(Int(Date().timeIntervalSince1970)),
        nonce: String = randomNonce()
    ) -> String {
        var oauth: [String: String] = [
            "oauth_consumer_key": consumerKey,
            "oauth_nonce": nonce,
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": timestamp,
            "oauth_version": "1.0",
        ]
        if let token {
            oauth["oauth_token"] = token
        } else {
            oauth["oauth_callback"] = "oob"
        }
        let all = requestParams.merging(oauth) { current, _ in current }
        let paramString = normalizedParamString(all)
        let base = baseString(method: method, url: url, paramString: paramString)
        oauth["oauth_signature"] = signature(baseString: base, consumerSecret: consumerSecret, tokenSecret: tokenSecret)
        let header = oauth
            .sorted { $0.key < $1.key }
            .map { "\(rfc3986Encode($0.key))=\"\(rfc3986Encode($0.value))\"" }
            .joined(separator: ", ")
        return "OAuth \(header)"
    }

    /// 随机 nonce（16 字节 hex，32 字符）
    static func randomNonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
