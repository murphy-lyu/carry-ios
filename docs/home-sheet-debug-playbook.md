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

## 6. ⚠️ 头号陷阱：有两个 Sheet 实现，默认跑的不是 FX

排查 Sheet 问题前**必须**先确认改对文件，否则所有改动“看起来无效”：

- `HomeView` 通过 `SheetVariant`（`@AppStorage(sheetVariantDefaultsKey)`）在两个实现间切换：
  - `.fallback` → **`CarryBottomSheet.swift`**（`SheetViewController`）← **默认值，真机/用户实际运行的就是它**
  - `.ultimate`  → `CarryBottomSheetFX.swift`（`FXSheetViewController`）← 仅 Dev Options 手动开启「Ultimate sheet」开关才启用
- 默认 `SheetVariant.fallback.rawValue`，所以**不开开关时改 `CarryBottomSheetFX.swift` 完全不会生效**。
- 真实教训（2026-05-30）：连续 4 次改 `CarryBottomSheetFX.swift` 修“快速上滑溢出露地图”，全部“无效”，因为默认根本没实例化 FX。最终靠“把填充块改成鲜红色仍完全看不到”才定位到改错了文件。
- 排查铁律：动手前先确认当前 `sheetVariantRaw` 的值（或直接在两个文件的关键方法打断点/改色验证哪个在跑），不要假设。

## 7. 已修复：快速上滑（expand 弹性 overshoot）底部露出 MapKit

- 现象：collapsed → 快速上滑把手迅速松手，sheet 顶部带弹性弹起（力度越大弹幅越大），sheet 底部边缘离开屏幕底，露出后面的 MapKit（可见高德 “Legal / 高德地图” 水印）。慢拖不触发。
- 根因：`SheetViewController`（fallback）用 `UIViewPropertyAnimator` spring 做 snap，expand 时 presentation 层 overshoot 飞过静止位。`containerView` 高度固定 = `expandedHeight`、背景 `.clear`、底部直角，一上移底部就空出来透到 ZStack 底层的地图。
- 修复（`placeSheet` + `viewDidLoad`）：`containerView` 向下延伸 `bottomExtension = 400`（静止时在屏幕外、底部本就是直角，正常不可见），并给 `containerView.backgroundColor` 设 `CarrySubtleBackground` 底部渐变色（dark `0.08/0.08/0.09`，light `0.98/0.98/0.97`）。`hostingView` 仍只占 `expandedHeight`，内容布局不受影响；overshoot 露出的是这段延伸背景而非地图。
- 同类隐患：`CarryBottomSheetFX.swift` 的 ultimate 版用 clippingView/outerView 多层结构，若将来启用 ultimate 需单独验证是否有同样的 overshoot 露底（当前未做）。

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
