//
//  ItineraryView.swift
//  Carry
//
//  行程路线规划视图——打包清单并列的「第二张脸」（spec: itinerary-route-planning.md）。
//  按 Day 分组的有序停靠点：增删、拖拽重排、地理搜索选点。地图区在 ItineraryMapView。
//

import SwiftUI
import MapKit

// MARK: - Distance helper

private let legDistanceFormatter: MKDistanceFormatter = {
    let f = MKDistanceFormatter()
    f.unitStyle = .abbreviated
    return f
}()

// MARK: - Time helpers

/// 自午夜起的分钟数 → 当天的 Date（用于时间选择器）。
func dateFromDayMinutes(_ minutes: Int) -> Date {
    let start = Calendar.current.startOfDay(for: Date())
    return Calendar.current.date(byAdding: .minute, value: max(0, minutes), to: start) ?? start
}

/// Date → 自午夜起的分钟数。
func dayMinutes(from date: Date) -> Int {
    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
}

/// 本地化的时间标签（随地区 12/24 小时制）。
func timeLabel(dayMinutes minutes: Int) -> String {
    dateFromDayMinutes(minutes).formatted(date: .omitted, time: .shortened)
}

// MARK: - Sheet targets

/// 单一 sheet 来源——SwiftUI 同一视图上多个 `.sheet(item:)` 会相互抑制，
/// 故用一个枚举驱动唯一的 sheet。
private enum ItinerarySheet: Identifiable {
    case addStop(dayId: UUID)
    case stopDetail(ItineraryStop)
    case editStop(ItineraryStop)
    case optimize(dayId: UUID)
    case addTransport(dayId: UUID, mode: TransportMode)
    case editTransport(UUID)
    case addLodging(checkInDayOrder: Int)
    case editLodging(UUID)

    var id: String {
        switch self {
        case .addStop(let dayId): return "add-\(dayId)"
        case .stopDetail(let stop): return "detail-\(stop.id)"
        case .editStop(let stop): return "edit-\(stop.id)"
        case .optimize(let dayId): return "opt-\(dayId)"
        case .addTransport(let dayId, let mode): return "addtr-\(dayId)-\(mode.rawValue)"
        case .editTransport(let id): return "edittr-\(id)"
        case .addLodging(let order): return "addlg-\(order)"
        case .editLodging(let id): return "editlg-\(id)"
        }
    }
}

// MARK: - ItineraryView

struct ItineraryView: View {
    let tripId: UUID
    /// 「地点排序」模式（由容器 PackingListView 的菜单/工具栏驱动）：压缩行 + 拖拽手柄 + 锁 tap。
    var isReordering: Binding<Bool> = .constant(false)

    @EnvironmentObject var store: TripStore

    @State private var activeSheet: ItinerarySheet?
    @State private var focusedDayId: UUID?
    /// 已安装的导航 App，onAppear 时探测一次（避免每行重复 canOpenURL）。
    /// 行内导航按钮据此：≥2 个弹锚定 `Menu`、仅 1 个（只有 Apple 地图）直接调起。
    @State private var navApps: [MapNavigationApp] = []

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var days: [ItineraryDay] { bundle?.safeItineraryDays ?? [] }
    private var activeFocusedDayId: UUID? {
        guard let focusedDayId, days.contains(where: { $0.id == focusedDayId }) else { return nil }
        return focusedDayId
    }
    private var visibleStartDate: Date? {
        guard let bundle, !bundle.isDateless else { return nil }
        return Calendar.current.startOfDay(for: bundle.departureDate)
    }

    private struct CalendarEntry: Identifiable {
        let offset: Int
        let date: Date
        let day: ItineraryDay?

        var isInTrip: Bool { day != nil }
        var id: Int { offset }
    }

