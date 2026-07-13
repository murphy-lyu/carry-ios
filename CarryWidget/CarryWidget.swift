//
//  CarryWidget.swift
//  CarryWidget
//
//  Home-screen widget: shows upcoming trips and their packing progress.
//

import WidgetKit
import SwiftUI
import AppIntents
import UIKit

// MARK: - Shared data (mirror of TripStore.WidgetTripSnapshot)

private let widgetAppGroup = "group.com.murphy.carry"
private let widgetSnapshotKey = "carry_widget_trips"

/// 行程「有时间的事件」镜像（spec: widget-trip-companion.md）。绝对 `date` 由主 App 按活动时区算好；
/// `kind` 语义标签（取图标 + 组装本地化前缀），`primary`/`secondary` 是用户数据。
struct WidgetEvent: Codable {
    let date: Date
    let kind: String
    let primary: String
    let secondary: String
}

/// 住宿跨度镜像（spec: widget-trip-companion.md）。判定「今晚住哪」。
struct WidgetStay: Codable {
    let name: String
    let checkInDayOrder: Int
    let nights: Int
}

/// 行程项镜像（含无时刻，spec: widget-trip-companion.md）。无「下一件事」时显示「今天的地点」。
struct WidgetPlanItem: Codable {
    let dayOrder: Int
    let order: Int
    let title: String
    let kind: String
}

/// large 概览条目镜像（spec: widget-upcoming-large.md）。
struct WidgetAgendaItem: Codable {
    let dayOrder: Int
    let order: Int
    let title: String
    let subtitle: String
    let kind: String
    let time: String
}

/// 旅行相位（spec: widget-trip-companion.md）。
enum TripPhase { case preTrip, inTrip, ended }

/// Field-identical mirror of the main app's `WidgetTripSnapshot`, decoded from the
/// JSON the app writes into the App Group UserDefaults.
///
/// ⚠️ 升级兼容：未来给 `WidgetTripSnapshot` 加新字段时，**这里对应字段必须是可选或
/// 自带默认值**，否则用户装了新版主 App（写入含新字段的 JSON）+ 未刷新的旧 Widget
/// extension 进程会解码失败，Widget 显示空白/崩溃。
/// 旅行伴侣相位字段（returnDate/isDateless/events/stays）一律**可选** → 解码旧 JSON（无这些键）
/// 时退化为出发前相位，不崩不空白。
struct WidgetTrip: Codable, Identifiable {
    let tripId: String
    let name: String
    let destinationCity: String
    let departureDate: Date
    let packedCount: Int
    let totalCount: Int
    // ── 旅行伴侣相位升级（spec: widget-trip-companion.md）；可选 = 向后兼容 ──
    let returnDate: Date?
    let isDateless: Bool?
    let events: [WidgetEvent]?
    let stays: [WidgetStay]?
    let plan: [WidgetPlanItem]?
    let agenda: [WidgetAgendaItem]?

    var id: String { tripId }

    var progress: Double {
        totalCount > 0 ? Double(packedCount) / Double(totalCount) : 0
    }

    /// carry://trip/{uuid} — handled by CarryApp.onOpenURL.
    var deepLink: URL? { URL(string: "carry://trip/\(tripId)") }

    var displayTitle: String { name.isEmpty ? destinationCity : name }

    /// 规划中（isDateless）行程没有出发日可用于倒计时——那是创建时的占位值，拿去算会显示随时间
    /// 推移毫无意义的「过期」倒计时。所有调用点统一从这里取，不再各自重复判断
    /// （spec: widget-planning-trip-fallback.md；code review 2026-07-07 发现 4 处倒计时调用点里
    /// 有一处漏了判断，只靠远端「规划中兜底只产生单条 snapshot」这个约定维持安全）。
    var countdownTextIfDated: String? {
        isDateless == true ? nil : countdownText(for: departureDate)
    }

    /// 行程规划（地点/交通/住宿）是否为空——规划中/即将出发两种 pre-trip 状态统一用它判断要不要
    /// 展示「开始规划行程」引导（而非打包进度），单点维护，避免三个尺寸各自重复算一遍（code review 2026-07-10）。
    var hasItinerary: Bool {
        !(agenda?.isEmpty ?? true)
    }

    // MARK: 相位推导（asOf 取 entry.date，使「今天 / 下一件事」随 timeline 推进）

    /// 含两端的日历天数（= returnDate − departureDate + 1）；无 returnDate 退化为 1。
    var spanDays: Int {
        guard let returnDate else { return 1 }
        let cal = Calendar.current
        let d = cal.dateComponents([.day],
                                   from: cal.startOfDay(for: departureDate),
                                   to: cal.startOfDay(for: returnDate)).day ?? 0
        return max(1, d + 1)
    }

    func phase(asOf now: Date) -> TripPhase {
        guard let returnDate, !(isDateless ?? false) else { return .preTrip }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard today <= cal.startOfDay(for: returnDate) else { return .ended }
        return today >= cal.startOfDay(for: departureDate) ? .inTrip : .preTrip
    }

    /// 0-based 天序号（相对出发日），clamp 到 [0, spanDays-1]。传「现在」得「当前第几天」，
    /// 传任意事件绝对时刻得「该事件所在第几天」（供 agendaDayLabel 取日期标签用）——同一套换算，参数名统一叫 asOf。
    func currentDayIndex(asOf now: Date) -> Int {
        let cal = Calendar.current
        let d = cal.dateComponents([.day],
                                   from: cal.startOfDay(for: departureDate),
                                   to: cal.startOfDay(for: now)).day ?? 0
        return max(0, min(d, spanDays - 1))
    }

    /// 现在之后最近的一件事（绝对时刻比较，跨午夜也成立）。
    func nextEvent(asOf now: Date) -> WidgetEvent? {
        (events ?? []).first { $0.date > now }
    }

