//
//  CalendarManager.swift
//  Carry

import EventKit
import UIKit
import Foundation
import SwiftUI

// MARK: - CalendarOverlayEvent（只读叠加事件值类型，spec: itinerary-calendar-overlay.md）

/// 从系统日历读出、铺进行程时间轴的只读事件。**永不进 model / 分享 / 导出 / 备份**——
/// 它只是视图层的临时值，由构造保证不外泄（详见 spec 隐私红线）。
struct CalendarOverlayEvent: Identifiable {
    let id: String          // EKEvent.eventIdentifier
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let tint: Color         // 事件所属日历的颜色
    let startMinutes: Int   // 当天起始分钟（自午夜），全天事件 = -1
    let calendarTitle: String   // 所属日历名（详情浮层头部，如「中国大陆节假日」）
    let location: String        // 事件地点（可空）
    let notes: String           // 事件备注（可空）
    let url: String             // 事件链接（会议/预订/详情，可空）——只读详情里作可点链接行
    let timeZoneId: String      // 事件时区 IANA（可空，定时事件展示用）
}

@MainActor
final class CalendarManager {

    static let shared = CalendarManager()
    private init() {}

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private static let addedIdsKey = "calendarAddedTripIds"
    private static let calendarTitle = "Carry"

    // 日历叠加层（spec: itinerary-calendar-overlay.md）
    static let overlayEnabledKey = "calendar_overlay_enabled"
    static let overlayCalendarIDsKey = "calendar_overlay_calendar_ids"
    static let overlayInitializedKey = "calendar_overlay_initialized"

