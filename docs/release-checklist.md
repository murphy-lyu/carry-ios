# Release Checklist

记录发布前必须完成的准备事项。每次发布新版本前对照检查。

首次整理：2026-05-27

---

## Apple Developer / App Store Connect 状态（2026-09-26，2026-10-21 本地复核）

- [x] 付费 Apple Developer 团队已切换为 `Bing Xue`（Team ID `25RAM7275Z`），App 与 Widget 均可正式签名。
- [x] Bundle ID 已统一为 `app.nevestudio.carry`，Widget 为 `app.nevestudio.carry.widget`，App Group 为 `group.app.nevestudio.carry`。
- [x] WeatherKit、HealthKit、App Group、iCloud/CloudKit 已进入 provisioning profile；Release 真机构建与安装通过。
- [x] SwiftData 已启用 CloudKit `.automatic`，容器为 `iCloud.app.nevestudio.carry`；本地初始化失败时仍保留 in-memory fallback。
- [x] 真机冷启动成功，设备内事件日志无 `db_init_failed`，确认未进入 in-memory fallback。
- [ ] 两台登录同一 iCloud 账号的设备验证新增、修改、删除双向同步；再做删除 App 后重装恢复。
- [ ] CloudKit Development schema 确认无误后部署到 Production；存在 schema 变更的新 TestFlight 构建也必须先完成此步，不能只等正式上架。
- [x] App Store Connect 应用记录已创建：Apple ID `6816165107`，状态 `Prepare for Submission`。
- [x] TestFlight build `1.0 (1)` 已于 2026-09-26 上传并处理完成；首次出口合规已手工确认。
- [x] TestFlight build `1.0 (2)` 已上传并处理完成，安装包内含出口合规键与 HealthKit 双用途说明，无需再次回答加密问题。
- [x] 已创建内部测试组 `Carry Internal`，开启 Xcode 构建自动分发；管理员与账户持有人均已加入。build 1、2 均已分配，后台显示各有 `2` 个邀请。
- [x] TestFlight 测试资料、审核联系人、隐私政策 URL、审核备注和 build 1 的「测试重点」已填写。
- [ ] 填写正式版本的政策项、内购和元数据；内测分组与 TestFlight 测试资料已配置。
- [ ] HealthKit 经期与 WeatherKit 天气仍需真机功能验收。
- [x] 版本已递增为 `1.0 (3)`，Release 模拟器目标构建通过。（2026-10-21）
- [x] Swift 6 并发前瞻检查：Live Activity 共享 attributes 已显式设为 `nonisolated`，消除 8 处未来会升级为错误的 actor isolation 警告。（2026-10-21）
- [x] `1.0 (3)` Release Archive 与 App Store Connect 分发导出成功；导出的 IPA 为 Production CloudKit、`beta-reports-active = true`、`get-task-allow = false`，App 与 Widget 签名及 entitlement 均已核对。（2026-10-21）
- [x] TestFlight build `1.0 (3)` 已上传成功，App Store Connect 已接收并开始处理；处理完成后的分组与 Beta App Review 状态待后台确认。（2026-10-21）

---

## 1. 工程层面

### Codex 连接发布门禁（2026-10-22）

- [x] 默认授权范围的 40 项工具实现；两轮本地自动验收与自行代码审查，证据见 `docs/codex-integration-qa.md`。
- [x] 新增回执模型本地旧库迁移、旧 JSON 备份兼容、真实 Keychain、事务保存与重复请求验证。
- [x] 主 App + Widget Release 真机目标构建；9 语言审计 0 errors / 0 warnings。
- [x] 中英隐私政策修改、push 和原 Pages 项目部署；英文线上新条款已读回。
- [x] 中文线上新条款完整读回（2026-10-25）；解码 Cloudflare 邮箱保护并移除对应注入脚本后，完整 HTML 与已提交源码一致。
- [x] 功能分支已推送 GitHub；最终 Worker 源码已部署，版本 `14cc66af-d01a-4a71-a9c3-c60c9842d822`（2026-10-25）。
- [x] 生产完整合成配对/命令/回执/撤销链路两轮各 12/12 通过（2026-10-25）；原始 Node fetch 脚本使用普通域名和证书验证，测试连接已撤销。此前 curl/代理传输超时仍记录为历史网络波动，不等于所有网络环境可用。
- [ ] 原生 URLSession 连接生产服务的完整 SwiftData 往返验收：补充测试已确认创建命令、本地落盘和首个回执，随后重复回执请求 `-1001` 超时，未完成快照读回（2026-10-25）；不能用 Node 协议验收替代。
- [ ] 在 `Bing Xue / 25RAM7275Z` 团队核对 `AutomationExecutionRecord` 的 Development schema 并部署 Production；用户已暂缓登录，待其方便时继续（2026-10-25）。
- [ ] 新功能真机界面、配对、离线恢复、前后台竞争、iCloud 账号切换与真实双设备同步验收。
- [ ] 按新数据用途核对 App Store Connect 隐私声明后，才上传包含连接功能的新 TestFlight 构建。当前旧 build 3 不包含本功能，未上传后续构建。

