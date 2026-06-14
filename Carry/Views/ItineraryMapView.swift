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

    private var mapPreview: some View {
        Group {
            if coordinateCount == 0 {
                emptyMapState
            } else {
                mapContent(for: displayDays)
                    .allowsHitTesting(false)   // 预览不抢地图手势；点整块进全屏交互
                    // 不再画 scope 胶囊：「当前是哪天」与正下方日历条的选中态重复（north-star §1）。
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                            .padding(8)
                            // 「看大图」是 chrome/工具性 affordance，用中性色（对齐 Apple Maps 地图控件）。
                            .foregroundStyle(.secondary)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if coordinateCount == 1 {
                            singleStopHint
                        }
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showFullScreen = true }   // 整块预览可点展开
    }

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

    private var singleStopHint: some View {
        Text("itinerary.single.map.hint")
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
    }

    // MARK: Full screen

    /// 全屏 = 整趟所有天，按天分色一次铺开（点「展开」的意图是看更全）。
    /// 多色针靠底部图例对应「色 → 天」，否则按天颜色无法解读。
    private var fullScreenMap: some View {
        NavigationStack {
            mapContent(for: allDays)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) { mapLegend(for: allDays) }
                .navigationTitle(Text("itinerary.map.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SheetCloseButton { showFullScreen = false }
                    }
                }
        }
    }

    /// 全屏地图底部图例：有坐标停靠点的天，按天色 + 短日期标注「色 → 天」。
    /// 仅 ≥2 天有点时显示（单天无需图例）。
    @ViewBuilder
    private func mapLegend(for days: [ItineraryDay]) -> some View {
        let daysWithStops = days.filter { $0.sortedStops.contains { $0.hasCoordinate } }
        if daysWithStops.count >= 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(daysWithStops, id: \.id) { day in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(ItineraryDayPalette.color(forDayIndex: day.sortOrder))
                                .frame(width: 8, height: 8)
                            Text(dayShortLabel(day))
                                .font(.system(.caption, design: .rounded).weight(.medium))
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
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

    @ViewBuilder
    private func mapContent(for days: [ItineraryDay]) -> some View {
        Map(initialPosition: .region(fittedRegion(for: days))) {
            // 按天编号（当天内 1、2、3…）+ 按天着色，与列表一一对应。
            // 自定义圆形针（当天色实心圆 + 白序号 + 白描边 + 阴影），与列表序号圆点同语言、
            // 比原生气泡针更干净、更品牌化；序号是与列表交叉对照的锚点。
            ForEach(dayMapData(for: days)) { day in
                ForEach(day.stops, id: \.stop.id) { entry in
                    Annotation(entry.stop.name, coordinate: entry.stop.coordinate!) {
                        stopMarker(index: entry.localIndex + 1, color: day.color)
                    }
                }
                if day.routeCoords.count >= 2 {
                    MapPolyline(coordinates: day.routeCoords)
                        .stroke(day.color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// 地图针标注内容（抽出以缓解 Map 闭包的类型检查负担）。
    private func stopMarker(index: Int, color: Color) -> some View {
        ZStack {
            Circle().fill(color)
            Circle().strokeBorder(.white, lineWidth: 1.5)
            Text("\(index)")
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
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
