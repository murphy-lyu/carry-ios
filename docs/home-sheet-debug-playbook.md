# Home Sheet 调试与收敛手册（持续更新）

> 目标：为后续新对话/新协作者提供完整上下文，避免重复走弯路与 A/B/C 补丁式死循环。

## 1. 模块范围

- 业务位置：`HomeView` 的底部 Sheet 容器（包含 Trip Overview + 行程卡片内容）。
- 核心实现文件：`/Users/murphy/Documents/Projects/Carry/Carry/Views/CarryBottomSheet.swift`

## 2. 用户明确不变的边界

- 不改 `Trip Overview` 和行程卡片 UI 本身。
- 先保证交互稳定，再谈视觉细腻。
- 禁止补丁式“改一处炸另一处”的循环。

## 3. 关键问题现象（历史）

- 快速下拉松手触发自动吸附时，曾出现：
  - 先弹到顶部再下落；
  - 或先弹到中段再下落；
  - 或半空先明显压缩高度，再快速落到底部；
  - 或落地末段左右边距/底部边距/圆角在最后一瞬突变。
- 但“全程手动跟随拖拽”多数情况下是正常的。

## 4. 根因结论（最重要）

- **手动跟随链路正确，问题集中在自动吸附链路。**
- 自动吸附阶段一度存在“多通道竞争”：
  - 位置一条通道；
  - 形态（shape/mask）另一条通道；
  - 个别方案还叠加 displayLink 或分段动画。
- 结果是位置、宽度、可见高度、圆角不再同节奏，触发反向弹跳/中段跳变/半空压缩。

## 5. 明确禁忌（后续不要再犯）

- 不要在“下落主动画开始阶段”就把 `shapeProgress` 直接推到终态。
- 不要在同一条自动收起路径里并行启用多个驱动源（主 animator + 额外 shape 跟随）。
- 特别是 `sheetPanDirectCollapse`：**不要启用 `startSnapShapeFollow(...)`**，这会把已收敛的单向收起再次拉回双驱动竞争区，容易复发“先上弹/中弹再下落”。
- 不要反复在 A/B/C 路径间来回切换，必须先固定单一路径再调参数。

## 6. 当前收敛策略（截止本文档）

- 自动吸附统一回到 `commitSnap` 主管线，不再使用独立“第二套”收起路径。
- 对“把手下拉松手收起”单独策略：
  - 非弹簧、单向收敛（避免反向 overshoot）；
  - 当前方向参数为 `easeIn`；
  - 避免下落中段提前触发明显高度压缩。
- 性能侧当前处理：
  - direct collapse 动画块里不再每帧调用 `applyCornerMask(...)`（减少中段卡顿）。
  - 左右/底部边距改为 `positionProgress` 驱动，避免 shape 锁定时边距末段突变。
- 圆角/底部显露时机通过 `bottomRevealProgress` 的 `threshold` 控制。

## 7. 关键参数与代码锚点

文件：`/Users/murphy/Documents/Projects/Carry/Carry/Views/CarryBottomSheet.swift`

- 位置/边距进度：
  - `effectProgress(_:)`
- 底部显露（影响“末段是否突变”）：
  - `bottomRevealProgress(_:)`
  - 当前：`threshold = 0.97`（中间曾试 0.75/0.65/0.55/0.35，均未从根本解决“吸附过程不均匀”）
- 自动吸附主入口：
  - `commitSnap(to:velocity:source:)`
- 把手下拉直接收起来源标识：
  - `source == "sheetPanDirectCollapse"`
- 手势入口：
  - `handleSheetPan(_:)`
  - `handleListPan(_:)`

## 8. 本轮关键修复要点（可追溯）

1. 删除/停止依赖独立的“分段收起动画路径”，统一进入 `commitSnap`。
2. 给“把手下拉松手收起”单独设置非反弹时序，抑制“先上弹/中弹”。
3. 避免在下落中段提前推进 shape 到终态，防止“半空先压矮再下落”。
4. 将底部显露时机参数外提为 `bottomRevealProgress.threshold`，用于纯参数调优。
5. 回归案例补充：曾尝试在 `sheetPanDirectCollapse` 里恢复 `startSnapShapeFollow(duration: 0.34)` 以求“更均匀变化”，结果复发上弹问题；已回退，作为反例保留。

## 9. 仍在调优的维度（不是结构问题）

- 末段圆角变化是否过快（通过 `bottomRevealProgress.threshold` 调整分布）。
- 左右边距、底部边距在自动收起时是否足够均匀（在不改主通道前提下微调）。
- direct collapse 在中段是否仍有卡顿/台阶感（重点观察快速短行程下拉松手）。

## 10. 回归测试清单（每次改动必跑）

1. 快速短行程下拉松手：不得先弹到顶部或中段。
2. 自动下落中段：不得“先压缩到最矮再落下”。
3. 慢速跟手拖拽：上拉/下拉都需线性跟手，无异常回弹。
4. 落地末段：圆角、左右边距、底部边距变化不可集中在最后一帧突变。
5. 列表手势联动规则需继续满足（内容区/把手区行为一致性）。

## 11. 未来建议（保持工程稳定）

- 先锁“结构正确性”，再做视觉丝滑参数化。
- 每次只改一个参数，并记录“改前值 -> 改后值 -> 结果”。
- 若引入新机制（如新的 shape 跟随方式），必须先写清楚替代关系，避免多通道并存。

## 14. 下一阶段优化路线（已对齐）

目标：在“左右间距一致性已基本达标”的前提下，优先优化上/下拉过程的丝滑度。

阶段 1（先做）：
- 只调直上/直下的时长参数，不动结构。
- 计划双档对比：
  - 档 A：`duration = 0.42`（当前）
  - 档 B：`duration = 0.48`（更细腻，代价是响应略慢）
  - 验收结果（本轮）：`0.48` 体感“还不错”，保留为当前值。

阶段 2：
- 拆分进度通道（参数层），不再让位移/边距/圆角强耦合。
- 目标：
  - `positionProgress` 负责位移
  - `insetProgress` 负责左右/底部边距
  - `cornerProgress` 负责圆角变化

阶段 3：
- 细调 `bottomRevealProgress` 的窗口（建议先 `0.97` vs `0.90`）。
- 目标：减轻尾段突变，让底部圆角显露更自然。

阶段 4：
- 补齐像素对齐策略，减少微抖和锯齿观感。
- 重点检查 `y / sideMargin / clippingHeight / width` 的一致对齐规则。

## 15. 需求基线（用户验收标准）

### 1) 基础体验（不含两侧/底部缩放视觉）

以下要求优先级最高，必须先稳定成立：

- 跟手一致性：
  - 拖拽把手时，上拉/下拉都必须 1:1 跟手，不得出现自动抢夺、提前回弹、延迟跟随。
  - 拖拽内容区时，需遵守与把手一致的联动规则（见下方 3 条基础规则）。

