# E2S — Garmin 登录流程技术规格（依据 garth 0.8.0 源码）

> 来源：`garth 0.8.0`（PyPI，`matin/garth`），本地路径
> `/Users/pigeon/.workbuddy/binaries/python/envs/m0/lib/python3.13/site-packages/garth/`。
> 本文为纯代码阅读产物，所有 URL/参数/UA/字段均直接抄自源码，未发任何网络请求。
> 中国区域名按 `{domain} = garmin.cn` 代入（garth 默认 `garmin.com`，域名是 `Client.domain` 的一个可配置字段，见 `http.py:43`）。

---

## 0. 源码事实勘误（实现前必读）

1. **consumer key/secret 不在 garth 源码里硬编码**。garth 0.8.0 运行时从
   `https://thegarth.s3.amazonaws.com/oauth_consumer.json` 下载（`sso.py:20`，
   `sso.py:60-62`），取 JSON 的 `consumer_key` / `consumer_secret` 两个字段。
   该 JSON 是社区公开镜像（S3 桶 `thegarth`，garth README 明示），实现时应把
   这两个值作为**一次性人工读取的常量**抄进 Swift 代码（读该 URL 一次即可），
   而不是在 App 里运行时请求 S3。**本文不虚构这两个值**——凡声称"从源码抄出"
   的凭据都属误传，正确出处是上述 S3 JSON。
2. **没有 csrfToken 提取步骤**。garth 0.8.0 的 SSO 流程（`/mobile/sso/en/sign-in`
   + `/mobile/api/login`）是纯 JSON API 流程，不解析 HTML、不提取 CSRF。
   "embed 页提取 csrfToken" 属于旧版 garth（`/sso/embed` + `csrfId`）或
   garminconnect 的 widget 降级流程（`garminconnect/client.py:141`
   `_CSRF_RE = re.compile(r'name="_csrf"\s+value="(.+?)"')`）。本文按 0.8.0
   实际代码写规格。
3. garth 全程使用 `requests.Session`，**没有显式禁止自动重定向**（无
   `allow_redirects=False`）；也没有 TLS 指纹伪装。CF 处理见 §3。

## 0.1 通用常量（抄自源码）

| 常量 | 值 | 出处 |
|---|---|---|
| `CLIENT_ID` | `GCM_ANDROID_DARK` | sso.py:19 |
| `service_url` | `https://mobile.integration.garmin.cn/gcm/android` | sso.py:101（domain 代入 .cn） |
| SSO 页面 UA | `Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148` | sso.py:32-35 |
| OAuth 接口 UA | `com.garmin.android.apps.connectmobile` | sso.py:27 |
| garth 会话默认 UA（数据接口兜底） | `GCM-iOS-5.22.1.4` | http.py:20 |
| OAuth consumer 来源 | `https://thegarth.s3.amazonaws.com/oauth_consumer.json` | sso.py:20 |
| connectapi 域 | `connectapi.garmin.cn` | sso.py:156 |
| sso 域 | `sso.garmin.cn` | http.py:173（`https://{subdomain}.{domain}`） |

SSO 页面请求附带头（`SSO_PAGE_HEADERS`，sso.py:36-44）：

```
User-Agent: <上面 SSO 页面 UA 原值>
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
Accept-Language: en-US,en;q=0.9
Sec-Fetch-Mode: navigate
Sec-Fetch-Dest: document
```

注释原文（sso.py:29-31）："Browser-like headers for SSO to avoid Cloudflare
challenges. The SSO endpoints run in a WebView, so requests must look like a
browser — not a Python HTTP client."

---

## Step 0（隐含）：获取 consumer 凭据

- URL：`https://thegarth.s3.amazonaws.com/oauth_consumer.json`，GET，无签名。
- 响应 JSON：`{"consumer_key": "<长随机串>", "consumer_secret": "<长随机串>"}`。
- Swift 实现建议：人工读取一次后硬编码为常量（JSON 会被 Garmin 定期轮换，
  garth 的做法是每次进程启动拉一次；iOS App 内硬编码 + 出错 401 时提示更新）。