    private var calendarEntries: [CalendarEntry] {
        guard let bundle, let startDate = visibleStartDate else { return [] }
        let tripDays = bundle.spanDays   // 实际天数（含两端），与行程页/首页一致
        let visibleDays = max(7, tripDays)

        return (0..<visibleDays).map { offset in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: startDate) ?? startDate
            let day = days.first(where: { $0.sortOrder == offset })
            return CalendarEntry(offset: offset, date: date, day: day)
        }
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
            // 天恒等于行程天数（自动生成），行程页始终展示「天」结构，无「整屏空态」；
            // 「整趟还没加地点」即表现为每天下方的「+ 添加地点」（决策 A）。
            dayList
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addStop(let dayId):
                AddStopView(
                    tripId: tripId,
                    dayId: dayId,
                    biasLatitude: bundle?.latitude ?? 0,
                    biasLongitude: bundle?.longitude ?? 0
                )
            case .stopDetail(let stop):
                StopDetailView(
                    tripId: tripId,
                    stop: stop,
                    distanceToNext: distanceToNextStop(stop),
                    navApps: navApps,
                    dayColor: dayColor(forStop: stop)
                )
            case .editStop(let stop):
                StopEditView(tripId: tripId, stop: stop)
            case .optimize(let dayId):
                OptimizeRouteView(tripId: tripId, dayId: dayId)
            case .addTransport(let dayId, let mode):
                TransportEditView(tripId: tripId, dayId: dayId, initialMode: mode)
            case .editTransport(let id):
                TransportEditView(tripId: tripId, segmentId: id)
            case .addLodging(let order):
                LodgingEditView(tripId: tripId, initialCheckInDayOrder: order)
            case .editLodging(let id):
                LodgingEditView(tripId: tripId, stayId: id)
            }
        }
        .toolbarBackground(Color(UIColor.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            store.syncItineraryDays(tripId: tripId)   // 兜底：天对齐到行程天数（存量行程/新建首开）
            syncFocusedDaySelectionIfNeeded()
            navApps = MapNavigationService.availableApps()
        }
        .onChange(of: days.map(\.id)) { _, _ in
            syncFocusedDaySelectionIfNeeded()
        }
    }

    // MARK: Day list

    private var dayList: some View {
        VStack(spacing: 8) {
            ItineraryMapView(tripId: tripId, focusedDayId: activeFocusedDayId)
            itineraryCalendarStrip
            // 原生 collection：长按拖拽，停靠点可跨天移动（spec: 跨天拖拽）。
            ItineraryReorderCollection(
                sections: daySections,
                scrollTargetDayId: activeFocusedDayId,
                isReordering: isReordering.wrappedValue,
                stopContent: { AnyView(stopRow($0)) },
                legContent: { AnyView(legRow($0)) },
                transportContent: { AnyView(transportRow($0)) },
                lodgingContent: { AnyView(lodgingRow($0, $1)) },
                addStopContent: { AnyView(addStopRow($0)) },
                optimizeContent: { AnyView(optimizeRow($0)) },
                headerContent: { AnyView(dayHeaderRow($0)) },
                onDelete: { deleteStop($0) },
                onArrange: { store.applyItineraryArrangement(tripId: tripId, dayOrders: $0) },
                onReorderBegan: { },
                onFocusDay: { focusedDayId = $0 }
            )
            // Day header 依赖行程级日期态（isDateless / departureDate）算标签，而这状态不在
            // collection 的 diffable 快照里 → section id 不变时旧 header 不会重配（转有/无日期后
            // 旧天仍显示「第 N 天」）。日期态变化时用 .id 强制重建 collection 一次刷新所有 header；
            // 日常加减地点不改此 key、不触发重建。
            // 含 isReordering：进出排序模式时重建 collection，让 .stop cell 刷新为压缩版/常规版。
            .id("\(itineraryDateStateKey)-reorder:\(isReordering.wrappedValue)")
            // 延伸到底部「行程/打包」切换器下方，内容在其渐变里淡出（与打包面统一）。
            // 末行让出切换器净空由 collection 的 contentInset.bottom 负责（见 bottomBarClearance）。
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    /// 影响 Day header 标签的行程级日期态。变化即强制 collection 重建（罕见操作，代价可忽略）。
    private var itineraryDateStateKey: String {
        guard let bundle else { return "none" }
        return "\(bundle.isDateless)_\(bundle.departureDate.timeIntervalSince1970)"
    }

    private var itineraryCalendarStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !calendarEntries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 11) {
                            ForEach(calendarEntries) { entry in
                                dayCalendarCell(
                                    entry: entry,
                                    isSelected: activeFocusedDayId == entry.day?.id
                                ) {
                                    guard entry.isInTrip, let day = entry.day else { return }
                                    focusedDayId = day.id
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    // 选中天变化（点选或随列表反向联动）→ 把该天日历格滚到可见居中，长行程不脱屏。
                    .onChange(of: activeFocusedDayId) { _, _ in
                        guard let day = days.first(where: { $0.id == activeFocusedDayId }) else { return }
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                            proxy.scrollTo(day.sortOrder, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 0)
        .padding(.bottom, 0)
    }

    @ViewBuilder
    private func dayCalendarCell(
        entry: CalendarEntry,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isDimmed = !entry.isInTrip && !isSelected

        Button(action: action) {
            VStack(spacing: 2) {
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    // 非行程日用语义色 tertiaryLabel（明暗自适应、克制），明确「仅作整周上下文、不可操作」。
                    .foregroundStyle(isSelected ? CarryAccent.color : (isDimmed ? Color(.tertiaryLabel) : .secondary))
                    .tracking(0.03)

                ZStack {
                    if isSelected {
                        Circle()
                            .fill(CarryAccent.color)
                            .frame(width: 28, height: 28)
                    }
                    Text("\(Calendar.current.component(.day, from: entry.date))")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(isSelected ? .white : (isDimmed ? Color(.tertiaryLabel) : .primary))
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 28, height: 28)
                .frame(maxWidth: .infinity)

                HStack(spacing: 2) {
                    ForEach(0..<dayDotCount(for: entry), id: \.self) { index in
                        Circle()
                            .fill(dayDotColor(for: entry, index: index))
                            .frame(width: 3.5, height: 3.5)
                    }
                }
                .frame(height: 4)
            }
            .frame(width: 40, height: 60)
        }
        .buttonStyle(.plain)
        .disabled(!entry.isInTrip)
    }

    private func syncFocusedDaySelectionIfNeeded() {
        if let focusedDayId, days.contains(where: { $0.id == focusedDayId }) {
            return
        }
        focusedDayId = days.first?.id
    }

    private func dayDotCount(for entry: CalendarEntry) -> Int {
        guard let day = entry.day else { return 0 }
        return min(3, max(0, day.sortedStops.count))
    }

    /// 圆点统一用「当天配色」（与 Day 头圆点 / 地图针 / 时间轴序号同色），表达「这天有安排 + 粗略数量」。
    /// 不再用类别色——类别色含义太隐，用户难以解读，反而成噪音。
    private func dayDotColor(for entry: CalendarEntry, index: Int) -> Color {
        guard let day = entry.day else { return .clear }
        return ItineraryDayPalette.color(forDayIndex: day.sortOrder)
    }

    /// 每天的结构快照（供 collection diffable）。entries 顺序 = 覆盖本天的住宿条 → 时间轴（停靠点 +
    /// 交通段，按 day.timeline 的共享 sortOrder）。leg / addStop / optimize 由 collection 自行插入/追加。
    private var daySections: [ItineraryDaySection] {
        let stays = bundle?.safeLodgingStays ?? []
        return days.map { day in
            // 覆盖本天的住宿常驻条（含**退房日** = checkIn+nights，用于显「退房」事件）。
            // 行 ID 带 day 维度，避免同一 stay 跨天在快照里重复（item 标识须全局唯一）。
            let lodgingRows: [ItineraryRowID] = stays
                .filter { $0.checkInDayOrder <= day.sortOrder && day.sortOrder <= $0.checkOutDayOrder }
                .map { .lodging(stay: $0.id, day: day.sortOrder) }
            let timelineRows: [ItineraryRowID] = day.timeline.map { item in
                switch item {
                case .stop(let s): return .stop(s.id)
                case .transport(let t): return .transport(t.id)
                }
            }
            return ItineraryDaySection(
                id: day.id,
                entries: lodgingRows + timelineRows,
                // 固定首尾后，需中间 ≥2 个点才有可优化空间，故坐标点 ≥4 才露入口。
                showsOptimize: day.sortedStops.filter(\.hasCoordinate).count >= 4
            )
        }
    }

    // MARK: 行内容（由 collection 闭包承载）

    @ViewBuilder
    private func stopRow(_ stopID: UUID) -> some View {
        if let day = days.first(where: { ($0.stops ?? []).contains { $0.id == stopID } }),
           let index = day.sortedStops.firstIndex(where: { $0.id == stopID }) {
            let dayStops = day.sortedStops
            let stop = dayStops[index]
            if isReordering.wrappedValue {
                reorderStopRow(stop, dayColor: ItineraryDayPalette.color(forDayIndex: day.sortOrder))
            } else {
            TimelineStopRow(
                stop: stop,
                index: index,
                isLast: index == dayStops.count - 1,
                dayColor: ItineraryDayPalette.color(forDayIndex: day.sortOrder)
            )
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            // 点击整行 → 打开停靠点【只读详情】（StopDetailView），看完即走；编辑在详情右上角入口。
            // 默认只读避免误改敏感字段（时间/位置）、也契合「这屏多数是来看信息」的高频意图。
            // 长按仍拖拽重排、左滑仍删除，tap 与之手势类型不同、不冲突。
            .onTapGesture { activeSheet = .stopDetail(stop) }
            }
        }
    }

    /// 排序模式的压缩行：类别图标 + 名称 + 拖拽手柄（≡，纯视觉提示）；不挂 tap（锁误触进详情）。
    /// 拖拽由 collection 的长按（即抓即拖）承载，整行可拖、手柄只是 affordance。
    private func reorderStopRow(_ stop: ItineraryStop, dayColor: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: stop.category.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(dayColor)
                .frame(width: 22)
            Text(stop.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// 连接段（连线 + 距离），独立成行夹在相邻停靠点之间。入参为下方停靠点 id。
    @ViewBuilder
    private func legRow(_ toStopID: UUID) -> some View {
        if let day = days.first(where: { ($0.stops ?? []).contains { $0.id == toStopID } }),
           let index = day.sortedStops.firstIndex(where: { $0.id == toStopID }), index > 0 {
            ItineraryLegConnector(
                distance: legLabel(stops: day.sortedStops, index: index),
                railColor: ItineraryDayPalette.color(forDayIndex: day.sortOrder).opacity(0.25)
            )
            .padding(.horizontal, 16)
        }
    }

    /// 交通段连接行（边）：mode 图标落在 rail 列，详情列显示班次 + 起讫站/时间。点击编辑。
    @ViewBuilder
    private func transportRow(_ segmentID: UUID) -> some View {
        if let day = days.first(where: { ($0.segments ?? []).contains { $0.id == segmentID } }),
           let seg = day.sortedSegments.first(where: { $0.id == segmentID }) {
            TransportTimelineRow(segment: seg, dayColor: ItineraryDayPalette.color(forDayIndex: day.sortOrder))
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture { activeSheet = .editTransport(segmentID) }
        }
    }

    /// 住宿常驻条：覆盖本天的住宿，置于当天顶部。点击编辑。
    /// `dayOrder` 决定显示入住 / 过夜 / 退房三态（spec: itinerary-transport-lodging.md）。
    @ViewBuilder
    private func lodgingRow(_ stayID: UUID, _ dayOrder: Int) -> some View {
        if let stay = (bundle?.lodgingStays ?? []).first(where: { $0.id == stayID }) {
            let phase: LodgingBannerRow.Phase =
                dayOrder == stay.checkInDayOrder ? .checkIn :
                dayOrder == stay.checkOutDayOrder ? .checkOut : .night
            LodgingBannerRow(stay: stay, phase: phase)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture { activeSheet = .editLodging(stayID) }
        }
    }

    /// 统一「+ 添加」入口（spec: itinerary-transport-lodging.md）：菜单选类型 → 地点 / 航班 / 火车 / 住宿。
    /// 次级内联动作用 secondary 灰，与打包「添加物品」一致（避免每组一行 accent 蓝、喧宾夺主）。
    private func addStopRow(_ dayID: UUID) -> some View {
        let order = days.first(where: { $0.id == dayID })?.sortOrder ?? 0
        return Menu {
            Button { activeSheet = .addStop(dayId: dayID) } label: {
                Label("itinerary.kind.place", systemImage: "mappin")
            }
            Button { activeSheet = .addTransport(dayId: dayID, mode: .flight) } label: {
                Label(TransportMode.flight.titleKey, systemImage: TransportMode.flight.symbolName)
            }
            Button { activeSheet = .addTransport(dayId: dayID, mode: .train) } label: {
                Label(TransportMode.train.titleKey, systemImage: TransportMode.train.symbolName)
            }
            Button { activeSheet = .addLodging(checkInDayOrder: order) } label: {
                Label("itinerary.category.lodging", systemImage: "bed.double")
            }
        } label: {
            inlineActionLabel(titleKey: "itinerary.add", icon: "plus")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        // 末个停靠点的连线在其自身行内终止（无底部留白），动作行用顶部留白与之分隔。
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func optimizeRow(_ dayID: UUID) -> some View {
        Button { activeSheet = .optimize(dayId: dayID) } label: {
            inlineActionLabel(titleKey: "itinerary.optimize.button", icon: "wand.and.stars")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// 内联动作行（添加地点 / 优化顺序）：图标落在 rail 圆点列、文字落在停靠点内容列，
    /// 与 `TimelineStopRow` 结构对齐（rail 宽 30 + spacing 12），整天「停靠点 + 动作」读成一列左对齐。
    private func inlineActionLabel(titleKey: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 12) {                       // = TimelineStopRow.railSpacing
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30)                   // = TimelineStopRow.railWidth，图标居中落在圆点列
            Text(titleKey)
                .font(.system(.subheadline, design: .rounded))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func dayHeaderRow(_ section: ItineraryDaySection) -> some View {
        if let day = days.first(where: { $0.id == section.id }) {
            dayHeader(day)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dayHeader(_ day: ItineraryDay) -> some View {
        // 日期头收进与 TimelineStopRow / 内联动作行同一套两列网格：圆点居中落在 rail 标记列
        // （26 宽，与类别图标圆 / +·✨ 同一条 spine），标题左缘对齐停靠点名称列（rail 26 + spacing 12）。
        // 分节层级靠字号/字重 + 上方留白建立，不靠更浅的缩进（north-star §2/§5）。
        HStack(spacing: 12) {                                     // = TimelineStopRow.railSpacing
            Circle()
                .fill(ItineraryDayPalette.color(forDayIndex: day.sortOrder))
                .frame(width: 8, height: 8)
                .frame(width: 30)                                // = railWidth，圆点居中落在标记列、压在 spine 上
            VStack(alignment: .leading, spacing: 2) {
                Text(dayDateLabel(day) ?? dayDisplayTitle(day))
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                if let title = customDayTitle(day) {
                    Text(title)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        // 首点上方原由「首点 cell 顶部占位」给的呼吸，已随连接段拆为独立 leg 而消失；
        // 在此用 header 底部留白补回（放 header 层、不动 stop cell，故不破坏左滑居中）。
        .padding(.bottom, 12)
        // 日期头不画分隔线（含吸顶时）：粗体圆体标题 + 当天彩色圆点 + 留白本身层级已足，吸顶时不透明
        // systemBackground 已干净切开浮动头与滚动内容，再加线是多余 chrome（north-star §1 退后 / §2 层级
        // 不靠线框，对标 Tripsy/Flighty/原生）。打包分区头是 ALL-CAPS 小灰字、分量轻，才保留锚定用的基线。
        .background(
            // header cell 已在 UIKit 层铺不透明 systemBackground；此处再铺一层，保证吸顶时无缝、不透出滚动内容。
            Rectangle()
                .fill(Color(UIColor.systemBackground))
        )
        .zIndex(3)
    }

    private func customDayTitle(_ day: ItineraryDay) -> String? {
        let trimmed = day.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 有日期行程：优先显示真实日期；无日期行程退回 Day N。
    private func dayDisplayTitle(_ day: ItineraryDay) -> String {
        if let date = dayDateLabel(day) { return date }
        let format = NSLocalizedString("itinerary.day.title", comment: "")
        return String(format: format, day.sortOrder + 1)
    }

    /// 有日期行程：按 出发日 + sortOrder 天 推算本地化日期（周几 月/日）。无日期行程返回 nil。
    private func dayDateLabel(_ day: ItineraryDay) -> String? {
        guard let bundle, !bundle.isDateless else { return nil }
        let base = Calendar.current.startOfDay(for: bundle.departureDate)
        let date = Calendar.current.date(byAdding: .day, value: day.sortOrder, to: base) ?? base
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// 与上一个停靠点的直线距离标签（即时本地，无网络）；任一端无坐标或首点返回 nil。
    private func legLabel(stops: [ItineraryStop], index: Int) -> String? {
        guard index > 0,
              let from = stops[index - 1].coordinate,
              let to = stops[index].coordinate else { return nil }
        let meters = RouteOptimizer.haversineMeters(from, to)
        return legDistanceFormatter.string(fromDistance: meters)
    }

    /// 到「下一站」的直线距离标签（供详情页路程模块）；本站是当天末站或两端无坐标返回 nil。
    private func distanceToNextStop(_ stop: ItineraryStop) -> String? {
        guard let day = days.first(where: { ($0.stops ?? []).contains { $0.id == stop.id } }) else { return nil }
        let stops = day.sortedStops
        guard let index = stops.firstIndex(where: { $0.id == stop.id }) else { return nil }
        return legLabel(stops: stops, index: index + 1)   // 复用：本站→下一站 = 下一站的 leg
    }

    /// 停靠点所属天的配色（与地图针 / 时间轴同色）。
    private func dayColor(forStop stop: ItineraryStop) -> Color {
        guard let day = days.first(where: { ($0.stops ?? []).contains { $0.id == stop.id } }) else { return .accentColor }
        return ItineraryDayPalette.color(forDayIndex: day.sortOrder)
    }


    // MARK: Mutations

    /// 滑动删除（collection 的 swipe action）。
    private func deleteStop(_ stopID: UUID) {
        guard let day = days.first(where: { ($0.stops ?? []).contains { $0.id == stopID } }) else { return }
        store.removeItineraryStop(tripId: tripId, dayId: day.id, stopId: stopID)
    }
}

// MARK: - ItineraryLegConnector

/// 相邻停靠点之间的连接段：固定高度的竖线 + 居中距离标签。独立成行（不再塞进 stop cell 顶部），
/// 使 stop cell 只含主行、左滑按钮按主行高度居中/定大小。竖线与 TimelineStopRow 的 rail 半段首尾相接。
private struct ItineraryLegConnector: View {
    let distance: String?
    let railColor: Color
    private let railWidth: CGFloat = 30        // = TimelineStopRow.railWidth
    private let railSpacing: CGFloat = 12       // = TimelineStopRow.railSpacing
    private let legGap: CGFloat = 24            // = 原 TimelineStopRow.legGap

    var body: some View {
        // 距离【夹在 Timeline 竖线里】：竖线在数字处被数字的背景切断、数字落在上下两段线中间、居中压在
        // spine 上，明确是这段 leg 的路程（在连接两站的路径上）。上下两段线靠相邻停靠点的 rail（含已修好
        // 的备注行连线）首尾接住，故数字不孤立、不飘。
        ZStack {
            Rectangle().fill(railColor).frame(width: 1.5)
            if let distance {
                Text(distance)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)        // 切口横向留白：数字两侧与线端留气口，不挤
                    .padding(.vertical, 1.5)        // 上下气口：线端不贴数字、夹得透气
                    .background(Color(uiColor: .systemBackground))
                    .fixedSize()
            }
        }
        .frame(width: railWidth, height: legGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - TransportTimelineRow

/// 交通段（边）行：rail 列放 mode 图标（当天色描边圆），详情列放班次 + 起讫站/时间。
/// 与 TimelineStopRow 的两列网格（rail 宽 30 + spacing 12）对齐，读成同一条时间轴。
private struct TransportTimelineRow: View {
    let segment: TransportSegment
    let dayColor: Color

    private let railWidth: CGFloat = 30
    private let railSpacing: CGFloat = 12

    var body: some View {
        HStack(spacing: railSpacing) {
            ZStack {
                Circle().strokeBorder(dayColor.opacity(0.5), lineWidth: 1.5)
                Image(systemName: segment.mode.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(dayColor)
            }
            .frame(width: 24, height: 24)
            .frame(width: railWidth)

            VStack(alignment: .leading, spacing: 2) {
                // 主行：班次（航司 · 班次号）；都空则退化用 mode 名。
                Text(titleText)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                // 次行：起讫站（+ 时间）。
                if let route = routeText {
                    Text(route)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var titleText: String {
        let parts = [segment.carrier, segment.number].filter { !$0.isEmpty }
        if parts.isEmpty {
            return NSLocalizedString(segment.mode.localizationKey, comment: "")
        }
        return parts.joined(separator: " · ")
    }

    /// 「KMG 09:00 → PEK 12:30」，缺项自适应；跨天到达加「+N」。
    private var routeText: String? {
        let from = endpointLabel(name: segment.fromName, code: segment.fromCode, minutes: segment.departLocalMinutes, dayOffset: 0)
        let to = endpointLabel(name: segment.toName, code: segment.toCode, minutes: segment.arriveLocalMinutes,
                               dayOffset: segment.arriveDayOrder - segment.departDayOrder)
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        if f.isEmpty && t.isEmpty { return nil }
        return "\(f) → \(t)"
    }

    private func endpointLabel(name: String, code: String, minutes: Int, dayOffset: Int) -> String {
        let place = !code.isEmpty ? code : name
        var s = place
        if minutes >= 0 {
            let time = timeLabel(dayMinutes: minutes)
            s = place.isEmpty ? time : "\(place) \(time)"
            if dayOffset > 0 { s += " +\(dayOffset)" }
        }
        return s
    }
}

// MARK: - LodgingBannerRow

/// 住宿常驻条：床图标 + 名称 + 状态。spec 倾向「入住/退房显事件、中间天极轻灰条」：
/// - 入住日：实心床 + 「入住 · 名称」（+ 入住时间），最醒目；
/// - 退房日：「退房 · 名称」（+ 退房时间）；
/// - 过夜中间天：极轻灰条，仅床轮廓 + 名称 + 晚数，退到背景。
private struct LodgingBannerRow: View {
    enum Phase { case checkIn, night, checkOut }
    let stay: LodgingStay
    let phase: Phase

    private let railWidth: CGFloat = 30
    private let railSpacing: CGFloat = 12

    private var displayName: String {
        stay.name.isEmpty ? NSLocalizedString("itinerary.category.lodging", comment: "") : stay.name
    }

    var body: some View {
        HStack(spacing: railSpacing) {
            Image(systemName: phase == .night ? "bed.double" : "bed.double.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: railWidth)
            Text(titleText)
                .font(.system(.footnote, design: .rounded).weight(phase == .night ? .regular : .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let trailing = trailingText {
                Text(trailing)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                // 过夜中间天更淡，退到背景；入住/退房日略实，作事件锚点。
                .fill(Color(.secondarySystemBackground).opacity(phase == .night ? 0.4 : 0.7))
        )
    }

    /// 入住/退房日带事件词前缀；过夜天仅名称。
    private var titleText: String {
        switch phase {
        case .checkIn:  return NSLocalizedString("itinerary.lodging.event.checkin", comment: "") + " · " + displayName
        case .checkOut: return NSLocalizedString("itinerary.lodging.event.checkout", comment: "") + " · " + displayName
        case .night:    return displayName
        }
    }

    /// 入住/退房日显对应时间（若设）；过夜天显晚数。
    private var trailingText: String? {
        switch phase {
        case .checkIn:
            return stay.checkInMinutes >= 0 ? timeLabel(dayMinutes: stay.checkInMinutes) : nil
        case .checkOut:
            return stay.checkOutMinutes >= 0 ? timeLabel(dayMinutes: stay.checkOutMinutes) : nil
        case .night:
            return String(format: NSLocalizedString("itinerary.lodging.nights_value", comment: ""), stay.nights)
        }
    }
}

// MARK: - TimelineStopRow

/// 时间轴行：leading 序号圆点 + 连线；序号圆点**与停靠点名称对齐**。段间连线/距离已拆为
/// 独立的 `ItineraryLegConnector` 行夹在相邻停靠点之间（本行只含主行 + 可选备注）。
private struct TimelineStopRow: View {
    let stop: ItineraryStop
    let index: Int
    let isLast: Bool
    /// 当天配色（与地图针 / 路线同色，便于图文互相对照）。
    let dayColor: Color

    private var railColor: Color { dayColor.opacity(0.25) }
    private let railWidth: CGFloat = 30
    private let circleSize: CGFloat = 28
    private let railSpacing: CGFloat = 12
    /// 固定行高——rail 连线由此完全确定，全程无 `maxHeight: .infinity` 贪婪 frame，
    /// 故自适应 cell 不会被撑高、各行（含首/末行）几何严格一致。
    private let rowHeight: CGFloat = 46
    /// 圆点上/下连线的固定半段长度（圆点在固定行高里垂直居中），与相邻 `ItineraryLegConnector` 首尾相接。
    private var halfLine: CGFloat { (rowHeight - circleSize) / 2 }

    var body: some View {
        // cell 只含主行（+ 可选备注）；段间连接段由独立的 ItineraryLegConnector 行承载。
        // 这样 cell 高度 = 主行高，左滑删除按钮按主行居中/定大小，不再因连接段被撑高而偏上偏大。
        VStack(spacing: 0) {
            // 停靠点主行：固定行高 + 居中对齐；rail 圆点与内容同在行中心，自然对齐。
            HStack(alignment: .center, spacing: railSpacing) {
                rail
                content
            }
            .frame(height: rowHeight)
            // 备注预览行：挂在主行下方，不动其固定几何；左侧补一条延续的连线列，使连接线不断开。
            if !stop.note.isEmpty {
                noteRow
            }
        }
    }

    /// 备注预览：让用户不进编辑也能看到备注。缩进到内容列、前缀 note 图标、截断 2 行；
    /// 左侧连线列延续主行圆点→下一段的连接线（末点不画）。
    private var noteRow: some View {
        HStack(spacing: railSpacing) {
            // 连线列【填满整行高，含文字下方留白】——首尾接住主行底部 stub 与下方 leg，备注处不再断线。
            Rectangle()
                .fill(isLast ? Color.clear : railColor)
                .frame(width: 1.5)
                .frame(width: railWidth)
                .frame(maxHeight: .infinity)
            // 不加前导图标：图标会把文字推到内容列右侧（x≈56），与名称/地址（x≈42）断成台阶，
            // 两行时整块「向右倾斜」。纯文本左齐 → 名称/地址/备注共一条左缘（north-star §5 对齐成线）。
            // 备注是会话化自然语言，内容已自证是备注，图标属冗余 chrome（§1 退后）。
            // 颜色用 tertiary（比地址 secondary 再淡一档）：落成 primary/secondary/tertiary 三层标签层级，
            // 与地址一眼分得开、不致读成同一坨；备注是预览（截断两行、完整内容在编辑页），退后正合适。
            Text(stop.note)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
        }
    }

    /// 时间标签：设了结束时间（stayMinutes>0）显示「开始–结束」，否则只显示开始。
    private var timeRangeLabel: String {
        let start = timeLabel(dayMinutes: stop.plannedStartMinutes)
        guard stop.stayMinutes > 0 else { return start }
        return "\(start)–\(timeLabel(dayMinutes: stop.plannedStartMinutes + stop.stayMinutes))"
    }

    /// 固定高度的 rail：上半连线（首点透明）+ 序号圆点 + 下半连线（末点透明）。
    /// 全部固定尺寸、无贪婪 frame——圆点恒在行高正中，相邻两圆点间连线对称、距离标签自然居中。
    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(index == 0 ? Color.clear : railColor)
                .frame(width: 1.5, height: halfLine)
            ZStack {
                Circle().fill(Color(uiColor: .systemBackground))
                Circle().fill(dayColor.opacity(0.15))
                // 类别图标取代序号：时间轴顺序由位置天然表达，图标更利于扫读「这是什么」。
                // 地图针仍用序号（地理散布、顺序不直观），分工见 decisions/progress。
                Image(systemName: stop.category.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dayColor)
            }
            .frame(width: circleSize, height: circleSize)
            Rectangle()
                .fill(isLast ? Color.clear : railColor)
                .frame(width: 1.5, height: halfLine)
        }
        .frame(width: railWidth)
    }

    private var content: some View {
        // 类别图标已移到 rail 圆点；此处只剩名称/地址 + 时间/无坐标标记。
        // 居中对齐：导航按钮(44pt)比名称块高，若顶对齐会把名称地址顶到上沿、与 rail 圆点(行中线)错位；
        // .center 让名称块与导航按钮都按行中线居中，名称块重新对齐圆点。
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // 名称与时间【同一行、右对齐】：地点=「什么」、时间=「何时」，互为一对，读成「地点 ——— 时间」
                // （对标日历/Flighty/Tripsy 的日程行）。时间落在名称基线上，不再悬在名称↔地址中缝里。
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(stop.name)
                        .font(.system(.body, design: .rounded).weight(.semibold))   // 名称加粗 + 圆体，作为每行的视觉锚
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if stop.plannedStartMinutes >= 0 {
                        Spacer(minLength: 6)
                        // 纯时间文字（去掉前导 pin 图标）：时间本身即表达「已排期」，图标冗余且其「优化时不会动」
                        // 的语义不自明。锚定行为不变，只去视觉噪音。secondary，不抢名称锚点。
                        Text(timeRangeLabel)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if !stop.address.isEmpty {
                    Text(stop.address)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // 恒满宽左对齐：否则「无时间」的行内容块只有固有宽度，会被外层 VStack（默认居中）挤向右
            // （仅「无时间 + 有备注」的行中招——备注行满宽把 VStack 撑开、主行被居中右移）。满宽后既不偏移，
            // 名称行里的 Spacer 仍能把时间推到行尾。
            .frame(maxWidth: .infinity, alignment: .leading)
            // 导航已收进停靠点详情的路程模块（点行 → 详情 → 导航）；行内只留「无坐标」轻提示
            // （数据完整性信号，看列表时即应知道）。行尾因此腾空，开始–结束时间得以贴到名称行真正行尾。
            if !stop.hasCoordinate {
                Image(systemName: "mappin.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        // 名称块与圆点（24pt 高）等高居中，使序号正对名称而非地址。
        .frame(minHeight: 24, alignment: .center)
    }
}

// MARK: - StopDetailView

/// 停靠点【只读详情】：点行进来先看信息（半高 sheet、看完即走）。时间/地址/备注只读展示，
/// 导航收在底部路程模块（行内 ↗ 迁入此处），编辑在右上角入口。默认只读避免误改敏感字段，
/// 契合「这屏多数是来看信息」的高频意图（spec: itinerary-stop-detail.md）。
struct StopDetailView: View {
    let tripId: UUID
    let stop: ItineraryStop
    let distanceToNext: String?
    let navApps: [MapNavigationApp]
    let dayColor: Color

    @State private var editing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    infoRows
                    navModule
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = true } label: { Text("itinerary.stop.detail.edit") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // 编辑钻入到详情之上：保存后回到详情（@Model 可观察、详情自动反映新值），再下滑关。
        .sheet(isPresented: $editing) {
            StopEditView(tripId: tripId, stop: stop)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(dayColor.opacity(0.15))
                Image(systemName: stop.category.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(dayColor)
            }
            .frame(width: 40, height: 40)
            Text(stop.name)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var infoRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            if stop.plannedStartMinutes >= 0 {
                detailRow(icon: "clock", text: timeRangeLabel)
            }
            if stop.hasCoordinate && !stop.address.isEmpty {
                detailRow(icon: "mappin.and.ellipse", text: stop.address)
            }
            if !stop.note.isEmpty {
                // 备注可任意长 → 默认折叠 6 行 + 展开/收起，避免长备注撑满详情、把导航模块挤到底。
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "note.text")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    ExpandableText(
                        text: stop.note,
                        font: .system(.subheadline, design: .rounded),
                        collapsedLineLimit: 6
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 路程 / 导航模块：导航到本地点（行内 ↗ 迁入）+ 到下一站直线距离。无坐标/无导航 App 不显示。
    @ViewBuilder
    private var navModule: some View {
        if stop.hasCoordinate && !navApps.isEmpty {
            VStack(spacing: 0) {
                navAction
                if let distanceToNext {
                    Divider().padding(.leading, 34)
                    HStack(spacing: 12) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                        Text(String(format: NSLocalizedString("itinerary.stop.detail.to_next", comment: ""), distanceToNext))
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    @ViewBuilder
    private var navAction: some View {
        if navApps.count > 1 {
            Menu {
                ForEach(navApps) { app in
                    Button(LocalizedStringKey(app.nameKey)) { navigate(app) }
                }
            } label: { navRowLabel }
        } else {
            Button { navigate(navApps[0]) } label: { navRowLabel }
                .buttonStyle(.plain)
        }
    }

    private var navRowLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                .font(.system(size: 18)).foregroundStyle(dayColor).frame(width: 22)
            Text("itinerary.stop.detail.navigate")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func navigate(_ app: MapNavigationApp) {
        guard let coord = stop.coordinate else { return }
        MapNavigationService.open(app, coordinate: coord, name: stop.name)
        CarryLogger.shared.log(.itineraryStopNavigated, context: app.rawValue)
    }

    private var timeRangeLabel: String {
        let start = timeLabel(dayMinutes: stop.plannedStartMinutes)
        guard stop.stayMinutes > 0 else { return start }
        return "\(start)–\(timeLabel(dayMinutes: stop.plannedStartMinutes + stop.stayMinutes))"
    }
}

// MARK: - ExpandableText

/// 可展开/收起的长文本：默认折叠到 `collapsedLineLimit` 行；**仅当文本确实被截断时**才显示「展开/收起」。
/// 截断检测：用同字体同宽下「全文高度」对比「折叠高度」（两份隐藏探针测高），不靠字数启发式，准确。
private struct ExpandableText: View {
    let text: String
    let font: Font
    let collapsedLineLimit: Int

    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0
    @State private var expanded = false

    private var isTruncated: Bool { fullHeight > collapsedHeight + 1 }

    private struct FullHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    private struct CollapsedHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(font)
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : collapsedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(measurementProbes)
            if isTruncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "itinerary.stop.detail.note_less" : "itinerary.stop.detail.note_more")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 隐藏探针：同字体、随宿主同宽（maxWidth:.infinity → background 取宿主宽）下测「全文 / 折叠 6 行」高度。
    private var measurementProbes: some View {
        ZStack {
            Text(text).font(font).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in Color.clear.preference(key: FullHeightKey.self, value: g.size.height) })
            Text(text).font(font).lineLimit(collapsedLineLimit).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in Color.clear.preference(key: CollapsedHeightKey.self, value: g.size.height) })
        }
        .hidden()
        .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }
        .onPreferenceChange(CollapsedHeightKey.self) { collapsedHeight = $0 }
    }
}

// MARK: - StopEditView

/// 轻量停靠点编辑：改名、改类型、备注、删除。
struct StopEditView: View {
    let tripId: UUID
    let stop: ItineraryStop

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var category: StopCategory
    @State private var note: String
    @State private var hasTime: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var showRelocate = false

    init(tripId: UUID, stop: ItineraryStop) {
        self.tripId = tripId
        self.stop = stop
        _name = State(initialValue: stop.name)
        _category = State(initialValue: stop.category)
        _note = State(initialValue: stop.note)
        _hasTime = State(initialValue: stop.plannedStartMinutes >= 0)
        let startMin = stop.plannedStartMinutes >= 0 ? stop.plannedStartMinutes : 9 * 60
        _startTime = State(initialValue: dateFromDayMinutes(startMin))
        // 结束时间：已存停留则 start+stay，否则默认 start+1h（可选，用户可改/拉平）。
        _endTime = State(initialValue: dateFromDayMinutes(stop.stayMinutes > 0 ? startMin + stop.stayMinutes : startMin + 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                // 「地点」段：名称（显示标签）/ 地址（只读定位）/ 更换地点 —— 一张「这是什么地方」的卡。
                // 名称与地址同段、视觉差异化（白底输入 vs 灰色只读 vs 蓝色动作），衔接顺、关系清楚。
                Section {
                    TextField(text: $name) { Text("itinerary.stop.edit.name") }
                    if stop.hasCoordinate && !stop.address.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.secondary)
                            Text(stop.address)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showRelocate = true
                    } label: {
                        Label(stop.hasCoordinate ? "itinerary.stop.edit.relocate" : "itinerary.stop.edit.set_location",
                              systemImage: "mappin.circle")
                    }
                } header: {
                    Text("itinerary.stop.edit.location_header")   // 「地点」（不是「位置」——含名称，语义为「这个地点」）
                } footer: {
                    Text("itinerary.stop.edit.name_footer")       // 名称是显示标签，可自定义
                }

                // 「详情」段：类型 + 可选的「开始 + 结束」时间段（结束以 stayMinutes 存）。
                Section {
                    // 自定义 Menu 替代原生 Picker：菜单 Picker 的「收起选中值」由系统按自己的紧凑排版渲染、
                    // 无视选项里的自定义间距（故下拉松、收起挤，且 SwiftUI 不给改）。改用 Menu 后，收起值标签
                    // 由我们手搓 → 图标↔文字间距 100% 可控；下拉仍是系统菜单 Picker（用 Label、间距本就合适）。
                    Menu {
                        Picker(selection: $category) {
                            ForEach(StopCategory.allCases, id: \.self) { cat in
                                Label(cat.titleKey, systemImage: cat.symbolName).tag(cat)
                            }
                        } label: {
                            Text("itinerary.add_stop.category")
                        }
                    } label: {
                        HStack {
                            Text("itinerary.add_stop.category")
                                .foregroundStyle(.primary)
                            Spacer()
                            HStack(spacing: 6) {                       // ← 收起值的呼吸感
                                Image(systemName: category.symbolName)
                                Text(category.titleKey)
                                Image(systemName: "chevron.up.chevron.down")
                                    .imageScale(.small)
                            }
                            .foregroundStyle(CarryAccent.color)
                        }
                    }
                    Toggle(isOn: $hasTime) { Text("itinerary.stop.edit.set_time") }
                        .tint(CarryAccent.color)
                    if hasTime {
                        DatePicker(selection: $startTime, displayedComponents: .hourAndMinute) {
                            Text("itinerary.stop.edit.start_time")
                        }
                        DatePicker(selection: $endTime, in: startTime..., displayedComponents: .hourAndMinute) {
                            Text("itinerary.stop.edit.end_time")
                        }
                    }
                } header: {
                    Text("itinerary.stop.edit.details_header")
                } footer: {
                    if hasTime {
                        Text("itinerary.stop.edit.time_footer")
                    }
                }
                .onChange(of: startTime) { _, newStart in
                    if endTime < newStart { endTime = newStart }   // 结束不早于开始
                }

                Section {
                    TextField(text: $note, axis: .vertical) { Text("itinerary.stop.edit.note") }
                        .lineLimit(2...5)
                }
                Section {
                    Button(role: .destructive) {
                        if let dayId = stop.day?.id {
                            store.removeItineraryStop(tripId: tripId, dayId: dayId, stopId: stop.id)
                        }
                        dismiss()
                    } label: {
                        Label("itinerary.stop.edit.delete", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(Text("itinerary.stop.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let startMin = dayMinutes(from: startTime)
                        let stay = hasTime ? max(0, dayMinutes(from: endTime) - startMin) : 0
                        store.updateItineraryStop(
                            tripId: tripId,
                            stopId: stop.id,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            category: category,
                            plannedStartMinutes: hasTime ? startMin : -1,
                            stayMinutes: stay,
                            note: note
                        )
                        dismiss()
                    }
                }
            }
            // 更换地点：复用 AddStopView 的搜索（relocate 模式更新本停靠点的坐标/地址/名称）。
            .sheet(isPresented: $showRelocate) {
                AddStopView(
                    tripId: tripId,
                    dayId: stop.day?.id ?? UUID(),
                    biasLatitude: stop.latitude,
                    biasLongitude: stop.longitude,
                    relocateStopId: stop.id,
                    onRelocated: { newName in name = newName }
                )
            }
        }
    }
}
