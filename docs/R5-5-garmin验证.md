# R5-5（E1）Garmin 中国区账号验证报告

> 日期：2026-09-28 ｜ 验证脚本：`r55_garmin_verify.py` ｜ 原始数据（脱敏）：`r55_garmin_results.json`
> 结论：**登录成功，5 个数据接口全部可用**。E2（iOS 直连）可行。

## 1. 登录验证

| 项 | 结果 |
|---|---|
| 中国区端点 | ✅ `is_cn=True` → garth 走 `sso.garmin.cn`，登录一次成功（无重试） |
| is_cn=True 是否必需 | **必需**。中国区账号走国际端点 sso.garmin.com 会 401/找不到账号；本次未反向测试（为省请求次数），但社区共识与库实现均要求中国区账号必须 `is_cn=True` |
| MFA/验证码 | 未触发（`needs_mfa` 未返回），无验证码拦截 |
| 凭据安全 | 密码仅通过 `security find-generic-password -s dietapp-r5-garmin -w` 从钥匙串读取，未落盘、未出现在任何输出 |
| 环境依赖 | `garminconnect 0.3.16` + `garth 0.8.0`（garth 已被上游标记 deprecated，但 API 仍稳定可用） |
| 请求量 | 登录 + 10 次数据请求（5 接口 × 今昨两天），符合 ≤15 限制 |

### Token 持久化（iOS 端参考）

- 路径：**`~/.garth_session_cn/`**（内容为 `garmin_tokens.json`，含 OAuth1/OAuth2 token 与 profile）
- 写入方式：`client.client.dump(tokenstore)`；再次登录前可 `client.login(tokenstore=~/.garth_session_cn)` 直接加载 token，**跳过 SSO 密码流程**
- garth 的 token 结构：OAuth1 token（长期有效）+ OAuth2 token（约 1 年有效期，过期后用 OAuth1 自动刷新，无需重新密码登录）

## 2. 各数据接口可用性与实际值

### 2.1 HRV（`get_hrv_data`）✅ HealthKit 无此数据

关键字段：`hrvSummary.lastNightAvg / weeklyAvg / lastNight5MinHigh / baseline{lowUpper,balancedLow,balancedUpper} / status`，另有 `hrvReadings[]`（逐分钟 `hrvValue` + 时间戳）。

| 日期 | 昨夜均值 | 5min 峰值 | 周均值 | 基线区间 |
|---|---|---|---|---|
| 09-28 | 36 ms | 53 | 49 | 41–58（均衡） |
| 09-27 | 38 ms | 67 | 51 | 41–58（均衡） |

### 2.2 身体电量（`get_body_battery`）✅ HealthKit 无此数据

关键字段：`charged / drained`，`bodyBatteryValuesArray`（[时间戳, 电量] 数组），`bodyBatteryActivityEvent[]`（各事件对身体电量的增减 `bodyBatteryImpact`）。

| 日期 | 充电 | 消耗 | 区间 |
|---|---|---|---|
| 09-28 | +33 | −30 | 5 → 36（当前 11） |
| 09-27 | +47 | −37 | 7 → 54 |

### 2.3 压力（`get_stress_data`）✅ HealthKit 无此数据

关键字段：`avgStressLevel / maxStressLevel`，`stressValuesArray`（3 分钟粒度时间序列）。`get_user_summary` 中还有分档时长（low/medium/high stress duration & percentage）。

| 日期 | 均值 | 峰值 | 高压力时长 |
|---|---|---|---|
| 09-28 | 34 | 98 | 22 min |
| 09-27 | 38 | 95 | 95 min |

### 2.4 睡眠含分期（`get_sleep_data`）✅ HealthKit 无官方睡眠分期（iOS 需第三方写入才有）

关键字段（`dailySleepDTO`）：`sleepTimeSeconds`、`deepSleepSeconds / lightSleepSeconds / remSleepSeconds / awakeSleepSeconds`、`napTimeSeconds`、`sleepScores.overall.value`、`avgSleepStress`、`averageSpO2Value`、`avgHeartRate`、`sleepNeed{baseline,actual}`；`sleepLevels[]` 为分期时间线（activityLevel：0= awake, 1= deep…按枚举）。另附 SpO2 / 呼吸 / 心率 / 睡眠压力逐分钟序列。

| 日期 | 总时长 | 深睡 | 浅睡 | REM | 睡眠分 | 备注 |
|---|---|---|---|---|---|---|
| 09-28（昨夜） | 3h34m | 46%（98min） | 47% | 7% | 45 | 无午睡 |
| 09-27 | 6h31m + 午睡 62m | 31%（121min） | 60% | 9% | 60 | 午睡单独记录 |