### 工程基线

- [x] **Release build 配置**：`SWIFT_COMPILATION_MODE = wholemodule`，`SWIFT_OPTIMIZATION_LEVEL` 沿用 Xcode 默认 `-O`，配置正确 ✅（2026-05-27 确认）
- [x] **Strip debug symbols**：`STRIP_SWIFT_SYMBOLS` 沿用 Xcode 默认 YES，Archive 时自动 strip ✅（2026-05-27 确认）
- [x] **CarryLogger 敏感数据**：无 console 输出；geocodeFailed 已用 #if DEBUG 区分，Release 下仅记录 city_len，不记录城市名内容 ✅（2026-05-27）
- [x] **Asset Catalog 完整性**：散落的 PNG 均为 Alternate Icon，iOS 规范要求放在 bundle 根目录，非问题 ✅（2026-05-27 确认）
- [x] **App Icon 完整性**：AppIcon.appiconset 含 Light/Dark 1024×1024，iOS 16+ 单尺寸方式，Archive 自动生成全尺寸 ✅（2026-05-27 确认）
- [x] **开发者选项隔离**：`DeveloperModeView` 已有 `#if DEBUG` 保护 ✅（2026-05-27 确认）
- [x] **SwiftData migration plan**：新版本如有 schema 变更，migration 已覆盖 ✅（已有 CarryMigrationPlan）
- [x] **Build number 递增**：build 3 已上传；后续再次上传时从 4 继续递增
- [x] **WeatherKit 能力配置**：
  1. [x] `Carry.entitlements` 已加入 `com.apple.developer.weatherkit`
  2. [x] Apple Developer App ID 已启用 WeatherKit（Automatic Signing 已成功创建 profile）
  3. [x] 新 provisioning profile 已下载并用于 Release 真机构建（2026-09-25）
  4. ✅ 隐私政策已补天气条款（carry-legal privacy/zh.html + index.html，2026-06-01 已发布）
- [x] **HealthKit 上传校验**：补齐 App Store 要求的 `NSHealthUpdateUsageDescription`；功能仍只请求经期数据读取权限，不请求写入权限。
- [x] **出口合规**：项目未实现加密算法；网络加密仅使用 Apple 系统 HTTPS，`ITSAppUsesNonExemptEncryption = NO`。首个已上传构建已在 App Store Connect 选择“None of the algorithms mentioned above”。

---

## 2. Apple 政策层面

- [ ] **Privacy Nutrition Labels**：在 App Store Connect 填写数据收集声明
  - 位置数据：CLGeocoder（目的地解析）+ MapKit（当前位置显示）→ 声明为「功能性」用途，**未与身份关联，未用于追踪**（2026-05-30 代码审计确认）
  - 日历数据：**写入**行程/提醒到本地日历 + 「日历叠加」**读取**用户所选日历事件，**全程仅设备本地处理、零上传** → 隐私标签填「**未收集**」（2026-06-21 权限复核确认 read+write 均不离设备）
  - 健康数据（经期，HealthKit）：仅设备本地只读、零传输 → 隐私标签填「**未收集**」；ASC 健康数据问卷据实勾选（已 opt-in、本机预测，审核备注已含 HealthKit）
  - 航班查询 / 地点检索：发送的查询参数（航班号+日期 / 检索词+目的地大致坐标）**不关联身份**；按 ASC 口径，若不关联用户身份且仅用于功能，可声明为「功能性、未与身份关联、不用于追踪」
  - 无广告追踪、无第三方分析 SDK、无跨 App 数据共享 → 可勾选对应豁免项
  - ⚠️ **接入 WeatherKit 后新增**：目的地坐标发送至 Apple Weather 服务 → 同样声明为「功能性」用途
