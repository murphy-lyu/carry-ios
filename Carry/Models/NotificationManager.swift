//
//  NotificationManager.swift
//  Carry

import Foundation
import UserNotifications

enum NotificationManager {

    private static let tripPrefix = "carry.trip."
    private static let reminderInfix = ".reminder."

    // MARK: - Permission

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Scheduling

    static func scheduleReminders(for trip: TripBundle) {
        cancelReminders(forTripId: trip.id)
        // 无日期「规划中」行程没有出发日，不排打包提醒（先清后不排 = 退回时也自动撤销）。
        guard !trip.isDateless else { return }
        for config in trip.reminderConfigs {
            scheduleReminder(for: trip, config: config)
        }
    }

    static func scheduleReminder(for trip: TripBundle, config: TripReminderConfig) {
        let now = Date()
        guard let fireDate = config.fireDate(relativeTo: trip.departureDate) else { return }
        // 行程出发日已过：不再排提醒（用户卸/重装等场景下的合理短路）
        guard trip.departureDate >= Calendar.current.startOfDay(for: now) else { return }

        let destination = trip.destinationCity.isEmpty ? trip.name : trip.destinationCity
        let (title, body) = notificationContent(
            daysBeforeDeparture: config.daysBeforeDeparture,
            tripName: trip.name,
            destination: destination
        )

        // C8 时区锁定：显式把 timeZone 写进 components。否则
        // UNCalendarNotificationTrigger 默认按"触发时系统时区"重新解析，
        // 跨时区飞行后通知时间会漂移（北京设的 9 点 → 落地纽约变 EST 9 点）。
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        comps.timeZone = TimeZone.current

        // C7 已过 fireDate 的降级：fireDate 已过但行程未到（如早 8 点编辑"出发当天 7 点"
        // 的提醒），不静默丢弃 → 60 秒后触发一次，让用户至少收到一次。
        let identifier = identifier(tripId: trip.id, configId: config.id)
        if fireDate > now {
            schedule(id: identifier, title: title, body: body, components: comps)
        } else {
            scheduleAfterInterval(id: identifier, title: title, body: body, interval: 60)
        }
    }

    /// 一次性 N 秒后触发（用于"已过 fireDate"的降级路径）
    private static func scheduleAfterInterval(id: String, title: String, body: String, interval: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                CarryLogger.shared.log(.reminderScheduleFailed,
                    context: "fallback id=\(id) error=\(error.localizedDescription)")
            }
        }
    }

    private static func notificationContent(
        daysBeforeDeparture: Int,
        tripName: String,
        destination: String
    ) -> (title: String, body: String) {
        switch daysBeforeDeparture {
        case 0:
            return (
                String(format: String(localized: "notif.departureDay.title"), destination),
                String(localized: "notif.departureDay.body")
            )
        case 1:
            return (
                String(format: String(localized: "notif.1day.title"), tripName),
                String(localized: "notif.1day.body")
            )
        case 2:
            return (
                String(format: String(localized: "notif.2days.title"), tripName),
                String(localized: "notif.2days.body")
            )
        case 3:
            return (
                String(format: String(localized: "notif.3days.title"), tripName),
                String(localized: "notif.3days.body")
            )
        case 7:
            return (
                String(format: String(localized: "notif.1week.title"), tripName),
                String(localized: "notif.1week.body")
            )
        case 14:
            return (
                String(format: String(localized: "notif.2weeks.title"), tripName),
                String(localized: "notif.2weeks.body")
            )
        default:
            return (
                String(format: String(localized: "notif.ndays.title"), tripName, daysBeforeDeparture),
                String(localized: "notif.ndays.body")
            )
        }
    }

    static func cancelReminders(forTripId id: UUID) {
        let prefix = tripPrefix + id.uuidString
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    static func cancelReminder(tripId: UUID, configId: UUID) {
        let id = identifier(tripId: tripId, configId: configId)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

#if DEBUG
    static func scheduleTestNotifications() {
        let center = UNUserNotificationCenter.current()
        let debugPrefix = "carry.debug.notif."
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(debugPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }

        let cases: [(days: Int, delay: TimeInterval)] = [
            (0, 4), (1, 9), (2, 14), (3, 19), (7, 24), (14, 29), (5, 34)
        ]
        let tripName = String(localized: "debug.notif.trip_name")
        let destination = String(localized: "debug.notif.destination")

        for (days, delay) in cases {
            let (title, body) = notificationContent(
                daysBeforeDeparture: days,
                tripName: tripName,
                destination: destination
            )
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(debugPrefix)\(days)d",
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
    }
#endif

    // MARK: - Private

    private static func identifier(tripId: UUID, configId: UUID) -> String {
        tripPrefix + tripId.uuidString + reminderInfix + configId.uuidString
    }

    /// 从打包提醒通知的 identifier 中提取 tripId。
    /// 格式：carry.trip.{uuid}.reminder.{uuid}
    static func tripId(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(tripPrefix) else { return nil }
        let afterPrefix = identifier.dropFirst(tripPrefix.count)
        guard let infixRange = afterPrefix.range(of: reminderInfix) else { return nil }
        let uuidString = String(afterPrefix[..<infixRange.lowerBound])
        return UUID(uuidString: uuidString)
    }

    private static func schedule(
        id: String,
        title: String,
        body: String,
        components: DateComponents
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                CarryLogger.shared.log(.reminderScheduleFailed, context: "error=\(error.localizedDescription)")
            } else {
                CarryLogger.shared.log(.reminderScheduled)
            }
        }
    }
}
