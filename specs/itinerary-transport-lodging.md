# Itinerary Transport & Lodging（交通段 + 住宿跨度 — 行程规划升级）

> **Status: Draft — 待确认，未实现。** 本 spec 定义数据模型 + 交互，确认后再编码。
>
> **本轮采用的默认路径（你说「开始吧」据此推进，可改）：**
> 1. **数据模型一次设计全**（交通 + 住宿一起想清楚），**实现分阶段**：航班 → 火车/通用交通 → 住宿。避免二次改 schema。
> 2. **规划能力先于 PDF 导出**：导出行程单的完整度完全取决于这层，故先把交通/住宿做扎实，签证 PDF 导出单列一份 spec（`itinerary-export-document.md`，后续）。
> 3. **借 Tripsy 的「正确数据模型」打地基，用 Carry 的克制审美决定呈现与范围**——不抄它的费用分摊 / 多人协作 / 邮箱解析 / 攻略社区；航班动态 API、邮箱导入属未来迭代，本轮只做「schema 可演进」。

## 动机

`itinerary-route-planning.md` 已落地「按天排地点 + 地图 + 单日重排」。但当前模型里**万物皆 `ItineraryStop`（单坐标的点）**，`flight`/`train` 只是它的一个 category——这是语义错位：

- **地点**（翠湖）是一个**点**，你在那儿停留。
- **航班**（CA1234，昆明 09:00 → 北京 12:30）不是点，是**两点间的一段移动**：有出发地+到达地、出发时间+到达时间、承运方、航班号，可能跨天、跨时区。塞进「单坐标点」会丢掉到达信息，地图上「到下一点的直线距离」也失去意义。
- **住宿**（某酒店，Jun 19–21）不是某一天的点，是**横跨若干晚的跨度**。

要把行程规划做完整（也为了导出一份使馆认可的标准行程单），交通与住宿必须升格为**独立对象**，而非 stop 的标签。

## 核心设计原则

1. **节点 + 边 + 跨度 三类对象**：
   - **节点 / Node** = 停留的点 = 现有 `ItineraryStop`（不动）。
   - **边 / Edge** = 连接两点的一段交通 = 新 `TransportSegment`。
   - **跨度 / Stay** = 横跨若干晚的住宿 = 新 `LodgingStay`。
2. **时间轴是唯一的家**：节点与交通段都落在同一条按天时间轴上，住宿以「跨天」形态叠加。不另开页面。
3. **schema 为未来航班动态预留**：本轮手动录入，但字段按完整设计；将来「输航班号自动带数据 → 实时状态」只是填充已有字段 + 加实时状态块，不再改表。
4. **航班按当地时间存、正确处理跨时区/跨天**：从一开始就做对，否则 3 小时航班会显示成 6 小时。
5. **向后兼容、轻量迁移**：新增 model（加表）属轻量迁移，所有字段可选带默认值；现有把航班/火车加成普通 stop 的旧数据不破坏。`DataBackupManager` 同步序列化新数据（CLAUDE.md 备份约定，发布前新增可选字段不升版本）。
6. **克制呈现**：时间轴为主、不堆卡片；信息密度服务当下任务。

## 数据模型

### 1. TransportSegment（交通段 — 边）

交通段是时间轴上的一项（不硬绑两个具体 stop 对象——更鲁棒，能处理「到达后还没排地点」「跨天航班」等），由 UI 渲染成「连接两点的连接行 + 地图弧线」。归属**出发日**，与 stop 共享同一条时间轴的排序空间。

