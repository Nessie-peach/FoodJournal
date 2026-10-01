# 今天吃什么 · FoodJournal

iOS 饮食与运动记录 App。**全部数据存在本机**，无服务器、无账号体系；拍照识图、每日小记与 AI 建议、健康/运动数据同步、统计与导出导入都在设备上完成。

技术栈：SwiftUI + SwiftData ｜ iOS 26+ ｜ Swift 6 ｜ XcodeGen 生成工程

---

## 功能

围绕「管住嘴 / 迈开腿」两条主线组织，底部固定 4 个 tab：**今日 / 小记 / 统计 / 我的**。

| 模块 | 能力 |
|---|---|
| **管住嘴** | 拍照识图（单张/连拍最多 5 张、相册多选）、营养表场景优先读取包装上的数值、识别结果可改名改量后保存、手动记录与编辑删除、空名称行不入库 |
| **今日汇总** | 今日摄入、热量缺口（缺口绿 / 盈余红）、近三天趋势表（日期 / 摄入 / 消耗 / 差值） |
| **小记** | 每日小记 + AI 建议（可手工编辑、可重新生成）；23:30 本地通知提醒撰写，点击后才真正生成，错过的次日补生成 |
| **迈开腿** | 当日四卡片：活动消耗 / 睡眠 / 心率 / HRV；运动记录列表；空态区分「无数据」与「未授权」 |
| **健康数据源** | Apple 健康（HealthKit 只读：活动能量、睡眠含入睡起床、心率、HRV、体能训练）＋ **佳明直连**（OAuth1 登录、令牌本地保存、按日同步） |
| **历史回看** | 饮食历史（按月导航、按日分组、展开明细、进编辑页，可在历史日补录记录）；锻炼历史只读 |
| **统计** | 摄入 vs 消耗 / 睡眠 / 运动三模块，日 · 周 · 月切换，日期联动 |
| **体重** | 录入（支持小数）、变化量按时间顺序显示（增重红 / 减重绿）、历史列表、左滑删除 |
| **我的** | 佳明账号、健康数据、目标设置、数据管理、LLM 模型设置（识图与建议分开配置） |
| **数据管理** | JSON 全量导出（含照片）、按 id 去重合并导入、上次导出时间、超 5 天未备份横幅提醒 |
| **同步** | 三通道：回前台 15 分钟防抖 / 后台 2 小时 / 手动强制；失败 3 次熔断；同步状态与转圈提示 |

**业务日 04:00 分界**：凌晨（00:00–04:00）记录的饮食、小记、建议都归前一天；凌晨消耗取前一自然日并注明。

---

## 技术要点

| 项 | 选择 |
|---|---|
| UI / 数据 | SwiftUI ／ SwiftData（本地持久化） |
| 最低版本 | iOS 26.0；Swift 6 |
| 工程生成 | **XcodeGen**（`project.yml` 是唯一真身，`FoodJournal.xcodeproj` 是生成物且不入库） |
| LLM | OpenAI 兼容抽象层（`LLMProvider`）：预设 DeepSeek 官方 / 火山引擎 / 腾讯云 / 阿里云 + 自定义端点，识图与建议可分别配置 |
| 密钥存放 | macOS/iOS **Keychain**（不进代码、不进配置文件） |
| 健康数据 | HealthKit（只读）＋ 佳明直连（OAuth1 自实现签名） |
| 通知 | 本地通知（`UNUserNotificationCenter`），23:30 触发建议生成提醒 |
| 分发 | 免费 Apple ID 侧载（无 App Store 包） |

---

## 目录结构

```
FoodJournal/
├── project.yml                 # XcodeGen 工程定义（target / 权限 / 签名 / 版本号）
├── FoodJournal/
│   ├── Models/                 # SwiftData 模型：Meal / FoodItem / WeightRecord /
│   │                           #   DailyJournal / DailyAdvice / DailyHealthSnapshot
│   ├── Repositories/           # 数据访问层
│   ├── Services/
│   │   ├── LLM/                # LLMClient / VisionService / AdviceService /
│   │   │                       #   AIEditService / KeychainStore / Presets
│   │   ├── Garmin/             # 登录、OAuth1 签名、数据客户端、同步、令牌存储
│   │   ├── HealthKitService.swift
│   │   ├── SyncCoordinator.swift / SyncStatusStore.swift
│   │   ├── NotificationService.swift / JournalCatchup.swift
│   │   └── BackupService.swift / BackgroundRefreshScheduler.swift
│   ├── Views/
│   │   ├── Home/               # 今日页（汇总、拍照流程、编辑、迈开腿、体重卡）
│   │   ├── Journal/ Stats/ History/ Weight/ Settings/
│   │   └── ...
│   ├── Utilities/
│   └── Info.plist / FoodJournal.entitlements
├── FoodJournalTests/           # 单元测试
├── docs/                       # 设计与验证文档（见下）
└── tools/ios-devmode.sh        # 真机开发者模式/设备状态自检脚本
```

