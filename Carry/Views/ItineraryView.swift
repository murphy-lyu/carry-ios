//
//  ItineraryView.swift
//  Carry
//
//  行程路线规划视图——打包清单并列的「第二张脸」（spec: itinerary-route-planning.md）。
//  按 Day 分组的有序停靠点：增删、拖拽重排、地理搜索选点。地图区在 ItineraryMapView。
//

import SwiftUI
import MapKit

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
    case searchFlight(dayId: UUID)
    case addTransport(dayId: UUID, mode: TransportMode)
    case transportDetail(TransportSegment, focus: TransportDetailFocus)
    case editTransport(UUID)
    case addLodging(checkInDayOrder: Int)
    /// `dayOrder` = the day whose row was tapped (check-in / overnight / checkout) — drives the
    /// detail's accent so it matches the colour the user touched, not always the check-in day.
    case lodgingDetail(LodgingStay, dayOrder: Int)
    case editLodging(UUID)
    case calendarEvent(CalendarOverlayEvent)

    var id: String {
        switch self {
        case .addStop(let dayId): return "add-\(dayId)"
        case .stopDetail(let stop): return "detail-\(stop.id)"
        case .editStop(let stop): return "edit-\(stop.id)"
        case .optimize(let dayId): return "opt-\(dayId)"
        case .searchFlight(let dayId): return "searchfl-\(dayId)"
        case .addTransport(let dayId, let mode): return "addtr-\(dayId)-\(mode.rawValue)"
        case .transportDetail(let seg, let focus): return "trdetail-\(seg.id)-\(focus.idToken)"
        case .editTransport(let id): return "edittr-\(id)"
        case .addLodging(let order): return "addlg-\(order)"
        case .lodgingDetail(let stay, let dayOrder): return "lgdetail-\(stay.id)-\(dayOrder)"
        case .editLodging(let id): return "editlg-\(id)"
        case .calendarEvent(let ev): return "calev-\(ev.id)"
        }
    }
}

// MARK: - ItineraryView