```swift
enum TransportMode: String, Codable, CaseIterable {
    case flight, train, bus, ferry, carRental, other
}

@Model final class TransportSegment {
    var id: UUID = UUID()
    var modeRaw: String = TransportMode.flight.rawValue

    // 承运方 / 班次
    var carrier: String = ""        // 航司 / 铁路（"China Eastern" / "中国铁路"）
    var number: String = ""         // 航班号 / 车次（"MU5801" / "G403"）

    // 出发端
    var fromName: String = ""       // 站点名（"昆明长水国际机场" / "昆明南站"）
    var fromCode: String = ""       // IATA / 车站代码（"KMG"），可空
    var fromLatitude: Double = 0
    var fromLongitude: Double = 0
    var fromTimeZoneId: String = "" // IANA tz（"Asia/Shanghai"），用于跨时区正确显示；可空
    var fromTerminal: String = ""   // 航站楼 / 站台，可空

    // 到达端
    var toName: String = ""
    var toCode: String = ""
    var toLatitude: Double = 0
    var toLongitude: Double = 0
    var toTimeZoneId: String = ""
    var toTerminal: String = ""

    // 时间（按各自当地时间存；跨天用 dayOrder 偏移，呼应 ItineraryStop.plannedStartMinutes 范式）
    var departDayOrder: Int = 0     // 出发落在第几天（0-based，对齐 ItineraryDay.sortOrder）
    var departLocalMinutes: Int = -1// 出发当地时间（自午夜分钟数，-1 = 未设）
    var arriveDayOrder: Int = 0     // 到达落在第几天（可 > departDayOrder，红眼/跨天）
    var arriveLocalMinutes: Int = -1

    // 选填实用信息
    var seat: String = ""
    var confirmationCode: String = ""
    var note: String = ""

    // 时间轴排序（与同日 stop 共享整数空间）
    var sortOrder: Int = 0
    var day: ItineraryDay?          // 归出发日

    // —— 未来航班动态预留（本轮不接 API，留空）——
    var liveStatusData: Data = Data()  // JSON: 延误/登机口/转盘/实际起降；可演进，不改表
}
```

**计算属性**（同 ItineraryStop 范式做兜底）：`mode`（未知 rawValue → .other）、`hasFromCoordinate`/`hasToCoordinate`、`fromCoordinate`/`toCoordinate`、`crossesDays`（arriveDayOrder > departDayOrder）。

### 2. LodgingStay（住宿跨度 — Stay）

住宿横跨若干晚，归属 **TripBundle**（不绑单天）。用 day sortOrder 锚定，兼容有日期 / 无日期行程（呼应 `dateless-planning-trips.md`）。

```swift
@Model final class LodgingStay {
    var id: UUID = UUID()
    var name: String = ""           // 酒店 / 民宿名
    var address: String = ""
    var latitude: Double = 0
    var longitude: Double = 0

    // 锚定：用 day sortOrder 表达「第几天 check-in，住几晚」
    var checkInDayOrder: Int = 0    // 0-based，对齐 ItineraryDay.sortOrder
    var nights: Int = 1             // 住几晚（check-out 日 = checkIn + nights）
    var checkInMinutes: Int = -1    // 入住时间（可空）
    var checkOutMinutes: Int = -1   // 退房时间（可空）

    var confirmationCode: String = ""
    var note: String = ""
    var sortOrder: Int = 0
    var bundle: TripBundle?
}
```

`checkOutDayOrder` = `checkInDayOrder + nights`（计算属性）。

### 3. TripBundle 关系新增

```swift
@Relationship(deleteRule: .cascade, inverse: \LodgingStay.bundle)
var lodgingStays: [LodgingStay]? = []
// TransportSegment 经 ItineraryDay 级联，无需 TripBundle 直接持有
```

### 4. ItineraryDay：时间轴合并

Day 同时挂 stop 与 transport，按 `sortOrder` 合并排序展示：

```swift
@Relationship(deleteRule: .cascade, inverse: \TransportSegment.day)
var segments: [TransportSegment]? = []

/// 合并 stop + segment，按 sortOrder 升序 —— 时间轴的单一数据源。
enum TimelineItem { case stop(ItineraryStop), transport(TransportSegment) }
var timeline: [TimelineItem] { /* merge stops + segments by sortOrder */ }
```

`sortOrder` 在 stop 与 segment 间共享整数空间；插入/重排时统一重编号（沿用现有 `ItineraryReorderCollection` 的提交模型，交通段视为不可与地点跨类穿插的特殊行——见交互）。

## 交互设计

### 录入入口：统一「+」选类型

现状每天底部「+ Add place」改成 **统一「+ 添加」→ 选类型**（地点 / 航班 / 火车·交通 / 住宿）——对标 Tripsy，干净可发现，时间轴仍是一切的家。不同类型走各自录入表单：

