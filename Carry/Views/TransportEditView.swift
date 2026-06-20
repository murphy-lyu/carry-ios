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
    /// 航班搜索的预填结果（仅新增航班时由 FlightSearchSheet 注入）；nil = 手动/空表单。
    var prefill: FlightLookupResult? = nil
    /// 是否自带 NavigationStack。独立呈现（编辑/非航班「+」）为 true；
    /// 被 FlightSearchSheet push 时为 false，复用其导航栈，避免嵌套栈。
    var embedInOwnNavigationStack: Bool = true
    /// 保存/删除完成回调。被 push 时由 FlightSearchSheet 传入以关闭整张 sheet；
    /// nil（独立呈现）则退回 dismiss()。
    var onFinish: (() -> Void)? = nil

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    // 表单状态
    @State private var mode: TransportMode = .flight
    @State private var carrier = ""
    @State private var number = ""

    @State private var fromName = ""
    @State private var fromCode = ""
    @State private var fromTerminal = ""
    @State private var fromAddress = ""
    @State private var fromLatitude: Double = 0
    @State private var fromLongitude: Double = 0
    @State private var fromTimeZoneId = ""

    @State private var toName = ""
    @State private var toCode = ""
    @State private var toTerminal = ""
    @State private var toAddress = ""
    @State private var toLatitude: Double = 0
    @State private var toLongitude: Double = 0
    @State private var toTimeZoneId = ""

    /// 租车专用：还车地点同取车（默认开，大多数租车原地还）。开 → 折叠还车「地点」，
    /// 仅保留还车日期/时间；保存时把取车地点拷给还车端。spec: itinerary-car-rental.md。
    @State private var sameReturnLocation = true

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
    @State private var vehicleModel = ""    // 租车专属
    @State private var licensePlate = ""    // 租车专属
    @State private var phone = ""           // 租车专属：联系电话
    @State private var costAmountText = ""
    @State private var costCurrencyCode = ""

    @State private var attachmentRequest: AttachmentAddRequest?
    @State private var pendingAttachments: [PendingAttachment] = []   // 新建段：保存后再 flush 入库
    @State private var didLoad = false
    /// 单一 sheet 驱动（地点搜索 / 时间选择）。同一视图挂多个 .sheet(item:) 会相互抑制，故合并为单枚举。
    @State private var activeSheet: TransportSheet? = nil
    private enum TransportSheet: Identifiable {
        case search(isFrom: Bool)   // 起 / 落地点搜索
        case time(isFrom: Bool)     // 起 / 落时间选择
        var id: String {
            switch self {
            case .search(let f): return "search-\(f)"
            case .time(let f):   return "time-\(f)"
            }
        }
    }

    private var isEditing: Bool { segmentId != nil }
    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var days: [ItineraryDay] { bundle?.safeItineraryDays ?? [] }

    var body: some View {
        if embedInOwnNavigationStack {
            NavigationStack { formContent }
        } else {
            formContent
        }
    }

    private var formContent: some View {
            Form {
                carrierSection
                placeSection(isFrom: true)
                placeSection(isFrom: false)
                moreSection
                // 固定顺序：费用 → 备注 → 附件，各自独立 Section。
                costSection
                noteSection
                // 附件：既有段直接入库；新建段缓冲在 pending、保存后 flush。呈现挂到 Form（见 .attachmentAddFlow）。
                AttachmentEditSection(
                    owner: editingSegment.map { .segment($0.id) },
                    existing: editingSegment?.attachments ?? [],
                    pending: $pendingAttachments,
                    tripId: tripId,
                    request: $attachmentRequest)
                if isEditing { deleteSection }
            }
            .attachmentAddFlow(tripId: tripId, owner: editingSegment.map { .segment($0.id) },
                               pending: $pendingAttachments, request: $attachmentRequest)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 被 push 时（embed=false）系统返回按钮已提供「返回搜索」，不再叠加 Cancel。
                if embedInOwnNavigationStack {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAndDismiss() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .search(let isFrom):
                    // 航班：走内置机场数据库（全球可搜 + 回填 IATA / 时区）；
                    // 其它交通方式：走通用地图地点搜索（火车站 / 港口等）。spec: itinerary-airport-search.md。
                    if mode == .flight {
                        AirportSearchSheet(titleKey: stationLabel(isFrom: isFrom)) { airport in
                            if isFrom {
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
                            titleKey: stationLabel(isFrom: isFrom),
                            placeholderKey: "itinerary.transport.search.placeholder",
                            biasLatitude: bundle?.latitude ?? 0,
                            biasLongitude: bundle?.longitude ?? 0
                        ) { name, lat, lon, address, pickedPhone in
                            if isFrom {
                                fromName = name; fromLatitude = lat; fromLongitude = lon; fromAddress = address
                                // 租车取车点电话自动回填（已填不覆盖）；非租车不收电话。
                                if mode == .carRental, phone.isEmpty { phone = pickedPhone }
                            } else {
                                toName = name; toLatitude = lat; toLongitude = lon; toAddress = address
                            }
                        }
                    }
                case .time(let isFrom):
                    ItineraryTimePickerSheet(
                        hasTime: Binding(get: { isFrom ? hasDepartTime : hasArriveTime },
                                         set: { if isFrom { hasDepartTime = $0 } else { hasArriveTime = $0 } }),
                        time: Binding(get: { isFrom ? departTime : arriveTime },
                                      set: { if isFrom { departTime = $0 } else { arriveTime = $0 } }))
                }
            }
            .onAppear(perform: loadIfNeeded)
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

    /// 标题承载类型（类型已在「+」菜单选定，页内不再用一行重复展示/可改）：「添加航班」/「编辑租车」…
    /// 类型固定在创建时；改类型 → 删除重加（极少见，且各类型字段本就不同）。spec: itinerary-car-rental.md。
    private var navTitle: String {
        let typeName = NSLocalizedString(mode.localizationKey, comment: "")
        let fmt = NSLocalizedString(
            isEditing ? "itinerary.transport.edit.title.typed" : "itinerary.transport.add.title.typed",
            comment: "")
        return String(format: fmt, typeName)
    }

    private var carrierSection: some View {
        Section {
            // 航班号/车次领衔（旅客主认它），承运方在下——与详情标题同序。租车等无班次号则仅显承运方。
            if showsNumber {
                TextField(numberLabel, text: $number)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
            TextField(carrierLabel, text: $carrier)
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

        // 租车还车段：「还车地点同取车」开关（默认开 → 折叠地点行，仅留日期/时间）。
        let isCarReturn = (mode == .carRental && !isFrom)
        let showsLocationRow = !(isCarReturn && sameReturnLocation)

        Section {
            if isCarReturn {
                Toggle("itinerary.transport.field.same_return_location",
                       isOn: $sameReturnLocation.animation())
            }
            // 地点行：点开搜索取坐标；有名字显示名字，否则提示。
            if showsLocationRow {
                Button {
                    activeSheet = .search(isFrom: isFrom)
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
            }
            // 常驻标签（标签左·值右，同「机型」行）——避免填了值后 placeholder 标签消失、剩裸值「HGH」「3」看不懂。
            if showsCode {
                LabeledContent {
                    TextField("", text: code)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                } label: {
                    Text("itinerary.transport.field.code")
                }
            }
            if showsTerminal {
                LabeledContent {
                    TextField("", text: terminal)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text(terminalLabel)
                }
            }
            // 日期 / 时间融合 chip（参考 Tripsy）：日期 chip 带行程天（点选换天）；
            // 时间 chip 可选——点开在弹出选择器里设 / 清除，未设则显示占位「时间」。
            // 选择器都在弹出层、chip 是普通行高 → 不撑高、不跳变、信息量小（取代原 day Picker 行 + 时间开关行）。
            dateTimeChipsRow(isFrom: isFrom, dayOrder: dayOrder, hasTime: hasTime, time: time)
            // 租车租期（派生、只读）：随取/还车日期实时更新，给用户「租了几天」的即时反馈（参考 Tripsy）。
            if isCarReturn, rentalDurationDays >= 1 {
                LabeledContent {
                    Text("\(rentalDurationDays)")
                } label: {
                    Text(rentalDurationDays == 1 ? "itinerary.transport.field.days.one" : "itinerary.transport.field.days")
                }
            }
        } header: {
            Text(sectionHeaderLabel(isFrom: isFrom))
        }
    }

    /// 租车租期 = 还车日 − 取车日（与详情、住宿「晚数」同一口径，按天差）。
    private var rentalDurationDays: Int { max(0, arriveDayOrder - departDayOrder) }

    /// 正在编辑的交通段（附件挂载用，需已持久化）；新增态为 nil。
    private var editingSegment: TransportSegment? {
        guard let segmentId else { return nil }
        return days.flatMap { $0.sortedSegments }.first { $0.id == segmentId }
    }

    // MARK: 日期 / 时间融合 chip（参考 Tripsy）

    @ViewBuilder
    private func dateTimeChipsRow(isFrom: Bool, dayOrder: Binding<Int>, hasTime: Binding<Bool>, time: Binding<Date>) -> some View {
        HStack(spacing: 8) {
            // 不放图标：表单同区其它行（代码/航站楼/座位…）皆「文字标签左·值右」无图标，
            // 这里也保持一致，标签左对齐成同一列。用「日期」而非「时间」（避开时间 chip 未设的「时间」占位重名）。
            Text("itinerary.transport.field.date")
            Spacer()
            // 日期 chip：多天行程可点选换天；单天行程仅作信息展示。
            if days.count > 1 {
                Menu {
                    Picker(selection: dayOrder) {
                        ForEach(days, id: \.sortOrder) { d in
                            Text(dayLabel(d.sortOrder)).tag(d.sortOrder)
                        }
                    } label: { EmptyView() }
                } label: {
                    FormChip(text: dayLabel(dayOrder.wrappedValue))
                }
            } else {
                FormChip(text: dayLabel(dayOrder.wrappedValue))
            }
            // 时间 chip：点开弹出时间选择器；未设显示占位「时间」。
            Button { activeSheet = .time(isFrom: isFrom) } label: {
                FormChip(text: hasTime.wrappedValue ? itineraryTimeString(time.wrappedValue)
                                                    : NSLocalizedString("itinerary.transport.field.time", comment: ""),
                         filled: hasTime.wrappedValue)
            }
            .buttonStyle(.plain)
        }
    }

    private var moreSection: some View {
        Section {
            // 座位 / 确认号：常驻标签（填了值如「3B」「ABC123」也看得懂；空态标签即提示）。
            if showsSeat {
                LabeledContent {
                    TextField("", text: $seat).multilineTextAlignment(.trailing)
                } label: {
                    Text("itinerary.transport.field.seat")
                }
            }
            LabeledContent {
                TextField("", text: $confirmationCode)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            } label: {
                Text("itinerary.transport.field.confirmation")
            }
            // 机型（航班搜索预填后只读展示）：从顶部承运方区挪到「更多」，顶部只留航班号/承运方。
            if mode == .flight && !aircraftType.isEmpty {
                LabeledContent {
                    Text(aircraftModelDisplay(aircraftType))
                } label: {
                    Text("itinerary.flight.field.aircraft")
                }
            }
            // 车型 / 车牌：仅租车显示（你拿到的那台具体的车），都非必填、空态标签即提示。
            if mode == .carRental {
                LabeledContent {
                    TextField("", text: $vehicleModel).multilineTextAlignment(.trailing)
                } label: {
                    Text("itinerary.transport.field.vehicle_model")
                }
                LabeledContent {
                    TextField("", text: $licensePlate)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                } label: {
                    Text("itinerary.transport.field.plate")
                }
                // 电话：取车点搜索可自动回填，也可手填（方便行程中联系）。
                LabeledContent {
                    TextField("", text: $phone)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.phonePad)
                } label: {
                    Text("itinerary.transport.field.phone")
                }
            }
        } header: {
            Text("itinerary.transport.section.more")
        }
    }

    // 费用 / 备注 各自独立 Section、固定顺序（费用 → 备注 → 附件），不与类型字段混排。
    private var costSection: some View {
        Section { CostInputRow(amountText: $costAmountText, currencyCode: $costCurrencyCode) }
    }
    private var noteSection: some View {
        Section {
            TextField("itinerary.transport.field.note", text: $note, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    /// 删除按钮文案随类型走，与标题「编辑租车」呼应：「删除租车」「删除航班」…（"删除交通" 里"交通"是分类名、当宾语别扭）。
    private var deleteTitle: String {
        let typeName = NSLocalizedString(mode.localizationKey, comment: "")
        let fmt = NSLocalizedString("itinerary.transport.delete.typed", comment: "")
        return String(format: fmt, typeName)
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                deleteAndDismiss()
            } label: {
                Text(deleteTitle)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: Helpers

    /// 至少要有「班次号」或「出发地名」才允许保存——避免落一条空段。
    /// 租车无班次号、地点又可选，故以「公司名」或「取车地点」为准（否则只填公司无法保存）。
    private var canSave: Bool {
        if mode == .carRental {
            return !carrier.trimmingCharacters(in: .whitespaces).isEmpty
                || !fromName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !number.trimmingCharacters(in: .whitespaces).isEmpty
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

    /// 出发天对应的真实日期（有日期行程）；无日期行程退回今天。供跨天推算的兜底。
    private func departDayDate() -> Date {
        if let bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            return Calendar.current.date(byAdding: .day, value: departDayOrder, to: base) ?? base
        }
        return Date()
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
            fromAddress = seg.fromAddress
            fromLatitude = seg.fromLatitude; fromLongitude = seg.fromLongitude
            fromTimeZoneId = seg.fromTimeZoneId
            toName = seg.toName; toCode = seg.toCode; toTerminal = seg.toTerminal
            toAddress = seg.toAddress
            toLatitude = seg.toLatitude; toLongitude = seg.toLongitude
            toTimeZoneId = seg.toTimeZoneId
            departDayOrder = seg.departDayOrder; arriveDayOrder = seg.arriveDayOrder
            if seg.departLocalMinutes >= 0 { hasDepartTime = true; departTime = dateFromMinutes(seg.departLocalMinutes) }
            if seg.arriveLocalMinutes >= 0 { hasArriveTime = true; arriveTime = dateFromMinutes(seg.arriveLocalMinutes) }
            seat = seg.seat; confirmationCode = seg.confirmationCode; note = seg.note
            aircraftType = seg.aircraftType
            // 租车还车开关：无显式存储位，从数据派生——还车端空、或与取车端同名同坐标即「同取车」。
            if seg.mode == .carRental {
                sameReturnLocation = seg.toName.isEmpty
                    || (seg.toName == seg.fromName
                        && seg.toLatitude == seg.fromLatitude
                        && seg.toLongitude == seg.fromLongitude)
            }
            distanceMeters = seg.distanceMeters; durationMinutes = seg.durationMinutes
            vehicleModel = seg.vehicleModel; licensePlate = seg.licensePlate; phone = seg.phone
            if seg.hasCost { costAmountText = CurrencyCatalog.amountText(seg.costAmount); costCurrencyCode = seg.costCurrencyCode }
        } else {
            // 新增：默认模式 + 起降日落到目标天。
            mode = initialMode
            let order = days.first(where: { $0.id == dayId })?.sortOrder ?? 0
            departDayOrder = order
            arriveDayOrder = order
            // 航班搜索预填：把结果映射进表单（航司/机场/起降时刻/航站楼/机型）；空字段留用户补。
            if let prefill { applyFlightResult(prefill) }
        }
    }

    /// 完成（保存/删除后）：被 push 时走 onFinish 关闭整张搜索 sheet；独立呈现退回 dismiss。
    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
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
        // 车型 / 车牌 / 电话仅租车有意义；切到其它模式一并清空，避免残留。
        let savedVehicleModel = mode == .carRental ? vehicleModel : ""
        let savedLicensePlate = mode == .carRental ? licensePlate : ""
        let savedPhone = mode == .carRental ? phone : ""

        // 租车「还车地点同取车」：把取车地点拷给还车端，保证详情/地图/导出两端数据完整。
        let returnSameAsPickup = mode == .carRental && sameReturnLocation
        let savedToName = returnSameAsPickup ? fromName : toName
        let savedToLat = returnSameAsPickup ? fromLatitude : toLatitude
        let savedToLon = returnSameAsPickup ? fromLongitude : toLongitude
        let savedToAddress = returnSameAsPickup ? fromAddress : toAddress
        // 机场搜索不回填地址；切到航班一并清空，避免残留旧地址。
        let savedFromAddress = mode == .flight ? "" : fromAddress
        let savedToAddressFinal = mode == .flight ? "" : savedToAddress

        if let segmentId {
            store.updateTransportSegment(
                tripId: tripId, segmentId: segmentId,
                mode: mode, carrier: carrier, number: savedNumber,
                fromName: fromName, fromCode: savedFromCode,
                fromLatitude: fromLatitude, fromLongitude: fromLongitude,
                fromTimeZoneId: savedFromTZ, fromTerminal: savedFromTerminal,
                fromAddress: savedFromAddress,
                toName: savedToName, toCode: savedToCode,
                toLatitude: savedToLat, toLongitude: savedToLon,
                toTimeZoneId: savedToTZ, toTerminal: savedToTerminal,
                toAddress: savedToAddressFinal,
                departDayOrder: departDayOrder, departLocalMinutes: departMinutes,
                arriveDayOrder: safeArriveDay, arriveLocalMinutes: arriveMinutes,
                seat: savedSeat, confirmationCode: confirmationCode, note: note,
                aircraftType: savedAircraft, distanceMeters: savedDistance, durationMinutes: savedDuration,
                vehicleModel: savedVehicleModel, licensePlate: savedLicensePlate, phone: savedPhone
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
                fromAddress: savedFromAddress,
                toName: savedToName, toCode: savedToCode,
                toLatitude: savedToLat, toLongitude: savedToLon,
                toTimeZoneId: savedToTZ, toTerminal: savedToTerminal,
                toAddress: savedToAddressFinal,
                departDayOrder: departDayOrder, departLocalMinutes: departMinutes,
                arriveDayOrder: safeArriveDay, arriveLocalMinutes: arriveMinutes,
                seat: savedSeat, confirmationCode: confirmationCode, note: note,
                aircraftType: savedAircraft, distanceMeters: savedDistance, durationMinutes: savedDuration,
                vehicleModel: savedVehicleModel, licensePlate: savedLicensePlate, phone: savedPhone
            ) {
                store.setTransportCost(tripId: tripId, segmentId: newId,
                                       amount: costAmountValue, currencyCode: costCurrencyToSave)
                // 新建段：把缓冲的附件落到刚建好的段。
                flushPendingAttachments(owner: .segment(newId))
            }
        }
        finish()
    }

    /// 把新建态缓冲的附件入库到刚持久化的实体（文件已在沙盒）。
    private func flushPendingAttachments(owner: AttachmentOwner) {
        for p in pendingAttachments {
            _ = store.addAttachment(tripId: tripId, owner: owner, kind: p.data.kind,
                                    displayName: p.data.displayName, fileName: p.data.fileName,
                                    utiOrExt: p.data.utiOrExt, urlString: p.data.urlString,
                                    thumbnailData: p.data.thumbnailData)
        }
        pendingAttachments.removeAll()
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
        finish()
    }

    // MARK: 航班搜索结果 → 表单映射（spec: itinerary-flight-search-first.md）
    // 查询/搜索 UI 已前移到 FlightSearchSheet；此处只负责把传入的结果映射进表单。

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
        // ymdDate 内部把 nil 兜底成「今天」，故 nil 回退必须在调用前显式判断（否则丢掉「无起飞时刻→落到出发日」的本意）。
        let depYMD: Date = r.from.scheduledLocal != nil
            ? ymdDate(r.from.scheduledLocal, tzId: r.from.timeZoneId)
            : ymdDate(departDayDate(), tzId: TimeZone.current.identifier)
        let arrYMD: Date = r.to.scheduledLocal != nil
            ? ymdDate(r.to.scheduledLocal, tzId: r.to.timeZoneId)
            : depYMD
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
