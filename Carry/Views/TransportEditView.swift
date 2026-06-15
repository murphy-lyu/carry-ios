//
//  TransportEditView.swift
//  Carry
//
//  交通段（边）的新增 / 编辑表单。spec: itinerary-transport-lodging.md。
//  航班 / 火车 / 巴士 / 渡轮 / 自驾 / 其他通用：承运方·班次 + 起降站（可地理搜索取坐标）
//  + 起降日期与时间（跨天/跨时区）+ 座位 / 确认号 / 备注。
//
//  字体：表单走系统 Form（SF 默认），符合 design-system「表单输入 / 系统控件 = SF」。
//

import SwiftUI
import MapKit

struct TransportEditView: View {
    let tripId: UUID
    /// 非 nil = 编辑现有段；nil = 在 `dayId` 末尾新增。
    var segmentId: UUID? = nil
    /// 新增时归属的出发日；编辑时可空（用段自身的 day）。
    var dayId: UUID? = nil
    /// 新增时的默认模式（统一「+」入口按所选类型传入）。
    var initialMode: TransportMode = .flight

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    // 表单状态
    @State private var mode: TransportMode = .flight
    @State private var carrier = ""
    @State private var number = ""

    @State private var fromName = ""
    @State private var fromCode = ""
    @State private var fromTerminal = ""
    @State private var fromLatitude: Double = 0
    @State private var fromLongitude: Double = 0

    @State private var toName = ""
    @State private var toCode = ""
    @State private var toTerminal = ""
    @State private var toLatitude: Double = 0
    @State private var toLongitude: Double = 0

    @State private var departDayOrder = 0
    @State private var hasDepartTime = false
    @State private var departTime = Date()
    @State private var arriveDayOrder = 0
    @State private var hasArriveTime = false
    @State private var arriveTime = Date()

    @State private var seat = ""
    @State private var confirmationCode = ""
    @State private var note = ""
    @State private var costAmountText = ""
    @State private var costCurrencyCode = ""

    @State private var didLoad = false
    /// 起 / 落地点搜索 sheet（nil = 不显示；true = 搜出发，false = 搜到达）。
    @State private var searchingFrom: Bool? = nil

