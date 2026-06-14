# Release Checklist

记录发布前必须完成的准备事项。每次发布新版本前对照检查。

首次整理：2026-05-27

---

## ⏳ 待付费账号统一处理（$99 Apple Developer，预计 2026-06-08 当周到位）

> 以下全部**阻塞在付费账号**，账号一到位作为一批集中做。代码/文档侧能做的已完成（见下方各节 ✅）。

1. **WeatherKit**：Developer Portal → App ID 勾选 WeatherKit → 保存 → Xcode 重下 Provisioning Profile → **然后才把 `com.apple.developer.weatherkit` 加回 `Carry.entitlements`**（⚠️ 免费 Personal Team 不支持 WeatherKit，entitlement 提前加会导致真机签名失败，故现已撤回，详见 §1）
2. **iCloud 同步（这版做）**：Developer Portal 建 CloudKit 容器 `iCloud.com.murphy.carry` + 加 iCloud/CloudKit capability → `ModelConfiguration` 切 `cloudKitDatabase: .automatic`（保留本地/in-memory fallback）→ 真机跨设备联调 + 删 App 重装验证恢复。**schema 已确认 CloudKit 兼容、无迁移风险**（详见记忆 `carry-icloud-todo`）
3. **ASC 政策项**：隐私营养标签（位置 + 天气坐标 = 功能性、不追踪）、出口合规（勾豁免加密）、支持 URL、年龄分级（4+）、填元数据（用 `app-store-metadata.md`，审核备注已含 HealthKit/WeatherKit ✅）
4. **TestFlight + 监控**：Release build 跑核心流程、接崩溃监控（Xcode Organizer 免费）
5. **HealthKit 经期**：上架前剩余真机验证 + 文案定稿（详见记忆 `carry-healthkit-todo`）
6. **Build number**：每次提交 ASC 递增 `CFBundleVersion`

---

## 1. 工程层面

- [x] **Release build 配置**：`SWIFT_COMPILATION_MODE = wholemodule`，`SWIFT_OPTIMIZATION_LEVEL` 沿用 Xcode 默认 `-O`，配置正确 ✅（2026-05-27 确认）
- [x] **Strip debug symbols**：`STRIP_SWIFT_SYMBOLS` 沿用 Xcode 默认 YES，Archive 时自动 strip ✅（2026-05-27 确认）
- [x] **CarryLogger 敏感数据**：无 console 输出；geocodeFailed 已用 #if DEBUG 区分，Release 下仅记录 city_len，不记录城市名内容 ✅（2026-05-27）
- [x] **Asset Catalog 完整性**：散落的 PNG 均为 Alternate Icon，iOS 规范要求放在 bundle 根目录，非问题 ✅（2026-05-27 确认）
- [x] **App Icon 完整性**：AppIcon.appiconset 含 Light/Dark 1024×1024，iOS 16+ 单尺寸方式，Archive 自动生成全尺寸 ✅（2026-05-27 确认）
- [x] **开发者选项隔离**：`DeveloperModeView` 已有 `#if DEBUG` 保护 ✅（2026-05-27 确认）
- [x] **SwiftData migration plan**：新版本如有 schema 变更，migration 已覆盖 ✅（已有 CarryMigrationPlan）
- [ ] **Build number 递增**：每次提交 App Store Connect，`CFBundleVersion` 必须比上一次大
- [ ] ⚠️ **WeatherKit 能力配置**（含天气功能的版本发布前必做）：
  1. [ ] `Carry.entitlements` 加 `com.apple.developer.weatherkit`（⚠️ **2026-06-01 曾提前加，导致免费 Personal Team 真机签名失败「do not support the WeatherKit capability」，已撤回**。务必在付费账号 + 下面 2/3 步完成后再加回）
  2. [ ] Developer Portal → App ID → 勾选 WeatherKit → 保存（**需付费账号，未做**）
  3. [ ] Xcode 重新下载 Provisioning Profile（**需付费账号，未做**）
  4. ✅ 隐私政策已补天气条款（carry-legal privacy/zh.html + index.html，2026-06-01 已发布）

---

## 2. Apple 政策层面

- [ ] **Privacy Nutrition Labels**：在 App Store Connect 填写数据收集声明
  - 位置数据：CLGeocoder（目的地解析）+ MapKit（当前位置显示）→ 声明为「功能性」用途，**未与身份关联，未用于追踪**（2026-05-30 代码审计确认）
  - 日历数据：仅写入设备本地日历，不上传服务器 → **无需在隐私标签中申报**
  - 无广告追踪、无第三方 SDK、无跨 App 数据共享 → 可勾选对应豁免项
  - ⚠️ **接入 WeatherKit 后新增**：目的地坐标发送至 Apple Weather 服务 → 同样声明为「功能性」用途
- [ ] **出口合规（Export Compliance）**：仅使用 HTTPS + StoreKit 标准加密，勾选「使用豁免加密」
- [ ] **App Store Connect 应用分类**：确认与工程 `LSApplicationCategoryType = public.app-category.travel` 一致（2026-05-30 代码审计确认已配置）
- [ ] **年龄分级**：按问卷填写，无暴力/成人内容，预期 4+（2026-05-30 代码审计确认内容合规）
- [ ] **支持 URL**：App Store Connect 必填，需要真实可访问的页面（联系邮件页亦可）
- [x] **隐私政策 URL**：https://murphy-lyu.github.io/carry-legal/privacy/ ✅（2026-05-27 上线）

---

## 3. 隐私协议 & 用户协议层面

- [x] **隐私政策页面上线**：https://murphy-lyu.github.io/carry-legal/privacy/ ✅（2026-05-27）
- [x] **隐私政策内容覆盖**：✅（2026-05-27 确认，含位置访问、通知、StoreKit、GDPR/CCPA）
- [x] **接入 WeatherKit 后新增**：✅ 已更新隐私政策位置数据章节 + 第三方服务，补充「目的地坐标通过 WeatherKit 发送至 Apple 用于获取天气预报」（中英，2026-06-01 发布）
- [x] **用户协议页面上线**：https://murphy-lyu.github.io/carry-legal/terms/ ✅（2026-05-27）
- [x] **App 内隐私入口**：`LegalViews` 链接已指向 GitHub Pages，可访问 ✅
- [x] **本地通知说明**：隐私政策 Section 5 已注明 ✅

---

## 4. 多语言

所有 9 种语言均在 `Localizable.xcstrings` 中全程维护，新增/修改文案时同步更新所有语言（见 CLAUDE.md 本地化规范）。

发布前检查：确认本次版本新增或修改的所有 key，9 种语言均已补全：

- [ ] en（英语）
- [ ] zh-Hans（简体中文）
- [ ] zh-Hant（繁体中文，台湾/香港用语）
- [ ] de（德语）
- [ ] es（西班牙语）
- [ ] fr（法语）
- [ ] ja（日语）
- [ ] ko（韩语）
- [ ] pt-BR（葡萄牙语-巴西）

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
  - [ ] 显示名称（三语）：`Carry: Travel Packing List` / `启程: 旅行打包清单` / `啟程: 旅行打包清單`（**刻意不叫 Travel Planner**——规划功能未上线，避免名不副实）
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

## 已上线版本历史

| 版本 | 日期 | 备注 |
|------|------|------|
| 首次上线 | 2026-05 | — |

---

*每次发布新版本后，在上方表格补充记录，并重新过一遍 checklist。*
