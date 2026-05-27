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
        for config in trip.reminderConfigs {
            scheduleReminder(for: trip, config: config)
        }
    }

    static func scheduleReminder(for trip: TripBundle, config: TripReminderConfig) {
        let now = Date()
        guard let fireDate = config.fireDate(relativeTo: trip.departureDate),
              fireDate > now else { return }

        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let destination = trip.destinationCity.isEmpty ? trip.name : trip.destinationCity
        let (title, body) = notificationContent(
            daysBeforeDeparture: config.daysBeforeDeparture,
            tripName: trip.name,
            destination: destination
        )

        schedule(
            id: identifier(tripId: trip.id, configId: config.id),
            title: title,
            body: body,
            components: comps
        )
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
        UNUserNotificationCenter.current().add(request)
    }
}
