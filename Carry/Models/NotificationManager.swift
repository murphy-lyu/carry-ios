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

    /// iOS 每 App 挂起本地通知硬上限 64；超出系统只留最近的、其余静默丢弃（spec: notification-budget.md）。
    private static let systemPendingLimit = 64
    /// 不贴满 64，留缓冲给 DEBUG 测试通知 / 未来可能新增的其它本地通知。
    private static let safetyMargin = 4

    /// 一条待排通知的值类型快照。主线程构建（读 `@Model` 留主线程），`commit` 的 getPending 回调里
    /// 只用它（不碰 `@Model`，避免 off-main 访问）。
    private struct Candidate {
        let id: String
        let fireDate: Date        // 未来时刻；排序与预算依据。已过期的提醒不入候选（直接丢弃）
        let title: String
        let body: String
        let tz: TimeZone
    }

    /// 通知中心总入口（spec: notification-center.md / notification-budget.md）：跨**所有行程**收集候选 →
    /// 按触发时间排序卡全局 64 预算 → 竞态安全提交。单行程独立调度已不成立（卡全局预算需全局视野）。
    static func reschedule(trips: [TripBundle]) {
        let now = Date()
        var candidates: [Candidate] = []
        // 跳过：① 无日期行程（无锚点）；② remindersEnabled==false 的行程——同行者分享 / Tripsy 导入的行程
        //    刻意把它设 false（导入别人的行程不该向你推送）。此处是唯一收口点：冷启动 / 回前台都经 reschedule，
        //    必须在这里 honor 该标志，否则 TripStore 里的 per-trip 守卫会被无条件全局重排绕过（已踩坑）。
        for trip in trips where !trip.isDateless && trip.remindersEnabled {
            collectDeparture(trip, now: now, into: &candidates)
            collectPackProgress(trip, now: now, into: &candidates)
            collectTransport(trip, now: now, into: &candidates)
            collectLodging(trip, now: now, into: &candidates)
            collectDailySummary(trip, now: now, into: &candidates)
            collectWeatherAlerts(trip, now: now, into: &candidates)
        }
        commit(candidates: candidates)
    }

    /// 天气预警（spec: weather-aware-packing.md, Part 2）。结论由 WeatherAlertEvaluator 异步写入
    /// WeatherAlertStore，这里同步读取 → 进 64 候选集（确定性 id，不被差集误删）。出发前 1 天 18:00
    /// 提醒（设备本地时区，回扣打包）；天气时效性强，已过则当下兜底。
    private static func collectWeatherAlerts(_ trip: TripBundle, now: Date, into out: inout [Candidate]) {
        guard ReminderPreferences.weatherAlertsEnabled else { return }
        guard trip.departureDate >= Calendar.current.startOfDay(for: now) else { return }
        guard let payload = WeatherAlertStore.payload(for: trip.id),
              now.timeIntervalSince(payload.fetchedAt) < 24 * 3600 else { return }   // 结论太旧不发
        let cfg = TripReminderConfig(daysBeforeDeparture: 1, hour: 18, minute: 0)
        guard let fireDate = cfg.fireDate(relativeTo: trip.departureDate) else { return }
        let dest = trip.destinationCity.isEmpty ? trip.name : trip.destinationCity
        let (title, body) = weatherAlertContent(kind: payload.kind, destination: dest)
        makeCandidate(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).weather",
                      title: title, body: body, now: now, tz: .current, into: &out)
    }

    private static func weatherAlertContent(kind: WeatherAlertPayload.Kind, destination: String) -> (String, String) {
        let titleKey: String
        switch kind {
        case .severe: titleKey = "notif.weather.title.severe"
        case .snow:   titleKey = "notif.weather.title.snow"
        case .heat:   titleKey = "notif.weather.title.heat"
        case .cold:   titleKey = "notif.weather.title.cold"
        case .rain:   titleKey = "notif.weather.title.rain"
        }
        let title = NSLocalizedString(titleKey, comment: "")
        // 全本地化「回扣打包」文案 + 目的地（不直接塞可能是外语的官方摘要）。
        let body = String(format: NSLocalizedString("notif.weather.body", comment: ""), destination)
        return (title, body)
    }

    /// 全局预算提交（spec: notification-budget.md）。竞态规避：通知 id 确定性、`add()` 同 id 替换；删除集 =
    /// 「`carry.trip.` 前缀匹配 − 本次选中集」，与新增集天然不相交 → 无论回调早晚都不会误删刚排的通知。
    private static func commit(candidates: [Candidate]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let foreign = pending.filter { !$0.identifier.hasPrefix(tripPrefix) }.count
            let budget = max(0, systemPendingLimit - foreign - safetyMargin)
            // 近的优先：fireDate 升序取前 budget 条；超额的远端留到下次重排（临近 + 用户开 App）时补位。
            let chosen = candidates.sorted { $0.fireDate < $1.fireDate }.prefix(budget)
            let chosenIds = Set(chosen.map(\.id))
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(tripPrefix) && !chosenIds.contains($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            for c in chosen { add(c) }
#if DEBUG
            if candidates.count > chosen.count {
                CarryLogger.shared.log(.reminderScheduleFailed,
                    context: "budget trim: \(candidates.count - chosen.count) dropped (budget=\(budget), foreign=\(foreign))")
            }
#endif
        }
    }

    /// 把一条候选写入系统（calendar trigger 在事件时区锁定防跨时区漂移）。
    private static func add(_ c: Candidate) {
        let content = UNMutableNotificationContent()
        content.title = c.title
        content.body = c.body
        content.sound = .default
        var cal = Calendar(identifier: .gregorian); cal.timeZone = c.tz
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: c.fireDate)
        comps.timeZone = c.tz
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: c.id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                CarryLogger.shared.log(.reminderScheduleFailed, context: "id=\(c.id) error=\(error.localizedDescription)")
            } else {
                CarryLogger.shared.log(.reminderScheduled)
            }
        }
    }

    /// 构建一条候选：仅当 fireDate 在未来才入候选；已过触发时刻的提醒一律**丢弃**。
    /// （不再把过期提醒兜底成「now+60 秒」——那会让「错过的提前提醒」在你打开 App 时被复活、且每次重排重发，
    /// 既制造「今天出发」「明天见」自相矛盾、又导致每分钟重复推送。错过即过、不补发。）
    private static func makeCandidate(_ fireDate: Date, id: String, title: String, body: String,
                                      now: Date, tz: TimeZone, into out: inout [Candidate]) {
        guard fireDate > now else { return }
        out.append(Candidate(id: id, fireDate: fireDate, title: title, body: body, tz: tz))
    }

    // MARK: A 类——出发日锚

    /// 出发提醒（含打包催促）。档位读全局设置（Settings 唯一真相源，无 per-trip 快照）。
    private static func collectDeparture(_ trip: TripBundle, now: Date, into out: inout [Candidate]) {
        guard ReminderPreferences.departureEnabled else { return }
        guard trip.departureDate >= Calendar.current.startOfDay(for: now) else { return }  // 出发已过整体短路
        let destination = trip.destinationCity.isEmpty ? trip.name : trip.destinationCity
        let h = ReminderPreferences.defaultMinutes / 60, m = ReminderPreferences.defaultMinutes % 60
        for offset in ReminderPreferences.enabledOffsets.sorted() {
            let cfg = TripReminderConfig(daysBeforeDeparture: offset, hour: h, minute: m)
            guard let fireDate = cfg.fireDate(relativeTo: trip.departureDate) else { continue }
            let (title, body) = notificationContent(daysBeforeDeparture: offset, tripName: trip.name, destination: destination)
            // 出发倒计时按设备本地时区（在用户当下所在地的清晨提醒，非目的地时区）。
            makeCandidate(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).depart.\(offset)",
                          title: title, body: body, now: now, tz: .current, into: &out)
        }
    }

    /// 打包进度提醒：出发前 N 天，仅「有物品且未打完」才发「还剩 X 件」。打完不吵。
    private static func collectPackProgress(_ trip: TripBundle, now: Date, into out: inout [Candidate]) {
        guard ReminderPreferences.packProgressEnabled else { return }
        guard trip.departureDate >= Calendar.current.startOfDay(for: now) else { return }
        let remaining = trip.totalCount - trip.packedCount
        guard trip.totalCount > 0, remaining > 0 else { return }
        // 打包用**自己的时间**（默认出发前一晚 21:00），与出发提醒（清晨倒计时）分开。
        let mins = ReminderPreferences.packReminderMinutes
        let cfg = TripReminderConfig(daysBeforeDeparture: ReminderPreferences.packProgressOffsetDays, hour: mins / 60, minute: mins % 60)
        guard let fireDate = cfg.fireDate(relativeTo: trip.departureDate) else { return }
        let title = NSLocalizedString("notif.pack.title", comment: "")
        let body = String.localizedStringWithFormat(NSLocalizedString("notif.pack.body", comment: ""), remaining)
        makeCandidate(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).pack",
                      title: title, body: body, now: now, tz: .current, into: &out)
    }

    // MARK: B 类——事件时刻锚

    private static func collectTransport(_ trip: TripBundle, now: Date, into out: inout [Candidate]) {
        for seg in trip.safeItineraryDays.flatMap({ $0.sortedSegments }) {
            guard !seg.remindersMuted else { continue }   // 逐段静音
            let isCar = seg.mode == .carRental
            guard (isCar ? ReminderPreferences.carRentalEnabled : ReminderPreferences.transportEnabled) else { continue }
            let leads = isCar ? ReminderPreferences.carRentalLeadsMinutes : ReminderPreferences.transportLeadsMinutes
            guard !leads.isEmpty else { continue }
            // 租车只提醒「还车」（取车用户绝不会忘）；其它交通提醒出发。
            collectTransportEvent(trip: trip, seg: seg, isReturn: isCar, leads: leads, now: now, into: &out)
        }
    }

    private static func collectTransportEvent(trip: TripBundle, seg: TransportSegment, isReturn: Bool, leads: [Int], now: Date, into out: inout [Candidate]) {
        let dayOrder = isReturn ? seg.arriveDayOrder : seg.departDayOrder
        let minutes = isReturn ? seg.arriveLocalMinutes : seg.departLocalMinutes
        // 端点自身时区（航班=机场库，其它交通=地点搜索捕获）；缺失回退行程主时区（spec: itinerary-timezone.md）。
        let rawTz = isReturn ? seg.toTimeZoneId : seg.fromTimeZoneId
        let tzId = rawTz.isEmpty ? trip.primaryTimeZoneId : rawTz
        guard let eventDate = absoluteDate(tripDeparture: trip.departureDate, dayOrder: dayOrder, minutes: minutes, tzId: tzId) else { return }
        let role = isReturn ? "dropoff" : "depart"
        let tz = TimeZone(identifier: tzId) ?? .current
        for lead in leads {
            let fireDate = eventDate.addingTimeInterval(TimeInterval(-lead * 60))
            let (title, body) = transportContent(seg: seg, isReturn: isReturn, leadMinutes: lead)
            makeCandidate(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).transport.\(seg.id.uuidString).\(role).\(lead)",
                          title: title, body: body, now: now, tz: tz, into: &out)
        }
    }

    private static func collectLodging(_ trip: TripBundle, now: Date, into out: inout [Candidate]) {
        guard ReminderPreferences.lodgingEnabled else { return }
        for stay in trip.safeLodgingStays {
            guard !stay.remindersMuted else { continue }   // 逐条静音
            // 只提醒「退房」（入住用户不会忘）。退房当天清晨固定时刻触发（晨间唤醒，非提前量倒计时）。
            // 用酒店所在地时区（缺失回退行程主时区）——修掉原 tzId:"" 按设备时区算、跨时区错点触发的 bug。
            let tzId = stay.effectiveTimeZoneId(trip: trip)
            let tz = TimeZone(identifier: tzId) ?? .current
            // 罕见早退房：退房时刻早于清晨锚 → 落在退房时刻本身，避免「已退房才提醒」。
            let morning = ReminderPreferences.lodgingCheckOutMinutes
            let fireMins = stay.checkOutMinutes >= 0 ? min(morning, stay.checkOutMinutes) : morning
            guard let fireDate = absoluteDate(tripDeparture: trip.departureDate, dayOrder: stay.checkOutDayOrder, minutes: fireMins, tzId: tzId) else { continue }
            let (t, b) = lodgingContent(stay: stay)
            makeCandidate(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).lodging.\(stay.id.uuidString).out",
                          title: t, body: b, now: now, tz: tz, into: &out)
        }
    }

    // MARK: C 类——行程日锚

    private static func collectDailySummary(_ trip: TripBundle, now: Date, into out: inout [Candidate]) {
        guard ReminderPreferences.dailySummaryEnabled else { return }
        let mins = ReminderPreferences.dailySummaryMinutes
        for day in trip.safeItineraryDays {
            let count = (day.stops?.count ?? 0) + day.sortedSegments.count
            guard count > 0 else { continue }
            // 用当天代表时区（缺失回退行程主时区）——每日提醒在「当地的 mins 时刻」触发，而非设备时区。
            let tzId = day.representativeTimeZoneId(trip: trip)
            let tz = TimeZone(identifier: tzId) ?? .current
            guard let fireDate = absoluteDate(tripDeparture: trip.departureDate, dayOrder: day.sortOrder, minutes: mins, tzId: tzId) else { continue }
            let title = String(format: NSLocalizedString("notif.daily.title", comment: ""),
                               trip.destinationCity.isEmpty ? trip.name : trip.destinationCity)
            // 带出当天第一个安排,具体又有期待;取不到名字则退到无名版。
            let firstName = firstPlanName(day: day)
            let body = firstName.isEmpty
                ? String.localizedStringWithFormat(NSLocalizedString("notif.daily.body.noname", comment: ""), count)
                : String.localizedStringWithFormat(NSLocalizedString("notif.daily.body", comment: ""), count, firstName)
            makeCandidate(fireDate, id: "\(tripPrefix)\(trip.id.uuidString).daily.\(day.sortOrder)",
                          title: title, body: body, now: now, tz: tz, into: &out)
        }
    }

    /// 当天按 sortOrder 最靠前的安排名(地点取名、交通取班次/承运方);无名返回空串。
    private static func firstPlanName(day: ItineraryDay) -> String {
        var items: [(Int, String)] = (day.stops ?? []).map { ($0.sortOrder, $0.name) }
        items += day.sortedSegments.map { ($0.sortOrder, $0.number.isEmpty ? $0.carrier : $0.number) }
        return items.filter { !$0.1.isEmpty }.sorted { $0.0 < $1.0 }.first?.1 ?? ""
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

    // MARK: 事件类文案

    /// 提前量可读文案（"3 小时" / "1 天" / "45 分钟"）。
    private static func leadText(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return String.localizedStringWithFormat(NSLocalizedString("notif.lead.days", comment: ""), minutes / 1440) }
        if minutes % 60 == 0 { return String.localizedStringWithFormat(NSLocalizedString("notif.lead.hours", comment: ""), minutes / 60) }
        return String.localizedStringWithFormat(NSLocalizedString("notif.lead.minutes", comment: ""), minutes)
    }

    private static func transportContent(seg: TransportSegment, isReturn: Bool, leadMinutes: Int) -> (String, String) {
        // 承运方按界面语言（航班解析本地化航司名，否则存值）；通知本就走设备 locale，口径一致。
        let carrier = seg.displayCarrier
        if seg.mode == .carRental {
            // 只还车（取车不提醒）。正文带「还车时刻」——lead 同日，故「今天」成立。
            let company = carrier.isEmpty ? NSLocalizedString("notif.car.fallback", comment: "") : carrier
            // 还车时刻跟随设备 12/24h 偏好（与退房 clockLabel 统一，不再硬编码 24h）。
            let returnTime = seg.arriveLocalMinutes >= 0 ? clockLabel(minutes: seg.arriveLocalMinutes) : ""
            return (String(format: NSLocalizedString("notif.car.dropoff.title", comment: ""), company),
                    String(format: NSLocalizedString("notif.car.dropoff.body", comment: ""), returnTime))
        }
        let label = seg.number.isEmpty
            ? (carrier.isEmpty ? NSLocalizedString("notif.transport.generic", comment: "") : carrier)
            : seg.number
        let lead = leadText(leadMinutes)
        let title = String(format: NSLocalizedString("notif.transport.title", comment: ""), label)
        // 航班 / 非航班两套口吻：航班=起飞·赶飞机；火车巴士渡轮=发车·留足时间。
        let bodyKey = seg.mode == .flight ? "notif.transport.body.flight" : "notif.transport.body.other"
        return (title, String(format: NSLocalizedString(bodyKey, comment: ""), lead))
    }

    /// 只「退房」提醒（入住不提醒）。正文聚焦「别落下东西」，不提超时（不施压）。
    private static func lodgingContent(stay: LodgingStay) -> (String, String) {
        let name = stay.name.isEmpty ? NSLocalizedString("notif.lodging.fallback", comment: "") : stay.name
        let title = String(format: NSLocalizedString("notif.lodging.checkout.title", comment: ""), name)
        // 退房时刻有填 → 带出截止点（按界面语言 12/24h 本地化）；没填 → 回落无时刻版。
        let body: String
        if stay.checkOutMinutes >= 0 {
            body = String(format: NSLocalizedString("notif.lodging.checkout.body.timed", comment: ""),
                          clockLabel(minutes: stay.checkOutMinutes))
        } else {
            body = NSLocalizedString("notif.lodging.checkout.body", comment: "")
        }
        return (title, body)
    }

    /// 把「自午夜分钟数」格式成本地化时刻串（如 12:00 / 12:00 PM），跟随设备语言/12-24h 偏好。
    /// 用 UTC 日历+formatter 配对，纯展示墙钟时刻、不被时区平移。
    private static func clockLabel(minutes: Int) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let date = cal.date(from: DateComponents(year: 2000, month: 1, day: 1,
                                                 hour: minutes / 60, minute: minutes % 60)) ?? Date()
        let df = DateFormatter()
        df.timeZone = utc
        df.locale = .current
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: date)
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
                String.localizedStringWithFormat(String(localized: "notif.ndays.title"), tripName, daysBeforeDeparture),
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

    /// 取消**所有行程**的挂起通知（用于「抹掉所有数据」，spec: erase-all-data.md）。
    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(tripPrefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
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

    /// 把通知 identifier 解析成富深链目标（spec: notification-deeplink-routing.md）：按类别决定落
    /// 「打包」还是「行程」脸，行程类再带锚点（段→所在天 / 住宿→退房天 / 每日→该天）。
    /// **新增通知类别时必须同步此函数**（与 `collectXxx` 成对维护，否则新通知落点回退到「保持上次脸」）。
    static func deepLink(fromIdentifier identifier: String) -> TripDeepLink? {
        guard let tripId = tripId(fromIdentifier: identifier) else { return nil }
        // dropFirst(prefix) 后形如 `{uuid}.{category}.…`；uuid 不含 '.'，按 '.' 切分即可。
        let comps = identifier.dropFirst(tripPrefix.count).split(separator: ".").map(String.init)
        guard comps.count >= 2 else { return TripDeepLink(tripId: tripId) }
        switch comps[1] {
        case "depart", "pack", "weather":
            return TripDeepLink(tripId: tripId, face: .packing)
        case "transport":
            // id: transport.{segId}.{depart|dropoff}.{lead}；还车(dropoff)锚到 arriveDayOrder 天。
            let isReturn = comps.count >= 4 && comps[3] == "dropoff"
            let anchor = comps.count >= 3
                ? UUID(uuidString: comps[2]).map { TripDeepLinkAnchor.segment(id: $0, isReturn: isReturn) }
                : nil
            return TripDeepLink(tripId: tripId, face: .itinerary, anchor: anchor)
        case "lodging":
            let anchor = comps.count >= 3 ? UUID(uuidString: comps[2]).map(TripDeepLinkAnchor.lodging) : nil
            return TripDeepLink(tripId: tripId, face: .itinerary, anchor: anchor)
        case "daily":
            let anchor = comps.count >= 3 ? Int(comps[2]).map(TripDeepLinkAnchor.day) : nil
            return TripDeepLink(tripId: tripId, face: .itinerary, anchor: anchor)
        default:
            return TripDeepLink(tripId: tripId)   // 未知类别：保持上次脸、无锚点（安全降级）
        }
    }

}
