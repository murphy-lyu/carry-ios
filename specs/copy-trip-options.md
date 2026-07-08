# 复制行程：新日期 + 交通/住宿开关（Copy Trip Options）

> **Status: Shipped.** 已实现，待真机验收。

## 动机

现状（`TripStore.duplicateTrip(withId:)`，`PackingListView.swift` 的"···"菜单调用）：点一下"复制行程"**零交互**，立即深拷贝——包括原日期（一字不改）、以及航班/租车/住宿的具体预订信息（确认码、电子客票号、座位号等字段全部照抄）。

问题：
1. **日期不问**：复制出来的副本和原行程日期完全相同，用户几乎总要手动改日期，等于每次复制都要多做一步本该被问到的操作。
2. **交通/住宿信息原样带走，但这些字段大概率是过期/错误的**：航班确认码、酒店预订码这类"具体预订"信息，新行程大概率要重新订，旧副本里留着只会误导用户（以为已经订好），必须先手动清空才能填新的。
3. 反观**行程规划里的地点安排、打包清单**——这些是"骨架"，价值最高，且不存在过期问题（Carry 的地点/交通时间都是"第几天+几点"相对存储，不绑对日期，换个出发日期自动就对上了）。

参考 Tripsy 的处理（截图流程）：7 屏 wizard，可按类别（文件/航班/租车/住宿/旅游团）选择要不要复制、再问新日期、再问要保留哪些"活动详情"字段、再问改不改名/改不改图。**这套思路对但对 Carry 太重**——与"克制、聚焦"的产品哲学冲突。

**产品方向（已与用户对齐，含第二轮补充）**：不做 Tripsy 那种多屏 wizard，做一个**轻量弹层**：新行程名称（预填原名，不自动加后缀）+ 新日期 + 「带不带打包清单」开关 + 「带不带交通/住宿具体信息」开关；只有行程规划的地点安排始终保留、不作为选项。

第二轮补充的两点（用户反馈）：
1. **名称直接可改，且不管改不改都不再自动加"（副本）"后缀**——原方案沿用了旧 `duplicateTrip` 里 `original.name + copySuffix` 的自动加后缀逻辑，用户认为无论改不改名字都不该被强加后缀。
2. **打包清单也应该是一个可选项，默认不带**——不同季节/行程物品往往不同，默认全量复制清单不合理，比照交通/住宿开关同款处理，只是默认值都是"不带"。

## 交互流程

```
行程详情"···"菜单 → 点「复制行程」
   → 弹 CopyTripOptionsSheet（新建）
        · 名称：预填原行程名称（无后缀），可编辑；为空则确认按钮禁用
        · 日期：默认预填原行程日期，可点开修改（复用 TripDateRangePickerSheet，
          含"先规划，日期以后再定"退回规划中的入口——与创建行程同一套控件）
        · 开关：「带上打包清单」，默认关，说明"不同季节/行程物品可能不同，建议重新规划"
        · 开关：「带上航班/租车/住宿的具体预订信息」，默认关，
          说明文案类似"这些通常需要重新预订，建议不带"
        · 底部按钮「复制行程」（名称为空时禁用）
   → 确认后：生成副本 → 回首页、扫光高亮新副本（与现状一致）
```

取消/下滑关闭 = 不复制，不产生任何副本（与现状"点了就立刻复制"不同，这是刻意的行为变化——弹层出现后，用户需要显式确认才会真正生成副本）。

## 实现方案（复用现有机制，不新造）

### 1. `TripStore.duplicateTrip` 加两个参数
```swift
func duplicateTrip(withId id: UUID, includeTransportAndLodging: Bool = true, includePackingList: Bool = true) -> UUID?
```
- 默认值都是 `true`，保持函数原行为不变（其他潜在调用点零影响）。
- `includeTransportAndLodging=false`：`itineraryDays` 深拷贝时**跳过** `segments`（交通段）和顶层 `lodgingStays` 的深拷贝——两者留空数组；**停靠点（地点）不受影响，照常全量深拷贝**（这是"骨架"，永远保留）。
- `includePackingList=false`：`newSections` 传空数组（不深拷贝任何分类/物品）；同时 `selectedSceneKeys` 也清空——否则清单是空的，但 App 会以为场景推荐"已应用"（`PackingListView.hasScenes` 等依赖这个字段判断），导致场景推荐入口被误关闭、用户没法用它重新建清单。
- **名称不再自动加后缀**：`newBundle` 的 `name` 直接用 `original.name`（不再 `+ copySuffix`），因为最终名称由 sheet 里用户编辑的值通过紧随的 `updateTripInfo` 调用写入——`duplicateTrip` 内的名称只是过渡态。旧的 `trip.copy_suffix` xcstrings key 已删除（无其他调用点引用）。

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
- 名称字段用 `TextField(text:)`（与 `EditTripView`/`LodgingEditView` 同款写法），预填 `trip.name`（无后缀）；为空时确认按钮 `.disabled`。
- 复用 `TripDateRangePickerSheet`（`Views/TripDateRangePickerSheet.swift`）承载日期选择，`onSkipDates` 传入以支持"复制成规划中行程"。
- 两个开关用现有 Form/Toggle 样式即可，无需新组件。
- 确认按钮点击后：
  1. `let newId = store.duplicateTrip(withId: tripId, includeTransportAndLodging:, includePackingList:)`
  2. 若 `newId` 非空：`store.updateTripInfo(tripId: newId, info: TripInfo(name: 用户编辑的名称, ...新日期/isDateless))`——这一步同时把最终名称写入（`duplicateTrip` 内的名称只是过渡态）
  3. `onCompleted(newId)` 回调给调用方处理收尾（`store.pendingShimmerTripId` + `router.path` 重置）

### 4. `PackingListView.swift` 调用点改动
现状（`:311-317`）直接调用 `duplicateTrip` 并立即收尾；改为设置 `@State private var showCopyOptions = false`，菜单里改成 `showCopyOptions = true`，弹出新 sheet，sheet 内完成上述两步调用后自行处理收尾+ dismiss。

## 本地化

新增文案（结构化 key，9 语言）：
- `trip.copy.title`（sheet 标题，如"复制行程"）
- `trip.copy.name_section` / `trip.copy.name_placeholder`（名称字段）
- `trip.copy.date_section`（日期区块标题）
- `trip.copy.include_packing_list` / `.footer`（打包清单开关 + 说明）
- `trip.copy.include_transport_lodging` / `.footer`（交通/住宿开关 + 说明）
- `trip.copy.confirm`（确认按钮，如"复制行程"）

已删除：`trip.copy_suffix`（自动加"（副本）"后缀的旧 key，无调用点后移除）。

## 边界 / 不做

- **不做 Tripsy 式逐条勾选**（每个具体航班/地点单独打勾）——粒度过细，和"复制"这个次要操作的心智负担不成比例；交通+住宿仍是一个开关，不拆成航班/租车/住宿三个独立开关。
- **不做"改封面图"这一屏**——封面图跟随原图深拷贝，用户可以复制完成后在编辑页里自己改，不需要在复制流程里前置打断。
- **打包清单物品的"未打包"重置**——`includePackingList=true` 时清单物品仍会重置为未打包（`isPacked: false`，现状行为不变）。
- **总费用/笔记等"活动详情"级别的取舍**（Tripsy 截图里的"我们应该保留哪些活动详情"那一屏）——本 spec 不做这一层精细控制，费用/笔记随停靠点一起原样复制（它们不属于两个开关管的范畴，本身也没有过期问题）。
