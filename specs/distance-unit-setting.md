# 距离单位设置（公里 / 英里）

**Status:** Implemented（模拟器验收通过，未提交；一级菜单分组/排序待后续统一调整）
**Date:** 2026-06-15

## 背景与问题

行程规划里地点详情的「路程模块」（到下一站直线距离）与时间轴段距，距离数字目前由 `MKDistanceFormatter` 按**设备 locale** 自动选公里/英里。美区设备已自动显示英里，但：

- 用户**无法手动切换**——例如设备设为美区但习惯公制、或反之，没有出口。
- 对全球用户而言，缺一个显性的单位偏好，本地化体验不够完整。

> 注：用户最初的描述「参考设置里的『货币』」与现状不符——设置一级菜单中**并无货币项**，货币仅出现在「目的地实用信息」卡片且自动跟随 locale、不可切换。本 spec 不引入货币相关改动。

## 目标

1. 设置中新增**「通用 / 单位」分组**，内含「距离单位」一行。
2. 距离单位三档：**自动 / 公里 / 英里**（对标「外观」的「跟随系统」范式）。
   - **自动**＝跟随设备地区（沿用 `MKDistanceFormatter` 默认 locale 行为）。
   - 默认值＝「自动」，因此设备地区默认体验零回归。
3. 偏好统一驱动**所有面向用户的距离显示**，不只用户提到的路程模块。

## 非目标

- 不引入货币 / 温度 / 其它单位偏好（未来可在「通用」分组扩展，本次只做距离）。
- 不改变排序/优化算法（仍用 Haversine 直线 + MKDirections，单位只影响**展示**）。
- 不做单位换算精度自定义（小数位仍交给 `MKDistanceFormatter`）。

## 现状（已核实可达）

| 显示位置 | 代码 | 当前格式化 |
|---|---|---|
| 地点详情「到下一站」路程模块 | `StopDetailView` 用 `distanceToNext` 字符串（`ItineraryView.swift:851/1042`） | 来自 `legLabel` → `legDistanceFormatter` |
| 时间轴相邻两站段距 | `ItineraryLegConnector`（`ItineraryView.swift:572`），数据来自 `legLabel`（`:536`） | `legDistanceFormatter`（`:14` 全局 `MKDistanceFormatter`） |
| 优化路线页 原始/优化距离 | `OptimizeRouteView.swift:425` | 该文件**自建**的另一个 `MKDistanceFormatter` |

→ 共 **2 套** `MKDistanceFormatter`、3 个展示点。根因解必须让两套都读同一份偏好（否则口径分裂）。

## 设计

### 1. 数据模型：`DistanceUnit`

新建 `Carry/Models/DistanceUnit.swift`，镜像 `AppearanceMode` 范式：

```swift
import MapKit
import SwiftUI

enum DistanceUnit: String, CaseIterable, Identifiable {
    case automatic   // 跟随设备地区（MKDistanceFormatter 默认 locale 行为）
    case kilometers
    case miles

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .automatic:  return "distance_unit.automatic"
        case .kilometers: return "distance_unit.kilometers"
        case .miles:      return "distance_unit.miles"
        }
    }

    /// 施加到 MKDistanceFormatter 的单位制；automatic → .default（交回 locale）。
    var formatterUnits: MKDistanceFormatter.Units {
        switch self {
        case .automatic:  return .default
        case .kilometers: return .metric
        case .miles:      return .imperial
        }
    }
}
```

存储键：`@AppStorage("distance_unit")`，默认 `DistanceUnit.automatic.rawValue`。

### 2. 共享格式化 helper（消灭两套 formatter）

在 `DistanceUnit.swift` 内提供单一入口，供所有展示点复用：

```swift
enum CarryDistanceFormat {
    /// 按给定单位偏好把米格式化为「12 km / 8 mi」等缩写。
    static func string(meters: CLLocationDistance, unit: DistanceUnit) -> String {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        f.units = unit.formatterUnits
        return f.string(fromDistance: meters)
    }
}
```

> 不复用单个全局 `let` formatter——`MKDistanceFormatter.units` 是可变状态，跨调用改它有竞态/可读性风险；每次 new 一个轻量 formatter（与 `OptimizeRouteView` 现有做法一致）。如真机 profile 显示热点再缓存，但当前无依据，先保持简单。

### 3. 接入展示点（响应式）

各展示 View 加 `@AppStorage("distance_unit") private var distanceUnitRaw = DistanceUnit.automatic.rawValue`，把 `DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic` 传进 `CarryDistanceFormat.string`：

- `ItineraryView`：删全局 `legDistanceFormatter`；`legLabel` 改用 helper（读 view 上的 @AppStorage）。`distanceToNextStop` 复用 `legLabel`，自然继承。`ItineraryLegConnector` 与 `StopDetailView` 接收的仍是已格式化字符串，无需各自读偏好。
- `OptimizeRouteView`：删本地 `MKDistanceFormatter`，改 helper + @AppStorage。

@AppStorage 使两处在用户切换单位后**实时重渲染**（无需重进页面）。

### 4. 设置 UI

`SettingsView` 新增一个 Section（放在「个性化」之后、「提醒与显示」之前，作为靠前的通用配置）：

```
Section header: settings.section.general   // 「通用 / 一般 / General」
  └ 距离单位行（settings.units.distance）：右侧显示当前值 + chevron，点按弹 confirmationDialog
```

交互完全对标现有「外观」行（`SettingsView.swift:230`）：`Button` + 右侧 `currentDistanceUnit.titleKey` + chevron，`confirmationDialog` 列三档 `ForEach(DistanceUnit.allCases)`。新增 `@State showDistanceUnitPicker` + `@AppStorage distanceUnitRaw` + `currentDistanceUnit` 计算属性。

### 5. 本地化（× 9 语言，结构化 key 含显式 en）

| key | en | zh-Hans | zh-Hant |
|---|---|---|---|
| `settings.section.general` | General | 通用 | 一般 |
| `settings.units.distance` | Distance Unit | 距离单位 | 距離單位 |
| `distance_unit.automatic` | Automatic | 自动 | 自動 |
| `distance_unit.kilometers` | Kilometers | 公里 | 公里 |
| `distance_unit.miles` | Miles | 英里 | 英里 |

其余 de / es / fr / ja / ko / pt-BR 一并补全（名词大小写、空格规范按 CLAUDE.md 本地化规范）。中文为短标签、无标点问题。

## 验收

- [ ] 设置出现「通用」分组 → 距离单位行，三档可切，当前值正确回显（明/暗、9 语言）。
- [ ] 切到「英里」→ 行程地点详情路程模块、时间轴段距、优化页距离**全部**变英里，且**实时**生效（不退页面）。
- [ ] 切回「自动」→ 跟随设备地区（中国设备公里、美区英里）。
- [ ] 默认全新安装＝自动，地区默认行为零回归。
- [ ] 编译绿（主 app + Widget）。

## 影响面 / 风险

- 纯展示层改动，无 SwiftData schema 变更、无迁移、不入备份（`@AppStorage` 设备本地偏好，符合 Appearance 等既有设备级设置惯例）。
- 不碰 `CarryBottomSheetFX` 等雷区文件。