    static func overlaySelectedCalendarIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: overlayCalendarIDsKey) ?? [])
    }

    /// 当前选中；**首次**（从未初始化）默认勾选「只读公共日历」——节假日这类不可编辑、非生日的订阅日历。
    /// 理由：法定节假日是公开信息（零隐私），默认显示既安全又用「已有一个勾」教会用户这些可勾选；
    /// 个人/可编辑日历、生日日历默认**不**勾（隐私最稳）。之后尊重用户选择（含清空）。
    func selectedOrDefaultOverlayIDs() -> Set<String> {
        if defaults.bool(forKey: Self.overlayInitializedKey) {
            return Self.overlaySelectedCalendarIDs()
        }
        // 只读 + 非生日 + **标题确为节假日** 才默认勾选。EventKit 无「isHoliday」API，
        // 仅靠 `!allowsContentModifications` 会把 TickTick / Tripsy 等只读订阅日历一并勾上
        // （已踩坑），故再按系统节假日日历名（覆盖 9 语言）收窄，其余留给用户自己勾。
        let defaultIDs = store.calendars(for: .event)
            .filter { $0.title != Self.calendarTitle }
            .filter { !$0.allowsContentModifications && $0.type != .birthday }
            .filter { Self.looksLikeHolidayCalendar($0.title) }
            .map { $0.calendarIdentifier }
        let set = Set(defaultIDs)
        defaults.set(Array(set), forKey: Self.overlayCalendarIDsKey)
        defaults.set(true, forKey: Self.overlayInitializedKey)
        return set
    }

    /// 是否为系统「节假日」日历。EventKit 无节假日标志，按标题关键词识别（覆盖 app 支持的
    /// 9 语言系统节假日日历名 + 常见写法），把法定节假日从其它只读订阅日历（TickTick / Tripsy 等）中分出。
    private static func looksLikeHolidayCalendar(_ title: String) -> Bool {
        let lower = title.lowercased()
        let keywords = ["holiday", "假日", "假期", "节日", "節日", "祝日", "공휴일",
                        "feiertag", "férié", "festivo", "feriado"]
        return keywords.contains { lower.contains($0) }
    }

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
        guard let tripUrl = URL(string: "carry://trip/\(trip.id.uuidString)") else {
            throw CalendarError.dateNormalizationFailed
        }

        // ── 1. 行程全天事件（现有逻辑保持不变）──
        let startComps = greg.dateComponents([.year, .month, .day], from: trip.departureDate)
        guard let dayStart = greg.date(from: startComps),
              let dayEnd   = greg.date(byAdding: .day, value: max(trip.days, 1), to: dayStart) else {
            throw CalendarError.dateNormalizationFailed
        }
        let tripEvent = EKEvent(eventStore: store)
        tripEvent.title     = "✈️ \(trip.name)"
        tripEvent.isAllDay  = true
        tripEvent.startDate = dayStart
        tripEvent.endDate   = dayEnd
        var tripNotes: [String] = []
        if !trip.destinationCity.isEmpty { tripNotes.append(trip.destinationCity) }
        if !trip.dateRange.isEmpty        { tripNotes.append(trip.dateRange) }
        if !tripNotes.isEmpty { tripEvent.notes = tripNotes.joined(separator: "\n") }
        tripEvent.url      = tripUrl
        tripEvent.calendar = cal
        do {
            try store.save(tripEvent, span: .thisEvent, commit: false)
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed,
                context: "tripEvent '\(trip.name)': \(error.localizedDescription)")
            throw error
        }

        // ── 2. 行程内事件：交通段 + 地点（按天遍历）──
        var itineraryEventCount = 0
        for day in trip.safeItineraryDays {
            // 交通段
            for seg in day.sortedSegments where seg.departLocalMinutes >= 0 {
                if let ev = makeTransportEvent(seg: seg, trip: trip, cal: cal, url: tripUrl) {
                    do {
                        try store.save(ev, span: .thisEvent, commit: false)
                        itineraryEventCount += 1
                    } catch {
                        CarryLogger.shared.log(.calendarItineraryEventFailed,
                            context: "transport \(seg.modeRaw) id=\(seg.id): \(error.localizedDescription)")
                    }
                }
            }
            // 地点（仅有时间的）
            for stop in day.sortedStops where stop.plannedStartMinutes >= 0 {
                if let ev = makeStopEvent(stop: stop, day: day, trip: trip, cal: cal, url: tripUrl) {
                    do {
                        try store.save(ev, span: .thisEvent, commit: false)
                        itineraryEventCount += 1
                    } catch {
                        CarryLogger.shared.log(.calendarItineraryEventFailed,
                            context: "stop '\(stop.name)' id=\(stop.id): \(error.localizedDescription)")
                    }
                }
            }
        }

        // ── 3. 住宿（全天跨度 + 可选入住/退房定时）──
        for stay in trip.safeLodgingStays {
            let eventsForStay = makeLodgingEvents(stay: stay, trip: trip, cal: cal, url: tripUrl)
            for ev in eventsForStay {
                do {
                    try store.save(ev, span: .thisEvent, commit: false)
                    itineraryEventCount += 1
                } catch {
                    CarryLogger.shared.log(.calendarItineraryEventFailed,
                        context: "lodging '\(stay.name)' id=\(stay.id): \(error.localizedDescription)")
                }
            }
        }

        // 统一提交（减少 IO 次数）
        try store.commit()

        if itineraryEventCount > 0 {
            CarryLogger.shared.log(.calendarItineraryEventsSaved,
                context: "trip='\(trip.name)' count=\(itineraryEventCount)")
        }
    }

    // MARK: - 交通段事件构建

    private func makeTransportEvent(seg: TransportSegment, trip: TripBundle,
                                    cal: EKCalendar, url: URL) -> EKEvent? {
        guard let startDate = seg.absoluteDeparture(tripDeparture: trip.departureDate) else { return nil }
        let endDate = seg.absoluteArrival(tripDeparture: trip.departureDate)
            ?? startDate.addingTimeInterval(3600)

        let ev = EKEvent(eventStore: store)
        ev.startDate = startDate
        ev.endDate   = endDate
        ev.isAllDay  = false
        ev.timeZone  = TimeZone(identifier: seg.fromTimeZoneId.isEmpty
            ? trip.primaryTimeZoneId : seg.fromTimeZoneId) ?? .current
        ev.url       = url
        ev.calendar  = cal

        let mode = seg.mode
        let emoji = Self.transportEmoji(mode)

        // 标题
        if mode == .carRental {
            // 租车：「🚗 取车 · {vendor} · {pickupName}」—— 无路线格式，语义是「取车地点/公司」
            var parts: [String] = [NSLocalizedString("calendar.transport.pickup", comment: "")]
            if !seg.carrier.isEmpty  { parts.append(seg.carrier) }
            let pickup = seg.fromName.isEmpty ? seg.fromCode : seg.fromName
            if !pickup.isEmpty { parts.append(pickup) }
            ev.title = "🚗 " + parts.joined(separator: " · ")
        } else {
            let fromShort = seg.fromCode.isEmpty ? seg.fromName : seg.fromCode
            let toShort   = seg.toCode.isEmpty   ? seg.toName   : seg.toCode
            let route     = [fromShort, toShort].filter { !$0.isEmpty }.joined(separator: "→")
            if !seg.number.isEmpty {
                ev.title = "\(emoji) \(seg.number)\(route.isEmpty ? "" : " \(route)")"
            } else if !seg.carrier.isEmpty {
                ev.title = "\(emoji) \(seg.carrier)\(route.isEmpty ? "" : " \(route)")"
            } else {
                ev.title = "\(emoji) \(route.isEmpty ? seg.fromName : route)"
            }
        }

        // location
        let loc = seg.fromAddress.isEmpty ? seg.fromName : seg.fromAddress
        if !loc.isEmpty { ev.location = loc }

        // notes
        var lines: [String] = []
        if !seg.carrier.isEmpty { lines.append(seg.carrier) }
        let fullRoute = [seg.fromName, seg.toName].filter { !$0.isEmpty }.joined(separator: " → ")
        if !fullRoute.isEmpty { lines.append(fullRoute) }
        let terminals = [seg.fromTerminal, seg.toTerminal].filter { !$0.isEmpty }.joined(separator: " → ")
        if !terminals.isEmpty { lines.append("Terminal: \(terminals)") }
        // 航班专属
        if mode == .flight {
            if !seg.seat.isEmpty            { lines.append("Seat: \(seg.seat)") }
            if !seg.cabinClass.isEmpty,
               let cc = CabinClass(rawValue: seg.cabinClass) {
                lines.append("Class: \(NSLocalizedString(cc.localizationKey, comment: ""))")
            }
            if !seg.eticketNumber.isEmpty   { lines.append("E-Ticket: \(seg.eticketNumber)") }
            if !seg.aircraftType.isEmpty    { lines.append("Aircraft: \(seg.aircraftType)") }
        }
        // 地面/水路
        if mode == .train || mode == .bus || mode == .ferry {
            if !seg.routeName.isEmpty    { lines.append(seg.routeName) }
            if !seg.coachNumber.isEmpty  { lines.append("Coach: \(seg.coachNumber)") }
            if !seg.seat.isEmpty         { lines.append("Seat: \(seg.seat)") }
            if !seg.seatClass.isEmpty    { lines.append("Class: \(seg.seatClass)") }
            if !seg.serviceType.isEmpty  { lines.append("Service: \(seg.serviceType)") }
        }
        // 租车专属
        if mode == .carRental {
            if !seg.vehicleModel.isEmpty  { lines.append("Vehicle: \(seg.vehicleModel)") }
            if !seg.licensePlate.isEmpty  { lines.append("Plate: \(seg.licensePlate)") }
            if !seg.toName.isEmpty        { lines.append("Return: \(seg.toName)") }
            if !seg.phone.isEmpty         { lines.append("Phone: \(seg.phone)") }
        }
        if !seg.confirmationCode.isEmpty { lines.append("Confirmation: \(seg.confirmationCode)") }
        if !seg.note.isEmpty             { lines.append(seg.note) }
        if !lines.isEmpty { ev.notes = lines.joined(separator: "\n") }

        return ev
    }

    // MARK: - 地点事件构建

    private func makeStopEvent(stop: ItineraryStop, day: ItineraryDay, trip: TripBundle,
                                cal: EKCalendar, url: URL) -> EKEvent? {
        let tzId = stop.effectiveTimeZoneId(trip: trip)
        guard let startDate = TransportSegment.itineraryAbsoluteDate(
            tripDeparture: trip.departureDate,
            dayOrder: day.sortOrder,
            minutes: stop.plannedStartMinutes,
            tzId: tzId) else { return nil }
        let duration: TimeInterval = stop.stayMinutes > 0
            ? TimeInterval(stop.stayMinutes * 60) : 3600
        let endDate = startDate.addingTimeInterval(duration)

        let ev = EKEvent(eventStore: store)
        ev.startDate = startDate
        ev.endDate   = endDate
        ev.isAllDay  = false
        ev.timeZone  = TimeZone(identifier: tzId) ?? .current
        ev.url       = url
        ev.calendar  = cal

        let emoji = Self.stopEmoji(stop.category)
        ev.title = "\(emoji) \(stop.name.isEmpty ? NSLocalizedString("calendar.stop.untitled", comment: "") : stop.name)"

        if !stop.address.isEmpty { ev.location = stop.address }

        var lines: [String] = []
        if !stop.address.isEmpty { lines.append(stop.address) }
        if !stop.phone.isEmpty   { lines.append("Phone: \(stop.phone)") }
        if !stop.note.isEmpty    { lines.append(stop.note) }
        if !lines.isEmpty { ev.notes = lines.joined(separator: "\n") }

        return ev
    }

    // MARK: - 住宿事件构建

    private func makeLodgingEvents(stay: LodgingStay, trip: TripBundle,
                                   cal: EKCalendar, url: URL) -> [EKEvent] {
        var events: [EKEvent] = []
        let greg = Calendar.current
        let tzId = stay.effectiveTimeZoneId(trip: trip)

        let notesLines: [String] = {
            var ls: [String] = []
            if stay.checkInMinutes >= 0 {
                let timeStr = String(format: "%02d:%02d", stay.checkInMinutes / 60, stay.checkInMinutes % 60)
                ls.append("Check-in: Day \(stay.checkInDayOrder + 1) \(timeStr)")
            } else {
                ls.append("Check-in: Day \(stay.checkInDayOrder + 1)")
            }
            if stay.checkOutMinutes >= 0 {
                let timeStr = String(format: "%02d:%02d", stay.checkOutMinutes / 60, stay.checkOutMinutes % 60)
                ls.append("Check-out: Day \(stay.checkOutDayOrder + 1) \(timeStr)")
            } else {
                ls.append("Check-out: Day \(stay.checkOutDayOrder + 1)")
            }
            if !stay.confirmationCode.isEmpty { ls.append("Confirmation: \(stay.confirmationCode)") }
            if !stay.phone.isEmpty            { ls.append("Phone: \(stay.phone)") }
            if !stay.note.isEmpty             { ls.append(stay.note) }
            return ls
        }()
        let notesStr = notesLines.joined(separator: "\n")
        let locationStr = stay.address.isEmpty ? stay.name : stay.address

        // 全天跨度事件（入住日午夜 → 退房日午夜，exclusive）
        if let checkInBase  = greg.date(byAdding: .day, value: stay.checkInDayOrder,  to: trip.departureDate),
           let checkOutBase = greg.date(byAdding: .day, value: stay.checkOutDayOrder, to: trip.departureDate) {
            let checkInMidnight  = greg.startOfDay(for: checkInBase)
            let checkOutMidnight = greg.startOfDay(for: checkOutBase)
            let allDay = EKEvent(eventStore: store)
            allDay.title     = "🏨 \(stay.name)"
            allDay.isAllDay  = true
            allDay.startDate = checkInMidnight
            allDay.endDate   = checkOutMidnight
            if !locationStr.isEmpty { allDay.location = locationStr }
            allDay.notes     = notesStr
            allDay.url       = url
            allDay.calendar  = cal
            events.append(allDay)
        }

        // 入住定时事件
        if stay.checkInMinutes >= 0,
           let ciDate = TransportSegment.itineraryAbsoluteDate(
               tripDeparture: trip.departureDate,
               dayOrder: stay.checkInDayOrder,
               minutes: stay.checkInMinutes,
               tzId: tzId) {
            let ev = EKEvent(eventStore: store)
            ev.title     = "🏨 \(NSLocalizedString("calendar.lodging.checkin", comment: "")) · \(stay.name)"
            ev.startDate = ciDate
            ev.endDate   = ciDate.addingTimeInterval(3600)
            ev.isAllDay  = false
            ev.timeZone  = TimeZone(identifier: tzId) ?? .current
            if !locationStr.isEmpty { ev.location = locationStr }
            ev.notes     = notesStr
            ev.url       = url
            ev.calendar  = cal
            events.append(ev)
        }

        // 退房定时事件
        if stay.checkOutMinutes >= 0,
           let coDate = TransportSegment.itineraryAbsoluteDate(
               tripDeparture: trip.departureDate,
               dayOrder: stay.checkOutDayOrder,
               minutes: stay.checkOutMinutes,
               tzId: tzId) {
            let ev = EKEvent(eventStore: store)
            ev.title     = "🏨 \(NSLocalizedString("calendar.lodging.checkout", comment: "")) · \(stay.name)"
            ev.startDate = coDate
            ev.endDate   = coDate.addingTimeInterval(3600)
            ev.isAllDay  = false
            ev.timeZone  = TimeZone(identifier: tzId) ?? .current
            if !locationStr.isEmpty { ev.location = locationStr }
            ev.notes     = notesStr
            ev.url       = url
            ev.calendar  = cal
            events.append(ev)
        }

        return events
    }

    // MARK: - Emoji helpers

    private static func transportEmoji(_ mode: TransportMode) -> String {
        switch mode {
        case .flight:    return "✈️"
        case .train:     return "🚄"
        case .bus:       return "🚌"
        case .ferry:     return "⛴️"
        case .carRental: return "🚗"
        case .other:     return "🚐"
        }
    }

    private static func stopEmoji(_ category: StopCategory) -> String {
        switch category {
        case .sightseeing: return "🏛️"
        case .food:        return "🍽️"
        case .activity:    return "🎯"
        case .shopping:    return "🛍️"
        case .lodging:     return "🏨"
        default:           return "📍"
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
        // 宽窗口（-2 年 ~ +5 年）覆盖所有可能的事件（含未来很久才出发的行程）。
        // EKEventStore 没有「按 URL 直接查询」的 API，只能按时间范围 predicate 拿全量再 filter。
        let now = Date()
        let cal0 = Calendar.current
        guard let start = cal0.date(byAdding: .year, value: -2, to: now),
              let end   = cal0.date(byAdding: .year, value:  5, to: now) else { return }
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

    /// 删除 Carry 写入的**全部**日历事件（用于「抹掉所有数据」，spec: erase-all-data.md）。
    /// 直接移除整个 Carry 日历容器、连带其所有事件一次清掉，并清空 addedIds；按标题查找、不创建
    /// （避免无日历时被 find-or-create 反而新建）。无权限 / 无该日历 → 仅清 addedIds。
    func removeAllCarryEvents() {
        saveAddedIds([])
        guard hasAccess,
              let cal = store.calendars(for: .event).first(where: { $0.title == Self.calendarTitle })
        else { return }
        do {
            try store.removeCalendar(cal, commit: true)
        } catch {
            CarryLogger.shared.log(.calendarSaveFailed, context: "removeAll: \(error.localizedDescription)")
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

    // MARK: - Overlay（只读日历事件，spec: itinerary-calendar-overlay.md）

    /// 可选日历列表（供设置多选）。排除 Carry 自己写入的日历。
    func availableCalendars() -> [(id: String, title: String, tint: Color)] {
        store.calendars(for: .event)
            .filter { $0.title != Self.calendarTitle }
            .map { (id: $0.calendarIdentifier, title: $0.title, tint: Color(cgColor: $0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// 行程区间 [start, end) 内、所选日历的只读事件。
    /// **排除 Carry 自写事件**（`carry://` scheme）避免回环；无权限 / 未选日历 → 空。
    func overlayEvents(start: Date, end: Date, calendarIDs: Set<String>) -> [CalendarOverlayEvent] {
        guard hasAccess, !calendarIDs.isEmpty else { return [] }
        let cals = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        let greg = Calendar.current
        return store.events(matching: predicate)
            .filter { $0.url?.scheme != "carry" }
            .map { ev in
                let c = greg.dateComponents([.hour, .minute], from: ev.startDate)
                return CalendarOverlayEvent(
                    id: ev.eventIdentifier ?? "\(ev.title ?? "")-\(ev.startDate.timeIntervalSinceReferenceDate)",
                    title: ev.title ?? "",
                    startDate: ev.startDate,
                    endDate: ev.endDate,
                    isAllDay: ev.isAllDay,
                    tint: Color(cgColor: ev.calendar.cgColor),
                    startMinutes: ev.isAllDay ? -1 : (c.hour ?? 0) * 60 + (c.minute ?? 0),
                    calendarTitle: ev.calendar.title,
                    location: ev.location ?? "",
                    notes: ev.notes ?? "",
                    // carry:// 事件已在上面被滤除，这里的 url 必是外部链接（会议/预订/详情）。
                    url: ev.url?.scheme == "carry" ? "" : (ev.url?.absoluteString ?? ""),
                    timeZoneId: ev.timeZone?.identifier ?? ""
                )
            }
    }

}

private enum CalendarError: Error {
    case dateNormalizationFailed
}
