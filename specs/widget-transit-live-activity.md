# Widget 出行日「下一程」Live Activity（Transit Live Activity）

> **Status: ✅ Implemented（A+B）— 编译绿（主 app + Widget Extension），待真机验收。** 未 push。
> **实现要点**：
> - 起停 = **A+B**（用户拍板）。A 自动起：冷启动（`TripStore.init` Task、`fetchTrips` 后）+ 回前台（`CarryApp.willEnterForeground`）扫所有行程，为「现在落在 [出发前 24h, 到达+1h] 内」最临近一程起 LA。B 显式：交通详情页「在锁屏追踪此程」按钮（`TransportDetailView.trackCard`）。
> - 主开关 `liveActivityTransitEnabled`（**默认开**）放「锁屏实时活动」设置页（原「锁屏打包进度」页泛化为含两个开关；入口标题改 `settings.liveactivity.title`）。关闭即 `endTransit()` 清空。
> - 新增共享模型 `SharedSources/TransportActivityAttributes.swift`（pbxproj 登记进两 target）；预留 `liveStatus`/`gate`/`actualDepartureDate` 给未来航班动态、不改结构。
> - `LiveActivityManager` 扩交通 LA 全生命周期（start/endTransit/endTransitIfArrived/并入 endAll），复用并发锁范式；删行程 `endTransit(tripId:)`、抹数据/关开关一并清。
> - 绝对起降时刻用新增 `TransportSegment.absoluteDeparture/Arrival`（Itinerary.swift，与 NotificationManager 同算法）。
> - 锁屏 + 灵动岛三态（`CarryTransitLiveActivity`）：倒计时用 `Text(timerInterval:)` 系统自走；相位（起飞前/途中/已抵达）渲染时按 `Date()` 判定。**schedule-based，文案不暗示实时追踪**。
> - 本地化：主 app +4 key（title/transit/track.start/track.tracking）、widget +3 key（until_departure/en_route/arrived），9 语言齐、i18n-audit [E]=0。

> **（原始 Draft）** 本 spec 是「Widget 表达行程规划」的**第二步**，体量大于姊妹 spec、建议在其之后实现。
> 关联：`itinerary-transport-lodging.md`（`TransportSegment` 模型）、`itinerary-timezone.md`（两端时区 → 绝对起降时刻）、`itinerary-flight-lookup.md`（航班查号回填 + 预留 `liveStatusData`）、`notification-budget.md` / `notification-center.md`（交通通知，避免重复打扰）、`notification-deeplink-routing.md`（点击深链到段）。
> 姊妹 spec：`widget-trip-companion.md`（桌面小组件相位升级，先实现）。

## 动机 / 现状根因

现在唯一的 Live Activity 是**打包进度**（`PackingActivityAttributes` + [CarryWidgetLiveActivity.swift](../CarryWidget/CarryWidgetLiveActivity.swift) + [LiveActivityManager.swift](../Carry/Models/LiveActivityManager.swift)）。它只在**出发前 `activationWindowDays` 窗口内**激活，出发即 `endIfDeparted` 结束（[LiveActivityManager.swift:48,174](../Carry/Models/LiveActivityManager.swift:48)）。

打包 LA 服务「出发前」。但**出行当天**——要赶飞机/高铁的那天——才是 Live Activity 最经典、价值最高的场景（Flighty / TripIt 整个产品立身于此）：锁屏 / 灵动岛常驻一个「下一程倒计时」，不解锁就知道「还有多久起飞、在哪个航站楼、登机口」。这一段 Carry 完全空白。

数据其实早已就绪：`TransportSegment` 有起降时刻（`departLocalMinutes`/`arriveLocalMinutes` + `departDayOrder`/`arriveDayOrder`）、两端机场码/航站楼、两端 IANA 时区（航班查号自动回填），且**预留了 `liveStatusData`**（[Itinerary.swift:481](../Carry/Models/Itinerary.swift:481)）给未来航班动态。

## 诚实的范围界定（关键）

