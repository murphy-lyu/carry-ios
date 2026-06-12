# Itinerary Route Planning（行程路线规划 — 地图与单日重排）

> **Status: Implemented (Phases 1–4) — 分支 `feature/itinerary-route-planning`，未合并，待合并前真机验收。** 编译绿 + 算法单测 + 模拟器真机数据实跑验证。进度详情见 `docs/progress.md`。MKDirections 采用「只用于展示」方案（排序仍 Haversine，保即时/离线）。
>
> **已确认的产品决策（来自需求讨论）：**
> 1. **路线优化力度 = 单日智能重排**：只对「某一天内的几个停靠点」按地理位置给出更顺的走法，用户一键采纳。**不做**跨天全局最优、不做考虑住宿位置的多日重排（过度智能反而不可控，违背克制原则）。
> 2. 第一版聚焦「手动编排 + 地图 + 单日重排」三件事，做透。OTA 预订、攻略社区、航班动态等明确不在本功能内。
>
> **已确认的 UI 决策（实现据此进行）：**
> 3. 行程详情页「打包 ⇄ 行程」切换 = **顶部 Segmented control**（轻量、原生、一眼看到两个模式）。默认进「打包」。
> 4. 地图在「行程」页 = **顶部常驻一块固定高度预览 + 可点开全屏**；下方是按 Day 的列表。
> 5. 停靠点类型 `StopCategory` = **6 类**：`sightseeing`（景点）/ `food`（餐饮）/ `lodging`（住宿）/ `transport`（交通节点）/ `activity`（活动）/ `other`（其他）。

## 动机

Carry 当前一个行程 = 一份打包清单。行程路线规划要回答的是另一个问题：**「这趟我要去哪些地方、按什么顺序走」**。

参考 Tripsy 的行程编排，但严格套用 Carry 哲学——只做最小内核：**把「按天安排停靠点、在地图上看清路线、让今天的点排得更顺」这件事做到极致**，不堆砌预订/社区/动态等大而全能力。

地基已经在 `TripBundle` 里：多目的地（`additionalDestinations` / `DestinationEntry`）、经纬度（`latitude/longitude`）、无日期规划态（`isDateless`）、地理编码工具（`GeocodingHelpers`）。本功能是在这套骨架上自然延伸出「行程」这第二张脸，而非另起炉灶。

## 核心设计原则

1. **打包与行程并列、共享同一个 `TripBundle`，互不污染**：行程规划是 `TripBundle` 挂的第二层数据，打包清单逻辑完全不动。
2. **按天分组、停靠点有序**：行程 = 多个 `ItineraryDay`，每个 Day = 有序的 `ItineraryStop`。顺序用 `sortOrder` 表达，不绑死绝对时间。
3. **无日期行程也能规划**：`isDateless` 行程没有真实日期，但「Day 1 / Day 2」相对顺序依然成立。Day 用序号而非日期驱动，使有日期 / 无日期行程共用同一套结构（呼应 `dateless-planning-trips.md`）。
4. **地图机制对标原生 / 竞品，不自研黑科技**：用 iOS 17+ SwiftUI `Map` + `Annotation` + `MapPolyline`，路程/耗时用 `MKDirections`，绝不自己用直线距离估算耗时。性能上遵循 CLAUDE.md「性能/动画排查纪律」——先看 Tripsy/原生 Maps 怎么做，再落地。
5. **优化是建议不是强制**：单日重排只「给更顺的走法 + 一键采纳」，用户随时可手动拖回。绝不在用户未确认时改动其顺序。
6. **加字段、可选、轻量迁移**：所有新字段可选、带默认值；新增 model 走 SwiftData 轻量迁移；`DataBackupManager` 同步带上新数据的序列化（CLAUDE.md 备份约定）。

## 数据模型

### 新增两层 SwiftData model

