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
    func addTrip(_ trip: TripBundle, packHour: Int, packMinute: Int) -> Bool {
        guard trip.departureDate >= Calendar.current.startOfDay(for: Date()) else { return false }
        var addedIds = loadAddedIds()
        let idString = trip.id.uuidString
        guard !addedIds.contains(idString) else { return true }
        guard let cal = carryCalendar else {
            CarryLogger.shared.log(.calendarSaveFailed, context: "carryCalendar=nil")
            return false
        }
        do {
            try writeEvents(for: trip, to: cal, packHour: packHour, packMinute: packMinute)
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
    func addAllUpcoming(_ trips: [TripBundle], packHour: Int, packMinute: Int) -> Int {
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
                try writeEvents(for: trip, to: cal, packHour: packHour, packMinute: packMinute)
                addedIds.insert(idString)
                written += 1
            } catch {
                CarryLogger.shared.log(.calendarSaveFailed, context: "\(trip.name): \(error.localizedDescription)")
            }
        }
        saveAddedIds(addedIds)
        return written
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

    private func writeEvents(for trip: TripBundle, to cal: EKCalendar, packHour: Int, packMinute: Int) throws {
        let greg = Calendar.current

        // All-day trip event.
        // startDate must be exact midnight; endDate is exclusive (3-day trip = +3 days).
        let startComps = greg.dateComponents([.year, .month, .day], from: trip.departureDate)
        guard let dayStart = greg.date(from: startComps),
              let dayEnd   = greg.date(byAdding: .day, value: max(trip.days, 1), to: dayStart) else {
            throw CalendarError.dateNormalizationFailed
        }

        let tripEvent = EKEvent(eventStore: store)
        tripEvent.title     = trip.name
        tripEvent.isAllDay  = true
        tripEvent.startDate = dayStart
        tripEvent.endDate   = dayEnd
        var notes: [String] = []
        if !trip.destinationCity.isEmpty { notes.append(trip.destinationCity) }
        if !trip.dateRange.isEmpty        { notes.append(trip.dateRange) }
        if !notes.isEmpty { tripEvent.notes = notes.joined(separator: "\n") }
        tripEvent.calendar = cal
        try store.save(tripEvent, span: .thisEvent, commit: true)

        // Pack reminder: day before departure at user-set time.
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
        packEvent.addAlarm(EKAlarm(relativeOffset: 0))
        packEvent.calendar  = cal
        try store.save(packEvent, span: .thisEvent, commit: true)
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