- **航班录入**：航班号 + 日期 → (Phase 1 手填) 航司 / 起降机场 / 起降时间 / 航站楼 / 座位 / 确认号。(Phase 2) 航班号自动带出机场+时间。
- **火车/通用交通**：车次 + 起讫站 + 起讫时间。
- **住宿**：名称 + 地址（可地理搜索）+ check-in 日 + 住几晚 + 确认号。

### 时间轴渲染

- **地点**：现有「序号圈 + 名称 + 地址」行（不变）。
- **交通段**：连接行——`✈️ MU5801 · KMG 09:00 → PEK 12:30 · 3h30m`；与地点的「序号圈」区分（用 mode 图标，非序号）。占据原本「两点间距离」那条连接槽——**边从隐式距离升级为显式交通**。
- **跨天航班**：锚出发日，到达信息标注「+1 天 / 次日 06:00」；到达日表头可选提示「抵达 PEK」。
- **住宿**：在所覆盖的每一天表头下方挂一条轻量「🛏 住 XX 酒店」常驻条（Tripsy 式），check-in 日显「入住」、check-out 日显「退房」。

### 地图

- 交通段（航班）画**大圆弧虚线**（`MKGeodesicPolyline`），与市内步行/驾车实线区分——一眼看出「这段是飞的」。
- 火车/巴士可用直线或虚线（不强求路网）。
- 住宿点用 `lodging` 图标针。

### 路线优化协同

交通段是**固定锚点**（没人重排航班），与现有「固定首尾、只优化中间」逻辑天然契合——交通自然钉住一天的头尾。`RouteOptimizer` 只重排地点节点，跳过 transport。

## 向后兼容与迁移

- 保留 `StopCategory.flight` / `.train`（rawValue `"transport"`）/ `.carRental` / `.cruise` 枚举与旧数据——**不破坏**已把交通加成普通 stop 的存量行程。
- 新建交通**走 `TransportSegment`**；「添加地点」流程**移除** flight/train/carRental/cruise 选项（引导到新交通流程），仅保留在地体验类 + lodging（lodging 单点仍可，或引导到 Stay——见待决策）。
- 新增 3 个 model 属轻量迁移（加表），不引入 SchemaV2（避免 checksum 重复崩溃，沿用 route-planning 经验）。
- `DataBackupManager`：加 `BackupTransportSegment` / `BackupLodgingStay` 镜像类型，`BackupTrip` 加可选数组；`duplicateTrip` 深拷贝（新 UUID）。

## 实现阶段

- **Phase A — 交通段（航班为主）**：model + 统一「+」入口 + 航班录入表单 + 时间轴连接行 + 地图弧线 + 备份 + 复制 + 9 语言 + 埋点。
- **Phase B — 火车/通用交通**：复用 A 的表单与渲染，mode 切换。
- **Phase C — 住宿跨度**：`LodgingStay` + 录入 + 跨天常驻条 + 备份。
- **（后续，另 spec）航班动态 API**：航班号自动带数据 → 实时状态写 `liveStatusData`，可复用 ActivityKit 推送。
- **（后续，另 spec）签证 PDF 行程单导出**：依赖本层完整度。

## 合规

- 航班 / 机场 / 铁路数据无地缘政治敏感点。
- 未来航班动态 API 有成本/限流，设计成可插拔；不在 Phase A 纠结。

## 本地化

- 新增类型选择、录入表单字段名、连接行/常驻条文案 → 结构化 key（显式 en），9 语言同步补全；中文全角标点；zh-Hant 台湾用语。
- 用户数据（站点名/航司/酒店名）原样存、不翻译。

## 埋点

- `transportAdded`（mode=flight/train/…）、`lodgingAdded`、`transportEdited`、`transportDeleted` 等；定义即接线（CLAUDE.md 埋点闭环）。

## 待你拍板的设计子决策