```swift
// 一天（有日期行程对应日历某天；isDateless 行程仅为相对序号 Day 1/2/3…）
@Model final class ItineraryDay {
    var id: UUID = UUID()
    var sortOrder: Int = 0          // 第几天，0-based；isDateless 与有日期行程统一用它排序
    var title: String = ""          // 可选自定义标题（"京都古寺线"），空则展示 "Day N"
    var note: String = ""           // 当天备注
    var bundle: TripBundle?
    @Relationship(deleteRule: .cascade, inverse: \ItineraryStop.day)
    var stops: [ItineraryStop]? = []
}

// 一个停靠点（POI）
@Model final class ItineraryStop {
    var id: UUID = UUID()
    var name: String = ""           // 用户输入或地理搜索结果名
    var latitude: Double = 0        // 复用项目既有坐标范式（同 DestinationEntry）
    var longitude: Double = 0
    var address: String = ""        // 可选，地理编码反查得到
    var category: String = ""       // 停靠点类型 rawValue（见 StopCategory）
    var plannedStartMinutes: Int = -1   // 当天计划时段起点（分钟，-1 = 未设）
    var stayMinutes: Int = 0        // 预计停留时长（0 = 未设）
    var note: String = ""
    var sortOrder: Int = 0          // 当天内顺序
    var day: ItineraryDay?
}
```

- `latitude/longitude == 0/0` 视为「无坐标停靠点」（用户记了个名字但没选点），地图与重排都要能优雅跳过，**不能崩、不能误画到几内亚湾**。
- `StopCategory` 枚举（rawValue 存库，UI 用本地化 key）= **6 类（已定）**：`sightseeing`（景点）/ `food`（餐饮）/ `lodging`（住宿）/ `transport`（交通节点）/ `activity`（活动）/ `other`（其他）。

### TripBundle 关系（`TripStore.swift`）

```swift
@Relationship(deleteRule: .cascade, inverse: \ItineraryDay.bundle)
var itineraryDays: [ItineraryDay]? = []
```

- 默认空数组 → 所有存量行程零数据风险，未规划行程「行程」页显示空状态。

### Schema 迁移（`CarrySchema.swift`）

- **新增两个 model 类是带默认值的可加变更，属轻量迁移**——保持单一 `SchemaV1`、空 stages，让 SwiftData 自动处理（与 `isDateless` 同策略）。
- ⚠️ 重蹈 `dateless-planning-trips.md` 踩过的坑：**不要**新增指向同一 live 类的 `SchemaV2`（会因 checksum 相同启动崩 "Duplicate version checksums"）。本项目未发布、无线上老数据，单版本 + 自动轻量迁移即可。
- 发布后若有非轻量变更，再按「冻结旧快照 + 显式 stage」补 SchemaV2。

## 入口与交互形态

### 行程详情页：打包 ⇄ 行程

- 现状：行程详情即 `PackingListView`。新增「行程」视图与之并列，共享同一 `TripBundle`。
- 切换形态 = **顶部 Segmented control（已定）**。默认进「打包」（当前核心），「行程」为第二张脸。
- 新 View 必须 `@EnvironmentObject` 注入 store / router（CLAUDE.md 约定）；导航走 `NavigationRouter`，不在子 View 自维护 `NavigationPath`。

### 「行程」视图结构（自上而下）

1. **地图区**：顶部常驻固定高度预览，展示当前选中 Day（或全部 Day）的停靠点 + 路线连线；可点开全屏。
2. **按 Day 分组的停靠点列表**：每组可拖拽重排（复用 `smooth-drag-reorder.md` 已打磨的拖拽交互范式，不重造）。
3. **添加停靠点入口**：地理搜索（`MKLocalSearch`）选点，或手动输名。
4. **单日重排入口**：当天 ≥3 个有坐标停靠点时出现「优化今天的顺序」按钮（见下）。

## 地图与路线（核心，重点避坑）

