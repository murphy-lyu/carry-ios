# 首页空态：固定「缩放浮卡」Sheet（不可下拉 + 地图可用）

**Status:** Implemented（模拟器验收通过；空态与有行程折叠态几何逐常量同源、交叉验证一致）
**Date:** 2026-06-16
**关联雷区：** `CarryBottomSheetFX.swift` —— 改前必读 `docs/home-sheet-debug-playbook.md`

## 背景与问题（仅「无行程 / 空数据」态）

空态下首页底部 Sheet 当前表现 = **有行程时「展开到顶」的样子**：全宽、底边贴屏、无间距，且**可以下拉**。但空态没有内容可滚，下拉无意义；全宽贴屏也偏重。

期望：空态把 Sheet 锁成**一个固定的最佳尺寸**（= 现在空态内容自适应的高度），用**有行程折叠后的「缩放浮卡」视觉**呈现（左右 + 底部留屏距、圆角浮起、轻微缩放），**禁止下拉**；同时露出的 MapKit 地图**可切换样式、可显示当前定位、可拖动/缩放**。

## 目标（只动空态，有行程态完全不碰）

1. **固定 + 不可拖**：空态 Sheet 锁定为固定尺寸，禁用拖拽手势（现 `sheetPan` 在空态是开的）。
2. **缩放浮卡视觉**：复用折叠态常量——左右各 `collapsedSideMargin`(8)、底部 `collapsedBottomMargin`(8) 间距、圆角顶 `collapsedTopRadius`(36)/底 `collapsedBottomRadius`(56)、统一 scale——但**可视高度 = 空态内容高**（不缩到折叠的 ~188pt），内容完整可见。
3. **地图可用**：露出的地图区域控件激活——切换样式按钮 + 定位按钮显示且可点（现因 `mapCityOpacity=0` 隐藏）、开启后显示当前位置蓝点；卡片外地图**全交互**（拖动/缩放，靠 `FXPassthroughView` 既有穿透，天然成立）。

## 非目标
- 不改有行程态的展开/折叠/拖拽/吸附/缩放同步等任何行为。
- 不改空态卡片**内容**（文案、CTA、布局）——只改其**承载 Sheet 的几何与交互**。
- 不引入地图取景锁定（用户已确认要全交互）。

## 现状机制（已读码确认）

- `FXSheetViewController.geometry(for: rawOffset)`：纯位置函数。`effectProgress(positionProgress)` 驱动 `sideMargin`/`scale`/底部 `lift`/圆角；`visibleHeight = expandedHeight - lift - banded`。
  - 展开(progress 0)：sideMargin 0、scale 1、lift 0 → 全宽贴屏（= 当前空态）。
  - 折叠(progress 1)：sideMargin 8、scale ≈ (w−16)/w、lift 8、圆角 36/56 → 缩放浮卡。
- `expandedHeight`（空态）= 内容自适应高（`HomeView.expandedSheetHeight` 空态分支，handle+topBar+card+breathing+safeArea）。
- `sheetPan`（`handleSheetPan`，line ~765）：`if !isListEmpty { return }` → **当前空态启用整片拖拽**。
- `mapStyleButton`：`.opacity(mapCityOpacity)` + `.allowsHitTesting(mapCityOpacity > 0.05)`；`mapCityOpacity` 由 `onSnapChanged`（折叠→1 / 展开→0）驱动。空态不折叠 → 恒 0 → 控件隐藏。
- 根视图 `FXPassthroughView.hitTest`：卡片外返回 nil → 触摸穿透到 MapKit。故卡片外地图本就可交互。

## 设计

### 1. 空态固定「缩放浮卡」几何（`CarryBottomSheetFX`）

核心：空态时让卡片**静止在「满缩放效果 + 不下滑」**的位姿——即 `effectProgress = 1`（取 sideMargin/scale/lift 的折叠值）、`banded = 0`（不竖向滑动）、`shapeProgress = 1`（折叠圆角），于是：
- `sideMargin = 8`、`scale = (w−16)/w`、`lift = collapsedBottomMargin(8)`；
- `visibleHeight = expandedHeight − lift − 0 = 内容高 − 8`；
- `topY = h − expandedHeight`（卡顶位置与现状一致，地图在其上方照常露出）；
- 卡片视觉框 = 左 8 / 右 8 / 底 8 间距、~0.96 缩放、圆角 36/56 → 正是「有行程折叠后」的浮卡。

