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

    @EnvironmentObject var store: TripStore
    @State private var showFullScreen = false

    private var bundle: TripBundle? { store.bundle(for: tripId) }

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
        (bundle?.safeItineraryDays ?? []).map { day in
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
        (bundle?.safeItineraryDays ?? []).flatMap { $0.sortedStops }.filter { $0.hasCoordinate }
    }

    var body: some View {
        // 只有 ≥2 个有坐标的停靠点（构成真实路线）才显示地图；否则不占垂直空间。
        if coordinateStops.count >= 2 {
            mapPreview
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .sheet(isPresented: $showFullScreen) {
                    fullScreenMap
                }
        }
    }

    // MARK: Preview

    private var mapPreview: some View {
        mapContent
            .allowsHitTesting(false)   // 预览不抢地图手势；点整块进全屏交互
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
                    .padding(8)
                    .foregroundStyle(CarryAccent.color)
            }
            .contentShape(Rectangle())
            .onTapGesture { showFullScreen = true }   // 整块预览可点展开
    }

    // MARK: Full screen

    private var fullScreenMap: some View {
        NavigationStack {
            mapContent
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text("itinerary.map.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") { showFullScreen = false }
                    }
                }
        }
    }

    // MARK: Shared map content

    @ViewBuilder
    private var mapContent: some View {
        Map(initialPosition: .region(fittedRegion)) {
            // 按天编号（当天内 1、2、3…）+ 按天着色，与列表一一对应。
            ForEach(dayMapData) { day in
                ForEach(day.stops, id: \.stop.id) { entry in
                    Marker(
                        "\(entry.localIndex + 1)",
                        systemImage: entry.stop.category.symbolName,
                        coordinate: entry.stop.coordinate!
                    )
                    .tint(day.color)
                }
                if day.routeCoords.count >= 2 {
                    MapPolyline(coordinates: day.routeCoords)
                        .stroke(day.color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
        }
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
