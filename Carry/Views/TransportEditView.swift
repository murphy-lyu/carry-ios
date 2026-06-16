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
                    titleKey: stationLabel(isFrom: target.isFrom),
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

    // MARK: 类型自适应（spec: itinerary-cost-tracking 之外的交互打磨 — Type 唯一权威，字段随之切换）

    /// 承运方标签：航班=航空公司、火车/巴士/渡轮=运营商、租车=公司、其他=承运方。
    private var carrierLabel: LocalizedStringKey {
        switch mode {
        case .flight:               return "itinerary.transport.field.airline"
        case .train, .bus, .ferry:  return "itinerary.transport.field.operator"
        case .carRental:            return "itinerary.transport.field.company"
        case .other:                return "itinerary.transport.field.carrier"
        }
    }

    /// 班次号：租车无班次号 → 隐藏。
    private var showsNumber: Bool { mode != .carRental }
    private var numberLabel: LocalizedStringKey {
        switch mode {
        case .flight: return "itinerary.transport.field.flight_number"
        case .train:  return "itinerary.transport.field.train_number"
        default:      return "itinerary.transport.field.number"
        }
    }

    /// 站点标签：机场 / 车站 / 港口 / 取车·还车地点 / 地点。
    private func stationLabel(isFrom: Bool) -> LocalizedStringKey {
        switch mode {
        case .flight:    return "itinerary.transport.field.airport"
        case .train, .bus: return "itinerary.transport.field.station"
        case .ferry:     return "itinerary.transport.field.port"
        case .carRental: return isFrom ? "itinerary.transport.field.pickup_location" : "itinerary.transport.field.dropoff_location"
        case .other:     return "itinerary.transport.field.place"
        }
    }

    /// 代码（IATA / 车站代码）与航站楼/站台：仅航班、火车有意义。
    private var showsCode: Bool { mode == .flight || mode == .train }
    private var showsTerminal: Bool { mode == .flight || mode == .train }
    private var terminalLabel: LocalizedStringKey {
        mode == .train ? "itinerary.transport.field.platform" : "itinerary.transport.field.terminal_only"
    }

    /// 段头：租车=取车/还车，其余=出发/到达。
    private func sectionHeaderLabel(isFrom: Bool) -> LocalizedStringKey {
        if mode == .carRental {
            return isFrom ? "itinerary.transport.section.pickup" : "itinerary.transport.section.dropoff"
        }
        return isFrom ? "itinerary.transport.section.depart" : "itinerary.transport.section.arrive"
    }

    /// 座位：租车无座位号 → 隐藏。
    private var showsSeat: Bool { mode != .carRental }

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
            TextField(carrierLabel, text: $carrier)
            if showsNumber {
                TextField(numberLabel, text: $number)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
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
                    (name.isEmpty ? Text(stationLabel(isFrom: isFrom)) : Text(name))
                        .foregroundStyle(name.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            if showsCode {
                TextField("itinerary.transport.field.code", text: code)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
            if showsTerminal {
                TextField(terminalLabel, text: terminal)
            }
            if days.count > 1 {
                Picker(selection: dayOrder) {
                    ForEach(days, id: \.sortOrder) { day in
                        Text(dayLabel(day.sortOrder)).tag(day.sortOrder)
                    }
                } label: {
                    Text("itinerary.transport.field.day")
                }
            }
            // 单行「标签 · 时间 chip · 开关」，避免 labelsHidden 选择器单独占行、左侧留空。
            HStack(spacing: 12) {
                Text("itinerary.transport.field.time")
                    .accessibilityHidden(true)
                Spacer()
                if hasTime.wrappedValue {
                    DatePicker("itinerary.transport.field.time", selection: time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                Toggle("itinerary.transport.field.time", isOn: hasTime.animation())
                    .labelsHidden()
            }
        } header: {
            Text(sectionHeaderLabel(isFrom: isFrom))
        }
    }

    private var moreSection: some View {
        Section {
            CostInputRow(amountText: $costAmountText, currencyCode: $costCurrencyCode)
            if showsSeat {
                TextField("itinerary.transport.field.seat", text: $seat)
            }
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

        // 当前模式隐藏的字段不入库——否则「填了航班号 → 改成租车」会把残留航班号存进租车段、
        // 在时间轴里显示出来。保存时按最终模式清空隐藏字段，保证数据与类型一致。
        let savedNumber = showsNumber ? number : ""
        let savedFromCode = showsCode ? fromCode : ""
        let savedToCode = showsCode ? toCode : ""
        let savedFromTerminal = showsTerminal ? fromTerminal : ""
        let savedToTerminal = showsTerminal ? toTerminal : ""
        let savedSeat = showsSeat ? seat : ""

        if let segmentId {
            store.updateTransportSegment(
                tripId: tripId, segmentId: segmentId,
                mode: mode, carrier: carrier, number: savedNumber,
                fromName: fromName, fromCode: savedFromCode,
                fromLatitude: fromLatitude, fromLongitude: fromLongitude,
                fromTerminal: savedFromTerminal,
                toName: toName, toCode: savedToCode,
                toLatitude: toLatitude, toLongitude: toLongitude,
                toTerminal: savedToTerminal,
                departDayOrder: departDayOrder, departLocalMinutes: departMinutes,
                arriveDayOrder: safeArriveDay, arriveLocalMinutes: arriveMinutes,
                seat: savedSeat, confirmationCode: confirmationCode, note: note
            )
            store.setTransportCost(tripId: tripId, segmentId: segmentId,
                                   amount: costAmountValue, currencyCode: costCurrencyToSave)
        } else if let dayId {
            if let newId = store.addTransportSegment(
                tripId: tripId, dayId: dayId,
                mode: mode, carrier: carrier, number: savedNumber,
                fromName: fromName, fromCode: savedFromCode,
                fromLatitude: fromLatitude, fromLongitude: fromLongitude,
                fromTerminal: savedFromTerminal,
                toName: toName, toCode: savedToCode,
                toLatitude: toLatitude, toLongitude: toLongitude,
                toTerminal: savedToTerminal,
                departDayOrder: departDayOrder, departLocalMinutes: departMinutes,
                arriveDayOrder: safeArriveDay, arriveLocalMinutes: arriveMinutes,
                seat: savedSeat, confirmationCode: confirmationCode, note: note
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