实现方式（二选一，实现时定，优先 A）：
- **A. 新增固定位姿入口**：`placeSheetFixedScaled()`——按 `effectProgress=1 / banded=0 / shapeProgress=1` 直接摆放，不走 rawOffset 通道。空态在 `viewDidLayoutSubviews` / `updateLayout` / 进入空态时调用它，且 `snappedOffset` 钉住该位姿。
- B. 给 `geometry(for:)` 加 `effectOverride` 参数，空态传 1 + banded 0。
- 复用既有 `placeSheet` 内对 `barView`（空态无 bar，跳过）/`outerView`/`innerView`/`hostingView` 的同一套摆放公式，不另造平行逻辑。

> 内容是按全宽 `expandedHeight` 一次性布局、再被 ~0.96 scale 整体缩放（既有不变式：内容不每帧 relayout）。空态卡片自带 `bottomBreathing(28)` + 安全区余量，0.96 缩放不致裁切 CTA（实现时真机确认）。

### 2. 禁用空态拖拽（`CarryBottomSheetFX`）

`handleSheetPan`：空态改为**直接 return**（不响应拖拽），即把现有 `if !isListEmpty { return }` 的空态分支反过来——空态不再驱动 sheet 位移。capsule 把手在空态可保留为纯装饰（不挂手势）或隐藏（实现时按视觉定，倾向保留装饰、无功能）。有行程态的 list 滚动驱动折叠**完全不动**。

### 3. 空态激活地图控件（`HomeView`）

空态把 `mapCityOpacity` 视同折叠态 = **1**：
- `mapStyleButton` 显示且可点（切换样式 + 定位）。
- `GlobeMapView` 的城市点等随 `cityOpacity` 行为与折叠态一致。
- 实现：`isEffectivelyEmpty` 为真时把 `mapCityOpacity` 置 1（onAppear / onChange(of: isEffectivelyEmpty)），退出空态恢复由 snap 驱动。
- 地图本就 `Map(position:)` 全交互；卡片外穿透已由 `FXPassthroughView` 保证 → 拖动/缩放天然可用。

### 4. 空↔有行程切换
- 进入空态：摆成固定缩放浮卡 + 禁拖 + mapCityOpacity=1。
- 退出空态（建了第一个行程 / 关闭 DEBUG 模拟空态）：恢复有行程态的可拖展开几何 + snap 驱动的 mapCityOpacity。用既有 `isListEmpty` 通路 + `.id`/update 重建保证干净切换。

## 影响面 / 风险
- **playbook 雷区**：只新增「空态固定位姿」一条独立路径 + 反转空态拖拽门控 + 空态 mapCityOpacity；**不碰**有行程态的 rawOffset→geometry→placeSheet 主链、吸附 spring、底栏同步缩放、cornerMask。
- 风险点：① 空态内容被 0.96 缩放后是否裁切 → 真机确认（必要时空态 `expandedHeight` 补一点余量）；② 空↔有行程切换是否有跳变/约束冲突；③ 空态地图拖动是否被卡片误吞（应不会，穿透已验）。

## 验收清单
- [ ] 空态：Sheet 为缩放浮卡（左右/底 8pt 间距、圆角浮起、轻缩放），**不可下拉**（拖把手/卡片无位移）。
- [ ] 空态内容（图标/标题/副标题/「创建第一个行程」CTA）完整不裁切，明暗两态。
- [ ] 空态：右上地图样式按钮 + 定位按钮显示且可点；开启定位显示蓝点；卡片外地图可拖动/缩放。
- [ ] 建第一个行程 → 平滑切到有行程态（可拖展开、底栏出现），无跳变/约束冲突/崩溃。
- [ ] DEBUG「模拟空态」开关来回切，两态都正确。
- [ ] 有行程态的展开/折叠/吸附/底栏同步缩放/无漏地图 等回归项全过（playbook §10）。
- [ ] 编译绿（主 app + Widget）。
