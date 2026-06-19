# Itinerary Car Rental（租车录入：接通入口 + 收口错误路径 + 表单打磨）

> **Status: Draft — 待确认，未实现。** 确认后再编码。
> 关联：`itinerary-transport-lodging.md`（交通段模型已落地）、`itinerary-route-planning.md`（地点/StopCategory）。

## 动机 / 现状根因

用户报「行程规划 → 添加地点 → 租车」体验别扭：现状是去**搜索租车公司的名称/地址**（截图 1）。问题——小公司搜不到、公司常不在机场（车一般送到机场/车站）。用户的诉求很清楚：**公司叫什么、公司地址在哪都不重要；重要的是「取车地点」能自己设（机场/车站），租车平台/公司只是一个按习惯填的普通字段。**

排查发现：代码里「租车」同时存在**两套并行概念**，这才是别扭的根：

1. **`StopCategory.carRental`**（地点的一个**类别**）—— 截图 1 走的就是它：`AddStopView` 的类别菜单（`StopCategory.allCases`）里有「车」，于是用户在「地点」流程里切到车类别去**搜一个坐标点**。把租车当成「单坐标点」，正是烂体验来源。
2. **`TransportMode.carRental`**（`TransportSegment` 交通**段/边**的一个模式）—— `TransportEditView` 已实现得几乎完整：公司=自由文本、取/还车地点=**可选**地理搜索、取/还车日期+时间、费用/确认号/备注，且隐藏了航班号/座位/IATA/航站楼等无关字段。**这正是用户想要的形态。**

**真正的缺口在入口**：统一「+」菜单（`ItineraryView.addStopRow`）只暴露 **地点 / 航班 / 火车 / 住宿**，**租车没有顶层入口**（连带 `bus / ferry / other` 交通模式也都进不去，只能靠「编辑已有段再改类型」碰到）。所以用户找不到对的路（`TransportEditView` 租车模式），只能掉进「地点 → 切车类别 → 搜公司」这条错的路。

**结论**：租车本就该是独立类型（它是「边」不是「点」，字段与地点根本不同），数据模型也早就这样建了。本轮不是从零实现，而是**接通 + 收口 + 打磨**三件事。

## 已拍板的产品决策

- **租车名称只用一个自由文本框**（不学 Tripsy 的「名字 + 公司」两框）：一个字段=公司/平台/自记名（携程租车 / 机场取车 / Hertz），直接当时间轴标题。符合 Carry 克制原则。
- **顺手补一个「其他交通」入口**：菜单加一项「其他交通」覆盖 `bus / ferry / other`，一次把交通入口缺口堵上。

## 改动清单

### 1. 接通入口：「+」菜单加「租车」+「其他交通」，并分组

`ItineraryView.addStopRow` 的 `Menu` 重排为三组（用 `Section`，对齐 Tripsy 的「住宿/交通」分组但更克制）：

- **地点**（`.addStop`）
- **交通**：航班（`.searchFlight` 搜索优先）/ 火车（`.addTransport mode:.train`）/ **租车（`.addTransport mode:.carRental`）** / **其他交通（`.addTransport mode:.other`）**
- **住宿**（`.addLodging`）

租车/其他交通全部复用现成的 `TransportEditView(initialMode:)`，零新表单。`.addTransport` 路由已存在（`ItineraryView.swift:160`），只加菜单项。

> 「其他交通」用 `initialMode: .other`，进表单后用户可在类型选择器切 bus/ferry。菜单标签用独立 key「其他交通」（`.other` 的 mode 名「其他」单独看有歧义）。

### 2. 收口错误路径：从「地点」类别选择器撤掉 carRental + cruise

- `AddStopView.categoryMenu` 不再拉 `StopCategory.allCases`，改用**精选的可选类别集** `StopCategory.placeSelectableCases`（在地体验 + lodging + other，**剔除 flight / train / carRental / cruise** —— 这些都该走交通流程）。
- **枚举 case 全部保留**（向后兼容铁律）：旧数据里把租车/邮轮加成的普通 stop 仍能正常解析、渲染、显示图标，只是新建时不再走这条路。
- cruise（邮轮/船）今后走「其他交通 → ferry」表达；`StopCategory.cruise` 仅为旧数据保留。

### 3. 文案修正：carRental 模式名「自驾/Car」→「租车/Car rental」

`itinerary.transport.mode.carRental` 现值 zh「自驾」/ en「Car」——当顶层入口名既不准（自驾≠租车）又与「汽车」易混。改为「租车」/「Car rental」，9 语言同步。

### 4. 表单打磨（`TransportEditView`，仅 carRental 受影响）

a. **公司是主字段、可单独保存**：当前 `canSave = 有班次号 || 有出发地名`。租车隐藏班次号、地点又是可选 → 只填公司无法保存（bug）。改为租车模式下 `有公司名(carrier) || 有取车地点` 即可保存。