struct ItineraryView: View {
    let tripId: UUID
    /// 「地点排序」模式（由容器 PackingListView 的菜单/工具栏驱动）：压缩行 + 拖拽手柄 + 锁 tap。
    var isReordering: Binding<Bool> = .constant(false)

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    /// 距离单位偏好（自动 / 公里 / 英里）；切换后段距/路程模块实时重渲染。
    @AppStorage("distance_unit") private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic }

    @State private var activeSheet: ItinerarySheet?
    @State private var focusedDayId: UUID?
    /// 已安装的导航 App，onAppear 时探测一次（避免每行重复 canOpenURL）。
    /// 行内导航按钮据此：≥2 个弹锚定 `Menu`、仅 1 个（只有 Apple 地图）直接调起。
    @State private var navApps: [MapNavigationApp] = []

    // 日历事件叠加层（spec: itinerary-calendar-overlay.md）。只读、永不入 model/分享/导出。
    @AppStorage(CalendarManager.overlayEnabledKey) private var calendarOverlayEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    /// 按天序分桶的只读日历事件；视图层临时态，不持久化。
    @State private var overlayEventsByDay: [Int: [CalendarOverlayEvent]] = [:]

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

        // 性能：sortOrder → day 建一次字典再 O(1) 查（原来每天都 days.first(where:) = O(N²)，
        // 且每次还重排 days；长行程下每次 body 求值都算几十万次，是空 180 天行程卡顿的主因）。
        let dayByOrder = Dictionary(bundle.safeItineraryDays.map { ($0.sortOrder, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let cal = Calendar.current
        return (0..<visibleDays).map { offset in
            let date = cal.date(byAdding: .day, value: offset, to: startDate) ?? startDate
            return CalendarEntry(offset: offset, date: date, day: dayByOrder[offset])
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
            case .searchFlight(let dayId):
                FlightSearchSheet(tripId: tripId, dayId: dayId)
            case .addTransport(let dayId, let mode):
                TransportEditView(tripId: tripId, dayId: dayId, initialMode: mode)
            case .transportDetail(let seg, let focus):
                TransportDetailView(
                    tripId: tripId,
                    segment: seg,
                    focus: focus,
                    navApps: navApps,
                    dayColor: ItineraryDayPalette.color(forDayIndex: focus == .dropoff ? seg.arriveDayOrder : seg.departDayOrder)
                )
            case .editTransport(let id):
                TransportEditView(tripId: tripId, segmentId: id)
            case .addLodging(let order):
                // 「+」住宿走搜索优先（与添加地点/航班一致）：搜到选中即直接加，底部「手动添加」push 进表单。
                LodgingSearchSheet(tripId: tripId, initialCheckInDayOrder: order)
            case .lodgingDetail(let stay, let dayOrder):
                LodgingDetailView(
                    tripId: tripId,
                    stay: stay,
                    navApps: navApps,
                    dayColor: ItineraryDayPalette.color(forDayIndex: dayOrder)
                )
            case .editLodging(let id):
                LodgingEditView(tripId: tripId, stayId: id)
            case .calendarEvent(let event):
                CalendarEventDetailView(event: event)
            }
        }
        // 照片回溯生成的入口已收进行程详情页共享「…」菜单（PackingListView），不在此另起工具栏图标。
        .toolbarBackground(Color(UIColor.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            store.syncItineraryDays(tripId: tripId)   // 兜底：天对齐到行程天数（存量行程/新建首开）
            syncFocusedDaySelectionIfNeeded()
            consumePendingItineraryAnchor()           // 深链锚点优先于默认聚焦首日
            navApps = MapNavigationService.availableApps()
            loadCalendarOverlay()
        }
        .onChange(of: days.map(\.id)) { _, _ in
            syncFocusedDaySelectionIfNeeded()
            consumePendingItineraryAnchor()           // 冷启动 days 后到时再消费一次
        }
        .onChange(of: calendarOverlayEnabled) { _, _ in loadCalendarOverlay() }
        // 从系统日历/设置返回（改了开关或选中日历）→ 刷新叠加层。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loadCalendarOverlay() }
        }
    }

    // MARK: Day list

    /// dateless 行程且整趟还没有任何地点/交通/住宿 → 用空态引导（而非地图下方孤零零的「Day 1 + 添加」）。
    private var isDatelessEmpty: Bool {
        guard let bundle, bundle.isDateless, !isReordering.wrappedValue else { return false }
        let noStops = days.allSatisfy { ($0.stops ?? []).isEmpty }
        let noSegments = days.allSatisfy { ($0.segments ?? []).isEmpty }
        let noLodging = (bundle.lodgingStays ?? []).isEmpty
        return noStops && noSegments && noLodging
    }

    /// dateless 空态：图标 + 「想去哪些地方?」+ 引导 + 「添加地点」CTA。复用 app 空态范式（north-star §8 叙事）。
    private var datelessEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "map")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("itinerary.dateless.empty.title")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text("itinerary.dateless.empty.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 8)
            Button {
                if let firstDay = days.first { activeSheet = .addStop(dayId: firstDay.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text("itinerary.dateless.empty.cta")
                }
            }
            .buttonStyle(CarryEmptyStatePrimaryButtonStyle())
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }

    private var dayList: some View {
        VStack(spacing: 8) {
            ItineraryMapView(tripId: tripId, focusedDayId: activeFocusedDayId,
                             suppressEmptyInvite: isDatelessEmpty)
            if isDatelessEmpty {
                Spacer(minLength: 0)
                datelessEmptyState
                Spacer(minLength: 0)
            } else {
            itineraryCalendarStrip
            // 原生 collection：长按拖拽，停靠点可跨天移动（spec: 跨天拖拽）。
            ItineraryReorderCollection(
                sections: daySections,
                scrollTargetDayId: activeFocusedDayId,
                isReordering: isReordering.wrappedValue,
                stopContent: { AnyView(stopRow($0)) },
                legContent: { AnyView(legRow($0)) },
                transportContent: { AnyView(transportRow($0)) },
                lodgingContent: { AnyView(lodgingRow($0, $1, $2)) },
                lodgingLegContent: { AnyView(lodgingLegRow($0, $1, $2, $3)) },
                carRentalContent: { AnyView(carRentalRow($0, $1, $2)) },
                calendarEventContent: { AnyView(calendarEventRow($0, $1)) },
                addStopContent: { AnyView(addStopRow($0)) },
                headerContent: { AnyView(dayHeaderRow($0)) },
                onDelete: { deleteStop($0) },
                onDeleteTransport: { deleteTransport($0) },
                onDeleteLodging: { deleteLodging($0) },
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
    }

    /// 影响 Day header 标签的行程级日期态。变化即强制 collection 重建（罕见操作，代价可忽略）。
    private var itineraryDateStateKey: String {
        guard let bundle else { return "none" }
        return "\(bundle.isDateless)_\(bundle.departureDate.timeIntervalSince1970)"
    }

    private var itineraryCalendarStrip: some View {
        // 计算一次复用（原先 `.isEmpty` + ForEach 各算一遍）。
        let entries = calendarEntries
        return VStack(alignment: .leading, spacing: 2) {
            if !entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // LazyHStack：长行程只构造可见的日期格，不再一次性建 181 个 cell。
                        LazyHStack(alignment: .top, spacing: 11) {
                            ForEach(entries) { entry in
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
                    // 横向 ScrollView 默认撑满竖直空间（不按内容收缩）→ 日期格被摆在高框顶部、下方留一大片空，
                    // 把逐日列表顶到屏幕下半。fixedSize 竖直按内容（日历格高）收缩，空白消除。
                    .fixedSize(horizontal: false, vertical: true)
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

    /// 消费深链锚点（spec: notification-deeplink-routing.md）：定位到对应天，`activeFocusedDayId`
    /// 变化即驱动 collection 滚动 + 日历条居中。仅行程脸唤起、故只在此消费。days 未就绪（冷启动竞态）
    /// 时不清空，待 days onChange 再来；解析不到（项已删等）则安全略过。消费后清空避免切别的行程重复触发。
    private func consumePendingItineraryAnchor() {
        guard let anchor = router.pendingItineraryAnchor, !days.isEmpty else { return }
        if let dayId = resolveAnchorDayId(anchor) { focusedDayId = dayId }
        router.pendingItineraryAnchor = nil
    }

    private func resolveAnchorDayId(_ anchor: TripDeepLinkAnchor) -> UUID? {
        switch anchor {
        case .day(let order):
            return days.first { $0.sortOrder == order }?.id
        case .segment(let segId):
            return days.first { $0.sortedSegments.contains { $0.id == segId } }?.id
        case .lodging(let stayId):
            guard let stay = bundle?.safeLodgingStays.first(where: { $0.id == stayId }) else { return nil }
            return days.first { $0.sortOrder == stay.checkOutDayOrder }?.id
        }
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
        return days.map { day in
            // 日历事件叠加行（spec: itinerary-calendar-overlay.md 增补 2026-06-22）：
            // 全天事件无时刻 → 钉当天顶部（背景信息 band）；定时事件 → 交给 timelineRowIDs 按各自时刻插入主脊，
            // 让这一天按时序读（时间轴的核心承诺），而非把所有日历事件不分时刻全钉顶部。
            let allDayRows: [ItineraryRowID] = (overlayEventsByDay[day.sortOrder] ?? [])
                .filter { $0.isAllDay }
                .map { .calendarEvent(id: $0.id, day: day.sortOrder) }
            // 住宿不再是顶部常驻条——已按当天角色（入住/出发/过夜/退房）注入主脊，见 timelineRowIDs。
            return ItineraryDaySection(
                id: day.id,
                entries: allDayRows + timelineRowIDs(for: day, timedCalendar: timedCalendarRows(day))
            )
        }
    }

    /// 当天「定时」日历事件（非全天）→ (id, 起始分钟)，供 timelineRowIDs 按时刻插入主脊。
    private func timedCalendarRows(_ day: ItineraryDay) -> [(id: String, minutes: Int)] {
        (overlayEventsByDay[day.sortOrder] ?? [])
            .filter { !$0.isAllDay }
            .map { (id: $0.id, minutes: $0.startMinutes) }
    }

    /// 当天「在主脊上」的行序列（停靠点 + 交通段，按 day.timeline 共享 sortOrder/时间）。
    /// **租车段拆成两条事件**：取车落在 timeline 给的取车时间位；还车按还车时间注入本天（其还车日可能 ≠ 出发日）。
    /// 是 daySections 的时间轴部分，也供首/末端点判定（连续脊的两端清线）。spec: itinerary-car-rental.md。
    private func timelineRowIDs(for day: ItineraryDay, timedCalendar: [(id: String, minutes: Int)] = []) -> [ItineraryRowID] {
        let carRentals = days.flatMap { $0.sortedSegments }.filter { $0.mode == .carRental }
        var timed: [(row: ItineraryRowID, minutes: Int)] = []
        var carry = -1
        for item in day.timeline {
            let own = item.effectiveMinutes
            if own >= 0 { carry = own }
            let eff = own >= 0 ? own : carry
            switch item {
            case .stop(let s): timed.append((.stop(s.id), eff))
            case .transport(let t):
                timed.append(t.mode == .carRental
                    ? (.carRental(segment: t.id, day: day.sortOrder, pickup: true), eff)
                    : (.transport(t.id), eff))
            }
        }
        for seg in carRentals where seg.arriveDayOrder == day.sortOrder {
            let m = seg.arriveLocalMinutes
            var idx = timed.count
            if m >= 0, let found = timed.firstIndex(where: { $0.minutes >= 0 && $0.minutes > m }) { idx = found }
            timed.insert((.carRental(segment: seg.id, day: day.sortOrder, pickup: false), m), at: idx)
        }
        // 住宿按当天角色注入主脊（spec 增补 2026-06-20）：入住日=入住（按入住时间就位、默认置末——
        // 当天玩完才回来 check in）；退房日=退房（按退房时间就位、默认置首——早上离店）；
        // 整中间日=出发（晨起，置首）+ 过夜（夜归，置末）。空中间日（无其它事项）只留「过夜」一条，避免两条相邻。
        var departs: [ItineraryRowID] = []   // 置首
        var overnights: [ItineraryRowID] = []// 置末
        for stay in (bundle?.safeLodgingStays ?? [])
            where stay.checkInDayOrder <= day.sortOrder && day.sortOrder <= stay.checkOutDayOrder {
            if day.sortOrder == stay.checkInDayOrder {
                let m = stay.checkInMinutes
                var idx = timed.count
                if m >= 0, let found = timed.firstIndex(where: { $0.minutes >= 0 && $0.minutes > m }) { idx = found }
                timed.insert((.lodging(stay: stay.id, day: day.sortOrder, role: .checkIn), m), at: idx)
            } else if day.sortOrder == stay.checkOutDayOrder {
                let m = stay.checkOutMinutes
                var idx = 0
                if m >= 0, let found = timed.firstIndex(where: { $0.minutes >= 0 && $0.minutes > m }) { idx = found }
                timed.insert((.lodging(stay: stay.id, day: day.sortOrder, role: .checkout), m), at: idx)
            } else {
                if !timed.isEmpty { departs.append(.lodging(stay: stay.id, day: day.sortOrder, role: .depart)) }
                overnights.append(.lodging(stay: stay.id, day: day.sortOrder, role: .overnight))
            }
        }
        // 定时日历事件按各自时刻插入主脊（spec: itinerary-calendar-overlay.md 增补 2026-06-22）：
        // 时间轴承诺按时序读 → 定时事件落到它的时间位、不再全钉顶部；全天事件无时刻、仍钉顶（见 daySections）。
        for ev in timedCalendar {
            var idx = timed.count
            if ev.minutes >= 0, let found = timed.firstIndex(where: { $0.minutes >= 0 && $0.minutes > ev.minutes }) { idx = found }
            timed.insert((.calendarEvent(id: ev.id, day: day.sortOrder), ev.minutes), at: idx)
        }
        return departs + timed.map(\.row) + overnights
    }

    private func isCalendarRow(_ rowID: ItineraryRowID) -> Bool {
        if case .calendarEvent = rowID { return true }
        return false
    }

    /// 主脊连续性（邻接判定）：脊上首项不画上半线、末项不画下半线；相邻为日历事件时也断线——
    /// 定时日历事件按时序落在主脊它的位置，但脊在它处**自然断开**（它是「来自你的日历」的外部叠加项、
    /// 不属于你规划的路线）。规划行之间仍两端皆画 → 与相邻规划行无缝相接。
    private func showsTopLine(_ rowID: ItineraryRowID, in day: ItineraryDay) -> Bool {
        let order = timelineRowIDs(for: day, timedCalendar: timedCalendarRows(day))
        guard let i = order.firstIndex(of: rowID), i > 0 else { return false }
        return !isCalendarRow(order[i - 1])
    }
    private func showsBottomLine(_ rowID: ItineraryRowID, in day: ItineraryDay) -> Bool {
        let order = timelineRowIDs(for: day, timedCalendar: timedCalendarRows(day))
        guard let i = order.firstIndex(of: rowID), i < order.count - 1 else { return false }
        return !isCalendarRow(order[i + 1])
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
                showTopLine: showsTopLine(.stop(stopID), in: day),
                showBottomLine: showsBottomLine(.stop(stopID), in: day),
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

    /// 住宿端点↔相邻地点的距离连接段（spec 增补 2026-06-20）。两端坐标算大圆距离；任一端无坐标 →
    /// 仍渲染连线段（distance nil），保持主脊连续。`departing` 不影响距离（对称），仅用于行 ID 唯一。
    private func lodgingLegRow(_ stayID: UUID, _ stopID: UUID, _ dayOrder: Int, _ departing: Bool) -> some View {
        let stay = (bundle?.lodgingStays ?? []).first { $0.id == stayID }
        let stop = days.flatMap { $0.sortedStops }.first { $0.id == stopID }
        let distance: String? = {
            guard let h = stay?.coordinate, let s = stop?.coordinate else { return nil }
            return CarryDistanceFormat.string(meters: RouteOptimizer.haversineMeters(h, s), unit: distanceUnit)
        }()
        return ItineraryLegConnector(
            distance: distance,
            railColor: ItineraryDayPalette.color(forDayIndex: dayOrder).opacity(0.25)
        )
        .padding(.horizontal, 16)
    }

    /// 交通段连接行（边）：mode 图标落在 rail 列，详情列显示班次 + 起讫站/时间。点击编辑。
    @ViewBuilder
    private func transportRow(_ segmentID: UUID) -> some View {
        if let day = days.first(where: { ($0.segments ?? []).contains { $0.id == segmentID } }),
           let seg = day.sortedSegments.first(where: { $0.id == segmentID }) {
            TransportTimelineRow(
                segment: seg,
                dayColor: ItineraryDayPalette.color(forDayIndex: day.sortOrder),
                showTopLine: showsTopLine(.transport(segmentID), in: day),
                showBottomLine: showsBottomLine(.transport(segmentID), in: day)
            )
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture { activeSheet = .transportDetail(seg, focus: .full) }
        }
    }

    /// 租车事件行（取车 / 还车）：同一租车段拆成两天两条事件，点击进同一段的详情。
    /// spec: itinerary-car-rental.md（增补：租车两事件）。
    @ViewBuilder
    private func carRentalRow(_ segID: UUID, _ dayOrder: Int, _ pickup: Bool) -> some View {
        if let seg = days.flatMap({ $0.sortedSegments }).first(where: { $0.id == segID }),
           let day = days.first(where: { $0.sortOrder == dayOrder }) {
            let rowID = ItineraryRowID.carRental(segment: segID, day: dayOrder, pickup: pickup)
            CarRentalEventRow(
                segment: seg, pickup: pickup,
                dayColor: ItineraryDayPalette.color(forDayIndex: dayOrder),
                showTopLine: showsTopLine(rowID, in: day),
                showBottomLine: showsBottomLine(rowID, in: day)
            )
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                // 取车 / 还车点开各自聚焦那一端（地址 + 导航），不再两端都铺。
                .onTapGesture { activeSheet = .transportDetail(seg, focus: pickup ? .pickup : .dropoff) }
        }
    }

    /// 住宿常驻条：覆盖本天的住宿，置于当天顶部。点击编辑。
    /// 住宿脊上节点：`role`（入住/出发/过夜/退房）由 timelineRowIDs 按当天角色决定。
    /// 与地点/交通同走 TimelineRail，按首/末项清线 → 主脊连续穿过。
    @ViewBuilder
    private func lodgingRow(_ stayID: UUID, _ dayOrder: Int, _ role: LodgingRole) -> some View {
        if let stay = (bundle?.lodgingStays ?? []).first(where: { $0.id == stayID }),
           let day = days.first(where: { $0.sortOrder == dayOrder }) {
            let rowID = ItineraryRowID.lodging(stay: stayID, day: dayOrder, role: role)
            LodgingBannerRow(stay: stay, role: role,
                             dayColor: ItineraryDayPalette.color(forDayIndex: dayOrder),
                             showTopLine: showsTopLine(rowID, in: day),
                             showBottomLine: showsBottomLine(rowID, in: day))
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture { activeSheet = .lodgingDetail(stay, dayOrder: dayOrder) }
        }
    }

    /// 只读日历事件叠加行（spec: itinerary-calendar-overlay.md）。
    /// 点击在 **Carry 内** 弹详情浮层（不跳系统日历——行程规划是核心页，避免误触跳出 App）。
    @ViewBuilder
    private func calendarEventRow(_ id: String, _ day: Int) -> some View {
        if let event = (overlayEventsByDay[day] ?? []).first(where: { $0.id == id }) {
            CalendarEventRow(event: event)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture { activeSheet = .calendarEvent(event) }
        }
    }

    /// 加载行程区间内、所选日历的只读事件，按天序分桶。开关关 / 无权限 / 无日期行程 → 清空。
    /// 纯视图层临时态，绝不写入 model / 分享 / 导出（spec 隐私红线，由「不入 model」构造保证）。
    private func loadCalendarOverlay() {
        guard calendarOverlayEnabled,
              let bundle, !bundle.isDateless,
              CalendarManager.shared.hasAccess else {
            if !overlayEventsByDay.isEmpty { overlayEventsByDay = [:] }
            return
        }
        let ids = CalendarManager.overlaySelectedCalendarIDs()
        guard !ids.isEmpty else { if !overlayEventsByDay.isEmpty { overlayEventsByDay = [:] }; return }

        let greg = Calendar.current
        let tripStart = greg.startOfDay(for: bundle.departureDate)
        guard let tripEnd = greg.date(byAdding: .day, value: max(bundle.days, 1), to: tripStart) else { return }
        let events = CalendarManager.shared.overlayEvents(start: tripStart, end: tripEnd, calendarIDs: ids)

        var buckets: [Int: [CalendarOverlayEvent]] = [:]
        for day in days {
            guard let dayStart = greg.date(byAdding: .day, value: day.sortOrder, to: tripStart),
                  let dayEnd = greg.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let inDay = events
                .filter { $0.startDate < dayEnd && $0.endDate > dayStart }   // 与当天区间相交（含跨天全天事件）
                .sorted { a, b in
                    if a.isAllDay != b.isAllDay { return a.isAllDay }         // 全天在前
                    return a.startMinutes < b.startMinutes
                }
            if !inDay.isEmpty { buckets[day.sortOrder] = inDay }
        }
        overlayEventsByDay = buckets
    }

    /// 统一「+ 添加」入口（spec: itinerary-transport-lodging.md）：菜单选类型 → 地点 / 航班 / 火车 / 住宿。
    /// 次级内联动作用 secondary 灰，与打包「添加物品」一致（避免每组一行 accent 蓝、喧宾夺主）。
    private func addStopRow(_ dayID: UUID) -> some View {
        let order = days.first(where: { $0.id == dayID })?.sortOrder ?? 0
        return Menu {
            Button { activeSheet = .addStop(dayId: dayID) } label: {
                Label("itinerary.kind.place", systemImage: "mappin")
            }
            // 交通组（边）：常用类型直列、低频收进「更多交通」子菜单——外层保持轻、低频也能一步直接落位，
            // 不在外层重复列出常用项。spec: itinerary-car-rental.md。
            Section("itinerary.add.section.transport") {
                ForEach(TransportMode.commonModes, id: \.self) { mode in
                    Button { addTransport(mode, dayID) } label: {
                        Label(mode.titleKey, systemImage: mode.symbolName)
                    }
                }
                Menu {
                    ForEach(TransportMode.moreModes, id: \.self) { mode in
                        Button { addTransport(mode, dayID) } label: {
                            Label(mode.titleKey, systemImage: mode.symbolName)
                        }
                    }
                } label: {
                    Label("itinerary.add.more_transport", systemImage: "ellipsis")
                }
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

    /// 交通入口路由：航班走「搜索优先」（航班号→自动填），其余走通用交通表单。
    /// spec: itinerary-flight-search-first.md。
    private func addTransport(_ mode: TransportMode, _ dayID: UUID) {
        if mode == .flight {
            activeSheet = .searchFlight(dayId: dayID)
        } else {
            activeSheet = .addTransport(dayId: dayID, mode: mode)
        }
    }

    /// 当天是否显示「优化顺序」入口：固定首尾后需中间 ≥2 个点才有可优化空间，故坐标点 ≥4 才露。
    private func showsOptimize(_ day: ItineraryDay) -> Bool {
        day.sortedStops.filter(\.hasCoordinate).count >= 4
    }

    /// day header 尾部的「优化顺序」入口：作用于整天的工具操作，落在「这天的标题栏」层级
    /// （对齐 Apple section-header accessory）；中性色 = 工具非主 CTA；header 吸顶 → 地点再多也一伸手可及。
    private func optimizeHeaderButton(_ day: ItineraryDay) -> some View {
        Button { activeSheet = .optimize(dayId: day.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
                Text("itinerary.optimize.button")
                    .font(.system(.subheadline, design: .rounded))
            }
            .foregroundStyle(.secondary)
            // 垂直内边距压到最小：header 高度几乎只由标题决定，有/无优化的天近似等高（§5 节奏）；
            // 点击区主要靠横向铺开补回（对齐 Apple header 里「See All」式矮而宽的附属按钮）。
            .padding(.vertical, 4)
            .padding(.leading, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("itinerary.optimize.button"))
    }

    /// 内联动作行（添加地点）：图标落在 rail 圆点列、文字落在停靠点内容列，
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
                .frame(width: 10, height: 10)                    // 与 20pt 加粗日期头光学配重（仍是「点」非「盘」）
                .frame(width: 30)                                // = railWidth，圆点居中落在标记列、压在 spine 上
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(dayDateLabel(day) ?? dayDisplayTitle(day))
                        // 比行标题（.body semibold 17）明显大一档、更重 → 日期头成为分节父级，
                        // 不靠线/缩进。纯字号字重建立层级（north-star §2/§3）。
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    // 多时区行程：当天所在时区小标（如 GMT+1）；单时区不显（spec: itinerary-timezone.md D1/D2）。
                    if let zone = dayZoneLabel(day) {
                        Text(zone)
                            .font(.system(.caption2, design: .rounded).weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                }
                if let title = customDayTitle(day) {
                    Text(title)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            // 「优化顺序」入口收进 header 尾部：作用于整天的操作落在标题栏层级；排序模式下隐藏
            // （此时在手动拖拽，不应再露自动优化）。仅 ≥4 个坐标点（中间 ≥2 可重排）才出现。
            if !isReordering.wrappedValue && showsOptimize(day) {
                Spacer(minLength: 8)
                optimizeHeaderButton(day)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 22)                                       // 每天上方多一截留白 → 节奏上把「新的一天」断开
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

    /// 多时区行程时，当天代表时区的小标（如 "GMT+1"，按当天实际日期算偏移、含夏令时）；
    /// 单时区行程或缺时区信息返回 nil（spec: itinerary-timezone.md D1/D2）。
    private func dayZoneLabel(_ day: ItineraryDay) -> String? {
        guard let bundle, bundle.isMultiTimeZone else { return nil }
        // carry-forward：空白天继承「上一次落地后所在的时区」（飞抵后即在目的地），而非回退出发地。
        let tzId = bundle.displayTimeZoneIds()[day.sortOrder] ?? bundle.primaryTimeZoneId
        guard let tz = TimeZone(identifier: tzId) else { return nil }
        let base = Calendar.current.startOfDay(for: bundle.departureDate)
        let date = Calendar.current.date(byAdding: .day, value: day.sortOrder, to: base) ?? base
        return gmtOffsetLabel(tz.secondsFromGMT(for: date))
    }

    /// 秒偏移 → "GMT+8" / "GMT−3:30" / "GMT+0"（负号用 U+2212 减号，排版更齐）。
    private func gmtOffsetLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let mins = abs(seconds) / 60
        let h = mins / 60, m = mins % 60
        return m == 0 ? "GMT\(sign)\(h)" : String(format: "GMT%@%d:%02d", sign, h, m)
    }

    /// 有日期行程：优先显示真实日期；无日期行程（永远只 1 天）显示「想去的地点」愿望清单标题——
    /// 而非误导性的「Day 1」（dateless 还没排日程，只是先收集想去的地方）。
    private func dayDisplayTitle(_ day: ItineraryDay) -> String {
        if let date = dayDateLabel(day) { return date }
        if bundle?.isDateless == true {
            return NSLocalizedString("itinerary.dateless.section", comment: "")
        }
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
        guard index > 0, index < stops.count,
              let from = stops[index - 1].coordinate,
              let to = stops[index].coordinate else { return nil }
        let meters = RouteOptimizer.haversineMeters(from, to)
        return CarryDistanceFormat.string(meters: meters, unit: distanceUnit)
    }

    /// 到「下一站」的直线距离标签（供详情页路程模块）；本站是当天末站或两端无坐标返回 nil。
    private func distanceToNextStop(_ stop: ItineraryStop) -> String? {
        guard let day = days.first(where: { ($0.stops ?? []).contains { $0.id == stop.id } }) else { return nil }
        let stops = day.sortedStops
        guard let index = stops.firstIndex(where: { $0.id == stop.id }),
              index + 1 < stops.count else { return nil }   // 末站无「下一站」→ nil（防 legLabel 下标越界）
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

    /// 左滑删除交通段（航班/火车/巴士/渡轮/租车）：按 segmentID 找其所属天后删整段。
    private func deleteTransport(_ segmentID: UUID) {
        guard let day = days.first(where: { ($0.segments ?? []).contains { $0.id == segmentID } }) else { return }
        store.removeTransportSegment(tripId: tripId, dayId: day.id, segmentId: segmentID)
    }

    /// 左滑删除住宿：按 stayID 删整段（住宿归 TripBundle、不绑单天）。
    private func deleteLodging(_ stayID: UUID) {
        store.removeLodgingStay(tripId: tripId, stayId: stayID)
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

// MARK: - TimelineRail

/// 时间轴主脊的 rail 列：地点 / 交通 / 租车行共用，保证连线几何完全一致、无缝相接成一条连续竖脊。
/// 固定行高 46、圆点 28、上下半线各 9pt；首项清上半线、末项清下半线，使整条脊连续而两端干净。
/// 与相邻 `ItineraryLegConnector`（地点间距离段）的竖线首尾相接。
private struct TimelineRail: View {
    let icon: String
    let dayColor: Color
    let showTopLine: Bool
    let showBottomLine: Bool

    static let width: CGFloat = 30
    static let spacing: CGFloat = 12
    static let rowHeight: CGFloat = 46
    private let circleSize: CGFloat = 28
    private var halfLine: CGFloat { (Self.rowHeight - circleSize) / 2 }
    private var railColor: Color { dayColor.opacity(0.25) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(showTopLine ? railColor : Color.clear).frame(width: 1.5, height: halfLine)
            ZStack {
                Circle().fill(Color(uiColor: .systemBackground))   // 垫底压住穿过的竖线
                Circle().fill(dayColor.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dayColor)
            }
            .frame(width: circleSize, height: circleSize)
            Rectangle().fill(showBottomLine ? railColor : Color.clear).frame(width: 1.5, height: halfLine)
        }
        .frame(width: Self.width)
    }
}

// MARK: - TransportTimelineRow

/// 交通段（边）行：rail 列放 mode 图标，详情列放班次 + 起讫站/时间。航班/火车是「边」（一段移动、两端两时刻），
/// 用内联 `A 8:00 → B 10:15` route 表达——不右对齐单一时间。与地点行共用 TimelineRail，主脊连续穿过；
/// 交通段本身即连接，不显距离 leg。spec: itinerary-car-rental.md（增补：时间轴统一）。
private struct TransportTimelineRow: View {
    let segment: TransportSegment
    let dayColor: Color
    var showTopLine: Bool = true
    var showBottomLine: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: TimelineRail.spacing) {
            TimelineRail(icon: segment.mode.symbolName, dayColor: dayColor,
                         showTopLine: showTopLine, showBottomLine: showBottomLine)
            VStack(alignment: .leading, spacing: 2) {
                // 主行：航班号/车次 · 承运方（左）——— 起降时刻区间（右），与地点/租车行同列右对齐，
                // 整条时间轴「标题 ——— 时间」读成一列。字体/字重逐段在 titleView 内设定（航班号 semibold、
                // 承运方 regular），故此处不再统一 .font。
                HStack(alignment: .center, spacing: 6) {
                    titleView
                        .lineLimit(1)
                    if let time = timeRangeText {
                        Spacer(minLength: 6)
                        time
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                // 次行：起讫站 + 航站楼，纯「在哪」——时间已上移主行、跨天 +N 随到达时刻。
                if let route = routeText {
                    route
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TimelineRail.rowHeight)
    }

    /// 主行：航班号/车次领衔（旅客主要认它），承运方降浅色次要；无班次号（租车）只显公司，都空退化 mode 名。
    private var titleView: Text {
        // 班次号（航班号/车次）与地点标题同级、同字号（.body）——航班/火车是和地点平级的时间轴事件，
        // 班次号作锚不该更小。承运方是次要归属信息，降一档到 .subheadline，靠「字号 + 字重 + 灰色」
        // 三重退后，与班次号拉开真正的两级层级（对标 Flighty / Apple Wallet：航班号大、航司名小一档且灰）。
        let leadFont = Font.system(.body, design: .rounded)
        let carrierFont = Font.system(.subheadline, design: .rounded)
        let number = segment.number.trimmingCharacters(in: .whitespaces)
        // 航司名按界面语言显示：航班从航班号解析本地化航司名，非航班/未识别则用存的承运方原文。
        let carrier = segment.displayCarrier
        if number.isEmpty {
            // 无班次号（租车等）：承运方升为主锚，用班次号同款字号/字重，避免整行偏小。
            let main = carrier.isEmpty ? NSLocalizedString(segment.mode.localizationKey, comment: "") : carrier
            return Text(main).font(leadFont.weight(.semibold)).foregroundStyle(.primary)
        }
        // 班次号 semibold/primary 作锚；承运方 subheadline/regular/secondary 退后 → 一行两级清晰层次。
        let lead = Text(number).font(leadFont.weight(.semibold)).foregroundStyle(.primary)
        // 拼接 Text 默认按「文字基线」对齐——大小字底线齐平、小字视觉重心偏低（看着沉下去一点）。
        // 给小一档的承运方加正 baselineOffset 上移约半个 cap 高度差（17↔15pt），改成「视觉重心对齐」。
        return carrier.isEmpty ? lead
            : lead + Text(" · \(carrier)").font(carrierFont.weight(.regular)).foregroundStyle(.secondary).baselineOffset(0.7)
    }

    /// 「CKG T3 → XIY T5」，缺项自适应；航站楼紧跟代码（同属「在哪」）。时间已上移主行右侧、
    /// 跨天「+N」随到达时刻，故此处不再拼时间/上标。
    private var routeText: Text? {
        let from = endpointLabel(name: segment.fromName, code: segment.fromCode, terminal: segment.fromTerminal)
        let to = endpointLabel(name: segment.toName, code: segment.toCode, terminal: segment.toTerminal)
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        if f.isEmpty && t.isEmpty { return nil }
        return Text("\(f) → \(t)")
    }

    /// 起降时刻区间（主行右对齐，与地点行 `21:00–21:20` / 租车单时刻同列同款 caption·medium·secondary）：
    /// 两端皆有 → 「10:35–11:55」；仅一端有 → 该端单时刻；都无 → nil。跨天到达加右上小上标「+N」。
    private var timeRangeText: Text? {
        let dep = segment.departLocalMinutes
        let arr = segment.arriveLocalMinutes
        let hasDep = dep >= 0, hasArr = arr >= 0
        guard hasDep || hasArr else { return nil }
        let baseFont = Font.system(.caption, design: .rounded).weight(.medium)
        func clock(_ m: Int) -> Text { Text(timeLabel(dayMinutes: m)).font(baseFont) }
        let dayOffset = segment.arriveDayOrder - segment.departDayOrder
        // 跨天「+N」做成右上角小上标（更小字号 + 上移基线），与详情卡 / 原内联一致。
        let plus = dayOffset > 0
            ? Text("\u{2009}+\(dayOffset)").font(.system(size: 9, weight: .semibold, design: .rounded)).baselineOffset(4)
            : nil
        let core: Text
        if hasDep && hasArr {
            core = clock(dep) + Text("–").font(baseFont) + clock(arr)
        } else if hasArr {
            core = clock(arr)
        } else {
            core = clock(dep)
        }
        return plus.map { core + $0 } ?? core
    }

    /// 端点文字：机场代码/站名 + 航站楼（紧跟、同属「在哪」）。时间不在这里拼（见 timeRangeText）。
    private func endpointLabel(name: String, code: String, terminal: String) -> String {
        let place = !code.isEmpty ? code : name
        var parts: [String] = []
        if !place.isEmpty { parts.append(place) }
        let term = terminalDisplay(terminal)
        if !term.isEmpty { parts.append(term) }
        return parts.joined(separator: " ")
    }

    /// 航站楼显示：仅航班、数字开头加「T」（2→T2）；火车站台等字母开头原样。与详情卡 terminalDisplay 同款。
    private func terminalDisplay(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard segment.mode == .flight, let first = t.first, first.isNumber else { return t }
        return NSLocalizedString("itinerary.transport.field.terminal_prefix", comment: "") + t
    }
}

// MARK: - CarRentalEventRow

/// 租车事件行（取车 / 还车）：租车是「点」（某地某时刻的动作，单一时间）→ 与地点行同构：
/// 主行「取车/还车 · 公司」+ **时间右对齐**；次行只放地点（不再把时间塞进副行）。
/// 同一租车段在取车日、还车日各渲染一条，各显本端地点与时间；与地点行共用 TimelineRail，主脊连续穿过。
/// spec: itinerary-car-rental.md（增补：时间轴统一）。
private struct CarRentalEventRow: View {
    let segment: TransportSegment
    let pickup: Bool
    let dayColor: Color
    var showTopLine: Bool = true
    var showBottomLine: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: TimelineRail.spacing) {
            TimelineRail(icon: segment.mode.symbolName, dayColor: dayColor,
                         showTopLine: showTopLine, showBottomLine: showBottomLine)
            VStack(alignment: .leading, spacing: 2) {
                // 主行：动作 + 公司（左）——— 时间（右对齐），与地点行「名称 ——— 时间」一致。
                HStack(alignment: .center, spacing: 6) {
                    Text(titleText)
                        .font(.system(.body, design: .rounded).weight(.semibold))   // 与地点标题同字号（同级事件）
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let t = timeText {
                        Spacer(minLength: 6)
                        Text(t)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                // 次行：地点（取/还车本端）。
                if let loc = locationText {
                    Text(loc)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TimelineRail.rowHeight)
    }

    /// 「取车」/「还车」——复用编辑表单同款 key（取车 / 还车）。
    private var actionLabel: String {
        NSLocalizedString(pickup ? "itinerary.transport.section.pickup" : "itinerary.transport.section.dropoff", comment: "")
    }

    /// 主行：「取车 · 携程租车」；无公司名则只显动作。
    private var titleText: String {
        let company = segment.carrier.trimmingCharacters(in: .whitespaces)
        return company.isEmpty ? actionLabel : "\(actionLabel) · \(company)"
    }

    /// 右对齐时间（本端：取车=出发时刻 / 还车=到达时刻）。未设则不显。
    private var timeText: String? {
        let minutes = pickup ? segment.departLocalMinutes : segment.arriveLocalMinutes
        return minutes >= 0 ? timeLabel(dayMinutes: minutes) : nil
    }

    /// 次行地点（本端）。空则不显。
    private var locationText: String? {
        let name = (pickup ? segment.fromName : segment.toName).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

// MARK: - LodgingBannerRow

/// 住宿常驻条：床图标 + 名称 + 状态。spec 倾向「入住/退房显事件、中间天极轻灰条」：
/// - 入住日：实心床 + 「入住 · 名称」（+ 入住时间），最醒目；
/// - 退房日：「退房 · 名称」（+ 退房时间）；
/// - 过夜中间天：极轻灰条，仅床轮廓 + 名称 + 晚数，退到背景。
private struct LodgingBannerRow: View {
    let stay: LodgingStay
    let role: LodgingRole
    let dayColor: Color   // 接入按天分色：床图标染当天色，让住宿进入 Carry 日间色系
    let showTopLine: Bool
    let showBottomLine: Bool

    private var displayName: String {
        stay.name.isEmpty ? NSLocalizedString("itinerary.category.lodging", comment: "") : stay.name
    }
    /// 入住/退房=离散**事件**（实心床、medium，与交通/地点同分量）；
    /// 出发/过夜=基地**锚点**（空心床、regular，更退后——它是「这天从这儿开始/结束」的位置标，不是要办的事）。
    private var isEvent: Bool { role == .checkIn || role == .checkout }

    var body: some View {
        // 与地点/交通行共用 TimelineRail（同款圆点 + 上下半线）→ 主脊连续穿过住宿节点、几何一致。
        // 「退到背景」改靠：空心床（锚点）+ regular 字重 + 动词文案，不再靠去掉 marker（那会断脊）。
        HStack(alignment: .center, spacing: TimelineRail.spacing) {
            TimelineRail(icon: isEvent ? "bed.double.fill" : "bed.double",
                         dayColor: dayColor, showTopLine: showTopLine, showBottomLine: showBottomLine)
            // 两行结构镜像 TimelineStopRow（地点）：行 1 = 酒店名 + 右侧时间，行 2 = 角色（入住/退房/出发/返回）。
            // 让住宿在脊上读成与地点/交通同一种「两行行」，去掉原「角色·名」单行夹在两行之间的格格不入。
            // 角色放第 2 行而非地址：同一次入住最多出现 4 次（入住/每日出发·返回/退房），地址重复是噪音，
            // 角色才是各行唯一差异、也最有用。酒店名当锚（与地点名/航班号一致），长名独占一行不被前缀挤掉。
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text(displayName)
                        // 事件（入住/退房）semibold + 实心床；锚点（出发/返回）medium + 空心床，更退后。
                        .font(.system(.body, design: .rounded).weight(isEvent ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let trailing = trailingText {
                        Spacer(minLength: 6)
                        // 时间字段（入住/退房时刻）与地点/交通同色 secondary；非时间（晚数计数）退作 tertiary。
                        Text(trailing)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(trailingIsTime ? .secondary : .tertiary)
                            .fixedSize()
                    }
                }
                Text(roleLabel)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TimelineRail.rowHeight)
    }

    /// 角色标签（第 2 行）：入住/退房=事件词；出发/过夜=动词锚点（从…出发 / 回…过夜）。不含酒店名（名在第 1 行）。
    private var roleLabel: String {
        switch role {
        case .checkIn:   return NSLocalizedString("itinerary.lodging.event.checkin", comment: "")
        case .checkout:  return NSLocalizedString("itinerary.lodging.event.checkout", comment: "")
        case .depart:    return NSLocalizedString("itinerary.lodging.timeline.depart", comment: "")
        case .overnight: return NSLocalizedString("itinerary.lodging.timeline.overnight", comment: "")
        }
    }

    /// 入住=入住时间（有则）否则晚数；退房=退房时间（有则）；出发/过夜=无（位置锚点、不编时间）。
    private var trailingText: String? {
        switch role {
        case .checkIn:
            if stay.checkInMinutes >= 0 { return timeLabel(dayMinutes: stay.checkInMinutes) }
            return String.localizedStringWithFormat(NSLocalizedString("itinerary.lodging.nights_value", comment: ""), stay.nights)
        case .checkout:
            return stay.checkOutMinutes >= 0 ? timeLabel(dayMinutes: stay.checkOutMinutes) : nil
        case .depart, .overnight:
            return nil
        }
    }
    private var trailingIsTime: Bool {
        switch role {
        case .checkIn:  return stay.checkInMinutes >= 0
        case .checkout: return stay.checkOutMinutes >= 0
        default:        return false
        }
    }
}

// MARK: - CalendarEventRow

/// 只读日历事件叠加行（spec: itinerary-calendar-overlay.md）。视觉上和行程数据明确区分：
/// rail 列用事件所属日历颜色的细竖条（不挂 marker 圆）+ 浅灰文字 + 右侧时间——
/// 一眼读出「来自你的日历、不是你规划的行程」。
private struct CalendarEventRow: View {
    let event: CalendarOverlayEvent

    private let railWidth: CGFloat = 30
    private let railSpacing: CGFloat = 12

    var body: some View {
        HStack(spacing: railSpacing) {
            // 日历色细竖条（替代停靠点的 marker 圆）：标识来源、落在 rail 列、与上下图标同心对齐。
            // 定时事件按时序落在主脊它的位置，但脊在它处自然断开（外部叠加项、不接规划脊）。
            Capsule()
                .fill(event.tint)
                .frame(width: 3, height: 15)
                .frame(width: railWidth)
            Text(event.title.isEmpty ? NSLocalizedString("itinerary.calendar.untitled", comment: "") : event.title)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(timeText)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    /// 右侧时间：全天 →「全天」；定时 → 开始时间，若同日且有更晚的结束 → 「开始–结束」（对标航班/有起止的停靠点）。
    /// 跨午夜/跨天事件不拼范围（右侧窄列里「18:00–次日…」会误读），只显开始时间。
    private var timeText: String {
        if event.isAllDay { return NSLocalizedString("itinerary.calendar.all_day", comment: "") }
        let start = timeLabel(dayMinutes: event.startMinutes)
        let cal = Calendar.current
        guard event.endDate > event.startDate,
              cal.isDate(event.startDate, inSameDayAs: event.endDate) else { return start }
        let endMinutes = cal.component(.hour, from: event.endDate) * 60 + cal.component(.minute, from: event.endDate)
        return "\(start)–\(timeLabel(dayMinutes: endMinutes))"
    }
}

// MARK: - TimelineStopRow

/// 时间轴行：leading 序号圆点 + 连线；序号圆点**与停靠点名称对齐**。段间连线/距离已拆为
/// 独立的 `ItineraryLegConnector` 行夹在相邻停靠点之间（本行只含主行 + 可选备注）。
private struct TimelineStopRow: View {
    let stop: ItineraryStop
    /// 是否画上/下半连线（脊上首项清上半、末项清下半，使整条脊连续而两端干净）。
    var showTopLine: Bool = true
    var showBottomLine: Bool = true
    /// 当天配色（与地图针 / 路线同色，便于图文互相对照）。
    let dayColor: Color

    var body: some View {
        // cell 只含主行（名称/时间/地址）。备注【不在列表展示】——两行备注会让行高参差、破坏列表工整；
        // 列表只承载「这趟有哪些站、几点、在哪」，备注是详情级信息（点行 → 只读详情可看完整备注，含折叠长文）。
        // 段间连接段由独立的 ItineraryLegConnector 行承载；rail 圆点与内容同在固定行高正中、自然对齐。
        HStack(alignment: .center, spacing: TimelineRail.spacing) {
            TimelineRail(icon: stop.category.symbolName, dayColor: dayColor,
                         showTopLine: showTopLine, showBottomLine: showBottomLine)
            content
        }
        .frame(height: TimelineRail.rowHeight)
    }

    /// 时间标签：设了结束时间（stayMinutes>0）显示「开始–结束」，否则只显示开始。
    private var timeRangeLabel: String {
        let start = timeLabel(dayMinutes: stop.plannedStartMinutes)
        guard stop.stayMinutes > 0 else { return start }
        return "\(start)–\(timeLabel(dayMinutes: stop.plannedStartMinutes + stop.stayMinutes))"
    }

    private var content: some View {
        // 类别图标已移到 rail 圆点；此处只剩名称/地址 + 时间/无坐标标记。
        // 居中对齐：导航按钮(44pt)比名称块高，若顶对齐会把名称地址顶到上沿、与 rail 圆点(行中线)错位；
        // .center 让名称块与导航按钮都按行中线居中，名称块重新对齐圆点。
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // 名称与时间【同一行、右对齐】：地点=「什么」、时间=「何时」，互为一对，读成「地点 ——— 时间」
                // （对标日历/Flighty/Tripsy 的日程行）。用 .center 垂直居中：时间(caption)比名称(body)小，
                // 若共享基线(.firstTextBaseline)，小字视觉中心会落在名称中心之下、看着偏下；居中才对齐。
                HStack(alignment: .center, spacing: 6) {
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

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var zoomedPhoto: ZoomedPhoto?

    var body: some View {
        // 不套 NavigationStack：那会带来一条「无标题、只挂个 X」的空导航栏、白占顶部。改把关闭 X 内联进
        // 头部行（见 header），顶部由「名称 + X」填满（对标 Apple 地图地点卡），不再空旷。编辑在底部。
        DetailSheetScaffold {
            header
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if !stop.sortedPhotos.isEmpty { photoStrip }
                infoCard
                navModule
                costCard
                noteCard
                AttachmentDetailCard(attachments: stop.attachments ?? [])
            }
        } footer: {
            DetailActionFooter(onEdit: { editing = true }, onDelete: deleteStop)
        }
        // 编辑钻入到详情之上：保存后回到详情（@Model 可观察、详情自动反映新值），再下滑关。
        .sheet(isPresented: $editing) {
            StopEditView(tripId: tripId, stop: stop)
        }
        // 点缩略图放大看（存的是约 640px 缩略图；零授权不取系统原图）。
        .fullScreenCover(item: $zoomedPhoto) { z in
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(data: z.data) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { zoomedPhoto = nil }
        }
    }

    private struct ZoomedPhoto: Identifiable { let id = UUID(); let data: Data }

    /// 该停靠点导入的照片（横向缩略图条，点击放大）。照片回溯生成的地点才有。
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stop.sortedPhotos, id: \.id) { photo in
                    Button { zoomedPhoto = ZoomedPhoto(data: photo.thumbnailData) } label: {
                        Group {
                            if let image = UIImage(data: photo.thumbnailData) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Image(systemName: "photo").foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color(.tertiarySystemFill))
                            }
                        }
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // 底部动作（编辑 + 移除）已统一收到 `DetailActionFooter`（详见 ItineraryDetailRows）。

    private var header: some View {
        DetailSheetHeader(
            iconSystemName: stop.category.symbolName,
            iconTint: dayColor,
            title: stop.name,
            subtitle: stopScheduleSubtitle,
            onClose: { dismiss() }
        )
    }

    /// 头部副标题 =「行程时间」：日期 + 时间区间（如 `Sat, May 2 · 21:00–21:20`）。把「这一站排在何时」（schedule
    /// 属性）聚到头部，与卡内「地点信息」（地址/电话）分离——对标 Apple 地图/日历「标题 + 日期·时间」范式（north-star §9）。
    /// 无日期行程只显时间、无时间只显日期、都无则 nil。格式与交通端点/住宿/Day 头一致（单一口径）。
    private var stopScheduleSubtitle: String? {
        let datePart: String? = {
            guard let bundle = store.bundle(for: tripId), !bundle.isDateless,
                  let order = stop.day?.sortOrder else { return nil }
            let start = Calendar.current.startOfDay(for: bundle.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: order, to: start) ?? start
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }()
        let timePart: String? = stop.plannedStartMinutes >= 0 ? timeRangeLabel : nil
        let parts = [datePart, timePart].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func deleteStop() {
        if let dayId = stop.day?.id {
            store.removeItineraryStop(tripId: tripId, dayId: dayId, stopId: stop.id)
        }
        dismiss()
    }

    /// 信息分组卡：每行带标签、行间细分隔、有值才显（学 Tripsy 的高可读）。裸地点（无任何附加信息）→ 不显空卡。
    @ViewBuilder
    private var infoCard: some View {
        let rows = infoRowViews
        if !rows.isEmpty { DetailRowGroup(rows: rows) }
    }

    // 费用 / 备注 各自独立成卡、固定顺序（费用 → 备注 → 附件），与编辑页一致。
    @ViewBuilder
    private var costCard: some View {
        if stop.hasCost {
            DetailRowGroup(rows: [AnyView(LabeledDetailRow(icon: "creditcard", labelKey: "cost.field.total",
                                                           value: CurrencyCatalog.format(stop.costAmount, code: stop.costCurrencyCode)))])
        }
    }
    @ViewBuilder
    private var noteCard: some View {
        if !stop.note.isEmpty {
            DetailRowGroup(rows: [AnyView(NoteDetailRow(text: stop.note))])
        }
    }

    private var infoRowViews: [AnyView] {
        var rows: [AnyView] = []
        // 「行程时间」（日期 + 时间）已移到头部副标题（schedule 属性，见 stopScheduleSubtitle）；
        // 此卡只放**地点固有信息**：地址 + 电话——schedule 与 place-info 分离（B1，north-star §1/§9）。
        // 地址（去到这里要用的定位）排在费用之前——费用属财务、现场执行时不是首要信息。
        if stop.hasCoordinate && !stop.address.isEmpty {
            rows.append(AnyView(CopyableDetailRow(icon: "mappin.and.ellipse", labelKey: "itinerary.lodging.field.address", value: stop.address)))
        }
        // 电话紧随地址（同属「怎么找到/联系这里」）：点按直接拨号。
        if !stop.phone.isEmpty {
            rows.append(AnyView(CallableDetailRow(labelKey: "itinerary.transport.field.phone", phone: stop.phone)))
        }
        return rows
    }

    /// 路程 / 导航模块：导航到本地点 + 到下一站直线距离。无坐标 / 无导航 App 不显示。
    /// 复用 `DirectionsModule`（地点与住宿共用同一处导航逻辑）。
    @ViewBuilder
    private var navModule: some View {
        if let coord = stop.coordinate, !navApps.isEmpty {
            DirectionsModule(coordinate: coord, name: stop.name, navApps: navApps,
                             distanceToNext: distanceToNext, tint: dayColor)
        }
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
/// internal（非 private）：地点 / 住宿 / 交通详情页共用。
struct ExpandableText: View {
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
                .textSelection(.enabled)   // 长按可选取/复制备注任意片段（不加按钮、不与展开/收起冲突）
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
    @State private var hasTime: Bool      // 有时间（单一「开始时间」，与租车/交通同范式）
    @State private var startTime: Date
    @State private var showTimeSheet = false   // 时间弹层（chip+弹出，统一交通范式）
    @State private var showRelocate = false

    @State private var costAmountText: String
    @State private var costCurrencyCode: String
    @State private var phone: String
    @State private var attachmentRequest: AttachmentAddRequest?
    @State private var dayOrder: Int   // 这个地点在哪天（行程已有的天，可改）

    init(tripId: UUID, stop: ItineraryStop) {
        self.tripId = tripId
        self.stop = stop
        _name = State(initialValue: stop.name)
        _category = State(initialValue: stop.category)
        _note = State(initialValue: stop.note)
        _hasTime = State(initialValue: stop.plannedStartMinutes >= 0)
        let startMin = stop.plannedStartMinutes >= 0 ? stop.plannedStartMinutes : 9 * 60
        _startTime = State(initialValue: dateFromDayMinutes(startMin))
        _costAmountText = State(initialValue: stop.hasCost ? CurrencyCatalog.amountText(stop.costAmount) : "")
        _costCurrencyCode = State(initialValue: stop.costCurrencyCode)
        _phone = State(initialValue: stop.phone)
        _dayOrder = State(initialValue: stop.day?.sortOrder ?? 0)
    }

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var days: [ItineraryDay] { bundle?.safeItineraryDays ?? [] }

    private var costAmountValue: Double {
        CurrencyCatalog.parseAmount(costAmountText)
    }

    private var costCurrencyToSave: String {
        costAmountText.trimmingCharacters(in: .whitespaces).isEmpty
            ? ""
            : (costCurrencyCode.isEmpty ? CurrencyCatalog.homeCurrencyCode : costCurrencyCode.uppercased())
    }

    /// 行程天的可读标签（有日期 → 周几·月·日；无日期 → 「第 N 天」），与交通/住宿编辑页同口径。
    private func dayLabel(_ order: Int) -> String {
        if let bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: order, to: base) ?? base
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), order + 1)
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
                }

                // 「详情」段：类型 + 可选的「开始 + 结束」时间段（结束以 stayMinutes 存）。
                Section {
                    // 自定义 Menu 替代原生 Picker：菜单 Picker 的「收起选中值」由系统按自己的紧凑排版渲染、
                    // 无视选项里的自定义间距（故下拉松、收起挤，且 SwiftUI 不给改）。改用 Menu 后，收起值标签
                    // 由我们手搓 → 图标↔文字间距 100% 可控；下拉仍是系统菜单 Picker（用 Label、间距本就合适）。
                    // 类别 = LabeledContent + Menu（与航班 Cabin 同款结构）。标题「Type」放在 LabeledContent 的
                    // label（Menu 外）、值（图标+名+chevron）放 Menu 的 label——关键：标题**不能**塞进 Menu 的 label，
                    // 否则菜单展开瞬间 SwiftUI 会把它缩到不可见（已知 gotcha）；外置即不受影响。值用主色，不用 accent 蓝。
                    LabeledContent {
                        Menu {
                            // 只列地点类别，剔除航班/火车/租车/邮轮（交通段走「+」交通入口）。
                            Picker(selection: $category) {
                                ForEach(StopCategory.placeSelectableCases, id: \.self) { cat in
                                    Label(cat.titleKey, systemImage: cat.symbolName).tag(cat)
                                }
                            } label: { EmptyView() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: category.symbolName)
                                Text(category.titleKey)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.primary)
                        }
                    } label: {
                        Text("itinerary.add_stop.category")
                    }
                    // 日期 + 时间融合一行（统一租车 dateTimeChipsRow 范式）：标签「日期」左·日期chip+时间chip右。
                    // 多天行程日期 chip 可点选换天（= 把停靠点移到目标天、保留时刻）；时间为单一「开始时间」、可清除。
                    HStack(spacing: 8) {
                        Text("itinerary.transport.field.date")
                        Spacer()
                        if days.count > 1 {
                            Menu {
                                Picker(selection: $dayOrder) {
                                    ForEach(days, id: \.sortOrder) { d in
                                        Text(dayLabel(d.sortOrder)).tag(d.sortOrder)
                                    }
                                } label: { EmptyView() }
                            } label: {
                                FormChip(text: dayLabel(dayOrder))
                            }
                        } else {
                            FormChip(text: dayLabel(dayOrder))
                        }
                        Button { showTimeSheet = true } label: {
                            FormChip(text: hasTime ? itineraryTimeString(startTime)
                                                   : NSLocalizedString("itinerary.transport.field.time", comment: ""),
                                     filled: hasTime,
                                     monospacedDigits: hasTime)
                        }
                        .buttonStyle(.plain)
                    }
                    // 电话不在编辑态露出：它是搜索地点时从 map 自动回填的辅助信息（没人会手敲地点电话），
                    // 详情页只读展示即可。phone 仍由搜索/换地点自动捕获、保存时原样带上（见 onRelocated / Save）。
                } header: {
                    Text("itinerary.stop.edit.details_header")
                }

                // 固定顺序：费用 → 备注 → 附件，各自独立 Section。
                Section {
                    CostInputRow(amountText: $costAmountText, currencyCode: $costCurrencyCode)
                }
                Section {
                    // 前导图标（详情 NoteDetailRow 同款 note.text）：与 Total cost / Attachments 统一为带图标的功能卡。
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "note.text")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        TextField(text: $note, axis: .vertical) { Text("itinerary.stop.edit.note") }
                            .lineLimit(1...4)   // 与航班/租车/住宿统一（最少 1 行，空态不撑高）
                    }
                }
                // 地点恒为既有实体（新地点经 AddStopView 搜索添加），owner 始终有 → 直接入库，无需缓冲。
                AttachmentEditSection(
                    owner: .stop(stop.id),
                    existing: stop.attachments ?? [],
                    pending: .constant([]),
                    tripId: tripId,
                    request: $attachmentRequest)
                // 删除不在编辑态露出：详情弹层「···」菜单已有删除（干净，详情自身 dismiss）；编辑态放删除既冗余、
                // 又因详情/编辑叠层在编辑里删后露出悬空详情。
            }
            .attachmentAddFlow(tripId: tripId, owner: .stop(stop.id), pending: .constant([]), request: $attachmentRequest)
            .navigationTitle(Text("itinerary.stop.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let startMin = dayMinutes(from: startTime)
                        store.updateItineraryStop(
                            tripId: tripId,
                            stopId: stop.id,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            category: category,
                            plannedStartMinutes: hasTime ? startMin : -1,
                            stayMinutes: 0,   // 地点只记开始时间；结束时间留待将来有需求再加（stayMinutes 模型字段保留）
                            note: note,
                            phone: phone
                        )
                        store.setStopCost(tripId: tripId, stopId: stop.id,
                                          amount: costAmountValue, currencyCode: costCurrencyToSave)
                        // 改了日期 → 把停靠点移到目标天（时刻按当天分钟存、自然保留）。
                        if dayOrder != (stop.day?.sortOrder ?? 0) {
                            store.moveItineraryStop(tripId: tripId, stopId: stop.id, toDayOrder: dayOrder)
                        }
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
                    // relocate 整体换地点：名称 + 电话都从更新后的 model 刷新，避免保存时用旧值覆盖。
                    onRelocated: { newName in name = newName; phone = stop.phone }
                )
            }
            // 时间弹层（chip+弹出，统一交通范式）；挂在 Form 稳定祖先上。
            .sheet(isPresented: $showTimeSheet) {
                ItineraryTimePickerSheet(hasTime: $hasTime, time: $startTime)
            }
        }
    }
}