- 三条基础联动规则（已明确）：
  1. 当内容区已在顶部时，继续下拉内容区，应等同于下拉把手（驱动 Sheet 下拉）。
  2. 当内容区在顶部且用户上滑内容区时，内容列表应保持正常滚动（不应被 Sheet 错误接管）。
  3. 当 Sheet 已在底部时，无论用户在把手还是内容区上滑，都应等同于上拉把手；且内容区不应发生列表滚动，只允许驱动 Sheet 上拉。

- 自动吸附行为一致性：
  - 把手下拉释放 与 内容区顶部下拉释放，必须同源、同表现（不可一条顺滑一条冲顶）。
  - 把手上拉释放 与 内容区上拉释放，也应在同类策略下收敛（避免路径分叉造成不同观感）。

- 自动吸附稳定性（严禁回归）：
  - 禁止“先弹到顶部再下落”。
  - 禁止“先弹到中段再下落”。
  - 禁止“先掉到底部/屏外再突然冒到顶部”。
  - 禁止中段明显卡顿/台阶跳变（例如 0→10、10→30 的分段突变观感）。
  - 禁止“半空先压缩到最矮再快速落下”。

- 上拉触发阈值（避免误触）：
  - 轻微位移或接近点击的小偏移，不应触发自动上弹。
  - 自动上弹需满足明确阈值（位移或速度），避免“过于灵敏”。

- 生命周期与状态一致性：
  - 动画过程中的当前位置读取必须与视觉位置一致（避免读取旧模型值导致中段跳变）。
  - 状态收尾必须由同一驱动源完成（避免双阶段/双驱动竞争引发卡顿）。

- 性能与实现约束：
  - 避免补丁式时间耦合（如 `asyncAfter` 等待动画结束）。
  - 优先事件/完成回调驱动状态收敛。
  - 单次迭代仅保留“可验证有效”的改动，低收益高复杂度改动应回退。

### 2) 增强体验（在基础体验稳定后追加）

目标：在不破坏基础体验的前提下，补齐并打磨 Sheet 的“边缘缩放质感”。

- 视觉要素范围：
  - Sheet 两侧边距（左右缩放）
  - Sheet 底部与屏幕边缘的间距（底边抬升）
  - 与上述变化配套的圆角过渡（尤其底部圆角显露节奏）

- 变化节奏要求：
  - 变化应连续、顺滑、接近像素级线性，不应集中在尾段突变。
  - 不允许出现左右不同步（尤其中段“右边先突然变大”这类差异）。
  - 不允许出现明显分段感（前半段几乎不变，后半段突然跳变）。

- 交互一致性要求：
  - 手动跟手下拉时的边距变化节奏，应与自动吸附下拉尽量一致（不能一个丝滑一个生硬）。
  - 上拉与下拉两个方向都要保持一致的质量标准（不是只优化下拉）。

- 验收口径：
  - 与 Tripsy/Flighty 目标观感对齐：细腻、连贯、无顿挫、无突跳。
  - 若“左右一致性”和“流畅度”冲突，先保一致性，再做流畅度微调。

## 12. 关联记录

- 高层进度摘要：`/Users/murphy/Documents/Projects/Carry/docs/progress.md`
- 本文档用途：让任意新对话先读本文件再动手改动此模块。

## 13. 变更-反馈对照日志（代码级）

> 说明：以下为本轮会话的关键改动与用户反馈的逐条对照，按时间顺序记录。

1. 改动：
   - 删除独立 `collapseHandleDragDirectly(...)` 路径。
   - `handleSheetPan` 下拉松手直接调用 `commitSnap(to:collapsedOffset, source:"sheetPanDirectCollapse")`。
   用户反馈：
   - 复发“先弹到屏幕顶部再下落”。

2. 改动：
   - `commitSnap` 增加 `source` 参数。
   - `sheetPanDirectCollapse` 分支设置 `dampingRatio=1.0`、`initialVelocity=0`。
   用户反馈：
   - 顶部冲顶缓解，但仍“非常弹、先上再下”。

3. 改动：
   - `sheetPanDirectCollapse` 从 spring 改为 `UIViewPropertyAnimator(duration:0.32, curve:.easeOut)`。
   用户反馈：
   - 不再冲顶，但出现“先到中间再下落”。

4. 改动：
   - direct collapse 关闭 `shapeDisplayLink`，并在同一 animator 内同时推进 position + shape（单驱动尝试）。
   用户反馈：
   - “半空先压矮再下落”更明显。

5. 改动：
   - 撤回 shape 提前推进；direct collapse 下落阶段固定 `shapeProgressOverride: visualProgress`。
   用户反馈：
   - 方向变对，但仍不够丝滑。

6. 改动：
   - 临时把 direct collapse 曲线改成 `.linear`，并尝试 shape 全程同步（后证伪）。
   用户反馈：
   - 复发其它问题，要求回到已认可方案。
   处理：
   - 回退到 `easeIn + 0.34`，并保持下落阶段固定 `visualProgress`。

7. 改动（参数探索）：
   - `bottomRevealProgress.threshold` 依次尝试：
     - `0.97 -> 0.75`
     - `0.75 -> 0.55`
     - `0.55 -> 0.35`
   用户反馈：
   - 吸附过程中“边距/圆角仍集中尾段”，基本无效。

8. 改动（错误尝试，已归档反例）：
   - 在 `sheetPanDirectCollapse` 恢复 `startSnapShapeFollow(duration:0.34)`。
   用户反馈：
   - 复发“先弹到顶部再下落”。
   处理：
   - 回退并写入禁忌规则（本手册第 5 节）。

9. 改动（错误尝试，已移除）：
   - 引入 direct collapse 的额外 displayLink（mask/position）和异步收尾。
   用户反馈：
   - 中段卡顿、分段跳变（0->10、10->30 台阶感）。
   处理：
   - 回退该路线，停止继续引入多驱动。

10. 当前最新改动（有效性待继续验收）：
   - 几何层面：`geometry(for:)` 中
     - `lift = bottomLift(positionProgress)`（由 shapeProgress 改为 positionProgress）
     - `sideMargin = collapsedSideMargin * effectProgress(positionProgress)`（由 shapeProgress 改为 positionProgress）
   - 动画层面：direct collapse 的动画 block 里移除每帧 `applyCornerMask(...)`，降低卡顿风险。
   用户反馈（最近一条）：
   - 要求把每次改动与反馈写入文档（即本节），便于后续对话继承上下文。

11. 改动：
   - 新增上拉自动吸附触发阈值：
     - `expandSnapMinTranslation = 26`
     - `expandSnapMinVelocity = -260`
   - 应用到把手上拉释放与内容区上拉释放。
   用户反馈：
   - 目的是修复“上滑过于灵敏，轻微偏移就自动上弹”。

