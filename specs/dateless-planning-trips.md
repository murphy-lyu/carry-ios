# Dateless Planning Trips（无日期「规划中」行程）

> **Status: Implemented** — 已实现并通过 simulator build，待真机/模拟器全流程验收。本 spec 覆盖所有"挂在日期上"的流程，避免遗漏导致 bug。
>
> **已知小限制**：普通行程清空日期"退回规划中"时，若此前开启过日历同步并写入了带日期的日历事件，该旧事件不会被自动移除（CalendarManager 无删除 API；日历同步本为 opt-in，影响有限）。提醒、Live Activity 在退回时已正确撤销。
>
> **已确认的 UI/行为决策**：
> 1. 创建入口：日期行下方**次级文字按钮**「暂不设置日期，先做规划」。
> 2. 首页分区位置：「规划中」放在 **Upcoming 之后、Past 之前**。
> 3. **双向**：支持创建无日期→补日期转正，也支持普通行程**清空日期退回**规划中（退回须正确撤销提醒/Live Activity/日历副作用）。

## 动机

允许创建**不设置出发/返程日期**的行程，作为"旅行计划"先把打包清单规划起来（"想去日本，先把要带的列出来，日期再说"）。和 Carry 定位不冲突——本质仍是为打包做准备。参考 Tripsy：可先建行程、日期随后补。无日期行程单独分组存放，补上日期后"转正"为普通行程。

## 核心设计原则

1. **加字段，不改可选**：`departureDate` 保持非可选（避免把现有字段改 optional 的高风险迁移）。新增 `isDateless: Bool`，为真时**所有日期相关功能优雅降级**，`departureDate` 退化为无意义占位值（不得被任何展示/计算读取）。
2. **占位日期是 bug 之源**：无日期行程的 `departureDate` 仍是 `Date()`（创建当天）。**任何按 `departureDate` 判断的逻辑若不先排除 `isDateless`，都会随时间出错**（见下"陷阱"）。凡读 `departureDate` 的地方，必须先 `guard !isDateless`。
3. **降级而非禁用入口**：核心能力（建清单、勾物品、场景推荐里与日期无关的部分）照常；只有需要日期的能力静默关闭。
4. **可逆**：补日期 → 转正（普通行程）；清空日期 → 退回规划中。两个方向都要正确触发/撤销日期相关副作用。

## 数据模型

### TripBundle（`TripStore.swift`）
新增：
```swift
var isDateless: Bool = false
```
- 默认 `false` → 所有存量/测试行程都是普通行程，零数据风险。

### TripInfo（`TripInfo.swift`，创建输入）
`departureDate` / `returnDate` 当前非可选。新增：
```swift
var isDateless: Bool = false
```
- 创建无日期行程时置 `true`；`departureDate`/`returnDate` 传占位值（不会被使用）。
- `durationDays` / `dateRangeDisplay` 在 `isDateless` 时不应被调用（调用方先判断）。

### Schema 迁移（`CarrySchema.swift`）
- **保持单一 `SchemaV1`、空 stages**，让 SwiftData 对本地 store 做自动轻量迁移（`isDateless` 是带默认值的可加字段，属轻量变更）。
- ⚠️ **踩过的坑**：最初新增了 `SchemaV2` 且其 `models` 仍指向同一个 live `TripBundle` 类——SwiftData 用模型当前结构算 checksum，新旧两版 checksum 相同 → 启动崩溃 **"Duplicate version checksums detected"**。正确的多版本写法需为旧版本**冻结独立模型快照**；但本项目未发布、无线上老数据，单版本 + 自动轻量迁移即可，无需引入第二版本。
- 将来发布后若有「重命名/删除字段、改关系」等**非轻量**变更，再按"冻结旧快照 + 显式 stage"补 SchemaV2。

## 日期依赖降级矩阵（逐项，必须全覆盖）

> 凡列出的每一处都要在 `isDateless` 时按"降级行为"处理。这是防 bug 的清单。

