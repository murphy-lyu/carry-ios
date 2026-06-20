//
//  NotificationManager.swift
//  Carry

import Foundation
import UserNotifications

enum NotificationManager {

    private static let tripPrefix = "carry.trip."

    // MARK: - Permission

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // 原实现 try? 直接吞错；失败时记日志便于排查（例如配置文件缺权限项等系统级错误）
            CarryLogger.shared.log(.reminderScheduleFailed,
                context: "requestAuthorization threw: \(error.localizedDescription)")
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // 注：权限被拒后排的通知由系统层静默忽略；本类的 `schedule(...)` add 回调
    // 会捕获 add error 并写入 reminderScheduleFailed 日志，足够排查。无需在
    // schedule 前再做一次 sync 状态检查（iOS 没有 sync API）。

    // MARK: - Scheduling

    /// 通知中心总入口（spec: notification-center.md）：先清该行程所有类别，再按全局设置逐类重排。
    /// 所有 identifier 以 `carry.trip.{id}` 开头，故 `cancelReminders` 一次清空全类别。
    static func scheduleReminders(for trip: TripBundle) {
        cancelReminders(forTripId: trip.id)
        guard !trip.isDateless else { return }   // 无日期行程无锚点，全类别不排
        let now = Date()
        scheduleDeparture(for: trip, now: now)
        schedulePackProgress(for: trip, now: now)
        scheduleTransport(for: trip, now: now)
        scheduleLodging(for: trip, now: now)
        scheduleDailySummary(for: trip, now: now)
    }

    // MARK: A 类——出发日锚

