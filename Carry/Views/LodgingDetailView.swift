//
//  LodgingDetailView.swift
//  Carry
//
//  住宿【只读详情】：点住宿条先看信息（半高 sheet），底部 Edit 再进编辑——与停靠点详情同一交互
//  （spec: itinerary-entity-detail-unify.md）。有值才显、空的不显；有坐标则带 Get Directions（去酒店）。
//

import SwiftUI

struct LodgingDetailView: View {
    let tripId: UUID
    let stay: LodgingStay
    let navApps: [MapNavigationApp]
    let dayColor: Color

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var contentHeight: CGFloat = 0

    private var displayName: String {
        stay.name.isEmpty ? NSLocalizedString("itinerary.category.lodging", comment: "") : stay.name
    }

    private var contentDetents: Set<PresentationDetent> {
        guard contentHeight > 0 else { return [.medium, .large] }
        return [.height(contentHeight + 28), .large]
    }

    /// 某天序对应的日期文案（有日期行程 → 「Sun, Jul 19」；无日期 → 「第 N 天」）。
    private func dayDateText(_ dayOrder: Int) -> String {
        if let bundle = stay.bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            if let d = Calendar.current.date(byAdding: .day, value: dayOrder, to: base) {
                return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            }
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), dayOrder + 1)
    }

    /// 入住 / 退房各自的「日期（+ 时间）」值——每个都绑定到具体哪天（对标 Tripsy，避免两个时间分不清谁是谁）。
    private var checkInValue: String {
        var s = dayDateText(stay.checkInDayOrder)
        if stay.checkInMinutes >= 0 { s += " · " + timeLabel(dayMinutes: stay.checkInMinutes) }
        return s
    }
    private var checkOutValue: String {
        var s = dayDateText(stay.checkOutDayOrder)
        if stay.checkOutMinutes >= 0 { s += " · " + timeLabel(dayMinutes: stay.checkOutMinutes) }
        return s
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                infoCard
                if let coord = stay.coordinate, !navApps.isEmpty {
                    DirectionsModule(coordinate: coord, name: displayName, navApps: navApps, tint: .accentColor)
                }
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
            LodgingEditView(tripId: tripId, stayId: stay.id)
        }
    }

    private var header: some View {
        DetailSheetHeader(
            iconSystemName: "bed.double.fill",
            iconTint: dayColor,
            title: displayName,
            onDelete: deleteStay,
            onClose: { dismiss() }
        )
    }

    private func deleteStay() {
        store.removeLodgingStay(tripId: tripId, stayId: stay.id)
        dismiss()
    }

    /// 信息分组卡：每行带标签、行间细分隔、有值才显（学 Tripsy 的高可读）。
    private var infoCard: some View {
        var rows: [AnyView] = [
            // 入住 / 退房各带「日期（+时间）」，绑定到具体哪天。
            AnyView(LabeledDetailRow(icon: "calendar", labelKey: "itinerary.lodging.event.checkin", value: checkInValue)),
            AnyView(LabeledDetailRow(icon: "calendar", labelKey: "itinerary.lodging.event.checkout", value: checkOutValue)),
            // 标签单复数：1 晚用单数（Night/Nacht…），≥2 用复数；zh/ja/ko 无单复数、两者同形。
            AnyView(LabeledDetailRow(icon: "moon",
                                     labelKey: stay.nights == 1 ? "itinerary.lodging.field.nights.one" : "itinerary.lodging.field.nights",
                                     value: "\(stay.nights)")),
        ]
        // 先地址（找到酒店要用的定位）→ 再确认号（前台入住要出示的凭据）→ 最后才是费用。费用属财务、置于体验性信息之后。
        if stay.hasCoordinate && !stay.address.isEmpty {
            rows.append(AnyView(CopyableDetailRow(icon: "mappin.and.ellipse", labelKey: "itinerary.lodging.field.address", value: stay.address)))
        }
        if !stay.confirmationCode.isEmpty {
            rows.append(AnyView(CopyableDetailRow(icon: "ticket", labelKey: "itinerary.transport.field.confirmation", value: stay.confirmationCode)))
        }
        if stay.hasCost {
            rows.append(AnyView(LabeledDetailRow(icon: "creditcard", labelKey: "cost.field.label",
                                                 value: CurrencyCatalog.format(stay.costAmount, code: stay.costCurrencyCode))))
        }
        if !stay.note.isEmpty {
            rows.append(AnyView(NoteDetailRow(text: stay.note)))
        }
        return DetailRowGroup(rows: rows)
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