- [x] **出口合规（Export Compliance）**：仅使用 Apple 系统 HTTPS + StoreKit 标准加密，项目已声明 `ITSAppUsesNonExemptEncryption = NO`；build 1 已完成问卷确认
- [ ] **App Store Connect 应用分类**：确认与工程 `LSApplicationCategoryType = public.app-category.travel` 一致（2026-05-30 代码审计确认已配置）
- [ ] **年龄分级**：按问卷填写，无暴力/成人内容，预期 4+（2026-05-30 代码审计确认内容合规）
- [x] **支持页面**：`https://legal.nevestudio.app/carry/support/zh`（中英双语；创建应用记录后填入 ASC）
- [x] **隐私政策页面**：`https://legal.nevestudio.app/carry/privacy/zh` 已作为正式地址

---

## 3. 隐私协议 & 用户协议层面

- [x] **隐私政策页面上线**：https://legal.nevestudio.app/carry/privacy/zh
- [x] **隐私政策内容覆盖**：✅（2026-05-27 确认，含位置访问、通知、StoreKit、GDPR/CCPA）
- [x] **接入 WeatherKit 后新增**：✅ 已更新隐私政策位置数据章节 + 第三方服务，补充「目的地坐标通过 WeatherKit 发送至 Apple 用于获取天气预报」（中英，2026-06-01 发布）
- [x] **用户协议页面上线**：https://legal.nevestudio.app/carry/terms/zh
- [x] **App 内隐私入口**：`LegalViews` 已指向 `legal.nevestudio.app`，可访问 ✅
- [x] **本地通知说明**：隐私政策 Section 5 已注明 ✅
- [x] **权限文案全面复核**（2026-06-21）：系统弹窗文案统一第二人称「你」、定位声明从 pbxproj 迁入 Info.plist 单点维护；日历文案补「读取叠加显示」（实现既写入又读取所选日历，需 Full Access）；相册确认纯 PHPicker、不申请授权（隐私最佳实践）；通知/Live Activity 无需 usage description（核对无误）✅
- [x] **隐私政策补日历披露**（2026-06-21）：Section 5 新增日历段（写入行程/提醒 + 「日历叠加」读取所选日历、均设备本地零传输）、标题加「日历」；PIPL 第 14 条同步——处理目的改「旅行助手」、撤回同意权加日历、跨境处理据实披露（境外地点检索关键词在境外处理、不关联身份、提供不使用即可避免的退路），消除原「零传输」与 Section 5 已披露的航班/境外检索传输之间的自相矛盾。中英同步 ✅
- [x] **用户协议定位更新**（2026-06-21）：terms 从「旅行打包清单应用」改「旅行助手应用（行程规划 + 打包）」、并修正失真的「不依赖网络连接」表述（航班/检索/天气/地图为可选联网功能）。中英同步 ✅
- [ ] **ASC 隐私政策 / 用户协议 URL**：应用记录创建后填 `https://legal.nevestudio.app/carry/privacy/zh` 与 `https://legal.nevestudio.app/carry/terms/zh`。

---

## 4. 多语言

所有 9 种语言均在 `Localizable.xcstrings` 中全程维护，新增/修改文案时同步更新所有语言（见 CLAUDE.md 本地化规范）。

发布前检查：确认本次版本新增或修改的所有 key，9 种语言均已补全：

- [x] en（英语）
- [x] zh-Hans（简体中文）
- [x] zh-Hant（繁体中文，台湾/香港用语）
- [x] de（德语）
- [x] es（西班牙语）
- [x] fr（法语）
- [x] ja（日语）
- [x] ko（韩语）
- [x] pt-BR（葡萄牙语-巴西）

2026-10-21 执行 `scripts/i18n-audit.py`：App 与 Widget 均为 0 errors / 0 warnings。

---

## ⛔ 版本升级必查（每次大版本发布前，防止老用户崩溃）

> 首版上线后，每次发布新版本必须额外对照此节。

