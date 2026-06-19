# Itinerary Flight：搜索优先的添加航班（Search-First Add Flight）

> **Status: Implemented（编译绿 · 模拟器 iOS 26.5 实测通过 · 待真机验收）。未提交。**
> 航司 logo 决策：按建议**不做真实 logo**，用中性小飞机符号承载识别。

## 实现定稿（2026-06-19，模拟器实测通过）

落地与最初 Draft 有两处交互定稿调整（经与用户多轮打磨）：

### 1. 第 1 段日期交互：竖排列表 · 「选日期 = 触发查询」（非 chip 累积）
- 输完航班号 → 即时识别航司（`AirlineDatabase`，已实测 MU→中国东方航空 / 中文设备显中文名）。
- 识别后**向下展开竖排日期列表**（不是横排 chip——横排宽 chip 丑且长行程要横滚）：本行程的每一天各一行 + 「选择其他日期…」（开系统日历，应付行程区间外的红眼航班）；无日期行程给 今天/明天。
- **触发模型对齐 Flighty**：不预填「待触发」的日期、不加查询按钮——**点某一天这个动作本身即触发查询** → 结果确认卡 → 点卡 push 进预填 `TransportEditView`。超长行程（>31 天）不铺几十行，只留「选择其他日期」日历。
- 走过的弯路（已纠正、勿重蹈）：① 横排日期 chip（丑+横滚）；② 单行原生 DatePicker 预填默认值（预填把「选日期=触发」这个天然触发点吃掉了，只能靠回车/按钮，别扭）。

### 2. 第 2 段（手动/预填表单）日期+时间：融合 chip（参考 Tripsy）
- `TransportEditView` 每个起降段的「日期 / 时间」**合成一行两个 chip**：`📅 [日期 chip] [时间 chip]`，取代原「day Picker 行 + 时间开关行」。
  - 日期 chip：显示该段所在**行程天**（带行程日期，如 Mon Jul 20）；多天行程点它弹菜单换天，单天仅作信息展示。**日期仍锚定在天上**（未做「无日期」——那是单独立项，见下）。
  - 时间 chip：可选——未设显示占位「时间」，点开**滚轮选择器 sheet**（Done 设定、编辑既有时间时可「清除时间」回未设）。
- **根因解了「开关一开行高被撑高」的跳变**：根因是把比开关高的 compact `.hourAndMinute` DatePicker 条件性塞进开关那一行。融合 chip 后无开关、选择器移到弹出层、chip 普通行高 → 行高恒定、信息量也压缩（两行→一行）。曾试过的「隐形占位」是 workaround（关态也虚高），已废弃。
- 地点搜索 + 时间选择**合并为单一 `.sheet` 枚举**（`TransportSheet.search/.time`），遵守「同一视图多 `.sheet(item:)` 互相抑制」教训。

### 3. 工程
- 顺手根治 `FlightLookupService` 的 Swift 6 隔离报错：上游 DTO（`ProxyResponse`/`FlightDTO` 等）补 `nonisolated`，使其合成的 `Decodable` 可在 `nonisolated` 的 `lookup` 中解码（与 `FlightLookupResult` 一致）。
- 航司表管线：`scripts/airlines/`（OpenFlights `airlines.dat` + Wikidata 多语言名，英文名也优先 Wikidata——OpenFlights 的 9C 旧名 "China SSS" 已被 "Spring Airlines/春秋航空" 覆盖）→ `Carry/Resources/airlines.json`（986 航司）。

## 留作单独立项：日期「真正可选」（脱离按天分组）
用户希望最终对齐 Tripsy 的「日期也可不启用」。但 Carry 时间轴是**按天分组**、交通段 `day: ItineraryDay?` 锚定某天；Tripsy 是**扁平按时间排**。「无日期交通段」与按天分组正面冲突，需新增「未排期」区 + `day` 可空/`departDayOrder` 哨兵 + schema 迁移 + 备份/复制/删天级联/PDF 全链路，且与并行租车会话改的时间轴高度重叠。**故拆出单独 spec + 协调后再做**，本轮先交付融合 chip（日期锚定天）。
> 关联：`itinerary-flight-lookup.md`（航班号→自动回填，已实现 P1）、`itinerary-airport-search.md`（内置机场库）、`itinerary-transport-lodging.md`（TransportSegment 数据模型）。
> 落点（预计）：新增 `Carry/Views/FlightSearchSheet.swift`（第 1 段搜索）、`Carry/Models/AirlineDatabase.swift` + `Carry/Resources/airlines.json` + `scripts/airlines/`（航司表）；改造 `TransportEditView.swift`（移除内嵌自动填块，作为第 2 段预填/手动表单）、`ItineraryView` 的「+」菜单航班入口。

## 动机

现状（`itinerary-flight-lookup.md` 落地后）：添加航班 = 打开 `TransportEditView` 一张**手动优先**的完整表单，所有字段一次摊开，「✨ 用航班号自动填」只是塞在航空公司下面的一个**可选加速器**。用户得先面对一堆字段才注意到能自动填——主次颠倒。