    /// 今晚住哪（住宿覆盖当前天：checkIn ≤ idx < checkIn+nights）。
    func tonightStay(asOf now: Date) -> WidgetStay? {
        let idx = currentDayIndex(asOf: now)
        return (stays ?? []).first { idx >= $0.checkInDayOrder && idx < $0.checkInDayOrder + $0.nights }
    }

    /// 今天的行程项（按序），供「无带时刻的下一件事」时显示「今天的地点」。
    func todayPlan(asOf now: Date) -> [WidgetPlanItem] {
        let idx = currentDayIndex(asOf: now)
        return (plan ?? []).filter { $0.dayOrder == idx }.sorted { $0.order < $1.order }
    }

    /// large 概览：从「现在」起的条目，按 (天, 当天序) 排（spec: widget-upcoming-large.md）。
    /// 今天（dayOrder == idx）的有时刻条目只保留时刻 >= 当前分钟数的，过去的不再展示。
    /// 无时刻条目（order 落在 24*60*2 + sortOrder 区间，即 order >= 24*60*2）不受限制。
    func upcomingAgenda(asOf now: Date) -> [WidgetAgendaItem] {
        let idx = currentDayIndex(asOf: now)
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return (agenda ?? []).filter { item in
            guard item.dayOrder >= idx else { return false }
            // 今天的有时刻条目：order = minutes * 2（偶数槽，0…2878），过了就过滤掉。
            // order < 0（退房 = -2）或 order >= 24*60*2（无时刻/入住）不做时刻过滤，直接保留。
            if item.dayOrder == idx, item.order >= 0, item.order < 24 * 60 * 2 {
                return item.order / 2 >= nowMinutes
            }
            return true
        }
        .sorted { ($0.dayOrder, $0.order) < ($1.dayOrder, $1.order) }
    }

    /// 某天序的分组头文案：今天 / 明天 / 周N · M/D。
    func agendaDayLabel(_ dayOrder: Int, asOf now: Date) -> String {
        let cur = currentDayIndex(asOf: now)
        if dayOrder == cur { return NSLocalizedString("widget.companion.today", comment: "") }
        if dayOrder == cur + 1 { return NSLocalizedString("widget.countdown.tomorrow", comment: "") }
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: dayOrder, to: cal.startOfDay(for: departureDate)) ?? departureDate
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static let preview = WidgetTrip(
        tripId: "preview",
        name: "Tokyo",
        destinationCity: "Tokyo",
        departureDate: Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date(),
        packedCount: 8,
        totalCount: 12,
        returnDate: nil,
        isDateless: false,
        events: nil,
        stays: nil,
        plan: nil,
        agenda: nil
    )

    /// 旅行中预览（spec 验收/Xcode 预览用）。
    static let previewInTrip = WidgetTrip(
        tripId: "preview-in",
        name: "Paris",
        destinationCity: "Paris",
        departureDate: Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date(),
        packedCount: 12,
        totalCount: 12,
        returnDate: Calendar.current.date(byAdding: .day, value: 4, to: Date()) ?? Date(),
        isDateless: false,
        events: [
            WidgetEvent(date: Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date(),
                        kind: "flight", primary: "AF111", secondary: "CDG → NRT"),
        ],
        stays: [WidgetStay(name: "Hôtel Le Meurice", checkInDayOrder: 0, nights: 6)],
        plan: nil,
        agenda: [
            WidgetAgendaItem(dayOrder: 2, order: 0, title: "AF111", subtitle: "CDG → NRT", kind: "flight", time: "13:45"),
            WidgetAgendaItem(dayOrder: 2, order: 1, title: "Louvre", subtitle: "Rue de Rivoli", kind: "sightseeing", time: ""),
            WidgetAgendaItem(dayOrder: 3, order: 0, title: "Versailles", subtitle: "", kind: "sightseeing", time: "10:00"),
        ]
    )
}

private func loadWidgetTrips() -> [WidgetTrip] {
    guard let defaults = UserDefaults(suiteName: widgetAppGroup),
          let data = defaults.data(forKey: widgetSnapshotKey),
          let trips = try? JSONDecoder().decode([WidgetTrip].self, from: data)
    else { return [] }
    return trips
}

// MARK: - Helpers

private func daysUntil(_ date: Date) -> Int {
    let cal = Calendar.current
    let from = cal.startOfDay(for: Date())
    let to = cal.startOfDay(for: date)
    return cal.dateComponents([.day], from: from, to: to).day ?? 0
}

private func countdownText(for date: Date) -> String {
    let days = daysUntil(date)
    if days <= 0 { return NSLocalizedString("widget.countdown.today", comment: "") }
    if days == 1 { return NSLocalizedString("widget.countdown.tomorrow", comment: "") }
    return String(format: NSLocalizedString("widget.countdown.days_left", comment: ""), days)
}

private func progressText(_ trip: WidgetTrip) -> String {
    String.localizedStringWithFormat(NSLocalizedString("widget.progress.packed", comment: ""), trip.packedCount, trip.totalCount)
}

/// 行程规划引导行（可选倒计时 + 规划进度文案），供三个尺寸的 pre-trip 视图共用——行程规划为空
/// 或规划中兜底行程都落进这里，避免三处各自重复写一遍（code review 2026-07-10）。
/// `showCountdown`：Large/Medium 现在把倒计时合并进头部行的 trailing 位置（同「X Planned」），
/// 这里传 false 避免正文再重复一遍；Small 倒计时挪到卡片底部单独展示，不走这个函数的倒计时分支，
/// 保持默认 true 不受影响（用户反馈 2026-07-12）。
@ViewBuilder
private func planningGuideText(_ trip: WidgetTrip, font: Font, summaryLineLimit: Int? = nil, showCountdown: Bool = true) -> some View {
    if showCountdown, let countdown = trip.countdownTextIfDated {
        Text(countdown)
            .font(font)
            .foregroundStyle(.secondary)
    }
    Text(planningSummaryText(trip))
        .font(font)
        .foregroundStyle(.secondary)
        .lineLimit(summaryLineLimit)
}

