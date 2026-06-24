# Widget 旅行伴侣：随相位自适应的桌面小组件（Trip Companion Widget）

> **Status: ✅ Implemented — 编译绿（主 app + Widget Extension），待 UI 验收。** 未 push。
> **实现要点 / 与原 spec 的偏差**：
> - 数据刷新**未**在十几处 itinerary mutation 散加调用——现有 `CarryApp.didEnterBackground`（[CarryApp.swift:113](../Carry/CarryApp.swift:113)）+ `onAppear`（启动）已是天然漏斗，`writeWidgetSnapshot` 现读了 itinerary 数据，用户「编行程 → 离开 App → 看 Widget」即覆盖；Widget 自身靠 timeline entries 跨午夜/事件推进，无需 App 重开。比 spec 设想更克制、零冗余 reloadAllTimelines。
> - 改动文件：[TripStore.swift](../Carry/Models/TripStore.swift)（snapshot 模型 + `widgetEvents` 展开 + `absoluteDate` + 选片改「未结束」）、[CarryWidget.swift](../CarryWidget/CarryWidget.swift)（镜像结构 + 相位推导 + 旅行中 Small/Medium + timeline 多 entry）、[CarryWidget/Localizable.xcstrings](../CarryWidget/Localizable.xcstrings)（4 key × 9 语言，i18n-audit [E]=0）。
> - 修了一个自审 bug：`tonight` 文案带 `%@` 占位符却当无参标签渲染 → 改为 `String(format:)` 单 Text。
>
> **真机暴露并修复（2026-06-24）**：
> - 🔴 **空写竞态（`c789fab`）**：`writeWidgetSnapshot` 原在 `App.onAppear` 调，但那时 `store.trips` 常未异步加载完 → 写出**空 snapshot 覆盖好的那份**，Widget 变空白/只剩缓存旧渲染（读模拟器 App Group plist 实测确认 `trips=0`）。**根因解**：与 Quick Actions / 交通 LA 同款——移出 onAppear、挪进 `TripStore.init` Task（`fetchTrips` 之后、trips 必已加载），保留 `didEnterBackground`；**绝不在 trips 加载前写 snapshot**。
> - 🟢 **无时刻行程项也显示（`7a4cd02`）**：原「下一件事」只收**有时刻**的项（`plannedStartMinutes`/`departLocalMinutes` ≥ 0），故「排了地点但没填时间」的行程 Widget 啥都不显示。新增 `WidgetPlanItem`（含无时刻项，带 dayOrder/order/title/kind）进 snapshot；当天**无带时刻的下一件事**时，Widget 显示「今天的地点」（small 首项、medium 前 3 项 + `Today / 共 N 处` 副标题，无倒计时）。让「有行程规划就显示」真正成立。新增 widget key `today`/`today_count`/`plan_more`。

> **（原始 Draft）** 确认后再编码。
> 关联：`itinerary-route-planning.md`（时间轴/stop/segment 数据）、`itinerary-transport-lodging.md`（住宿/交通段）、`itinerary-timezone.md`（每活动时区 → 绝对时刻）、`dateless-planning-trips.md`（无日期行程边界）。
> 姊妹 spec：`widget-transit-live-activity.md`（出行日「下一程」Live Activity，独立实现）。

## 动机 / 现状根因

桌面小组件（`CarryWidget`）现在**只表达「打包」一件事**：即将出发行程名 + 倒计时 + 打包进度（[CarryWidget.swift](../CarryWidget/CarryWidget.swift)）。数据管线极窄——主 App 只往 App Group 写 6 字段（`tripId/name/destinationCity/departureDate/packedCount/totalCount`，[TripStore.swift:3069](../Carry/Models/TripStore.swift:3069)），且 `writeWidgetSnapshot` **只选「未来行程」**（`departureDate >= today`）、排除无日期行程、最多 3 条。

但打包只是出发**前几天**的事。一旦出发，打包早已完成，这张 Widget 对「人已在路上」的那几天**完全失去当下意义**——这是个真空。与此同时，行程规划已经把「今天第几天、接下来去哪、今晚住哪、几点退房」这些**旅行中每天都想瞄一眼**的信息都建好了，却从未出现在 Widget 上。

**根因不是「再加一个 Widget」，而是「同一张 Widget 没有随旅行相位切换它该说的话」。** 一趟旅行有清晰的三相：

| 相位 | 判定（有日期行程） | 用户此刻关心 |
|------|------|------|
| **出发前** | `today < departureDate` | 还有几天 · 打包进度（**现状，保持**） |
| **旅行中** | `departureDate ≤ today ≤ returnDate` | Day N / M · 下一件事 · 今晚住哪 / 退房 |
| **已结束** | `today > returnDate` | （不展示，行程自然落出 Widget） |

`returnDate = departureDate + days`，`spanDays = days + 1`（含两端日历天数）。**无日期行程没有「今天第几天」概念 → 旅行中相位对它不适用，维持只在出发前/不展示。**

## 核心原则

