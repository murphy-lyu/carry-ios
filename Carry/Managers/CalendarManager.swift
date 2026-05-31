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

    /// Adds events for a single upcoming trip. Returns true if written (or already added).
    @discardableResult
    func addTrip(_ trip: TripBundle, packHour: Int, packMinute: Int, includePackReminder: Bool = true) -> Bool {
        guard trip.departureDate >= Calendar.current.startOfDay(for: Date()) else { return false }
        var addedIds = loadAddedIds()
        let idString = trip.id.uuidString
        guard !addedIds.contains(idString) else { return true }
        guard let cal = carryCalendar else {
            CarryLogger.shared.log(.calendarSaveFailed, context: "carryCalendar=nil")
            return false
        }
        do {
            try writeEvents(for: trip, to: cal, packHour: packHour, packMinute: packMinute, includePackReminder: includePackReminder)
            addedIds.insert(idString)
            saveAddedIds(addedIds)
            return true
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed, context: "addTrip: \(error.localizedDescription)")
            return false
        }
    }

    /// Adds events for all upcoming trips not yet added. Returns count of trips written.
    @discardableResult
    func addAllUpcoming(_ trips: [TripBundle], packHour: Int, packMinute: Int, includePackReminder: Bool = true) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        guard let cal = carryCalendar else {
            CarryLogger.shared.log(.calendarSaveFailed, context: "carryCalendar=nil in addAllUpcoming")
            return 0
        }
        var addedIds = loadAddedIds()
        var written = 0
        for trip in trips where trip.departureDate >= today {
            let idString = trip.id.uuidString
            guard !addedIds.contains(idString) else { continue }
            do {
                try writeEvents(for: trip, to: cal, packHour: packHour, packMinute: packMinute, includePackReminder: includePackReminder)
                addedIds.insert(idString)
                written += 1
            } catch {
                CarryLogger.shared.log(.calendarSaveFailed, context: "\(trip.name): \(error.localizedDescription)")
            }
        }
        saveAddedIds(addedIds)
        return written
    }

    /// Debug: returns "title (source)" of the calendar we write to.
    var carryCalendarDebugInfo: String {
        guard let cal = carryCalendar else { return "nil" }
        return "\(cal.title) · \(cal.source?.title ?? "?") · \(cal.calendarIdentifier.prefix(8))"
    }

    func pendingCount(from trips: [TripBundle]) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        let addedIds = loadAddedIds()
        return trips.filter {
            $0.departureDate >= today && !addedIds.contains($0.id.uuidString)
        }.count
    }

    // MARK: - Carry calendar

    private var carryCalendar: EKCalendar? {
        if let existing = store.calendars(for: .event).first(where: { $0.title == Self.calendarTitle }) {
            return existing
        }
        guard let source = bestSource() else {
            CarryLogger.shared.log(.calendarSaveFailed, context: "no EKSource available; sources=\(store.sources.map { "\($0.title)/\($0.sourceType.rawValue)" })")
            return nil
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = Self.calendarTitle
        cal.source = source
        cal.cgColor = UIColor.systemOrange.cgColor
        do {
            try store.saveCalendar(cal, commit: true)
            return cal
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed, context: "saveCalendar: \(error.localizedDescription)")
            return nil
        }
    }

    private func bestSource() -> EKSource? {
        store.sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.defaultCalendarForNewEvents?.source
    }

    // MARK: - Event writing

    private func writeEvents(for trip: TripBundle, to cal: EKCalendar, packHour: Int, packMinute: Int, includePackReminder: Bool) throws {
        let greg = Calendar.current

        // All-day trip event.
        // startDate must be exact midnight; endDate is exclusive (3-day trip = +3 days).
        let startComps = greg.dateComponents([.year, .month, .day], from: trip.departureDate)
        guard let dayStart = greg.date(from: startComps),
              let dayEnd   = greg.date(byAdding: .day, value: max(trip.days, 1), to: dayStart) else {
            throw CalendarError.dateNormalizationFailed
        }

        #if DEBUG
        print("[CalendarManager] '\(trip.name)' departureDate=\(trip.departureDate) → dayStart=\(dayStart) dayEnd=\(dayEnd)")
        #endif

        let tripEvent = EKEvent(eventStore: store)
        tripEvent.title     = "✈️ \(trip.name)"
        tripEvent.isAllDay  = true
        tripEvent.startDate = dayStart
        tripEvent.endDate   = dayEnd
        var notes: [String] = []
        if !trip.destinationCity.isEmpty { notes.append(trip.destinationCity) }
        if !trip.dateRange.isEmpty        { notes.append(trip.dateRange) }
        if !notes.isEmpty { tripEvent.notes = notes.joined(separator: "\n") }
        tripEvent.url      = URL(string: "carry://trip/\(trip.id.uuidString)")
        tripEvent.calendar = cal
        do {
            try store.save(tripEvent, span: .thisEvent, commit: true)
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed, context: "tripEvent '\(trip.name)' dayStart=\(dayStart) dayEnd=\(dayEnd): \(error.localizedDescription)")
            throw error
        }

        // Pack reminder: day before departure at user-set time (optional).
        guard includePackReminder else { return }
        guard let packDay = greg.date(byAdding: .day, value: -1, to: dayStart) else { return }
        var comps = greg.dateComponents([.year, .month, .day], from: packDay)
        comps.hour   = packHour
        comps.minute = packMinute
        guard let packStart = greg.date(from: comps),
              let packEnd   = greg.date(byAdding: .minute, value: 30, to: packStart) else { return }

        let packEvent = EKEvent(eventStore: store)
        packEvent.title     = String(format: NSLocalizedString("calendar.event.pack.title", comment: ""), trip.name)
        packEvent.startDate = packStart
        packEvent.endDate   = packEnd
        packEvent.notes     = packingListNotes(for: trip)
        packEvent.addAlarm(EKAlarm(relativeOffset: 0))
        packEvent.url      = URL(string: "carry://trip/\(trip.id.uuidString)")
        packEvent.calendar = cal
        do {
            try store.save(packEvent, span: .thisEvent, commit: true)
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed, context: "packEvent '\(trip.name)' packStart=\(packStart): \(error.localizedDescription)")
            throw error
        }
    }

    private func packingListNotes(for trip: TripBundle) -> String? {
        let sections = (trip.sections ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { section -> String? in
                let items = section.sortedItems.map { item in
                    "· \(item.name) × \(item.quantity)"
                }
                guard !items.isEmpty else { return nil }
                return section.title.isEmpty
                    ? items.joined(separator: "\n")
                    : "\(section.title)\n" + items.joined(separator: "\n")
            }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    // MARK: - Persistence

    func clearAddedIds() {
        defaults.removeObject(forKey: Self.addedIdsKey)
    }

    private func loadAddedIds() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.addedIdsKey) ?? [])
    }

    private func saveAddedIds(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: Self.addedIdsKey)
    }
}

private enum CalendarError: Error {
    case dateNormalizationFailed
}
