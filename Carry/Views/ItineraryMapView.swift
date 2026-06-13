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

    /// 按天聚合的地图数据。编号按天重置、颜色按天区分，与列表完全对应。
    private var dayMapData: [DayMapData] {
        displayDays.map { day in
            let coordStops = day.sortedStops.filter { $0.hasCoordinate }
            return DayMapData(
                id: day.id,
                color: ItineraryDayPalette.color(forDayIndex: day.sortOrder),
                stops: coordStops.enumerated().map { (localIndex: $0.offset, stop: $0.element) },
                routeCoords: coordStops.compactMap(\.coordinate)
            )
        }
    }

    /// 所有有坐标的停靠点（用于阈值判断 + 计算可视区域）。
    private var coordinateStops: [ItineraryStop] {
        displayDays.flatMap { $0.sortedStops }.filter { $0.hasCoordinate }
    }

    private var scopeLabel: String? {
        guard let day = displayDays.first else { return nil }
        let trimmed = day.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(format: NSLocalizedString("itinerary.day.title", comment: ""), day.sortOrder + 1) : trimmed
    }

    private var coordinateCount: Int { coordinateStops.count }

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
                mapContent
                    .allowsHitTesting(false)   // 预览不抢地图手势；点整块进全屏交互
                    .overlay(alignment: .topLeading) {
                        if let scopeLabel {
                            Text(scopeLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                                .padding(10)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                            .padding(8)
                            .foregroundStyle(CarryAccent.color)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("itinerary.empty.map.subtitle")
                .font(.footnote)
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
    }

    // MARK: Full screen

    private var fullScreenMap: some View {
        NavigationStack {
            mapContent
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text("itinerary.map.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SheetCloseButton { showFullScreen = false }
                    }
                }
        }
    }

    // MARK: Shared map content

    @ViewBuilder
    private var mapContent: some View {
        Map(initialPosition: .region(fittedRegion)) {
            // 按天编号（当天内 1、2、3…）+ 按天着色，与列表一一对应。
            // 自定义圆形针（当天色实心圆 + 白序号 + 白描边 + 阴影），与列表序号圆点同语言、
            // 比原生气泡针更干净、更品牌化；序号是与列表交叉对照的锚点。
            ForEach(dayMapData) { day in
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
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
    }

    /// 包住所有坐标点的可视区域（带 padding）；单点时给固定小 span。
    private var fittedRegion: MKCoordinateRegion {
        let coords = coordinateStops.compactMap(\.coordinate)
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
