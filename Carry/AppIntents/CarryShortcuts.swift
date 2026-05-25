//
//  CarryShortcuts.swift
//  Carry
//

import AppIntents
import SwiftData

// MARK: - Shared helpers

private extension UserDefaults {
    static let shortcutActionKey = "carry_shortcut_action"
    static let shortcutTripIdKey = "carry_shortcut_trip_id"

    /// Store a "navigate to existing trip" shortcut action.
    func setShortcutOpenTrip(_ id: UUID) {
        set("open_trip", forKey: Self.shortcutActionKey)
        set(id.uuidString, forKey: Self.shortcutTripIdKey)
    }

    /// Store a "create new trip" shortcut action.
    func setShortcutCreateTrip() {
        set("create_trip", forKey: Self.shortcutActionKey)
    }
}

/// Returns the trip whose departure date is closest to today (past or future).
private func nearestTrip() throws -> TripBundle? {
    let context = ModelContext(CarryApp.container)
    let trips = try context.fetch(FetchDescriptor<TripBundle>())
    return trips.min(by: {
        abs($0.departureDate.timeIntervalSinceNow) < abs($1.departureDate.timeIntervalSinceNow)
    })
}

// MARK: - 1. New Trip

struct CreateTripIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut.create_trip.title"
    static var description = IntentDescription("shortcut.create_trip.description")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.setShortcutCreateTrip()
        return .result()
    }
}

// MARK: - 2. Nearest Trip (by departure date)

struct OpenNearestTripIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut.nearest_trip.title"
    static var description = IntentDescription("shortcut.nearest_trip.description")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        if let trip = try nearestTrip() {
            UserDefaults.standard.setShortcutOpenTrip(trip.id)
        } else {
            UserDefaults.standard.setShortcutCreateTrip()
        }
        return .result()
    }
}

// MARK: - 3. Continue Packing (last opened trip)

struct ContinuePackingIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut.continue_packing.title"
    static var description = IntentDescription("shortcut.continue_packing.description")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Use the last trip the user explicitly opened, fall back to nearest.
        if let idStr = UserDefaults.standard.string(forKey: "carry_last_opened_trip"),
           let id = UUID(uuidString: idStr) {
            UserDefaults.standard.setShortcutOpenTrip(id)
        } else if let trip = try nearestTrip() {
            UserDefaults.standard.setShortcutOpenTrip(trip.id)
        } else {
            UserDefaults.standard.setShortcutCreateTrip()
        }
        return .result()
    }
}

// MARK: - App Shortcuts Provider

struct CarryAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateTripIntent(),
            phrases: [
                "New trip in \(.applicationName)",
                "Create a trip in \(.applicationName)",
                "Plan a trip with \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("New Trip"),
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: OpenNearestTripIntent(),
            phrases: [
                "My next trip in \(.applicationName)",
                "Upcoming trip in \(.applicationName)",
                "Open my trip in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Nearest Trip"),
            systemImageName: "airplane.departure"
        )
        AppShortcut(
            intent: ContinuePackingIntent(),
            phrases: [
                "Continue packing in \(.applicationName)",
                "Open packing list in \(.applicationName)",
                "My packing list in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Packing List"),
            systemImageName: "checklist"
        )
    }
}