## Step 1：SSO 登录页请求（设置 Cookie，非获取 CSRF）

`login()` 第一步（sso.py:109-114）：

- **URL**：`https://sso.garmin.cn/mobile/sso/en/sign-in?clientId=GCM_ANDROID_DARK`
- 方法：GET
- query 参数：`clientId=GCM_ANDROID_DARK`（唯一参数）
- headers：`SSO_PAGE_HEADERS` + `Sec-Fetch-Site: none`（共 6 个头）
- body：无
- 目的：**仅为了在该域名下种下会话 Cookie**（源码注释 "Set cookies"）。
  响应是 HTML 登录页，garth 不解析它，不提取任何字段。
- 成功特征：HTTP 2xx。Cookie 由 Session 自动存入 cookie jar。

## Step 2：登录 POST（拿 ticket）

sso.py:117-129：

- **URL**：`https://sso.garmin.cn/mobile/api/login?clientId=GCM_ANDROID_DARK&locale=en-US&service=https%3A%2F%2Fmobile.integration.garmin.cn%2Fgcm%2Fandroid`
- 方法：POST
- query 参数（`login_params`）：
  - `clientId=GCM_ANDROID_DARK`
  - `locale=en-US`
  - `service=https://mobile.integration.garmin.cn/gcm/android`（URL 编码后拼在 query）
- headers：`SSO_PAGE_HEADERS`（同上 5 个头，`Sec-Fetch-Site` 不加）+
  `Content-Type: application/json`（由 `json=` 参数自动设置）
- body（JSON）：

```json
{
  "username": "<email>",
  "password": "<password>",
  "rememberMe": false,
  "captchaToken": ""
}
```

- **成功响应**：JSON，特征为 `responseStatus.type == "SUCCESSFUL"`
  （常量 `SSO_SUCCESSFUL`，sso.py:23）。
- **ticket 提取**：**JSON 路径，不是正则** —— `resp_json["serviceTicketId"]`
  （sso.py:133）。这就是后续 OAuth1 换 token 用的 ticket。
- 其它可能的 `responseStatus.type`：
  - `"MFA_REQUIRED"`（`SSO_MFA_REQUIRED`）：需走 MFA 分支（见 §5）。
  - 其它值即失败，报错格式 `{type}: {message}`（`_parse_sso_response`，sso.py:76-86）。
  - MFA 分支响应中 `customerMfaInfo.mfaLastMethodUsed` 指明 MFA 渠道
    （缺省 `"email"`，sso.py:137-138）。

### Step 2b（MFA 分支，可选）

sso.py:206-231：

- URL：`https://sso.garmin.cn/mobile/api/mfa/verifyCode?clientId=GCM_ANDROID_DARK&locale=en-US&service=<同上>`
- 方法：POST，headers 同 Step 2
- body（JSON）：`{"mfaMethod": "<email|...>", "mfaVerificationCode": "<用户输入的验证码>", "rememberMyBrowser": false, "reconsentList": [], "mfaSetup": false}`
- 成功：`responseStatus.type == "SUCCESSFUL"`，同样取 `serviceTicketId`。

## Step 2c：embed 页（种 Cloudflare LB Cookie）

`_complete_login`（sso.py:254-266）在拿 ticket 之后、换 OAuth1 之前：

- URL：`https://sso.garmin.cn/portal/sso/embed`
- 方法：GET
- headers：`SSO_PAGE_HEADERS` + `Sec-Fetch-Site: same-origin` + `Referer: <Step 2 响应的最终 URL>`
  （`referrer=True` 时取 `self.last_resp.url`，http.py:175-176）
- 源码注释（sso.py:257）："Sets Cloudflare LB cookie for backend pinning —
  best-effort"。**该步失败会被吞掉异常继续**（`except GarthException: pass`）。
- 这就是 0.8.0 中 "embed 页" 的真实用途：**不提取 csrfToken，只种 CF LB cookie**。