/// 规划中（isDateless）兜底行程「已规划 N 项」文案；N=0 时换成引导文案（spec: widget-planning-trip-fallback.md）。
private func planningSummaryText(_ trip: WidgetTrip) -> String {
    let count = plannedItemsCount(trip)
    guard count > 0 else { return NSLocalizedString("widget.planning.empty", comment: "") }
    return String.localizedStringWithFormat(NSLocalizedString("widget.planning.items_count", comment: ""), count)
}

private func plannedItemsCount(_ trip: WidgetTrip) -> Int {
    trip.agenda?.count ?? 0
}

/// 规划中行程的地点/交通预览——直接取 dayOrder==0 的条目，**不做任何按时刻过滤**。
/// 与 `WidgetTrip.upcomingAgenda(asOf:)` 不同：那个方法按 `currentDayIndex(asOf:)` 算「今天」，
/// 而规划中行程的 departureDate 是占位值，拿去算「今天」没有意义，会把某个时段的地点误判成「已过」而漏显示。
private func planningAgendaPreview(_ trip: WidgetTrip) -> [WidgetAgendaItem] {
    (trip.agenda ?? []).filter { $0.dayOrder == 0 }.sorted { $0.order < $1.order }
}

// MARK: - Widget appearance configuration

enum WidgetAppearance: String, AppEnum {
    case automatic, light, dark

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "widget.config.appearance"
    static var caseDisplayRepresentations: [WidgetAppearance: DisplayRepresentation] = [
        .automatic: "widget.appearance.automatic",
        .light:     "widget.appearance.light",
        .dark:      "widget.appearance.dark",
    ]
}

struct CarryWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "widget.config.title"
    static var description = IntentDescription("widget.config.description")

    @Parameter(title: "widget.config.appearance", default: .automatic)
    var appearance: WidgetAppearance
}

// MARK: - Timeline

struct CarryEntry: TimelineEntry {
    let date: Date
    let trips: [WidgetTrip]
    var appearance: WidgetAppearance = .automatic

}

/// containerBackground 的材质颜色由系统 trait 决定，无法通过 SwiftUI 环境注入覆盖。
/// 强制 Light / Dark 时，用 UITraitCollection 解析出对应的 UIColor.systemBackground
/// 作为明确背景色；Automatic 仍用系统自适应的 .fill.tertiary。
private struct WidgetColorSchemeOverride: ViewModifier {
    let appearance: WidgetAppearance
    @Environment(\.colorScheme) private var systemScheme

    private var resolvedScheme: ColorScheme {
        switch appearance {
        case .automatic: return systemScheme
        case .light:     return .light
        case .dark:      return .dark
        }
    }

    /// 强制模式下用 UIKit trait 解析出目标模式的 systemBackground，
    /// 视觉上与标准 widget 背景一致，且不受系统模式影响。
    private var forcedBackground: Color {
        let style: UIUserInterfaceStyle = resolvedScheme == .dark ? .dark : .light
        // secondarySystemBackground 在 dark 模式下为 #1C1C1E，与 fill.tertiary 材质接近；
        // systemBackground 在 dark 模式下为纯黑 #000000，与 Automatic 档位视觉不一致。
        let uiColor = UIColor.secondarySystemBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
        return Color(uiColor)
    }

    func body(content: Content) -> some View {
        let scheme = resolvedScheme
        content
            .environment(\.colorScheme, scheme)
            .containerBackground(for: .widget) {
                if appearance == .automatic {
                    Rectangle().fill(.fill.tertiary)
                } else {
                    forcedBackground
                }
            }
    }
}

struct CarryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CarryEntry {
        CarryEntry(date: Date(), trips: [.preview])
    }

    func snapshot(for configuration: CarryWidgetIntent, in context: Context) async -> CarryEntry {
        let trips = context.isPreview ? [.preview] : loadWidgetTrips()
        return CarryEntry(date: Date(), trips: trips, appearance: configuration.appearance)
    }

    func timeline(for configuration: CarryWidgetIntent, in context: Context) async -> Timeline<CarryEntry> {
        let now = Date()
        let trips = loadWidgetTrips()
        let cal = Calendar.current

        // 倒计时/相位按天变 → 至少每日午夜刷新；旅行中再在「每个未来事件时刻」补 entry，
        // 使「下一件事 / Day N」在恰当时刻翻页（事件之间倒计时由 Text(style:.relative) 自走）。
        let firstMidnight = cal.nextDate(after: now,
                                         matching: DateComponents(hour: 0, minute: 0, second: 5),
                                         matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)

        var refDates: Set<Date> = [now]
        if let primary = trips.first {
            for ev in (primary.events ?? []) where ev.date > now { refDates.insert(ev.date) }
        }
        // 一串每日午夜（覆盖到主卡 returnDate 之后一天，无则 14 天兜底）。
        // 规划中（isDateless）行程的 returnDate 是创建时占位值（可能已在过去），不能当真实日期用——
        // 否则 end 落在过去、下面 while 循环一次都不跑，Widget 刷新窗口被意外压成仅 1 小时
        // （spec: widget-planning-trip-fallback.md 补充；code review 2026-07-07 发现）。
        let primaryReturnDate = (trips.first?.isDateless == true) ? nil : trips.first?.returnDate
        let end = primaryReturnDate.flatMap { cal.date(byAdding: .day, value: 1, to: $0) }
            ?? cal.date(byAdding: .day, value: 14, to: now) ?? now.addingTimeInterval(14 * 86400)
        var m = firstMidnight
        while m <= end {
            refDates.insert(m)
            guard let next = cal.date(byAdding: .day, value: 1, to: m) else { break }
            m = next
        }

        // 上限 60 个 entry（WidgetKit 友好），按时间升序。
        let dates = refDates.sorted().prefix(60)
        let entries = dates.map { CarryEntry(date: $0, trips: trips, appearance: configuration.appearance) }
        let policyEnd = entries.last.map { $0.date.addingTimeInterval(3600) } ?? firstMidnight
        return Timeline(entries: entries.isEmpty ? [CarryEntry(date: now, trips: trips, appearance: configuration.appearance)] : entries,
                        policy: .after(policyEnd))
    }
}

