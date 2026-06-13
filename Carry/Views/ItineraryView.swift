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
    case editStop(ItineraryStop)
    case optimize(dayId: UUID)

    var id: String {
        switch self {
        case .addStop(let dayId): return "add-\(dayId)"
        case .editStop(let stop): return "edit-\(stop.id)"
        case .optimize(let dayId): return "opt-\(dayId)"
        }
    }
}

// MARK: - ItineraryView

struct ItineraryView: View {
    let tripId: UUID

    @EnvironmentObject var store: TripStore

    @State private var activeSheet: ItinerarySheet?
    @State private var focusedDayId: UUID?

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
            case .editStop(let stop):
                StopEditView(tripId: tripId, stop: stop)
            case .optimize(let dayId):
                OptimizeRouteView(tripId: tripId, dayId: dayId)
            }
        }
        .toolbarBackground(Color(UIColor.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            store.syncItineraryDays(tripId: tripId)   // 兜底：天对齐到行程天数（存量行程/新建首开）
            syncFocusedDaySelectionIfNeeded()
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
                stopContent: { AnyView(stopRow($0)) },
                addStopContent: { AnyView(addStopRow($0)) },
                optimizeContent: { AnyView(optimizeRow($0)) },
                headerContent: { AnyView(dayHeaderRow($0)) },
                onDelete: { deleteStop($0) },
                onEdit: { editStop($0) },
                onArrange: { store.applyItineraryArrangement(tripId: tripId, dayOrders: $0) },
                onReorderBegan: { }
            )
            // Day header 依赖行程级日期态（isDateless / departureDate）算标签，而这状态不在
            // collection 的 diffable 快照里 → section id 不变时旧 header 不会重配（转有/无日期后
            // 旧天仍显示「第 N 天」）。日期态变化时用 .id 强制重建 collection 一次刷新所有 header；
            // 日常加减地点不改此 key、不触发重建。
            .id(itineraryDateStateKey)
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

    /// 每天的结构快照（供 collection diffable）。
    private var daySections: [ItineraryDaySection] {
        days.map { day in
            ItineraryDaySection(
                id: day.id,
                stopIDs: day.sortedStops.map(\.id),
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
            TimelineStopRow(
                stop: stop,
                index: index,
                isLast: index == dayStops.count - 1,
                legFromPrevious: legLabel(stops: dayStops, index: index),
                dayColor: ItineraryDayPalette.color(forDayIndex: day.sortOrder)
            )
            .padding(.horizontal, 16)
            // 不再「点击整行=编辑」；编辑改由向左滑动出现的「编辑」按钮触发（见 onEdit）。
        }
    }

    private func addStopRow(_ dayID: UUID) -> some View {
        // 次级内联动作用 secondary 灰，与打包「添加物品」一致（避免每组一行 accent 蓝、喧宾夺主）。
        Button { activeSheet = .addStop(dayId: dayID) } label: {
            inlineActionLabel(titleKey: "itinerary.add_stop", icon: "plus")
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
    /// 与 `TimelineStopRow` 结构对齐（rail 宽 26 + spacing 12），整天「停靠点 + 动作」读成一列左对齐。
    private func inlineActionLabel(titleKey: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 12) {                       // = TimelineStopRow.railSpacing
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26)                   // = TimelineStopRow.railWidth，图标居中落在圆点列
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
        HStack(spacing: 8) {
            Circle()
                .fill(ItineraryDayPalette.color(forDayIndex: day.sortOrder))
                .frame(width: 7, height: 7)
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
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.03))
                .frame(height: 1)
        }
        .background(
            Rectangle()
                .fill(Color(UIColor.systemBackground))
        )
        // 与 Packing 的 sectionTitle 一样，把 header 变成稳定的 section surface，
        // 避免吸顶时直接露出下面的渐变/透明层，造成“分块感”。
        .offset(y: -1)
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


    // MARK: Mutations

    /// 滑动删除（collection 的 swipe action）。
    private func deleteStop(_ stopID: UUID) {
        guard let day = days.first(where: { ($0.stops ?? []).contains { $0.id == stopID } }) else { return }
        store.removeItineraryStop(tripId: tripId, dayId: day.id, stopId: stopID)
    }

    /// 滑动编辑（collection 的 swipe action）：找到停靠点并唤起编辑 sheet。
    private func editStop(_ stopID: UUID) {
        guard let stop = days.flatMap({ $0.stops ?? [] }).first(where: { $0.id == stopID }) else { return }
        activeSheet = .editStop(stop)
    }
}

// MARK: - TimelineStopRow

/// 时间轴行：leading 序号圆点 + 连线；序号圆点**与停靠点名称对齐**；段间直线距离落在
/// 名称上方的「间隙」里（压在连线上），不与名称/地址抢同一行。
private struct TimelineStopRow: View {
    let stop: ItineraryStop
    let index: Int
    let isLast: Bool
    /// 与上一点的距离标签（首点为 nil）。
    let legFromPrevious: String?
    /// 当天配色（与地图针 / 路线同色，便于图文互相对照）。
    let dayColor: Color

    private var railColor: Color { dayColor.opacity(0.25) }
    private let railWidth: CGFloat = 26
    private let circleSize: CGFloat = 24
    private let railSpacing: CGFloat = 12
    /// 固定行高——rail 连线与行间距由此完全确定，全程无 `maxHeight: .infinity` 贪婪 frame，
    /// 故自适应 cell 不会被撑高、各行（含首/末行）几何严格一致。
    private let rowHeight: CGFloat = 46
    /// 相邻停靠点之间的固定竖向间距；距离标签压在其正中。
    private let legGap: CGFloat = 24
    /// 圆点上/下连线的固定半段长度（圆点在固定行高里垂直居中）。
    private var halfLine: CGFloat { (rowHeight - circleSize) / 2 }

    var body: some View {
        VStack(spacing: 0) {
            // 连接段：有上一点时画竖线 + 居中距离标签；首点画等高透明占位。
            // 关键：首点也保留 legGap 高度，使每个 stop cell 恒为 legGap+rowHeight。
            // 否则首点 cell（仅 rowHeight）比其余矮，UICollectionView 自适应列表会因
            // 估算高度错配在其前后插入间距（实测每处约 14pt），导致首点间距偏大。
            if index > 0 {
                legSegment
            } else {
                Color.clear.frame(height: legGap)
            }
            // 停靠点主行：固定行高 + 居中对齐；rail 圆点与内容同在行中心，自然对齐。
            HStack(alignment: .center, spacing: railSpacing) {
                rail
                content
            }
            .frame(height: rowHeight)
        }
    }

    /// 两个停靠点之间的连接段：竖线 + 居中的距离标签。
    private var legSegment: some View {
        ZStack {
            Rectangle().fill(railColor).frame(width: 1.5)
            if let legFromPrevious {
                Text(legFromPrevious)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(Color(uiColor: .systemBackground))
                    .fixedSize()
            }
        }
        .frame(width: railWidth, height: legGap)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.system(size: 11, weight: .semibold))
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
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))   // 名称加粗 + 圆体，作为每行的视觉锚
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !stop.address.isEmpty {
                    Text(stop.address)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if stop.plannedStartMinutes >= 0 {
                // 已设时间：重排锚点。pin 图标 + 时间，传达「优化时不会动」。
                HStack(spacing: 3) {
                    Image(systemName: "pin.fill").font(.system(size: 9))
                    Text(timeLabel(dayMinutes: stop.plannedStartMinutes))
                        .font(.system(.caption, design: .rounded).weight(.medium))
                }
                .foregroundStyle(.secondary)
            }
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
    @State private var time: Date

    init(tripId: UUID, stop: ItineraryStop) {
        self.tripId = tripId
        self.stop = stop
        _name = State(initialValue: stop.name)
        _category = State(initialValue: stop.category)
        _note = State(initialValue: stop.note)
        _hasTime = State(initialValue: stop.plannedStartMinutes >= 0)
        _time = State(initialValue: dateFromDayMinutes(stop.plannedStartMinutes >= 0 ? stop.plannedStartMinutes : 9 * 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) { Text("itinerary.stop.edit.name") }
                    Picker(selection: $category) {
                        ForEach(StopCategory.allCases, id: \.self) { cat in
                            Label(cat.titleKey, systemImage: cat.symbolName).tag(cat)
                        }
                    } label: {
                        Text("itinerary.add_stop.category")
                    }
                }
                Section {
                    Toggle(isOn: $hasTime) { Text("itinerary.stop.edit.set_time") }
                        .tint(CarryAccent.color)
                    if hasTime {
                        DatePicker(selection: $time, displayedComponents: .hourAndMinute) {
                            Text("itinerary.stop.edit.time")
                        }
                    }
                } footer: {
                    // 提示设了时间的停靠点在「优化顺序」时会被钉住。
                    if hasTime {
                        Text("itinerary.stop.edit.time_footer")
                    }
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
                        store.updateItineraryStop(
                            tripId: tripId,
                            stopId: stop.id,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            category: category,
                            plannedStartMinutes: hasTime ? dayMinutes(from: time) : -1,
                            note: note
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}