12. 改动：
   - 内容区在顶部下拉释放不再走 `finalizeGestureAndSnap(listPanDown)`。
   - 改为与把手下拉同源：`commitSnap(..., source:"sheetPanDirectCollapse")`。
   用户反馈：
   - 原因是两者表现不一致，且内容区路径会复发“先冲顶再下落”。

13. 改动：
   - 上拉展开路径（`sheetPanDirectExpand` / `listPanUp`）改为非弹簧直达动画，避免 spring 反向超调。
   用户反馈：
   - 目标是修复“先掉到底部甚至屏外，再突然冒到顶部”。

14. 改动：
   - 为提升丝滑度，直升/直降统一为 `duration: 0.42 + curve: .linear`。
   用户反馈：
   - 目标是从“1->3->5->7”改善到更接近像素级线性推进。

15. 改动（无效，已记录）：
   - 引入 `directMaskSyncDisplayLink` 仅做 direct 路径 mask 同步。
   用户反馈：
   - “没有生效”。
   结论：
   - 该方案未解决“左右边距不一致”，不能作为根解。

16. 改动（当前最新）：
   - direct collapse / direct expand 改为 `directPositionDisplayLink` 单驱动逐帧位置推进。
   - 每帧同入口调用：
     - `placeSheet(at: raw, shapeProgressOverride: fixedProgress)`
     - `applyCornerMask(...)`
   - 终点统一在 `t>=1` 收尾，移除这两条路径对 `UIViewPropertyAnimator` 的依赖。
   用户反馈：
   - 请求提交并同步文档记录（当前步骤）。

17. 改动：
   - `currentVisualOffset()` 改为“只要有 `presentation` 就优先读取”，不再依赖 `runningAnimator != nil` 前置条件。
   - 目的：direct displayLink 路径也能拿到真实视觉位置，避免读到旧 model 值引发中段跳变。
   用户反馈：
   - 现象为“上下拉中段明显卡顿一下再到位”。

18. 改动：
   - `handleDirectPositionTick(...)` 每帧同步：
     - `snappedOffset = raw`
     - `liveDelta = 0`
   - 目的：避免中途状态读取落后导致的二次收敛/卡顿。
   用户反馈：
   - 要求“修卡顿且不能引回左右边距不一致（尤其右侧中段先偏大）”。

19. 改动（A/B 审计准备）：
   - 新增两个开关用于评估 `ff473c5` 的真实收益：
     - `useHighRefreshDisplayLink`
     - `useMaskPathDeltaCache`
   - 目的：在不动其它已验证有效改动的前提下，单独判断“高刷上限”和“mask 缓存阈值”是否带来可感知提升，决定后续保留或回退。

20. A/B 结论（执行后）：
   - 用户反馈：A 档（开）与 B 档（关）“几乎没有差异”。
   - 决策：按“最小必要有效改动集合”原则，回退 A/B 开关实现，避免引入额外维护复杂度。
   - 当前结论：流畅度瓶颈不在 `ff473c5` 这两项（高刷上限/阈值缓存）本身，后续优化应转向 direct 路径的布局/状态同步稳定性。

21. 改动（2026-06-03，FX/ultimate 缩放，待真机验收）：
   - 文件：`CarryBottomSheetFX.swift`（ultimate 变体；Dev Options「Enable Scaling Effects」开启时才跑）。
   - 用户确认症状：**底部末段突变**——两侧边距连续跟手拉开，但底部圆角/收缩在快到底时才突然冒出来。
   - 根因（结构性，非参数）：`applyCornerMask` 的 `visibleH = fullH + ep*(rawVisible - fullH)`，`ep = bottomRevealProgress(progress)`。只要 `ep < 1`，圆角底边就被画在可见裁剪线**之下**（被裁掉）→ 底部恒为直角；只有 `ep→1`（进度逼近 1）圆角才可见。这解释了为何历史上把 threshold 从 0.97 降到 0.35（日志第 7 条）"基本无效"——降 threshold 改的是起点，改变不了"必须 ep≈1 才可见"的本质。
   - 修复：`visibleH = max(0, min(fullH, rawVisible))`，底部圆角始终贴可见裁剪线，随下拉连续上抬，与两侧同步。删除 `bottomRevealProgress` 函数。
   - 关键安全性：两端点不变 —— 展开 `p=0` 时 `rawVisible == fullH`、收起 `p=1` 时 `rawVisible ==` 收起可见高度，与旧公式算出的 `visibleH` 一致；只改中间拖拽态。因此**不触碰脆弱的自动吸附收尾路径**（`commitSnap` / `handleDirectPositionTick` 结构未动），吸附中 mask 仍按既有时机重建，未引入"先压矮再下落"风险来源。
   - 配套：缩放幅度 `collapsedSideMargin` / `collapsedBottomMargin` 由 `8 → 14`（用户口径"明显但克制"，对标 Tripsy/Flighty；这是纯调参旋钮，真机再微调）。
   - 顺手清理：删除死代码 `disableGestureAutoSnap`（声明 `= true` 但全代码无人读取，是"做一半"残留）。
   - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
   - 真机验收清单：① 慢速跟手下拉，底部圆角/边距是否与两侧**同步**连续上抬（不再末段突变）；② 快速下拉松手自动吸附，底部是否仍**无**"先压矮再下落"（本次未碰吸附路径，预期不回归，但需确认）；③ 上拉展开方向底部圆角是否同样连续；④ 14pt 幅度是否"明显但克制"。

22. 改动（2026-06-03，紧接第 21 条，待真机验收）：
   - 用户反馈第 21 条结果：「缩放幅度太过了 + 不够流畅」。
   - 幅度：`collapsedSideMargin` / `collapsedBottomMargin` 由 `14 → 10`。
   - 流畅度根因：`geometry()` 把 `sideMargin / width / clippingHeight` 做了 `pixelAligned` 像素对齐。这些缩放量在整段 ~580pt 行程里只变 ~10pt，变化极慢；像素对齐后每 ~15–20pt 手指位移才跳一个像素 → 慢拖时两侧/底部边距**阶梯式跳变**。且幅度越小阶梯越粗，故"降幅度"会加重卡顿，必须同时连续化。
   - 修复：缩放量去掉 `pixelAligned`，连续变化（`sideMargin` / `width` / `clippingHeight`）。`y`（垂直位置）与基准 `height` 仍保留像素对齐，避免内容文字抖动/锯齿。
   - 配套：`applyCornerMask` mask 路径缓存阈值 `0.25/0.5 → 0.1/0.2`，让圆角跟上连续值，不再跳过亚像素更新。
   - ⚠️ 已知取舍（需真机确认）：`width` 连续后，`hostingView.frame` 宽度逐帧变化 → SwiftUI 内容逐帧 relayout（原像素对齐会让连续多帧宽度相同从而跳过 relayout）。可见列表很短，现代设备预期可承受；**若真机反而出现 CPU 掉帧**，则改用「两侧用 GPU transform 缩放、不 resize 内容 frame」的方案（更大改动，届时单独评估）。
   - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
   - 真机验收：① 慢拖两侧/底部是否连续无阶梯；② 10pt 幅度是否合适（仍是 `collapsedSideMargin`/`collapsedBottomMargin` 两个旋钮）；③ 是否有新的逐帧 relayout 掉帧（重点看列表较长时下拉）。