---

## 构建与运行

前置：Xcode 27、iOS 26+ 真机或模拟器、XcodeGen（`brew install xcodegen`）。

```bash
# 1. 生成工程（必须先做，.xcodeproj 不入库）
xcodegen generate

# 2. 打开
open FoodJournal.xcodeproj
```

首次真机运行前：
1. 在 Xcode 的 `Signing & Capabilities` 里选择自己的 Team（本工程签名已写进 `project.yml`，换账号时改 `DEVELOPMENT_TEAM` 后重新 `xcodegen generate`）
2. iPhone 需开启「设置 → 隐私与安全性 → 开发者模式」并重启
3. `Info.plist` 里的隐私文案（相机、健康）按需保留

命令行构建与推送（等价于点 Run）：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project FoodJournal.xcodeproj -scheme FoodJournal -configuration Debug \
  -destination "platform=iOS,id=<设备 UDID>" \
  -derivedDataPath .build/DerivedData -allowProvisioningUpdates \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' build

xcrun devicectl device install app --device <UDID> .build/DerivedData/Build/Products/Debug-iphoneos/FoodJournal.app
xcrun devicectl device process launch --device <UDID> com.somethingwierd.FoodJournal
```

> `OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox'`：在受限进程环境（沙箱终端 / CI）里，Swift 编译器给宏插件（`@Model`、`@State`）套沙箱会失败并报出大量假的「external macro implementation type … could not be found」。Xcode 图形界面点 Run 不需要这个开关。

---

## 测试

```bash
xcodebuild -project FoodJournal.xcodeproj -scheme FoodJournal \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build/DerivedData \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' test
```

当前 **210 个测试**（207 XCTest + 3 Swift Testing），覆盖服务层聚合逻辑、识别流程状态机、业务日换算、导出导入去重等。测试统计注意：XCTest 输出 `Test Case ... passed`，Swift Testing 输出 `✔`，两者都要计入。

---

## 隐私

- 饮食、体重、小记、健康快照**全部存本机** SwiftData，App 不含任何自建后端
- LLM API Key 存 Keychain；请求直连所选厂商端点，不经过第三方中转
- 佳明账号密码与令牌仅本地保存（Keychain）
- 健康数据只读，不写回 Apple 健康
- 仓库内**不含**任何密钥、账号、证书与描述文件

---

## 已知限制

| 项 | 说明 |
|---|---|
| 分发方式 | 免费 Apple ID 侧载，签名 7 天有效；到期需覆盖安装续期（**不要删除 App**，删除会清空本地数据） |
| 系统版本 | 需要 iOS 26+（SwiftData 与部分 SwiftUI API 依赖） |
| 工程文件 | `.xcodeproj` 为生成物，不入库；克隆后必须先 `xcodegen generate` |
| 佳明 | 依赖佳明账号与接口，接口变更可能影响同步 |

---

## 文档（docs/）

| 文件 | 内容 |
|---|---|
| `真机测试指南.md` | 环境准备、签名配置、验收清单、命令行推送、排障 |
| `M0-实测记录.md` / `M0-识图评估.md` / `M0-端点校准.md` | LLM 通道与识图能力实测（含模型对比、延迟） |
| `M2-thinking提速验证.md` | 关闭 thinking 后的识图延迟对比 |
| `E2S-登录流程规格.md` | 佳明登录流程技术规格（依据 garth 0.8.0 源码） |
| `E2S-spike结果.md` / `R5-5-garmin验证.md` | 佳明接入可行性验证与账号验证报告 |
| `test-images/` | 识图评测用样本图 |

---

## 说明

个人自用项目，暂无开源计划；代码与文档均为作者本人整理，第三方组件仅使用系统框架。
