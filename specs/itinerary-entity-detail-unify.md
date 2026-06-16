# 行程时间轴三类对象：统一「只读详情 → 编辑」交互

> **Status: 已拍板（2026-06-16）— 待/正实现。** 依赖 `itinerary-stop-detail.md`（StopDetailView 模式）、`itinerary-stop-travel-modes.md`（导航模块）、`itinerary-cost-tracking.md`（费用展示）。

## 背景 / 问题

时间轴上三类对象点击行为不一致：
- 地点 `stop` → `.stopDetail` → **只读详情**（看信息，底部 Edit 再进编辑）✅
- 交通 `transport` → `.editTransport` → **直接进编辑** ❌
- 住宿 `lodging` → `.editLodging` → **直接进编辑** ❌

直接进编辑「过了」：多数点击意图是查看（确认航班时间/酒店地址/确认号），且易误改。应统一为 **点击 → 只读详情 → Edit 按钮 → 编辑**，与地点一致（ADA 一致性）。

## 决策（已拍板）

1. **交通、住宿都新增只读详情页**，复用 `StopDetailView` 的壳：内容贴合高度 sheet、不透明底、头部内联 X、底部烟蓝 Edit、`ExpandableText` 折叠长备注、无障碍齐全。
2. **有值才显，空的不显**（条件渲染，不留空行）——同 `StopDetailView`。
3. **住宿带 Get Directions**（有坐标，导航去酒店有意义）；**交通不带**（导航去"出发站"意义不大）。
4. 编辑入口：详情底部 Edit → 钻入现有 `LodgingEditView` / `TransportEditView`（nested sheet，同 StopDetailView 的 editing 模式）。保存后 `@Model` 可观察、详情自动反映。

## 架构

- **抽出可复用导航模块** `DirectionsModule`（`coordinate / name / navApps / distanceToNext? / tint`，自持 `@State navMode`）——从 `StopDetailView.navModule` 提取，地点与住宿共用，消除重复、避免漂移。交通详情不引用它。
- 新文件 `LodgingDetailView.swift` / `TransportDetailView.swift`（项目惯例：新文件自动纳入 target）。
- 路由（`ItineraryView`）：
  - `ItinerarySheet` 加 `.lodgingDetail(UUID)` / `.transportDetail(UUID)`（带 id 项 + sheet 内容分支）。
  - 点击改：交通行 `.editTransport` → `.transportDetail`；住宿行 `.editLodging` → `.lodgingDetail`。
  - `.editTransport` / `.editLodging` 仍保留（由详情页 Edit 钻入）。

## 字段清单（有值才显，逐项核对——防遗漏）

### 住宿 LodgingDetailView（顺序）
- 头部：床图标 + `stay.name`（空→「住宿」）+ X
- 入住：`checkin_day` 标签 + 入住日期 + 晚数（`nights_value`）——核心，常显
- 入住时间 `checkInMinutes >= 0` 才显
- 退房时间 `checkOutMinutes >= 0` 才显
- 费用 `stay.hasCost` 才显（`CurrencyCatalog.format`，真实付款币种不折算）
- 确认信息 `!confirmationCode.isEmpty` 才显（复用 `itinerary.transport.field.confirmation`）
- 备注 `!note.isEmpty` 才显（`ExpandableText` 折叠）
- 地址 `hasCoordinate && !address.isEmpty`：地址行（点按复制）+ **DirectionsModule**（去酒店）
- 底部 Edit

### 交通 TransportDetailView（顺序）
- 头部：mode 图标 + 标题（`carrier · number`，都空→ mode 名）+ X
- 出发：`fromName`/`fromCode` + 出发时间 + 航站楼 `fromTerminal`——逐项有才显
- 到达：`toName`/`toCode` + 到达时间（跨天 +N）+ `toTerminal`——逐项有才显
- 座位 `!seat.isEmpty`
- 确认信息 `!confirmationCode.isEmpty`
- 费用 `hasCost`
- 备注 `!note.isEmpty`（`ExpandableText`）
- 底部 Edit
- **不带 Get Directions**

## 文案

尽量复用既有 key（`field.confirmation/seat/terminal_only`、`lodging.field.checkin_day/nights_value`、`section.depart/arrive`、`mode.*`、`stop.detail.edit/copy_hint/address_copied/note_more/note_less`、`common.close`）。缺的结构化 key（如住宿"入住/退房时间"只读标签若不复用 edit 的）补齐 × 9 语言、显式 en、中文全角。

## 不做 / 范围

- 不改三类的编辑页本身（只在其前面加只读层）。
- 交通不做导航 / 不做 turn-by-turn。
- 不动费用闭环（`CostBearing` 四处同步规则不受影响，只读页仅展示）。

## 待办

1. 抽 `DirectionsModule`，`StopDetailView` 改用它（回归验证地点导航不变）。
2. `LodgingDetailView`（含 DirectionsModule）+ `TransportDetailView`。
3. 路由：加两个 detail case、改两处 tap、Edit 钻入。
4. 文案缺项补齐 × 9。
5. 编译；真机/模拟器验收三类点击一致 + 条件渲染 + 住宿导航 + 交通无导航。
