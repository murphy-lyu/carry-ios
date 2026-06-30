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
                    Text(String.localizedStringWithFormat(String(localized: "widget.liveactivity.progress"), packed, total))
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

// MARK: - 出行日「下一程」Live Activity（spec: widget-transit-live-activity.md）

/// 交通段 mode → SF Symbol。
private func transitIcon(_ modeRaw: String) -> String {
    switch modeRaw {
    case "flight":    return "airplane"
    case "train":     return "tram.fill"
    case "bus":       return "bus"
    case "ferry":     return "ferry"
    case "carRental": return "car.fill"
    default:          return "arrow.right"
    }
}

/// 当前相位（按 `Date()` 在渲染时判定）。
private enum TransitPhase { case beforeDeparture, enRoute, arrived }
private func transitPhase(_ s: TransportActivityAttributes.ContentState, now: Date) -> TransitPhase {
    if now < s.departureDate { return .beforeDeparture }
    if now < s.arrivalDate { return .enRoute }
    return .arrived
}

struct CarryTransitLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransportActivityAttributes.self) { context in
            TransitLockScreenView(state: context.state)
                .activityBackgroundTint(.clear)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: transitIcon(s.modeRaw))
                            .font(.system(size: 14, weight: .semibold))
                        Text(s.carrierAndNumber.isEmpty ? s.fromLabel : s.carrierAndNumber)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(verbatim: "\(s.fromLabel) → \(s.toLabel)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    transitCountdown(s, now: Date(), large: true)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                }
            } compactLeading: {
                Image(systemName: transitIcon(s.modeRaw))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            } compactTrailing: {
                transitCompactTrailing(s, now: Date())
            } minimal: {
                Image(systemName: transitIcon(s.modeRaw))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .keylineTint(.primary)
        }
    }
}

/// 倒计时 + 状态说明（展开态 bottom / 锁屏复用）。
@ViewBuilder
private func transitCountdown(_ s: TransportActivityAttributes.ContentState, now: Date, large: Bool) -> some View {
    let phase = transitPhase(s, now: now)
    HStack(alignment: .firstTextBaseline) {
        switch phase {
        case .beforeDeparture:
            Text(timerInterval: now...s.departureDate, countsDown: true)
                .font(.system(size: large ? 22 : 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("widget.transit.until_departure")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        case .enRoute:
            Text("widget.transit.en_route")
                .font(.system(size: large ? 18 : 14, weight: .bold, design: .rounded))
            Spacer(minLength: 4)
            Text(timerInterval: now...s.arrivalDate, countsDown: true)
                .font(.system(size: large ? 16 : 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .arrived:
            Text("widget.transit.arrived")
                .font(.system(size: large ? 18 : 14, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
        }
        if case .beforeDeparture = phase { Spacer(minLength: 4) }
    }
}

/// 灵动岛紧凑 trailing：倒计时（出发前数到起飞，途中数到抵达）。
@ViewBuilder
private func transitCompactTrailing(_ s: TransportActivityAttributes.ContentState, now: Date) -> some View {
    switch transitPhase(s, now: now) {
    case .beforeDeparture:
        Text(timerInterval: now...s.departureDate, countsDown: true)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: 56)
    case .enRoute:
        Text(timerInterval: now...s.arrivalDate, countsDown: true)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: 56)
    case .arrived:
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.green)
    }
}

private struct TransitLockScreenView: View {
    let state: TransportActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：mode 图标 + 班次 + 出发时刻
            HStack {
                Image(systemName: transitIcon(state.modeRaw))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                // 承运方/班次（如「携程租车」「CA1234」）。空则不显——路线已在下方竖排展示，避免重复。
                if !state.carrierAndNumber.isEmpty {
                    Text(state.carrierAndNumber)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer()
                let headerTime: Date = (state.modeRaw == "carRental" && state.isCarRentalDropoff)
                    ? state.arrivalDate : state.departureDate
                Text(headerTime, style: .time)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            // 路线显示：
            // - 航班（有 IATA 码）→ 单行 "CKG → XIY"，码短、一行装得下且更简洁
            // - 租车取车 LA → 显示取车地（空心点）；租车还车 LA → 显示还车地（实心点）
            // - 其他（地名长）→ 竖排双行，空心点=起点、实心点=终点
            let isCarRental = state.modeRaw == "carRental"
            let hasCodes = !state.fromCode.isEmpty && !state.toCode.isEmpty
            let displayLabel: String = isCarRental
                ? (state.isCarRentalDropoff ? state.toLabel : state.fromLabel)
                : state.fromLabel
            let displayIcon: String = isCarRental
                ? (state.isCarRentalDropoff ? "circle.fill" : "circle")
                : "circle"

            if hasCodes && !isCarRental {
                // 航班/火车：单行 CODE → CODE
                Text(verbatim: "\(state.fromCode) → \(state.toCode)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            } else if isCarRental {
                // 租车：单行显示当前相关端（取车地 or 还车地）
                HStack(spacing: 8) {
                    Image(systemName: displayIcon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(displayLabel)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
            } else {
                // 其他（地名长）：竖排双行
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(state.fromLabel)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(state.toLabel)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
            }

            // 倒计时 / 状态 + 航站楼·座位
            transitCountdown(state, now: Date(), large: true)
            if !state.fromTerminal.isEmpty || !state.seat.isEmpty {
                HStack(spacing: 12) {
                    if !state.fromTerminal.isEmpty {
                        Label(state.fromTerminal, systemImage: "building.2")
                    }
                    if !state.seat.isEmpty {
                        Label(state.seat, systemImage: "chair")
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
#endif
