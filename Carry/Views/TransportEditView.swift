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
    @State private var fromTimeZoneId = ""

    @State private var toName = ""
    @State private var toCode = ""
    @State private var toTerminal = ""
    @State private var toLatitude: Double = 0
    @State private var toLongitude: Double = 0
    @State private var toTimeZoneId = ""

    @State private var departDayOrder = 0
    @State private var hasDepartTime = false
    @State private var departTime = Date()
    @State private var arriveDayOrder = 0
    @State private var hasArriveTime = false
    @State private var arriveTime = Date()

    @State private var seat = ""
    @State private var confirmationCode = ""
    @State private var note = ""
    @State private var aircraftType = ""
    @State private var distanceMeters: Double = 0
    @State private var durationMinutes: Int = 0
    @State private var costAmountText = ""
    @State private var costCurrencyCode = ""

    // 用航班号自动填（spec: itinerary-flight-lookup.md）
    @State private var lookupDate = Date()
    @State private var lookupStatus: LookupStatus = .idle
    private enum LookupStatus: Equatable { case idle, loading, filled, notFound, failed, notConfigured }

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
                // 航班：走内置机场数据库（全球可搜 + 回填 IATA / 时区）；
                // 其它交通方式：走通用地图地点搜索（火车站 / 港口等）。spec: itinerary-airport-search.md。
                if mode == .flight {
                    AirportSearchSheet(titleKey: stationLabel(isFrom: target.isFrom)) { airport in
                        if target.isFrom {
                            fromName = airport.displayName; fromCode = airport.iata
                            fromLatitude = airport.lat; fromLongitude = airport.lon
                            fromTimeZoneId = airport.tz
                        } else {
                            toName = airport.displayName; toCode = airport.iata
                            toLatitude = airport.lat; toLongitude = airport.lon
                            toTimeZoneId = airport.tz
                        }
                    }
                } else {
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
            // 自定义 Menu 取代原生 Picker：原生折叠态把「✈ + Flight」渲染得紧贴、间距系统控制改不了。
            // 这里自己排版，图标与文字间显式留 6pt 呼吸感；选项仍用内嵌 Picker 保留勾选态、整行可点。
            Menu {
                Picker(selection: $mode) {
                    ForEach(TransportMode.allCases, id: \.self) { m in
                        Label(m.titleKey, systemImage: m.symbolName).tag(m)
                    }
                } label: { EmptyView() }
            } label: {
                HStack {
                    Text("itinerary.transport.section.type")
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbolName)
                        Text(mode.titleKey)
                    }
                    .foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
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
            // 航班：输航班号 + 日期 → 一键自动填全段（spec: itinerary-flight-lookup.md）。是加速器，失败可手填。
            if mode == .flight && FlightLookupConfig.isConfigured {
                DatePicker("itinerary.flight.lookup.date", selection: $lookupDate, displayedComponents: .date)
                Button { lookupFlight() } label: {
                    HStack(spacing: 8) {
                        if lookupStatus == .loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("itinerary.flight.lookup.button")
                        Spacer()
                    }
                }
                .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty || lookupStatus == .loading)
                if let msg = lookupStatusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(lookupStatus == .filled ? Color.secondary : Color(.systemOrange))
                }
                if !aircraftType.isEmpty {
                    LabeledContent {
                        Text(aircraftType)
                    } label: {
                        Text("itinerary.flight.field.aircraft")
                    }
                }
            }
        }
    }

    private var lookupStatusMessage: LocalizedStringKey? {
        switch lookupStatus {
        case .idle, .loading:   return nil
        case .filled:           return "itinerary.flight.lookup.filled"
        case .notFound:         return "itinerary.flight.lookup.notfound"
        case .failed:           return "itinerary.flight.lookup.failed"
        case .notConfigured:    return "itinerary.flight.lookup.failed"
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
            fromTimeZoneId = seg.fromTimeZoneId
            toName = seg.toName; toCode = seg.toCode; toTerminal = seg.toTerminal
            toLatitude = seg.toLatitude; toLongitude = seg.toLongitude
            toTimeZoneId = seg.toTimeZoneId
            departDayOrder = seg.departDayOrder; arriveDayOrder = seg.arriveDayOrder
            if seg.departLocalMinutes >= 0 { hasDepartTime = true; departTime = dateFromMinutes(seg.departLocalMinutes) }
            if seg.arriveLocalMinutes >= 0 { hasArriveTime = true; arriveTime = dateFromMinutes(seg.arriveLocalMinutes) }
            seat = seg.seat; confirmationCode = seg.confirmationCode; note = seg.note
            aircraftType = seg.aircraftType
            distanceMeters = seg.distanceMeters; durationMinutes = seg.durationMinutes
            if seg.hasCost { costAmountText = CurrencyCatalog.amountText(seg.costAmount); costCurrencyCode = seg.costCurrencyCode }
        } else {
            // 新增：默认模式 + 起降日落到目标天。
            mode = initialMode
            let order = days.first(where: { $0.id == dayId })?.sortOrder ?? 0
            departDayOrder = order
            arriveDayOrder = order
        }
        // 航班查询的默认日期 = 出发日对应的真实日期（有日期行程）；无日期行程用今天。
        if let bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            lookupDate = Calendar.current.date(byAdding: .day, value: departDayOrder, to: base) ?? base
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
        // 时区仅航班机场选点会填；切到非航班模式时一并清空，避免残留。
        let savedFromTZ = mode == .flight ? fromTimeZoneId : ""
        let savedToTZ = mode == .flight ? toTimeZoneId : ""
        // 机型 / 航程 / 时长仅航班有意义。
        let savedAircraft = mode == .flight ? aircraftType : ""
        let savedDistance = mode == .flight ? distanceMeters : 0
        let savedDuration = mode == .flight ? durationMinutes : 0

        if let segmentId {
            store.updateTransportSegment(
                tripId: tripId, segmentId: segmentId,
                mode: mode, carrier: carrier, number: savedNumber,
                fromName: fromName, fromCode: savedFromCode,
                fromLatitude: fromLatitude, fromLongitude: fromLongitude,
                fromTimeZoneId: savedFromTZ, fromTerminal: savedFromTerminal,
                toName: toName, toCode: savedToCode,
                toLatitude: toLatitude, toLongitude: toLongitude,
                toTimeZoneId: savedToTZ, toTerminal: savedToTerminal,
                departDayOrder: departDayOrder, departLocalMinutes: departMinutes,
                arriveDayOrder: safeArriveDay, arriveLocalMinutes: arriveMinutes,
                seat: savedSeat, confirmationCode: confirmationCode, note: note,
                aircraftType: savedAircraft, distanceMeters: savedDistance, durationMinutes: savedDuration
            )
            store.setTransportCost(tripId: tripId, segmentId: segmentId,
                                   amount: costAmountValue, currencyCode: costCurrencyToSave)
        } else if let dayId {
            if let newId = store.addTransportSegment(
                tripId: tripId, dayId: dayId,
                mode: mode, carrier: carrier, number: savedNumber,
                fromName: fromName, fromCode: savedFromCode,
                fromLatitude: fromLatitude, fromLongitude: fromLongitude,
                fromTimeZoneId: savedFromTZ, fromTerminal: savedFromTerminal,
                toName: toName, toCode: savedToCode,
                toLatitude: toLatitude, toLongitude: toLongitude,
                toTimeZoneId: savedToTZ, toTerminal: savedToTerminal,
                departDayOrder: departDayOrder, departLocalMinutes: departMinutes,
                arriveDayOrder: safeArriveDay, arriveLocalMinutes: arriveMinutes,
                seat: savedSeat, confirmationCode: confirmationCode, note: note,
                aircraftType: savedAircraft, distanceMeters: savedDistance, durationMinutes: savedDuration
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

    // MARK: 用航班号自动填（spec: itinerary-flight-lookup.md）

    private func lookupFlight() {
        let num = number.trimmingCharacters(in: .whitespaces)
        guard !num.isEmpty else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        let dateStr = f.string(from: lookupDate)
        lookupStatus = .loading
        CarryLogger.shared.log(.flightLookupStarted)
        Task {
            do {
                let result = try await FlightLookupService.lookup(number: num, dateString: dateStr)
                await MainActor.run {
                    applyFlightResult(result)
                    lookupStatus = .filled
                    CarryLogger.shared.log(.flightLookupResolved,
                                           context: "from=\(result.from.hasAirport) to=\(result.to.hasAirport)")
                }
            } catch FlightLookupError.notFound {
                await MainActor.run { lookupStatus = .notFound; CarryLogger.shared.log(.flightLookupNotFound) }
            } catch FlightLookupError.notConfigured {
                await MainActor.run { lookupStatus = .notConfigured }
            } catch {
                await MainActor.run { lookupStatus = .failed; CarryLogger.shared.log(.flightLookupFailed) }
            }
        }
    }

    /// 把查询结果映射进表单（尽力填，缺的留手填）。
    private func applyFlightResult(_ r: FlightLookupResult) {
        if !r.airlineName.isEmpty { carrier = r.airlineName }
        if !r.flightNumber.isEmpty { number = r.flightNumber }
        aircraftType = r.aircraftType
        distanceMeters = r.distanceMeters
        durationMinutes = r.durationMinutes
        if r.from.hasAirport {
            fromName = r.from.name; fromCode = r.from.iata
            if r.from.latitude != 0 || r.from.longitude != 0 { fromLatitude = r.from.latitude; fromLongitude = r.from.longitude }
            if !r.from.timeZoneId.isEmpty { fromTimeZoneId = r.from.timeZoneId }
            fromTerminal = r.from.terminal
        }
        if r.to.hasAirport {
            toName = r.to.name; toCode = r.to.iata
            if r.to.latitude != 0 || r.to.longitude != 0 { toLatitude = r.to.latitude; toLongitude = r.to.longitude }
            if !r.to.timeZoneId.isEmpty { toTimeZoneId = r.to.timeZoneId }
            toTerminal = r.to.terminal
        }
        applyFlightTimes(r)
    }

    /// 起降时刻 + 跨天。时刻按「机场当地时区的时:分」存（与现有 minutes(from:) 范式一致）；
    /// dayOrder 用航班的当地日期相对行程首日推算，跨午夜 → arriveDayOrder > departDayOrder。
    private func applyFlightTimes(_ r: FlightLookupResult) {
        if let dep = r.from.scheduledLocal {
            let c = localComponents(dep, tzId: r.from.timeZoneId)
            departTime = dateFromMinutes((c.hour ?? 0) * 60 + (c.minute ?? 0)); hasDepartTime = true
        }
        if let arr = r.to.scheduledLocal {
            let c = localComponents(arr, tzId: r.to.timeZoneId)
            arriveTime = dateFromMinutes((c.hour ?? 0) * 60 + (c.minute ?? 0)); hasArriveTime = true
        }
        let depYMD = ymdDate(r.from.scheduledLocal, tzId: r.from.timeZoneId) ?? ymdDate(lookupDate, tzId: TimeZone.current.identifier)
        let arrYMD = ymdDate(r.to.scheduledLocal, tzId: r.to.timeZoneId) ?? depYMD
        let cross = max(0, daysBetween(depYMD, arrYMD))
        if let bundle, !bundle.isDateless {
            let tripStart = ymdDate(bundle.departureDate, tzId: TimeZone.current.identifier)
            let span = bundle.spanDays
            let dOrder = clampOrder(daysBetween(tripStart, depYMD), span: span)
            departDayOrder = dOrder
            arriveDayOrder = clampOrder(dOrder + cross, span: span)
        } else {
            arriveDayOrder = departDayOrder + cross
        }
    }

    // MARK: 时区/日期换算

    private func calendar(tzId: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tzId) ?? .current
        return c
    }
    private func localComponents(_ date: Date, tzId: String) -> DateComponents {
        calendar(tzId: tzId).dateComponents([.hour, .minute], from: date)
    }
    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()
    /// 取某绝对时刻在 tz 下的「当地日历日」，归一成 UTC 午夜，供按天数差比较。
    private func ymdDate(_ date: Date?, tzId: String) -> Date {
        guard let date else { return Self.utcCal.startOfDay(for: Date()) }
        let c = calendar(tzId: tzId).dateComponents([.year, .month, .day], from: date)
        var d = DateComponents(); d.year = c.year; d.month = c.month; d.day = c.day
        return Self.utcCal.date(from: d) ?? Self.utcCal.startOfDay(for: date)
    }
    private func daysBetween(_ a: Date, _ b: Date) -> Int {
        Self.utcCal.dateComponents([.day], from: a, to: b).day ?? 0
    }
    private func clampOrder(_ o: Int, span: Int) -> Int { min(max(0, o), max(0, span - 1)) }
}

/// 让 Bool 能驱动 .sheet(item:)。
private struct SearchTarget: Identifiable {
    let isFrom: Bool
    var id: Bool { isFrom }
}