## Step 3：ticket → OAuth1（preauthorize）

`get_oauth1_token`（sso.py:154-170）：

- **URL**（完整构造）：

```
https://connectapi.garmin.cn/oauth-service/oauth/preauthorized
    ?ticket=<serviceTicketId>
    &login-url=https://mobile.integration.garmin.cn/gcm/android
    &accepts-mfa-tokens=true
```

（`login-url` 的值在拼 URL 时需 query 编码；签名时作为请求参数参与签名，见 §6。）

- 方法：GET
- **Authorization 头**：OAuth 1.0a 签名头，由 `GarminOAuth1Session`（requests_oauthlib
  `OAuth1Session` 子类，sso.py:47-73）自动生成：
  - signature method：**HMAC-SHA1**
  - consumer key/secret：Step 0 的 S3 JSON 值
  - 此时**没有 token**，`oauth_token` 参数为空、签名 key 为
    `consumer_secret + "&"`（见 §6）
  - oauth 头参数：`oauth_nonce`（随机）、`oauth_timestamp`（秒级）、
    `oauth_signature_method="HMAC-SHA1"`、`oauth_version="1.0"`、
    `oauth_consumer_key`、`oauth_callback="oob"`（requests_oauthlib 默认 oob）
- 额外 headers：`User-Agent: com.garmin.android.apps.connectmobile`（sso.py:27，
  注释要求"必须与 S3 里的 Android consumer key 匹配"）
- Cookie：**继承主 Session 的 cookie jar**（sso.py:70
  `self.cookies.update(parent.cookies)`，含 Step 1/2c 种下的 cookie）
- **成功响应**：`text/plain` 形式的 URL 编码键值对，**不是 JSON**。提取方式：
  `urllib.parse.parse_qs`，字段（sso.py:168-170）：
  - `oauth_token` —— OAuth1 token
  - `oauth_token_secret` —— OAuth1 token secret
  - `mfa_token`（当 `accepts-mfa-tokens=true` 且账号启用了 MFA 时返回）
- 错误：非 2xx 直接 `raise_for_status`。

## Step 4：OAuth1 → OAuth2（exchange）

`exchange`（sso.py:173-203）：

- **URL**：`https://connectapi.garmin.cn/oauth-service/oauth/exchange/user/2.0`
- 方法：POST
- headers：
  - `Authorization: OAuth ...`（OAuth1 签名头，同 §6，但此时带
    `oauth_token=<oauth_token>`、`oauth_token_secret` 参与签名）
  - `User-Agent: com.garmin.android.apps.connectmobile`
  - `Content-Type: application/x-www-form-urlencoded`
- body（x-www-form-urlencoded；登录场景必带 audience）：
  - `audience=GARMIN_CONNECT_MOBILE_ANDROID_DI`（`login=True` 时，sso.py:186）
  - `mfa_token=<mfa_token>`（仅当 OAuth1 token 含 mfa_token，sso.py:187-188）
- **成功响应**：JSON，字段（`OAuth2Token`，auth_tokens.py:26-35）：

| 字段 | 含义 |
|---|---|
| `scope` | 权限范围 |
| `jti` | token id |
| `token_type` | `Bearer` |
| `access_token` | **后续数据接口用的 Bearer token** |
| `refresh_token` | 刷新用 |
| `expires_in` | access token 有效秒数 |
| `refresh_token_expires_in` | refresh token 有效秒数 |

garth 额外计算 `expires_at = now + expires_in`、
`refresh_token_expires_at = now + refresh_token_expires_in`（sso.py:234-239）。
过期后刷新 = 用保存的 OAuth1 token 再调一次本接口（不带 `login=True`，
http.py:231-241）。

## Step 5：数据接口调用（connectapi）

`connectapi`（http.py:243-249）+ `request(api=True)`（http.py:177-186）：

