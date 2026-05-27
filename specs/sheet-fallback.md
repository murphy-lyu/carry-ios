# Sheet Fallback Implementation — Spec

## 背景

HomeView 底部 Sheet 的终极方案（含两侧/底部缩放视觉效果）尚有未解决的疑难杂症。
为确保产品按时上线，先实现一套无缩放视觉的保底方案，通过 feature flag 切换，
终极方案稳定后删掉保底方案及所有 A/B 相关代码。

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
    case fallback   // 保底方案（无缩放）
    case ultimate   // 终极方案（含缩放）
}

// 上线前改这一行
let activeSheetVariant: SheetVariant = .fallback
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

## 终态清洁路径

终极方案稳定后，删除步骤：

1. 删除 `CarryBottomSheetFallback.swift`
2. 删除 `SheetFeatureFlag.swift`
3. 将 HomeView 的 `switch activeSheetVariant` 还原为直接调用 `CarryBottomSheet`
4. 删除 `DeveloperModeView` 里的 Sheet Implementation section

**HomeView 的 Sheet 调用参数签名不需要改动。**

---

## 暂不处理

- 终极方案现有 bug 的修复（独立进行）
- Sheet 内容区域的任何 UI 改动
