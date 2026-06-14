# 首页底栏随 Sheet 同步缩放

> **Status: Proposed（待用户确认 → 再实现）。** 关联：`Carry/Views/CarryBottomSheetFX.swift`（**仅新增** scale 输出，不改任何几何/吸附/手势/圆角/栅格化逻辑）、`Carry/Views/HomeView.swift`（底栏 `bottomActionBar` 加 `.scaleEffect`）。改前必读 `docs/home-sheet-debug-playbook.md`（§2 边界 / §5 禁忌）。

## 目标
下拉收起时，底部三键栏（搜索行程 ｜ 我的行程册 ｜ 创建 FAB）跟随 Sheet **等比缩小**，上拉时一起放大，让首页像一个整体在呼吸；不再是 Sheet 缩、底栏定死。

## 非目标（硬边界）
- **不改 Sheet 本身行为**：几何、吸附（`commitSnap` / `UIViewPropertyAnimator`）、手势、圆角、`placeSheet` / `applyCornerMask`、栅格化——全不动。
- 不给吸附链路加第二驱动源（§5 禁忌）。
- 不改卡片 / Trip Overview UI（§2）。
- 不引入 `CADisplayLink`（FX 已全程纯 CA，§32）。

## 机制
Sheet 内部本就逐帧算 `currentScale = g.scale`（拖拽，~L396）；松手吸附走 `UIViewPropertyAnimator(0.42, dampingRatio: 1.0)`（临界阻尼、无回弹）。我们**只把这个已存在的 scale 读出来发给底栏**：

- 新增输出 `onScale: (_ scale: CGFloat, _ animated: Bool) -> Void`（闭包）。
  - **拖拽**：在设 `currentScale` 处同帧发 `onScale(g.scale, false)`（跟手、不带动画）。
  - **吸附**：在 `commitSnap` 启动 animator 的同一时刻，发 `onScale(targetScale, true)`（`targetScale = geometry(for: target).scale`），让底栏用一条匹配曲线动到目标。

## ⚠️ 不影响 Sheet 的关键：隔离，避免反向触发 Sheet 重算
Sheet 的铁律是「动画期间零 SwiftUI re-evaluate」。若把 scale 存成 HomeView 顶层 `@State`，逐帧改它会让 HomeView body 每帧重算 → 连带 `CarryBottomSheetFX.updateUIView` 每帧被调 → **反向干扰 Sheet**。

**做法**：scale 存进一个**只被底栏观察**的轻量 `ObservableObject`（如 `SheetScaleModel { @Published var scale: CGFloat = 1 }`）。`onScale` 闭包写它 → **只有底栏那一小块重渲染**，HomeView body 与 `CarryBottomSheetFX` 都不被重算、`updateUIView` 不因缩放触发。Sheet 100% 维持原样。
- 拖拽：`model.scale = s`（用 `Transaction` 关动画，跟手即时）。
- 吸附：`withAnimation(<匹配曲线>) { model.scale = target }`。

## 吸附跨引擎同步（唯一调校点）
Sheet 吸附是 CA（GPU）；底栏是 SwiftUI——两套引擎。底栏用尽量贴近的 SwiftUI 动画追同一目标：`0.42s`、临界阻尼/无回弹（候选 `.easeOut(duration: 0.42)` 或临界阻尼 `interpolatingSpring`，真机调）。短促且无回弹，肉眼基本看不出差；**这是唯一可能"差一点点"的地方，需真机确认手感**，非结构问题。

## 视觉参数（真机定）
- **比例**：底栏与 Sheet **完全同比**缩放（用户要的"一起缩"）。
- **锚点**：`.scaleEffect(model.scale, anchor: .bottom)`（向屏幕底收，呼应收起后上抬的卡片底缘）；`.center` 作备选，真机各看一眼。
- `.scaleEffect` 是渲染变换、不改布局，`safeAreaInset` 预留空间不变，不引起跳动。

## 性能
底栏小、`scaleEffect` 纯 transform 不 relayout；逐帧只重渲染底栏（隔离）、不波及 Sheet。开销可忽略。

## 验收（含 playbook 回归）
1. **Sheet 自身行为零变化**：拖拽/吸附/圆角/滚动锁等全程如旧——**必跑 playbook §10 回归清单**（重点：下拉中途上拉不卡中段、direct collapse 不回弹、上拉滚动锁稳）。
2. 底栏：拖拽中实时跟手缩放；吸附段与 Sheet 同步收敛（重点看这 0.42s 是否同步）。
3. 无性能回归（确认缩放不触发 Sheet 重算 / `updateUIView` 每帧调用）。
4. 暗色、9 语言、Mac Catalyst（Catalyst 无此 FX sheet → 底栏 scale 恒 1，正常）。

## 数据 / 迁移
无。纯展示层。

---

# 终极方案（frame-perfect · 同一 animator 驱动）

