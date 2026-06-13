# 单日重排：以「道路口径」判定是否改进（修订 MKDirections 用法）

> **Status: Implemented（方案 A 已落地、编译绿、纯函数验证通过；待真机验收 4 态）。** 关联：`specs/itinerary-route-planning.md`（本条修订其中「MKDirections 只用于展示」一句）、`Carry/Views/OptimizeRouteView.swift`、`Carry/Models/RouteOptimizer.swift`、`Carry/Models/RouteDistanceService.swift`。
>
> **呈现决策：采用方案 A（渐进披露）。** 进页立即显示地图 + 建议顺序；「节省数字 + 距离对比 + CTA」这块"判定区"在道路核对完成前显示「计算中」，道路返回后定调（有省→显示节省 + 「采用此顺序」；没省/更长→判定区收为"这条路线已是较优" + 中性「知道了」；超时/失败→退回直线 + 「按直线距离」注脚）。地图与建议顺序列表全程不跳变，只判定区一小块随结果变化。

## 问题（真机暴露）

优化页偶尔出现「**当前 83 公里 → 优化后 87 公里，节省 0 米**」——优化后按道路反而更长。

**根因 = 口径不一致**：
- 排序用**直线距离（Haversine）**搜最优顺序（`RouteOptimizer.optimize`，瞬时、离线可用）。
- 展示与「是否改进」的**屏判定**目前也用直线（`result.isImprovement`，同步算）。
- 但屏上**展示的数字**是**道路距离**（`RouteDistanceService.totalRoadDistance`，异步后到）。
- 直线更短的顺序，换成道路可能更长 → 「声称优化却没省/变长」。

## 决策

**让「是否算改进」的判定，用我们实际展示、用户实际在意的口径——道路距离（在可得时）。** 直线只继续负责**快速搜出候选顺序**。

不做**全程按道路挑最优**（需 N² 次 MKDirections、受限流、离线失效；Apple/Google 靠服务端道路矩阵，客户端实时不现实）。这是明确的 Non-Goal。

## 判定逻辑

记当前顺序道路距离 `roadOriginal`、候选顺序道路距离 `roadOptimized`（两者本就为展示而算）。

1. **道路数据两者皆可得**：用道路判定。改进阈值**沿用 `isImprovement` 同款**口径一致：
   `saved = roadOriginal − roadOptimized；saved > 50m 且 saved/roadOriginal > 1%` → **算改进**，否则 → **已较优**。
   - 抽成纯函数 `isImprovement(original:optimized:)`（供 `RouteOptimizer` 与本处共用 + 单测）。
2. **道路数据拿不到（离线/超时/失败）**：退回**直线**判定（`result.isImprovement`），改进态保留现有「**按直线距离**」注脚（诚实告知口径）。
3. 直线判定本身就「无改进」时（候选≈当前）：直接「已较优」，**跳过道路计算**（省请求，符合现状早退）。

效果：道路口径下没省/更长 → 走「已是较优路线」(`alreadyOptimal`)，**不再给用户一个更长的「优化」**;"节省 0/负" 永久消失。

## 呈现与状态（关键 UX，需你拍板）

现状：`body` 在 `.task` 里**同步**用直线 `isImprovement` 决定显示 `improvementContent` 还是 `alreadyOptimal`，道路距离**异步后到**仅替换数字。改为道路判定后，「显示哪屏」要**等道路算完**。

道路计算是**串行 MKDirections**（N 段 × 2 条顺序，7 点约 12 段，~2–5s）——不能让用户对着空白等。两种方案：

- **方案 A（推荐）·"建议先出、判定后定"**：进页**立即**显示候选顺序的**地图 + 建议顺序列表**（这些不依赖道路、本就有用）；只把**「节省」数字 + 主 CTA**区域置为「正在按道路核对…」(`itinerary.optimize.calculating`)。道路返回后：
  - 确认有省 → 显示道路 saved 数字 + 启用「采用此顺序」。
  - 没省/更长 → 该区域替换为一行「这条路线已经挺顺，无需调整」+ 把 CTA 换成中性「知道了」(走 discard)。**只换底部一小块,不整屏跳变**(避免突兀)。
  - 超时（>6s）/失败 → 退回直线判定 + 「按直线距离」注脚。
- 方案 B·"先 loading 再定屏"：进页先整屏 spinner「计算最优路线…」，算完再给改进/已较优。简单但每次都要等 2–5s 空白。

我倾向 **A**：信息**渐进披露**，地图/顺序先用，判定后定调，最坏情况也只是底部一小块从"计算中"变"已较优"，不整屏跳。

## 文案（落定后补全 9 语言）

- 复用：`itinerary.optimize.calculating`（计算中）、`itinerary.optimize.optimal.title/subtitle`（已较优）、`itinerary.optimize.straight_line`（按直线距离注脚）。
- 可能新增：方案 A 里"已挺顺、无需调整"的内联短句（若 `optimal.*` 不贴合内联场景再加；优先复用）。

## 实现要点

- `OptimizeRouteView`：引入呈现状态（`computing / improvement / alreadyGood`，由直线 result + 道路结果 + roadLoading + 超时派生）；道路判定取代同步直线判定；加 6s 超时退回。
- `RouteOptimizer`：抽出 `isImprovement(original:optimized:) -> Bool` 纯函数（现 `Result.isImprovement` 复用它），供道路判定共用。
- `RouteDistanceService`：不变（已串行防限流）；如需可加超时包装。
- 不动排序算法、不动 model、不动备份。

## 测试

- **纯函数验证（已做）**：`RouteOptimizer.isImprovement(original:optimized:)` 用独立 `swift` 跑 7 例全 PASS——`83km→87km` ⇒ false（真机 bug 那组，现判"已较优"）、`91km→80km` ⇒ true、相等 ⇒ false、省=50m 边界 ⇒ false、省 51m 但 <1% ⇒ false、省 200m 且 2% ⇒ true、original=0 ⇒ false。
  > 注：本仓库当前**无测试 target**（只有 Carry / CarryWidgetExtension），历史「单测」均为 ad-hoc 跑、未进仓库；此处沿用同法。若后续建测试 target，应把本例与 RouteOptimizer 既有算法例一并纳入。
- **模拟器（待真机验收）**：① 道路有省（正常优化，improved）；② 道路没省/更长（命中"已较优"，无"省 0/变长"，notImproved）；③ 飞行模式（退回直线 + 注脚，unavailable）；④ 多点（~10）观察 computing 时长与渐进披露观感（地图/顺序先出、判定区后定）。

## Non-Goals

- 不做全程道路矩阵最优（成本/限流/离线不现实）。
- 不改"固定首尾、只重排中间"策略。
- 不引入服务端。
