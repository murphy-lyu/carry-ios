# 行程「地点排序」模式（菜单进入 · 压缩行 + 拖拽手柄 + 锁误触）

> **Status: Implemented · 模拟器自测通过（2026-06-15，commit `518a121`），待用户真机验收。** 形态如设计（压缩行 + 拖拽手柄 + 锁误触 + 保留常驻长按；未做移到第X天/多选/独占）。
>
> **自测结论（iPhone 17 Pro 模拟器）**：菜单「Reorder Places」按 ≥2 地点显示、位置/图标/本地化正确；进模式 …→Done、压缩行+≡手柄、底部切换器隐藏、leg/交通/住宿/Add/Optimize 全隐；天内重排 ✅、跨天移动 ✅（自动滚动、无数据丢失）、地图预览随拖拽实时更新 ✅；Done 退出恢复完整行+chrome ✅；正常态常驻长按拖拽仍可用 ✅；运行时无约束冲突/AttributeGraph 重入/崩溃。
>
> **一处可选细化（留用户定）**：排序模式下顶部地图预览 + 日历条仍显示。判断：保留更佳——地图随拖拽实时反映新顺序（即时空间反馈）、日历条便于跨天时跳转；故未隐藏。如想更极致聚焦可再隐去地图。
>
> 关联：`Carry/Views/PackingListView.swift`、`Carry/Views/ItineraryView.swift`、`Carry/Views/ItineraryReorderCollection.swift`。

## 背景 / 现状（已验证）
- 跨天拖拽**能力已存在**：`ItineraryReorderCollection` 用 `UILongPressGestureRecognizer` + `beginInteractiveMovementForItem`，**长按任意 `.stop` 行即可拖、可跨天**（原生 cross-section），带 lift/step 触感（`ItineraryReorderCollection.swift:348`）。行 tap = 进详情、滚动 = 正常滚，三者不冲突。
- "…" 菜单在容器 `PackingListView`（行程详情容器，`case .itinerary: ItineraryView(tripId:)`，菜单 `:165`），两个 tab 共享、分支渲染。

## 为什么还要做这个模式（两个真实痛点各占一半）
- **A 可发现性**：长按拖拽是隐藏手势，用户多半不知道能拖。
- **B 批量重排效率**：长按逐个拖、长列表里盲滚，跨多天大改很累。
- 一个「从菜单进入的排序模式」一举吃掉两者：菜单项解决 A，模式内的形态变化解决 B。**不是把长按拖拽换层皮**——它带来长按给不了的压缩视图/锁误触增量。

## 设计

### 入口
- `PackingListView` 共享 "…" 菜单的 **itinerary 分支**新增 **「地点排序」**（`itinerary.reorder.menu`），紧邻其它 itinerary 专属项；与每日行内的 **Optimize（自动）** 形成「手动/自动」一对心智。
- **显示条件**：仅 itinerary tab + 当前行程**总 `.stop` 数 ≥ 2**（<2 无可排，不显示）。

### 模式状态（放容器层）
- `PackingListView` 持 `@State private var isReorderingItinerary = false`，以 `Binding` 传入 `ItineraryView(tripId:isReordering:)`，再下传 `ItineraryReorderCollection`。
- 放容器层的原因：进入模式要把导航栏 **"…" 换成 "完成"**（`common.done`）、并可隐藏 tab 切换控件——这些都是容器拥有的 chrome。
- 进入/退出用 `withAnimation(.spring(duration: 0.3, bounce: 0.2))`（项目标准交互动画）。

### 模式内表现（相对常驻长按的增量价值）
1. **压缩行**：`.stop` 行只留 **类别图标 + 名称**单行，隐去地址 / 时间 / 距离 → 一屏看更多天、跨天搬不盲滚。（ItineraryView 在 `isReordering` 时渲染 compact 版 `stopRow`。）
2. **拖拽手柄 ≡**：每行尾部出 `line.3.horizontal` 手柄（`.tertiary`）→ 显性"可拖"（强化 A）。
3. **锁误触**：`isReordering` 时 `.stop` 行的 `onTapGesture`（进详情）禁用；导航按钮、leg 段距、Add place、Optimize、transport/lodging 行**全部隐藏**（collection 在该模式不插入这些自动行，只渲染 day header + stop）。
4. **即抓即拖**：模式内把长按 `minimumPressDuration` 降到 ~0（或允许从手柄直接拖），手感像"抓住手柄拖"，而非再等长按；跨天 interactive movement、触感不变。
5. **日期分隔**：day header 作为 section 头保留（且可 sticky），看清落到哪天。

### 退出
- 导航栏 "完成" → `isReorderingItinerary = false`，恢复正常行（带地址/时间/距离）、恢复 chrome 与 tap 进详情。
- 排序结果走现有 `onArrange` → `store.applyItineraryArrangement(tripId:dayOrders:)`（持久化逻辑复用，不新写）。

### 保留常驻长按拖拽（不独占）
- 正常态仍可长按任意行直接拖（偶尔挪一两个，免进出模式）；模式服务批量大改。两者强度不同、模式带压缩/锁误触的真增量，非纯重复。Apple 同时给常驻拖拽 + 编辑态（Reminders/Files）。

## 与「交通/住宿」功能的交叉（实现时必须对齐）
- 当前只 `.stop` 可拖（`handleLongPress` 仅 `case .stop`）。排序模式**只重排地点（places）**。
- 交通段（边）/住宿（跨度）如何随地点重排而跟随/重算，**取决于那条线最终的数据模型**——本 spec **不锁定**该交互，留作实现时与「交通/住宿」spec 对齐的开放项。先保证地点重排正确，交通/住宿跟随为后续增量。

## 不做（克制 · 先上线看真实使用）
- 不做「移到第 X 天」下拉、不做多选批量移动——拖拽 + 压缩行先验证；超长行程仍痛再加。
- 不做模式独占（去掉常驻长按）——高频小挪动不该被进出模式拖累。

## 文案（9 语言，含显式 en；中文全角）
- `itinerary.reorder.menu` = 地点排序 / Reorder places（zh-Hant：地點排序；其余 de/es/fr/ja/ko/pt-BR 同步）
- `itinerary.reorder.title`（模式标题/提示，可选）= 拖动以重新排序 / Drag to reorder
- 复用现有 `common.done`（若无则新增，9 语言）。

## 验收
1. 菜单项仅 itinerary tab + ≥2 停靠点时出现；点击平滑进模式（… → 完成）。
2. 模式内：压缩行、手柄、tap 不进详情、chrome 隐藏；拖拽跨天正确、触感在；完成退出恢复如初、排序已持久化。
3. 正常态常驻长按拖拽**仍可用**（未被模式破坏）。
4. 与交通/住宿行的交叉行为符合对齐后的约定（占位，待定）。
5. 暗色 / 9 语言 / 空与单停靠点（不显示入口）/ Mac Catalyst（如行程页存在）。

## 数据 / 迁移
无新模型。复用 `applyItineraryArrangement` 持久化。
