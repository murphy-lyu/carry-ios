//
//  LiveActivityManager.swift
//  Carry
//

import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

/// 管理打包清单 Live Activity 的生命周期（启动 / 更新 / 结束）。
///
/// 触发逻辑：
/// - 用户在 Settings 开启「锁屏打包进度」开关后，打开行程打包清单时自动启动。
/// - 多行程并发时，以当前打开的行程为准；若系统已有其他行程的 Activity 则先结束它。
/// - 每次物品 isPacked 状态变更时由调用方同步调用 update(for:)。
/// - 出发当天 / 行程删除时自动结束。
@MainActor
final class LiveActivityManager {

    static let shared = LiveActivityManager()
    private init() {}

    // MARK: - Settings key

    static let enabledKey = "liveActivityPackingEnabled"

    /// 仅在出发前这么多天内（且未出发）才激活 Live Activity。更远的行程点开清单
    /// 不应在锁屏常驻活动——Live Activity 面向临近 / 进行中的事件，远期行程无紧迫性。
    static let activationWindowDays = 7

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - 内部状态

    private var currentActivity: Activity<PackingActivityAttributes>?
    private var currentTripId: UUID?
    /// 锁：startIfNeeded 进行中（含 terminateAll 异步结束旧 activity 期间）拒绝并发重入。
    /// 防止用户快速点击行程 A → B 时，两次 request 在旧 end Task 完成前同时发起，
    /// 撞 ActivityKit 单 attribute 上限。
    private var isStarting: Bool = false

    // MARK: - 交通 LA 状态（spec: widget-transit-live-activity.md）

    /// 出行日「下一程」LA 的主开关 key。控制自动起（A）与显式起（B）。
    static let transitEnabledKey = "liveActivityTransitEnabled"
    /// 出发前多少小时内开始追踪「下一程」（自动起 A 的时间窗）。
    static let transitWindowHours = 24
    /// 到达后保留多久再结束（让「已抵达」态留片刻）。
    static let arrivalGraceMinutes = 60

