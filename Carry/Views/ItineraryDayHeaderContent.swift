import SwiftUI

/// 日期优先占据横向空间；尾部工具在空间不足时收为图标，保持日期单行。
struct ItineraryDayHeaderContent: View {
    let title: String
    let timeZoneLabel: String?
    let subtitle: String?
    let dayColor: Color
    var optimizeAction: (() -> Void)? = nil
    var optimizeTitle: LocalizedStringKey = "itinerary.optimize.button"

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(dayColor)
                .frame(width: 10, height: 10)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("itinerary.day.title")
                    if let timeZoneLabel {
                        Text(timeZoneLabel)
                            .font(.system(.caption2, design: .rounded).weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            if let optimizeAction {
                Spacer(minLength: 8)
                Button(action: optimizeAction) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            optimizeIcon
                            Text(optimizeTitle).font(.system(.subheadline, design: .rounded))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        optimizeIcon.frame(minWidth: 24)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .padding(.leading, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(optimizeTitle))
                .accessibilityIdentifier("itinerary.day.optimize")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var optimizeIcon: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 13, weight: .medium))
            .accessibilityHidden(true)
    }
}
