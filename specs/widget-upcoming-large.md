# Widget large 尺寸：按天分组的「接下来的行程」概览（Upcoming Agenda）

> **Status: Draft — 待确认，未实现。** 确认后再编码。
> 关联：`widget-trip-companion.md`（小/中尺寸相位自适应 + snapshot 的 events/plan/stays 数据管线，本 spec 直接复用并扩展）、`widget-transit-live-activity.md`（出行日 LA）、`itinerary-timezone.md`（绝对时刻）。
> 参考：Tripsy「Next Activities」widget（一列接下来的活动 + 时间 + 日期）。

## 动机 / 生态位

Carry 已覆盖：Quick Action =「跳一下」、小/中 Widget =「瞄一眼下一件事」、Live Activity = 出行日「正在进行」。**唯独缺「概览」**——一眼看到接下来一连串要做什么。large 尺寸的独特价值正是给出「接下来的全貌」，与小/中（只给下一件事）互补、不重复。Tripsy 的「Next Activities」验证了这个需求。

## 🔑 核心设计决策：按「天」分组，不按时间扁平排（差异化 Tripsy）

Tripsy 的清单**按时间排序**（每项都有时刻），因为 Tripsy 用户细填时间。但 **Carry 的行程项常常不填时间**（用户已明确）。纯时间排序在 Carry 真实数据下会很空、很别扭。

**Carry 正解 = 按天分组 + 当天顺序**：
```
今天 · 周三 6/24
  ✈️ MU9939 · XIY → YIN              13:45
  🚗 携程租车 · 伊宁机场                18:30
  🛏 那野山河民宿                      22:30
明天 · 周四 6/25
  🗺 那拉提国家旅游度假区               （无时刻 → 不显时刻，按顺序排）
  …
```
- **有时刻** → 右侧显时刻（与 Tripsy 一样好用）；
- **无时刻**（Carry 常态）→ 不显时刻、只按当天 sortOrder 顺序排，照样有完整概览。

这比 Tripsy 的扁平时间流**更适配 Carry**，是差异化而非模仿。

## 相位自适应（沿用小/中思路）

- **旅行中**：从**今天**起，按天分组列出活动，填满 large（约 6–7 行），用 day 分组头（`今天` / `明天` / `周N · M/D`）。
- **出发前**：顶部倒计时 + 打包进度条，下方**出发当天（Day 1）行程预览**（前几项）。让 large 在行前也有用（先看到第一天安排）。
- **无日期行程**：不进 agenda（无「天」），large 退化为打包进度 + 行程项简列（按 Day 1/2… 相对序）。或与中尺寸一致仅出发前态——实现时定。

## 数据（复用 + 必要的合并）

snapshot 已有：`events`（有时刻项，绝对 Date）、`plan`（无时刻项，dayOrder/order/title/kind）、`stays`（住宿跨度）。large 需要**统一的「按天有序条目」**，每条含：`dayOrder` / `order` / `title` / `subtitle`（地点，可空）/ `kind`（图标）/ `time`（时钟标签，可空）。

**实现选择（实现时定，spec 倾向 A）**：
- **A. 合并为单一 agenda 列表**（推荐）：把 events+plan+住宿入住/退房 consolidate 成一份 `WidgetAgendaItem`（带可选 time + subtitle），按 (dayOrder, order) 排。小/中的「下一件事」改从「agenda 里第一个有未来时刻的项」取——单一真源、消除 events/plan 重复。
- **B. 不动现有字段**：large 在 Widget 侧把 events/plan/stays 合并展示。改动小、但三份数据合并逻辑落在 Widget 侧、易漂移。
- **subtitle（地点）**：当前 `plan`/`events` 未带地点副标题（Tripsy 有）。large 要显地点 → 给条目加 `subtitle`（stop.address 简写 / 交通 fromName→toName / 住宿地址）。这是本 spec 主要的新增数据。

绝对时刻仍在 App 侧按各活动时区算（Widget 不碰时区）。条目上限（如 ~12）防 snapshot 膨胀。

## UI（遵循 design-system：圆体数字/标题、语义色、明暗双态）

- `.systemLarge` 加进现有 `CarryWidget` 的 `supportedFamilies`（小/中/大同一 widget，大 = 列表态）。
- 顶部标题行：`接下来` / `今日行程`（旅行中）或行程名 + 倒计时（出发前）；右上可选「共 N 项」轻计数（Carry 克制，倾向只在旅行中显、或不显）。
- 每行：kind 图标（圆底，同时间轴/中尺寸图标范式）+ 标题（1 行）+ 地点副标题（次要色，1 行）+ 右侧时刻（有则显）+ 日期（跨天时）。
- day 分组头：`今天` / `明天` / `周N · M/D`（首组今天高亮）。
- 行数填满即止（约 6–7），超出不显（large 是概览、非全量；看全部进 App）。**若截断，末行轻提示**或留白，不假装「全部」。
- 深链：整卡点击 → 行程详情「行程」脸 + 锚到今天（复用 `TripDeepLink(face:.itinerary, anchor:.day(今天))`，同通知/Quick Action）。

## 边界 / 退化

- **旅行中但今天及之后无任何行程项**（空行程）→ 显示 `Day N/M + 目的地 + 暂无安排`？不——避免空话；退化为「打包进度 / 倒计时到返程」等仍有意义的内容，或与中尺寸的降级一致。实现时定，**不显空列表/空话**。
- **过去项不显**（只从今天起）。
- **刷新/相位/时区**：与小/中完全同源（snapshot 走 `TripStore.init` Task + `didEnterBackground` 写、绝不在 trips 加载前写；timeline entries 跨午夜/事件推进）。
- **不依赖 App 每天打开**：snapshot 带今天及之后的条目，Widget 自行按当天分组（同小/中原则）。

## 不做（明确排除）

地图 large、Trip Book/统计 large、纯打包清单 large（打包在 App 里做更好）。目的地「今日实用信息」（天气+货币+插头）large **是有价值的第二个 large**、但要把 WeatherKit 喂进 Widget，**留作独立后续 spec**，不在本次。

## 本地化

新增结构化 key（en 显式 + 9 语言齐、中文全角）：`widget.agenda.title`（接下来/今日行程）、`widget.agenda.today`/`widget.agenda.tomorrow`（分组头）、`widget.agenda.empty`（若需）、计数若做。day 分组头的「周N · M/D」用设备 locale 格式化（同 Day 头）。改完跑 `python3 scripts/i18n-audit.py`（[E]=0）。

## 验收

编译绿（主 app + Widget Extension）后 UI 验收：
1. 旅行中、有**带时刻**行程 → large 按天分组列出，时刻/日期正确。
2. 旅行中、行程项**无时刻** → 照样按天分组列出（不显时刻），不空白。
3. 出发前 → 倒计时 + 打包 + Day 1 预览。
4. 跨天分组头（今天/明天/周N）正确；今天在最前。
5. 超 6–7 行截断不假装全量；空行程优雅退化、无空话。
6. 点击进「行程」脸今天；明暗 + 多语言扫一遍。
7. 小/中尺寸无回归（若选方案 A 合并 agenda，重点回归「下一件事」「今天的地点」）。

## 实现顺序

1.（若方案 A）snapshot 合并为 `WidgetAgendaItem`（events+plan+lodging → 单一有序列表 + subtitle + 可选 time）；小/中「下一件事/今天的地点」改从 agenda 取（回归验证）。
2. `.systemLarge` 加入 supportedFamilies + large 列表视图（按天分组、相位自适应）。
3. 本地化 + i18n-audit + 编译 → 交用户验收。