    /// 主开关：未显式设置时默认 **开**（出行日是 Live Activity 最高价值场景）。
    var isTransitEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.transitEnabledKey) as? Bool ?? true
    }

    /// 用户「划掉了自动出现的下一程卡」的交通段 id 集合（spec: widget-transit-live-activity.md）。
    /// 根因：交通 LA 只剩自动起（A），用户对单程的唯一退出手段是**在锁屏上手动划除**；A 若不记住这个动作，
    /// 回前台会把它重新起起来、覆盖用户意图（「划掉又冒出来」）。检测靠 `reconcileDismissedTransit`：
    /// 我们记下「意图展示的段」，A 运行时若发现它已不在系统活跃 LA 里、又非我们主动结束 → 判定用户划掉、记此集合并跳过。
    /// 只存活跃段（在 `startTransitIfNeeded` 里按现存段剪枝、不无限增长）。
    static let dismissedTransitKey = "liveActivityTransitDismissed"
    private var dismissedTransitSegmentIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.dismissedTransitKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.dismissedTransitKey) }
    }

    /// 「我们当前意图展示的交通段」id（跨启动持久化）。startTransit 成功起/重连即写；任何**我们主动**结束
    /// 该段即清。A 运行时对账：若它非空、但系统里已无对应活跃 LA → 只可能是用户在锁屏手动划除（含 App 被杀期间划的）
    /// → 记入 dismissed、清空本值。这是「划掉又冒出来」的根因修复锚点。
    static let intendedTransitKey = "liveActivityTransitIntended"
    private var intendedTransitSegment: String? {
        get { UserDefaults.standard.string(forKey: Self.intendedTransitKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.intendedTransitKey) }
    }

    private var currentTransitActivity: Activity<TransportActivityAttributes>?
    private var currentTransitSegmentId: UUID?
    private var currentTransitTripId: UUID?
    private var isStartingTransit: Bool = false

    // MARK: - 启动

    /// 若开关开启且条件满足，为指定行程启动 Live Activity。
    func startIfNeeded(for trip: TripBundle) {
        // 并发保护：上一次 startIfNeeded 触发的 terminateAll 异步 end 尚未完成期间，
        // 拒绝新的 start，避免两次 Activity.request 撞 ActivityKit 上限。
        guard !isStarting else { return }
        guard isEnabled else { return }
        guard !trip.isDateless else { return }   // 无日期行程无倒计时，不激活 Live Activity
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // 仅为临近出发的行程激活：出发前 activationWindowDays 天内、且未出发。
        // 远期行程（如几个月后）点开清单不应在锁屏常驻 Live Activity（无紧迫性）。
        let calendar = Calendar.current
        let daysUntilDeparture = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: trip.departureDate)
        ).day ?? 0
        guard daysUntilDeparture >= 0, daysUntilDeparture <= Self.activationWindowDays else { return }

        // 同一行程已在运行，无需重复启动
        if let current = currentActivity,
           currentTripId == trip.id,
           current.activityState == .active { return }

        let allItems = trip.safeSections
            .flatMap { $0.items ?? [] }
            .filter { !$0.name.isEmpty }
        let total = allItems.count
        guard total > 0 else { return }

        let packed = allItems.filter { $0.isPacked }.count
        let attributes = PackingActivityAttributes(tripId: trip.id)
        let state = PackingActivityAttributes.ContentState(
            packedItems: packed,
            totalItems: total,
            isCompleted: packed == total,
            tripName: trip.name,
            destinationCity: trip.destinationCity.isEmpty ? trip.name : trip.destinationCity,
            departureDate: trip.departureDate
        )

        // 加锁串行执行：await 真正等所有残留 Activity 结束，再 request 新的。
        // 否则 terminateAll 的异步 end Task 与紧随其后的同步 request 之间存在 race，
        // 旧 activity 还没真正 end 就 request → 撞 ActivityKit 单 attribute 上限。
        isStarting = true
        let newTripId = trip.id
        Task { @MainActor in
            defer { self.isStarting = false }
            await self.terminateAllAndWait()
            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: nil),
                    pushType: nil
                )
                self.currentActivity = activity
                self.currentTripId = newTripId
                CarryLogger.shared.log(.liveActivityStarted, context: "trip=\(newTripId)")
            } catch {
                CarryLogger.shared.log(.liveActivityStartFailed, context: error.localizedDescription)
            }
        }
    }

    // MARK: - 更新

    /// 物品打包状态变更时调用，同步更新锁屏进度。
    func update(for trip: TripBundle) {
        guard let activity = currentActivity,
              currentTripId == trip.id,
              activity.activityState == .active else { return }

        let allItems = trip.safeSections
            .flatMap { $0.items ?? [] }
            .filter { !$0.name.isEmpty }
        let total = allItems.count
        let packed = allItems.filter { $0.isPacked }.count

        let state = PackingActivityAttributes.ContentState(
            packedItems: packed,
            totalItems: total,
            isCompleted: total > 0 && packed == total,
            tripName: trip.name,
            destinationCity: trip.destinationCity.isEmpty ? trip.name : trip.destinationCity,
            departureDate: trip.departureDate
        )
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    // MARK: - 结束

    /// 正常结束指定行程的 Activity（保留完成态片刻后消失）。
    func end(for tripId: UUID? = nil) {
        if let tripId, currentTripId != tripId { return }
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .default)
            currentActivity = nil
            currentTripId = nil
            CarryLogger.shared.log(.liveActivityEnded)
        }
    }

    /// 立即结束所有 Live Activity（抹掉数据 / 重置 / 删全部行程时使用）。打包 + 交通两类一并清。
    func endAll() {
        endAllPacking()
        endTransit()
    }

    /// 仅结束**打包** Live Activity（关闭「锁屏打包进度」开关时用——不可误伤交通 LA）。
    func endAllPacking() {
        let snapshot = Array(Activity<PackingActivityAttributes>.activities)
        currentActivity = nil
        currentTripId = nil
        Task {
            for activity in snapshot {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - 交通 LA：启动 / 结束（spec: widget-transit-live-activity.md）

    /// A（自动起）：App 进前台 / 启动时扫所有行程，为「最临近的下一程」起 LA。
    /// 候选条件：非无日期行程、交通段有出发时间、且「现在」落在 [出发前 transitWindowHours, 到达 + 宽限] 内
    /// （即出发临近、或正在途中）。多段取出发最早（最当下）的一段。
    func startTransitIfNeeded(trips: [TripBundle]) {
        guard isTransitEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        reconcileDismissedTransit()   // 先认领「用户划掉」的段，A 才不会把它重新起起来
        let now = Date()
        let windowEnd = now.addingTimeInterval(Double(Self.transitWindowHours) * 3600)
        // 剪枝：dismissed 只保留「当前仍存在的段」（防跨行程长期累积）。
        let allSegmentIds = Set(trips.flatMap { $0.safeItineraryDays.flatMap { $0.sortedSegments.map(\.id.uuidString) } })
        let dismissed = dismissedTransitSegmentIds.intersection(allSegmentIds)
        if dismissed != dismissedTransitSegmentIds { dismissedTransitSegmentIds = dismissed }

        var best: (trip: TripBundle, seg: TransportSegment, depart: Date)?
        for trip in trips where !trip.isDateless {
            // 粗筛：出发晚于时间窗末端 → 最早段（≥ departureDate）必都在窗外，跳过、不深扫。
            // （过去侧不剪：返程日晚间可能仍有回程航班，靠内层 now ≤ graceEnd 逐段过滤。）
            guard trip.departureDate <= windowEnd else { continue }
            for day in trip.safeItineraryDays {
                for seg in day.sortedSegments {
                    guard !dismissed.contains(seg.id.uuidString) else { continue }   // 用户显式停过 → 不自动重起
                    guard let dep = seg.absoluteDeparture(tripDeparture: trip.departureDate) else { continue }
                    let arr = seg.absoluteArrival(tripDeparture: trip.departureDate) ?? dep
                    let windowOpen = dep.addingTimeInterval(-Double(Self.transitWindowHours) * 3600)
                    let graceEnd = arr.addingTimeInterval(Double(Self.arrivalGraceMinutes) * 60)
                    guard now >= windowOpen, now <= graceEnd else { continue }
                    if best == nil || dep < best!.depart { best = (trip, seg, dep) }
                }
            }
        }
        guard let best else { return }   // 无候选 → 在途结束交给 endTransitIfArrived
        startTransit(for: best.seg, trip: best.trip)
    }

    /// A/B 共用启动器。B（显式）由详情页按钮调用，可在自动时间窗之外启动用户主动追踪的一程。
    func startTransit(for segment: TransportSegment, trip: TripBundle) {
        guard !isStartingTransit else { return }
        guard isTransitEnabled else { return }
        guard !trip.isDateless else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let dep = segment.absoluteDeparture(tripDeparture: trip.departureDate) else { return }
        let arr = segment.absoluteArrival(tripDeparture: trip.departureDate) ?? dep

        // 同一段已有活跃 Activity → 重连引用并 no-op（覆盖冷启动：系统持久化的 LA 仍在、但本进程
        // currentTransit* 为 nil；不重连会被下面 terminate+recreate 造成闪烁）。
        if let existing = Activity<TransportActivityAttributes>.activities.first(where: {
            $0.attributes.segmentId == segment.id && $0.activityState == .active
        }) {
            currentTransitActivity = existing
            currentTransitSegmentId = segment.id
            currentTransitTripId = trip.id
            intendedTransitSegment = segment.id.uuidString
            return
        }

        let number = segment.number.trimmingCharacters(in: .whitespaces)
        let carrier = segment.displayCarrier.trimmingCharacters(in: .whitespaces)
        let label = number.isEmpty ? carrier : number
        let state = TransportActivityAttributes.ContentState(
            modeRaw: segment.mode.rawValue,
            carrierAndNumber: label,
            fromCode: segment.fromCode, toCode: segment.toCode,
            fromName: segment.fromName, toName: segment.toName,
            departureDate: dep, arrivalDate: arr,
            fromTerminal: segment.fromTerminal, seat: segment.seat,
            liveStatus: nil, gate: nil, actualDepartureDate: nil
        )
        let attributes = TransportActivityAttributes(tripId: trip.id, segmentId: segment.id)
        let staleDate = arr.addingTimeInterval(Double(Self.arrivalGraceMinutes) * 60)

        isStartingTransit = true
        let segId = segment.id
        let tripId = trip.id
        Task { @MainActor in
            defer { self.isStartingTransit = false }
            await self.terminateAllTransitAndWait()
            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: staleDate),
                    pushType: nil
                )
                self.currentTransitActivity = activity
                self.currentTransitSegmentId = segId
                self.currentTransitTripId = tripId
                self.intendedTransitSegment = segId.uuidString
                CarryLogger.shared.log(.liveActivityStarted, context: "transit seg=\(segId)")
            } catch {
                CarryLogger.shared.log(.liveActivityStartFailed, context: "transit \(error.localizedDescription)")
            }
        }
    }

    /// A 运行时对账「用户是否在锁屏划掉了自动出现的下一程卡」（含 App 被杀期间划除）。
    /// 我们记下「意图展示的段」(`intendedTransitSegment`)；若它已不在系统活跃 LA 里、又非我们主动结束，
    /// 只可能是用户手动划除 → 记入 dismissed 让 A 不再自动重起，并清空意图值与本进程残留引用。
    /// （若该段已抵达、系统自然结束 LA，标记 dismissed 无害：抵达后已出 A 的时间窗，本就不会重起。）
    private func reconcileDismissedTransit() {
        guard let intended = intendedTransitSegment else { return }
        let stillLive = Activity<TransportActivityAttributes>.activities.contains {
            $0.attributes.segmentId.uuidString == intended && $0.activityState == .active
        }
        guard !stillLive else { return }
        dismissedTransitSegmentIds.insert(intended)
        intendedTransitSegment = nil
        if currentTransitSegmentId?.uuidString == intended {
            currentTransitActivity = nil
            currentTransitSegmentId = nil
            currentTransitTripId = nil
        }
    }

    /// 结束交通 LA（指定段 / 指定行程 / 全部交通）。我们主动结束 → 同步清「意图段」，
    /// 免得 `reconcileDismissedTransit` 把它误判成用户划除。
    func endTransit(segmentId: UUID? = nil, tripId: UUID? = nil) {
        let matches = Activity<TransportActivityAttributes>.activities.filter { a in
            if let segmentId { return a.attributes.segmentId == segmentId }
            if let tripId { return a.attributes.tripId == tripId }
            return true
        }
        let clearsCurrent = (segmentId == nil && tripId == nil)
            || (segmentId != nil && currentTransitSegmentId == segmentId)
            || (tripId != nil && currentTransitTripId == tripId)
        if clearsCurrent {
            currentTransitActivity = nil
            currentTransitSegmentId = nil
            currentTransitTripId = nil
            intendedTransitSegment = nil
        } else if let intended = intendedTransitSegment,
                  matches.contains(where: { $0.attributes.segmentId.uuidString == intended }) {
            intendedTransitSegment = nil
        }
        Task {
            for a in matches { await a.end(nil, dismissalPolicy: .default) }
            CarryLogger.shared.log(.liveActivityEnded, context: "transit")
        }
    }

    /// App 回前台时调用：已抵达（过到达 + 宽限）的交通 LA 自动结束。
    func endTransitIfArrived() {
        let now = Date()
        for a in Activity<TransportActivityAttributes>.activities where a.activityState == .active {
            let graceEnd = a.content.state.arrivalDate.addingTimeInterval(Double(Self.arrivalGraceMinutes) * 60)
            if now >= graceEnd {
                let segId = a.attributes.segmentId
                Task { await a.end(nil, dismissalPolicy: .default) }
                if intendedTransitSegment == segId.uuidString { intendedTransitSegment = nil }
                if currentTransitSegmentId == segId {
                    currentTransitActivity = nil; currentTransitSegmentId = nil; currentTransitTripId = nil
                }
            }
        }
    }

    private func terminateAllTransitAndWait() async {
        let snapshot = Array(Activity<TransportActivityAttributes>.activities)
        for a in snapshot { await a.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - 出发日检查

    /// App 进入前台时调用；若已经出发则结束 Activity。
    /// ⚠️ 修复点：
    /// 1. 原实现 `first(where: { _ in true })` 会拿到 activities 数组里的"任一条"，
    ///    多 Activity 残留时可能取错条目，用别的 trip 的 departureDate 判断当前 trip。
    ///    改为按 `attributes.tripId == currentTripId` 精确过滤。
    /// 2. 原实现按 `startOfDay` 比较"天"，跨时区飞行时本机时区切换会让天数计算偏移
    ///    一天（北京建的 trip departureDate 是北京午夜的 Date，到 EST 后 startOfDay
    ///    会回退一天 → 可能漏结束或提前结束）。改为按"departureDate 已过去"判断，
    ///    绝对秒数比较，跨时区无歧义。
    func endIfDeparted() {
        guard let tripId = currentTripId else { return }
        guard let activity = Activity<PackingActivityAttributes>.activities
            .first(where: { $0.attributes.tripId == tripId }) else { return }
        let departure = activity.content.state.departureDate
        // 出发当天保留 Activity（最有用的一天）；出发当天 24:00 后结束。
        let endOfDeparture = Calendar.current.date(byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: departure)) ?? departure
        if Date() >= endOfDeparture {
            end(for: tripId)
        }
    }

    // MARK: - Private

    // MARK: - 诊断（DEBUG）

    var diagnosticAuthEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

#if DEBUG
    var diagnosticActivityState: String {
        let activities = Activity<PackingActivityAttributes>.activities
        guard !activities.isEmpty else { return "❌ 系统中无 PackingActivityAttributes Activity" }
        let info = activities.enumerated().map { i, a in
            "[\(i)] state=\(a.activityState)"
        }.joined(separator: "\n")
        return "共 \(activities.count) 条:\n\(info)"
    }
#endif

#if DEBUG
    /// 强制启动并返回错误描述，供 Developer 页面诊断用。
    func forceStart(for trip: TripBundle) -> String {
        guard isEnabled else { return "❌ 开关未开启" }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return "❌ 系统未授权 Live Activity" }
        guard trip.departureDate >= Calendar.current.startOfDay(for: Date()) else { return "❌ 行程已出发（departureDate < today）" }

        terminateAll()

        let allItems = trip.safeSections
            .flatMap { $0.items ?? [] }
            .filter { !$0.name.isEmpty }
        let total = allItems.count
        guard total > 0 else { return "❌ 行程没有物品" }

        let packed = allItems.filter { $0.isPacked }.count
        let attributes = PackingActivityAttributes(tripId: trip.id)
        let state = PackingActivityAttributes.ContentState(
            packedItems: packed,
            totalItems: total,
            isCompleted: packed == total,
            tripName: trip.name,
            destinationCity: trip.destinationCity.isEmpty ? trip.name : trip.destinationCity,
            departureDate: trip.departureDate
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            currentTripId = trip.id
            return "✅ 已启动：\(trip.name)（\(packed)/\(total)）"
        } catch {
            return "❌ Activity.request 失败：\(error.localizedDescription)"
        }
    }
#endif

    private func terminateAll() {
        // 先快照，Task 只 end 调用时已存在的旧 Activity，
        // 避免 end 掉调用后立刻创建的新 Activity。
        let snapshot = Array(Activity<PackingActivityAttributes>.activities)
        Task {
            for activity in snapshot {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        currentActivity = nil
        currentTripId = nil
    }

    /// terminateAll 的 await 版本：等所有旧 Activity 真正 end 后才返回。
    /// 仅供 startIfNeeded 内部串行化使用，避免 end Task 与紧随其后的 request 竞争。
    private func terminateAllAndWait() async {
        let snapshot = Array(Activity<PackingActivityAttributes>.activities)
        currentActivity = nil
        currentTripId = nil
        for activity in snapshot {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

#endif
