//
//  CalendarManager.swift
//  Carry

import EventKit
import Foundation

@MainActor
final class CalendarManager {

    static let shared = CalendarManager()
    private init() {}

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private static let addedIdsKey = "calendarAddedTripIds"

    // MARK: - Permission

    /// Requests full calendar access. Returns true if granted.
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    // MARK: - Add trips

    /// Adds calendar events for a single trip (skips if already added).
    func addTrip(_ trip: TripBundle, packHour: Int, packMinute: Int) {
        guard trip.departureDate >= Calendar.current.startOfDay(for: Date()) else { return }
        var addedIds = loadAddedIds()
        let idString = trip.id.uuidString
        guard !addedIds.contains(idString) else { return }

        writeEvents(for: trip, packHour: packHour, packMinute: packMinute)
        addedIds.insert(idString)
        saveAddedIds(addedIds)
    }

    /// Adds calendar events for all upcoming trips not yet added.
    func addAllUpcoming(_ trips: [TripBundle], packHour: Int, packMinute: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        var addedIds = loadAddedIds()
        for trip in trips where trip.departureDate >= today {
            let idString = trip.id.uuidString
            guard !addedIds.contains(idString) else { continue }
            writeEvents(for: trip, packHour: packHour, packMinute: packMinute)
            addedIds.insert(idString)
        }
        saveAddedIds(addedIds)
    }

    /// Returns count of upcoming trips not yet added to calendar.
    func pendingCount(from trips: [TripBundle]) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        let addedIds = loadAddedIds()
        return trips.filter {
            $0.departureDate >= today && !addedIds.contains($0.id.uuidString)
        }.count
    }

    // MARK: - Private

    private func writeEvents(for trip: TripBundle, packHour: Int, packMinute: Int) {
        // 1. Full-day trip event
        let tripEvent = EKEvent(eventStore: store)
        tripEvent.title = trip.name
        tripEvent.isAllDay = true
        tripEvent.startDate = trip.departureDate
        tripEvent.endDate = Calendar.current.date(byAdding: .day, value: max(trip.days - 1, 0), to: trip.departureDate) ?? trip.departureDate

        var notes: [String] = []
        if !trip.destinationCity.isEmpty { notes.append(trip.destinationCity) }
        if !trip.dateRange.isEmpty { notes.append(trip.dateRange) }
        if !notes.isEmpty { tripEvent.notes = notes.joined(separator: "\n") }

        tripEvent.calendar = store.defaultCalendarForNewEvents
        try? store.save(tripEvent, span: .thisEvent)

        // 2. Pack reminder event (day before departure at user-set time)
        guard let packDay = Calendar.current.date(byAdding: .day, value: -1, to: trip.departureDate) else { return }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: packDay)
        components.hour = packHour
        components.minute = packMinute
        guard let packStart = Calendar.current.date(from: components),
              let packEnd = Calendar.current.date(byAdding: .minute, value: 30, to: packStart) else { return }

        let packTitle = String(format: NSLocalizedString("calendar.event.pack.title", comment: ""), trip.name)
        let packEvent = EKEvent(eventStore: store)
        packEvent.title = packTitle
        packEvent.startDate = packStart
        packEvent.endDate = packEnd
        packEvent.addAlarm(EKAlarm(relativeOffset: 0))
        packEvent.calendar = store.defaultCalendarForNewEvents
        try? store.save(packEvent, span: .thisEvent)
    }

    // MARK: - Persistence

    private func loadAddedIds() -> Set<String> {
        let array = defaults.stringArray(forKey: Self.addedIdsKey) ?? []
        return Set(array)
    }

    private func saveAddedIds(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: Self.addedIdsKey)
    }
}