1. **Widget 不展示「整个计划」，只提炼「此刻的下一步」。** 价值不在信息量，恰在替用户从一整张时间轴里挑出当下唯一要紧的那条——契合 Carry「克制、聚焦」。整条时间轴 / 地图 / 花费**明确不进 Widget**（见「不做」）。
2. **Widget 不能依赖「用户每天打开 App」。** 旅行中用户可能一整天不开 App，但 Widget 必须仍显示正确的「今天」。→ snapshot 必须带**整段行程的事件**（每个事件预先算好**绝对 `Date`**），由 Widget 在渲染时按 `Date()` 自行决定「今天是 Day 几、下一件事是哪条」，并用 timeline entries 在每个事件边界 + 每日午夜推进。**绝不**只写「今天的事件」靠 App 被打开来刷新（脆弱、会显示昨天）。
3. **绝对时刻在 App 侧算，Widget 保持「哑」。** Widget 跑不了 SwiftData、也没有时区逻辑。每个有时间的活动（stop `plannedStartMinutes` / segment `departLocalMinutes` / 住宿 `checkInMinutes`/`checkOutMinutes`）按其**有效时区**（`effectiveTimeZoneId`，见 itinerary-timezone.md）换算成绝对 `Date` 后写进 snapshot。Widget 拿 `Date()`（设备绝对时刻）与之比较——跨时区天然正确（两边都是绝对时刻）。
4. **向后兼容铁律（升级安全）**：snapshot 加字段时，主 App（[TripStore.swift:3069](../Carry/Models/TripStore.swift:3069)）与 Widget 侧 `WidgetTrip`（[CarryWidget.swift:24](../CarryWidget/CarryWidget.swift:24)）**必须同步改**，新字段在 Widget 侧一律**可选 / 带默认值**——否则装了新版主 App（写含新字段 JSON）+ 未刷新的旧 Widget 进程会解码失败、显示空白。

## Snapshot 模型改动（数据管线）

`WidgetTripSnapshot`（主 App）与镜像 `WidgetTrip`（Widget）字段对齐扩展。**现有 6 字段保留**，新增（全部可选 / 默认值）：

```
// 相位判定用
returnDate: Date?            // = departureDate + days；缺省 nil → 退化为「仅出发前」行为
isDateless: Bool             // 默认 false；true → Widget 只走出发前相位

// 旅行中相位用（仅有日期行程填充；按需精简，避免 snapshot 膨胀）
events: [WidgetEvent]        // 整段行程「有时间的事件」，绝对 Date 已算好，按时间升序
stays:  [WidgetStay]         // 住宿跨度（判定「今晚住哪 / 是否退房日」）

struct WidgetEvent {
    let date: Date           // 绝对时刻（App 侧按活动时区算好）
    let title: String        // 事件标题（航班号/地点名/「退房·酒店」等，已本地化/原样用户输入）
    let kind: String         // "flight"/"train"/"bus"/"ferry"/"carRental"/"stop"/"checkin"/"checkout"，→ Widget 取 SF Symbol
    let subtitle: String     // 可选副信息（如航班 "KMG → PEK · T2"；地点地址简写）；空则不显
}
struct WidgetStay {
    let name: String
    let checkInDayOrder: Int
    let nights: Int          // checkOutDayOrder = checkInDayOrder + nights
}
```

**`writeWidgetSnapshot` 选片逻辑改**（[TripStore.swift:3087](../Carry/Models/TripStore.swift:3087)）：
- 现状「`departureDate >= today` 未来行程」→ 改为「**`today ≤ returnDate` 未结束行程**」（即纳入**进行中**的行程），仍排除 `isDateless`、按 `departureDate` 升序、上限 3。
- 排序后第一条天然是「进行中（若有）→ 否则最近未来」，正好当主卡。
- 事件量级：一趟行程几十条事件，JSON 入 UserDefaults 完全可控。只对**会进 Widget 的前 3 条行程**展开 events/stays，避免无谓体积。

**调用时机不变**：`writeWidgetSnapshot` 仍由 App 生命周期（启动 / 进后台）+ 既有数据变更触发；额外确认**行程规划数据变更**（加航班/改时间/加住宿）也要触发一次（接到 itinerary 写入漏斗后调用），否则 Widget 看到旧事件。

## Widget 渲染逻辑（保持哑、自推导）

`CarryProvider.timeline` 改为：
1. 取主卡行程，按 `Date()` 算当前相位。
2. **出发前**：现状布局（倒计时 + 打包进度），不动。
3. **旅行中**：
   - 当前 Day index = `daysBetween(departureDate, today)`（设备本地日历，clamp 到 `[0, spanDays-1]`）→ 显示 `Day N / spanDays`。
   - **下一件事** = `events` 中第一个 `date > now` 的事件（跨午夜也成立，因为是绝对时刻；若今天剩余无事件，自然顺延到明天第一件）。倒计时用 `Text(event.date, style: .relative)` / `Text(timerInterval:)`——**系统自动推进，无需频繁 reload**。
   - **今晚住哪** = `stays` 中 `covers(currentDayIndex)` 的那条（`checkInDayOrder ≤ N < checkInDayOrder+nights`）。
   - **退房** = 若 `currentDayIndex == checkOutDayOrder` 且当天有 checkout 事件 → 顶到醒目位（当天最要紧的硬动作）。