竞品（Flighty / Tripsy 实测截图，2026-06-18）都是**搜索优先 + 两段式**：
1. **第 1 段·搜索航班**：智能输入框，输航班号 → 识别 → 补日期 → 出结果卡（渐进披露，每步只呈现当下要填的一件事）。
2. **第 2 段·预填可编辑详情**：把 API 能拿到的**全填进去**，API 给不了的（预订代码/座位/座位等级/费用/备注）留占位让用户补，点保存 → 进行程。

目标：把 Carry 的添加航班从「手动优先」翻转为「**检索优先、手动兜底**」。对春秋航空（9C）等 API 查不到的航班，保留手动输入作为**兜底**（而非默认）。

## 关键洞察：第 2 段我们已经有了

竞品第 2 段「预填的可编辑详情页」= Carry 现有的 `TransportEditView`（航司/航班号/起降机场+航站楼/起降时间/座位/确认号/费用/备注一应俱全）。
所以本次**不是新写详情页**，而是**重构链路**：把「自动填」从表单中间抽出来前移成第 1 段搜索；搜到 → 带结果进 `TransportEditView`（预填）；搜不到 → 「手动输入」进**同一个** `TransportEditView`（空表单）兜底。

## 流程图

```
行程「+」菜单 → 航班
        │
        ▼
  ┌──────────────────────────────┐
  │ 第1段  FlightSearchSheet (新) │
  │  航班号 (即时识别航司)         │
  │     → 日期                    │
  │     → 查询 → 结果确认卡        │
  │  [底部常驻·低权重: 手动输入]   │
  └──────────────────────────────┘
     │ 点结果确认卡                  │ 点「手动输入」
     ▼                              ▼
  TransportEditView (预填)      TransportEditView (空, mode=.flight)
     │  用户补座位/确认号/费用…      │  用户全手填
     └──────────→ 保存 → 进行程 ←───┘
```

- **编辑已存在航班**：不走搜索，直接进 `TransportEditView`（在改不是在加）。
- **非航班交通**（火车/巴士/渡轮/自驾/住宿）：维持现状，「+」菜单直接进对应表单，不在本 spec 内。

## 已确认的产品决策（2026-06-18 与用户敲定）

1. **「手动输入」兜底入口 = 常驻搜索页底部·低视觉权重**（次要灰字「找不到你的航班?」+ 强调色「手动输入」），一进搜索页即在，不必等查询失败才出现。
   - 理由：春秋航空等用户**事先就知道查不到**，强制先输一遍再撞「未找到」= 先碰壁；查到的结果也可能不是用户那一班（同号不同日/代码共享）需随时转手动。低权重 → 搜索框仍是主角（克制不破），逃生口随手可得（北极星：别让用户先碰壁）。与 Tripsy 一致。
2. **搜到航班后先出「结果确认卡」再进编辑页**（查询 → 结果卡：航司/航线/起降时刻 → 点卡片才进预填编辑页）。
   - 理由：让用户核对「是不是这班」，能优雅处理同号不同日/多候选，避免填错班。Tripsy 即如此。
3. **航司即时识别 P1 一起做**：输航班号时即时显示航司名（MU → China Eastern Airlines）。需新增本地航司表（见下）。

## 待确认（实现前请用户拍板）

- **航司 logo**：竞品显示真实航司彩色 logo（东航红标等）。建议**不做真实 logo**（商标授权风险 + 数百张图片资源体积 + 我们有过 monogram 兜底残留教训），改用**中性的 IATA 色块/小飞机符号**承载识别，只保证「名称」准确。← 待用户确认是否接受「无真实 logo」。

## 第 1 段：FlightSearchSheet（新建）

### 布局（渐进披露）
- 顶部：标题「搜索航班」+ 取消。
- **航班号输入框**（自动大写、关闭自动纠错、数字+字母键盘）。输入时：
  - 即时解析「航司代码 + 班次号」（如 `MU5431` → `MU` + `5431`），命中航司表 → 下方显示一行「`MU 5431` / China Eastern Airlines」识别结果（带中性航司色块）。
  - 解析不出/航司未知 → 仍可继续（航司名查询成功后补）。
- 选中识别行 / 继续 → 输入框转为 **chip 累积式**：`✈ MU` `# 5431` + 第三格「日期」（点开内联日历/快捷 今天·明天）。日期默认 = 该航班所属行程出发日对应真实日期（沿用现有 `loadIfNeeded` 逻辑）。
- 航班号 + 日期齐 → 调 `FlightLookupService.lookup` → **结果确认卡**：
  - 航司名 / 航线（出发城市 → 到达城市）/ `SHA 19:10 → CKG 22:20` / 日期。
  - 多候选（同号多实例）→ 列多张卡供选（`FlightLookupService.pickFlight` 当前按日期自动选一班；本 spec 可扩展为列候选，P1 至少正确显示选中那班）。
- **底部常驻·低权重**：「找不到你的航班?  手动输入」。

