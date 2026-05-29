//
//  CarryWidgetLiveActivity.swift
//  CarryWidget
//

import ActivityKit
import WidgetKit
import SwiftUI

struct CarryWidgetLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PackingActivityAttributes.self) { context in
            // ── 锁屏 / 横幅 UI ──
            LockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground))

        } dynamicIsland: { context in
            DynamicIsland {
                // ── 展开态 ──
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "airplane")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.blue)
                        Text(context.attributes.destinationCity)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(departureSummary(date: context.attributes.departureDate))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PackingProgressRow(
                        packed: context.state.packedItems,
                        total: context.attributes.totalItems,
                        isCompleted: context.state.isCompleted
                    )
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                // ── 紧凑态 Leading：飞机图标 ──
                Image(systemName: context.state.isCompleted ? "checkmark.circle.fill" : "airplane")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(context.state.isCompleted ? .green : .blue)
            } compactTrailing: {
                // ── 紧凑态 Trailing：进度百分比 ──
                let pct = context.attributes.totalItems > 0
                    ? Int(Double(context.state.packedItems) / Double(context.attributes.totalItems) * 100)
                    : 0
                Text("\(pct)%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            } minimal: {
                // ── 最小态：飞机图标 ──
                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .widgetURL(URL(string: "carry://packing"))
            .keylineTint(.blue)
        }
    }
}

// MARK: - 锁屏视图

private struct LockScreenView: View {
    let context: ActivityViewContext<PackingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行
            HStack {
                Image(systemName: "airplane")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(context.attributes.tripName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(departureSummary(date: context.attributes.departureDate))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // 进度行
            PackingProgressRow(
                packed: context.state.packedItems,
                total: context.attributes.totalItems,
                isCompleted: context.state.isCompleted
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 进度条组件（锁屏 + 展开态共用）

private struct PackingProgressRow: View {
    let packed: Int
    let total: Int
    let isCompleted: Bool

    private var progress: Double {
        total > 0 ? Double(packed) / Double(total) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 6)
                    Capsule()
                        .fill(isCompleted ? Color.green : Color.blue)
                        .frame(width: max(geo.size.width * progress, 6), height: 6)
                        .animation(.spring(duration: 0.4, bounce: 0.2), value: progress)
                }
            }
            .frame(height: 6)

            // 标签行
            HStack {
                if isCompleted {
                    Label("打包完成，出发吧 🎉", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Text("已打包 \(packed) / \(total) 件")
                        .font(.system(size: 12, weight: .medium))
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
    case 0: return "今天出发"
    case 1: return "明天出发"
    default: return "\(days) 天后出发"
    }
}
