# Trip Book（我的行程册 — 旅行数据回顾）

> **Status: Approved — 范围已确认，实现中。** 本 spec 把「现在 3 行统计的行程册」升级为一个值得一看的旅行回顾，**全部基于 `TripBundle` 已有数据 + 一张静态「国家→大洲」映射表**，无后端、无第三方、无新合规风险。
>
> 参考对象：Tripsy「My Tripsy Book」。**严格套用 Carry 哲学**——只把「已有数据能诚实算出来的」做透，绝不为补齐 Tripsy 的航班/住宿/花费板块而引入一整套手动录入（那会把 Carry 从「打包+轻规划」变成「完整行程记录器」，违背克制定位）。
>
> **已确认决策（来自需求讨论 2026-06-13）：**
> 1. **🟡 两块（行程节点类别 / 在路上距离）v1 不做**——仅覆盖填了行程规划的 trip，老用户多半看到空/0；待行程规划上线、数据沉淀后再加。
> 2. **国内/国际 = 跟随 storefront 的 home country，而非硬编码 CN**——建唯一来源 `homeCountryCode`，统计与打包共用，避免日后重复维护（详见下「Home country 单一来源」）。
> 3. **季节 = 按目的地纬度判南北半球翻转**（澳洲 6 月→夏），用现成 `latitude`，做正确口径，不图省事按北半球月份。

## 动机

行程册当前只有 3 行（全部行程 / 即将出发 / 到访国家），信息薄、不值得专门打开。Carry 其实已经攒下了足够多的结构化数据（目的地国家、天数、日期、行程节点、打包完成度），把它们聚合成一份「旅行回顾」，能给老用户一个**回看自己走过多少路**的情感时刻——这正是 Tripsy Book 的价值，而我们能用现成数据做到其中一大半。

## 核心设计原则（= 克制的边界）

1. **只用已有数据，零新增录入**：不为某个板块新增「让用户填航班号/住宿晚数/费用」的入口。能从现有字段诚实算出来的才做。
2. **诚实优先于炫目**：算不准的不假装（如住宿"晚数"无 check-in/out → 不显示晚数）；只覆盖部分行程的指标要明确标注口径（如"基于已规划的行程"）。
3. **Carry 味，不抄 Tripsy 的紫色霓虹**：沿用 design-system 的单一烟蓝 + 卡片体系 + SF Rounded，明暗自适应。把 Tripsy 的「数据密度」学过来，把它的「视觉风格」丢掉。
4. **复用既有计算口径**：国家计数与 HK/MO/TW 合规归并复用 `HomeView.visitedCountriesCount` / `normalizedCountryCode`；国内/国际复用 `TripBundle.isInternational`；打包用 `packedCount/totalCount`。不另起一套，避免口径漂移。

## 范围决策（逐板块）

### 🟢 纳入 v1（全部用现有数据、覆盖所有行程、口径可靠）

| 板块 | 数据来源 / 计算口径 |
|---|---|
| **旅行总数** | `store.trips.count` |
| **旅行天数总计** | Σ `trip.days`（有日期与无日期均有 `days`） |
| **国家和地区** | distinct `normalizedCountryCode`（主 `countryCode` + `additionalDestinations`），HK/MO/TW 在大陆 storefront 归并为 CN（复用现成逻辑）。展示：已访问数 / 全球总数（常量，见下）/ 占比 |
| **最常去（Top 国家/地区）** | 按 normalized code 计数，降序取前 3，带 `Nx`（国旗 emoji 由 code 生成：`GlobeView.flagEmoji(for:)` 现为 private，**需抽到共享处复用**，不重写） |
| **大洲分布** | `countryCode` → 大洲（**新增静态映射表**，见下）；distinct 大洲数 + 各洲到访次数 |
| **国内 / 国际 占比** | `trip.isInternational`（重构为 `homeCountryCode` 基准，见下）→ 国内/国际/未知 三档占比条 |
| **季节分布** | 由 `departureDate` 月份判定季节；**按目的地纬度修正南北半球**（`latitude < 0` 翻转：北 12–2 冬 / 3–5 春 / 6–8 夏 / 9–11 秋，南半球对调）；`isDateless` 行程不计入。春/夏/秋/冬各计数 |
| **到访地图入口** | 复用首页地球，行程册里放一个「查看到访地图」入口（点了收起 sheet 回首页地球，或独立全屏地图） |
| **打包统计（Carry 独有差异化）** | Σ `packedCount` / Σ `totalCount`、整体打包完成率%。Tripsy 没有，是 Carry 的独特角度 |

**全球总数常量**：**无现成常量**，需新增一个（取 ISO 3166-1 国家+地区数，如 ~249）。首页目前只显示"到访数"、未显示"全球占比"，所以这是本功能新引入的口径——定一个常量集中管理即可。