1. **住宿单点 vs 跨度**：lodging 是否一律走 `LodgingStay`（跨天）？还是保留「单天 lodging 地点」作为轻量选项（用户只想标记一个住处、不关心日期跨度时）？倾向：**统一走 Stay**，更完整、利于签证文档汇总。
2. **重排约束**：交通段在时间轴里允许用户手动拖动改位吗？还是按出发时间自动定位（不可拖）？倾向：**有时间则按时间自动排、无时间可手动**。
3. **跨天住宿常驻条**：每天表头都挂一条，会不会在长住同一酒店时显得啰嗦？是否只在 check-in / check-out 日显事件、中间天不显？倾向：**check-in/out 显事件，中间天显一条极轻的灰条**，可后续按观感调。

## 增补（2026-06-19）：住宿录入改「入住日 + 退房日」两日期（弃「住几晚」Stepper）

> **Status: 实现中。** 触发：用户对「入住有『入住』、退房没『退房』」困惑。

### 根因（不是显示 bug）
显示三态（入住/过夜/退房）本就对称、正确。问题在**输入用「住几晚」(nights Stepper)**——人脑想的是「住到 X 号」(退房**日期**)，不是「住 N 晚」。入住 7/19、想住到 21 号本是 **2 晚**，一不留神填了 3，退房日 = 7/22 落到**行程外**，于是「退房」无 day 可渲染、消失；而 7/21 你其实**还在住**（第 3 晚）→ 显「过夜」是对的。

### 设计（对标酒店/Tripsy）
- 录入从「入住日 + 住几晚」改为「**入住日 Picker + 退房日 Picker**」，两者都从**行程内的天**里选；`nights = 退房日 − 入住日`（派生）。
- **内部存储不变**（`checkInDayOrder + nights`，零 schema 改动）；保存时由两个 dayOrder 反推 nights。
- 约束：入住日 Picker 排除**最后一天**（最后一天没法开始过夜）；退房日 Picker 只列 `> 入住日` 的天 → **退房日恒在行程内**，「退房」事件必然有 day 可渲染、不再消失。入住日改动时夹断 nights 保持 ≤ 行程末日。
- **显示侧（时间轴三态、详情）一行不改**——退房日恒在行程内后，三态对称自洽。
- 新文案 `itinerary.lodging.field.checkout_day`（退房日 / Check-out），9 语言；旧 `field.nights` / `nights_value` 仍用于时间轴「N 晚」展示，保留。
- 落点：仅 `LodgingEditView` 录入控件（nights Stepper → 退房日 Picker + 派生绑定）。⚠️ 与并行「住宿附件/地址」会话同文件，注意合并。

## 增补（2026-06-20）：住宿并入时间轴主脊，做「当天导航锚点」（弃顶部常驻条）

> **Status: 已实现（2026-06-20），待真机验收。** 两步均落地：① 住宿按角色上脊（入住/出发/过夜/退房）+ 去顶部常驻条 + 共用 TimelineRail 脊连续 + 导航（点节点进详情、内含 Get Directions）+ 文案；② 酒店端点距离 leg（`.lodgingLeg` 行，「酒店↔相邻地点」大圆距离，复用 ItineraryLegConnector）。落点：`ItineraryView`（timelineRowIDs 注入 / lodgingRow / LodgingBannerRow / lodgingLegRow）、`ItineraryReorderCollection`（行 ID + role/leg 维度 + 快照边界插 leg）、`Localizable.xcstrings`（depart/overnight 9 语言）。触发：用户场景——一天的真实移动是 **酒店 → A → B → … → 回酒店**；用 Carry「点一下调导航、一站站去」时，酒店作为这条链的**起点/终点**却只在顶部常驻条、不在链里，连续导航对酒店场景缺席。参考 Tripsy（住宿自动进列表），但**只取其「正确数据模型」、用 Carry 克制审美定呈现**。

### 现状与缺口
- 现状：住宿是**每天置顶的「常驻条」**（`ItineraryView.daySections` 里 `entries = lodgingRows + overlayRows + timelineRowIDs`，lodging 排在主脊之前），按当天显**入住/过夜/退房**三态，**不上主脊、不与地点连距离 leg**（决策见本 spec 主体「住宿=跨度/背景」）。
- 缺口：① 酒店不是可点导航节点，连续导航链缺起点/终点；② 当天路线距离不含「酒店↔首/末个点」leg，不完整。
- **前提已变**：原「住宿=被动背景」的决策，前提是酒店只是背景；「连续导航」用例 + 已落地的入住/退房**时间**，使其值得重新评估（同费用/航班统计的前提反转）。

