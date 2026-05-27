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