| # | 位置 | 现状（依赖日期） | `isDateless` 时的降级行为 |
|---|------|-----------------|--------------------------|
| 1 | `TripBundle.countsAsVisited` | `startOfDay(now) > startOfDay(departureDate)` | **必须 `&& !isDateless`** → 永远不算到访（否则占位日期过几天就误判为已到访，污染地图点亮 + 到访国家数）⚠️ 高危 |
| 2 | `HomeView.rebuildTripLists` 的 `isPast` / upcoming 分区 | 按 returnDate 分 upcoming/past | 无日期行程**既不进 upcoming 也不进 past**，单独进新「规划中」分组（否则占位日期过期后会自己从列表蒸发/跳到 Past）⚠️ 高危 |
| 3 | `HomeView` 到访统计 `consider(...)` 循环（visitedCountries/Cities/Count） | 遍历 trips 用 departureDate | 跳过 `isDateless` 行程 |
| 4 | `MacGlobePanel`（×2 到访点亮） | 同上 | 跳过 `isDateless` |
| 5 | `NotificationManager.scheduleReminders` | `config.fireDate(relativeTo: departureDate)` | 不为无日期行程排任何打包提醒 |
| 6 | `TripReminderSheet` / `TripReminderConfig` | 出发前 N 天提醒 UI | 无日期行程的"打包提醒"入口**禁用/隐藏**，并提示"设置日期后可用" |
| 7 | `LiveActivityManager.startIfNeeded` | 出发前 `activationWindowDays`(7) 内激活 | 无日期行程不激活 Live Activity |
| 8 | `CalendarManager.writeEvents/addTrip` | 写带日期的日历事件 | 无日期行程不写日历（日历同步开关对它无效） |
| 9 | `PackingListView.fetchDestinationWeather` + `DestinationInfoView` 天气区 | 需要 `[start,end]` 区间 | 不拉天气、隐藏天气卡（插头/电压/货币仍展示） |
| 10 | `ItemPickerView.tripDateRange` / `ScenePickerView` → `CycleInference` | 经期预测需日期区间 | `tripDateRange` 返回 nil → 不跑经期预测、不显示经期 nudge |
| 11 | `ClimateInference.inferredSceneKeys(countryCode:departureDate:)` | 季节性 winter 看出发月份(11/12/1/2) | 无日期时：**保留**与日期无关的推断（tropical、always-cold IS/GL、high_altitude），**跳过**季节性 winter 分支（无月份可判）。建议给 `inferredSceneKeys` 加可选 date 参数或单独入口 |
| 12 | `HomeView` 卡片日期行（`localizedDateRange` / "· N days"） | 显示日期区间 | 隐藏日期行；显示"规划中 / 无固定日期"轻标签。物品计数（"X left"）照常 |
| 13 | 卡片倒计时/排序 | 按 departureDate 排序 | 规划中分组按 `createdAt` 倒序排 |
| 14 | `DataBackupManager`（`BackupTrip` 编解码） | 备份/还原行程字段 | **必须把 `isDateless` 纳入备份模型**，否则还原后丢失标记 → 退化成普通行程、占位日期作乱 ⚠️ 易漏 |
| 15 | Widget（`WidgetTripSnapshot` 即将出发快照） | 取最近 upcoming 行程 | **排除 `isDateless`**（桌面小组件不展示无日期行程，无倒计时可言） |
| 16 | AppIntents「Nearest Trip」Quick Action（`CarryShortcuts`） | 按 departureDate 找最近行程 | 排除 `isDateless` |
| 17 | 复制行程（trip-duplicate） | 复制全部字段 | 复制时保留 `isDateless`（复制一个规划中行程仍是规划中） |
| 18 | 自动打包 / suggestion 流程（`autoPackReview` 等用 `durationDays`） | 按天数生成数量（如内衣按天数） | 无日期 → 无 `days`；数量默认按 1 处理（`defaultQuantity` 已 `max(1, tripDays)`，传 1 即可） |

## 创建流程（TripInfoView）

- 现状：`canContinue = name 非空 && destination 非空`（日期总有默认值）。
- 新增**「暂不设置日期」入口**：
  - 方案：日期选择行下方加一个次级文字按钮「暂不设置日期，先做规划」(`tripinfo.skip_dates`)；点它 → `isDateless = true` → 直接继续（日期行变灰/收起）。
  - 或：日期行本身可清空，清空即视为 dateless。**二选一，UI 决策见"待确认"。**
