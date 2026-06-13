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
    @State private var renameDayTarget: ItineraryDay?
    @State private var renameDayText: String = ""

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var days: [ItineraryDay] { bundle?.safeItineraryDays ?? [] }
    private var totalStops: Int { days.reduce(0) { $0 + ($1.stops?.count ?? 0) } }

    var body: some View {
        Group {
            if days.isEmpty {
                emptyState
            } else {
                dayList
            }
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
        .alert(Text("itinerary.day.rename.title"), isPresented: renameDayPresented) {
            TextField(text: $renameDayText) { Text("itinerary.day.rename.placeholder") }
            Button("common.cancel", role: .cancel) { renameDayTarget = nil }
            Button("Save") {
                if let day = renameDayTarget {
                    store.updateItineraryDay(tripId: tripId, dayId: day.id, title: renameDayText)
                }
                renameDayTarget = nil
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("itinerary.empty.title")
                .font(.headline)
            Text("itinerary.empty.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                store.addItineraryDay(tripId: tripId)
            } label: {
                Label("itinerary.empty.add_first_day", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(CarryAccent.color)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Day list

    private var dayList: some View {
        VStack(spacing: 0) {
            ItineraryMapView(tripId: tripId)
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
            addDayButton
        }
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
        Button { activeSheet = .addStop(dayId: dayID) } label: {
            Label("itinerary.add_stop", systemImage: "plus").font(.subheadline)
        }
        .tint(CarryAccent.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        // 末个停靠点的连线在其自身行内终止（无底部留白），动作行用顶部留白与之分隔。
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func optimizeRow(_ dayID: UUID) -> some View {
        Button { activeSheet = .optimize(dayId: dayID) } label: {
            Label("itinerary.optimize.button", systemImage: "wand.and.stars").font(.subheadline)
        }
        .tint(CarryAccent.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func dayHeaderRow(_ section: ItineraryDaySection) -> some View {
        if let day = days.first(where: { $0.id == section.id }) {
            dayHeader(day)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                // 首个停靠点 cell 顶部已有 legGap(24) 透明占位充当表头→首点的间距，
                // 故表头底部只留少量呼吸，避免与透明 leg 叠加导致间距过大。
                .padding(.bottom, 2)
                .background(Rectangle().fill(Color(UIColor.systemBackground)))
        }
    }

    private var addDayButton: some View {
        Button { store.addItineraryDay(tripId: tripId) } label: {
            Label("itinerary.add_day", systemImage: "calendar.badge.plus").font(.subheadline)
        }
        .tint(CarryAccent.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func dayHeader(_ day: ItineraryDay) -> some View {
        HStack(spacing: 8) {
            // 当天色点：与该天的地图针 / 路线 / 时间轴节点同色，作为图例。
            Circle()
                .fill(ItineraryDayPalette.color(forDayIndex: day.sortOrder))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle(day))
                if let date = dayDateLabel(day) {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button {
                    renameDayText = day.title
                    renameDayTarget = day
                } label: {
                    Label("itinerary.day.menu.rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    store.removeItineraryDay(tripId: tripId, dayId: day.id)
                } label: {
                    Label("itinerary.day.menu.delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 自定义标题优先；否则「Day N」（N = sortOrder + 1，对 isDateless 同样成立）。
    private func dayTitle(_ day: ItineraryDay) -> String {
        let trimmed = day.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
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

    private var renameDayPresented: Binding<Bool> {
        Binding(get: { renameDayTarget != nil }, set: { if !$0 { renameDayTarget = nil } })
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
                    .font(.system(size: 9, weight: .medium))
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
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stop.category.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(dayColor)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !stop.address.isEmpty {
                    Text(stop.address)
                        .font(.caption)
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
                        .font(.caption.weight(.medium))
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