b. **「还车地点同取车」开关**（借 Tripsy「相同的下车地址」，默认开，仅 carRental 显）：
- 新增 `@State sameReturnLocation = true`。
- 仅折叠**还车「地点」**一项；还车的**日期/时间仍独立**（同地取还、但取车 Day1、还车 Day5）。
- 开关位置：放「还车」section 顶部第一行；开 → 隐藏该 section 的地点按钮；关 → 显示，可填不同还车点。
- 保存时若开：`toName/toLatitude/toLongitude = from*`（把取车地点拷给还车端，保证导出/详情/地图数据完整）。
- 编辑回填：载入时按 `toName == fromName && 坐标一致 || 还车端为空` 推断初值（无显式存储位，派生即可）。

c. 其余字段差异化（公司标签、隐藏班次号/座位/IATA/航站楼、取/还车段头）**已实现**，不动。

### 5. 本地化（9 语言：en/zh-Hans/zh-Hant/de/es/fr/ja/ko/pt-BR）

- 改：`itinerary.transport.mode.carRental` →「租车」/「Car rental」/ 台港「租車」/ 各语言对应。
- 新：菜单「其他交通」key（如 `itinerary.kind.other_transport`，显式 en）。
- 新：还车开关 key（如 `itinerary.transport.field.same_return_location` =「还车地点同取车」/「Same as pickup」）。
- 中文全角标点；zh-Hant 台湾用语（租車）；结构化 key 显式写 en。

### 6. 埋点

`transportAdded(mode:)` 已覆盖 `carRental`/`other`，无需新增；确认菜单新入口触发的就是它。

## 不在本轮范围

- bus / ferry 的专属字段细化（先用通用交通表单）。
- 租车的实时取车提醒、车型库、价格比较等（远期）。
- 把旧的 `StopCategory.carRental` 存量 stop 迁移成 `TransportSegment`（保留即可，不强迁）。

## 验收要点

1. 「+」菜单出现「租车」「其他交通」，分组清晰；点租车进的是交通表单不是地点搜索。
2. 「地点」搜索的类别选择器里不再有车/邮轮；旧的租车 stop 仍正常显示。
3. 只填公司名能保存；时间轴显「公司名 + 车图标」。
4. 还车地点默认同取车、只填一处；关掉开关可填不同还车点；保存后详情/地图两端数据完整。
5. carRental 模式名各语言显示为「租车」类语义，非「自驾」。
6. 编译绿、启动不崩；备份/还原/复制行程对 carRental 段无回归（沿用既有 TransportSegment 通路，无新字段，零迁移）。

## 增补（2026-06-19）：租车在时间轴渲染为「取车 / 还车」两个事件

> **Status: 实现中。** 承接本 spec，修两处用户反馈。

### 动机
1. **详情/列表标签错位**：`TransportDetailView` 与时间轴行对租车仍显「Departure / Arrival（出发/到达）」——那是航班语义。租车应是「取车 / 还车」（编辑表单早已正确）。
2. **租车是「跨度」不是「一次移动」**：和住宿同形（你持有车 N 天），有两个**各自独立、在不同天、各有地点+时间**的动作——取车、还车。现状把它当一条「边」渲染成**单行**落在出发日、还车只用「+N」角标 → **还车那天时间轴上没有任何提示**（你那天得按时还车却无感知）。应像住宿（入住/退房两事件）那样拆成两个事件。

### 设计（镜像住宿，零模型迁移）
- 一条租车 `TransportSegment` 在**取车日**渲染「取车 · 公司 / 取车地点 · 时间」事件、在**还车日**渲染「还车 · 公司 / 还车地点 · 时间」事件。数据已够（两端地点 + 两个 dayOrder + 两个时间）。
- **不碰 `Itinerary.swift` 的 `timeline`**（航班会话热区）：它仍把租车段按取车时间放好；在 `ItineraryView.daySections` 把那条租车 timeline 项**解释成「取车」行**，并在还车日**按还车时间注入「还车」行**。
- 行 ID 用 `.carRental(segment:day:pickup:)`，**带 day 维度**保跨天全局唯一（避 diffable「item identifiers are not unique」崩溃——项目踩过两次，住宿用 `.lodging(stay:day:)` 同理）。
- 不可拖（`canReorderItem` 仅 `.stop`，天然排除）；重排模式只留 `.stop`，天然隐藏。
- 范围：**只做取车/还车两事件，不做中间天「持有中」跨天常驻条**（用户拍板）。
- 公共信息（公司/费用/确认号/备注）在详情浮层展示；详情对租车用「取车/还车」标签（复用 `section.pickup` / `section.dropoff`）。

### 落点
`ItineraryReorderCollection`（`ItineraryRowID` 加 `.carRental` + 内容闭包 + 派发 + 并入非 stop 组打断邻接）、`ItineraryView`（`daySections` 映射取车 + 注入还车并按时间定位、`carRentalRow` + `CarRentalEventRow`、闭包接线）、`TransportDetailView`（mode 自适应标签）。航班/火车/巴士/渡轮不变（它们确是单次移动，「+N」合理）。
