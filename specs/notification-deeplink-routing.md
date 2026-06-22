# 通知/深链跳转的承接路由（Notification & Deep-link Routing）

> **Status: Implemented（2026-06-23 · 编译绿，待真机/模拟器验收）** — 根因解「通知点开落点不符合通知语义」。
> 实现文件：`ContentView.swift`（共享类型 `TripDetailFace`/`TripDeepLinkAnchor`/`TripDeepLink` + router `pendingTrip`/`pendingItineraryAnchor` + `handlePendingTrip`）、`NotificationManager.deepLink(fromIdentifier:)`、`CarryApp.swift`（通知 handler + URL scheme）、`PackingListView.swift`（`TripDetailFaceStore` 提升）、`ItineraryView.swift`（消费锚点 → `focusedDayId`）。
> 关联：[[notification-budget]]、[[notification-center]]、[[app-navigation-framework]]、[[weather-aware-packing]]、`itinerary-route-planning`。

## 问题（2026-06-23 审查所得）

Carry 现有 6 类行程通知，点击后**全部**只解析出 `tripId` → `router.path = [tripId]` → 落到 `PackingListView`，且开在该行程**「上次看的脸」**（`TripDetailFaceStore`，打包/行程二选一，老行程默认行程）。深链**不参与选脸**，id 里携带的 `segId`/`stayId`/`dayOrder` 锚点被丢弃。后果：

- **A·落点不按语义选脸**：点「还剩 3 件没打包」可能开在「行程路线」；点「今天 3 个安排」可能开在「打包清单」——看运气（上次手停在哪）。
- **B·有锚点却不定位**：交通/住宿/每日概要的 id 本就带精确锚点，承接页只到「行程级」，不滚到那一段/那一天。

URL scheme 侧同病：`carry://trip/{id}` 与 `carry://packing/{id}` 两个 host 当前也不区分脸。

## 各通知 → 目标脸 + 锚点（映射表，已定）

| 通知类别 | id 命名 | 目标脸 | 锚点 |
|---|---|---|---|
| 出发提醒 depart | `…depart.{offset}` | 打包 | — |
| 打包进度 pack | `…pack` | 打包 | — |
| 天气预警 weather | `…weather` | 打包 | — |
| 交通 transport | `…transport.{segId}.{role}.{lead}` | 行程 | 段所在天 |
| 住宿 lodging | `…lodging.{stayId}.out` | 行程 | 退房天 |
| 每日概要 daily | `…daily.{dayOrder}` | 行程 | 该天 |
| URL `carry://packing/{id}` | — | 打包 | — |
| URL `carry://trip/{id}` / Widget / 快捷指令 | — | 保持上次脸（不强制） | — |

## 设计

### 1. 富深链目标（取代裸 `UUID`）
```swift
enum TripDetailFace { case packing, itinerary }       // 由 PackingListView 私有 DetailTab 提升为共享
enum TripDeepLinkAnchor: Equatable { case day(Int); case segment(UUID); case lodging(UUID) }
struct TripDeepLink: Equatable {
    let tripId: UUID
    var face: TripDetailFace? = nil    // nil = 保持上次脸（Widget / carry://trip / 快捷指令）
    var anchor: TripDeepLinkAnchor? = nil
}
```
`NavigationRouter.pendingTripId: UUID?` → `pendingTrip: TripDeepLink?`（三个生产者同步改：通知 handler、`onOpenURL`、冷启动消费）。再加 `pendingItineraryAnchor: TripDeepLinkAnchor?` 供 ItineraryView 消费。

### 2. 解析（单一真源，与 id 命名同处维护）
`NotificationManager.deepLink(fromIdentifier:) -> TripDeepLink?`：按 id 段判类别 → 填 face + anchor。**新增通知类别时必须同步此函数**（与 `collectXxx` 成对，纳入埋点闭环式自检）。

### 3. 选脸（无闪烁）
`face != nil` 时，跳转**前** `TripDetailFaceStore.save(face, tripId:)`（init 首帧即读到正确脸，复用既有「首帧即正确面」机制，不在 onAppear 纠正、无 push 中闪烁）。副作用＝更新「上次看的脸」，可接受（深链看了某脸＝看过它）。`TripDetailFaceStore` 由 `private` 提升为文件内/共享可见。

### 4. 锚点（行程脸内滚到对应天）
`handlePendingTrip` 把 `anchor` 写入 `router.pendingItineraryAnchor`。ItineraryView 在数据就绪后消费一次：
- `.day(order)` → `focusedDayId =` 该 sortOrder 的天；
- `.segment(segId)` → 段所在天（`departDayOrder`）；
- `.lodging(stayId)` → 退房天（`checkOutDayOrder`）。
- 设 `focusedDayId` 即驱动 `ItineraryReorderCollection.scrollTargetDayId` 滚动 + 日历条居中。消费后清空 anchor（避免重复触发）。

**锚点深度＝「定位到天并滚动」，不自动弹出该项详情 sheet**（到达即弹 modal 偏侵入，且该天视图已让目标项可见）。如需「直达该项详情」可作后续增强。

### 5. 拆 modal（已实现，保留）
`handlePendingTrip` 仍先拆掉根级 sheet（`rootModalDismissalRequest` + ContentView 级 sheet），见提交 `7eccc8a`。

## 不做
- 不自动弹目标项的 detail sheet（见 §4）。
- 不做行内（行级）精确滚动，天级足以让目标可见（Minimal Effective Set）。

## 测试 Checklist
- [ ] 6 类通知各自落对脸（打包类→打包；行程类→行程）。
- [ ] 行程类落到正确的天并滚动到位（段→所在天、住宿→退房天、每日→该天）。
- [ ] 打包类无锚点、不误触发滚动。
- [ ] `carry://packing/{id}` 落打包；`carry://trip/{id}`/Widget/快捷指令保持上次脸、不回归。
- [ ] 停在某 sheet→Home→点通知：拆 modal 仍生效，且落对脸 + 锚点。
- [ ] 冷启动点通知（App 被杀）：富目标在 SplashView 阶段被消费、不丢。
- [ ] 无锚点深链不改变无关行程的「上次脸」。