| 能力 | 正确做法（CLAUDE.md 性能纪律） |
|------|------------------------------|
| 地图渲染 | iOS 17+ SwiftUI `Map` + `Annotation`；仅当遇到手势/性能瓶颈才隔离进 `UIViewRepresentable`（不暴露上层） |
| 停靠点标注 | `Annotation`，按 `category` 用不同 SF Symbol + Color Token（禁硬编码 hex） |
| 路线连线 | `MapPolyline`，按 Day 内 `sortOrder` 连接有坐标的停靠点 |
| 实际路程 / 耗时 | `MKDirections.calculate`，**禁止**用经纬度直线距离估算耗时（会误导用户）；无网/算不出时优雅降级为「仅连直线、不显示耗时」 |
| 地理搜索选点 | `MKLocalSearch` + `MKLocalSearchCompleter`（边输边补全） |
| 反查地址 | 复用 `GeocodingHelpers` |

- **`MKDirections` 有速率限制**：批量算路线要节流 + 缓存结果（按「起点坐标→终点坐标」键缓存当次会话），避免拖动重排时狂发请求。这是性能根因点，初版就要做对。

## 单日智能重排（本功能的杀手锏）

**目标**：给定「今天这 N 个有坐标的停靠点」，输出一个总移动更省的访问顺序，用户一键采纳。

**算法（克制、可解释、不黑箱）**：
- N ≤ 8：这是典型小规模 TSP（旅行商问题）。用**最近邻构造 + 2-opt 局部优化**即可得到接近最优解，毫秒级、纯本地、可解释。无需引入重型求解器。
- 距离度量：初版可用 Haversine 直线距离排序（快、稳、够用）；**若**要更准，再对候选顺序用 `MKDirections` 实际耗时校验（按上面的节流/缓存约束）。建议初版先 Haversine，把交互闭环跑通。
- **固定首尾、只优化中间（2026-06-12 定，方案 A，类似 Google Maps「优化途经点」）**：把**当天第 1 个和最后 1 个**停靠点都当**固定锚点**，只重排中间的停靠点（端点固定的 NN+2-opt，复用时间锚点那套段端固定逻辑）。这样：
  - **「酒店出发→中间一堆景点→回到酒店」往返日**：用户把酒店放在首和尾（录两次），优化只动中间、首尾酒店不被挪走。
  - **单程日**（酒店→…→机场）：机场被钉在末尾、不会被挪到中间。
  - 锚点集合 = `{首, 尾}` ∪ `{设了 plannedStartMinutes 的时间锚点}`；自由段（相邻锚点之间未设时间的点）才参与重排。
- 时间锚点：设了 `plannedStartMinutes` 的停靠点保持原位、不参与重排（同上锚点处理）。

**交互**：
- 仅当当天有坐标停靠点 **≥ 4** 时露出「优化顺序」入口——固定首尾后需中间≥2 个点才有可优化空间（3 个点固定首尾后中间只剩 1 个，无可重排）。
- 点击 → 计算新顺序 → **预览态**（地图 + 列表同时高亮新旧差异，显示「总移动距离 12.4 km → 8.1 km」），并提示「起点与终点保持不变」让用户理解为何首尾不动。
- 用户「采纳」才写库（改 `sortOrder`）；「放弃」则不动。**绝不未确认就改顺序**（设计原则 5）。
- 采纳是可撤销的（用户随后仍能手动拖拽调整）。

## 政策合规（中国大陆上架，CLAUDE.md 硬约束）

- MapKit 底图在大陆设备自动切高德，政治边界由 Apple 处理，**无需也禁止**自带 GeoJSON / 边界数据。
- 停靠点的 `countryCode`（若记录）存原始 ISO 值；HK/MO/TW 归并只在展示层、且只在 `HomeView.normalizedCountryCode` 那一处做，**禁止**在行程功能里重复归并。
- 行程规划本身不触发证件推荐逻辑（那在打包侧 `generatePackingSections`），两者解耦。

