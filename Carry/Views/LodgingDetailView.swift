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

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var addressCopied = false
    @State private var contentHeight: CGFloat = 0

    private var displayName: String {
        stay.name.isEmpty ? NSLocalizedString("itinerary.category.lodging", comment: "") : stay.name
    }

    private var contentDetents: Set<PresentationDetent> {
        guard contentHeight > 0 else { return [.medium, .large] }
        return [.height(contentHeight + 28), .large]
    }

    /// 入住日期（有日期行程）/ 第 N 天（无日期行程）+ 晚数，读成「Sun, Jul 19 · 3 nights」。
    private var stayText: String {
        var parts: [String] = []
        if let bundle = stay.bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            if let d = Calendar.current.date(byAdding: .day, value: stay.checkInDayOrder, to: base) {
                parts.append(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            }
        } else {
            parts.append(String(format: NSLocalizedString("itinerary.day.title", comment: ""), stay.checkInDayOrder + 1))
        }
        parts.append(String(format: NSLocalizedString("itinerary.lodging.nights_value", comment: ""), stay.nights))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                infoRows
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
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(dayColor.opacity(0.15))
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(dayColor)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
            Text(displayName)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .glassCircleButton()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.close"))
        }
    }

    @ViewBuilder
    private var infoRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailRow(icon: "calendar", text: stayText)
            if stay.checkInMinutes >= 0 {
                detailRow(icon: "clock",
                          text: NSLocalizedString("itinerary.lodging.event.checkin", comment: "") + " " + timeLabel(dayMinutes: stay.checkInMinutes))
            }
            if stay.checkOutMinutes >= 0 {
                detailRow(icon: "clock",
                          text: NSLocalizedString("itinerary.lodging.event.checkout", comment: "") + " " + timeLabel(dayMinutes: stay.checkOutMinutes))
            }
            if stay.hasCost {
                detailRow(icon: "creditcard", text: CurrencyCatalog.format(stay.costAmount, code: stay.costCurrencyCode))
            }
            if !stay.confirmationCode.isEmpty {
                detailRow(icon: "ticket",
                          text: NSLocalizedString("itinerary.transport.field.confirmation", comment: "") + " " + stay.confirmationCode)
            }
            if stay.hasCoordinate && !stay.address.isEmpty {
                addressRow
            }
            if !stay.note.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                        .accessibilityHidden(true)
                    ExpandableText(text: stay.note, font: .system(.subheadline, design: .rounded), collapsedLineLimit: 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var addressRow: some View {
        Button {
            UIPasteboard.general.string = stay.address
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) { addressCopied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeInOut(duration: 0.2)) { addressCopied = false }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                    .accessibilityHidden(true)
                Text(stay.address)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if addressCopied {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                        Text("itinerary.stop.detail.address_copied")
                    }
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(stay.address))
        .accessibilityHint(Text("itinerary.stop.detail.copy_hint"))
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
