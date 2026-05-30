# Release Checklist

记录发布前必须完成的准备事项。每次发布新版本前对照检查。

首次整理：2026-05-27

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
  1. Xcode → Signing & Capabilities → 添加 WeatherKit
  2. Developer Portal → App ID → 勾选 WeatherKit → 保存
  3. Xcode 重新下载 Provisioning Profile

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
- [ ] ⚠️ **接入 WeatherKit 后新增**：更新 https://murphy-lyu.github.io/carry-legal/privacy/ 中位置数据章节，补充「目的地坐标通过 WeatherKit 发送至 Apple 服务器用于获取天气预报」
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

## 5. 发布流程 & 其他

- [ ] **TestFlight 内测**：提交正式版前用 Release build 完整跑一遍核心流程
- [ ] **崩溃监控**：接入 Xcode Organizer Crash Reports（免费，Apple 原生）或 Firebase Crashlytics
- [ ] **App Store Connect 元数据**：
  - [ ] 副标题（Subtitle，≤25 字，影响搜索权重）
  - [ ] 关键词（Keywords，认真选，直接影响搜索排名）
  - [ ] 主分类 + 次分类
  - [ ] 审核备注（Review Notes）：说明内购操作路径、通知权限触发时机
- [ ] **`exit(0)` 说明**：仅在 `#if DEBUG` 下可见，不影响线上用户，无需处理 ✅

---

## 已上线版本历史

| 版本 | 日期 | 备注 |
|------|------|------|
| 首次上线 | 2026-05 | — |

---

*每次发布新版本后，在上方表格补充记录，并重新过一遍 checklist。*