23. 改动（2026-06-03，FX 滚动锁与 fallback 对齐 + 底部圆角，待真机验收）：
   - 用户反馈：①「内容区上滑锁需参考 CarryBottomSheet.swift（fallback）」②「底部圆角初始值太小，缩放前段裁剪不完整」。
   - 背景：playbook §16.1（`contentOffsetObservation` KVO 钳制）与 §17（中间位置不释放锁、snap 到极点）两个修复，当时只补进了 fallback `CarryBottomSheet.swift`，**漏同步到 FX**。本轮把三处移植进 `CarryBottomSheetFX.swift`：
     - `attachScrollView` 增加 `contentOffsetObservation = sv.observe(\.contentOffset)`，锁定期间 offset 漂移 >0.5 即拉回，不依赖 delegate。
     - `handleListPan .ended` 的 `drag==0` guard：`snappedOffset>0 && !isCollapsedState` 时 snap 到最近极点（`listPanInterruptedSettle`），不再无条件释放锁。
     - 中间 settle 分支：由 `settleAtCurrentPositionWithoutSnap()` 改为 snap 到最近极点（`listPanMidwaySettle`）。
   - 底部圆角：几何分析确认「初始值太小」与「前段裁剪不完整」同根因——底边最多只抬 10pt，大圆角贴屏底露不全。用户选「只加大圆角数值，不动底边抬升」。实现：
     - 新增 `expandedBottomRadius = 44`，让底部圆角**起点与顶部解耦**（顶部仍 36 不变），`bottomRadius(p)` 改用它作基。
     - `collapsedBottomRadius` `48 → 52`。
     - 顶部圆角、`topRadius` 完全未动。
   - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
   - 真机验收：① 上拉内容区（收起态/中断收起）滚动锁是否稳（§16 概率性漏滚是否改善）；② 下拉中途上拉、是否还会卡中间+可滚（§17 回归）；③ 底部圆角初始是否够圆、前段是否还"裁剪不完整"——`expandedBottomRadius`/`collapsedBottomRadius` 是旋钮；④ 若用户后续仍觉裁剪不完整，则真因是底边抬升不足（需调 `collapsedBottomMargin`，本轮按用户要求未动）。

24. 改动（2026-06-03，修「切换开关后 FX 滚动锁整体失效」，待真机验收）：
   - 现象：在 Dev Options 切换 Enable Scaling Effects 开关后，内容区滚动锁完全消失——上滑内容区本应驱动 sheet，结果变回普通内容滚动（handleListPan 整个没生效）。冷启动不复现，仅"切换后"复现。
   - 根因：FX 只在 `installContent` 用一次性 `asyncAfter(0.15s)` 调 `attachScrollView`，且 `findScrollView` 失败时 `guard else return` **无重试**。切换开关时 HomeView `switch` 销毁旧 sheet、新建 `FXSheetViewController`，整页重渲染，SwiftUI 的 List 在 0.15s 内常还没生成 UIScrollView → attach 静默失败 → `handleListPan` target 未加、`delegateProxy` 未建 → 锁永远装不上。
   - 排除自身改动：第 21–23 轮的 `.ended`/KVO 改动均在 attach 成功之后才生效，attach 没跑成则全不生效，故非那些改动引入；属 FX attach 时序固有脆弱（§16 已提）。
   - 修复：`viewDidLayoutSubviews` 增加兜底——**仅当 `listScrollView == nil`（从未成功 attach）** 时调用 `attachScrollView(in: hostingView)`。scroll view 一布局出来即接上；attach 自带 `sv !== listScrollView` 幂等 guard，不会重复加 target。
   - 刻意收窄条件：只在"从未 attach"时触发，**不**在 `sv !== listScrollView`（mid-session 重建）时重连——后者是 §16 试过并回退的更宽自愈，避免重蹈复杂度。
   - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
   - 真机验收：切换开关 → 立刻上滑/下拉内容区，锁是否恢复（驱动 sheet 而非滚内容）；反复来回切换多次仍需稳。

25. 改动（2026-06-03，撤回反向操作 + 底部圆角=屏幕圆角，待真机验收）：
   - 用户反馈：①「不流畅，怀疑技术方案不科学、每帧运算太多导致卡帧」②「底部圆角初始值仍太小，下拉前半段圆角被屏幕挡住；预期初始圆角=屏幕圆角」。
   - 卡帧根因（确认用户直觉正确）：FX 每帧 `placeSheet` 改 `hostingView.frame` 宽度 → 宽度变 → SwiftUI 每帧 relayout 整个 sheet 内容（行程列表）。这是主因。**且第 22 轮我去掉缩放量的 `pixelAligned`（误判卡顿为"阶梯感"）反而把宽度变成逐帧不同 → relayout 从"每~19pt 一次"恶化为"每帧一次"**；同轮把 mask 缓存阈值从 0.25/0.5 调到 0.1/0.2 也增加了每帧 path 重建。
   - 本轮（低风险撤回，先止血）：
     - 恢复 `sideMargin/width/clippingHeight` 的 `pixelAligned`（宽度跨帧稳定 → `hostingView.frame` 多帧相同 → 跳过 relayout）。代价：边距 ~0.33pt 亚像素阶梯，远比每帧 relayout 卡顿轻。
     - mask 缓存阈值还原 `0.1/0.2 → 0.25/0.5`。
   - 底部圆角（用户要"初始=屏幕圆角"）：`expandedBottomRadius 44 → 55`（≈现代 iPhone 屏幕圆角，使展开时底部与屏幕圆角嵌套，不再被遮）；`collapsedBottomRadius 52 → 36`（收起成对称卡片）。注：无公开 API 读设备圆角（私有 API 禁用），55 为常量、可调。
   - ⚠️ 根因未除：上述只是"减少每帧重复运算"的止血。**彻底丝滑的正解是停止每帧 resize 内容、改用 GPU transform（CALayer scale）做缩放——内容固定尺寸、永不 relayout、mask 一次成形随 transform 缩放**。属架构级改写，触碰 placeSheet/applyCornerMask（被多处 snap 路径调用，§5 雷区），需真机迭代，未在本轮盲改。待用户验证止血效果后决定是否上重写。
   - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
   - 真机验收：① 慢/快拖是否明显变顺（撤回是否止血）；② 底部圆角展开时是否与屏幕圆角齐平、前半段不再被挡；③ 若仍卡 → 需上 transform 重写（架构级）。

