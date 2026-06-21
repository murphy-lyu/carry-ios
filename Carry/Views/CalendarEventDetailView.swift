//
//  CalendarEventDetailView.swift
//  Carry
//
//  只读日历事件详情浮层（spec: itinerary-calendar-overlay.md）。
//  点击行程规划里的日历事件 → 在 Carry **内** 弹此浮层，不跳系统日历——行程规划是核心页，
//  误触跳出 App 体感差。视觉对齐 StopDetailView（内联头 + 贴内容 detent + 不透明底）。
//

import SwiftUI

struct CalendarEventDetailView: View {
    let event: CalendarOverlayEvent

    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 0

    /// sheet 高度贴着内容（稀疏事件不留大片空白）。+28 ≈ home-indicator 气口。
    private var contentDetents: Set<PresentationDetent> {
        guard contentHeight > 0 else { return [.medium] }
        // 单一真源 cappedContentHeight：钳在屏高以下，长事件也不会顶满屏触发 iOS 26 脱离（斜滚根因）。
        return [.cappedContentHeight(contentHeight + 28)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                infoRows
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { contentHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in contentHeight = h }
            })
        }
        .presentationDetents(contentDetents)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(UIColor.systemBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 来源行：日历色点 + 日历名（如「中国大陆节假日」）+ 内联关闭。
            HStack(spacing: 8) {
                Circle().fill(event.tint).frame(width: 9, height: 9)
                Text(event.calendarTitle)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.secondarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.close"))
            }
            Text(displayTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var infoRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailRow(icon: "calendar", text: dateText)
            if !event.location.isEmpty {
                detailRow(icon: "mappin.and.ellipse", text: event.location)
            }
            if !event.notes.isEmpty {
                detailRow(icon: "note.text", text: event.notes)
            }
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayTitle: String {
        event.title.isEmpty
            ? NSLocalizedString("itinerary.calendar.untitled", comment: "")
            : event.title
    }

    /// 日期文本：全天 → 日期(范围) +「全天」；定时 → 日期 + 时间范围（跨天带两端日期）。
    private var dateText: String {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: event.startDate)
        // 全天事件 endDate 常为「末日次日 00:00」（独占式）→ 显示时回退一天到真正末日。
        let endDay: Date = {
            if event.isAllDay {
                let sod = cal.startOfDay(for: event.endDate)
                return event.endDate == sod ? (cal.date(byAdding: .day, value: -1, to: sod) ?? sod) : sod
            }
            return cal.startOfDay(for: event.endDate)
        }()
        let multiDay = !cal.isDate(startDay, inSameDayAs: endDay)
        let dateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day().weekday(.abbreviated)
        let startStr = event.startDate.formatted(dateStyle)

        if event.isAllDay {
            let allDay = NSLocalizedString("itinerary.calendar.all_day", comment: "")
            return multiDay
                ? "\(startStr) – \(endDay.formatted(dateStyle)) · \(allDay)"
                : "\(startStr) · \(allDay)"
        } else {
            let timeStyle = Date.FormatStyle.dateTime.hour().minute()
            if multiDay {
                return "\(startStr) \(event.startDate.formatted(timeStyle)) – \(endDay.formatted(dateStyle)) \(event.endDate.formatted(timeStyle))"
            }
            return "\(startStr) · \(event.startDate.formatted(timeStyle))–\(event.endDate.formatted(timeStyle))"
        }
    }
}