4. **timeline entries**：在「每个未来事件的 `date`」+「每日本地午夜」各放一个 entry，使「下一件事 / Day N」随时间自动翻页（现状仅午夜一个 entry，[CarryWidget.swift:160](../CarryWidget/CarryWidget.swift:160)）。

## UI / 布局（遵循 design-system，圆体数字、Color Token、明暗双态）

沿用现有支持的 `.systemSmall` / `.systemMedium`（[CarryWidget.swift:324](../CarryWidget/CarryWidget.swift:324)），**外观选择器 / 强制明暗逻辑全部复用**（`WidgetColorSchemeOverride`）。布局只新增「旅行中」形态：

- **Small（旅行中）**：头部 `Day N / M`（替「UPCOMING」）→ 下一件事图标 + 标题（1 行）→ 相对倒计时（`style:.relative`）→ 底部一行「今晚 · 酒店名」或退房时刻。信息密度 = 出发前版相当，不堆叠。
- **Medium（旅行中）**：左侧 `Day N / M` + 行程名 + 下一件事（图标 + 标题 + 副信息 + 倒计时）；右侧「今晚住哪」紧凑块（住宿名 / 若退房日则显「今天 12:00 退房」）。第二条未来行程**不再挤进来**（进行中时它不相关）。
- 图标按 `kind` 取 SF Symbol（航班 `airplane`、火车 `tram.fill`/`train.side.front.car`、住宿 `bed.double.fill`、退房 `arrow.up.forward`、地点按 StopCategory 图标范式）。深链：主卡点击进该行程详情（旅行中可深链到「行程」脸 + 锚到今天，复用 `TripDeepLink`，见 notification-deeplink-routing）。

## 边界 / 退化

- **无日期行程**：`isDateless=true` → 永远走出发前/不进旅行中；`events`/`stays` 不填。
- **旅行中但今天及之后无任何有时间事件**（用户没排时刻，只列了地点）：下一件事区**降级**为「Day N / M · 今晚住 X」或仅「Day N / M」，不强造空时间。**绝不**显示「无事件」这类空话。
- **多目的地 / 多时区**：事件绝对时刻已按各自时区算好，Widget 比较 `Date()` 天然正确，无需额外处理。
- **行程当天出发**（`today == departureDate`）：归「旅行中」（Day 1）；首件事常是去机场的航班，正好当下最相关。
- **解码失败 / 旧 Widget 进程**：新字段可选 → 退化为现有出发前布局，不崩不空白。

## 不做（明确排除，避免为做而做）

- 整条每日时间轴 Widget（太密、过不了「可瞄」）。
- 地图 Widget（看着酷、要用还得进 App，过不了「省一次打开」）。
- 花费 Widget（回顾性、非当下）。
- 单独的酒店地址 / 确认号 / 附件 Widget（静态、需要时才查）。
- 新增独立 Widget 种类——本 spec 是**升级现有 Widget 的相位表达**，不增桌面占位。

## 本地化

新增结构化 key（显式写 en + 9 语言齐、中文全角、复数变体）：`widget.companion.day_of`（`Day %lld / %lld` —— 序数/比例，扁平 `%lld` 合法、无需复数）、`widget.companion.tonight`（今晚 · %@）、`widget.companion.checkout`（今天 %@ 退房，按设备 12/24h）、各 `kind` 若需文字标签。改完跑 `python3 scripts/i18n-audit.py`（[E]=0）。

## 验收

编译绿（主 app + Widget）后，UI 验收交用户（默认）。建议覆盖：
1. 出发前行程 → Small/Medium 仍是倒计时 + 打包（无回归）。
2. 把某行程 departureDate 调到「今天/昨天」、returnDate 在未来 → Widget 切「旅行中」：Day N/M 正确、下一件事 = 最近未来事件、倒计时自走、今晚住哪正确。
3. 退房日 → 退房时刻顶到醒目位。
4. 旅行中但无时间事件 → 优雅降级（Day N/M + 今晚），不显空话。
5. 跨时区行程（上海→巴黎）→ 在巴黎时段事件按巴黎绝对时刻排序正确。
6. 无日期行程 → 不进旅行中相位。
7. 切设备语言（de/es/fr/ja/ko/pt/繁中）+ 明暗双态扫一遍。

## 实现顺序（先于姊妹 LA spec）

1. 扩 snapshot 模型（主 App + Widget 镜像同步）+ 改 `writeWidgetSnapshot` 选片 & 事件展开。
2. 接行程规划写入漏斗触发 snapshot 刷新。
3. Widget 相位判定 + 旅行中布局（Small/Medium）+ timeline entries。
4. 本地化 + i18n-audit + 编译验证 → 交用户验收。
