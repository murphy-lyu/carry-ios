//
//  TransportDetailView.swift
//  Carry
//
//  交通【只读详情】：点交通段先看信息（半高 sheet），底部 Edit 再进编辑——与停靠点 / 住宿详情同一交互
//  （spec: itinerary-entity-detail-unify.md）。有值才显、空的不显。交通不带 Get Directions（导航去"出发站"意义不大）。
//

import SwiftUI

struct TransportDetailView: View {
    let tripId: UUID
    let segment: TransportSegment
    let dayColor: Color

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var contentHeight: CGFloat = 0

    private var contentDetents: Set<PresentationDetent> {
        guard contentHeight > 0 else { return [.medium, .large] }
        return [.height(contentHeight + 28), .large]
    }

    /// 标题：航司 · 班次；都空则退化用 mode 名（与时间轴行一致）。
    private var titleText: String {
        let parts = [segment.carrier, segment.number].filter { !$0.isEmpty }
        return parts.isEmpty ? NSLocalizedString(segment.mode.localizationKey, comment: "") : parts.joined(separator: " · ")
    }

    /// 「站名 (代码) · 09:00 +1 · T2」，缺项自适应；全空返回 nil（不显该行）。
    private func endpointText(name: String, code: String, minutes: Int, dayOffset: Int, terminal: String) -> String? {
        var parts: [String] = []
        let place = code.isEmpty ? name : (name.isEmpty ? code : "\(name) (\(code))")
        if !place.isEmpty { parts.append(place) }
        if minutes >= 0 {
            var t = timeLabel(dayMinutes: minutes)
            if dayOffset > 0 { t += " +\(dayOffset)" }
            parts.append(t)
        }
        if !terminal.isEmpty { parts.append(terminal) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                infoRows
                editButton
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
        .sheet(isPresented: $editing) {
            TransportEditView(tripId: tripId, segmentId: segment.id)
        }
    }

    private var header: some View {
        DetailSheetHeader(
            iconSystemName: segment.mode.symbolName,
            iconTint: dayColor,
            title: titleText,
            deleteLabelKey: "itinerary.transport.delete",
            onEdit: { editing = true },
            onDelete: deleteSegment,
            onClose: { dismiss() }
        )
    }

    private func deleteSegment() {
        if let dayId = segment.day?.id {
            store.removeTransportSegment(tripId: tripId, dayId: dayId, segmentId: segment.id)
        }
        dismiss()
    }

    @ViewBuilder
    private var infoRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let dep = endpointText(name: segment.fromName, code: segment.fromCode,
                                      minutes: segment.departLocalMinutes, dayOffset: 0,
                                      terminal: segment.fromTerminal) {
                LabeledDetailRow(icon: "arrow.up.forward", labelKey: "itinerary.transport.section.depart", value: dep)
            }
            if let arr = endpointText(name: segment.toName, code: segment.toCode,
                                      minutes: segment.arriveLocalMinutes,
                                      dayOffset: segment.arriveDayOrder - segment.departDayOrder,
                                      terminal: segment.toTerminal) {
                LabeledDetailRow(icon: "arrow.down.forward", labelKey: "itinerary.transport.section.arrive", value: arr)
            }
            if !segment.seat.isEmpty {
                DetailInfoRow(icon: "chair", text: segment.seat)
            }
            if !segment.confirmationCode.isEmpty {
                CopyableDetailRow(icon: "ticket", text: segment.confirmationCode)   // 只显内容、可点复制
            }
            if segment.hasCost {
                DetailInfoRow(icon: "creditcard", text: CurrencyCatalog.format(segment.costAmount, code: segment.costCurrencyCode))
            }
            if !segment.note.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                        .accessibilityHidden(true)
                    ExpandableText(text: segment.note, font: .system(.subheadline, design: .rounded), collapsedLineLimit: 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var editButton: some View {
        Button { editing = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "pencil").font(.system(size: 14, weight: .semibold))
                Text("itinerary.stop.detail.edit")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