26. 改动（2026-06-03，根因解决卡帧 = 内容布局与缩放彻底解耦，待真机验收）：
   - 用户硬性要求：不接受任何止血/补丁/过渡方案，只要根因科学解（已写入 CLAUDE.md「重要约定」+ 用户记忆）。
   - 卡帧根因（确认）：FX 旧实现每帧把 `hostingView.frame` 的**宽度**设成"被收窄后的 outerView 宽度"→ 宽度逐帧变 → SwiftUI **每帧重新布局整个行程列表**（多毫秒级）。这是"不流畅"的真因，不是圆角/像素对齐之类的表层。
   - 根因方案（性能不变量）：**SwiftUI 内容只在完整展开尺寸下布局一次，拖拽/吸附全程永不 resize。**
     - `placeSheet`：`hostingView.frame` 固定为 `(x: 居中偏移, y: 0, width: 满宽, height: expandedHeight)`——宽高恒定，每帧只改 origin.x 居中。改 origin 是 GPU 廉价的 position 变更，**不触发 layoutSubviews → SwiftUI 不 relayout**。
     - 宽度收窄不再靠"把内容布局成更窄"，而是内容保持满宽、由 innerView 的 mask **裁切**实现（裁掉的是 ≤10pt 的内容内边距区，列表 padding 足以吸收）。
     - geometry 去掉 `pixelAligned`（连续值）——relayout 已解耦，连续不再有代价，反而消除了像素对齐在缓慢变化的边距上造成的阶梯感。删除 `pixelAligned` 函数（无引用）。
   - 每帧剩余开销：仅图层几何（frame/clip/mask path）——无任何 SwiftUI 布局。mask path 为 4 段弧的廉价 CG 构建，非瓶颈。
   - 视觉差异（需真机确认）：收起态内容现按满宽渲染再裁 ≤10pt（旧实现是 reflow 成窄宽）；若有贴右边元素被裁，再议（预期 padding 吸收）。
   - 圆角沿用第 25 轮：`expandedBottomRadius=55`（≈屏幕圆角，展开时底部与屏幕嵌套）→ 收起 `36`；顶部恒 36。
   - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
   - 真机验收：① 拖拽是否达到 Flighty/Tripsy 级顺滑（这是根因解，预期质变）；② 底部圆角展开与屏幕齐平；③ 收起态内容右/左缘有无异常裁切。若仍有残余掉帧——唯一剩余每帧成本是 mask path 重栅格化，届时再上"顶部 layer.cornerRadius + 底部独立处理"的纯 GPU 圆角方案（需放弃 mask）。

27. 改动（2026-06-03，根因修「偶现内容区自由滚动」= 锁改为状态驱动，待真机验收）：
   - 用户反馈：FX 偶现内容区在不该滚时仍能上下滚动；要求核对 FX 锁逻辑是否与 fallback 一致。
   - 审计结论：FX 的锁逻辑（`.began`/`.changed`/`.ended`/`attachScrollView`/`installProxy`/`FXDecelerationCanceller`/手势 delegate）已与 fallback `CarryBottomSheet` 逐行等价，**不是漏抄**。
   - 根因（两套共有的设计弱点，非 FX/fallback 差异）：锁是否生效绑在**易失的每手势标志**上——`activePanDriver == .list` + `.began` 里设的 `lockedOffsetY`。时序窗（§16）：① delegate 被 SwiftUI 顶替一帧；② `activePanDriver` 在 `.cancelled/.failed` 未复位 → 锁没设上 → 整段手势内容自由滚动 = 偶现。
   - 根因解（仅改 FX）：把 delegate-无关的 `contentOffsetObservation` KVO 钳制改为 **状态驱动**——直接由 `snappedOffset + liveDelta > 0.5`（Sheet 非完全展开）判定该不该钉顶，**不依赖 lockedOffsetY 标志，也不依赖 activePanDriver**。KVO 在 offset 任何变化时触发，确定性消除时序窗。完全展开（≈0）才放开滚动（规则 2）。
   - 为何 FX 安全而未同步改 fallback：FX 收起/展开走 `directPositionDisplayLink`，`snappedOffset` 每帧跟随真实位置，状态判定全程准确；fallback 用 spring animator，动画期 `snappedOffset` 仅在首/尾更新，盲套同款状态判定有动画中途误判风险。故 fallback **暂未动**（其同款潜在时序窗仍在，但用户未踩到）；如需两套严格一致，需对 fallback 单独按其 snap 模型适配，不可照抄。
   - 保留：原 `lockedOffsetY` + `FXDecelerationCanceller` delegate 钳制 + `cancelNext`（负责动量取消），作为次级层与状态驱动 KVO 同向（都钉 topInset），不冲突。
   - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
   - 真机验收：反复在收起态/中断收起态上下滑内容区（高频试），是否还能偶现自由滚动（预期根除）；展开态内容区上下滚动是否仍正常自由（规则 2 不被误锁）。

28. 改动（2026-06-03，根因消除最后一项每帧重活 = 去 CAShapeLayer mask，待真机验收）：
   - 用户要求：继续从代码/实现层找流畅度优化空间，要科学解、无论多复杂。
   - 逐帧开销审计：relayout 解耦后（§26），拖拽每帧仍有一项真重活——`applyCornerMask` 每帧用 `UIBezierPath` 重建 4 段弧并赋给 `CAShapeLayer.path`（innerView 的 `.mask`）。CAShapeLayer 作 mask 时 path 一变，渲染服务器要把**整张图层等大的 alpha 位图重栅格化**（展开态 ~1180×2100@3x），是 relayout 之后的头号每帧成本。根因是"上下圆角不同（顶 36/底 55→36）只能用 path mask"。
   - 根因解（Apple 自家圆角 sheet 的做法）：用**两层嵌套的单半径 `cornerRadius` 图层**替代 path mask——
     - `outerView`：圆底部两角（`maskedCorners` 下两角）+ 其 `bounds.height` 承担底部裁切（取代 mask 的 visibleH 与旧 clippingView）；
     - `innerView`：圆顶部两角；
     - 内容被两层依次裁切 → 四角独立半径，全程 **零 path、零 mask 栅格化**，`cornerRadius` 为 GPU 原生。
   - 连带架构收益：
     - 删除 `clippingView`、`innerMaskLayer`、`lastMask*` 缓存、整个 `applyCornerMask` 的路径构建（→ 仅两行 cornerRadius 赋值）。
     - 卡片高度 `visibleHeight = expandedHeight - lift - banded` 是**位置的纯函数**，与位置永远锁死 → 结构性根除"先压矮再下落"（§4/§5 反复出现的吸附伪影的根）。
     - 删除死代码 `directMaskSync*`（§15 已证伪、定义后从未调用的 displayLink + 两个状态变量 + 5 处无操作调用点）。
     - 去掉每帧无意义的 `innerView.transform = .identity`。
   - 现每帧只剩：geometry 数学 + 3 个 frame 赋值（host 仅改 origin，size 恒定→无 SwiftUI 布局）+ 2 个 cornerRadius 标量。等价于 Apple 原生圆角 sheet 的逐帧成本。
   - 视图层级新：`outerView(底角+裁高) → innerView(顶角) → hostingView(固定满尺寸，仅居中平移)`。
   - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
   - 真机验收：① 拖拽/吸附是否已达 Flighty/Tripsy 级丝滑（无掉帧）；② 圆角观感：展开顶 36/底 55(嵌屏)、收起四角 36；连续过渡无突跳；③ 底部"离港"间隙与圆角是否仍正确；④ 收起态内容裁切是否正常（host 满宽裁 ≤10pt）。

