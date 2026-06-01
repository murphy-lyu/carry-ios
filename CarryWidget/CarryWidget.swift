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

/// Field-identical mirror of the main app's `WidgetTripSnapshot`, decoded from the
/// JSON the app writes into the App Group UserDefaults.
struct WidgetTrip: Codable, Identifiable {
    let tripId: String
    let name: String
    let destinationCity: String
    let departureDate: Date
    let packedCount: Int
    let totalCount: Int

    var id: String { tripId }

    var progress: Double {
        totalCount > 0 ? Double(packedCount) / Double(totalCount) : 0
    }

    /// carry://trip/{uuid} — handled by CarryApp.onOpenURL.
    var deepLink: URL? { URL(string: "carry://trip/\(tripId)") }

    static let preview = WidgetTrip(
        tripId: "preview",
        name: "Tokyo",
        destinationCity: "Tokyo",
        departureDate: Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date(),
        packedCount: 8,
        totalCount: 12
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
    String(format: NSLocalizedString("widget.progress.packed", comment: ""), trip.packedCount, trip.totalCount)
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
        let uiColor = UIColor.systemBackground.resolvedColor(
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
        let entry = CarryEntry(date: Date(), trips: loadWidgetTrips(), appearance: configuration.appearance)
        // Countdown changes daily — refresh at the next local midnight.
        let nextMidnight = Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(3600)
        return Timeline(entries: [entry], policy: .after(nextMidnight))
    }
}

// MARK: - Views

struct CarryWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: CarryEntry

    var body: some View {
        Group {
            if let trip = entry.trips.first {
                switch family {
                case .systemMedium:
                    mediumView(primary: trip, secondary: entry.trips.dropFirst().first)
                default:
                    smallView(trip)
                }
            } else {
                emptyView
            }
        }
        .modifier(WidgetColorSchemeOverride(appearance: entry.appearance))
    }

    // MARK: Small

    private func smallView(_ trip: WidgetTrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            widgetHeader
            Spacer(minLength: 8)
            Text(trip.name.isEmpty ? trip.destinationCity : trip.name)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(countdownText(for: trip.departureDate))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ProgressView(value: trip.progress)
                .tint(.primary)
                .padding(.top, 8)
            HStack {
                Text(progressText(trip))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((trip.progress * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
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
                .font(.caption.weight(.semibold))
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
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Text(countdownText(for: primary.departureDate))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(progressText(primary))
                        .font(.caption2)
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
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(countdownText(for: secondary.departureDate))
                        .font(.caption2)
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
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("widget.empty.subtitle")
                .font(.caption2)
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
    CarryEntry(date: .now, trips: [])
}
