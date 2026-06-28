//
//  CalendarEventDetailView.swift
//  Carry
//
//  只读日历事件详情浮层（spec: itinerary-calendar-overlay.md）。
//  点击行程规划里的日历事件 → 在 Carry **内** 弹此浮层，不跳系统日历——行程规划是核心页，
//  误触跳出 App 体感差。视觉**完全对齐**其它只读详情（地点/住宿/交通）：DetailSheetHeader
//  （图标圈 + 标题 + 副标题=日期时间）+ 灰画布上的白卡分组。差异仅「无底部动作条」——系统
//  日历事件在 Carry 里只读，不可编辑/删除。
//

import SwiftUI

struct CalendarEventDetailView: View {
    let event: CalendarOverlayEvent

    @Environment(\.dismiss) private var dismiss
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var selectedDetent: PresentationDetent = .height(UIScreen.main.bounds.height * 0.50)

    /// sheet 高度贴着内容（稀疏事件不留大片空白）。单一真源 cappedContentHeight：钳在屏高以下，
    /// 长事件也不会顶满屏触发 iOS 26 脱离（斜滚根因）。头部钉在顶、故 detent = 头 + 卡片内容。
    private let collapsedH = UIScreen.main.bounds.height * 0.50
    private let expandedMaxH = UIScreen.main.bounds.height * 0.90

    private var contentDetents: Set<PresentationDetent> {
        let idealH = headerHeight + contentHeight + 8
        let expandedH = idealH > 0 ? min(idealH, expandedMaxH) : expandedMaxH
        return [.height(collapsedH), .height(expandedH)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部钉在顶部不随滚动（与 DetailSheetScaffold 同结构），坐在不透明灰画布上、与白卡拉开层次。
            DetailSheetHeader(
                iconSystemName: "calendar",
                iconTint: event.tint,
                title: displayTitle,
                subtitle: dateText,   // 日期·时间进副标题（schedule 槽位），与地点/景区一致
                onClose: { dismiss() }
            )
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(heightReader($headerHeight))
            .background(Color.carryCanvas)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    infoCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)     // 首卡向上柔性阴影渲染在裁切边界内，不被顶部切掉
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(heightReader($contentHeight))
            }
        }
        .presentationDetents(contentDetents, selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.carryCanvas)
    }

    /// 信息卡：地址 → 备注 → 链接 → 来源日历（色点 + 日历名，对标 Apple 日历事件底部的来源色签，放最后）。
    /// 顺序逻辑：内容（在哪 → 写了啥 → 可点链接）在前，元信息（来源日历）沉底。前几项都可能空；来源行恒在，故卡不空。
    private var infoCard: some View {
        DetailRowGroup(rows: infoCardRows)
    }

    private var infoCardRows: [AnyView] {
        var rows: [AnyView] = []
        // 地点：系统事件的 location 是自由文本（常是多行地址）→ 长按可复制（粘到地图/发司机），与地点/住宿地址一致。
        if !event.location.isEmpty {
            rows.append(AnyView(CopyableDetailRow(icon: "mappin.and.ellipse",
                                                  labelKey: "itinerary.lodging.field.address",
                                                  value: event.location)))
        }
        if !event.notes.isEmpty {
            rows.append(AnyView(NoteDetailRow(text: event.notes)))
        }
        // 链接（会议/预订/详情）：可点打开，紧跟内容、在来源元信息之上。复用附件链接的本地化 key。
        if !event.url.isEmpty {
            rows.append(AnyView(LinkDetailRow(labelKey: "itinerary.attachment.link_url", urlString: event.url)))
        }
        rows.append(AnyView(sourceRow))
        return rows
    }

    /// 来源行：日历色点 + 日历名（如「中国大陆节假日」）——对标 Apple 日历的来源色签。
    /// 色点已是「来源日历」的通用语义，无需再加「Calendar」标签（零新增本地化）。
    private var sourceRow: some View {
        HStack(alignment: .center, spacing: 12) {
            // 色点落在 22pt 图标槽内，与其它行的图标列左对齐。
            Circle().fill(event.tint).frame(width: 10, height: 10).frame(width: 22)
                .accessibilityHidden(true)
            Text(event.calendarTitle)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func heightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { binding.wrappedValue = g.size.height }
                .onChange(of: g.size.height) { _, h in binding.wrappedValue = h }
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
