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

    /// 租车专用：还车地点是否**镜像取车**（默认 true，大多数原地还）。无 UI——选/改取车时自动同步到还车；
    /// 用户手动改还车地点即解绑（=false），此后取车再变不动还车。取/还模块完全对称、无 toggle。spec: itinerary-car-rental.md。
    @State private var returnMirrorsPickup = true

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
    @State private var cabinClass = ""   // CabinClass.rawValue，空 = 未填
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
                        ) { name, lat, lon, address, pickedPhone, pickedTZ in
                            if isFrom {
                                fromName = name; fromLatitude = lat; fromLongitude = lon; fromAddress = address
                                if !pickedTZ.isEmpty { fromTimeZoneId = pickedTZ }   // 捕获取车/出发点时区
                                // 租车取车点电话自动回填（已填不覆盖）；非租车不收电话。
                                if mode == .carRental, phone.isEmpty { phone = pickedPhone }
                                // 还车镜像取车：未解绑时，取车地点自动同步到还车（含坐标/地址/时区）。
                                if mode == .carRental, returnMirrorsPickup {
                                    toName = name; toLatitude = lat; toLongitude = lon; toAddress = address
                                    if !pickedTZ.isEmpty { toTimeZoneId = pickedTZ }
                                }
                            } else {
                                toName = name; toLatitude = lat; toLongitude = lon; toAddress = address
                                if !pickedTZ.isEmpty { toTimeZoneId = pickedTZ }   // 捕获还车/到达点时区
                                // 用户手动设了还车地点 → 解绑镜像，此后取车变更不再覆盖还车（异地还）。
                                if mode == .carRental { returnMirrorsPickup = false }
                            }
                        }
                    }
                case .time(let isFrom):
                    ItineraryTimePickerSheet(
                        hasTime: Binding(get: { isFrom ? hasDepartTime : hasArriveTime },
                                         set: { if isFrom { hasDepartTime = $0 } else { hasArriveTime = $0 } }),
                        time: Binding(get: { isFrom ? departTime : arriveTime },
                                      set: { if isFrom { departTime = $0 } else { arriveTime = $0 } }),
                        timeZoneId: isFrom ? $fromTimeZoneId : $toTimeZoneId,
                        showZone: zoneRowVisible(zoneId: isFrom ? fromTimeZoneId : toTimeZoneId))
                }
            }
            .onAppear(perform: loadIfNeeded)
    }

    /// 时间选择器是否点亮「时区」兜底行：多时区行程、或该端自动推导失败（时区为空）时才显（spec: itinerary-timezone.md Phase 3）。
    private func zoneRowVisible(zoneId: String) -> Bool {
        (bundle?.isMultiTimeZone ?? false) || zoneId.isEmpty
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
                // 班次号 = 字母+数字（即时过滤其余，大小写随用户输入、不强制）。承运方是自由文本（可中文），不限。
                TextField(numberLabel, text: $number.filteringInput(ItineraryInputFilter.alphanumeric))
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

        // 租车还车段：还车 = 与取车**完全对称**的地点模块（无 toggle）。还车地点默认镜像取车
        // （选/改取车时自动同步），用户手动改还车即解绑——绝大多数为原地还，异地还少数手改即可。
        Section {
            if mode == .carRental {
                // 租车端点（取/还同构）：mappin + 地点（点开搜索）+ 正下方日期/时间 chips，整合成一块。
                // 不显「Days/租期」——它是派生值（还−取日期），编辑态正在设这两个日期、回显冗余=噪声；
                // 租期的价值在只读详情（一眼知租几天），编辑不需要（与 Tripsy 编辑态一致）。
                carRentalEndpoint(isFrom: isFrom, name: name, dayOrder: dayOrder,
                                  hasTime: hasTime, time: time)
            } else {
                // 非租车（航班/火车/巴士/渡轮/其他）：保持现状（地点 + 代码 + 航站楼 + 日期时间行）。
                // 航班的「整段路线 hero 可编辑」留待后续单独做。
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
                // 常驻标签（标签左·值右，同「机型」行）——避免填了值后 placeholder 标签消失、剩裸值「HGH」「3」看不懂。
                if showsCode {
                    LabeledContent {
                        // 机场/站代码（IATA）= 字母+数字（大小写随用户输入、不强制）。
                        TextField("", text: code.filteringInput(ItineraryInputFilter.alphanumeric))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    } label: {
                        Text("itinerary.transport.field.code")
                    }
                }
                if showsTerminal {
                    LabeledContent {
                        // 航站楼/站台 = 字母+数字（如 T2 / B / 2，大小写随用户输入、不强制）。
                        TextField("", text: terminal.filteringInput(ItineraryInputFilter.alphanumeric))
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text(terminalLabel)
                    }
                }
                // 日期 / 时间融合 chip：日期 chip 带行程天（点选换天）；时间 chip 可选（弹出选择器设/清除）。
                dateTimeChipsRow(isFrom: isFrom, dayOrder: dayOrder, hasTime: hasTime, time: time)
            }
        } header: {
            Text(sectionHeaderLabel(isFrom: isFrom))
        }
    }

    /// 租车端点整合块（取/还**完全对称**）：地点（通用 mappin + 点开搜索）+ 正下方日期/时间 chips
    /// （缩进对齐地点文字下方）。编辑是功能性表单 → 地点行用通用 `mappin`（与航班等同款），语义化 marker 属详情。
    /// 还车地点默认镜像取车（见搜索回调），故两端结构一致、无塌缩、无 toggle。
    @ViewBuilder
    private func carRentalEndpoint(isFrom: Bool, name: String,
                                   dayOrder: Binding<Int>, hasTime: Binding<Bool>, time: Binding<Date>) -> some View {
        // 「地址（在哪）」与「时间（何时）」是两类信息 → 用细分隔线 + 上下呼吸分成两层（地址在上、时间在下），
        // 不再贴成一坨。分隔线缩进 34 对齐地点文字列（与详情卡分隔线同款），不加图标避免刻意。
        VStack(alignment: .leading, spacing: 0) {
            Button {
                activeSheet = .search(isFrom: isFrom)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    (name.isEmpty ? Text(stationLabel(isFrom: isFrom)) : Text(name))
                        .font(.body)
                        .foregroundStyle(name.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            Divider().padding(.leading, 34)

            // 时间行也图标领头（calendar=「何时」，与 mappin=「在哪」成对照）：补齐详情页「每行=图标+内容」节奏、
            // 填掉左侧空列。图标与 mappin 同列对齐（frame 22 + 间距 12 → chips 落在 34、与分隔线起点齐）。
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                dayTimeChips(isFrom: isFrom, dayOrder: dayOrder, hasTime: hasTime, time: time)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
    }

    /// 正在编辑的交通段（附件挂载用，需已持久化）；新增态为 nil。
    private var editingSegment: TransportSegment? {
        guard let segmentId else { return nil }
        return days.flatMap { $0.sortedSegments }.first { $0.id == segmentId }
    }

    // MARK: 日期 / 时间融合 chip（参考 Tripsy）

    /// 带「日期」标签的整行（航班/火车等用）：标签左 · chips 右。
    @ViewBuilder
    private func dateTimeChipsRow(isFrom: Bool, dayOrder: Binding<Int>, hasTime: Binding<Bool>, time: Binding<Date>) -> some View {
        HStack(spacing: 8) {
            // 不放图标：表单同区其它行（代码/航站楼/座位…）皆「文字标签左·值右」无图标，
            // 这里也保持一致，标签左对齐成同一列。用「日期」而非「时间」（避开时间 chip 未设的「时间」占位重名）。
            Text("itinerary.transport.field.date")
            Spacer()
            dayTimeChips(isFrom: isFrom, dayOrder: dayOrder, hasTime: hasTime, time: time)
        }
    }

    /// 日期 + 时间两枚 chip（裸 chips，不含标签/Spacer）——租车端点块与带标签整行共用，保证两处交互一致。
    /// 日期 chip：多天行程可点选换天；单天仅展示。到达 chip 对「边」型交通在出发已落末日时多给「末日+1」
    /// （红眼返程选「次日落地」，见 selectableDayOrders）。时间 chip：点开弹出选择器设/清除，未设显占位「时间」。
    @ViewBuilder
    private func dayTimeChips(isFrom: Bool, dayOrder: Binding<Int>, hasTime: Binding<Bool>, time: Binding<Date>) -> some View {
        HStack(spacing: 8) {
            let dayOptions = selectableDayOrders(isFrom: isFrom)
            if dayOptions.count > 1 {
                Menu {
                    Picker(selection: dayOrder) {
                        ForEach(dayOptions, id: \.self) { order in
                            Text(dayLabel(order)).tag(order)
                        }
                    } label: { EmptyView() }
                } label: {
                    FormChip(text: dayLabel(dayOrder.wrappedValue))
                }
            } else {
                FormChip(text: dayLabel(dayOrder.wrappedValue))
            }
            // 时刻 chip 用等宽数字（filled 时），与详情页时间列对齐。
            Button { activeSheet = .time(isFrom: isFrom) } label: {
                FormChip(text: hasTime.wrappedValue ? itineraryTimeString(time.wrappedValue)
                                                    : NSLocalizedString("itinerary.transport.field.time", comment: ""),
                         filled: hasTime.wrappedValue,
                         monospacedDigits: hasTime.wrappedValue)
            }
            .buttonStyle(.plain)
        }
    }

    /// 日期 chip 的可选天。出发恒为行程内的天；**到达**对「边」型交通（航班/火车/巴士/渡轮）
    /// 在出发已落最后一天时，额外给出「末日+1」——红眼返程跨午夜落到行程结束日之后，
    /// 该到达不需要成为一个真实行程天（航班渲染为「边」、到达只是时刻+「+N」角标）。
    /// 租车「还车」是离散事件、须落在真实天，故不放开。
    private func selectableDayOrders(isFrom: Bool) -> [Int] {
        let base = days.map(\.sortOrder)
        guard let last = base.max() else { return base }
        if !isFrom, mode != .carRental, departDayOrder >= last {
            return base + [last + 1]
        }
        return base
    }

    private var moreSection: some View {
        Section {
            // 座位 / 确认号：常驻标签（填了值如「3B」「ABC123」也看得懂；空态标签即提示）。
            if showsSeat {
                LabeledContent {
                    // 座位 = 字母+数字（如 32A，大小写随用户输入、不强制）。
                    TextField("", text: $seat.filteringInput(ItineraryInputFilter.alphanumeric))
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("itinerary.transport.field.seat")
                }
            }
            // 舱位等级（仅航班）：受控词表用原生 .menu Picker（标题留 LabeledContent 外、值在右），
            // 纯手动——航班查询不返回舱位。空 = 未填。
            if mode == .flight {
                LabeledContent {
                    Picker("", selection: $cabinClass) {
                        Text("cabin.unset").tag("")
                        ForEach(CabinClass.allCases) { c in
                            Text(LocalizedStringKey(c.localizationKey)).tag(c.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } label: {
                    Text("itinerary.flight.field.cabin")
                }
            }
            LabeledContent {
                // 确认号 = 字母+数字（即时过滤空格/符号）。**不强制大写**——部分订单号区分大小写。
                // 占位用中性 pattern 示例（ABC123）：右对齐浅灰，既示「可输入」又示格式。
                TextField("itinerary.transport.field.confirmation.placeholder",
                          text: $confirmationCode.filteringInput(ItineraryInputFilter.alphanumeric))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            } label: {
                Text("itinerary.transport.field.confirmation")
            }
            // 机型：可编辑（航班搜索预填后可改、手动添加可填）。常驻于「更多」，顶部只留航班号/承运方。
            // 存接口原值，详情页展示时再经 aircraftModelDisplay 剥品牌前缀。
            if mode == .flight {
                LabeledContent {
                    TextField("", text: $aircraftType).multilineTextAlignment(.trailing)
                } label: {
                    Text("itinerary.flight.field.aircraft")
                }
            }
            // 车型 / 车牌：仅租车显示（你拿到的那台具体的车），都非必填、空态标签即提示。
            if mode == .carRental {
                // 占位均用中性 pattern 示例（右对齐浅灰）：示「可输入」+ 示格式，不锁某国格式。
                LabeledContent {
                    TextField("itinerary.transport.field.vehicle_model.placeholder", text: $vehicleModel)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("itinerary.transport.field.vehicle_model")
                }
                LabeledContent {
                    TextField("itinerary.transport.field.plate.placeholder", text: $licensePlate)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                } label: {
                    Text("itinerary.transport.field.plate")
                }
                // 电话：取车点搜索可自动回填，也可手填（方便行程中联系）。= 数字 + `+-() 空格`。
                LabeledContent {
                    TextField("itinerary.transport.field.phone.placeholder",
                              text: $phone.filteringInput(ItineraryInputFilter.phone))
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
            // 前导图标（详情页 NoteDetailRow 同款 note.text）：与 Total cost / Attachments 统一为「带前导图标的功能卡」。
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "note.text")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                TextField("itinerary.transport.field.note", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            }
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
            // 机型剥品牌前缀展示（"Airbus A321" → "A321"），与详情页/Trip Book 一致；存的也归一为型号。
            aircraftType = aircraftModelDisplay(seg.aircraftType)
            cabinClass = seg.cabinClass
            // 还车是否镜像取车：无显式存储位，从数据派生——还车端空、或与取车端同名同坐标即「仍镜像」；
            // 异地还（还车与取车不同）→ 已解绑，编辑时改取车不动还车。
            if seg.mode == .carRental {
                returnMirrorsPickup = seg.toName.isEmpty
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
        // 时区：航班从机场库回填、其它交通从地点搜索捕获——都保留（spec: itinerary-timezone.md）。
        // 类型在创建时固定（改类型=删除重加），故无「切模式残留旧区」之虞。
        let savedFromTZ = fromTimeZoneId
        // 还车镜像取车时，时区也随取车端（维持「镜像⟺两端一致」）；解绑则用还车自身捕获的时区。
        let savedToTZ = (mode == .carRental && returnMirrorsPickup) ? fromTimeZoneId : toTimeZoneId
        // 机型 / 舱位 / 航程 / 时长仅航班有意义。
        let savedAircraft = mode == .flight ? aircraftType : ""
        let savedCabin = mode == .flight ? cabinClass : ""
        let savedDistance = mode == .flight ? distanceMeters : 0
        let savedDuration = mode == .flight ? durationMinutes : 0
        // 车型 / 车牌 / 电话仅租车有意义；切到其它模式一并清空，避免残留。
        let savedVehicleModel = mode == .carRental ? vehicleModel : ""
        let savedLicensePlate = mode == .carRental ? licensePlate : ""
        let savedPhone = mode == .carRental ? phone : ""

        // 租车还车镜像取车：仍镜像时把取车地点存给还车端（保证两端数据完整 + 维持「镜像⟺to==from」不变式，
        // UI 已实时同步、此处是兜底）；已解绑（异地还）则存还车自身。
        let returnSameAsPickup = mode == .carRental && returnMirrorsPickup
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
                aircraftType: savedAircraft, cabinClass: savedCabin, distanceMeters: savedDistance, durationMinutes: savedDuration,
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
                aircraftType: savedAircraft, cabinClass: savedCabin, distanceMeters: savedDistance, durationMinutes: savedDuration,
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
        aircraftType = aircraftModelDisplay(r.aircraftType)   // 剥品牌前缀，与各处展示一致
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
            // 出发夹在行程内；到达 = 出发 + 跨天数，**不设上限**——红眼返程可落到行程末日之后
            // （与手动 chip 的「末日+1」一致，时间轴按差值显示「+N」）。
            arriveDayOrder = dOrder + cross
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