// MARK: - Views

struct CarryWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: CarryEntry

    var body: some View {
        Group {
            // 「未结束」的行程才作为 Widget 主角；returnDate 已过的排在前面也视同无活跃行程。
            // （writeWidgetSnapshot 只在 App 生命周期节点重算过滤，snapshot 写入后到下次写入之间，
            // 午夜翻页可能让原本未结束的行程在这段间隙里变成已结束——这里兜底过滤，避免误显示。）
            let activeTrips = entry.trips.filter { $0.phase(asOf: entry.date) != .ended }
            if let trip = activeTrips.first {
                switch (family, trip.phase(asOf: entry.date)) {
                case (.systemLarge, .inTrip):
                    largeAgendaView(trip, now: entry.date)
                case (.systemLarge, .preTrip):
                    largePreTripView(trip, now: entry.date)
                case (.systemMedium, .inTrip):
                    inTripMediumView(trip, now: entry.date)
                case (.systemMedium, .preTrip):
                    mediumView(primary: trip, secondary: activeTrips.dropFirst().first)
                case (_, .inTrip):
                    inTripSmallView(trip, now: entry.date)
                default:
                    smallView(trip)
                }
            } else {
                emptyView
            }
        }
        // WidgetKit 的系统自动 content margins 按 family 各给一套默认值，三个尺寸的标题/内容左边距因此
        // 对不上（用户反馈）。改为统一关掉自动边距、自己按 family 手动给 padding——同一个绝对数值在
        // Small（约 155pt 见方）和 Large（约 350pt 见方）上占比天差地别：16pt 统一套用后，Small 反而
        // 显得比 Medium/Large 更宽松（用户复核截图确认的方向），故 Small 用更小的绝对值。
        .padding(family == .systemSmall ? 12 : 16)
        .modifier(WidgetColorSchemeOverride(appearance: entry.appearance))
    }

    // MARK: In-trip helpers (spec: widget-trip-companion.md)

    /// 事件 kind → SF Symbol。kind 直接来自 `StopCategory`/`TransportMode` 的 rawValue
    /// （见 `TripStore.widgetAgenda`/`widgetPlan` 里 `stop.category.rawValue`/`seg.mode.rawValue`），
    /// 图标必须跟主 App 唯一真源 `Carry/Views/StopCategoryStyle.swift` 的 `symbolName` 逐条对齐，
    /// 否则同一地点在 App 里和 Widget 里显示不同图标（用户反馈 2026-07-12）。
    private func icon(for kind: String) -> String {
        switch kind {
        case "sightseeing":         return "binoculars"
        case "museum":              return "paintpalette"
        case "park":                return "tree"
        case "beach":               return "beach.umbrella"
        case "restaurant":          return "fork.knife"
        case "cafe":                return "cup.and.saucer"
        case "bar":                 return "wineglass"
        case "shopping":            return "bag"
        case "lodging", "checkin", "checkout": return "bed.double"
        case "flight":              return "airplane"
        // StopCategory.train 的 rawValue 显式保留旧值 "transport"；TransportSegment 走 seg.mode.rawValue = "train"。
        case "train", "transport":  return "train.side.front.car"
        case "bus":                 return "bus"
        case "ferry":               return "ferry.fill"
        // StopCategory 没有独立 cruise 图标真源，沿用 TransportMode.ferry 同款渡轮图标。
        case "cruise":              return "ferry.fill"
        case "carRental", "carRentalPickup", "carRentalDropoff": return "car.fill"
        default:                    return "mappin"
        }
    }

    /// 事件 kind → 类别色，复用 `SpendCategory.color`（`TripSpendView.swift`）同款配色，
    /// 不新造一套颜色语言（对标 Tripsy 事件列表的彩色图标圆底，用户反馈 2026-07-12）。
    private func categoryColor(for kind: String) -> Color {
        switch kind {
        case "flight", "train", "transport", "bus", "ferry", "cruise",
             "carRental", "carRentalPickup", "carRentalDropoff":
            return .blue
        case "checkin", "checkout", "lodging":
            return .indigo
        case "restaurant":
            return .orange
        case "cafe":
            return Color(red: 0.6, green: 0.4, blue: 0.2)
        case "bar":
            return .purple
        case "sightseeing":
            return .teal
        case "museum":
            return Color(red: 0.3, green: 0.5, blue: 0.7)
        case "park":
            return .green
        case "beach":
            return Color(red: 0.0, green: 0.7, blue: 0.8)
        case "shopping":
            return Color(red: 0.9, green: 0.4, blue: 0.5)
        default:
            return .gray
        }
    }

    /// 事件标题文本：checkin/checkout 前缀本地化（用户数据拼在后），其余直接用用户数据。
    /// 单一 Text（verbatim 组合「已本地化标签 · 用户数据」）：避免 `Text + Text`（iOS 26 弃用）
    /// 与「插值字面量被抽成本地化键」两个坑，且整串作为一体截断更自然。
    private func eventTitle(_ ev: WidgetEvent) -> Text {
        switch ev.kind {
        case "checkin", "checkout":
            let label = NSLocalizedString(
                ev.kind == "checkin" ? "widget.companion.checkin" : "widget.companion.checkout", comment: "")
            return ev.primary.isEmpty ? Text(label) : Text(verbatim: "\(label) · \(ev.primary)")
        default:
            return Text(ev.primary.isEmpty ? ev.secondary : ev.primary)
        }
    }

    /// "DAY N / M" 头部行。
    private func dayHeader(_ trip: WidgetTrip, now: Date) -> some View {
        let s = String.localizedStringWithFormat(
            NSLocalizedString("widget.companion.day_of", comment: ""),
            trip.currentDayIndex(asOf: now) + 1, trip.spanDays)
        return HStack(spacing: 5) {
            Image(systemName: "suitcase.fill").font(.caption)
            Text(s)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .foregroundStyle(.secondary)
    }

    /// 今晚住哪行（"Tonight · 酒店名"，占位符由本地化字符串带）。
    private func tonightRow(_ stay: WidgetStay) -> some View {
        let s = String(format: NSLocalizedString("widget.companion.tonight", comment: ""), stay.name)
        return HStack(spacing: 5) {
            Image(systemName: "bed.double.fill").font(.caption2)
            Text(s).lineLimit(1)
        }
        .font(.system(.caption2, design: .rounded))
        .foregroundStyle(.secondary)
    }

    // MARK: In-trip Small

    private func inTripSmallView(_ trip: WidgetTrip, now: Date) -> some View {
        let nextEv = trip.nextEvent(asOf: now)
        let firstPlan = trip.todayPlan(asOf: now).first
        let heroKind: String? = nextEv?.kind ?? firstPlan?.kind
        let dayLabelText: String? = {
            if let ev = nextEv { return trip.agendaDayLabel(trip.currentDayIndex(asOf: ev.date), asOf: now) }
            if firstPlan != nil { return trip.agendaDayLabel(trip.currentDayIndex(asOf: now), asOf: now) }
            return nil
        }()
        // 三段式：头部+TODAY 固定贴顶（跟 Medium/Large 一样），分割线+今日小结固定贴底，
        // 中间的图标+地点名在剩下的空白里用前后 Spacer 垂直居中——内容总量没变，只是把原来
        // 全部堆在顶部、留白甩在最后一段的分布，改成两头固定、中段居中（用户反馈 2026-07-13）。
        // 不再把图标叠到标题上方（那版已撤回、会溢出），保持图标+标题同一行、safe。
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "suitcase.fill").font(.caption2)
                Text("widget.agenda.title")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            .foregroundStyle(.secondary)

            if let dayLabelText {
                dayGroupLabel(dayLabelText)
            }

            Spacer(minLength: 4)

            if let kind = heroKind {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: icon(for: kind))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(categoryColor(for: kind), in: Circle())
                    Group {
                        if let ev = nextEv {
                            eventTitle(ev)
                        } else if let first = firstPlan {
                            Text(first.title)
                        }
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // 交通类事件（primary=航班号/车次）补一行 secondary（航线），否则信息量不足；
                // checkin/checkout 的 secondary 恒为空，不受影响。
                if let ev = nextEv, !ev.secondary.isEmpty {
                    Text(verbatim: ev.secondary)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 50)
                }
            } else {
                Text(trip.displayTitle)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 4)

            todayTotalFooter(trip, now: now)
            if let stay = trip.tonightStay(asOf: now) {
                tonightRow(stay)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(trip.deepLink)
    }

    /// 天分组标签（如 "TODAY"/"TOMORROW"/"MON · 7/14"）——跟 `agendaRenderRows` 渲染天头用的样式
    /// 完全一致，供进行中的三个尺寸共用同一套视觉语言（用户反馈 2026-07-13）。
    private func dayGroupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }

    /// 进行中 agenda 列表底部小结——「今日共 N 项」，独立于上方因 `maxItems` 封顶而实际展示的条目数，
    /// 补偿"少展示几条"丢掉的信息（用户反馈 2026-07-13）。按当前天的 `dayOrder` 从完整 `agenda`
    /// （非按时刻过滤的 `upcomingAgenda`）数，反映"今天总共安排了几处"而非"还剩几处没去"。
    @ViewBuilder
    private func todayTotalFooter(_ trip: WidgetTrip, now: Date) -> some View {
        let idx = trip.currentDayIndex(asOf: now)
        let count = (trip.agenda ?? []).filter { $0.dayOrder == idx }.count
        if count > 0 {
            Divider().padding(.top, 4).padding(.bottom, 2)
            Text(String.localizedStringWithFormat(NSLocalizedString("widget.agenda.today_stops", comment: ""), count))
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: In-trip Medium — 复用 agenda 布局，maxSlots 更小

    private func inTripMediumView(_ trip: WidgetTrip, now: Date) -> some View {
        // 1 条：2 条 + 地址 + 分割线 + 小结在 Medium 真实高度上会溢出，撤回过一次；居中卡片式
        // （图标叠标题上方）同样溢出、已撤回（用户反馈 2026-07-13）。退回列表行样式，1 条。
        agendaView(trip, now: now, maxSlots: 3, maxItems: 1)
    }

    // MARK: Large — 按天分组的「接下来的行程」概览（spec: widget-upcoming-large.md）

    /// 一行渲染单元：天分组头（dayOrder 非空）/ 行程条目（item 非空）。
    private struct AgendaRenderRow: Identifiable {
        let id: String
        var dayOrder: Int? = nil
        var item: WidgetAgendaItem? = nil
    }

    /// 把按 (天,序) 排好的条目展开成「天头 + 条目」行序列，封顶 maxSlots 个视觉槽。
    /// 视觉槽计数：天头 = 1 slot；有副标题的条目 = 2 slots（标题行 + 副标题行）；无副标题 = 1 slot。
    private func agendaRenderRows(_ items: [WidgetAgendaItem], maxSlots: Int) -> [AgendaRenderRow] {
        var rows: [AgendaRenderRow] = []
        var lastDay: Int? = nil
        var usedSlots = 0
        for (i, it) in items.enumerated() {
            let needsHeader = it.dayOrder != lastDay
            let headerSlots = needsHeader ? 1 : 0
            let itemSlots = it.subtitle.isEmpty ? 1 : 2
            // 不超槽，且不放孤零零的天头（天头 + 条目必须同时放得下）。
            if usedSlots + headerSlots + itemSlots > maxSlots { break }
            if needsHeader {
                rows.append(AgendaRenderRow(id: "h\(it.dayOrder)", dayOrder: it.dayOrder))
                lastDay = it.dayOrder
                usedSlots += 1
            }
            rows.append(AgendaRenderRow(id: "i\(i)", item: it))
            usedSlots += itemSlots
        }
        return rows
    }

    /// 图标统一用类别色圆底（对标 Tripsy 的事件列表），规划中/即将出发/进行中三种状态共用同一套
    /// 视觉语言，不再有「进行中朴素图标、别处彩色图标」的不一致（用户反馈 2026-07-13）。
    /// `showSubtitle`：地址副标题是否展示——跟图标风格解耦成独立参数，因为两者取舍的理由不同：
    /// 规划中/即将出发预览行的任务是「浏览我规划了什么」，完整门牌是噪音，砍掉（默认 false）；
    /// 进行中的任务是「我现在要去哪」，地址是实际导航需要的信息，保留（agendaView 传 true）。
    @ViewBuilder
    private func agendaItemRow(_ it: WidgetAgendaItem, showSubtitle: Bool = false) -> some View {
        // Small（155pt 宽）用 .subheadline 时地名只能显示 10~12 个字符就被截断，比 Medium/Large
        // 明显更狠——预览行的价值在于「认出是哪个地点」，砍得太狠会读不出信息。只在不展示地址的
        // 预览行里收紧（这些是唯一会在 systemSmall 下渲染的调用点，用户反馈 2026-07-12）。
        let isCompact = !showSubtitle && family == .systemSmall
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: icon(for: it.kind))
                    .font(.system(size: isCompact ? 8 : 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: isCompact ? 16 : 20, height: isCompact ? 16 : 20)
                    .background(categoryColor(for: it.kind), in: Circle())
                Text(it.title)
                    .font(.system(isCompact ? .caption : .subheadline, design: .rounded).weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !it.time.isEmpty {
                    // 右侧时间是辅助信息，字重应轻于标题（.medium）而非同权重并列。
                    Text(it.time)
                        .font(.system(.subheadline, design: .rounded).weight(.regular))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if showSubtitle, !it.subtitle.isEmpty {
                Text(it.subtitle)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 28)
            }
        }
    }

    /// Large 和 Medium 共用的 agenda 列表视图。`maxSlots` 是视觉槽兜底（防止极端情况撑爆画布），
    /// `maxItems` 才是主要的条数封顶——2 条带地址的条目挤在 Medium 里底边距明显不够，改成「少展示
    /// 几条 + 底部『今日共 N 项』小结」腾出呼吸感，小结补偿被截掉的条目信息（用户反馈 2026-07-13）。
    private func agendaView(_ trip: WidgetTrip, now: Date, maxSlots: Int, maxItems: Int) -> some View {
        let items = Array(trip.upcomingAgenda(asOf: now).prefix(maxItems))
        let rows = agendaRenderRows(items, maxSlots: maxSlots)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("widget.agenda.title")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Spacer()
                dayHeader(trip, now: now)
            }
            if rows.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("widget.agenda.empty")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ForEach(rows) { row in
                    if let d = row.dayOrder {
                        dayGroupLabel(trip.agendaDayLabel(d, asOf: now))
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                    } else if let it = row.item {
                        agendaItemRow(it, showSubtitle: true)
                    }
                }
                todayTotalFooter(trip, now: now)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(trip.deepLink)
    }

    private func largeAgendaView(_ trip: WidgetTrip, now: Date) -> some View {
        // maxSlots=13：天头1槽、无副标题条目1槽、有副标题条目2槽；留底部自然白边而非强制撑满。
        // maxItems=5（原先按槽位算出来的是 6）——少展示 1 条，换底部「今日共 N 项」小结，呼吸感更好
        // （用户反馈 2026-07-13）。
        agendaView(trip, now: now, maxSlots: 13, maxItems: 5)
    }

    /// 出发前 large：倒计时 + 打包进度 + 出发当天预览。规划中（isDateless）兜底行程改展示规划进度 +
    /// 已规划条目预览（不是倒计时/打包进度，spec: widget-planning-trip-fallback.md v2）——用
    /// `planningAgendaPreview` 而非 `upcomingAgenda(asOf:)`，因为后者依赖 `departureDate` 算「今天」，
    /// 对占位日期的规划中行程没有意义、会误判条目「已过」。
    private func largePreTripView(_ trip: WidgetTrip, now: Date) -> some View {
        let isPlanning = trip.isDateless == true
        // 行程规划（地点/交通）是否为空——不管规划中还是有日期，行程规划为空就统一引导去规划，
        // 不展示打包进度；有至少 1 项才展示对应内容（用户反馈）。
        let hasItinerary = trip.hasItinerary
        let preview = isPlanning ? planningAgendaPreview(trip) : trip.upcomingAgenda(asOf: now).filter { $0.dayOrder == 0 }
        let hasPlannedCount = isPlanning && plannedItemsCount(trip) > 0
        // 头部行 trailing：规划中且有条目显示「X Planned」，有日期行程显示倒计时——跟「X Planned」
        // 同一个位置、同一套处理，正文不再重复一遍（用户反馈 2026-07-12）。
        let headerTrailing = hasPlannedCount ? planningSummaryText(trip) : trip.countdownTextIfDated
        // 「即将出发（已规划、打包中）」分支的头部比「规划中」多出进度条 + 打包行（倒计时已挪进头部，
        // 两分支这里差距缩小了，但打包分支仍多 2 行）——同样封顶会把预览列表撑出固定画布、顶部不稳定，
        // 按分支给不同的条数预算；截图显示 6 条下方仍有余量，放宽到 8（用户反馈 2026-07-12）。
        let previewCap = isPlanning ? 9 : 8
        // 内容一律紧贴顶部按顺序排列，不做居中/大 Spacer 填空——卡片下方多余的空间就是留白，
        // 跟 Apple 自家 Widget（日历/提醒事项）的处理一致（用户反馈：居中处理反而显得断层、不协调）。
        // 根因：WidgetKit 不会自动把整个可用画布的尺寸提议给这里的根 VStack——内容量少时，VStack
        // 只会按内容尺寸收缩，然后被系统在整块画布内居中摆放，`Spacer(minLength: 0)` 因为拿不到
        // 「画布减去内容」的多余空间可分配、根本不生效。`agendaView`（Large/Medium 共用的进行中视图）
        // 早就用 `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)` 显式把
        // 整块画布尺寸要回来、再声明左上对齐，这里补齐同款处理，从根上解决"内容偏少时整体跑到画布中间"。
        return VStack(alignment: .leading, spacing: 8) {
            widgetHeader(isPlanning: isPlanning, trailing: headerTrailing)
            Text(trip.displayTitle)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .lineLimit(1)
            if !hasItinerary || isPlanning {
                if !hasPlannedCount {
                    planningGuideText(trip, font: .system(.subheadline, design: .rounded).weight(.medium), showCountdown: false)
                }
            } else {
                ProgressView(value: trip.progress).tint(.primary)
                HStack {
                    Text(progressText(trip))
                    Spacer()
                    Text("\(Int((trip.progress * 100).rounded()))%")
                }
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
            }
            if !preview.isEmpty {
                Divider().padding(.vertical, 2)
                // 预览行不展示副标题（地址），恒为单行高度，直接按条数封顶即可——
                // 不再需要 agendaSlotsCapped 那套"副标题占 2 槽"的可变高度预算（用户反馈 2026-07-12）。
                ForEach(Array(preview.prefix(previewCap).enumerated()), id: \.offset) { _, it in
                    agendaItemRow(it)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(trip.deepLink)
    }

    // MARK: Small

    private func smallView(_ trip: WidgetTrip) -> some View {
        // 内容一律紧贴顶部按顺序排列，不做居中/大 Spacer 填空，与 mediumView/largePreTripView 统一
        // （用户反馈：三个尺寸此前各用一套锚定方式，看着不协调；这里之前遗留的 Spacer(minLength: 8)
        // 是更早一轮"贴底展示"的旧写法，本轮统一时漏改，导致 1×1 单独跟另外两个尺寸不一致）。
        // 显式要回整块画布尺寸 + 声明左上对齐（根因见 largePreTripView 同款注释）。
        let isPlanning = trip.isDateless ?? false
        // 行程规划为空就统一引导去规划、不展示打包进度，不管规划中还是有日期（用户反馈，见
        // largePreTripView 同款注释）。
        let hasItinerary = trip.hasItinerary
        let hasPlannedCount = isPlanning && plannedItemsCount(trip) > 0
        // 规划中且已有条目时展示预览——之前 Small 只有三行文字、下方大片空白看着像没做完；
        // 跟 Medium/Large 用同一个 coloredIcon 行组件展示已规划地点，三个尺寸视觉语言统一
        // （用户反馈 2026-07-12）。范围同 Q2：只覆盖规划中状态，不动"有日期+已有行程规划"的正常态
        // （那个分支已经有倒计时+打包进度条撑满空间，没有空白问题）。
        // 「顶部标题+行程名+X Planned」三行头部占用太多、几乎不剩空间展示行程本身——去掉 X Planned
        // 这行文案（`hasPlannedCount` 为真时跳过 `planningGuideText`），腾出的空间用来多展示 2 条预览
        // （用户反馈 2026-07-12：宁要 3 行地点，不要 3 行头部信息）。count=0 的引导态文案不受影响。
        let planningPreview = isPlanning ? planningAgendaPreview(trip) : []
        return VStack(alignment: .leading, spacing: 4) {
            widgetHeader(isPlanning: isPlanning)
            Text(trip.name.isEmpty ? trip.destinationCity : trip.name)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !hasItinerary || isPlanning {
                // 规划中（isDateless）或行程规划为空的有日期行程：展示规划进度，不展示打包进度——
                // 「已规划 N 项」更能反映用户实际在推进的事（spec: widget-planning-trip-fallback.md v2）。
                if !hasPlannedCount {
                    planningGuideText(trip, font: .system(.subheadline, design: .rounded).weight(.medium), summaryLineLimit: 2)
                }
                if !planningPreview.isEmpty {
                    Divider().padding(.vertical, 2)
                    // 缩字号后单行更矮，且截图显示 3 条下方仍有余量——放到 4 条（用户反馈 2026-07-12）。
                    ForEach(Array(planningPreview.prefix(4).enumerated()), id: \.offset) { _, it in
                        agendaItemRow(it)
                    }
                }
            } else {
                // 倒计时不跟标题紧挨着，弱化成分割线下的小字——纯为了好看，倒计时不是这张卡片此刻
                // 最要紧的信息，打包进度才是。但也不能整块顶到画布最底部：中间会空出一大截、看着
                // 像断层，比原来「紧跟标题」还难看（用户反馈 2026-07-12）。改成紧跟在打包进度块
                // 后面——同一组内容里降一级，不再单独占用底部，剩余空间仍然是紧贴内容之后的纯留白。
                ProgressView(value: trip.progress)
                    .tint(.primary)
                    .padding(.top, 8)
                HStack {
                    Text(progressText(trip))
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((trip.progress * 100).rounded()))%")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let countdown = trip.countdownTextIfDated {
                    Divider().padding(.top, 4)
                    Text(countdown)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(trip.deepLink)
    }

    /// Header row: suitcase icon + "Upcoming"/"Planning" label, both in the same secondary
    /// colour. Used as a small-caption header above the trip name in both sizes.
    /// `isPlanning`：规划中（isDateless）兜底行程时换成 "Planning" 文案（spec: widget-planning-trip-fallback.md）。
    /// `trailing`：已规划条目数摘要（如「9 Planned」），靠右显示在同一行——原先单独占一整行文案，
    /// 跟标题/行程名合计三行偏占空间；合并进头部行，规划中/即将出发两种状态从三行收紧到两行
    /// （用户反馈 2026-07-12）。仅在有条目可数时传入，为空引导文案（「开始规划行程」句子偏长，
    /// 不适合挤进头部行）仍走下方 `planningGuideText` 独立一行。
    private func widgetHeader(isPlanning: Bool, trailing: String? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "suitcase.fill")
                .font(.caption)
            Text(isPlanning ? "widget.header.planning" : "widget.header.upcoming")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
            if let trailing {
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Medium

    private func mediumView(primary: WidgetTrip, secondary: WidgetTrip?) -> some View {
        let isPlanning = primary.isDateless == true
        // 「即将出发（已规划、打包中）」不展示出发当天预览——试过跟 largePreTripView 统一展示，
        // 但 Medium 只有约 155pt 高，倒计时进头部 + 进度条换线性样式两轮调整后，2 条预览仍然装不下
        // （用户反馈 2026-07-12：还是显示不下）。这个相位的主线信息是打包进度，预览本就是「空间够时
        // 的锦上添花」而非必需——Medium 空间不够，就不勉强塞，交给 Large 承担预览这件事；
        // 只有「规划中」分支（下面这行 `planningPreview` 的唯一来源）继续展示，那个分支已验证过没问题。
        let preview = isPlanning ? planningAgendaPreview(primary) : []
        let hasPlannedCount = isPlanning && plannedItemsCount(primary) > 0
        // 行程规划为空就统一引导去规划、不展示打包进度，不管规划中还是有日期（用户反馈，见
        // largePreTripView 同款注释）。
        let hasItinerary = primary.hasItinerary
        // 头部行 trailing：规划中且有条目显示「X Planned」，有日期行程显示倒计时——跟 largePreTripView
        // 同款处理，正文不再重复一遍（用户反馈 2026-07-12）。
        let headerTrailing = hasPlannedCount ? planningSummaryText(primary) : primary.countdownTextIfDated
        // 内容一律紧贴顶部按顺序排列，不做居中/大 Spacer 填空，与 largePreTripView 统一（用户反馈）；
        // 显式要回整块画布尺寸 + 声明左上对齐（根因见 largePreTripView 同款注释）。
        return VStack(alignment: .leading, spacing: 10) {
            // `widgetHeader` 必须是这层画布宽 VStack 的直接子视图，才能拿到跟 largePreTripView 一样的
            // 「完整画布宽度」提案，内部 Spacer 才能把 trailing 摘要真正推到右边缘——之前嵌在
            // 「标题+倒计时」那个 leading VStack 里（当时还跟进度环平铺在同一个 HStack 里），
            // 那层 VStack 按内容宽度收缩、不撑满，trailing 文案右边距因此比 Large 明显更大
            // （用户反馈 2026-07-12：1×4 和 4×4 的 "X Planned" 右边距不一样）。
            widgetHeader(isPlanning: isPlanning, trailing: headerTrailing)
            Text(primary.name.isEmpty ? primary.destinationCity : primary.name)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .lineLimit(1)
            if !hasItinerary || isPlanning {
                // 规划中兜底/行程规划为空：展示规划进度，不展示打包进度（同 smallView，spec v2）。
                if !hasPlannedCount {
                    planningGuideText(primary, font: .system(.caption, design: .rounded).weight(.semibold), showCountdown: false)
                }
            } else {
                // 原来的 58×58 进度环把「标题+进度」这一行的高度顶到跟环一样高，挤占了下面预览列表
                // 的空间（用户反馈 2026-07-12：怀疑是环太大导致内容显示不全）。改成跟 largePreTripView
                // 同款的线性进度条，高度只要几 pt，把腾出的空间让给预览条目；两个尺寸视觉也更统一。
                ProgressView(value: primary.progress).tint(.primary)
                HStack {
                    Text(progressText(primary))
                    Spacer()
                    Text("\(Int((primary.progress * 100).rounded()))%")
                }
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
            }

            if !preview.isEmpty {
                Divider()
                // 预览行不再展示地址副标题、恒为单行高度，腾出的空间够多展示 1 条（用户反馈 2026-07-12）。
                ForEach(Array(preview.prefix(2).enumerated()), id: \.offset) { _, it in
                    agendaItemRow(it)
                }
            }

            Spacer(minLength: 0)

            if let secondary {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "suitcase")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(secondary.name.isEmpty ? secondary.destinationCity : secondary.name)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    // 目前 secondary 永远不会是规划中行程（兜底只产生单条 snapshot），但本地防御
                    // 而非只靠远端约定——见 countdownTextIfDated 文档注释（code review 2026-07-07）。
                    if let countdown = secondary.countdownTextIfDated {
                        Text(countdown)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(primary.deepLink)
    }

    // MARK: Empty

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "suitcase")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("widget.empty.title")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            if family != .systemSmall {
                Text("widget.empty.subtitle")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Widget

struct CarryWidget: Widget {
    let kind: String = "CarryWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: CarryWidgetIntent.self, provider: CarryProvider()) { entry in
            CarryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("widget.display_name")
        .description("widget.description")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    CarryWidget()
} timeline: {
    CarryEntry(date: .now, trips: [.preview])
    CarryEntry(date: .now, trips: [.previewInTrip])
    CarryEntry(date: .now, trips: [])
}

#Preview(as: .systemMedium) {
    CarryWidget()
} timeline: {
    CarryEntry(date: .now, trips: [.preview])
    CarryEntry(date: .now, trips: [.previewInTrip])
}

#Preview(as: .systemLarge) {
    CarryWidget()
} timeline: {
    CarryEntry(date: .now, trips: [.previewInTrip])
    CarryEntry(date: .now, trips: [.preview])
}