- [ ] **SwiftData schema 变更类型判断**
  - 只加带默认值的字段 → 轻量迁移，SwiftData 自动处理，无需新版本 ✅
  - 重命名/删除字段/改关系 → **非轻量**，必须冻结旧版快照 + 新建 SchemaV{N+1}（见 `CarrySchema.swift` 末尾模板；做错会让所有老用户启动崩溃）
- [ ] **真机迁移验证**：用真实老版本数据安装新版，确认数据完整、App 正常启动（模拟器复现不了迁移崩溃）
- [ ] **CarryBackup 格式变更**：改了 `CarryBackup` 结构 → 同步在 `restoreFromData` 加版本判断，防止跨版本还原崩溃
- [ ] **UserDefaults key 变更**：key 不能直接改名，须新 key + 一次性迁移旧值 + 删旧 key
- [ ] **App Group / Widget 快照格式**：`WidgetTripSnapshot` 字段变更须保持向后兼容（Widget 进程可能读旧格式）

## 5. 发布流程 & 其他

- [ ] **TestFlight 内测**：提交正式版前用 Release build 完整跑一遍核心流程
- [ ] **崩溃监控**：接入 Xcode Organizer Crash Reports（免费，Apple 原生）或 Firebase Crashlytics
- [ ] **App Store Connect 元数据**（文案见 `app-store-metadata.md`）：
  - [ ] 显示名称（三语）：`Carry: Trip Planner & Packing` / `启程：让每一次出发更从容` / `啟程：讓每一次出發更從容`
  - [ ] 副标题（Subtitle，≤30 字符，影响搜索权重）：en / zh-Hans / zh-Hant 三语已定稿，补名称未含的新词
  - [ ] 关键词（Keywords，认真选，直接影响搜索排名）
  - [ ] 主分类 + 次分类
  - [ ] 审核备注（Review Notes）：说明内购操作路径、通知权限触发时机
- [ ] **App Store 截图**（脚本 + 模拟数据 + 中英 slogan 见 `app-store-screenshots.md`，6 帧）：
  - [ ] iPhone 6.9"（1290×2796，**必需**）：en-US + zh-Hans 两套，各 6 帧
  - [ ] iPad 13"（2064×2752）+ Mac/Catalyst（2880×1800）：可在 iPhone 版定稿后补；首版至少保证 6.9" 一套，其余 fallback
  - [ ] 数据清洗：删名为 `Test` 的行程、状态栏锁 9:41、地球旗子标签不重叠、统一深色
  - [ ] 第 4 帧用出国行程（230V，如 London & Paris & Amsterdam）触发电压橙标
  - [ ] 第 5 帧用「两天后出发」的行程 + 先进一次清单页，才能触发 Live Activity
  - [ ] 中英两版 = 同构图 + 切系统语言重截 UI + 换 slogan 文字层（中文版数据也要本地化）
  - [ ] 文件：PNG、RGB、无 alpha 透明通道
- [ ] **`exit(0)` 说明**：仅在 `#if DEBUG` 下可见，不影响线上用户，无需处理 ✅

## 6. 功能行为验收（真机/模拟器）

- [ ] **优化路线「道路口径判定」4 态走查**（spec: `itinerary-optimize-road-gating.md`）——逐态确认渲染与触发正确：
  - [ ] **improved**：道路确认有省 → 显示节省 + 「采用此顺序」，注脚「按道路距离」（车图标）。（已初步见 84→80）
  - [ ] **computing**：多停靠点天进「优化顺序」头几秒 → 判定区「计算中…」+ spinner、底部 CTA 灰禁用。
  - [ ] **notImproved**：道路没省/更长 → 判定区收「已是较优」、底部中性「完成」，**无「节省 0/变长」**。（数据不易稳定复现，必要时加临时 `#if DEBUG` verdict 覆盖测渲染、测后删）
  - [ ] **offline**：飞行模式 → 退回直线判定，注脚「按直线距离」（尺子图标），「采用」可点。
  - [ ] 9 语言扫一眼判定区/CTA 文案（复用 `calculating`/`optimal.*`/`done`，无新增 key）。

---

## 正式发布记录

| 版本 | 日期 | 备注 |
|------|------|------|
| 暂无 | — | 当前仅 TestFlight，尚未正式上架 |

---

*每次发布新版本后，在上方表格补充记录，并重新过一遍 checklist。*