### 2.5 每日摘要（`get_user_summary`）✅ 部分与 HealthKit 重叠

关键字段：`totalSteps / totalKilocalories（含 BMR 拆分）/ activeKilocalories / floors / restingHeartRate / minHeartRate / maxHeartRate / averageSpo2 / 中高强度分钟数 / 久坐时长` 等，一次请求可替代多个 HealthKit 查询。

| 日期 | 步数 | 总热量（活动/BMR） | 静息心率 | 爬楼 |
|---|---|---|---|---|
| 09-28 | 3,938 | 1996 / 248+1748 kcal | 57 | 21.6 层 |
| 09-27 | 2,718 | 2634 / 168+2466 kcal | 57 | 3.0 层 |

## 3. 与 HealthKit 的互补性结论

| 数据 | HealthKit | Garmin API | 互补价值 |
|---|---|---|---|
| HRV（逐夜 + 基线） | ✗（仅记录在 Apple Watch 健康 App 内有 sdnn，但 App 读取需用户手动授权且无基线分析） | ✅ `lastNightAvg` + 官方基线/状态 | **高** |
| 身体电量 | ✗ 完全没有 | ✅ charged/drained/时间线 | **高** |
| 压力（全天时间线） | ✗ 完全没有 | ✅ 3 分钟粒度 + 分档时长 | **高** |
| 睡眠分期 | △ HealthKit 有 `sleepAnalysis` 分类（Asleep Core/Deep/REM），但值来自手表/手环写入；若用户只戴 Garmin，HealthKit 无数据 | ✅ 深浅/REM 秒数 + 分数 + 分期时间线 | **高** |
| 睡眠需求 sleepNeed | ✗ | ✅ baseline/actual | 中 |
| SpO2 / 呼吸频率（睡眠期） | △ 部分 | ✅ 睡眠期均值/最低值 | 中 |
| 步数 / 卡路里 / 心率 | ✅ 有 | ✅ 有（含 BMR 拆分、爬楼） | 低（去重即可） |

**结论**：HRV、身体电量、压力、睡眠分期 4 类数据是 Garmin 相对 HealthKit 的净增量，是接入的主要价值；摘要类数据可作为 HealthKit 缺失时的兜底。

## 4. E2（iOS 直连）可行性评估

**结论：可行，建议 iOS 端复刻 garth 的 SSO 流程或采用服务端代理。**

1. **登录链路复杂度（中高）**：garth 的 SSO 流程为 5 步左右：① GET sso embed 页（取 CSRF `csrfToken`）→ ② POST `/sso/signin`（email+password+csrf，返回 ticket）→ ③ 用 ticket 换 OAuth1 token（`oauth-service/oauth/preauthorize`，需 RSA/digest 签名头）→ ④ OAuth1 换 OAuth2 token（`oauth-service/oauth/exchange/user/2.0`）→ ⑤ GET `/usersummary` 之类接口验证。**难点**在第 ③ 步的加密签名（garth 用内置 RSA 私钥+digest）和 Cloudflare 指纹校验（garminconnect 因此引入了 curl_cffi/UA 伪装）——Swift 原生实现需自行处理 TLS 指纹，存在被 CF 拦截的风险。
2. **Cookie/CSRF**：需要。登录过程依赖 SSO 域 cookie + csrfToken；登录完成后数据接口只需 OAuth2 Bearer 头，无需 cookie。
3. **Token 有效期与续期**：OAuth2 token 约 1 年，过期可用长期有效的 OAuth1 token 自动换新（garth 在每次请求前自动刷新）。**即首次密码登录后，一年内无需再走 SSO**。
4. **建议方案**：
   - **方案 A（推荐）**：首次登录放 Python/服务端（复用本脚本 + `~/.garth_session_cn`），把 OAuth token 注入 iOS App（Keychain 保存），iOS 端只需带 Bearer 调 `connectapi.garmin.cn` 数据接口——纯只读 REST，复杂度低。
   - **方案 B**：iOS 全原生实现 garth 协议，需移植 RSA 签名与 CF 指纹对抗，工作量约 3–5 天，且存在 Garmin 改版风险。
   - 数据端点（中国区）：`connectapi.garmin.cn`，路径与国际版一致（如 `/wellness-service/wellness/nightlySleep/{date}`）。
5. **合规注意**：只读调用、遵守请求频率（建议每日缓存一次全量数据），token 存 Keychain。
