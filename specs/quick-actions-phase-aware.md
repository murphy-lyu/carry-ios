# 主屏 Quick Actions：相位感知 + 数据驱动（Phase-Aware Quick Actions）

> **Status: ✅ Implemented — 编译绿、i18n [E]=0，待 UI/真机验收。** 未提交。
> **与原 Draft 的偏差**：① 删了 `quickaction.subtitle.today`——`.upcoming` 相位恒「今天 < 出发日」→ daysUntil≥1，出发当天已归 `.today`，「今天出发」副标题不可达。② 新增 `.recent` 第三相位（无未来/进行中行程时回落最近过去行程、保持上次脸）——保留旧 `findNearestTrip` 的过去回落行为，不静默回归。③ 第 4 槽「下一程」未做（用户未要、spec 标默认不做）。
> 改动文件：`CarryShortcuts.swift`（`QuickActionTarget.resolve` 单一真源 + face/day 信号 + handle/Intent 接入）、`CarryApp.swift`（`refreshQuickActions(trips:)` 动态装载）、`TripStore.swift`（init Task 冷启动刷新）、`ContentView.swift`（open_trip 走 `TripDeepLink`）、`Carry/Localizable.xcstrings`（+4 key×9 语言）。

> **（原始 Draft）** 确认后再编码。
> 关联：`notification-deeplink-routing.md`（`TripDeepLink(face:anchor:)` 路由机制，本 spec 直接复用）、`widget-trip-companion.md`（相位判定 + 生命周期刷新钩子同源）、`dateless-planning-trips.md`（无日期行程边界）。

## 动机 / 现状根因

长按 App 图标的主屏快捷操作（[CarryApp.swift](../Carry/CarryApp.swift) `installQuickActions` + [CarryShortcuts.swift](../Carry/AppIntents/CarryShortcuts.swift) `CarryQuickAction`）现有 3 个、**全静态**（启动装一次、永不变）：**New Trip**（进创建）/ **Nearest Trip**（开最近即将出发行程）/ **Footprint**（足迹地图）。同套镜像成 App Shortcuts（Siri/Spotlight）。

两个根因问题：
1. **Nearest Trip 不感知相位、落「上次看的脸」**（[ContentView.swift](../Carry/ContentView.swift) `handlePendingShortcut` 走 `router.path.append(id)`）——旅行中用户想看「今天的行程」，却可能被甩到打包页。
2. **全静态、无副标题**——长按只看到三个干词，不告诉你「最近是哪趟、还有几天 / 第几天」。**行程规划能力完全没上 Quick Actions**。

## 核心原则

1. **Quick Action = 立刻跳一下**（跳到目的地、跳过导航），不同于 Widget 的「瞄一眼信息」。二者互补：Widget 旅行中卡片瞄「Day 3 · 下一件事」，Quick Action 长按直达今天的行程。
2. **槽位极稀缺**（iOS 最多 ~4）：只有「高频、有意图、比开 App 再导航明显快」的跳转才配占槽。**不塞深度录入/低频动作**。
3. **杠杆 = 数据驱动 + 相位感知**：Quick Action 支持运行时动态更新 + 副标题，现在完全没用上。改静态为动态是本 spec 的使能点。
4. **复用既有深链机器，不另造**：跳「行程脸 + 锚到某天」已由 `TripDeepLink(tripId,face,anchor)` + `handlePendingTrip` 实现（通知/Widget 在用，含无闪烁选脸 + 滚到当天）。Quick Action 的 trip-open 一律改走它。

## 相位与目标解析（单一真源）

新增纯函数 `QuickActionTarget.resolve(trips:) -> Target?`，供「刷新显示」与「点击路由」共用，避免两处各算一套：

- 取**非无日期**行程。判定：
  - **旅行中**（`departureDate ≤ today ≤ returnDate`，`returnDate = departureDate + days`）→ `Target(tripId, face: .itinerary, anchor: .day(currentDayIndex), kind: .today)`；`currentDayIndex = clamp(daysBetween(departureDate, today), 0, spanDays-1)`。
  - 否则取**最近即将出发**（`departureDate ≥ today` 最小者；无则不取）→ `Target(tripId, face: .packing, anchor: nil, kind: .upcoming)`。
  - 二者皆无（只有过去行程 / 无行程）→ nil。
- 中间槽位据此**变脸**：旅行中 = 「今天的行程」；出发前 = 「Nearest Trip」（落打包脸）。仍是**一个槽位**，不增视觉噪音。

## 改动清单

### 1. 动态刷新 shortcutItems（相位 + 数据副标题）
- `installQuickActions()` → `refreshQuickActions(trips:)`，读 `store.trips` 算 `QuickActionTarget.resolve`，组装 ≤4 项：
  - **New Trip**（恒在）。
  - **中间槽（变脸）**：`kind == .today` → 标题「今天的行程」、副标题 `东京 · Day 3`；`kind == .upcoming` → 标题「Nearest Trip」、副标题 `东京 · 还有 3 天 / 明天 / 今天`；target 为 nil → 该槽省略（只剩 New Trip + Footprint）。
  - **Footprint**（恒在）。