29. 改动（2026-06-03，内容收窄改等比缩放 = 内边距保持固定，待真机验收）：
    - 用户对照 Flighty/Tripsy：下拉时它们「Sheet 内内容整体 + 内边距保持固定」；而我们的内容在卡片收窄时内边距越来越小直到贴边。
    - 根因：§26/§28 为不 relayout，让 host 固定满宽、靠裁切收窄 → 内容满宽不动、卡片边内收，内边距被**绝对**裁掉 M(~10pt)→ 趋零贴边。
    - 科学解（Flighty 的做法）：侧边收窄改为对整张卡片施加**等比 scale transform**，`s=(w-2M)/w`。host 仍固定满尺寸不 resize（不 relayout），收窄是 GPU transform；内容/内边距/圆角等比一起缩 → 内边距占卡宽比例恒定 = "保持固定"。垂直收起仍由 bounds.height 裁切。
    - 实现要点：`outerView` 用 `bounds`+`transform`+`center`（UIView API，无隐式动画）；默认 anchor，center 取 `(w/2, topY+visibleHeight/2)`、bounds 高 `visibleHeight/s`，使缩放后视觉 frame 恰为 `(M, topY, w-2M, visibleHeight)` → `presentation().frame.origin.y==topY` 不变，吸附读位置不受影响。host 满宽 `(0,0,w,expandedHeight)` 填满卡片（无需居中偏移），随父层缩放。圆角按 `radius/scale` 反算保证视觉准确（新增 `currentScale`）。
    - 取舍（需真机确认）：等比缩放下，内容在最收起态会整体缩 ~5%（s≈0.95）——这是 Flighty 式"卡片轻微 zoom"，内边距比例恒定。若要内容**零缩放**且内边距恒定，只能 reflow(=relayout=卡)，已否决。幅度由 `collapsedSideMargin` 调（越小缩得越少）。
    - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
    - 真机验收：① 下拉时内容与卡片边的内边距是否保持恒定（不再贴边）；② 仍丝滑（host 未 resize）；③ 收起态内容 ~5% 缩放是否可接受，否则调小 `collapsedSideMargin`；④ 圆角/底部间隙是否仍正确。

30. 改动（2026-06-03，根因修真机掉帧 = 运动期栅格化内容，待真机验收）：
    - 真机 iPhone 17 Pro 仍明显掉帧。A/B 决定性定位：关开关跑 fallback（内容相同、无缩放 transform，纯平移）**丝滑**；开开关跑 FX（每帧 scale transform）**卡**。
    - 根因（确认）：§27 把侧边收窄改成每帧变化的 scale transform。`.blur`（`CarrySubtleBackground` 背景 blur 18~24）与卡片 ~10 处 `.shadow` 是**缩放相关滤镜**，父层 transform 每帧变 → CoreAnimation 每帧在 GPU 重渲染这些 blur/阴影。fallback 只平移固定渲染所以不卡 = 等于把 relayout 换成了 transform 滤镜重渲染。
    - 科学解：运动期把内容层 `hostingView.layer.shouldRasterize = true`，blur/阴影只渲染一次成位图，每帧缩放只合成缓存纹理（GPU 廉价）——性质回到 fallback 的"移动固定渲染"，只多了缩放。`rasterizationScale = 屏幕 scale`，且只向下缩放，位图清晰。
    - 严格门控（关键，否则列表滚动被冻在缓存位图）：仅在**真正驱动 Sheet 移动**时开——`applyLiveDelta(delta != 0)`（含把手拖动、规则 1/3）+ `commitSnap` 吸附期；`applyLiveDelta(0)`（规则 2 列表滚动 / no-op）、两个吸附完成回调、`settleAtCurrentPositionWithoutSnap` 一律关。新增 `setContentRasterized(_:)`（幂等，避免连续帧重复触发重栅格化）。
    - 已知小代价：拖动第一帧要栅格化一次满屏 host 位图（~一帧），手指刚落下时几乎无感；若真机仍见起手一顿，可预栅格化。
    - 测试机记录：iPhone 17 Pro，屏幕圆角 `expandedBottomRadius=62`（§ 上条）。
    - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
    - 真机验收：① 下拉收起 / 上拉展开是否已达 fallback 级丝滑（预期质变）；② 展开态列表正常上下滚动是否正常、不被冻结(验证门控正确)；③ 起手第一帧有无可感顿挫。

31. 改动（2026-06-03，根因修自动吸附掉帧 = 改用 Core Animation，待真机验收）：
    - 用户决定性反驳：把 17 Pro 锁 60Hz，Tripsy 依旧丝滑、我们仍卡 → **掉帧根因不是帧率**（120fps 的 §30 是治标），是吸附**动画方法**错了。手动跟手顺（输入驱动），自动吸附卡。
    - 根因（确认）：自动吸附是手写 `CADisplayLink` 逐帧动画（`startDirectPositionSync`/`handleDirectPositionTick`），主线程每帧算位置 + 限步（≤18pt/帧）。这种手搓动画在任何刷新率都易抖（时序/限步/追不上理想值）。Tripsy 用 Core Animation：动画交渲染服务器 GPU 插值，与刷新率自适应、天然丝滑。
    - 为何现在能换（当初不能）：当初用 displayLink 是因为老的 CAShapeLayer mask path 没法被动画器干净插值（§4-5 多通道竞争）。§28 起 mask 已删，位置/缩放/圆角全由可动画的 `transform`/`bounds`/`center`/`cornerRadius` 驱动 + 内容已栅格化 → 单个 `UIViewPropertyAnimator` 一条曲线即可全部插值。
    - 修复：direct 吸附分支（`sheetPanDirectCollapse`/`Expand`/`listPanUp`）改为 `UIViewPropertyAnimator(duration: 0.4, dampingRatio: 1.0)`，在 addAnimations 里 `placeSheet(target)`+`applyCornerMask(target)`。临界阻尼=无 overshoot（满足直接吸附"不回弹"要求 §5/§13）。栅格化的内容被动画 transform 合成缓存位图 → 任何刷新率丝滑。
    - 暂留（验证驱动，非偷懒）：`startDirectPositionSync`/`handleDirectPositionTick` + `directPosition*` 状态暂未删（现已无人调用），作为"新方案真机验顺前"的可回退备份；spring 路径（少见 settle）仍用旧 `startSnapShapeFollow` displayLink 驱动 cornerRadius（位置已是 CA，cornerRadius 仅 6pt 变化、无关大局）。用户确认 CA 吸附丝滑后，整体删除这些 displayLink 残骸。
    - 时长 0.4 是旋钮（之前 displayLink 0.36/0.48）。
    - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
    - 真机验收：① 松手自动上拉/下拉是否已与 Tripsy 同级丝滑（含 60Hz 下）；② 有无 overshoot/回弹（应无）；③ 速度是否合适（调 duration）。验顺后删 displayLink 残骸。

