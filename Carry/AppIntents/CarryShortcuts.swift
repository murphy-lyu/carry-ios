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

    @MainActor
    func perform() async throws -> some IntentResult {
        CarryLogger.shared.log(.siriShortcutExecuted, context: "action=create_trip")
        UserDefaults.standard.setShortcutCreateTrip()
        return .result()
    }
}

// MARK: - 2. Nearest Trip (by departure date)

struct OpenNearestTripIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut.nearest_trip.title"
    static var description = IntentDescription("shortcut.nearest_trip.description")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let trip = try nearestTrip() {
            CarryLogger.shared.log(.siriShortcutExecuted, context: "action=open_nearest_trip")
            UserDefaults.standard.setShortcutOpenTrip(trip.id)
        } else {
            CarryLogger.shared.log(.siriShortcutExecuted, context: "action=open_nearest_trip fallback=create")
            UserDefaults.standard.setShortcutCreateTrip()
        }
        return .result()
    }
}

// MARK: - 3. Footprint — open the visited-countries map

struct ShowFootprintIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut.footprint.title"
    static var description = IntentDescription("shortcut.footprint.description")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CarryLogger.shared.log(.siriShortcutExecuted, context: "action=show_footprint")
        UserDefaults.standard.set("show_map", forKey: "carry_shortcut_action")
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
            systemImageName: "plus"
        )
        AppShortcut(
            intent: OpenNearestTripIntent(),
            phrases: [
                "My next trip in \(.applicationName)",
                "Upcoming trip in \(.applicationName)",
                "Open my trip in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Nearest Trip"),
            systemImageName: "suitcase.fill"
        )
        AppShortcut(
            intent: ShowFootprintIntent(),
            phrases: [
                "Show my footprint in \(.applicationName)",
                "Open travel map in \(.applicationName)",
                "My visited countries in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Footprint"),
            systemImageName: "globe.asia.australia.fill"
        )
    }
}
