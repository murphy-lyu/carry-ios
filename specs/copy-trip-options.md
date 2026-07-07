# 复制行程：新日期 + 交通/住宿开关（Copy Trip Options）

> **Status: Shipped.** 已实现，待真机验收。

## 动机

现状（`TripStore.duplicateTrip(withId:)`，`PackingListView.swift` 的"···"菜单调用）：点一下"复制行程"**零交互**，立即深拷贝——包括原日期（一字不改）、以及航班/租车/住宿的具体预订信息（确认码、电子客票号、座位号等字段全部照抄）。

问题：
1. **日期不问**：复制出来的副本和原行程日期完全相同，用户几乎总要手动改日期，等于每次复制都要多做一步本该被问到的操作。
2. **交通/住宿信息原样带走，但这些字段大概率是过期/错误的**：航班确认码、酒店预订码这类"具体预订"信息，新行程大概率要重新订，旧副本里留着只会误导用户（以为已经订好），必须先手动清空才能填新的。
3. 反观**行程规划里的地点安排、打包清单**——这些是"骨架"，价值最高，且不存在过期问题（Carry 的地点/交通时间都是"第几天+几点"相对存储，不绑对日期，换个出发日期自动就对上了）。

参考 Tripsy 的处理（截图流程）：7 屏 wizard，可按类别（文件/航班/租车/住宿/旅游团）选择要不要复制、再问新日期、再问要保留哪些"活动详情"字段、再问改不改名/改不改图。**这套思路对但对 Carry 太重**——与"克制、聚焦"的产品哲学冲突。

**产品方向（已与用户对齐）**：不做 Tripsy 那种多屏 wizard，做一个**轻量弹层**：只问"新日期"+ 一个"要不要带上交通/住宿具体信息"的开关，其余（行程规划的地点安排、打包清单）默认全部保留、不作为选项。

## 交互流程

```
行程详情"···"菜单 → 点「复制行程」
   → 弹 CopyTripOptionsSheet（新建）
        · 日期：默认预填原行程日期，可点开修改（复用 TripDateRangePickerSheet，
          含"先规划，日期以后再定"退回规划中的入口——与创建行程同一套控件）
        · 开关：「带上航班/租车/住宿的具体预订信息」，默认关，
          说明文案类似"这些通常需要重新预订，建议不带"
        · 底部按钮「复制行程」
   → 确认后：生成副本 → 回首页、扫光高亮新副本（与现状一致）
```

取消/下滑关闭 = 不复制，不产生任何副本（与现状"点了就立刻复制"不同，这是刻意的行为变化——弹层出现后，用户需要显式确认才会真正生成副本）。

## 实现方案（复用现有机制，不新造）

### 1. `TripStore.duplicateTrip` 加一个参数
```swift
func duplicateTrip(withId id: UUID, includeTransportAndLodging: Bool = true) -> UUID?
```
- 默认值 `true` 保持函数当前行为不变（其他潜在调用点零影响）。
- 为 `false` 时：`itineraryDays` 深拷贝时**跳过** `segments`（交通段）和顶层 `lodgingStays` 的深拷贝——两者留空数组；**停靠点（地点）不受影响，照常全量深拷贝**（这是"骨架"，永远保留）。
- 具体产出：`false` 时每个 `copiedDay.segments = []`；`newBundle.lodgingStays = []`（跳过对应的 `.map` 深拷贝块）。

### 2. 新日期：直接复用 `updateTripInfo` 已有的日期变更机制
`duplicateTrip` 内部**不改动日期处理**——复制时仍然沿用原日期先建出副本（和现状一样）。新日期的应用**在 sheet 确认后、`duplicateTrip` 返回新 id 之后**，紧接着调用一次已有的：
```swift
store.updateTripInfo(tripId: newId, info: TripInfo(...新日期/或 isDateless...))
```
`updateTripInfo` 内部已经做好了这一整条链路（`Models/TripStore.swift:968-1024`）：
- `syncItineraryDays(tripId:)`——**天数变化时自动收拢**：新日期范围如果比原行程短，超出新天数的尾部天的地点+交通段会被**移到最后保留的那天**（不是丢弃，见 `syncItineraryDays` 里"多余尾部天的停靠点与交通段挪到最后保留的那天"的注释与实现，`TripStore.swift:1325-1350`）——这正是本 spec 需要的"新日期天数变化"处理，**不需要另写**。
- 通知重排、日历同步、Live Activity 状态——全部已经在 `updateTripInfo` 里处理好，复制流程白得。

即：复制行程 = `duplicateTrip(includeTransportAndLodging:)` 产出副本 → 立即 `updateTripInfo` 套用户选的新日期，两步组合，零重复造轮子。

### 3. 新建 `CopyTripOptionsSheet`
- 复用 `TripDateRangePickerSheet`（`Views/TripDateRangePickerSheet.swift`）承载日期选择，`onSkipDates` 传入以支持"复制成规划中行程"。
- 开关用现有 Form/Toggle 样式即可，无需新组件。
- 确认按钮点击后：
  1. `let newId = store.duplicateTrip(withId: tripId, includeTransportAndLodging: includeToggle)`
  2. 若 `newId` 非空：`store.updateTripInfo(tripId: newId, info: 用户选的新日期/isDateless)`
  3. `store.pendingShimmerTripId = newId`；`router.path = NavigationPath()`（与现状收尾一致）

### 4. `PackingListView.swift` 调用点改动
现状（`:311-317`）直接调用 `duplicateTrip` 并立即收尾；改为设置 `@State private var showCopyOptions = false`，菜单里改成 `showCopyOptions = true`，弹出新 sheet，sheet 内完成上述两步调用后自行处理收尾+ dismiss。

## 本地化

新增文案（结构化 key，9 语言）：
- `trip.copy.title`（sheet 标题，如"复制行程"）
- `trip.copy.date_section`（日期区块标题）
- `trip.copy.include_transport_lodging`（开关文案，如"带上航班/租车/住宿信息"）
- `trip.copy.include_transport_lodging.footer`（说明文案，如"这些信息通常需要重新预订，建议不带"）
- `trip.copy.confirm`（确认按钮，如"复制行程"）

## 边界 / 不做

- **不做 Tripsy 式逐条勾选**（每个具体航班/地点单独打勾）——粒度过细，和"复制"这个次要操作的心智负担不成比例；本 spec 只做"类别级"开关（交通+住宿一起一个开关，不拆成航班/租车/住宿三个独立开关——三者同属"具体预订信息"这一类，拆开没有实际意义，只会让弹层变复杂）。
- **不做"改行程名称/改封面图"这两屏**——现有"复制"已经用 `original.name + copySuffix` 自动生成新名字（如"新疆·伊犁 副本"），封面图也照抄；这两者用户可以复制完成后在编辑页里自己改，不需要在复制流程里前置打断。
- **打包清单物品的"未打包"重置**——已经是现状行为（`isPacked: false`），不受本 spec 影响，继续保留。
- **总费用/笔记等"活动详情"级别的取舍**（Tripsy 截图里的"我们应该保留哪些活动详情"那一屏）——本 spec 不做这一层精细控制，费用/笔记随停靠点一起原样复制（它们不属于"交通/住宿具体预订信息"这个开关管的范畴，本身也没有过期问题）。