- `canContinue` 在 dateless 时只校验 name+destination（不校验日期）。
- `info` 构造时带上 `isDateless`；下游 `confirmSelection` / `commitDraftTrip` 把 `bundle.isDateless` 落库。

## 转正 / 退回流程（EditTripView）

- **补日期（转正）**：dateless 行程在 EditTrip 里设置了日期 → `isDateless = false`、写入 departureDate/days/dateRange → **必须重新触发日期副作用**：
  - 重排打包提醒（`NotificationManager.scheduleReminders`）
  - 重新评估 Live Activity（若进入激活窗口）
  - 若日历同步开启，补写日历事件
  - 触发首页列表/到访统计刷新（行程从「规划中」迁到 upcoming）
- **清空日期（退回）**：普通行程在 EditTrip 清空日期 → `isDateless = true` → **撤销副作用**：取消该行程的打包提醒、结束其 Live Activity、移除已写日历事件（若有）。
- EditTripView 现以非可选日期工作，需支持"无日期"态（同创建流程的 UI 决策）。

## 首页分组（HomeView）

- 新增第三个分区「规划中」(`home.planning` / Planning / Someday)，位置：建议在 Upcoming 之后、Past 之前（"未来计划 > 即将出发 > 已过去"的时间直觉里，规划中是"尚未排期"，放 Upcoming 后较自然）。**最终位置见"待确认"。**
- `rebuildTripLists` 三分：`isDateless` → 规划中；非 dateless 且未过期 → upcoming；非 dateless 且已过期 → past。
- 规划中分组按 `createdAt` 倒序；空则不显示该分区。

## 卡片 UI（无日期态）

- 隐藏日期区间行与"· N days"。
- 加一个克制的「规划中 / No dates yet」轻标签（次要色）。
- 物品进度（"X left" 已打包/总数）照常——这是核心，无日期也成立。
- 不显示倒计时类元素（本就没有）。

## 本地化（9 语言，新增 key）

- `home.planning`（分区标题，"规划中" / "Planning"）
- `tripinfo.skip_dates`（"暂不设置日期，先做规划"）
- `trip.card.no_dates`（卡片轻标签，"规划中" / "No dates yet"）
- `edittrip.add_dates` / 相关编辑态文案
- `tripreminder.needs_dates`（提醒入口禁用提示，"设置日期后可用"）

> zh-Hant 用台湾用语；其余语言地道翻译，不简繁直转。

## 陷阱清单（实现时重点自查）

1. **`countsAsVisited` 不加 `!isDateless` → 占位日期过期后误算到访**（污染地图 + 到访数）。
2. **`isPast` 不排除 dateless → 规划中行程过几天自动跳到 Past**（用户以为丢了）。
3. **备份模型漏 `isDateless` → 还原后变普通行程**，占位日期立刻作乱。
4. **Widget / Nearest Trip 不排除 dateless → 倒计时/最近行程出现无日期行程**。
5. **转正时漏触发副作用**（提醒没排、Live Activity 没起、日历没写）。
6. **退回时漏撤销副作用**（残留提醒/日历事件指向无意义日期）。
7. **复制行程丢 `isDateless`**。
8. **ClimateInference 季节 winter** 在无日期时不能判月份——别用占位日期去判（会按"今天的月份"误推）。

## 不在本版本范围内

- 把无日期行程参与任何"按时间"的统计/排序/提醒。
- 模糊日期（"大概 5 月"/季节）——只支持"有日期 / 无日期"二态，不做区间猜测。
- 多段日期、待定返程等中间态。

## 建议实现顺序

1. 模型 + SchemaV2 迁移 + 备份字段（地基，先稳数据）。
2. 降级矩阵 1–18 逐项处理（先把"读 departureDate 的地方全部 `guard !isDateless`"扫一遍）。
3. 创建流程（TripInfoView 暂不设置日期）。
4. 首页「规划中」分组 + 卡片无日期态。
5. 转正 / 退回（EditTripView）+ 副作用触发/撤销。
6. 本地化 9 语言。
7. 模拟器验证：建无日期行程 → 确认不进 upcoming/past/到访/widget/提醒/天气/经期；补日期 → 转正且副作用全到位；清空 → 退回且副作用撤销；备份还原保标记；复制保标记。
