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

    // MARK: - 启动

    /// 若开关开启且条件满足，为指定行程启动 Live Activity。
    func startIfNeeded(for trip: TripBundle) {
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

        // 结束其他行程残留的 Activity
        terminateAll()

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

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            currentTripId = trip.id
            CarryLogger.shared.log(.liveActivityStarted, context: "trip=\(trip.id)")
        } catch {
            CarryLogger.shared.log(.liveActivityStartFailed, context: error.localizedDescription)
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

    /// App 进入前台时调用；若已到出发日则结束 Activity。
    func endIfDeparted() {
        guard let tripId = currentTripId else { return }
        guard let activity = Activity<PackingActivityAttributes>.activities
            .first(where: { _ in true }) else { return }
        let calendar = Calendar.current
        let departure = activity.content.state.departureDate
        if calendar.startOfDay(for: departure) <= calendar.startOfDay(for: Date()) {
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
}

#endif
