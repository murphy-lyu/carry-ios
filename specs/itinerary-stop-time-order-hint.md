# 地点顺序与时间不一致提示（Stop Order/Time Mismatch Hint）

> **Status: Shipped.** 已实现列表行提示；详情页头部未做（见下方「边界 / 不做」补充）。

## 动机

Carry 的行程排序规则（`Itinerary.swift:timeline`，`docs/decisions.md` 2026-06-xx「时间轴排序规则」）是刻意的产品决策：**停靠点（地点）永远保持手动 `sortOrder`，绝不因时间被重排**；只有交通段（本身不可手动拖动）才按时间「就位」插入。这是对的——旅行里"路线顺序"和"预计时间"经常不是一回事（比如按地理位置顺路排的 A→B→C，只给 A、C 填了预约时间，B 没填），一填时间就重排会打乱用户精心排好的路线。

但这也带来一个**真实的盲区**：如果用户手动排的顺序（A→B→C）和填的时间明显冲突（比如 A 填了 14:00、B 填了 9:00），App 完全不提示，用户很可能线下才发现"怎么先到的地方时间反而更晚"。

**产品方向**：不自动重排（维持现有承诺），但让这种冲突"看得见"——一个安静的视觉提示，不阻断、不要求立即处理，用户自己决定要不要手动调整顺序。

## 判定规则

仅比较**同一天内、都设了 `plannedStartMinutes`（≥0）的停靠点**，按当前手动 `sortOrder` 顺序检查时间是否单调不减：

- 若某个停靠点的 `plannedStartMinutes` **早于**它前面（sortOrder 更小）某个已设时间的停靠点，判定为「顺序/时间冲突」。
- 未设时间的停靠点跳过（不参与比较，也不因此触发误报）。
- 只在**同一天**内比较，跨天不比较（`ItineraryDay` 之间时间轴本就独立）。
- 交通段不参与此判定（它们已经按时间「就位」，天然不会冲突）。

判定逻辑建议作为 `ItineraryDay` 或 `TripBundle` 的计算属性/辅助方法，返回「冲突的停靠点 id 集合」，供列表行读取，例如：

```swift
/// 当天停靠点里，时间早于「前面某个已设时间停靠点」的那些 stop id（仅按手动 sortOrder 比较，不含交通段）。
var stopsWithTimeOrderConflict: Set<UUID> {
    var lastSeenMinutes = -1
    var conflicts: Set<UUID> = []
    for stop in sortedStops where stop.plannedStartMinutes >= 0 {
        if stop.plannedStartMinutes < lastSeenMinutes {
            conflicts.insert(stop.id)
        } else {
            lastSeenMinutes = stop.plannedStartMinutes
        }
    }
    return conflicts
}
```

## 视觉方案

复用现有「无坐标」提示的位置和克制程度（`ItineraryView.swift` 停靠点行，`mappin.slash` 图标），但语义不同——这个是「值得看一眼但不紧急」，参考 `voltage-converter-nudge.md` 已确立的 `Color.alertOrange` 警示色precedent（非阻断类警示的既有 token，不新造颜色）：

- 停靠点行的时间文字（`timeRangeLabel`）本身着色为 `Color.alertOrange`（平时是 `.secondary`），不加额外图标、不加文字说明——颜色变化本身就是提示，保持列表克制。
- 不可点、不弹提示、不打断——用户看到时间变色，自然会意识到"这个时间和前面顺序对不上"，若想处理，自己去拖拽重排或改时间。
- 停靠点详情页（`StopDetailView`）如果也显示时间，同样着色，保持一致。

## 涉及范围

- `Carry/Models/Itinerary.swift`：`ItineraryDay` 新增 `stopsWithTimeOrderConflict` 计算属性。
- `Carry/Views/ItineraryView.swift`：停靠点行 `timeRangeLabel` 的 `Text` 读取该集合决定颜色；`StopDetailView` 同步。
- 不涉及 SwiftData schema 变更（纯计算属性，不落盘）。
- 不涉及 Widget（Widget 的 agenda 是「未来事件」列表，本身按时间排序展示，不复现这个「手动顺序 vs 时间」的场景）。

## 边界 / 不做

- 不提供「一键按时间重排」的按钮——那等于变相鼓励自动重排，与本 spec「不自动重排」的前提矛盾；用户如果认可时间、想调整顺序，用现有的「地点排序」手动拖拽即可。
- 不做 modal/toast 类型的阻断提示——克制，只做静默的颜色信号。
- 不处理「交通段与停靠点」之间的顺序冲突——交通段已经按时间强制就位，不存在这类冲突。
- **实现范围收窄为仅列表行**：`StopDetailView` 头部副标题（`stopScheduleSubtitle`）是日期+时间拼成的一整条 `String`，经共享组件 `DetailSheetHeader`（住宿/交通详情共用）渲染；单独给"时间"上色需要改共享组件接口，成本明显超过这个小提示本身的价值——且详情页一次只看一个地点，冲突信号在"能同时看到多个地点顺序"的列表里才真正有意义。故只在列表行（`TimelineStopRow`）实现。