## 本地化（9 语言，新增 key）

所有面向用户文案走 `Localizable.xcstrings`，零硬编码，同步补全 `en / zh-Hans / zh-Hant / de / es / fr / ja / ko / pt-BR`。中文用全角标点。预计新增（结构化 key，须显式写 `en`）：

- `itinerary.tab.title`（「行程」切换标签）
- `itinerary.empty.title` / `itinerary.empty.subtitle`（空状态）
- `itinerary.day.title`（"Day %d" 带变量）
- `itinerary.stop.add`（添加停靠点）
- `itinerary.stop.search_placeholder`（地理搜索 placeholder）
- `itinerary.category.sightseeing` / `.food` / `.lodging` / `.transport` / `.activity` / `.other`
- `itinerary.optimize.button`（优化今天的顺序）
- `itinerary.optimize.preview_title`（重排预览）
- `itinerary.optimize.distance_delta`（"%@ → %@" 距离对比）
- `itinerary.optimize.apply` / `.discard`
- `itinerary.route.duration`（路段耗时展示）
- `itinerary.route.offline`（算不出路线时的降级提示）

> zh-Hant 用台湾用语（「行程」「最佳化」而非「优化」「路線」）；其余语言地道翻译，不简繁直转、不机翻。

## 备份与还原（`DataBackupManager`）

- **新增 `ItineraryDay` / `ItineraryStop` 必须纳入备份模型**（`BackupTrip` 扩展嵌套 days/stops），否则还原后整个行程规划丢失。这是 `dateless-planning-trips.md` 踩过的同类坑（漏字段 → 还原丢数据）。
- 新增字段一律可选、保持向后兼容；发布前不升 `currentBackupVersion`（无在野旧备份，统一归当前版本）。
- 停靠点坐标全在 SwiftData 内，无沙盒外关联文件，无需像背景图那样额外带字节。

## 复制行程（trip-duplicate）

- 复制行程时**深拷贝 `itineraryDays` 及其 `stops`**（新 UUID），否则复制出的行程与原行程共享/丢失规划。与复制打包清单同一处逻辑里补齐。

## 埋点（`CarryLogger.Event`，闭环约定）

新增功能要评估埋点，且**定义即接线**（禁止先定义后接）。建议事件：
- `itineraryStopAdded` / `itineraryStopRemoved`
- `itineraryDayReordered`（手动拖拽）
- `itineraryOptimizeShown` / `itineraryOptimizeApplied` / `itineraryOptimizeDiscarded`（衡量重排功能价值）
- `itineraryRouteCalcFailed`（路线算不出，错误类 → 同步加入 `errorEvents`）

## 陷阱清单（实现时重点自查）

1. **无坐标停靠点（0/0）**：地图、连线、重排都要先过滤 `lat/long != 0`，否则画到几内亚湾 / 重排把它当真实点。
2. **`MKDirections` 速率限制 + 拖动狂发请求**：必须节流 + 会话内缓存，否则拖拽重排时卡顿/被限流（性能根因，初版就做对）。
3. **重排未确认就改顺序**：违反设计原则 5。必须预览→采纳两段式。
4. **备份漏 days/stops 字段** → 还原丢整份行程规划（同 dateless 漏 `isDateless` 的坑）。
5. **复制行程浅拷贝** → 两行程共享 stops 或复制后为空。
6. **isDateless 行程**：Day 用 `sortOrder` 而非日期，确认无日期行程也能正常建 Day / 加点 / 重排，不触碰任何 `departureDate`。
7. **Schema 误加 SchemaV2 指向 live 类** → 启动崩 "Duplicate version checksums"。保持单版本轻量迁移。
8. **硬编码文案/颜色**：类型图标颜色用 Color Token；所有文案走 xcstrings、中文全角标点。

## 按天编号与按天分色（2026-06-13 定，已实现）

