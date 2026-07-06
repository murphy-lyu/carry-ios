# Widget 兜底显示「规划中」行程（Widget Planning Trip Fallback）

> **Status: Shipped.** 已实现，待真机验收。

## 动机

Widget（1×1 / 1×4 / 4×4）现在的相位优先级是「进行中」→「即将出发（有日期）」，两者都没有时**一律显示空状态**（`emptyView`：行李箱图标 + "No upcoming trip" 文案）。

但 App 首页早已有第三种行程状态——「规划中」（`isDateless == true`，先建行程/清单，日期以后再定，`specs/dateless-planning-trips.md`），首页明确把它单独分区展示（Upcoming 之后、Past 之前）。Widget 完全没有对应这个状态——`TripStore.writeWidgetSnapshot()` 的 `active` 过滤直接 `guard !trip.isDateless else { return false }`，把所有规划中行程整体排除。结果是：只要用户手头没有已经定下日期的行程，Widget 就是空的，即使他其实正在认真规划下一趟旅行、打包清单已经建了一半。

**产品方向**：Widget 相位优先级补第三级兜底——**进行中 > 有日期的即将出发 > 规划中（无日期，取最新创建的一个）**。规划中兜底只在前两级都没有候选时才出现，且不与「有日期」的行程混排（不进 Medium 的 primary/secondary 双槽逻辑，只作为「完全没有其它候选」时的单一兜底）。

## 现状代码（改动前必读）

- `TripStore.writeWidgetSnapshot()`（`Carry/Models/TripStore.swift:3403-`）：`active` 过滤排除 `isDateless`，按 `departureDate` 升序取前 3 个。
- `WidgetTrip.phase(asOf:)`（`CarryWidget/CarryWidget.swift`）：**已经**对 `isDateless == true` 的行程返回 `.preTrip`（`guard let returnDate, !(isDateless ?? false) else { return .preTrip }`）——但这条路径目前永远不会触发，因为规划中行程根本不会进入 snapshot。
- `smallView` / `mediumView` / `largePreTripView`：都直接调用 `countdownText(for: trip.departureDate)` 和 `widgetHeader`（写死 "Upcoming" 文案）。规划中行程的 `departureDate` 是创建时的占位值（`dateless-planning-trips.md` 明确警告"占位日期是 bug 之源"），**绝不能**被这几处直接拿去算倒计时——否则会显示一个随时间推移、毫无意义的"过期"倒计时。

## 设计

### 1. 兜底候选的产生（`TripStore.writeWidgetSnapshot`）

```
若 active（有日期、未结束）非空 → 沿用现状，不变。
否则 → 从 trips 里筛 isDateless == true 的，按 createdAt 降序取第 1 个，作为唯一候选写入 snapshot。
```

- 「最新」＝`createdAt` 降序（规划中行程没有日期可排，`createdAt` 已存在于 `TripBundle`，天然满足"最新创建"语义，不需要新字段）。
- 兜底候选**只取 1 个**，不取多个——Widget 三个尺寸目前的「多行程」逻辑（Medium 的 secondary 槽）都是围绕「有日期、可排序」设计的，规划中行程混进去没有意义（两个规划中行程之间没有"谁更该显示"的进一步依据，也不需要支持）。
- `WidgetTripSnapshot.isDateless` 字段已存在（`Codable`，非可选），无需加字段；`packedCount`/`totalCount` 正常计算；`events`/`stays`/`plan`/`agenda` 对规划中行程传空数组（día-based 概念对无日期行程没有意义，见下）。

### 2. Widget 侧渲染（`CarryWidget.swift`）

`phase(asOf:)` 已经能正确识别 `isDateless` → `.preTrip`，不用改。**但 preTrip 的三个视图不能直接照搬**，因为它们假设「有 `departureDate` 可以算倒计时」。改法：

- **`widgetHeader` 拆成按需传参**：新增 `isPlanning: Bool` 参数（默认 `false`），为真时图标/文案换成 "Planning"（新 key `widget.header.planning`，复用主 App 已有的 `home.planning` 翻译，9 语言直接照抄，语义完全一致）。
- **倒计时文字整体隐藏**：`smallView` / `mediumView` / `largePreTripView` 里 `Text(countdownText(for: trip.departureDate))` 这一行，`trip.isDateless == true` 时不渲染（不是"显示个错误倒计时"，是"这一整行没有对应概念，就不显示"）。
- **`largePreTripView` 的 "day 1 预览" 分块整体跳过**：规划中行程没有出发日、没有"今天"锚点，`upcomingAgenda(asOf:)` 对它不该被调用（`plan`/`agenda` 本就传空数组，`day1` 天然为空，`if !day1.isEmpty` 分支自然不触发——不需要额外分支，只要 snapshot 侧老实传空数组即可）。
- 三个视图改动后的样子：
  - **1×1**：Planning 标签 + 行程名 + 打包进度条 + 百分比（去掉倒计时那一行）。
  - **1×4**：同上布局比例放大，**不显示 secondary 行程**（`mediumView` 的 `secondary` 参数传 `nil`）。
  - **4×4**：Planning 标签 + 行程名 + 打包进度 + 百分比，不显示 day1 预览分块。

### 3. 本地化

新增 `widget.header.planning`（命名空间跟随现有 `widget.header.upcoming`），9 语言值直接照抄主 App `home.planning`：

| 语言 | 值 |
|---|---|
| en | Planning |
| zh-Hans | 规划中 |
| zh-Hant | 規劃中 |
| de | In Planung |
| es | En planificación |
| fr | En préparation |
| ja | 計画中 |
| ko | 계획 중 |
| pt-BR | Em planejamento |

## 涉及范围

- `Carry/Models/TripStore.swift`：`writeWidgetSnapshot()` 加规划中兜底分支。
- `CarryWidget/CarryWidget.swift`：`widgetHeader` 加参数；`smallView`/`mediumView`/`largePreTripView` 按 `trip.isDateless` 隐藏倒计时行；`mediumView` 调用点在无 active 行程、只有兜底候选时不传 secondary。
- `CarryWidget/Localizable.xcstrings`：新增 `widget.header.planning`（9 语言）。
- 不涉及 SwiftData schema 变更、不涉及主 App `Localizable.xcstrings`。

## 边界 / 不做

- 不支持多个规划中行程轮流显示——只取最新创建的一个，够用即可，不为这个兜底场景做复杂的多行程管理。
- 不给规划中行程编造"倒计时"或"第几天"之类的假日期概念——isDateless 的核心承诺是"所有日期相关功能优雅降级"，Widget 必须遵守，不能因为兜底场景就破例。
- Live Activity（打包/交通）不受影响——两者本就要求有日期（`LiveActivityManager` 依赖 `departureDate`），规划中行程天然不触发，本 spec 不改动这部分。
