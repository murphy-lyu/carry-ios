//
//  TransportDetailView.swift
//  Carry
//
//  交通【只读详情】：点交通段先看信息（半高 sheet），底部 Edit 再进编辑——与停靠点 / 住宿详情同一交互
//  （spec: itinerary-entity-detail-unify.md）。有值才显、空的不显。交通不带 Get Directions（导航去"出发站"意义不大）。
//

import SwiftUI
import CoreLocation

/// 交通详情聚焦端：航班/火车等单次移动 = `.full`（出发→到达整段）；
/// 租车拆成取车/还车两事件，各自只聚焦那一端的地址（并带导航），= `.pickup` / `.dropoff`。
enum TransportDetailFocus {
    case full, pickup, dropoff
    var idToken: String {
        switch self {
        case .full: return "full"
        case .pickup: return "pickup"
        case .dropoff: return "dropoff"
        }
    }
}

struct TransportDetailView: View {
    let tripId: UUID
    let segment: TransportSegment
    var focus: TransportDetailFocus = .full
    var navApps: [MapNavigationApp] = []
    let dayColor: Color

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @AppStorage("distance_unit") private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic }

    /// 标题：只放领衔标识（航班号/车次；无则承运方/公司；都空退化 mode 名）。
    /// 承运方下移到副标题（`headerSubtitle` .full），航司全名两行展示、不从中间断行。
    private var titleText: String {
        let number = segment.number.trimmingCharacters(in: .whitespaces)
        if !number.isEmpty { return number }
        let carrier = segment.displayCarrier
        return carrier.isEmpty ? NSLocalizedString(segment.mode.localizationKey, comment: "") : carrier
    }

    /// 航线 hero 的一个端点：主行（机场码优先，无码退化用站名）、次行（站名 / 航站楼）、详细地址、时间（含跨天 +N）。
    private struct RoutePoint {
        let primary: String      // 机场码（如 SHA）或站名
        let secondary: String?   // 站名（有码时）+ 航站楼，· 分隔
        let address: String?     // 详细地址（出门最实用）；与主/次行重复或空则 nil
        let time: String?        // 纯时刻「23:15」（跨天 +N 单独走 dayOffset、渲染成右上角小角标）
        let dayOffset: Int       // 跨天偏移（红眼到达 = 1），> 0 时显「+N」上标
        let zone: String?        // 该端时区（GMT±N）——仅「两端跨时区」时填，消除时刻歧义
    }

    /// 本段是否两端跨时区（两端都有时区且不同）——是则在两端时刻下显各自时区。
    private var crossesTimeZone: Bool {
        !segment.fromTimeZoneId.isEmpty && !segment.toTimeZoneId.isEmpty
            && segment.fromTimeZoneId != segment.toTimeZoneId
    }

    /// IANA → "GMT+8" / "GMT−3:30"（按当前日期算偏移；标签用途，跨夏令时边界外都准）。
    private func gmtZoneLabel(_ tzId: String) -> String? {
        guard !tzId.isEmpty, let tz = TimeZone(identifier: tzId) else { return nil }
        let secs = tz.secondsFromGMT(for: Date())
        let sign = secs < 0 ? "−" : "+"
        let mins = abs(secs) / 60, h = mins / 60, m = mins % 60
        return m == 0 ? "GMT\(sign)\(h)" : String(format: "GMT%@%d:%02d", sign, h, m)
    }

    /// 由端点字段拼出 RoutePoint；无地点也无时间 → nil（该端点不渲染）。
    private func routePoint(name: String, code: String, minutes: Int, dayOffset: Int, terminal: String, address: String, zone: String? = nil) -> RoutePoint? {
        let hasPlace = !name.isEmpty || !code.isEmpty
        let time: String? = minutes >= 0 ? timeLabel(dayMinutes: minutes) : nil
        guard hasPlace || time != nil else { return nil }

        let primary: String
        var secondaryParts: [String] = []
        if !code.isEmpty {
            primary = code
            if !name.isEmpty { secondaryParts.append(name) }
        } else {
            primary = name
        }
        if !terminal.isEmpty { secondaryParts.append(terminal) }
        let secondary = secondaryParts.isEmpty ? nil : secondaryParts.joined(separator: " · ")
        // 地址与名称/次行重复时不再重复显示。
        let addr = address.trimmingCharacters(in: .whitespaces)
        let showAddr = !addr.isEmpty && addr != primary && addr != secondary && addr != name
        return RoutePoint(primary: primary,
                          secondary: secondary,
                          address: showAddr ? addr : nil,
                          time: time,
                          dayOffset: time != nil ? max(0, dayOffset) : 0,
                          zone: zone)
    }

    private var departurePoint: RoutePoint? {
        routePoint(name: localizedAirportName(code: segment.fromCode, fallback: segment.fromName),
                   code: segment.fromCode,
                   minutes: segment.departLocalMinutes, dayOffset: 0,
                   terminal: terminalDisplay(segment.fromTerminal), address: segment.fromAddress,
                   zone: crossesTimeZone ? gmtZoneLabel(segment.fromTimeZoneId) : nil)
    }
    private var arrivalPoint: RoutePoint? {
        routePoint(name: localizedAirportName(code: segment.toCode, fallback: segment.toName),
                   code: segment.toCode,
                   minutes: segment.arriveLocalMinutes,
                   dayOffset: segment.arriveDayOrder - segment.departDayOrder,
                   terminal: terminalDisplay(segment.toTerminal), address: segment.toAddress,
                   zone: crossesTimeZone ? gmtZoneLabel(segment.toTimeZoneId) : nil)
    }

    /// 机场名按界面语言显示：码命中机场目录则用本地化名，否则回落存的原文（非机场地点/未收录机场不受影响）。
    /// 同步取自 `AirportCatalog`（单一数据源、启动已预热）→ 首帧即正确、无异步刷新闪烁。
    private func localizedAirportName(code: String, fallback: String) -> String {
        AirportCatalog.airport(forIATA: code)?.displayName ?? fallback
    }

    /// 航站楼显示：仅航班、且值以数字开头时加「T」前缀（2 → T2，国际通用航站楼记法）。
    /// 火车此字段是「站台」、字母开头（如 "A" / 已带 "T2"）的原样返回，避免误加。
    private func terminalDisplay(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard segment.mode == .flight, let first = t.first, first.isNumber else { return t }
        return NSLocalizedString("itinerary.transport.field.terminal_prefix", comment: "") + t
    }

    /// 飞行时长「3h 15m」（h/m 通用、无需逐语言）。
    private func durationText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var body: some View {
        DetailSheetScaffold {
            header
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                routeCard
                directionsCard
                detailsCard
                costCard
                noteCard
                AttachmentDetailCard(attachments: segment.attachments ?? [])
                muteCard
                editButton
            }
        }
        .sheet(isPresented: $editing) {
            TransportEditView(tripId: tripId, segmentId: segment.id)
        }
    }

    private var header: some View {
        DetailSheetHeader(
            iconSystemName: segment.mode.symbolName,
            iconTint: dayColor,
            title: titleText,
            subtitle: headerSubtitle,
            onDelete: deleteSegment,
            onClose: { dismiss() }
        )
    }

    /// 聚焦取车/还车时，把「取车 / 还车」放到标题副标题（与时间轴行一致），卡片内只留地址/时间，更好读。
    private var headerSubtitle: String? {
        switch focus {
        case .pickup:  return NSLocalizedString("itinerary.transport.section.pickup", comment: "")
        case .dropoff: return NSLocalizedString("itinerary.transport.section.dropoff", comment: "")
        case .full:
            // 航班/火车等：标题已是班次号 → 承运方放副标题（航司全名两行）；标题已是承运方时不重复。
            // 航司名按界面语言显示（航班从航班号解析本地化航司名，否则存的承运方原文）。
            let number = segment.number.trimmingCharacters(in: .whitespaces)
            let carrier = segment.displayCarrier
            return (!number.isEmpty && !carrier.isEmpty) ? carrier : nil
        }
    }

    private func deleteSegment() {
        if let dayId = segment.day?.id {
            store.removeTransportSegment(tripId: tripId, dayId: dayId, segmentId: segment.id)
        }
        dismiss()
    }

    // MARK: - 航线 hero（独立成卡）
    // 出发/到达单拎一张卡，用一条竖直 rail 把两端串成「一段旅程」，机场码与时间放大成主角——
    // 这是交通段最特别、最有仪式感的信息（学 Tripsy）。其余字段降到下方 detailsCard。

    @ViewBuilder
    private var routeCard: some View {
        // 租车=取车/还车（与编辑表单、时间轴事件一致）；其余交通=出发/到达。
        let isCarRental = segment.mode == .carRental
        let fromLabel = isCarRental ? "itinerary.transport.section.pickup" : "itinerary.transport.section.depart"
        let toLabel = isCarRental ? "itinerary.transport.section.dropoff" : "itinerary.transport.section.arrive"
        switch focus {
        case .full:
            fullRouteCard(fromLabel: fromLabel, toLabel: toLabel)
        case .pickup:
            // 取车事件：只聚焦取车这一端（地址 + 时间），导航另起一卡。
            focusedRouteCard(departurePoint, isDeparture: true)
        case .dropoff:
            focusedRouteCard(focusedArrivalPoint, isDeparture: false)
        }
    }

    /// 聚焦还车端：不带「+N」跨天角标。「+N」是相对取车日的偏移，只在整段双端 hero 里有参照；
    /// 单端聚焦视图无对照起点、详情又已锚定在还车那天 → 显「+N」反而困惑，去掉。
    private var focusedArrivalPoint: RoutePoint? {
        routePoint(name: segment.toName, code: segment.toCode,
                   minutes: segment.arriveLocalMinutes, dayOffset: 0,
                   terminal: terminalDisplay(segment.toTerminal), address: segment.toAddress)
    }

    /// 整段（出发→到达）：竖直 rail 串两端，机场码/时间放大成主角。用于航班/火车等单次移动。
    @ViewBuilder
    private func fullRouteCard(fromLabel: String, toLabel: String) -> some View {
        let dep = departurePoint
        let arr = arrivalPoint
        // 有跨天到达时，两行都预留「+N」小列 → 时钟成列右对齐、+N 右边距与卡片一致（见 placeTimeRow）。
        let crossDay = (arr?.dayOffset ?? 0) > 0
        if dep != nil || arr != nil {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                if let dep {
                    GridRow {
                        railCell(isDeparture: true, showLine: arr != nil, labelKey: fromLabel)
                        endpointContent(dep, crossDay: crossDay)
                    }
                }
                if let arr {
                    GridRow {
                        railCell(isDeparture: false, showLine: dep != nil, labelKey: toLabel)
                        endpointContent(arr, crossDay: crossDay)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    /// 单端聚焦（取车 或 还车）：marker（无连接线）+ 该端地址/时间。
    /// 「取车/还车」语境已移到浮窗标题副标题（与时间轴行一致），卡内只留实质信息，更好读。
    @ViewBuilder
    private func focusedRouteCard(_ p: RoutePoint?, isDeparture: Bool) -> some View {
        if let p {
            // marker 顶部对齐到名称行（而非对整块居中），与名称/时间共一条视觉锚线；地址往下排。
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Color(.secondarySystemBackground))
                    Circle().fill(dayColor.opacity(0.15))
                    Image(systemName: markerSymbol(isDeparture: isDeparture))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(dayColor)
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                placeTimeRow(p)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    // MARK: - 导航卡（仅取车/还车聚焦时）
    // 去取车点 / 还车点都可能要导航 → 复用 DirectionsModule（与地点/住宿同一处逻辑）。
    // 航班/火车等 `.full` 不显（导航去"出发站"意义不大，沿用既有取舍）。

    @ViewBuilder
    private var directionsCard: some View {
        if let coord = focusedCoordinate, !navApps.isEmpty {
            DirectionsModule(coordinate: coord, name: focusedName, navApps: navApps, tint: dayColor)
        }
    }

    private var focusedCoordinate: CLLocationCoordinate2D? {
        switch focus {
        case .pickup:  return segment.fromCoordinate
        case .dropoff: return segment.toCoordinate
        case .full:    return nil
        }
    }
    private var focusedName: String {
        focus == .dropoff ? segment.toName : segment.fromName
    }

    /// 端点 marker 图标，按 mode 取最贴切的形式：
    /// - 租车：钥匙（取车/还车，是「拿/还车」而非位移；两端常是同一地点，起飞/降落箭头会误导，学 Tripsy）。
    /// - 飞机/火车/巴士/渡轮：通用直达箭头 ↗ 出发 / ↘ 到达（飞机正好读成起飞/降落）。
    private func markerSymbol(isDeparture: Bool) -> String {
        switch segment.mode {
        case .carRental: return "key.fill"
        default:         return isDeparture ? "arrow.up.forward" : "arrow.down.forward"
        }
    }

    /// rail 列：当天色端点 marker + 半截连接线，两行相接处线段续上 → 连成一条。
    private func railCell(isDeparture: Bool, showLine: Bool, labelKey: String) -> some View {
        ZStack {
            if showLine {
                // 两个半段都显式占满一半高度（Rectangle 会贪婪吃掉 Spacer，故用等高的 Color.clear 占位，
                // 保证线只画 marker → 行边界这一半，不越过 marker 露头）。
                VStack(spacing: 0) {
                    if isDeparture {
                        Color.clear.frame(maxHeight: .infinity)               // 出发：上半空
                        Rectangle().fill(dayColor.opacity(0.3)).frame(width: 1.5).frame(maxHeight: .infinity)  // 下半段线
                    } else {
                        Rectangle().fill(dayColor.opacity(0.3)).frame(width: 1.5).frame(maxHeight: .infinity)  // 到达：上半段线
                        Color.clear.frame(maxHeight: .infinity)               // 下半空
                    }
                }
            }
            ZStack {
                Circle().fill(Color(.secondarySystemBackground))  // 不透明垫底，挡住穿过圆心的连接线
                Circle().fill(dayColor.opacity(0.15))
                Image(systemName: markerSymbol(isDeparture: isDeparture))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(dayColor)
            }
            .frame(width: 24, height: 24)
            .accessibilityLabel(Text(LocalizedStringKey(labelKey)))
        }
        .frame(width: 24)
        .frame(maxHeight: .infinity)
    }

    /// 端点内容（rail 行用）：地址/时间一行 + 上下气口；a11y 合并朗读。
    private func endpointContent(_ p: RoutePoint, crossDay: Bool = false) -> some View {
        placeTimeRow(p, crossDay: crossDay)
            .padding(.vertical, 6)   // 收紧出发/到达行上下内边距，减小两端块之间的空当
            .accessibilityElement(children: .combine)
    }

    /// 地址 + 时间一行：左侧机场码（大）+ 站名/航站楼（小），右侧时间（大），基线对齐成一行。
    private func placeTimeRow(_ p: RoutePoint, crossDay: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if !p.primary.isEmpty {
                    Text(p.primary)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                }
                if let sub = p.secondary {
                    Text(sub)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // 详细地址：出门最实用，放在名称下方，最多两行。
                if let addr = p.address {
                    Text(addr)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            if let t = p.time {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(t)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize()
                        // 跨天「+N」固定宽度小列（gutter）：在场=显 +N、出发行=留空占位 → 两行时钟在 gutter 左缘
                        // **右对齐**成列；gutter 右缘 = 内容右边距 → +N 与卡片右边距一致、不贴边、呼吸感统一。
                        // 仅「有跨天到达」的卡片预留（crossDay），同日航班不留列、时钟照常贴右。
                        if crossDay {
                            Text(p.dayOffset > 0 ? "+\(p.dayOffset)" : "")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .baselineOffset(6)
                                .frame(width: 13, alignment: .leading)
                        }
                    }
                    // 跨时区时显该端时区（GMT±N）——消除「出发时刻 vs 到达时刻不在同一时区」的歧义
                    // （这是详情里唯一真有歧义、值得显时区的地方；spec: itinerary-timezone.md 详情卡决策）。
                    if let z = p.zone {
                        Text(z)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: - 其余信息卡
    // 凭据（座位/确认号）→ 描述性规格（时长/机型/距离）→ 费用 → 备注，有值才显（spec: design-system 活动详情卡字段排序框架）。

    @ViewBuilder
    private var detailsCard: some View {
        let rows = detailRows
        if !rows.isEmpty { DetailRowGroup(rows: rows) }
    }

    private var detailRows: [AnyView] {
        var rows: [AnyView] = []
        // 租车租期（派生、只读）：取/还车跨天数，与住宿「晚数」同款。≥1 天才显（同天租赁由日期自明）。
        if segment.mode == .carRental {
            let days = segment.arriveDayOrder - segment.departDayOrder
            if days >= 1 {
                rows.append(AnyView(LabeledDetailRow(
                    icon: "calendar",
                    labelKey: days == 1 ? "itinerary.transport.field.days.one" : "itinerary.transport.field.days",
                    value: "\(days)")))
            }
        }
        // 随身要用的凭据（座位 / 确认号）：登机/检票时最先要找的，优先级高于描述性规格。
        if !segment.seat.isEmpty {
            rows.append(AnyView(LabeledDetailRow(icon: "chair", labelKey: "itinerary.transport.field.seat", value: segment.seat)))
        }
        // 舱位等级（仅航班设了才显）：受控词表，按设备 locale 本地化展示。
        if let cabin = CabinClass(rawValue: segment.cabinClass) {
            rows.append(AnyView(LabeledDetailRow(icon: "chair.lounge.fill", labelKey: "itinerary.flight.field.cabin",
                                                 value: NSLocalizedString(cabin.localizationKey, comment: ""))))
        }
        if !segment.confirmationCode.isEmpty {
            rows.append(AnyView(CopyableDetailRow(icon: "ticket", labelKey: "itinerary.transport.field.confirmation", value: segment.confirmationCode)))
        }
        // 租车专属：你拿到的那台车（车型 → 车牌，从泛到具体）；车牌可点按复制（停车/违章常要）。
        if !segment.vehicleModel.isEmpty {
            rows.append(AnyView(LabeledDetailRow(icon: "car.fill", labelKey: "itinerary.transport.field.vehicle_model", value: segment.vehicleModel)))
        }
        if !segment.licensePlate.isEmpty {
            rows.append(AnyView(CopyableDetailRow(icon: "licenseplate", labelKey: "itinerary.transport.field.plate", value: segment.licensePlate)))
        }
        // 电话（租车点）：点按直接拨号，方便行程中联系。
        if !segment.phone.isEmpty {
            rows.append(AnyView(CallableDetailRow(labelKey: "itinerary.transport.field.phone", phone: segment.phone)))
        }
        // 描述性规格（时长 → 机型 → 距离）：刻画这趟行程本身、属"了解一下"，按有用程度排，距离最次要。
        // 飞行时长放明细列表（与距离/机型一组，对标 Tripsy「航班时长」），不挤进 hero。
        if segment.durationMinutes > 0 {
            rows.append(AnyView(LabeledDetailRow(icon: "clock", labelKey: "itinerary.flight.field.duration", value: durationText(segment.durationMinutes))))
        }
        if !segment.aircraftType.isEmpty {
            rows.append(AnyView(LabeledDetailRow(icon: "airplane", labelKey: "itinerary.flight.field.aircraft", value: aircraftModelDisplay(segment.aircraftType))))
        }
        if segment.distanceMeters > 0 {
            rows.append(AnyView(LabeledDetailRow(icon: "ruler", labelKey: "itinerary.flight.field.distance",
                                                 value: CarryDistanceFormat.string(meters: segment.distanceMeters, unit: distanceUnit))))
        }
        return rows
    }

    // 费用 / 备注 各自独立成卡、固定顺序（费用 → 备注 → 附件），与编辑页一致、不与类型字段混排。
    @ViewBuilder
    private var costCard: some View {
        if segment.hasCost {
            DetailRowGroup(rows: [AnyView(LabeledDetailRow(icon: "creditcard", labelKey: "cost.field.total",
                                                           value: CurrencyCatalog.format(segment.costAmount, code: segment.costCurrencyCode)))])
        }
    }
    @ViewBuilder
    private var noteCard: some View {
        if !segment.note.isEmpty {
            DetailRowGroup(rows: [AnyView(NoteDetailRow(text: segment.note))])
        }
    }

    /// 逐段静音（spec: notification-center.md）：仅当此段有时刻（可能产生提醒）时才显。
    /// 开关「接收提醒」开=不静音；关=静音此段，不随全局规则提醒。
    @ViewBuilder
    private var muteCard: some View {
        if segment.departLocalMinutes >= 0 || segment.arriveLocalMinutes >= 0 {
            DetailRowGroup(rows: [AnyView(
                HStack(spacing: 12) {
                    Image(systemName: segment.remindersMuted ? "bell.slash" : "bell")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                    Text(segment.mode == .carRental ? "notif.mute.carrental" : "notif.mute.transport")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { !segment.remindersMuted },
                        set: { store.setTransportReminderMuted(tripId: tripId, segmentId: segment.id, muted: !$0) }
                    )).labelsHidden().tint(CarryAccent.color)
                }
                .padding(.vertical, 8)
            )])
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