32. 改动（2026-06-03，丝滑确认 + 收口）：
    - 用户确认 0.33 吸附在真机彻底丝滑、无回弹 → CA 动画根治成立。
    - 微调：`collapsedBottomRadius 60→54`（收起卡底角不那么鼓）；direct 吸附 `duration 0.33→0.36`（沉稳一点点）。
    - 彻底删除全部 `CADisplayLink` 残骸：① §30 起已无人调用的 `directPosition*`（startDirectPositionSync/handleDirectPositionTick/stopDirectPositionSync + 9 变量 + 4 调用点）；② spring 路径的 shape displayLink（startSnapShapeFollow/handleShapeDisplayLink/stopShapeDisplayLink/shapeDisplayLink/snapShapeStart/snapShapeTarget + 6 调用点），其 cornerRadius 已并入该路径的 `UIViewPropertyAnimator.addAnimations`。FX 现全程纯 Core Animation 驱动，文件内无任何 displayLink。
    - **默认变体切到 `.ultimate`（FX）**：`SheetFeatureFlag.activeSheetVariant` 返回值、HomeView `@AppStorage` 默认、HomeView switch 兜底、SettingsView 开关 get 兜底四处统一 `.fallback → .ultimate`。fallback 保留作 Dev Options A/B 备选。详见 §6 已更新。
    - 编译：iphonesimulator Debug `BUILD SUCCEEDED`。
    - 至此 §21–§32 这条「FX 缩放从做一半带 bug → 视觉到位 + 纯 CA 丝滑 → 设为默认」长链收口。

## 6. ⚠️ 有两个 Sheet 实现，确认改对文件（默认已于 2026-06-03 改为 FX）

排查 Sheet 问题前**必须**先确认改对文件，否则所有改动“看起来无效”：

- `HomeView` 通过 `SheetVariant`（`@AppStorage(sheetVariantDefaultsKey)`）在两个实现间切换：
  - `.ultimate`  → **`CarryBottomSheetFX.swift`**（`FXSheetViewController`）← **现默认值（2026-06-03 起），新装/未手动切换的用户跑的就是它**
  - `.fallback` → `CarryBottomSheet.swift`（`SheetViewController`）← 无缩放矩形版，现仅作 Dev Options A/B 备选
- 编译期默认 `SheetVariant.ultimate.rawValue`（`SheetFeatureFlag.activeSheetVariant`、HomeView `@AppStorage` 与 switch 兜底、SettingsView 开关 get 四处一致）。
- 历史教训（2026-05-30，当时默认还是 fallback）：连续 4 次改 `CarryBottomSheetFX.swift` 全部“无效”，因为默认没实例化 FX。**如今默认反过来了**——若要改 fallback 版需确认开关已切到 fallback，否则改 `CarryBottomSheet.swift` 不生效。
- 排查铁律：动手前先确认当前 `sheetVariantRaw` 的值（或在关键方法打断点/改色验证哪个在跑），不要假设。

## 7. 已修复：快速上滑（expand 弹性 overshoot）底部露出 MapKit

- 现象：collapsed → 快速上滑把手迅速松手，sheet 顶部带弹性弹起（力度越大弹幅越大），sheet 底部边缘离开屏幕底，露出后面的 MapKit（可见高德 “Legal / 高德地图” 水印）。慢拖不触发。
- 根因：`SheetViewController`（fallback）用 `UIViewPropertyAnimator` spring 做 snap，expand 时 presentation 层 overshoot 飞过静止位。`containerView` 高度固定 = `expandedHeight`、背景 `.clear`、底部直角，一上移底部就空出来透到 ZStack 底层的地图。
- 修复（`placeSheet` + `viewDidLoad`）：`containerView` 向下延伸 `bottomExtension = 400`（静止时在屏幕外、底部本就是直角，正常不可见），并给 `containerView.backgroundColor` 设 `CarrySubtleBackground` 底部渐变色（dark `0.08/0.08/0.09`，light `0.98/0.98/0.97`）。`hostingView` 仍只占 `expandedHeight`，内容布局不受影响；overshoot 露出的是这段延伸背景而非地图。
- 同类隐患：`CarryBottomSheetFX.swift` 的 ultimate 版用 clippingView/outerView 多层结构，若将来启用 ultimate 需单独验证是否有同样的 overshoot 露底（当前未做）。

## 17. 已修复：下拉中途向上拉导致 Sheet 停在中间 + 内容区滚动锁失效（2026-06-01）

**现象**：把手下拉 Sheet 即将到底时，同时做向上拉动作，概率性阻断 Sheet 落底，停在中间位置，内容区可以滚动（违反 Rule 3）。

**根因链路**（单一、已确认）：
1. `handleSheetPan .ended` → `commitSnap(to: collapsedOffset)` 启动动画（~0.48s）
2. 动画进行中，用户手指触碰内容区 → `handleListPan .began` → `beginInteractiveControl()` 中断动画，Sheet 冻在中间（`snappedOffset` = 中间值 > 0）
3. 用户向上手势 → `isCollapsedState = false`，Rule 2 触发 → `liveDelta = 0`
4. `handleListPan .ended`：`drag = liveDelta = 0` → 命中 `guard drag != 0 else` → **无条件释放锁**（`lockedOffsetY = nil`）
5. Sheet 留在中间 + 锁释放 → 内容可滚

**修复**（commit `aeb37fb`，`handleListPan .ended` 两处）：
- `drag == 0` 的 guard 分支：加判断 `snappedOffset > 0 && !isCollapsedState`，若是中间位置则 `commitSnap` 到最近极点（`listPanInterruptedSettle`），不直接释放锁
- 原 `settleAtCurrentPositionWithoutSnap()` 分支：同样替换为 snap 到最近极点（`listPanMidwaySettle`），关闭第二条留在中间的路径
- 真机验证通过（用户确认）

---

## 16. 待解：上拉内容区「概率性滚动」（2026-06-01，非钩子失效）

**现象**：上拉内容区（尤其收起态，规则 3 应"上拉=驱动 Sheet 上移、内容不滚"）**概率性**出现内容滚动。概率性 = 时序竞争。

**已用诊断日志排除"钩子失效"**：临时在 `attachScrollView`（打印是否重连到新 sv）与 `handleListPan`（打印 `listScrollView == nil`）打点。在「规划中」分区从无到有切换时：
- 无 `previousWasNil=false`（scroll view 未被重建）
- 无 `listScrollView == nil`（钩子一直有效）

