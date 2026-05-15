//
//  NotificationManager.swift
//  Carry
//

import Foundation
import UserNotifications

/// Manages local notification scheduling for trips.
/// Strategy: 2 fixed reminders per trip — 3 days before at 09:00,
/// and on departure day at 07:00.
enum NotificationManager {

    private enum Kind: String {
        case threeDaysBefore = "t-3d"
        case departureDay = "t-0d"
    }

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

        let now = Date()
        let calendar = Calendar.current

        if let threeDaysBefore = calendar.date(byAdding: .day, value: -3, to: trip.departureDate) {
            var comps = calendar.dateComponents([.year, .month, .day], from: threeDaysBefore)
            comps.hour = 9
            comps.minute = 0
            if let fireDate = calendar.date(from: comps), fireDate > now {
                schedule(
                    id: identifier(tripId: trip.id, kind: .threeDaysBefore),
                    title: String(format: String(localized: "notif.threeDays.title"), trip.name),
                    body: String(localized: "notif.threeDays.body"),
                    components: comps
                )
            }
        }

        var dayComps = calendar.dateComponents([.year, .month, .day], from: trip.departureDate)
        dayComps.hour = 7
        dayComps.minute = 0
        if let fireDate = calendar.date(from: dayComps), fireDate > now {
            let destination = trip.destinationCity.isEmpty ? trip.name : trip.destinationCity
            schedule(
                id: identifier(tripId: trip.id, kind: .departureDay),
                title: String(format: String(localized: "notif.departureDay.title"), destination),
                body: String(localized: "notif.departureDay.body"),
                components: dayComps
            )
        }
    }

    static func cancelReminders(forTripId id: UUID) {
        let ids = [
            identifier(tripId: id, kind: .threeDaysBefore),
            identifier(tripId: id, kind: .departureDay)
        ]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Private

    private static func identifier(tripId: UUID, kind: Kind) -> String {
        "carry.trip.\(tripId.uuidString).\(kind.rawValue)"
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