- **URL 示例**：`https://connectapi.garmin.cn/userprofile-service/socialProfile`
- 方法：GET
- headers：
  - `Authorization: Bearer <access_token>`
    （garth 实现为 `f"{token_type.title()} {access_token}"`，即 `"Bearer xxx"`，
    auth_tokens.py:58-59）
  - 若在 `Client.sess` 上调用还会带默认 UA `GCM-iOS-5.22.1.4`；但**该 UA 不用于
    SSO/OAuth 步骤**（那两步各自显式覆盖 UA）
- access token 过期 → 自动用 OAuth1 token 重跑 Step 4（http.py:181-185）。
- 其余数据接口同理，如 `/usersummary-service/...` 等，均为
  `https://connectapi.garmin.cn/<path>` + Bearer。

## §5 完整流程图

```
GET  sso.garmin.cn/mobile/sso/en/sign-in?clientId=GCM_ANDROID_DARK     (种 cookie)
POST sso.garmin.cn/mobile/api/login?...        JSON body               → serviceTicketId
     [可选 MFA: POST /mobile/api/mfa/verifyCode                        → serviceTicketId]
GET  sso.garmin.cn/portal/sso/embed                (best-effort, 种 CF LB cookie)
GET  connectapi.garmin.cn/oauth-service/oauth/preauthorized?ticket=... (OAuth1 签名)
     → oauth_token / oauth_token_secret / mfa_token
POST connectapi.garmin.cn/oauth-service/oauth/exchange/user/2.0       (OAuth1 签名)
     → access_token / refresh_token / expires_in ...
GET  connectapi.garmin.cn/<path>  Authorization: Bearer <access_token>
```

## §6 重定向与 Cookie 注意点

1. **没有哪一步显式禁止重定向**。garth 全程 `requests` 默认行为（自动跟随）。
   `requests_oauthlib` 的 OAuth1Session 对 3xx 同样自动跟随。Swift 里用
   URLSession 默认行为即可；但注意 Step 2 的 ticket 在 JSON body 里而非重定向
   URL 里，所以不依赖重定向解析。
2. **Cookie 依赖**：
   - Step 1 的唯一目的是种 SSO 域 cookie；Step 2 必须在**同一 cookie jar**
     下进行（同一 `Session`）。
   - Step 2c 种的 CF LB cookie 用于 **backend pinning**（源码注释），让后续
     connectapi 请求落在同一后端；best-effort，失败不影响流程。
   - Step 3/4 的 `GarminOAuth1Session` 显式 `self.cookies.update(parent.cookies)`
     继承主 jar（sso.py:70）——Swift 里要保证共享 `HTTPCookieStorage`。
   - OAuth 接口（connectapi）与 SSO 接口不同域，cookie 不互通、也不需要。
3. **CSRF 与 cookie 的关系**：在 0.8.0 的 mobile API 流程中不存在 CSRF token；
   会话合法性完全由 SSO 域的 cookie 承载。如果将来改用 web portal 流程
   （`/sso/embed` 表单），才需要正则提取 `name="_csrf"`（见 garminconnect
   `client.py:141`），并把 CSRF 随表单 POST 回去——那是另一套流程。

## §7 Cloudflare 相关

1. **garth 自身没有 TLS 指纹/CF 挑战处理**，不用 curl_cffi。它的对策只有：
   - SSO 页面用浏览器式 headers（WebView UA + Accept/Sec-Fetch，sso.py:29-44，
     注释明说 "to avoid Cloudflare challenges"）；
   - embed 步骤种 CF LB cookie（backend pinning，best-effort）。
2. **garth 自己的 UA**：
   - 会话默认（数据接口）：`GCM-iOS-5.22.1.4`（http.py:20）
   - OAuth 接口：`com.garmin.android.apps.connectmobile`（sso.py:27）
   - SSO 页面：iPhone WebView UA（sso.py:32-35，见 §0.1）
3. **curl_cffi 在 garminconnect 层的用途**（`garminconnect 0.3.16/client.py`，
   本地源码）：做 **TLS 指纹伪装轮换**（`impersonate="safari_ios"/"safari"/
   "chrome120"/"edge101"/"chrome"`，client.py:131-138），并配 10–20s 反 WAF
   随机延迟（"Cloudflare flags rapid GET→POST sequences as bot-like"，
   client.py:122-128）。它有 4 条登录策略（iOS mobile / DI token / SSO widget /
   portal web），是 garth 之外的更激进方案。