> **`N×` 口径（不是 bug，别再当 bug 查）**：国家/大洲列表里每项的 `N×` = **「有几趟行程到访过这个国家/大洲」**，**不是**把总行程数分摊到各项。因为**一趟可去多个国家/多个大洲**（如「伦敦&维也纳&荷兰&日本」一趟跨 4 国 2 洲），它会给每个国家/大洲各 +1，所以**各项 `N×` 之和会 > 总旅行数**（多国行程被多算）。顶部的「distinct 国家数 / 大洲数」才是去重后的真实数量。这与 Tripsy「访问最多 中国 7×」一致，是标准做法。用户已两次就此确认。

### 🟡 可选（仅覆盖"填了行程规划"的 trip，须诚实标注口径）

| 板块 | 口径 / 局限 |
|---|---|
| **行程节点类别统计** | 数 itinerary `StopCategory`：去过 N 个景点 / N 家餐厅 / N 处住宿等。**只统计已添加行程规划的 trip**；若全 App 无行程数据则整块隐藏（不显示一排 0） |
| **在路上·规划距离** | 由相邻停靠点坐标算（复用 `RouteOptimizer` Haversine 或 `RouteDistanceService` 路网）。**标注"基于已规划行程的路线距离，非实际行驶"**；无行程则隐藏 |

> **决策：v1 不做**（已确认）。把 🟢 做到极致；待行程规划功能上线、用户真的有行程数据沉淀后再加，否则大多数老用户看到的是空/0。

### 🔴 明确不做（无对应数据，要做得先加录入 → 违背克制）

- ~~**航班里程 / 时长 / 机场 Top（CKG 3x）**：Carry 不记录航班号/机场/里程……做半成品反而劣质，不做。~~
  > **🔁 决策已反转（2026-06-19，spec: `itinerary-flight-search-first.md` / `itinerary-flight-lookup.md`）**：前提变了——航班搜索 + `FlightLookupService` 落地后，`TransportSegment` 已带 `distanceMeters`（大圆里程）、`durationMinutes`（飞行时长）、`aircraftType`（机型）、`fromCode`/`toCode`（IATA 机场码），且**航班号查询自动回填、零新增录入**。「无数据」不再成立（与花费同一逻辑）。Trip Book 已加：**① 飞行卡（累计里程 + 飞行时长，合一）；② 机型（坐过 N 种 / 最常坐，轻量小行）；③ 机场 Top（按 IATA 码计数，镜像「最常去国家」卡）**。仍克制：里程用大圆距离（诚实标注非实际航迹另不展开）、机型/机场只做计数 Top 不做花哨可视化、座位偏好（窗/过道/中间）**不做**（`seat` 自由文本无法靠机型座位图可靠反推，做准须新增三态录入 → 违背零录入）。
- ~~**住宿晚数（16 晚）**：无 check-in/check-out 数据……给不出"晚数"。~~
  > **🔁 决策已反转（2026-06-19，spec: `itinerary-transport-lodging.md`）**：前提变了——住宿录入改「入住日 + 退房日」两日期后，`LodgingStay.nights` / `checkOutDayOrder` 已是确定派生值。Trip Book 已加**累计住宿晚数**（与飞行卡对称，避免「交通有统计、住宿没有」的偏废）。
- **以上三块（航班 / 住宿 / 花费）均为部分覆盖**：只有加了航班/住宿/费用的行程才有数 → 每块**无数据时整块隐藏**（同花费卡），老用户不显示一排 0。
- ~~**总花费 / 分类消费（¥27,622）**：Carry 零记账字段……**坚决不做**。~~
  > **🔁 决策已反转（2026-06-16，spec: `itinerary-cost-tracking.md`）**：前提变了——费用现在是用户**主动录入**在航班/住宿/地点上的行程数据，「无数据」不再成立，记账成了「数据沉淀 → 黏性」的核心。Trip Book 已加「总花费」卡（每趟总额 + 交通/住宿/地点三类目，按本位币折算）。但仍**克制**：只按实体类型聚合（不做 Tripsy 的餐饮/购物消费分类标签）、不做分摊/预算/账单导入。

## Home country 单一来源（国内/国际基准，决策 2）

现状：`TripBundle.isInternational`（计算属性）与 `TripStore.inferIsInternational(for:)`（同步版）**都硬编码 CN**，且 `isInternational` 被打包推荐 `generatePackingSections` 用来过滤 `internationalOnly` 物品（护照/转换插头等），调用点遍布 ContentView / SuggestionPreviewView / ItemPickerView。

目标：**单一来源，统计与打包共用**，跟随 storefront。

