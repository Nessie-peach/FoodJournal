# E2S — Garmin 中国区 SSO 登录 spike 实测结果

> 实现：`docs/e2s_garmin_spike.swift`（纯 Swift，URLSession，单文件）
> 运行：`cd docs && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift e2s_garmin_spike.swift`
> 时间：2026-09-28　账号：tonytao81@outlook.com（密码经 Keychain subprocess 读取，未落盘未回显）
> 会话：共享 `HTTPCookieStorage.shared`；所有步骤经 `URLSessionTaskDelegate.willPerformHTTPRedirection` 拦截自动重定向，实际手动跟随（本次无任何 3xx）。

## 每步结果

| 步骤 | 请求 | 状态 | 提取结果 |
|---|---|---|---|
| Step 0 | GET `https://thegarth.s3.amazonaws.com/oauth_consumer.json` | 200 | consumer_key(len=36)、consumer_secret(len=35) 提取成功 |
| Step 1 | GET `https://sso.garmin.cn/mobile/sso/en/sign-in?clientId=GCM_ANDROID_DARK`（WebView UA + SSO_PAGE_HEADERS + Sec-Fetch-Site: none） | 200 | HTML(30264B)，种下 5 个 garmin cookie，无重定向 |
| Step 2 | POST `https://sso.garmin.cn/mobile/api/login?clientId=GCM_ANDROID_DARK&locale=en-US&service=<enc>`，JSON body（尝试 1/2） | 200 | `responseStatus.type=SUCCESSFUL`，`serviceTicketId`(len=34) 提取成功 |
| Step 2c | GET `https://sso.garmin.cn/portal/sso/embed`（+Sec-Fetch-Site: same-origin +Referer=Step2 final URL） | 200 | HTML(918B)，cookie 总数 5→8（CF LB cookie 到位） |
| Step 3 | GET `https://connectapi.garmin.cn/oauth-service/oauth/preauthorized?ticket=…&login-url=…&accepts-mfa-tokens=true`（OAuth1 HMAC-SHA1 无 token 签名，UA=`com.garmin.android.apps.connectmobile`） | 200 | text/plain urlencoded → `oauth_token`(len=36)、`oauth_token_secret`(len=35)；无 mfa_token |
| Step 4 | POST `https://connectapi.garmin.cn/oauth-service/oauth/exchange/user/2.0`，body `audience=GARMIN_CONNECT_MOBILE_ANDROID_DI`（OAuth1 带 token 签名） | 200 | JSON：access_token(len=1897)、refresh_token(len=152)、expires_in=81944、scope 含 CONNECT_READ/WRITE 等 |
| Step 5 | GET `https://connectapi.garmin.cn/userprofile-service/socialProfile`（Bearer + UA=`GCM-iOS-5.22.1.4`） | 200 | 3058B 用户资料 JSON，displayName 正常返回 |

## 过程观察

- **零失败、零重试**：全流程一次通过，未触发任何 CF 挑战（无 403/503，无 `cf-mitigated` 头），内置的"换移动 UA 重试"和"第 2 次登录尝试"均未启用。
- **无重定向**：Step 1/2 均直接 200（无 3xx 链），ticket 确认在 JSON body 里，与规格 §6.1 一致。
- **GET→POST 之间加了 1.5s 人类化延迟**（规格 §7.4 的保险措施），未验证是否必要。
- MFA 未触发（该账号未开启），`MFA_REQUIRED` 分支未实测，但 `/mobile/api/mfa/verifyCode` 端点规格齐全，可按需补。
- 手写 OAuth1 HMAC-SHA1（CryptoKit `HMAC<Insecure.SHA1>` + RFC 3986 percent-encoding）签名一次通过，Step 3/4 均被服务端接受，证明规格 §8 的 base string 构造规则准确。

## 卡点诊断

无卡点。潜在风险备注（供 App 内实现参考）：

1. **consumer 凭据轮换**：S3 JSON 是社区镜像，Garmin 会定期轮换；App 内应运行时拉取一次并缓存，401 时重新拉取。
2. **CF**：本次未拦截，但 garth 注释明示 SSO 端点有 CF；真机上 URLSession 的 TLS 栈是真 Safari 指纹，风险比 Python 客户端低。若未来 403，按 spike 内置策略换 `GCM-iOS-5.22.1.4` UA 重试该步一次。
3. **CLIENT_ID**：`GCM_ANDROID_DARK` 在 .cn 区 preauthorize/exchange 实测可用，无需换成 .cn 专有值。

## 最终结论：iOS 原生登录 **可行** ✅

规格文档（garth 0.8.0 源码阅读产物）与 .cn 区实际端点完全吻合，纯 Swift/URLSession 无需任何 TLS 伪装或 WebView 即可完成登录。

### Swift 实现要点清单（供 App 内 GarminService）

1. **常量**：`CLIENT_ID=GCM_ANDROID_DARK`；UA 三套——SSO 页用 iPhone WebView UA（含 Accept/Accept-Language/Sec-Fetch-Mode/Dest），OAuth 接口用 `com.garmin.android.apps.connectmobile`，数据接口用 `GCM-iOS-5.22.1.4`。
2. **consumer key/secret**：进程启动从 `https://thegarth.s3.amazonaws.com/oauth_consumer.json` 拉一次并缓存；401 时重拉。
3. **Cookie**：全程共享 `HTTPCookieStorage`（App 内 URLSession 默认即为共享 .shared，无需额外处理）。
4. **流程**（5 步）：
   1. GET `sso.garmin.cn/mobile/sso/en/sign-in?clientId=GCM_ANDROID_DARK` 种 cookie（不解析 HTML）；
   2. POST `sso.garmin.cn/mobile/api/login?...` JSON body `{username, password, rememberMe:false, captchaToken:""}` → `serviceTicketId`；`responseStatus.type` 判 SUCCESSFUL / MFA_REQUIRED（MFA 走 `/mobile/api/mfa/verifyCode`）；
   3. GET `sso.garmin.cn/portal/sso/embed`（Referer=Step2 URL，best-effort 吞错）种 CF LB cookie；
   4. GET `connectapi.garmin.cn/oauth-service/oauth/preauthorized?ticket=…&login-url=…&accepts-mfa-tokens=true`，OAuth1 无 token 签名 → `oauth_token/secret/mfa_token`（text/plain，parse_kv 非 JSON）；
   5. POST `connectapi.garmin.cn/oauth-service/oauth/exchange/user/2.0`，body `audience=GARMIN_CONNECT_MOBILE_ANDROID_DI`（有 mfa_token 则附带），OAuth1 带 token 签名 → access/refresh token（expires_in≈81944s≈22.8h）。
5. **OAuth1 签名**：HMAC-SHA1；RFC 3986 编码（保留集仅 `A-Za-z0-9-._~`）；参数=key 字典序（query + form body + oauth_*）；base string 三层编码；key=`enc(cs)&enc(tokenSecret)`（无 token 时以 `&` 结尾）；CryptoKit `HMAC<Insecure.SHA1>` 即可，无需第三方库。
6. **重定向**：ticket 在 JSON 里，不依赖 Location；URLSession 默认自动跟随即可（spike 里禁自动重定向只是实测观察用）。
7. **刷新**：access token 过期后用已存 OAuth1 token 重跑 exchange（不带 audience）。
8. **健壮性**：登录失败按 `responseStatus.type: message` 归类；403 疑似 CF 时换移动 UA 重试一次；GET→POST 间加 1–3s 延迟作保险。
