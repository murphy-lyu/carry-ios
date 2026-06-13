//
//  CarryWidgetLiveActivity.swift
//  CarryWidget
//

import WidgetKit
import SwiftUI

#if canImport(ActivityKit)
import ActivityKit

struct CarryWidgetLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PackingActivityAttributes.self) { context in
            // ── 锁屏 / 横幅 UI ──
            LockScreenView(context: context)
                .activityBackgroundTint(.clear)

        } dynamicIsland: { context in
            DynamicIsland {
                // ── 展开态 ──
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "suitcase.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(context.state.destinationCity)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(departureSummary(date: context.state.departureDate))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PackingProgressRow(
                        packed: context.state.packedItems,
                        total: context.state.totalItems,
                        isCompleted: context.state.isCompleted
                    )
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                // ── 紧凑态 Leading：始终显示行李箱，完成时变绿 ──
                Image(systemName: "suitcase.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(context.state.isCompleted ? .green : .primary)
            } compactTrailing: {
                // ── 紧凑态 Trailing：进度百分比 ──
                let pct = context.state.totalItems > 0
                    ? Int(Double(context.state.packedItems) / Double(context.state.totalItems) * 100)
                    : 0
                Text("\(pct)%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            } minimal: {
                // ── 最小态 ──
                Image(systemName: "suitcase.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .widgetURL(URL(string: "carry://packing/\(context.attributes.tripId.uuidString)"))
            .keylineTint(.primary)
        }
    }
}

// MARK: - 锁屏视图

private struct LockScreenView: View {
    let context: ActivityViewContext<PackingActivityAttributes>

    private var progress: Double {
        let t = context.state.totalItems
        return t > 0 ? Double(context.state.packedItems) / Double(t) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack {
                Image(systemName: "suitcase.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(context.state.tripName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(departureSummary(date: context.state.departureDate))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if context.state.isCompleted {
                // 完成态
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                    Text(String(localized: "widget.liveactivity.completed"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.green)
                }
            } else {
                // 数字区：大号件数 + 百分比
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(context.state.packedItems)")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    Text(" / \(context.state.totalItems)")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }

                // 进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 10)
                        Capsule()
                            .fill(Color.primary)
                            .frame(width: max(geo.size.width * progress, 10), height: 10)
                            .animation(.spring(duration: 0.4, bounce: 0.2), value: progress)
                    }
                }
                .frame(height: 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - 进度条组件（Dynamic Island 展开态用）

private struct PackingProgressRow: View {
    let packed: Int
    let total: Int
    let isCompleted: Bool

    private var progress: Double {
        total > 0 ? Double(packed) / Double(total) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 6)
                    Capsule()
                        .fill(isCompleted ? Color.green : Color.primary)
                        .frame(width: max(geo.size.width * progress, 6), height: 6)
                        .animation(.spring(duration: 0.4, bounce: 0.2), value: progress)
                }
            }
            .frame(height: 6)

            HStack {
                if isCompleted {
                    Label(String(localized: "widget.liveactivity.completed"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.green)
                } else {
                    Text(String(format: String(localized: "widget.liveactivity.progress"), packed, total))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

// MARK: - 工具函数

private func departureSummary(date: Date) -> String {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let departure = calendar.startOfDay(for: date)
    let days = calendar.dateComponents([.day], from: today, to: departure).day ?? 0
    switch days {
    case 0: return String(localized: "widget.liveactivity.departure.today")
    case 1: return String(localized: "widget.liveactivity.departure.tomorrow")
    default: return String(format: String(localized: "widget.liveactivity.departure.days"), days)
    }
}
#endif
