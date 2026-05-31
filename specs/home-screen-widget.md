# Home Screen Widget — Spec

> **Status: Implemented（待 App Group 配置 + 真机验证）** — 2026-05-31
> 由 Claude 按理解实现，等待开发者确认。

## 背景

`CarryWidget` target 目前只有 Live Activity（锁屏/灵动岛）。主屏幕 Widget 仍是 Xcode 模板占位（emoji 示例 `CarryWidget.swift`），且**未在 `CarryWidgetBundle` 注册**，所以用户在主屏幕加不到 Carry 小组件。

## 目标

提供一个主屏幕 Widget，展示**即将出发的行程**及其打包进度，呼应 App 核心（打包清单）。点击跳转对应行程。

- **Small**：下一个即将出发的行程——目的地、出发倒计时、打包进度环。
- **Medium**：下一个行程详情 + 最多再列 1 个后续行程的简要进度。
- **空状态**：无即将出发的行程时显示引导文案。

## 数据共享方案

Widget 在独立进程，无法直接访问主 App 的 SwiftData。采用 **App Group + UserDefaults JSON 快照**（轻量、不动 SwiftData 容器、无数据迁移风险）：

- **不**改 `ModelContainer` 为 App Group 容器——那会改变现有用户数据的存储位置，导致数据丢失。
- 主 App 在生命周期节点把「即将出发 top 3 行程」的精简快照写入 App Group 的 `UserDefaults`，Widget 读取。

### App Group

- ID：`group.com.murphy.carry`
- **需开发者在 Xcode 操作**（见下方「待确认」）：给 `Carry` 和 `CarryWidgetExtension` 两个 target 在 Signing & Capabilities 添加 App Group `group.com.murphy.carry`。Automatic signing 会自动同步 entitlements + provisioning。
- 未配置时：`UserDefaults(suiteName:)` 返回 nil，Widget 安全降级为空状态，App 不崩。

### 快照结构

精简镜像（不依赖 SwiftData 类型），主 App 与 Widget 各定义一份字段一致的 `Codable`，通过 JSON 跨进程传递（避免新增 SharedSources 文件 / 改 pbxproj）：

```swift
{ tripId, name, destinationCity, departureDate, packedCount, totalCount }
```

- Key：`carry_widget_trips`（JSON `[WidgetTripSnapshot]`）
- 写入内容：`departureDate >= 今天0点` 的行程，按出发日升序，取前 3。

### 写入时机

集中在 `CarryApp` 生命周期，避免散落改 TripStore 的每个 mutation：
- `onAppear`（启动/回到内容）
- `didEnterBackground`（用户改完数据切后台 → 立即刷新 Widget）

每次写入后调 `WidgetCenter.shared.reloadAllTimelines()`。

## 倒计时本地化（避免复数陷阱）

按天数分支，绕开各语言复数规则：
- `days == 0` → `widget.countdown.today`（Today / 今天）
- `days == 1` → `widget.countdown.tomorrow`（Tomorrow / 明天）
- `days > 1`  → `widget.countdown.days_left` = `"%d days left"` / `"还有 %d 天"`（已排除 0/1，>1 时各语言均为复数形态，单一字符串即可）

进度：`widget.progress.packed` = `"%1$d / %2$d packed"` / `"已打包 %1$d / %2$d"`。
空状态：`widget.empty.title` / `widget.empty.subtitle`。

文案走 `CarryWidget/Localizable.xcstrings`（widget 专属，不共享主 App），9 语言全补。

## 文件改动（全部修改现有文件，零 pbxproj）

| 文件 | target | 改动 |
|------|--------|------|
| `Carry/Models/TripStore.swift` | 主 App | + `WidgetTripSnapshot`、+ `writeWidgetSnapshot()`、`import WidgetKit` |
| `Carry/CarryApp.swift` | 主 App | onAppear / didEnterBackground 调 `writeWidgetSnapshot()` |
| `CarryWidget/CarryWidget.swift` | Widget | 占位 emoji widget → 行程进度 widget（Provider + Entry + View） |
| `CarryWidget/AppIntent.swift` | Widget | 清理模板 emoji 配置（改用 StaticConfiguration） |
| `CarryWidget/CarryWidgetBundle.swift` | Widget | 注册新 Widget |
| `CarryWidget/Localizable.xcstrings` | Widget | 新增文案 × 9 语言 |

## 点击行为

Widget 设 `widgetURL(carry://trip/{tripId})`；`CarryApp.onOpenURL` 已处理 `carry://trip/{uuid}` → `router.pendingTripId` → 跳转打包清单。复用，零改动。

## 待开发者确认（明天）

1. **加 App Group capability**：Xcode → `Carry` target → Signing & Capabilities → + App Group → `group.com.murphy.carry`；对 `CarryWidgetExtension` target 重复。
2. **真机验证**：
   - 主屏幕添加 Carry Widget（Small / Medium）。
   - 有即将出发行程：显示目的地 + 倒计时 + 进度；点击进入该行程。
   - 改打包进度 → 切后台 → Widget 刷新。
   - 无即将出发行程：显示空状态。
3. 确认深浅色模式、9 语言文案显示正常。

## 设计取向

Apple 原生、极简、克制：进度用细环 / 细条，目的地为主信息，倒计时次之。不堆叠多余装饰。深浅色均用系统语义色，与锁屏 Live Activity 视觉语言一致。
