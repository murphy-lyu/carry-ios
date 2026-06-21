# Itinerary Flight：机场 / 航司名按界面语言显示（Localized Airport & Airline Names）

> **Status: Implemented（待编译验证 + 真机验收）。**
> 关联：`itinerary-flight-search-first.md`、`itinerary-flight-lookup.md`、`itinerary-airport-search.md`。

## 落地（定稿决策，2026-06-21）

- **航司（单一数据源）**：`AirlineDatabase` 从 actor 改为**非 actor 同步目录**（不可变参考数据无需 actor 隔离）——`static let` 一次性、线程安全懒加载 `airlines.json`（225K），`airline(forIATA:)` / `airlineName(forFlightNumber:)` 同步 O(1)。**搜索与显示共用这一份，不重复加载**（原先一度引入 `FlightNameCache` 做第二份同步缓存，已删除并入此处）。承运方展示逻辑放 `TransportSegment.displayCarrier`（模型自我呈现、数据层不耦合模型）：航班从航班号解析本地化航司名、否则存的 `carrier` 原文，gate 在 `.flight`。接入时间轴 `TransportTimelineRow.titleView`、详情 `headerSubtitle`/`titleText`、搜索结果卡（优先 `recognized.displayName`）。de-actor 后 `FlightSearchSheet.numberChanged` 也从 `Task{await}` 简化为同步直取。
- **机场（单一数据源 + 同步零闪）**：把机场不可变数据抽成 `AirportCatalog`（`static let all`/`byIATA`，一次性懒加载），`AirportDatabase` actor 退化为只读 `AirportCatalog.all` 的**搜索引擎**（模糊检索逐键扫表、仍放后台不卡打字），二者共用一份、不重复加载。详情 `TransportDetailView` 改为**同步**取 `AirportCatalog.airport(forIATA:)?.displayName`（去掉 `@State`+`.task` 异步）→ 首帧即正确、**零异步刷新闪烁**。1.6M 大库不在主线程同步解码：`CarryApp` 启动在后台 `Task.detached` 调 `AirportCatalog.preload()`（+`AirlineDatabase.preload()`）预热，详情/搜索打开时已就绪。只在详情副行露名（时间轴 / Trip Book 显码、本就语言无关）。
- **确定性、无启发式**：码命中库 → 本地化名；否则 → 存名。同时修好「上游英文」与「手动搜索冻结语言」，且**零迁移、无新字段**。机场名非自由文本（只能搜索选）→ 无覆盖顾虑；承运方是自由文本但航班解析 gate 在 `.flight`（火车号 `G403` 不会误判为航司 `G4`），非航班/自定义承运方原样保留。
- **决策记录**（取代下方 Draft 待确认项）：① 用「码/号 → 库」确定性解析，不加 `carrierEdited` 标志、不用等值启发式；② 航司 IATA 从航班号 `split` 取（航班号即航司身份，不另存字段）；③ 航司同步缓存（小库，首帧即正确无闪烁）、机场异步 `.task`（大库、按需单页）——按数据体积分工。

## 问题

中文（及其它非英文）环境下，已保存航班的**机场名**和**航司名**显示为英文。

根因不是数据缺失，而是**「已有的多语言库没接到显示层」**：
- App 已内置多语言库：`AirlineDatabase`（`airlines.json` ~986 家，`Airline.nm` 9 语言字典 + `displayName` 按设备语言选名）、`AirportDatabase`（`airports.json`，`Airport.nm` 9 语言 + `displayName`）。**目前只用于「搜索/选点」**。
- 添加航班时，上游 API（AeroDataBox）只返回**英文**名，App 直接把英文存进 `TransportSegment.carrier` / `fromName` / `toName`（`TransportEditView.applyFlightResult`），显示时（`TransportTimelineRow` / `TransportDetailView`）直接用这个英文字符串——**全程没查本地多语言库**。

## 目标 / 非目标

**目标**：机场名、航司名在显示时按**当前界面语言**呈现（中文设备 → 中国东方航空 / 上海浦东国际机场），零硬编码、复用已有多语言 JSON、**用户切换设备语言后自动跟随**、**无数据迁移**。

**非目标**：
- 不改上游请求传 `lang`（上游是否支持未知，且仍是单语言、不跟随设备）。
- 不在保存时把名字转成某语言存库（会冻结语言、切语言不变，反模式）。
- 不翻译用户**输入的自定义内容**（自建承运方、火车车次、未知码的包机等）。
- 不做航司 logo（见 flight-search-first：已决定不做）。

## 设计：Render-time resolution（存码、显示查名、回落原文）

