//
//  ItineraryMapView.swift
//  Carry
//
//  行程地图区（spec: itinerary-route-planning.md）：顶部常驻预览 + 可全屏。
//  按 category 标注有坐标的停靠点，按 (day, sortOrder) 顺序用直线连接每天的路线。
//
//  路线说明：当前为「直线连线」基线（spec 列为离线/降级形态的有效呈现）。
//  实际道路路径与逐段耗时（MKDirections）待「路线详情」UI 落地后再接入——
//  在没有展示耗时的界面前先建 RouteCalculator 会产生零调用的死代码，违反「定义即接线」。
//

import SwiftUI
import MapKit

struct ItineraryMapView: View {
    let tripId: UUID
    let focusedDayId: UUID?

    @EnvironmentObject var store: TripStore
    @State private var showFullScreen = false
    /// 全屏地图的按天筛选：nil = 全部天；非 nil = 只看某天。
    @State private var fullScreenScope: UUID?
    /// 全屏相机：切筛选时动画重新 fit 到对应范围。
    @State private var fullScreenCamera: MapCameraPosition = .automatic

    private var bundle: TripBundle? { store.bundle(for: tripId) }

    private var allDays: [ItineraryDay] { bundle?.safeItineraryDays ?? [] }
    private var displayDays: [ItineraryDay] {
        guard let focusedDayId else { return allDays }
        return allDays.filter { $0.id == focusedDayId }
    }

    /// 一天在地图上的绘制数据：颜色（按天）、按天编号的有坐标停靠点、连线坐标。
    private struct DayMapData: Identifiable {
        let id: UUID
        let color: Color
        /// 该天「有坐标」的停靠点，按当天顺序编号（localIndex 0-based）。
        let stops: [(localIndex: Int, stop: ItineraryStop)]
        /// 连线坐标（≥2 个点才成线）。
        let routeCoords: [CLLocationCoordinate2D]
    }

    /// 按天聚合的地图数据（指定天集合）。编号按天重置、颜色按天区分，与列表完全对应。
    /// 预览传聚焦的当天；全屏传 `allDays`——整趟一张按天分色的多彩图。
    private func dayMapData(for days: [ItineraryDay]) -> [DayMapData] {
        days.map { day in
            let coordStops = day.sortedStops.filter { $0.hasCoordinate }
            return DayMapData(
                id: day.id,
                color: ItineraryDayPalette.color(forDayIndex: day.sortOrder),
                stops: coordStops.enumerated().map { (localIndex: $0.offset, stop: $0.element) },
                routeCoords: coordStops.compactMap(\.coordinate)
            )
        }
    }

    /// 指定天集合里所有有坐标的停靠点（阈值判断 + 计算可视区域）。
    private func coordinateStops(in days: [ItineraryDay]) -> [ItineraryStop] {
        days.flatMap { $0.sortedStops }.filter { $0.hasCoordinate }
    }

    /// 预览态坐标点数（聚焦当天）——决定空态 / 单点提示。
    private var coordinateCount: Int { coordinateStops(in: displayDays).count }

    /// 整趟（所有天）有坐标的停靠点——当天为空时用于「上下文态」。
    private var tripCoordinateCount: Int { coordinateStops(in: allDays).count }