### 核心设计：按「当天角色」把酒店锚到主脊，框住「以酒店为基地」的那段
住宿从「顶部常驻条」改为**主脊上的锚点节点**，位置由当天三态决定：

| 当天角色 | 主脊位置 | 文案（结构）|
|---|---|---|
| **入住日**（当天到店） | 当天行程**之后**，设了入住时间则按时间落位、否则置当天末尾 | 「入住 · {酒店} · {入住时间?}」 |
| **整中间日**（早出晚归，stay 跨度内非首末日） | 当天**第一个节点（出发）** + **最后一个节点（过夜）** | 「从 {酒店} 出发」… 地点 …「回 {酒店} 过夜」 |
| **退房日**（当天离店） | 当天**第一个节点**，设了退房时间则按时间落位、否则置当天开头 | 「退房 · {酒店} · {退房时间?}」 |

> 单晚住宿（入住日 == 退房日−1，无中间日）：入住日 = 入住节点收尾、退房日 = 退房节点起头，无「出发/过夜」对。

### 不产生疑惑的呈现规则（用户一眼看懂是酒店、不当成景点）
1. **专属视觉**：床图标 + **比景点节点更轻/退后的「基地」样式**（不是「要去玩的点」）。
2. **动词框定**：出发=「从 …」、夜晚=「回 … 过夜」、入住/退房沿用现有词——读起来即「这天从这儿开始 / 到这儿结束」。
3. **不编时间（诚实）**：「出发/过夜」是**位置锚点、无时间**；只有入住/退房在**用户设了时间**时显时间。**时间用于精确化入住/退房两个事件，不作整个功能的开关**——没设时间的用户照样需要导航锚点。
4. **取消顶部常驻条**（避免「酒店出现两次」的疑惑）：原 bar 的「N 晚」并入**入住节点**（「入住 · {酒店} · N 晚」）。整中间日酒店出现在当天首尾 = 一天的自然往返，不算重复。
5. **距离 leg 接上**：`酒店↔首个点`、`末个点↔酒店` 纳入当天路线距离（复用现有 leg 计算）。

### 数据 / 工程
- **零 schema 改动**：仍是 `LodgingStay`（`checkInDayOrder + nights + checkIn/checkOutMinutes`）；只改**渲染层**——把 lodging 从「daySections 顶部 lodgingRows」改为**按角色注入主脊 `timelineRowIDs`** 的对应位置（参照租车「取车/还车」两事件注入主脊的同款做法）。
- **行 ID 唯一性**：同一 stay 跨多天复用，行 ID 必须带区分维度（如 `.lodging(stay:day:role:)`，role∈{checkIn,depart,overnight,checkout}），避免 diffable「item identifiers not unique」崩溃（本项目踩过两次）。
- **导航**：酒店节点点按 → 复用现有 `DirectionsModule`（地点同款）调导航。
- **跨度背景**：是否仍保留一条贯穿当天的极淡「住宿底色」表示「这几天都住这」可选，默认不留（靠首尾节点已表达）。

### 待你拍板的子决策（spec 按推荐项写，可改）
1. **整中间日两端都摆（出发+过夜）** vs 只摆「出发」一端 → **推荐两端**（导航链完整）。
2. **取消顶部常驻条** vs 保留一条极简的 → **推荐取消**（并入入住节点），避免重复露出。
3. **所有住宿自动上脊** vs 加开关 → **推荐自动**（住哪是事实，不该手动开）。

### 本地化
新增结构化文案（9 语言）：`itinerary.lodging.timeline.depart`（从 %@ 出发 / Leave %@）、`itinerary.lodging.timeline.overnight`（回 %@ 过夜 / Overnight at %@）；入住/退房/N 晚复用现有 key。

### 落点
`ItineraryView.daySections`（lodging 注入位置）、`lodgingRow` 渲染（三态扩为四角色 + 出发/过夜）、行 ID 枚举、距离 leg 计算纳入酒店端点；删顶部 lodgingRows 常驻条。⚠️ 改动时间轴核心渲染，须配 `home-sheet-debug-playbook` 之外的「diffable 唯一 ID」纪律。
