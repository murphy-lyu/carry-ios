//
//  CalendarManager.swift
//  Carry

import EventKit
import UIKit
import Foundation

@MainActor
final class CalendarManager {

    static let shared = CalendarManager()
    private init() {}

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private static let addedIdsKey = "calendarAddedTripIds"
    private static let calendarTitle = "Carry"

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
        guard let cal = carryCalendar else { return }

        writeEvents(for: trip, to: cal, packHour: packHour, packMinute: packMinute)
        addedIds.insert(idString)
        saveAddedIds(addedIds)
    }

    /// Adds calendar events for all upcoming trips not yet added.
    func addAllUpcoming(_ trips: [TripBundle], packHour: Int, packMinute: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let cal = carryCalendar else { return }
        var addedIds = loadAddedIds()
        for trip in trips where trip.departureDate >= today {
            let idString = trip.id.uuidString
            guard !addedIds.contains(idString) else { continue }
            writeEvents(for: trip, to: cal, packHour: packHour, packMinute: packMinute)
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

    // MARK: - Carry calendar

    /// Returns the existing "Carry" calendar, or creates it if needed.
    private var carryCalendar: EKCalendar? {
        if let existing = store.calendars(for: .event).first(where: { $0.title == Self.calendarTitle }) {
            return existing
        }
        guard let source = bestSource() else { return nil }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = Self.calendarTitle
        cal.source = source
        cal.cgColor = UIColor.systemOrange.cgColor
        do {
            try store.saveCalendar(cal, commit: true)
            return cal
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed, context: error.localizedDescription)
            return nil
        }
    }

    /// Picks the best EKSource to attach a new calendar to.
    /// Prefer iCloud (calDAV titled "iCloud"), then any calDAV, then local.
    private func bestSource() -> EKSource? {
        let sources = store.sources
        return sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
            ?? sources.first(where: { $0.sourceType == .calDAV })
            ?? sources.first(where: { $0.sourceType == .local })
            ?? store.defaultCalendarForNewEvents?.source
    }

    // MARK: - Event writing

    private func writeEvents(for trip: TripBundle, to cal: EKCalendar, packHour: Int, packMinute: Int) {
        // 1. Full-day trip event
        let tripEvent = EKEvent(eventStore: store)
        tripEvent.title = trip.name
        tripEvent.isAllDay = true
        tripEvent.startDate = trip.departureDate
        tripEvent.endDate = Calendar.current.date(
            byAdding: .day, value: max(trip.days - 1, 0), to: trip.departureDate
        ) ?? trip.departureDate

        var notes: [String] = []
        if !trip.destinationCity.isEmpty { notes.append(trip.destinationCity) }
        if !trip.dateRange.isEmpty { notes.append(trip.dateRange) }
        if !notes.isEmpty { tripEvent.notes = notes.joined(separator: "\n") }
        tripEvent.calendar = cal

        do {
            try store.save(tripEvent, span: .thisEvent, commit: true)
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed, context: "trip_event: \(error.localizedDescription)")
        }

        // 2. Pack reminder event (day before departure at user-set time)
        guard let packDay = Calendar.current.date(byAdding: .day, value: -1, to: trip.departureDate) else { return }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: packDay)
        comps.hour = packHour
        comps.minute = packMinute
        guard let packStart = Calendar.current.date(from: comps),
              let packEnd = Calendar.current.date(byAdding: .minute, value: 30, to: packStart) else { return }

        let packTitle = String(format: NSLocalizedString("calendar.event.pack.title", comment: ""), trip.name)
        let packEvent = EKEvent(eventStore: store)
        packEvent.title = packTitle
        packEvent.startDate = packStart
        packEvent.endDate = packEnd
        packEvent.addAlarm(EKAlarm(relativeOffset: 0))
        packEvent.calendar = cal

        do {
            try store.save(packEvent, span: .thisEvent, commit: true)
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed, context: "pack_event: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    /// Clears the dedup record so all trips can be re-added on next enable.
    func clearAddedIds() {
        defaults.removeObject(forKey: Self.addedIdsKey)
    }

    private func loadAddedIds() -> Set<String> {
        let array = defaults.stringArray(forKey: Self.addedIdsKey) ?? []
        return Set(array)
    }

    private func saveAddedIds(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: Self.addedIdsKey)
    }
}
