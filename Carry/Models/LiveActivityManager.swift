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

    /// 立即结束所有 Live Activity（关闭开关 / 行程删除时使用）。
    func endAll() {
        let snapshot = Array(Activity<PackingActivityAttributes>.activities)
        currentActivity = nil
        currentTripId = nil
        Task {
            for activity in snapshot {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
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