4. **对 Swift 实现的启示**：iOS URLSession 的 TLS 栈本身就是真 Safari 指纹，
   通常不会触发 CF 的 TLS 层挑战；关键是把上述 UA/Sec-Fetch 头带上，并在
   GET→POST 之间加入 1–3s 人类化延迟（可选保险）。

## §8 OAuth1 签名实现要点（Swift 手写指南）

OAuth 1.0a / HMAC-SHA1，与 RFC 5849 一致：

1. **参数收集**：所有参与签名的参数 = 请求 query 参数 + 表单 body 参数
   （`application/x-www-form-urlencoded` 时）+ `Authorization` 头里的 oauth 参数
   （`oauth_consumer_key`、`oauth_nonce`、`oauth_signature_method`、
   `oauth_timestamp`、`oauth_version`、`oauth_callback`、有 token 时
   `oauth_token`）。`Authorization` 头里的 `oauth_signature` 本身不参与。
2. **归一化规则**：
   - 每个参数 key/value 均做 RFC 3986 percent-encoding：保留字符仅
     `A-Z a-z 0-9 - . _ ~`；空格 → `%20`（不是 `+`）；`~` 不编码。
   - 按 **key 字典序排序，key 相同再按 value 字典序**。
   - 拼接为 `k1=v1&k2=v2&...`（k/v 均为编码后值）。
3. **base string**：
   `HTTP_METHOD(大写) + "&" + percent_encode(完整请求 URL，含 path，不含 query) + "&" + percent_encode(第 2 步的参数串)`
   注意三层嵌套：参数串整体要再编码一次放进 base string。
4. **signing key**：`percent_encode(consumer_secret) + "&" + percent_encode(token_secret)`；
   Step 3（preauthorized，尚无 token）时 token_secret 为空串，即 key 以 `&` 结尾；
   Step 4（exchange）时 token_secret = OAuth1 的 `oauth_token_secret`。
5. **签名**：`base64(HMAC-SHA1(key, base_string))`，放进
   `oauth_signature`，构造 `Authorization: OAuth oauth_consumer_key="...",
   oauth_nonce="...", oauth_signature="...", oauth_signature_method="HMAC-SHA1",
   oauth_timestamp="...", oauth_version="1.0"[, oauth_token="..."][, oauth_callback="oob"]`
   （各值再 percent-encode）。
6. **本流程的参数明细**：
   - Step 3 GET：参与签名的请求参数 = `ticket`、`login-url`、`accepts-mfa-tokens`
     （注意 `login-url` 的值是 URL，编码后很长）+ 7 个 oauth_* 参数。
   - Step 4 POST：参与签名的请求参数 = `audience`（和可选 `mfa_token`）+ oauth_* 参数。
7. **nonce**：任意随机串（requests_oauthlib 用 32 位随机十六进制）；
   **timestamp**：Unix 秒。

## §9 中国区域名备注

- garth 的 domain 是单一字段（默认 `garmin.com`），所有 URL 由
  `https://{sso|connectapi|mobile.integration}.{domain}/...` 拼出。切到
  `garmin.cn` 即得上文所有 `.cn` URL。
- `mobile.integration.garmin.cn`、`connectapi.garmin.cn` 是否在中国区真实可用
  **源码无法证明**，需实测验证；若 `.cn` 区 SSO 端点路径不同（如缺少
  `/mobile/api/login`），需抓包中国区 Garmin Connect App 校正路径与 `CLIENT_ID`
  （`GCM_ANDROID_DARK` 是 Android 国际版的值，`.cn` 区可能不同）。
- garminconnect 本地源码的域名白名单恰好是 `{"garmin.com", "garmin.cn"}`（client.py:94），
  说明 `.cn` 是被社区认可的可用域。