### 状态机
`idle`（仅航班号）→ `needDate`（航班号 OK，待日期）→ `loading` → `result(确认卡)` / `notFound` / `failed`。
- `notFound` / `failed`：提示一行 + 底部手动输入入口（本就常驻）更显眼地引导。

### 衔接到第 2 段
- 点结果卡 → present/push `TransportEditView`，用 `FlightLookupResult` **预填**（复用现有 `applyFlightResult` 映射逻辑，从 TransportEditView 抽成可被 search 复用的入口，或经初始化参数注入）。
- 点「手动输入」→ `TransportEditView`（空，`mode=.flight`，带已输入的航班号/日期若有）。

## 第 2 段：TransportEditView 改造

- **移除**内嵌的「✨ 用航班号自动填」块（`carrierSection` 内 `lookupDate`/`lookupFlight`/`lookupStatus` 那段）——自动填唯一入口前移到第 1 段，避免两个自动填入口打架。
- 新增「预填初始值」入口：搜索结果经初始化参数（或一个 `prefill: FlightLookupResult?`）注入，`loadIfNeeded` 在「新增且有 prefill」时调用 `applyFlightResult`。
- 其余字段/保存逻辑不变（航司/航班号/机场/航站楼/时间/座位/确认号/费用/备注 → `store.addTransportSegment`）。空字段保留 placeholder 让用户补（对齐 Tripsy 第 5 张）。
- `applyFlightResult` / `applyFlightTimes` / 时区日期换算 helper 保留（被新链路复用）。

## 航司表（airlines.json + AirlineDatabase）

沿用机场库（`itinerary-airport-search.md`）同一套管线：

- **数据源**：OpenFlights `airlines.dat`（IATA/ICAO → 航司名，ODbL，与机场库同源已署名）+ Wikidata 补多语言名。
- **裁剪**：有 IATA 二字码、active 的航司（含中国国内航司如 9C 春秋——即便航班查不到，识别航司名仍有价值）。
- **数据模型**（`Airline`，对齐 `Airport`）：`iata`（2字码）、`icao?`、`name`（英文）、`nm: [String:String]?`（多语言名，键同 `AirportLocale.languageKey`：zh-Hans/zh-Hant/de/es/fr/ja/ko/pt-BR）。`displayName` 按设备语言取，缺失回落英文。
- **加载**：`AirlineDatabase` actor，JSON 懒加载、后台解码（同 `AirportDatabase`）。提供 `name(forIATA:)` 同步快查（小表可全量驻内存，~1500 航司体积小）。
- **脚本**：`scripts/airlines/`（build + fetch_names）+ README（来源/许可/重建步骤），对齐 `scripts/airports/`。
- **署名**：`AboutView`「数据来源」卡已列 OpenFlights，航司数据同源无需新增条目（如用 Wikidata 多语言名，CC0 无需署名，与机场库一致）。

## 本地化

- 新增文案（结构化 key，9 语言齐全、含显式 en、中文全角、日语常体、韩语해요体）：
  - `flight.search.title`（搜索航班）、`flight.search.placeholder`（航班号占位，如「航班号，例如 MU5431」）、`flight.search.date`（日期）、`flight.search.manual`（手动输入）、`flight.search.manual_hint`（找不到你的航班?）、`flight.search.notfound`、`flight.search.failed`、`flight.search.detected`（已识别航班）等。
  - 复用现有 `itinerary.flight.*`（已实现的查询态文案）尽量复用，不重复造。
- 航司/机场名为数据，非 xcstrings（按设备语言取 `nm`，已有范式）。

## 埋点

- 复用现有 `flightLookupStarted/Resolved/NotFound/Failed`。
- 新增评估：`flightSearchManualFallback`（用户走了手动输入兜底）——衡量「查不到」的真实占比，指导后续是否换/补数据源。即定义即接线（CLAUDE.md 埋点闭环）。

## 非目标（明确边界）

- 实时动态（延误/登机口变更/推送）——留 Pro 阶段（`liveStatusData` 已预留）。
- 真实航司 logo 图片资源（见「待确认」）。
- 机场/航司「浏览」式添加（Flighty 的 frequently-used 列表是 flight-tracker DNA，Carry 是 trip-planner，只需「航班号→自动填」这一条主路径）。
- 非航班交通方式的搜索化。

## 验收要点（待真机）

1. 「+」→航班 → 输 `MU5431` → 即时显示「China Eastern Airlines」→ 补日期 → 结果卡正确（SHA→CKG / 时刻 / 跨午夜）→ 点卡进预填表单 → 补座位/费用 → 保存 → 时间轴+地图正确。
2. 输 `9C8888`（春秋，查不到）→ 底部「手动输入」常驻可见 → 点进空表单手填 → 保存正常。
3. 查询失败/无网 → 优雅降级到手动，不卡死。
4. 编辑已存在航班 → 直接进表单、不走搜索。
5. 多语言：中文设备显示中文航司/机场名；英文设备显示英文。
