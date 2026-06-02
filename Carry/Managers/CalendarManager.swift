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
            // 记日志，便于排查（原实现直接吞错，与"用户主动拒绝"无法区分）
            CarryLogger.shared.log(.calendarSaveFailed,
                context: "requestFullAccessToEvents threw: \(error.localizedDescription)")
            return false
        }
    }

    /// 返回当前权限状态，用于 UI 区分"未决定 / 已拒绝 / 已授权"以提供合适的引导。
    /// 例：被拒后引导用户去「设置 → Carry → 日历」开权限，而不是无差别提示"开启失败"。
    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    // MARK: - Add trips

    /// Adds events for a single upcoming trip. Returns true if written (or already added).
    @discardableResult
    func addTrip(_ trip: TripBundle) -> Bool {
        guard !trip.isDateless else { return false }   // 无日期行程不写日历
        guard trip.departureDate >= Calendar.current.startOfDay(for: Date()) else { return false }
        var addedIds = loadAddedIds()
        let idString = trip.id.uuidString
        guard !addedIds.contains(idString) else { return true }
        guard let cal = carryCalendar else {
            CarryLogger.shared.log(.calendarSaveFailed, context: "carryCalendar=nil")
            return false
        }
        do {
            try writeEvents(for: trip, to: cal)
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
    func addAllUpcoming(_ trips: [TripBundle]) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        guard let cal = carryCalendar else {
            CarryLogger.shared.log(.calendarSaveFailed, context: "carryCalendar=nil in addAllUpcoming")
            return 0
        }
        var addedIds = loadAddedIds()
        var written = 0
        for trip in trips where !trip.isDateless && trip.departureDate >= today {
            let idString = trip.id.uuidString
            guard !addedIds.contains(idString) else { continue }
            do {
                try writeEvents(for: trip, to: cal)
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

    private func writeEvents(for trip: TripBundle, to cal: EKCalendar) throws {
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
    }

    // MARK: - Persistence

    func clearAddedIds() {
        defaults.removeObject(forKey: Self.addedIdsKey)
    }

    /// 删除某行程在 Carry 日历里的所有事件（按 `carry://trip/{uuid}` URL 标记匹配）。
    /// 同时从已添加 ID 集合中移除——这样若用户后续重新启用同步或重新加入此行程，
    /// 不会被 `addTrip` 的"已加过"短路逻辑跳过。删除事件失败不抛出，仅记日志。
    func removeTrip(_ tripId: UUID) {
        let idString = tripId.uuidString
        var addedIds = loadAddedIds()
        defer {
            addedIds.remove(idString)
            saveAddedIds(addedIds)
        }
        guard let cal = carryCalendar else { return }
        // 用一个宽窗口（去年 → 明年+1）覆盖所有可能的事件。EKEventStore 没有"按 URL 直接查询"的 API。
        let now = Date()
        let cal0 = Calendar.current
        guard let start = cal0.date(byAdding: .year, value: -1, to: now),
              let end   = cal0.date(byAdding: .year, value:  2, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [cal])
        let matches = store.events(matching: predicate).filter {
            $0.url?.absoluteString.contains(idString) == true
        }
        for ev in matches {
            do {
                try store.remove(ev, span: .thisEvent, commit: false)
            } catch {
                CarryLogger.shared.log(.calendarSaveFailed,
                    context: "removeTrip ev='\(ev.title ?? "?")': \(error.localizedDescription)")
            }
        }
        do {
            try store.commit()
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed,
                context: "removeTrip commit: \(error.localizedDescription)")
        }
    }

    /// 更新某行程在 Carry 日历里的事件（先删除旧的，再按当前数据重写）。
    /// 仅在 `calendar_sync_enabled` 且行程未删除时调用；内部不再检查开关，调用方负责。
    func updateTrip(_ trip: TripBundle) {
        removeTrip(trip.id)
        // 从 addedIds 移除后，addTrip 内的"已加过"短路就不会拦截。
        _ = addTrip(trip)
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