核心：**存语言无关的「键」（IATA 码），显示时按当前语言查名**。键已在手里——`TransportSegment` 已存 `fromCode`/`toCode`，航班号经 `AirlineDatabase.split("MU5801") → ("MU","5801")` 取航司 IATA。

### 解析规则（关键：尊重用户编辑）

显示某字段时：
- **航司**：若能从 `number` 解析出航司 IATA 且命中 `AirlineDatabase`，**且** `carrier` 为空或 `carrier == 命中航司的英文 .name`（即未被用户改过）→ 显示该航司 `displayName`（按设备语言）；否则显示存的 `carrier`（用户自定义，原样保留）。
- **机场**：若 `fromCode`/`toCode` 命中 `AirportDatabase`，**且** `fromName`/`toName` 为空或 `== 命中机场的英文 .name` → 显示机场 `displayName`；否则显示存的 `fromName`/`toName`。

> 判据 `存名 == 库英文名` 是「未被用户编辑」的可靠信号：API 原样存的英文 = 库英文名 → 安全替换为本地化；用户改过 → 与库英文名不等 → 保留用户文本。无码 / 码查不到 → 天然回落存名。

### 关键实现点：需要**同步**的本地化查名接口

`AirlineDatabase` / `AirportDatabase` 是 `actor`，现有查询是 `async`——**不能在 SwiftUI `body` 里调**。方案：新增一条**同步、只读、locale-aware** 的查名路径，供显示用：
- 把 `airlines.json` / `airports.json` 在启动（或首次显示前）预载进一个**同步可读的不可变字典**（`[iata: Airline]` / `[iata: Airport]`），暴露同步函数：
  - `LocalizedFlightNames.airlineName(forIATA:) -> String?`（内部走 `Airline.displayName`）
  - `LocalizedFlightNames.airportName(forIATA:) -> String?`
- 现有 actor 仍保留给「搜索」（模糊匹配/打分）；本接口只做「按码精确取本地化名」。两者读同一份 JSON。
- `AirportDatabase` 目前只有 `search()`（线性打分），需补 `byIATA` 索引；航司已有 `byIATA`。
- 不持久化、纯展示派生，所以**零迁移**。

## 受影响的显示点（范围比想象小）

| 位置 | 现状 | 改动 |
|---|---|---|
| `TransportTimelineRow` 航司（标题 `号 · 承运方`）| 直接 `segment.carrier` | 按上面规则解析航司名 |
| `TransportTimelineRow` 路由端点 | **优先 IATA 码**（SHA/PEK，已 OK），无码才用名 | 仅「无码用名」分支接解析（影响极小） |
| `TransportDetailView` 航司标题 | `segment.carrier` | 同上 |
| `TransportDetailView` 机场（码下方的全名次行）| `fromName`/`toName`（英文） | 按规则解析机场名 ← **主要露英文处** |
| `FlightSearchSheet` 结果卡航司 | 查到上游就用英文 `r.airlineName` | 改为优先 `recognized.displayName`（已有 `recognized`，顺手对齐）|
| Trip Book 机场统计 | 已用 **IATA 码**（语言无关）| 不改 |

> 实测可知：时间轴端点本就显码、Trip Book 也用码，所以「机场英文」主要露在**详情页码下方那行全名**；「航司英文」则在时间轴/详情标题。改动集中、不是系统级重构。

## 待确认的设计点

1. **「尊重用户编辑」判据**：用「存名 == 库英文名 → 可替换」这条够不够？（备选：给 model 加 `carrierEdited: Bool` 标志，更精确但要迁移——倾向不加，用等值判据，零迁移。）
2. **航司 IATA 来源**：只从 `number` 前缀解析（`split`），还是顺手在保存航班时存一个 `carrierIATA` 字段更稳？（倾向先用 `split`，零迁移；存字段留作后续可选优化。）
3. **同步查名的预载时机**：启动预热 vs 首次进入行程页懒加载。（倾向懒加载 + 缓存，避免拖慢启动；首次可能有一帧回落英文、随即刷新——可接受，或首屏前 await 预热。）

## 风险 / 边界

- 库未收录的小众机场/航司（无 `nm` 或不在库）→ 回落英文，与现状一致、不退化。
- 用户把已知机场改成昵称 → 与库英文名不等 → 保留昵称（符合预期）。
- 名字仅展示层派生：分享/导出渲染器若读 `carrier`/`fromName`，是否也要本地化？（导出按文档语言——见 export-document 的 `ItineraryDocumentText` 模式：导出时按所选语言查名，不依赖设备 locale。本 spec 先做 App 内显示，导出本地化作后续。）
