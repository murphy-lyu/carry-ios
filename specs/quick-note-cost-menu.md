# Quick Note & Cost — ··· Menu Actions

**Date:** 2026-06-27  
**Status:** Implementing

## Problem

备注和费用是高频补录操作，但入口藏在「编辑」主流程里，动线过长（点详情 → 关详情 → 点编辑 → 滚到备注/费用行 → 输入 → 保存）。

## Solution

在所有事件详情 sheet 的 ··· 菜单里加入「添加备注」和「记录费用」两个快捷动作。触发后弹出专用的轻量 sheet（不进编辑主流程），完成后回到原详情 sheet，内容实时更新。

## Entry Point

`DetailActionFooter` 的 ··· 菜单新增两条，位于「移除」之上：

```
··· 菜单（从上到下，iOS 向上展开所以声明顺序 = 反序）：
  [移除 xxx]      ← destructive，最靠近锚点（底部）
  [记录费用]
  [添加备注]      ← 最远离锚点（顶部）
```

适用范围：TransportDetailView / LodgingDetailView / ItineraryView 里的 stop detail（三处都用 `DetailActionFooter`）。

## QuickNoteSheet

**触发：** ··· → 添加备注  
**形式：** `.sheet` presentedOver 现有 detail sheet（SwiftUI sheet 叠加，不 dismiss 原 sheet）  
**detent：** `.medium`，有内容时可拖到 `.large`  
**内容：**
- 顶部 grab indicator（系统默认）
- 标题行：`"备注"` + 右侧 `"完成"` 按钮（accent 色）
- TextEditor 全宽，`.onAppear` 自动 focus（`@FocusState` + `.focused()`，TextEditor 是原生 SwiftUI 组件，可正常使用 FocusState）
- 已有备注时预填；空时 placeholder overlay（TextEditor 无内置 placeholder）
- 底部留 keyboard avoidance（`.ignoresSafeArea(.keyboard, edges: .bottom)` 交给系统）

**保存逻辑：**
- 点「完成」或 sheet dismiss：将 TextEditor 内容写入对应 entity
  - Stop → `store.updateItineraryStop(tripId:stopId:note:)`
  - Segment → `store.updateTransportSegment(tripId:segmentId:note:)`
  - Stay → `store.updateLodgingStay(tripId:stayId:note:)`
- 空字符串 = 清除备注（允许）

**不做：**
- 不做 Cancel/确认弹窗（备注轻量，直接 dismiss 即保存，符合 iOS Notes 范式）
- 不做字数限制

## QuickCostSheet

**触发：** ··· → 记录费用  
**形式：** `.sheet`，不 dismiss 原 detail sheet  
**detent：** `.medium` 固定（numpad 高度下足够）  
**内容：**
- 顶部 grab indicator
- 标题行：`"费用"` + 右侧 `"完成"` 按钮
- 大金额显示区（居中，`font(.system(size: 48, weight: .semibold, design: .rounded))`）
  - 空时显示 `"0"` placeholder
  - 有值时显示 `"¥1,234.00"` 格式（复用 `CurrencyCatalog.format`）
- 货币选择胶囊（复用现有 `CurrencyPickerView`，点击 push）
- numpad 键盘（`.numberPad`，绑定 TextField hidden off-screen 触发键盘）

**保存逻辑：**
- 点「完成」或 dismiss：调对应 `setStopCost` / `setTransportCost` / `setLodgingCost`
- 空输入 = amount 0 + currencyCode ""（= 清除费用，`hasCost` = false）

**不做：**
- 不做计算器逻辑（+-×÷），只做数字录入，对标 Tripsy

## DetailActionFooter API 变更

```swift
// Before
struct DetailActionFooter: View {
    let onEdit: () -> Void
    let onDelete: () -> Void
}

// After
struct DetailActionFooter: View {
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onNote: (() -> Void)? = nil    // nil = 不显示此菜单项
    var onCost: (() -> Void)? = nil    // nil = 不显示此菜单项
}
```

CalendarEventDetailView 不支持备注/费用（只读系统日历事件），onNote/onCost 传 nil，菜单维持原状。

## i18n Keys (新增)

| Key | en | zh-Hans |
|---|---|---|
| `quickaction.note.title` | Note | 备注 |
| `quickaction.note.placeholder` | Add a note… | 添加备注… |
| `quickaction.note.done` | Done | 完成 |
| `quickaction.cost.title` | Cost | 费用 |
| `quickaction.cost.done` | Done | 完成 |
| `itinerary.menu.add_note` | Add Note | 添加备注 |
| `itinerary.menu.record_cost` | Record Cost | 记录费用 |

## File Plan

- **新建** `Carry/Views/QuickNoteSheet.swift` — 备注快速编辑 sheet
- **新建** `Carry/Views/QuickCostSheet.swift` — 费用快速录入 sheet
- **修改** `Carry/Views/ItineraryDetailRows.swift` — `DetailActionFooter` 加 onNote/onCost
- **修改** `Carry/Views/TransportDetailView.swift` — 传入 onNote/onCost，管理 sheet 状态
- **修改** `Carry/Views/LodgingDetailView.swift` — 同上
- **修改** `Carry/Views/ItineraryView.swift` — stop detail 同上
- **修改** `Carry/Localizable.xcstrings` — 新增 7 个 key × 9 语