    private var isEditing: Bool { segmentId != nil }
    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var days: [ItineraryDay] { bundle?.safeItineraryDays ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                carrierSection
                placeSection(isFrom: true)
                placeSection(isFrom: false)
                moreSection
                if isEditing { deleteSection }
            }
            .navigationTitle(Text(isEditing ? "itinerary.transport.edit.title" : "itinerary.transport.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAndDismiss() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .sheet(item: Binding(
                get: { searchingFrom.map { SearchTarget(isFrom: $0) } },
                set: { searchingFrom = $0?.isFrom }
            )) { target in
                ItineraryPlaceSearchSheet(
                    titleKey: "itinerary.transport.field.place",
                    placeholderKey: "itinerary.transport.search.placeholder",
                    biasLatitude: bundle?.latitude ?? 0,
                    biasLongitude: bundle?.longitude ?? 0
                ) { name, lat, lon, _ in
                    if target.isFrom {
                        fromName = name; fromLatitude = lat; fromLongitude = lon
                    } else {
                        toName = name; toLatitude = lat; toLongitude = lon
                    }
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    // MARK: Sections

    private var typeSection: some View {
        Section {
            Picker(selection: $mode) {
                ForEach(TransportMode.allCases, id: \.self) { m in
                    Label(m.titleKey, systemImage: m.symbolName).tag(m)
                }
            } label: {
                Text("itinerary.transport.section.type")
            }
        }
    }

    private var carrierSection: some View {
        Section {
            TextField("itinerary.transport.field.carrier", text: $carrier)
            TextField("itinerary.transport.field.number", text: $number)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
        }
    }

    @ViewBuilder
    private func placeSection(isFrom: Bool) -> some View {
        let name = isFrom ? fromName : toName
        let code = Binding(get: { isFrom ? fromCode : toCode },
                           set: { if isFrom { fromCode = $0 } else { toCode = $0 } })
        let terminal = Binding(get: { isFrom ? fromTerminal : toTerminal },
                               set: { if isFrom { fromTerminal = $0 } else { toTerminal = $0 } })
        let dayOrder = Binding(get: { isFrom ? departDayOrder : arriveDayOrder },
                               set: { if isFrom { departDayOrder = $0 } else { arriveDayOrder = $0 } })
        let hasTime = Binding(get: { isFrom ? hasDepartTime : hasArriveTime },
                              set: { if isFrom { hasDepartTime = $0 } else { hasArriveTime = $0 } })
        let time = Binding(get: { isFrom ? departTime : arriveTime },
                           set: { if isFrom { departTime = $0 } else { arriveTime = $0 } })

        Section {
            // 地点行：点开搜索取坐标；有名字显示名字，否则提示。
            Button {
                searchingFrom = isFrom
            } label: {
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    (name.isEmpty ? Text("itinerary.transport.field.place") : Text(name))
                        .foregroundStyle(name.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            TextField("itinerary.transport.field.code", text: code)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            TextField("itinerary.transport.field.terminal", text: terminal)
            if days.count > 1 {
                Picker(selection: dayOrder) {
                    ForEach(days, id: \.sortOrder) { day in
                        Text(dayLabel(day.sortOrder)).tag(day.sortOrder)
                    }
                } label: {
                    Text("itinerary.transport.field.day")
                }
            }
            Toggle("itinerary.transport.field.time", isOn: hasTime.animation())
            if hasTime.wrappedValue {
                DatePicker("itinerary.transport.field.time", selection: time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } header: {
            Text(isFrom ? "itinerary.transport.section.depart" : "itinerary.transport.section.arrive")
        }
    }

    private var moreSection: some View {
        Section {
            CostInputRow(amountText: $costAmountText, currencyCode: $costCurrencyCode)
            TextField("itinerary.transport.field.seat", text: $seat)
            TextField("itinerary.transport.field.confirmation", text: $confirmationCode)
                .autocorrectionDisabled()
            TextField("itinerary.transport.field.note", text: $note, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("itinerary.transport.section.more")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                deleteAndDismiss()
            } label: {
                Text("itinerary.transport.delete")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: Helpers

    /// 至少要有「班次号」或「出发地名」才允许保存——避免落一条空段。
    private var canSave: Bool {
        !number.trimmingCharacters(in: .whitespaces).isEmpty
            || !fromName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 日期标签：有日期行程「周几 月/日」，无日期行程「Day N」。
    private func dayLabel(_ order: Int) -> String {
        if let bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: order, to: base) ?? base
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), order + 1)
    }

    private func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func dateFromMinutes(_ m: Int) -> Date {
        let start = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .minute, value: max(0, m), to: start) ?? start
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        // 编辑：用现有段回填。
        if let segmentId,
           let seg = days.flatMap({ $0.sortedSegments }).first(where: { $0.id == segmentId }) {
            mode = seg.mode
            carrier = seg.carrier; number = seg.number
            fromName = seg.fromName; fromCode = seg.fromCode; fromTerminal = seg.fromTerminal
            fromLatitude = seg.fromLatitude; fromLongitude = seg.fromLongitude
            toName = seg.toName; toCode = seg.toCode; toTerminal = seg.toTerminal
            toLatitude = seg.toLatitude; toLongitude = seg.toLongitude
            departDayOrder = seg.departDayOrder; arriveDayOrder = seg.arriveDayOrder
            if seg.departLocalMinutes >= 0 { hasDepartTime = true; departTime = dateFromMinutes(seg.departLocalMinutes) }
            if seg.arriveLocalMinutes >= 0 { hasArriveTime = true; arriveTime = dateFromMinutes(seg.arriveLocalMinutes) }
            seat = seg.seat; confirmationCode = seg.confirmationCode; note = seg.note
            if seg.hasCost { costAmountText = CurrencyCatalog.amountText(seg.costAmount); costCurrencyCode = seg.costCurrencyCode }
        } else {
            // 新增：默认模式 + 起降日落到目标天。
            mode = initialMode
            let order = days.first(where: { $0.id == dayId })?.sortOrder ?? 0
            departDayOrder = order
            arriveDayOrder = order
        }
    }

    private func saveAndDismiss() {
        let departMinutes = hasDepartTime ? minutes(from: departTime) : -1
        let arriveMinutes = hasArriveTime ? minutes(from: arriveTime) : -1
        // 到达日不得早于出发日（夹断）。
        let safeArriveDay = max(arriveDayOrder, departDayOrder)

        if let segmentId {
            store.updateTransportSegment(
                tripId: tripId, segmentId: segmentId,
                mode: mode, carrier: carrier, number: number,
                fromName: fromName, fromCode: fromCode,
                fromLatitude: fromLatitude, fromLongitude: fromLongitude,
                fromTerminal: fromTerminal,
                toName: toName, toCode: toCode,
                toLatitude: toLatitude, toLongitude: toLongitude,
                toTerminal: toTerminal,
                departDayOrder: departDayOrder, departLocalMinutes: departMinutes,
                arriveDayOrder: safeArriveDay, arriveLocalMinutes: arriveMinutes,
                seat: seat, confirmationCode: confirmationCode, note: note
            )
            store.setTransportCost(tripId: tripId, segmentId: segmentId,
                                   amount: costAmountValue, currencyCode: costCurrencyToSave)
        } else if let dayId {
            if let newId = store.addTransportSegment(
                tripId: tripId, dayId: dayId,
                mode: mode, carrier: carrier, number: number,
                fromName: fromName, fromCode: fromCode,
                fromLatitude: fromLatitude, fromLongitude: fromLongitude,
                fromTerminal: fromTerminal,
                toName: toName, toCode: toCode,
                toLatitude: toLatitude, toLongitude: toLongitude,
                toTerminal: toTerminal,
                departDayOrder: departDayOrder, departLocalMinutes: departMinutes,
                arriveDayOrder: safeArriveDay, arriveLocalMinutes: arriveMinutes,
                seat: seat, confirmationCode: confirmationCode, note: note
            ) {
                store.setTransportCost(tripId: tripId, segmentId: newId,
                                       amount: costAmountValue, currencyCode: costCurrencyToSave)
            }
        }
        dismiss()
    }

    /// 解析录入的金额（空 → 0）。
    private var costAmountValue: Double {
        CurrencyCatalog.parseAmount(costAmountText)
    }

    /// 要保存的币种：金额留空 → "" 清除费用；否则用选定币种，未选则跟随本位币。
    private var costCurrencyToSave: String {
        costAmountText.trimmingCharacters(in: .whitespaces).isEmpty
            ? ""
            : (costCurrencyCode.isEmpty ? CurrencyCatalog.homeCurrencyCode : costCurrencyCode.uppercased())
    }

    private func deleteAndDismiss() {
        guard let segmentId,
              let day = days.first(where: { d in (d.segments ?? []).contains { $0.id == segmentId } }) else { return }
        store.removeTransportSegment(tripId: tripId, dayId: day.id, segmentId: segmentId)
        dismiss()
    }
}

/// 让 Bool 能驱动 .sheet(item:)。
private struct SearchTarget: Identifiable {
    let isFrom: Bool
    var id: Bool { isFrom }
}
