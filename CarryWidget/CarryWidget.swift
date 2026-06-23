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

/// 旅行相位（spec: widget-trip-companion.md）。
enum TripPhase { case preTrip, inTrip }

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

    var id: String { tripId }

    var progress: Double {
        totalCount > 0 ? Double(packedCount) / Double(totalCount) : 0
    }

    /// carry://trip/{uuid} — handled by CarryApp.onOpenURL.
    var deepLink: URL? { URL(string: "carry://trip/\(tripId)") }

    var displayTitle: String { name.isEmpty ? destinationCity : name }

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
        guard today <= cal.startOfDay(for: returnDate) else { return .preTrip }   // 已结束（防御，选片已排除）
        return today >= cal.startOfDay(for: departureDate) ? .inTrip : .preTrip
    }

    /// 0-based 当前天序号，clamp 到 [0, spanDays-1]。
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
        stays: nil
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
        stays: [WidgetStay(name: "Hôtel Le Meurice", checkInDayOrder: 0, nights: 6)]
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
        let end = trips.first?.returnDate.flatMap { cal.date(byAdding: .day, value: 1, to: $0) }
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
            if let trip = entry.trips.first {
                switch (family, trip.phase(asOf: entry.date)) {
                case (.systemMedium, .inTrip):
                    inTripMediumView(trip, now: entry.date)
                case (.systemMedium, .preTrip):
                    mediumView(primary: trip, secondary: entry.trips.dropFirst().first)
                case (_, .inTrip):
                    inTripSmallView(trip, now: entry.date)
                default:
                    smallView(trip)
                }
            } else {
                emptyView
            }
        }
        .modifier(WidgetColorSchemeOverride(appearance: entry.appearance))
    }

    // MARK: In-trip helpers (spec: widget-trip-companion.md)

    /// 事件 kind → SF Symbol。
    private func icon(for kind: String) -> String {
        switch kind {
        case "flight":              return "airplane"
        case "train":               return "tram.fill"
        case "bus":                 return "bus"
        case "ferry", "cruise":     return "ferry"
        case "carRental":           return "car.fill"
        case "checkin", "checkout", "lodging": return "bed.double.fill"
        case "food":                return "fork.knife"
        case "sightseeing":         return "camera.fill"
        case "activity":            return "figure.walk"
        case "shopping":            return "bag.fill"
        default:                    return "mappin.circle.fill"
        }
    }

    /// 事件标题文本：checkin/checkout 前缀本地化（用户数据拼在后），其余直接用用户数据。
    @ViewBuilder
    private func eventTitle(_ ev: WidgetEvent) -> some View {
        switch ev.kind {
        case "checkin":
            if ev.primary.isEmpty { Text("widget.companion.checkin") }
            else { Text("widget.companion.checkin") + Text(verbatim: " · \(ev.primary)") }
        case "checkout":
            if ev.primary.isEmpty { Text("widget.companion.checkout") }
            else { Text("widget.companion.checkout") + Text(verbatim: " · \(ev.primary)") }
        default:
            Text(ev.primary.isEmpty ? ev.secondary : ev.primary)
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
        VStack(alignment: .leading, spacing: 4) {
            dayHeader(trip, now: now)
            Spacer(minLength: 6)
            if let ev = trip.nextEvent(asOf: now) {
                HStack(spacing: 5) {
                    Image(systemName: icon(for: ev.kind)).font(.subheadline)
                    eventTitle(ev)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(ev.date, style: .relative)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(trip.displayTitle)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            if let stay = trip.tonightStay(asOf: now) {
                tonightRow(stay)
            }
        }
        .widgetURL(trip.deepLink)
    }

    // MARK: In-trip Medium

    private func inTripMediumView(_ trip: WidgetTrip, now: Date) -> some View {
        let next = trip.nextEvent(asOf: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    dayHeader(trip, now: now)
                    Text(trip.displayTitle)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .lineLimit(1)
                    if let ev = next {
                        HStack(spacing: 5) {
                            Image(systemName: icon(for: ev.kind)).font(.caption)
                            eventTitle(ev).lineLimit(1)
                        }
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        if !ev.secondary.isEmpty {
                            Text(ev.secondary)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                if let ev = next {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ev.date, style: .relative)
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(ev.date, style: .time)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            if let stay = trip.tonightStay(asOf: now) {
                Divider()
                tonightRow(stay)
            }
        }
        .widgetURL(trip.deepLink)
    }

    // MARK: Small

    private func smallView(_ trip: WidgetTrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            widgetHeader
            Spacer(minLength: 8)
            Text(trip.name.isEmpty ? trip.destinationCity : trip.name)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(countdownText(for: trip.departureDate))
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
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
        }
        .widgetURL(trip.deepLink)
    }

    /// Header row: suitcase icon + "Upcoming" label, both in the same secondary
    /// colour. Used as a small-caption header above the trip name in both sizes.
    private var widgetHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "suitcase.fill")
                .font(.caption)
            Text("widget.header.upcoming")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Medium

    private func mediumView(primary: WidgetTrip, secondary: WidgetTrip?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    widgetHeader
                    Text(primary.name.isEmpty ? primary.destinationCity : primary.name)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .lineLimit(1)
                    Text(countdownText(for: primary.departureDate))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(progressText(primary))
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                progressRing(primary.progress)
                    .frame(width: 58, height: 58)
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
                    Text(countdownText(for: secondary.departureDate))
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .widgetURL(primary.deepLink)
    }

    private func progressRing(_ value: Double) -> some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.001, value))
                .stroke(.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
        }
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
            Text("widget.empty.subtitle")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
        .supportedFamilies([.systemSmall, .systemMedium])
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