- **本轮是「按时刻表的倒计时」，不是「实时航班动态」。** Carry 暂未接航班实时状态 API（延误/登机口/转盘/实际起降），Roadmap 里「航班实时动态」是独立的进行中项。
- 因此本 LA 现阶段 = **计划起降时刻 + 相对倒计时 + 静态实用信息（航站楼/座位/航班号）**。倒计时用系统原生 `Text(timerInterval:)` 渲染——**系统自走、无需 App 频繁 update**，本地 `pushType:nil` 即可（与打包 LA 同范式）。
- **设计成「实时数据就绪」**：`ContentState` 预留可选 live 字段（gate/delay/status），将来接 API 时只填充 + `activity.update`，**不改 LA 结构**。`liveStatusData` 字段已在模型层等着。

> ⚠️ 不为了「有个炫的 LA」而把它当成已有实时能力对外呈现。文案/视觉**不暗示**我们在追踪实时航班——只显「计划 09:00 起飞 · 还有 2 小时」这类如实信息，避免用户误以为延误会自动反映。

## 核心原则

1. **一次只追一程：当下最近的「未来交通段」。** LA 锚定「现在之后、最近的一段交通」（航班/火车/巴士/渡轮/租车取车）。它出发后 → 自动结束或滚动到下一程。
2. **schedule-based，系统自走倒计时。** 绝对起降时刻在 App 侧按段两端时区算好写进 `ContentState`；锁屏/灵动岛用 `Text(timerInterval:)` 呈现倒计时，过程零 App 干预。
3. **与打包 LA 不冲突、相位接力。** 二者是**不同 `ActivityAttributes` 类型**，ActivityKit 上可并存。但相位上基本是接力：打包 LA 在出发前、出发即结束；交通 LA 在出行日。重叠仅出现在「出发当天还没打包完」的极少数情形——见「与打包 LA 的关系」。
4. **不重复打扰。** 已有交通出发通知（`notification-center.md` 的 B 锚）。LA 是**常驻陪伴**、通知是**单次提醒**，二者互补不矛盾；但文案口吻统一（Made with Love、不施压），且 LA 存在期间不额外加码通知。

## 数据模型（新增，放 SharedSources/ 双 target 共用）

```
struct TransportActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        // 计划信息（schedule-based，必填）
        var modeRaw: String        // TransportMode.rawValue → 图标/口吻
        var carrierAndNumber: String  // "MU5801" / "G403" / 自填名；可空
        var fromCode: String       // "KMG"（航班/火车）；无码交通显 fromName
        var toCode: String
        var fromName: String       // 站点名（无码时用）
        var toName: String
        var departureDate: Date    // 绝对起飞/发车时刻（App 侧按 fromTimeZone 算）
        var arrivalDate: Date      // 绝对到达时刻（按 toTimeZone 算）
        var fromTerminal: String   // 可空
        var seat: String           // 可空
        // 实时预留（本轮恒空，接 API 时填充，不改结构）
        var liveStatus: String?    // "On Time"/"Delayed 20m"/"Boarding" …
        var gate: String?
        var actualDepartureDate: Date?
    }
    var tripId: UUID
    var segmentId: UUID
}
```

## 起停机制（**主要产品决策点，需你拍板**）

iOS 不允许 App 在**后台**无 push 地启动 Live Activity。无 push infra（与打包 LA 同约束）下，候选方案：

- **A（自动·前台）**：App 进前台 / 启动时，若存在「现在之后 ≤ `transitWindowHours`（如 24h）内出发的交通段」→ 自动起 LA。优点：零操作、最接近 Flighty 体感；缺点：用户当天若不开 App 就不会起（可接受——出行日几乎必开 App）。
- **B（显式·按钮）**：交通段**详情页**加「在锁屏追踪此程」按钮，用户主动起。优点：可控、不意外占用锁屏；缺点：多一步、易被忽略。
- **A + B（推荐）**：自动起为主（出行日体感好），详情页保留显式开关兜底（可手动起/停某程）。

> 这是 UX/产品决策（是否默认占用用户锁屏），交你定。工程上三者都可做。**倾向 A+B**：自动覆盖主场景、显式给掌控感。

**结束**：到达时刻 + buffer（如 1h）后自动 `end`；或下一程更近时滚动；或用户手动关。复用 `LiveActivityManager` 的并发保护范式（`isStarting` 锁 + `terminateAllAndWait`，避免撞 ActivityKit 上限）。

**激活门槛**（呼应打包 LA）：`!isDateless`（无日期无起降时刻）、`areActivitiesEnabled`、该段有有效 `departureDate`（`departLocalMinutes >= 0`）。