> **Status: Shipped（已落地，真机验收通过 2026-06-14）。** 底栏移进 `FXSheetViewController`、与卡片同一 `UIViewPropertyAnimator` 驱动，像素级同步缩放。还原点：基线 commit `b2be676`（SwiftUI scaleEffect 近似版）；如需回退：`git checkout b2be676 -- Carry/Views/CarryBottomSheetFX.swift Carry/Views/HomeView.swift`。
>
> **实现要点（与下方设计一致）**：删除基线 `SheetScaleModel`/`onScaleChanged`/`BottomBarScaleSync`/`import Combine`；FX 泛型加 `Bar`，新增 `bottomBar:` builder + `installBottomBar(_:)`（底栏钉 `view` 底、约束 = 原 18pt padding、z 序在卡片上、不入 outerView）；`placeSheet` 里对 `barView` 施加底边锚定同 scale transform——吸附时该函数在 snap animator 块内被调用 → 底栏被同一 animator 插值，无第二驱动源（守 §5）。手势穿透靠 HostingController 对空白区返回 nil（pan 落到下方列表/卡片），按钮吃 tap，列表底部 124/176pt 占位行兜底。

## 为什么要它
基线版底栏（SwiftUI）与 Sheet（Core Animation）是两套引擎，只能"高度近似"；**快速甩动**时 Sheet 的 spring 带手势初速度、底栏不带 → 开头一小段会有可察觉的先后。终极解 = 让底栏与卡片**由同一条 CA 时间线/同一个 `UIViewPropertyAnimator` 驱动**，逐帧像素级一致，吃满物理上限。

## 架构改动
- 底栏从 HomeView 的 `.safeAreaInset(edge:.bottom)` **移进 `FXSheetViewController`**：新增 `barHost: UIHostingController`，承载现有 SwiftUI `bottomActionBar`（内容仍由 HomeView 经新 `@ViewBuilder bottomBar:` 闭包传入，按钮绑定 HomeView 的 search/tripBook/create 状态不变）。
- `view` 层级：`outerView`(卡) 先加 → `barHost.view` 后加（z 序在上）；`barHost.view` 钉在 `view` 底（`safeAreaLayoutGuide.bottom`），**不放进 outerView**（否则会随卡片滑走、改变定位）。
- 缩放：在 `placeSheet(at:)` 里对 `barHost.view` 施加与卡片**相同的 scale**（`layer.anchorPoint = (0.5, 1)` 锚定底边，向屏幕底收）。拖拽逐帧、吸附在**同一个 animator 块**里设 → frame-perfect、同曲线同初速度。
- **移除**基线的 `SheetScaleModel` / `onScaleChanged` / `BottomBarScaleSync` / safeAreaInset 底栏（终极取代之，不留过渡件）。

## ⚠️ 必须妥善处理的风险点（都在 §5 雷区附近，逐一守住）
1. **手势穿透**：`sheetPan` 挂在 `view` 上。底栏移进来后，「从底栏区域上滑要仍能拖动/滚动 Sheet」必须保持（基线靠"只吸收 tap、不拦 pan"）。需确认 barHost 的 SwiftUI 内容**不吞 pan**，pan 仍冒泡到 `sheetPan`；按钮/tap 正常消费。**这是头号风险**。
2. **列表底部净空**：现底栏的 contentInset/clearance 若依赖 safeAreaInset 预留，移走后列表可能被底栏遮挡。需把底栏高度显式喂给列表 `contentInset.bottom`（沿用 `bottomBarClearance` 思路）。
3. **底锚点缩放**：`anchorPoint=(0.5,1)` 要同步修正 `position`，否则锚点一改位置会跳。
4. **吸附所有路径**：direct + spring 两个 animator 块都要加 `barHost.view` 的 transform；§5 禁忌（不加第二驱动、不提前推终态）对底栏同样遵守——它就搭在卡片同一 animator 上，天然同步、不引第二源。
5. **安全区/旋转/Catalyst**：底栏底距随安全区；Catalyst 无 FX sheet 时退化。

## 诚实评估（供你拍板）
- **收益**：仅"快速甩动"那一小段从"近似"变"像素级一致"；常规拖放基线已"看起来丝滑"。
- **代价/风险**：改动落在**全 app 最脆弱的 FX 手势/布局/吸附链**（playbook 反复踩坑区），手势穿透/净空若没守住会引入新 bug——正是你担心的那类。
- 这是你明确选择"要最优、不在乎成本"且已设还原点的前提下推进。基线 `b2be676` 是安全网。

## 验收（比基线更严）
1. **playbook §10 全回归**（重点：下拉中途上拉不卡中段、direct collapse 不回弹、上拉滚动锁稳）+ **从底栏区域上滑仍能拖/滚 Sheet**。
2. 快速甩动：底栏与 Sheet 是否逐帧一致（终极的验证目标）。
3. 底栏按钮（搜索/行程册/创建）功能、列表不被遮挡、底距正确。
4. 暗色 / 9 语言 / Catalyst。