故曾假设"一次性 0.15s 钩子被 SwiftUI 重建后失效"并加 `viewDidLayoutSubviews` 自愈重连——**证伪并已回退（commit `a641c74`）**。

**当前最可能真因（代码层，未真机证实）**：
- 锁滚动依赖 `DecelerationCanceller` 代理 delegate 的 `scrollViewDidScroll` 把 `contentOffset` 拉回 `lockedOffsetY`。
- 但 SwiftUI 会自行设 `scrollView.delegate`，靠 `delegateObservation`(KVO `\.delegate`) 再装回代理——**KVO 重装有一帧窗**，窗口内生效的是 SwiftUI 的 delegate，`scrollViewDidScroll` 锁不执行 → 滚动漏过。
- 次因：`activePanDriver` 在 `.cancelled/.failed` 边界可能未复位，影响下一手势判定。

**下一步（真机 + 仪器化，模拟器手势测不准）**：
1. 真机找触发序列（什么情况概率升高）。
2. 在 `installProxy` / `delegateObservation` / `scrollViewDidScroll` 打点，确认滚动瞬间生效的 delegate 是否被 SwiftUI 顶替。
3. 候选方向：锁不再依赖 delegate 时序——例如 `.began` 同步 `sv.isScrollEnabled = false`、`.ended` 恢复（而非靠 `scrollViewDidScroll` 拉回）；需单一路径验证，勿多驱动并存（见第 5 节禁忌）。

**是否由「无日期行程」引入**：存疑——分区切换不触发重建，倾向既有/独立时序问题，需进一步确认。

### 16.1 候选修复（commit `112ac4c`，待真机验证）

在 `attachScrollView` 增加 `contentOffset` 的 KVO 观察：锁定期间（`delegateProxy.lockedOffsetY != nil`）只要 offset 漂移 > 0.5 就 `setContentOffset` 拉回。**与 delegate 无关**——KVO 在 offset 任何变化时都触发，绕开"代理 delegate 被 SwiftUI 顶替"的时序窗。保留原 `DecelerationCanceller` 代理（负责 forwarding + 减速取消），KVO 作为稳健的锁强制层。

自带 DEBUG 日志：`🩺[Sheet] contentOffset KVO clamp: 漏滚 y=… → 拉回 … · 此刻 delegate 是代理? false/true`。

真机验收：① 上拉内容区不再漏滚 = 修复有效；② 日志出现 `delegate 是代理? false` = 证实 delegate 被顶替假设。通过后删 🩺。若仍漏滚且 KVO 从不触发 → 是 `lockedOffsetY`/`activePanDriver` 未在该路径正确设置（状态分支），转查 `handleListPan` 的 `.began`。

## 18. 已修复：Release 构建崩溃（Swift 6.3.2 优化器无限递归，2026-06-13）

**现象**：`-O`（Release）构建时 `swift-frontend` 崩溃；DEBUG（`-Onone`）正常，故日常开发不报、易被忽略，直到打发布包才暴露。崩溃栈：
```
While running pass "EarlyPerfInliner" on SILFunction "...BottomSheetFXV11CoordinatorCfD"
  for 'deinit' (at CarryBottomSheetFX.swift)
isCallerAndCalleeLayoutConstraintsCompatible(...)  ← 同地址连续栈帧 = 无限递归 → 栈溢出
```

**根因**：编译器优化器 bug——内联 `CarryBottomSheetFX.Coordinator`（持 `UIHostingController<AnyView>?` + `Binding<Double>?`）的合成 `deinit` 时，布局约束兼容性检查无限递归。非本项目逻辑问题。

**修复**：给 `Coordinator` 加显式 `@_optimize(none) deinit {}`，把这单个函数排除出该内联 pass。deinit 非性能热点，零运行时代价。

> ⚠️ **不要删掉那个「看起来多余的空 deinit + @_optimize(none)」**——它在 DEBUG 下毫无作用、极像可清理的死代码，但一删 Release 就再次崩溃、无法发布。升级 Xcode/Swift 后可重新验证该 bug 是否已修，确认修复后才可移除。

## 19. 首页底栏「移进控制器·同 animator 同步缩放」终极方案（2026-06-14，已落地 commit `7a5a900`）

**做了什么**：把首页底栏（搜索 / 行程册 / 创建 FAB）从 HomeView 的 `.safeAreaInset(edge:.bottom)` **移进 `FXSheetViewController`**，与卡片由**同一个 `UIViewPropertyAnimator`** 驱动，实现像素级同步缩放。删除了基线近似版的 `SheetScaleModel`/`onScaleChanged`/`BottomBarScaleSync`/`import Combine`（基线还原点 `b2be676`）。

**机制（为什么对）**：底栏宿主钉在 `view` 底部（约束 = 原 18pt padding）、z 序在卡片之上、**不入 outerView**；缩放在唯一漏斗 `placeSheet` 里对 `barView` 施加**底边锚定**的同 `scale` transform（公式：`translate(0,(1-s)·h/2) · scale(s)`，等价 `.scaleEffect(anchor:.bottom)`）。因为吸附时 `placeSheet(at:target)` 在 snap 的 animator 块内被调用 → 底栏 transform 被同一 animator 插值 → 同曲线同初速度、无第二驱动源（守 §5）。拖拽时 `placeSheet` 逐帧调用、UIView transform 直接 set（无隐式动画）→ 跟手。

**手势穿透（头号风险，已守住）**：底栏宿主 clear 背景、空白区域 UIHostingController 返回 nil → pan 落到下方列表/卡片（从底栏上滑仍能滚列表 ✓）；按钮吃 tap；列表底部 124/176pt 占位行兜底。

**全盘审计结论（静态 + iPhone 17 Pro 模拟器实测，2026-06-14）**：未发现 bug/崩溃/死锁/循环引用；运行时日志零 Auto Layout 约束冲突、零 AttributeGraph 循环、零泄漏。展开/收起/新建/滚动/三按钮全通过。**核心正确性来自构造**：所有 Sheet 运动路径都经过 `placeSheet`，底栏与卡片由此天然同步、打断吸附时一起停在当前值。

> ⚠️ **唯一已知行为差异（取舍，非 bug）**：去掉了基线的"透明吸 tap 背景"，底栏三按钮之间两条约 14pt 空隙的**点击**会穿透到底栏后的列表行。原因：该背景一旦加回会让整条底栏可命中 → pan 也被吞 → 破坏"从底栏上滑滚列表"，二者在"底栏作 UIKit 兄弟视图"架构下互斥。按钮各有 54pt 命中区夹住、死区仅 ~14pt，危害可忽略，故保持现状。**若日后想消除穿透，唯一代价是放弃底栏区域的滑动穿透**——别试图两全，架构上做不到。