## UI / 布局（遵循 design-system，圆体数字、明暗双态）

- **锁屏卡片**：标题行 = mode 图标 + `carrierAndNumber`（+ 目的地城市）；主区 = `FROM → TO`（码或名）+ **大号相对倒计时**（`Text(timerInterval:)`，「2:14:30 后起飞」）；副行 = 计划起飞时刻（按出发地时区，标注城市/GMT 仅跨区时）+ 航站楼/座位（有则显）。起飞后切「已起飞 · 预计 TO 到达」。
- **灵动岛**：
  - 紧凑 leading：mode 图标；紧凑 trailing：倒计时（`Text(timerInterval:)` 紧凑格式）。
  - 最小态：mode 图标。
  - 展开态：leading `FROM→TO` + 航班号；trailing 计划起飞时刻；bottom 倒计时进度（出发→到达可做一条「飞行中」进度，但**无实时数据时仅按计划时刻线性推**，需注明非真实位置）。
- 深链：点击 → `TripDeepLink`（行程脸 + 锚到该段 / 该天），复用 `notification-deeplink-routing`。
- 图标按 `TransportMode`：flight `airplane`、train `tram.fill`、bus `bus`、ferry `ferry`、carRental `car.fill`。

## 与打包 LA 的关系

- 两类 LA 可并存（不同 attributes）。正常相位接力：打包（出发前）→ 出发即 `endIfDeparted` 结束 → 交通 LA（出行日）接棒。
- 重叠窗口（出发当天打包未完）：**不强制互斥**——打包未完时打包 LA 仍有价值，交通 LA 也该起。锁屏会有两张卡，属合理（都当下相关）。**待真机看观感**，若过挤再议「出发当天打包 LA 让位」策略（留作实现期决策、不预先复杂化）。
- `LiveActivityManager`：倾向**扩展现有 manager**（加 `Activity<TransportActivityAttributes>` 的并行 start/update/end/endAll），复用授权检查、并发锁、`endAll`（「抹掉所有数据」/删行程时一并清）。`eraseAllData` / 删行程路径需同步 end 交通 LA（呼应 `erase-all-data.md`）。

## 本地化

新增结构化 key（en 显式 + 9 语言齐、中文全角）：起飞倒计时模板、「已起飞」、「预计 %@ 到达」、各 mode 标签若需文字。倒计时数字由系统格式化（`Text(timerInterval:)`，本地化自动）。改完跑 `python3 scripts/i18n-audit.py`（[E]=0）。

## 验收

编译绿（主 app + Widget Extension）后，**真机验收交用户**（Live Activity 在模拟器表现有限）。建议覆盖：
1. 建一段「今天/明天起飞」的航班 → 开 App（方案 A）/ 点详情按钮（方案 B）→ 锁屏 + 灵动岛出现「下一程」，倒计时自走、起降时刻/航站楼正确。
2. 跨时区段（PVG→CDG）→ 起飞倒计时按出发地时区、到达按目的地时区，无错点。
3. 起飞时刻过后 → 切「已起飞」；到达 + buffer 后自动消失。
4. 多段行程 → LA 始终锚「最近未来段」，前一段结束滚动到下一段。
5. 删行程 / 抹掉所有数据 → 交通 LA 一并结束（无残留）。
6. 与打包 LA 并存观感（出发当天打包未完）。
7. 系统关闭 Live Activity 权限 → 不激活、不崩。

## 实现顺序（在姊妹 spec 之后）

1. 新增 `TransportActivityAttributes`（SharedSources/，双 target）。
2. 扩 `LiveActivityManager`：交通 LA 的 start/update/end/endAll + 并发锁复用；接 `eraseAllData`/删行程清理。
3. 起停策略（按拍板的 A / B / A+B）+ 「最近未来段 + 绝对起降时刻」计算（App 侧按两端时区）。
4. `CarryWidgetLiveActivity` 加 `TransportActivityAttributes` 的 `ActivityConfiguration`（锁屏 + 灵动岛三态）。
5. 本地化 + i18n-audit + 编译 → 真机验收。
6.（未来）接航班实时动态 API 时填充 `liveStatus`/`gate` 并 `update`，不改结构。
