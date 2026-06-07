# Sheet Fallback Implementation — Spec

> **Status: 已退役（2026-06-07）** — 终极方案（`CarryBottomSheetFX`）长期稳定后,无缩放保底方案
> 已删除:`CarryBottomSheet.swift` + `SheetFeatureFlag.swift` + Dev Options「Sheet Implementation」
> 开关 + 相关 xcstrings key 全部移除,HomeView 直接调用 FX。本 spec 仅作历史留档;**下文「行为要求」
> (手势跟手/三条联动规则/吸附策略/禁止行为)仍是 FX 的有效规范**。FX 调试全过程见
> `docs/home-sheet-debug-playbook.md` §21–§32。
>
> ⚠️ 术语/文件名提醒：本 spec 早期用 `CarryBottomSheetFallback.swift` 指保底方案，
> 但**实际实现**为：保底=`CarryBottomSheet.swift`（无缩放），终极=`CarryBottomSheetFX.swift`（缩放）。
> 下文已按实际文件名校正。

## 背景

HomeView 底部 Sheet 的终极方案（`CarryBottomSheetFX.swift`，含两侧/底部缩放视觉效果）早期尚有疑难杂症，
故先做一套无缩放保底方案（`CarryBottomSheet.swift`）通过 feature flag 切换、确保按时上线。
**2026-06-03：终极方案已稳定且丝滑，切换为默认；后续待其长期稳定后再删掉保底方案及 A/B 代码（现暂留）。**

---

## 行为要求

### 手势跟手

- 拖拽把手：上拉/下拉全程 1:1 跟手，不得提前回弹或延迟。
- 拖拽内容区：遵守下方三条联动规则。

### 三条联动规则（优先级：规则 3 > 规则 2 > 规则 1）

| 规则 | 条件 | 行为 |
|------|------|------|
| 1 | 内容区在顶部 + 下拉内容区 | 等同下拉把手，驱动 Sheet 下移 |
| 2 | 内容区在顶部 + 上滑内容区 | 正常列表滚动，不接管 Sheet |
| 3 | **Sheet 在底部位置** + 任意上滑（把手或内容区） | 驱动 Sheet 上移，**禁止列表滚动** |

规则 3 优先于规则 2：Sheet 处于底部时，位置状态高于内容滚动状态。

### 自动吸附策略

**触发条件（复合）：**
```
速度 > velocityThreshold
OR（位移 > displacementThreshold AND 速度不是反向）
```

建议初始值：
- `velocityThreshold`: 300 pt/s
- `displacementThreshold`: Sheet 可移动范围的 30%

**把手释放与内容区顶部释放必须走同一个 snap 决策函数**，不得出现行为分叉。

### 禁止行为（严禁回归）

- 先弹到顶部再下落
- 先弹到中段再下落
- 先掉到底部/屏外再冒回顶部
- 中段明显卡顿/台阶跳变（视觉不连续）
- 半空先压缩到最矮再快速落下
- 动画过程中读取旧模型值导致位置跳变

---

## 技术实现

### 与终极方案的关系

| 层 | 保底方案 | 终极方案 |
|----|---------|---------|
| 手势仲裁 | ✅ 完整实现 | ✅ 完整实现 |
| Snap 物理 | ✅ 完整实现 | ✅ 完整实现 |
| 视觉布局 | 无缩放，矩形 Sheet | 两侧 + 底部缩放 |

保底方案 = 终极方案的手势/snap 层 + 简化的 `applyLayout()`（无缩放计算）。

### 文件结构

```
CarryBottomSheet.swift          ← 终极方案（现有文件，不动）
CarryBottomSheetFallback.swift  ← 保底方案（新文件）
SheetFeatureFlag.swift          ← 唯一配置入口（新文件）
```

`CarryBottomSheetFallback` 对外暴露与 `CarryBottomSheet` 完全相同的 SwiftUI 接口：
```swift
struct CarryBottomSheetFallback<Content: View>: UIViewControllerRepresentable {
    let expandedHeight: CGFloat
    let collapsedOffset: CGFloat
    @Binding var mapCityOpacity: Double
    @Binding var collapseRequest: Bool
    let isListEmpty: Bool
    @ViewBuilder let content: () -> Content
}
```

### Feature Flag

```swift
// SheetFeatureFlag.swift
enum SheetVariant {
    case fallback   // 保底方案（无缩放，CarryBottomSheet.swift）— A/B 备选
    case ultimate   // 终极方案（含缩放，CarryBottomSheetFX.swift）— 现默认
}

// 编译期默认（2026-06-03 起为 .ultimate）；UserDefaults / Dev Options 开关可覆盖
var activeSheetVariant: SheetVariant { /* … UserDefaults override … */ .ultimate }
```

### HomeView 调用层

```swift
// HomeView.swift — 唯一改动处
Group {
    switch activeSheetVariant {
    case .fallback:
        CarryBottomSheetFallback(...) { sheetContent }
    case .ultimate:
        CarryBottomSheet(...) { sheetContent }
    }
}
```

### Developer Options 开关

在 `DeveloperModeView` 新增一个 Section：
```
Sheet Implementation
[ ] Use fallback (no scaling)  ←→  Use ultimate
```

读写 `UserDefaults`，覆盖 `activeSheetVariant` 的编译期默认值，App 无需重启生效（需要重新推入 HomeView 或重载）。

---

## 终态清洁路径（**暂不执行**，用户决定先保留 fallback 作 A/B）

待终极方案（FX）长期稳定、确认无需回退后，退役**保底方案**步骤：

1. 删除 `CarryBottomSheet.swift`（保底/无缩放版）
2. 删除 `SheetFeatureFlag.swift`
3. 将 HomeView 的 `switch` 还原为直接调用 `CarryBottomSheetFX`
4. 删除 `SettingsView`（Dev Options）里的 Sheet Implementation section

**HomeView 的 Sheet 调用参数签名不需要改动。**

---

## 暂不处理

- 退役 fallback（见上「终态清洁路径」，用户决定先留）
- Sheet 内容区域的任何 UI 改动

> 注：终极方案早期的疑难杂症（卡帧、漏地图、滚动锁、圆角等）已在 2026-06-03 全部根治，
> 详见 `docs/home-sheet-debug-playbook.md` §21–§32。