    /// 目的地 geocode 坐标（创建/编辑行程时解析，复用既有字段，无需新 geocode）。
    /// 0,0 = 未解析（无目的地 / geocode 失败 / 无日期占位），返回 nil。
    private var destinationRegion: MKCoordinateRegion? {
        guard let bundle, bundle.latitude != 0 || bundle.longitude != 0 else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: bundle.latitude, longitude: bundle.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)   // 城市/区域级，作目的地背景
        )
    }

    /// 预览三档：地图永不为空（north-star §1 内容为王 / §8 叙事 / §9 顺平台）。
    private enum PreviewMode {
        case route                            // 当天有地点 → 正常路线图
        case context                          // 当天空、但本趟别处有地点 → 整趟真地图（淡化），不谎称空白
        case destination(MKCoordinateRegion)  // 整趟空、目的地已解析 → 居中目的地，作出发邀请
        case placeholder                      // 兜底：整趟空且目的地未知（无日期/未解析）
    }
    private var previewMode: PreviewMode {
        if coordinateCount > 0 { return .route }
        if tripCoordinateCount > 0 { return .context }
        if let region = destinationRegion { return .destination(region) }
        return .placeholder
    }
    /// 可展开全屏的前提是有真实路线可看（route / context）。目的地背景与兜底态不展开。
    private var isExpandable: Bool {
        switch previewMode {
        case .route, .context: return true
        case .destination, .placeholder: return false
        }
    }

    var body: some View {
        mapPreview
            .frame(height: 200)   // 略加高：多点行程在 176 里偏挤，200 可读性更好
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .sheet(isPresented: $showFullScreen) {
                fullScreenMap
            }
    }

    // MARK: Preview

    @ViewBuilder
    private var mapPreview: some View {
        Group {
            switch previewMode {
            case .route:
                // 当天有地点：正常路线图。不画 scope 胶囊（「当前是哪天」与日历条选中态重复，north-star §1）。
                // 单点不再提示「再加一个就能连线」——针本身自解释、添加入口就在下方列表，提示属多余 hand-holding（§1）。
                mapContent(for: displayDays)
                    .allowsHitTesting(false)   // 预览不抢地图手势；点整块进全屏交互
                    .overlay(alignment: .topTrailing) { expandControl }

            case .context:
                // 当天空、整趟别处有地点：铺整趟真地图、其它天针淡化——给出地理上下文，不谎称整趟空白。
                mapContent(for: allDays, dimmed: true)
                    .allowsHitTesting(false)
                    .overlay(alignment: .topTrailing) { expandControl }
                    .overlay(alignment: .bottomLeading) {
                        mapHint("itinerary.empty.map.day_hint", systemImage: "calendar")
                    }

            case .destination(let region):
                // 整趟空、目的地已知：居中目的地作背景，配一句出发邀请（§8 叙事，替代灰盒）。
                destinationMap(region)
                    .allowsHitTesting(false)
                    .overlay(alignment: .bottomLeading) {
                        mapHint("itinerary.empty.map.invite", systemImage: "mappin.and.ellipse")
                    }

            case .placeholder:
                emptyMapState
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isExpandable { showFullScreen = true } }   // 有真实路线才可展开
    }

    /// 目的地背景图：以目的地坐标居中的安静地图，无针（坐标为区域质心、不指代具体地点）。
    private func destinationMap(_ region: MKCoordinateRegion) -> some View {
        Map(initialPosition: .region(region))
    }

    /// 「看大图」工具性 affordance，用中性色（对齐 Apple Maps 地图控件）。
    private var expandControl: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 13, weight: .semibold))
            .padding(8)
            .background(.regularMaterial, in: Circle())
            .padding(8)
            .foregroundStyle(.secondary)
    }

    /// 兜底空态（仅「整趟空且目的地未知」时出现，如无日期行程 / geocode 未完成）。
    private var emptyMapState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary.opacity(0.7))
            Text("itinerary.empty.map.title")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
            Text("itinerary.empty.map.subtitle")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(UIColor.secondarySystemBackground),
                    Color(UIColor.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// 地图上的浮层提示胶囊（material + 圆体）：单点提示 / 空当天 / 出发邀请共用。
    private func mapHint(_ key: LocalizedStringKey, systemImage: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(key)
                .font(.system(.caption, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }

    // MARK: Full screen

    /// 全屏按筛选显示的天集合：nil = 全部；否则只看选中那天。
    private var fullScreenDays: [ItineraryDay] {
        guard let id = fullScreenScope else { return allDays }
        return allDays.filter { $0.id == id }
    }

    /// 全屏 = 整趟所有天按天分色一次铺开（点「展开」= 看更全）；底部筛选条可切「全部 / 某天」，
    /// 切时动画重新 fit。多色针靠筛选条对应「色 → 天」。
    private var fullScreenMap: some View {
        NavigationStack {
            Map(position: $fullScreenCamera) {
                mapAnnotations(for: fullScreenDays)
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) { mapFilterBar }
            .navigationTitle(Text("itinerary.map.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { showFullScreen = false }
                }
            }
            .onAppear {
                fullScreenScope = nil                                   // 每次展开默认「全部」
                fullScreenCamera = .region(fittedRegion(for: allDays))
            }
            .onChange(of: fullScreenScope) { _, _ in
                withAnimation(.easeInOut(duration: 0.35)) {
                    fullScreenCamera = .region(fittedRegion(for: fullScreenDays))
                }
            }
        }
    }

    /// 全屏底部筛选条：有坐标停靠点的天 →「全部 + 各天」chip，点切筛选并重新 fit。
    /// 仅 ≥2 天有点时显示（单天无需筛选）。选中态 = 实心高亮，未选 = 常态。
    @ViewBuilder
    private var mapFilterBar: some View {
        let daysWithStops = allDays.filter { $0.sortedStops.contains { $0.hasCoordinate } }
        if daysWithStops.count >= 2 {
            // 宽度自适应：天少时胶囊贴合内容、靠 overlay(.bottom) 天然居中（不再拉满整宽留空）；
            // 天多到一行放不下时，ViewThatFits 退回整宽可滚。
            ViewThatFits(in: .horizontal) {
                filterChipsRow(daysWithStops)
                ScrollView(.horizontal, showsIndicators: false) {
                    filterChipsRow(daysWithStops)
                }
            }
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func filterChipsRow(_ days: [ItineraryDay]) -> some View {
        HStack(spacing: 6) {
            filterChip(label: Text("itinerary.map.all_days"),
                       dot: nil,
                       isSelected: fullScreenScope == nil) { fullScreenScope = nil }
            ForEach(days, id: \.id) { day in
                filterChip(label: Text(dayShortLabel(day)),
                           dot: ItineraryDayPalette.color(forDayIndex: day.sortOrder),
                           isSelected: fullScreenScope == day.id) { fullScreenScope = day.id }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    /// 筛选条单个 chip：可选当天色点 + 标签；选中实心高亮 + semibold。
    private func filterChip(label: Text, dot: Color?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8)
                }
                label
                    .font(.system(.caption, design: .rounded).weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(Color.primary.opacity(0.10))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 图例里的短日期标签：有日期行程「月/日」，无日期行程「Day N」（复用既有 key，无新增文案）。
    private func dayShortLabel(_ day: ItineraryDay) -> String {
        if let bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: day.sortOrder, to: base) ?? base
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), day.sortOrder + 1)
    }

    // MARK: Shared map content

    /// 预览态（静态相机）。全屏走 `Map(position:)` 单独装配（可动画切筛选）。
    @ViewBuilder
    private func mapContent(for days: [ItineraryDay], dimmed: Bool = false) -> some View {
        Map(initialPosition: .region(fittedRegion(for: days))) {
            mapAnnotations(for: days, dimmed: dimmed)
        }
    }

    /// 地图针 + 路线（按天编号、按天着色），预览与全屏共用。
    /// 自定义圆形针（当天色实心圆 + 白序号 + 白描边 + 阴影），与列表序号圆点同语言、比原生气泡针干净。
    /// `dimmed`：当天为空、把整趟作上下文淡化展示时为真（针/线退到背景，不抢当天的「空」）。
    @MapContentBuilder
    private func mapAnnotations(for days: [ItineraryDay], dimmed: Bool = false) -> some MapContent {
        ForEach(dayMapData(for: days)) { day in
            ForEach(day.stops, id: \.stop.id) { entry in
                Annotation(entry.stop.name, coordinate: entry.stop.coordinate!) {
                    stopMarker(index: entry.localIndex + 1, color: day.color, dimmed: dimmed)
                }
            }
            if day.routeCoords.count >= 2 {
                MapPolyline(coordinates: day.routeCoords)
                    .stroke(day.color.opacity(dimmed ? 0.3 : 1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        // 交通段（边）：起讫两端都有坐标才画**大圆弧虚线**（contourStyle: .geodesic），
        // 与市内步行/驾车的实线路程区分——一眼看出「这段是飞/跨城的」（spec: itinerary-transport-lodging.md）。
        ForEach(days, id: \.id) { day in
            ForEach(day.sortedSegments.filter { $0.hasRouteCoordinates }, id: \.id) { seg in
                MapPolyline(coordinates: [seg.fromCoordinate!, seg.toCoordinate!], contourStyle: .geodesic)
                    .stroke(ItineraryDayPalette.color(forDayIndex: day.sortOrder).opacity(dimmed ? 0.3 : 0.9),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))
            }
        }
    }

    /// 地图针标注内容（抽出以缓解 Map 闭包的类型检查负担）。
    private func stopMarker(index: Int, color: Color, dimmed: Bool = false) -> some View {
        ZStack {
            Circle().fill(color)
            Circle().strokeBorder(.white, lineWidth: 1.5)
            Text("\(index)")
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
        .opacity(dimmed ? 0.4 : 1)
    }

    /// 包住指定天集合所有坐标点的可视区域（带 padding）；单点时给固定小 span。
    private func fittedRegion(for days: [ItineraryDay]) -> MKCoordinateRegion {
        let coords = coordinateStops(in: days).compactMap(\.coordinate)
        guard let first = coords.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
            )
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.02),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.02)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