- 刷新时机：挂在与 `writeWidgetSnapshot` **同一生命周期钩子**（`onAppear` 启动 + `didEnterBackground`），零额外驱动。`shortcutItems` 写入廉价（≤4 项）。
- `userInfo` 带上 target（tripId / face / dayOrder），让点击路由无需再查库（冷启动也稳）。

### 2. 点击路由统一走 TripDeepLink（修「落上次的脸」）
- `CarryQuickAction.handle(type:)` 与 App Intent：trip-open 类不再写 `open_trip + tripId` 裸信号，改写**富信号**（action + tripId + face + dayOrder），或直接复用 target。
- `handlePendingShortcut` 的 `open_trip` 分支：从 `router.path.append(id)` 升级为 `router.pendingTrip = TripDeepLink(tripId, face, anchor)`——**复用 `handlePendingTrip`**（无闪烁选脸 + 滚到当天）。`create_trip` / `show_map` 不变。
- 收益：旅行中长按 → 直达**行程脸 + 今天**；出发前 → 打包脸。与通知/Widget 路由口径一致。

### 3. App Shortcuts（Siri/Spotlight）对齐
- `OpenNearestTripIntent` 复用 `QuickActionTarget.resolve`：旅行中说「打开我的行程」→ 落行程脸今天；出发前 → 打包脸。短语/标题保持。`CreateTrip` / `Footprint` 不变。

### 4. 可选 · 第 4 槽「下一程」（**待你定取舍**）
- 旅行中再加一项 → 直达**下一段交通详情**（机场拿登机牌/预订码用），`anchor: .segment(id, isReturn:false)`。
- 取舍：与刚做的**交通 Live Activity** 场景重叠、且占满第 4 槽；价值边际递减。**默认不做**，除非「长按直接调出登机信息」被判为刚需。

## 边界 / 退化

- **无行程 / 只有过去行程**：中间槽省略，仅 New Trip + Footprint。
- **无日期行程**：不参与相位（无「今天第几天」），不进中间槽。
- **冷启动时序**：沿用现有 `handlePendingShortcut` 的 0.35s 兜底（NavigationStack 就绪无可观察钩子，CLAUDE.md 已记此反模式的保留理由）；改走 `pendingTrip` 后由 `handlePendingTrip` 的冷启动保护消费（已存在）。
- **副标题语言**：按设备 locale 在刷新时算好（与 Widget 同设备、口径一致）。

## 不做（避免为做而做）

长按加地点/加航班（深度录入、主屏频率低）、导航到下一站（该用地图 App）、把行程规划各功能铺成一堆动作（爆槽）。

## 本地化

新增结构化 key（en 显式 + 9 语言齐、中文全角）：
- `quickaction.today.title`（「今天的行程」/ Today's Plan）。
- 副标题模板：`quickaction.subtitle.day`（`%@ · Day %lld`——序数/比例，扁平 `%lld` 合法）；`quickaction.subtitle.in_days`（`%@ · 还有 %lld 天`——**调用点已特判 0=今天/1=明天，故 N≥2**，按 CLAUDE.md「恒≥2」属合法扁平例外，无需复数变体）；`quickaction.subtitle.today` / `quickaction.subtitle.tomorrow`。
- 现有 `New Trip` / `Nearest Trip` / `Footprint` 标题键复用。改完跑 `python3 scripts/i18n-audit.py`（[E]=0）。

## 验收

编译绿后，UI 验收交用户。建议覆盖：
1. 出发前行程 → 长按：中间槽「Nearest Trip · 东京 · 还有 3 天」，点 → 落**打包脸**。
2. 把某行程出发日调到昨天、返程在未来 → 长按：中间槽「今天的行程 · 东京 · Day 2」，点 → 落**行程脸**且滚到今天。
3. 无行程 → 只剩 New Trip + Footprint，无崩。
4. 无日期行程 → 不进中间槽。
5. 冷启动（杀进程后长按进入）目标正确、不丢跳转。
6. Siri「打开我的行程」相位落点同上。
7. 切设备语言看标题/副标题（含 count=1 显「明天」而非「还有 1 天」）。

## 实现顺序

1. `QuickActionTarget.resolve(trips:)` 纯函数（相位 + 目标 + 副标题数据）。
2. `refreshQuickActions(trips:)` 动态装载 + 挂生命周期钩子。
3. 点击路由改走 `TripDeepLink` / `handlePendingTrip`（含 `userInfo` 富信号）。
4. App Shortcuts `OpenNearestTripIntent` 对齐。
5. 本地化 + i18n-audit + 编译 → 交用户验收。
6.（可选）第 4 槽「下一程」——经你确认再做。
