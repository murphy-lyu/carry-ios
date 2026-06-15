# 首页 Sheet 自动吸附「克制果冻」回弹

> **Status: Shipped（真机验收通过 2026-06-15，全盘审计无 bug/崩溃/死锁/泄漏/回归）。** 参数：展开 dampingRatio 0.74/dur 0.52、收起 0.82/0.46。 关联：`Carry/Views/CarryBottomSheetFX.swift` 的 `commitSnap` 直接吸附分支。改前必读 `docs/home-sheet-debug-playbook.md`（§5 禁忌 / §7 expand overshoot / §32 用 CA 非 displayLink）。

## 目标
下拉松手自动收起到底、上拉松手自动展开到顶时，落位带一个**克制的 spring 过冲**（轻微果冻回弹），让"到位"有精神气；而不是当前的临界阻尼"硬停"。**克制**＝几乎察觉得到的一点点过冲，**不是**弹两下的明显果冻（对齐 north-star 克制/优雅、Apple 原生 sheet 手感）。

## 非目标 / 硬边界
- 不动几何、滚动锁、手势链、圆角逻辑、`placeSheet` 漏斗、栅格化。
- **不加第二驱动源**（§5）：回弹完全由现有那条 `UIViewPropertyAnimator` 的阻尼实现，不引 displayLink、不引并行 shape 跟随。
- 不动**非直接**吸附分支（velocity 路径，已是 0.95/0.88 spring）——本次只让"直接松手"路径从"无回弹"变"克制回弹"。

## 为什么现在做是安全的（破除"禁止回弹"的历史包袱）
playbook §4/§5 当年禁回弹，是为消除**多驱动竞争**导致的失控伪影（"先上弹/中段跳变"——位置与形态走不同时间线）。该根因已随单一 CA 通道 + 内容固定尺寸 + 删 mask 重构**消除**。如今吸附是**单一 animator** 在 transform 上插值、且只经唯一漏斗 `placeSheet`，`dampingRatio < 1` 产生的是被同一 animator 干净插值的**受控过冲**，与当年伪影本质不同。底栏搭同一 animator → 一起弹，免费同步。

## 机制（最小改动）
`commitSnap` 直接吸附分支当前：`UIViewPropertyAnimator(duration: 0.42, dampingRatio: 1.0)`。改为**方向不对称的欠阻尼 spring**：

| 方向 | dampingRatio | duration | 说明 |
|---|---|---|---|
| 展开到顶（`isCollapsing == false`）| ~0.74 | ~0.52s | 到位精神气，给多一点过冲 |
| 收起到底（`isCollapsing == true`）| ~0.82 | ~0.46s | 贴屏幕底缘，更收敛，避免边缘抖动观感 |

（以上为**起始候选值**，真机调手感为准。）`addCompletion` 收尾逻辑不变。

## ⚠️ 展开过冲漏 MapKit：真因与修复（2026-06-15，commit `b58b478`）

> 上线后用户报告"展开吸附回弹时底部仍漏出地图"。我**第一次判断错了方向**（以为是卡片底缘被抬起，去改 outerView 锚点钉底边）——逐帧推算证明**卡片底缘其实全程 ≥ 屏幕底（过冲只往屏幕外冲）、并未抬起**，那次改动修了不存在的问题、已完全回退。

**真因（渲染覆盖，不是几何位移）**：卡片三层 `outerView/innerView/hostingView` **本身全透明**，Sheet 底色仅由内容里的 `.background(CarrySubtleBackground())` 画；而内容**固定高 = expandedHeight、钉在 innerView 顶部**。展开吸附 spring 过冲会把 `innerView.bounds` 瞬间撑过 expandedHeight → 底部多出约 56pt 一条「无内容、又无背景」的**透明带** → 漏出后面的 MapKit；落定后 bounds 收回缝合。

**修复（根因·一行）**：给 `innerView` 自身一层不透明兜底背景 = `CarrySubtleBackground.baseColor`（渐变底端同色，专为消除底部接缝而设）。卡片从此不透明：正常态被内容完全盖住、不可见；过冲那条带露出的是与 Sheet 底端无缝同色而非地图。`ViewModifiers` 暴露 `baseUIColor` 作单一色源。**不碰几何/吸附/手势/内容尺寸**（内容固定尺寸的性能不变量保持）。

**教训**：固定高内容 + 透明卡片，遇到「可视窗口可瞬间撑过内容高度」的动画（过冲/橡皮筋）必漏底——卡片应有自己的不透明背景，而非依赖固定高内容兜全部不透明。

## 验收（真机）
1. **头号回归**：展开/收起过冲时**底缘不漏 MapKit、顶缘不露怪缝**。
2. 手感：过冲克制、只一下、不肉、不弹两下；展开比收起略多一点。
3. playbook §10 全回归：下拉中途上拉不卡中段、滚动锁稳、圆角跟手。
4. 底栏随卡片一起弹、同步无脱节（搭同一 animator）。
5. 暗色正常；快速连续甩动不叠加抖动（generation token 已护）。

## 数据 / 迁移
无。纯动画参数。
