//
//  TripReminderConfig.swift
//  Carry

import Foundation

struct TripReminderConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var daysBeforeDeparture: Int  // 0 = departure day
    var hour: Int
    var minute: Int = 0

    static let defaults: [TripReminderConfig] = [
        TripReminderConfig(daysBeforeDeparture: 3, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 0, hour: 7),
    ]

    static let presets: [TripReminderConfig] = [
        TripReminderConfig(daysBeforeDeparture: 0, hour: 7),
        TripReminderConfig(daysBeforeDeparture: 1, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 2, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 3, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 7, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 14, hour: 9),
    ]

    var timeString: String {
        String(format: "%02d:%02d", hour, minute)
    }

    func fireDate(relativeTo departureDate: Date) -> Date? {
        let calendar = Calendar.current
        guard let base = calendar.date(byAdding: .day, value: -daysBeforeDeparture, to: departureDate) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)
    }

    func isSameTrigger(as other: TripReminderConfig) -> Bool {
        daysBeforeDeparture == other.daysBeforeDeparture && hour == other.hour && minute == other.minute
    }
}