设计：
- 新增 `homeCountryCode`（如放 `SceneItemMap.swift`，与 `isChinaStorefront` 同处）：读 `SKPaymentQueue.default().storefront?.countryCode`（**alpha-3**，如 `CHN`/`USA`），经 **新增 ISO 3166-1 alpha-3 → alpha-2 静态表** 转 alpha-2（`CN`/`US`）。**取不到 / 大陆 → 默认 `CN`**。`#if DEBUG` 沿用 `debugChinaStorefront` 覆盖习惯，便于测试。
- 重构 `isInternational` / `inferIsInternational`：把字面量 `"CN"` 换成 `homeCountryCode`。语义不变（仍是「所有目的地都在本国 = 国内」），只是基准从写死 CN 变成 storefront 本国。
- **零回归保证**：大陆 storefront → `homeCountryCode == "CN"` → 与当前行为逐字节一致；非大陆 storefront 才按其本国判定（对打包推荐也更正确：US→US 不再误判国际、不再塞护照）。
- **合规不受影响**：旅行证件差异化（护照 ↔ 港澳/台湾通行证）逻辑在 `generatePackingSections(destinationCodes:)` 内、基于 `isChinaStorefront` + 目的地码，**不依赖 `isInternational`**，本次不动。
- Trip Book 的国内/国际统计直接用同一 `homeCountryCode`，与打包口径一致（避免「统计说国内、打包给护照」的割裂）。
- **HK/MO/TW**：统计展示层仍走 `normalizedCountryCode`（大陆 storefront 归并为 CN）；`isInternational` 的判定维持现有处理（不在此扩大改动面）。

> 风险与边界：`isInternational` 是 launch 关键路径（打包）。本次只把「基准国」从写死 CN 抽成 storefront 单一来源，**不改其判定语义**；CN 市场零行为变化。alpha-3→alpha-2 用完整静态表（storefront 只返回 alpha-3，无系统 API 可靠转换）。

## 时间筛选

- Tripsy 顶部有「所有时间 / 按年」切换。**v1 只做「所有时间」**，不加年份筛选（先把聚合做对；年份切换作为后续增量，口径都是同一套聚合函数加个日期过滤）。

## 入口与呈现

- **入口不变**：首页底部「Trip Book」胶囊。点开仍是 sheet。
- **从 `.medium` 升级为可滚动的 `.large`（或全屏）sheet**：板块多，需要纵向滚动的卡片流。顶部沿用 `home.tripbook.title`（"我的行程册"）标题 + 关闭按钮（用既有 `SheetCloseButton`）。
- **卡片体系**：每个板块一张 `carrySurfaceCardBackground` 卡片，标题（headline）+ 大数字（rounded bold）+ 次级明细。饼图/占比条用烟蓝 + 中性灰，**不引入多彩**（季节板块如需区分可用低饱和的语义图标，不破坏单一强调色纪律——参照行程分色破例的克制度，本功能默认不破例）。
- **空/少数据状态**：行程数 < 阈值（如 < 2）时，行程册要么显示精简版（只 3 个核心数字），要么给一句"多走几趟，这里会记下你的足迹"的引导，避免一堆 0/1 的尴尬卡片。具体阈值实现时定。

## 视觉规范遵循

- 颜色：Color Token，单一烟蓝强调，明暗自适应（design-system）。
- 字体：SF Rounded 系，大数字用 `.system(size:, weight:.bold, design:.rounded)`。
- 间距/圆角/卡片：沿用 design-system 既有规格，不新造。

## 数据/工程要点

- **复用而非重写**：`visitedCountriesCount`、`normalizedCountryCode`、`isInternational`、`packedCount/totalCount` 直接复用；把它们与新增聚合集中到一个 `TripBookStats`（纯计算，输入 `[TripBundle]`，输出各板块数据）便于单测。
- **新增静态映射**：`countryCode → Continent`（7 大洲）。一次性静态字典，放 Models（如 `ContinentMap.swift`）。大陆 storefront 下 HK/MO/TW 归并为 CN 后再映射（亚洲）。
- **性能**：聚合是纯内存计算，trips 量级很小（几十），一次算好即可；不需缓存复杂化。若 sheet 打开略卡再考虑 `onAppear` 预算一次。
- **本地化**：所有新文案 9 语言补齐（含季节名、大洲名、各板块标题/单位），中文全角、zh-Hant 台湾用语。大洲名/国家名走本地化或系统 `Locale.localizedString(forRegionCode:)`。
- **埋点**：`tripBookOpened`（可带 trips_count）；如加板块交互（点地图入口）补对应事件。定义即接线。
- **不碰 SwiftData schema**：纯读现有字段，无 model 变更、无迁移、无备份格式变化。

## 明确不在本功能内

OTA/预订、攻略、航班动态、记账、住宿晚数、社交分享 Recap 视频（Tripsy Recap）。本功能 = **把已有数据聚合成一份诚实、克制、好看的旅行回顾**，仅此而已。

## 验收

- 真机用真实多行程数据跑：各 🟢 板块数字与手算一致（尤其国家去重 + HK/MO/TW 归并、南半球季节翻转、国内/国际口径）。
- 明暗两套、9 语言、大陆 storefront 归并正确。
- 少数据/空状态不尴尬。
- `TripBookStats` 纯函数单测覆盖：国家去重、大洲映射、季节判定（含南半球）、国内国际三档、打包率。