> 决策详情见 `docs/decisions.md` 2026-06-13。本节是对「地图与路线」「数据模型」的补充，纯展示层、零迁移。

**问题**：地图针原先**全程连续编号**（跨天 1…N 不重置），列表却**按天重置**（每天从 1 数）。多天行程下两套编号对不上，用户无法照列表在地图上定位针。

**决策**：
1. **统一为按天编号**——地图改成与列表一致（每天 1、2、3…）。对齐方向是「地图向列表靠」：序号要承载「第几天的第几站」这一有意义语义，「整趟第 14 站」对用户无意义。
2. **按天分色**——按天编号后不同天会出现重复的「1、2」针，必须靠颜色区分；多天路线同色画在一张图上也是乱线。为此**正式破例**覆盖单一强调色原则（**仅限**行程规划）。

**实现**：
- `ItineraryDayPalette`（`AppearanceMode.swift`）：7 色循环、明暗自适应、克制低饱和；**第 1 天＝烟蓝（CarryAccent）**保品牌连续，其余为陶土/鼠尾草绿/梅紫/赭黄/暮蓝/玫灰。按 `ItineraryDay.sortOrder` 取色，`index % count` 循环。
- **地图**（`ItineraryMapView`）：`dayMapData` 按天聚合——每天的有坐标停靠点按当天顺序编号（针 label = 当天 localIndex+1），针 `tint` 与路线 `MapPolyline.stroke` 用该天颜色。
- **列表**（`TimelineStopRow`）：序号圆点、上下连线、类别图标用 `dayColor`；天标题前加 8pt 同色圆点作图例。**动作按钮**（添加停靠点/优化/添加一天）仍用 `CarryAccent`——分色只给「数据节点」，不给控件。
- 颜色由 `sortOrder` 派生，**不进 model/schema/备份**。

**边界**：`ItineraryDayPalette` 不得在行程规划之外引用；App 其余一切仍只用烟蓝。

## 不在本功能范围内（明确边界）

- ❌ 跨天全局路线优化、考虑住宿位置的多日重排（只做单日重排）。
- ❌ 机票/酒店/租车预订接入（非 Carry 定位）。
- ❌ 航班动态、酒店入住记录、自驾导航（路线图更后期，单独功能）。
- ❌ 攻略推荐、UGC 内容（远期）。
- ❌ 行程内的费用/预算管理。
- ❌ 多人协作编辑同一行程。

## 建议实现顺序（分期）

> 按「先稳数据地基，再交互，最后智能」推进。每期都可独立 build 验证。

**Phase 1 — 数据地基**
1. 新增 `ItineraryDay` / `ItineraryStop` model + `TripBundle` 关系 + 轻量迁移。
2. `DataBackupManager` 纳入新模型；复制行程深拷贝。
3. 模拟器验证：建/删 Day 与 Stop、备份还原保数据、复制行程独立、isDateless 行程可建 Day。

**Phase 2 — 编排与展示（无智能）**
4. 「行程」视图 + 打包/行程切换入口。
5. 地理搜索选点（`MKLocalSearch`）、手动加点、按 Day 拖拽重排（复用拖拽范式）。
6. 地图区：`Annotation` + `MapPolyline` 画点画线；`MKDirections` 算路段耗时（节流+缓存）。
7. 空状态、无坐标点降级、本地化 9 语言、埋点接线。

**Phase 3 — 单日智能重排**
8. 最近邻 + 2-opt 重排算法（本地、Haversine）。
9. 预览态（地图+列表高亮差异、距离对比）+ 采纳/放弃两段式。
10. 埋点（shown/applied/discarded）衡量价值；模拟器验证重排正确性与可撤销。

**Phase 4（可选，验证 Phase 3 价值后再定）**
- 重排距离度量从 Haversine 升级为 `MKDirections` 实际耗时校验。
- 时间锚点（`plannedStartMinutes`）作为重排约束。