    /// 出发提醒（含打包催促）。档位读全局设置（Settings 唯一真相源，无 per-trip 快照）。
    private static func scheduleDeparture(for trip: TripBundle, now: Date) {
        guard ReminderPreferences.departureEnabled else { return }
        guard trip.departureDate >= Calendar.current.startOfDay(for: now) else { return }  // 出发已过整体短路
        let destination = trip.destinationCity.isEmpty ? trip.name : trip.destinationCity
        let h = ReminderPreferences.defaultMinutes / 60, m = ReminderPreferences.defaultMinutes % 60
        for offset in ReminderPreferences.enabledOffsets.sorted() {
            let cfg = TripReminderConfig(daysBeforeDeparture: offset, hour: h, minute: m)
            guard let fireDate = cfg.fireDate(relativeTo: trip.departureDate) else { continue }
            let (title, body) = notificationContent(daysBeforeDeparture: offset, tripName: trip.name, destination: destination)
            scheduleAt(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).depart.\(offset)",
                       title: title, body: body, allowImminentFallback: true, now: now)
        }
    }

    /// 打包进度提醒：出发前 N 天，仅「有物品且未打完」才发「还剩 X 件」。打完不吵。
    private static func schedulePackProgress(for trip: TripBundle, now: Date) {
        guard ReminderPreferences.packProgressEnabled else { return }
        guard trip.departureDate >= Calendar.current.startOfDay(for: now) else { return }
        let remaining = trip.totalCount - trip.packedCount
        guard trip.totalCount > 0, remaining > 0 else { return }
        let h = ReminderPreferences.defaultMinutes / 60, m = ReminderPreferences.defaultMinutes % 60
        let cfg = TripReminderConfig(daysBeforeDeparture: ReminderPreferences.packProgressOffsetDays, hour: h, minute: m)
        guard let fireDate = cfg.fireDate(relativeTo: trip.departureDate) else { return }
        let title = String(format: NSLocalizedString("notif.pack.title", comment: ""), trip.name)
        let body = String.localizedStringWithFormat(NSLocalizedString("notif.pack.body", comment: ""), remaining)
        scheduleAt(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).pack",
                   title: title, body: body, allowImminentFallback: false, now: now)
    }

    // MARK: B 类——事件时刻锚

    private static func scheduleTransport(for trip: TripBundle, now: Date) {
        for seg in trip.safeItineraryDays.flatMap({ $0.sortedSegments }) {
            guard !seg.remindersMuted else { continue }   // 逐段静音
            let isCar = seg.mode == .carRental
            guard (isCar ? ReminderPreferences.carRentalEnabled : ReminderPreferences.transportEnabled) else { continue }
            let leads = isCar ? ReminderPreferences.carRentalLeadsMinutes : ReminderPreferences.transportLeadsMinutes
            guard !leads.isEmpty else { continue }
            scheduleTransportEvent(trip: trip, seg: seg, isReturn: false, leads: leads, now: now)
            if isCar { scheduleTransportEvent(trip: trip, seg: seg, isReturn: true, leads: leads, now: now) }
        }
    }

    private static func scheduleTransportEvent(trip: TripBundle, seg: TransportSegment, isReturn: Bool, leads: [Int], now: Date) {
        let dayOrder = isReturn ? seg.arriveDayOrder : seg.departDayOrder
        let minutes = isReturn ? seg.arriveLocalMinutes : seg.departLocalMinutes
        let tzId = isReturn ? seg.toTimeZoneId : seg.fromTimeZoneId
        guard let eventDate = absoluteDate(tripDeparture: trip.departureDate, dayOrder: dayOrder, minutes: minutes, tzId: tzId) else { return }
        let role = isReturn ? "dropoff" : "depart"
        let tz = TimeZone(identifier: tzId) ?? .current
        for lead in leads {
            let fireDate = eventDate.addingTimeInterval(TimeInterval(-lead * 60))
            let (title, body) = transportContent(seg: seg, isReturn: isReturn, leadMinutes: lead)
            scheduleAt(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).transport.\(seg.id.uuidString).\(role).\(lead)",
                       title: title, body: body, allowImminentFallback: false, now: now, tz: tz)
        }
    }

    private static func scheduleLodging(for trip: TripBundle, now: Date) {
        guard ReminderPreferences.lodgingEnabled else { return }
        for stay in trip.safeLodgingStays {
            guard !stay.remindersMuted else { continue }   // 逐条静音
            let inMin = stay.checkInMinutes >= 0 ? stay.checkInMinutes : ReminderPreferences.lodgingCheckInMinutes
            if let inDate = absoluteDate(tripDeparture: trip.departureDate, dayOrder: stay.checkInDayOrder, minutes: inMin, tzId: "") {
                let (t, b) = lodgingContent(stay: stay, isCheckOut: false)
                scheduleAt(inDate, id: "\(tripPrefix)\(trip.id.uuidString).lodging.\(stay.id.uuidString).in",
                           title: t, body: b, allowImminentFallback: false, now: now)
            }
            let outClock = stay.checkOutMinutes >= 0 ? stay.checkOutMinutes : 11 * 60
            if let outDate = absoluteDate(tripDeparture: trip.departureDate, dayOrder: stay.checkOutDayOrder, minutes: outClock, tzId: "") {
                let fireDate = outDate.addingTimeInterval(TimeInterval(-ReminderPreferences.lodgingCheckOutLeadMinutes * 60))
                let (t, b) = lodgingContent(stay: stay, isCheckOut: true)
                scheduleAt(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).lodging.\(stay.id.uuidString).out",
                           title: t, body: b, allowImminentFallback: false, now: now)
            }
        }
    }

    // MARK: C 类——行程日锚

    private static func scheduleDailySummary(for trip: TripBundle, now: Date) {
        guard ReminderPreferences.dailySummaryEnabled else { return }
        let mins = ReminderPreferences.dailySummaryMinutes
        for day in trip.safeItineraryDays {
            let count = (day.stops?.count ?? 0) + day.sortedSegments.count
            guard count > 0 else { continue }
            guard let fireDate = absoluteDate(tripDeparture: trip.departureDate, dayOrder: day.sortOrder, minutes: mins, tzId: "") else { continue }
            let title = String(format: NSLocalizedString("notif.daily.title", comment: ""),
                               trip.destinationCity.isEmpty ? trip.name : trip.destinationCity)
            let body = String.localizedStringWithFormat(NSLocalizedString("notif.daily.body", comment: ""), count)
            scheduleAt(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).daily.\(day.sortOrder)",
                       title: title, body: body, allowImminentFallback: false, now: now)
        }
    }

    // MARK: 通用排期 + 事件绝对时刻

    /// 把「行程出发日 + dayOrder 天 + 当天分钟 + 事件时区」算成绝对 Date（minutes<0 视为未设→nil）。
    private static func absoluteDate(tripDeparture: Date, dayOrder: Int, minutes: Int, tzId: String) -> Date? {
        guard minutes >= 0 else { return nil }
        let tz = TimeZone(identifier: tzId) ?? .current
        guard let dayDate = Calendar.current.date(byAdding: .day, value: dayOrder, to: tripDeparture) else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: dayDate)  // 年月日按行程布局推
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        comps.timeZone = tz
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: comps)
    }

    /// 排一条：fireDate 在事件时区锁定（防跨时区漂移，沿用 C8）；已过 fireDate 时按
    /// `allowImminentFallback` 决定 60s 兜底（出发提醒）或直接跳过（事件类）。
    private static func scheduleAt(_ fireDate: Date, id: String, title: String, body: String,
                                   allowImminentFallback: Bool, now: Date, tz: TimeZone = .current) {
        if fireDate > now {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            comps.timeZone = tz
            schedule(id: id, title: title, body: body, components: comps)
        } else if allowImminentFallback {
            scheduleAfterInterval(id: id, title: title, body: body, interval: 60)
        }
    }

    // MARK: 事件类文案

    /// 提前量可读文案（"3 小时" / "1 天" / "45 分钟"）。
    private static func leadText(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return String.localizedStringWithFormat(NSLocalizedString("notif.lead.days", comment: ""), minutes / 1440) }
        if minutes % 60 == 0 { return String.localizedStringWithFormat(NSLocalizedString("notif.lead.hours", comment: ""), minutes / 60) }
        return String.localizedStringWithFormat(NSLocalizedString("notif.lead.minutes", comment: ""), minutes)
    }

    private static func transportContent(seg: TransportSegment, isReturn: Bool, leadMinutes: Int) -> (String, String) {
        let lead = leadText(leadMinutes)
        if seg.mode == .carRental {
            let company = seg.carrier.isEmpty ? NSLocalizedString("notif.car.fallback", comment: "") : seg.carrier
            let titleKey = isReturn ? "notif.car.dropoff.title" : "notif.car.pickup.title"
            let bodyKey = isReturn ? "notif.car.dropoff.body" : "notif.car.pickup.body"
            return (String(format: NSLocalizedString(titleKey, comment: ""), company),
                    String(format: NSLocalizedString(bodyKey, comment: ""), lead))
        }
        let label = seg.number.isEmpty
            ? (seg.carrier.isEmpty ? NSLocalizedString("notif.transport.generic", comment: "") : seg.carrier)
            : seg.number
        let route = [seg.fromName, seg.toName].filter { !$0.isEmpty }.joined(separator: " → ")
        let title = String(format: NSLocalizedString("notif.transport.title", comment: ""), label)
        let body = route.isEmpty
            ? String(format: NSLocalizedString("notif.transport.body", comment: ""), lead)
            : String(format: NSLocalizedString("notif.transport.body.route", comment: ""), lead, route)
        return (title, body)
    }

    private static func lodgingContent(stay: LodgingStay, isCheckOut: Bool) -> (String, String) {
        let name = stay.name.isEmpty ? NSLocalizedString("notif.lodging.fallback", comment: "") : stay.name
        let titleKey = isCheckOut ? "notif.lodging.checkout.title" : "notif.lodging.checkin.title"
        let bodyKey = isCheckOut ? "notif.lodging.checkout.body" : "notif.lodging.checkin.body"
        return (String(format: NSLocalizedString(titleKey, comment: ""), name),
                NSLocalizedString(bodyKey, comment: ""))
    }

    /// 一次性 N 秒后触发（用于"已过 fireDate"的降级路径）
    private static func scheduleAfterInterval(id: String, title: String, body: String, interval: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                CarryLogger.shared.log(.reminderScheduleFailed,
                    context: "fallback id=\(id) error=\(error.localizedDescription)")
            }
        }
    }

    private static func notificationContent(
        daysBeforeDeparture: Int,
        tripName: String,
        destination: String
    ) -> (title: String, body: String) {
        switch daysBeforeDeparture {
        case 0:
            return (
                String(format: String(localized: "notif.departureDay.title"), destination),
                String(localized: "notif.departureDay.body")
            )
        case 1:
            return (
                String(format: String(localized: "notif.1day.title"), tripName),
                String(localized: "notif.1day.body")
            )
        case 2:
            return (
                String(format: String(localized: "notif.2days.title"), tripName),
                String(localized: "notif.2days.body")
            )
        case 3:
            return (
                String(format: String(localized: "notif.3days.title"), tripName),
                String(localized: "notif.3days.body")
            )
        case 7:
            return (
                String(format: String(localized: "notif.1week.title"), tripName),
                String(localized: "notif.1week.body")
            )
        case 14:
            return (
                String(format: String(localized: "notif.2weeks.title"), tripName),
                String(localized: "notif.2weeks.body")
            )
        default:
            return (
                String(format: String(localized: "notif.ndays.title"), tripName, daysBeforeDeparture),
                String(localized: "notif.ndays.body")
            )
        }
    }

    static func cancelReminders(forTripId id: UUID) {
        let prefix = tripPrefix + id.uuidString
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

#if DEBUG
    static func scheduleTestNotifications() {
        let center = UNUserNotificationCenter.current()
        let debugPrefix = "carry.debug.notif."
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(debugPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }

        let cases: [(days: Int, delay: TimeInterval)] = [
            (0, 4), (1, 9), (2, 14), (3, 19), (7, 24), (14, 29), (5, 34)
        ]
        let tripName = String(localized: "debug.notif.trip_name")
        let destination = String(localized: "debug.notif.destination")

        for (days, delay) in cases {
            let (title, body) = notificationContent(
                daysBeforeDeparture: days,
                tripName: tripName,
                destination: destination
            )
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(debugPrefix)\(days)d",
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
    }
#endif

    // MARK: - Private

    /// 从任意类别通知的 identifier 中提取 tripId（所有命名空间都形如 `carry.trip.{uuid}.…`）。
    static func tripId(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(tripPrefix) else { return nil }
        let afterPrefix = identifier.dropFirst(tripPrefix.count)
        // tripId = 紧跟前缀的 UUID（到下一个 '.' 为止）
        let uuidString = String(afterPrefix.prefix { $0 != "." })
        return UUID(uuidString: uuidString)
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
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                CarryLogger.shared.log(.reminderScheduleFailed, context: "error=\(error.localizedDescription)")
            } else {
                CarryLogger.shared.log(.reminderScheduled)
            }
        }
    }
}
