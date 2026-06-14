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
