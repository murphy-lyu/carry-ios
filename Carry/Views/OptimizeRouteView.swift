//
//  OptimizeRouteView.swift
//  Carry
//
//  单日智能重排预览（spec: itinerary-route-planning.md, Phase 3）。
//  两段式：先预览「新顺序 + 距离对比 + 新路线地图」，用户「采用」才写库；
//  「放弃」不动。已是近最短时只给只读提示，不提供采用。
//

import SwiftUI
import MapKit

struct OptimizeRouteView: View {
    let tripId: UUID
    let dayId: UUID

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var result: RouteOptimizer.Result?
    @State private var didCompute = false

    // 真实道路距离（米）；nil = 未算到/失败，则展示退回 Haversine。
    @State private var roadOriginal: Double?
    @State private var roadOptimized: Double?
    @State private var roadLoading = false

    private var day: ItineraryDay? {
        store.bundle(for: tripId)?.safeItineraryDays.first { $0.id == dayId }
    }
    private var stops: [ItineraryStop] { day?.sortedStops ?? [] }

    /// 按优化后顺序排列的停靠点（仅有坐标的）。
    private var optimizedStops: [ItineraryStop] {
        guard let result else { return [] }
        let byId = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return result.orderedStopIDs.compactMap { byId[$0] }
    }

    private var dayTitle: String {
        guard let day else { return NSLocalizedString("itinerary.scope.day_unknown", comment: "") }
        let trimmed = day.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(format: NSLocalizedString("itinerary.day.title", comment: ""), day.sortOrder + 1) : trimmed
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result, result.isImprovement {
                    improvementContent(result)
                } else {
                    alreadyOptimal
                }
            }
            // 背景铺满整屏（含底部钉条背后），与钉条渐隐同源——避免底部色带接缝。
            .background(CarrySubtleBackground().ignoresSafeArea())
            .navigationTitle(Text("itinerary.optimize.title"))
            .navigationBarTitleDisplayMode(.inline)
            // 导航栏「取消」常驻可见：长清单时底部按钮需滚到底才看得到，顶部需要一个随时可退出的入口
            // （下拉手势并非人人会想到）。这是 Apple 标准——可滚动长内容 + 底部提交时，导航栏 Cancel 作退出口。
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { discard() }
                }
            }
        }
        .task {
            guard !didCompute else { return }
            didCompute = true
            result = RouteOptimizer.optimize(stops: stops)
            CarryLogger.shared.log(.itineraryOptimizeShown)
            await loadRoadDistances()
        }
    }

    /// 异步算两条顺序的真实道路距离，与 6s 超时竞速；超时/失败则保持 nil → 退回直线判定与展示。
    /// 道路是「是否改进」的判定口径（在可得时），不再只是展示——见 spec: itinerary-optimize-road-gating。
    private func loadRoadDistances() async {
        guard let result, result.isImprovement else { return }
        roadLoading = true
        defer { roadLoading = false }
        let byId = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let originalCoords = stops.filter { $0.hasCoordinate }.compactMap(\.coordinate)
        let optimizedCoords = result.orderedStopIDs.compactMap { byId[$0]?.coordinate }

        let road: (Double, Double)? = await withTaskGroup(of: (Double, Double)?.self) { group in
            group.addTask {
                guard let o = await RouteDistanceService.shared.totalRoadDistance(coordinates: originalCoords),
                      let p = await RouteDistanceService.shared.totalRoadDistance(coordinates: optimizedCoords) else { return nil }
                return (o, p)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)   // 6s 超时哨兵
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let (o, p) = road {
            roadOriginal = o
            roadOptimized = p
        } else {
            CarryLogger.shared.log(.itineraryRouteCalcFailed)   // 超时/失败 → verdict 退回 .unavailable
        }
    }

    // 展示用距离：有道路数据用道路，否则回退 Haversine。
    private var displayOriginal: Double { roadOriginal ?? (result?.originalDistanceMeters ?? 0) }
    private var displayOptimized: Double { roadOptimized ?? (result?.optimizedDistanceMeters ?? 0) }
    private var displaySaved: Double { max(0, displayOriginal - displayOptimized) }
    private var usingRoad: Bool { roadOriginal != nil && roadOptimized != nil }

    /// 道路口径下的最终判定（方案 A 的"判定区"据此定调）。
    private enum RoadVerdict {
        case computing      // 道路正在算，未定调
        case improved       // 道路确认有省 → 显示节省 + 「采用」
        case notImproved    // 道路没省/更长 → 「已是较优」+ 「完成」
        case unavailable    // 离线/超时/失败 → 退回直线判定（带「按直线距离」注脚）
    }

    private var roadVerdict: RoadVerdict {
        if let o = roadOriginal, let p = roadOptimized {
            return RouteOptimizer.isImprovement(original: o, optimized: p) ? .improved : .notImproved
        }
        return roadLoading ? .computing : .unavailable
    }

    // MARK: Improvement

    private func improvementContent(_ result: RouteOptimizer.Result) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        // 正文头部以「第 N 天」（在优化哪天）为主行；不再重复「优化路线」——导航栏已承担该标题。
                        Text(dayTitle)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("itinerary.optimize.preview_subtitle")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        savedBadge
                    }
                }

                routeMap
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                verdictBlock

                VStack(alignment: .leading, spacing: 10) {
                    Text("itinerary.optimize.new_order")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    ForEach(Array(optimizedStops.enumerated()), id: \.element.id) { index, stop in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                                .foregroundStyle(CarryAccent.color)
                                .frame(width: 24, height: 24)
                                .background(CarryAccent.color.opacity(0.10), in: Circle())
                            Image(systemName: stop.category.symbolName)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stop.name)
                                    .font(.system(.subheadline, design: .rounded))
                                    .lineLimit(1)
                                if stop.plannedStartMinutes >= 0 {
                                    Text(timeLabel(dayMinutes: stop.plannedStartMinutes))
                                        .font(.system(.caption2, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.top, 2)

                // 让用户理解为何首尾不动（方案 A：固定首尾、只优化中间）。
                Label("itinerary.optimize.endpoints_fixed", systemImage: "pin")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        // 背景由 body 的 Group 统一铺（含本条背后），此处不再各自垫，避免与钉条不同源造成色带。
        // 主 CTA 钉底部常驻：长清单也无需滚到底即可采用（顶部「取消」同样常驻、随时可退）。
        .safeAreaInset(edge: .bottom) {
            actionBar(result)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                // 滚动内容在按钮上沿柔和淡出（全 App 统一，见 BottomBarScrim）；淡出到 baseColor
                // （= CarrySubtleBackground 渐变底端色）故与整屏背景无缝、无磨砂色带。
                // 2026-06-14 规范更新：底部栏由「一律实心」改为「上沿渐变淡出 + 实心兜底」。
                .bottomBarScrim(CarrySubtleBackground.baseColor)
        }
    }

    private var distanceBar: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("itinerary.optimize.current")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(distanceString(displayOriginal))
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .strikethrough()
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("itinerary.optimize.optimized")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(distanceString(displayOptimized))
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(CarryAccent.color)
                }
                Spacer()
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder
    private var distanceCaption: some View {
        HStack(spacing: 6) {
            if roadLoading {
                ProgressView().controlSize(.mini)
                Text("itinerary.optimize.calculating")
            } else if usingRoad {
                Image(systemName: "car.fill").font(.caption2)
                Text("itinerary.optimize.by_road")
            } else {
                Image(systemName: "ruler").font(.caption2)
                Text("itinerary.optimize.straight_line")
            }
            Spacer()
        }
        .font(.system(.caption2, design: .rounded))
        .foregroundStyle(.tertiary)
    }

    /// 顶部右上「节省 X」徽标：道路确认有省/退回直线→显示节省；计算中→spinner；已较优→不显示。
    @ViewBuilder
    private var savedBadge: some View {
        switch roadVerdict {
        case .improved, .unavailable:
            Text(distanceString(displaySaved))
                .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(CarryAccent.color)
            Text("itinerary.optimize.saved_short")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
        case .computing:
            ProgressView().controlSize(.small)
        case .notImproved:
            EmptyView()
        }
    }

    /// 判定区：计算中 / 道路对比 / 已较优，随 roadVerdict 定调。地图与建议顺序在区外、全程不跳变。
    @ViewBuilder
    private var verdictBlock: some View {
        switch roadVerdict {
        case .computing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("itinerary.optimize.calculating")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        case .improved, .unavailable:
            distanceBar
            distanceCaption
        case .notImproved:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(CarryAccent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("itinerary.optimize.optimal.title")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text("itinerary.optimize.optimal.subtitle")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    /// 底部常驻动作区：改进/退回直线=「采用」；计算中=禁用；已较优=中性「完成」（走 discard）。
    @ViewBuilder
    private func actionBar(_ result: RouteOptimizer.Result) -> some View {
        switch roadVerdict {
        case .improved, .unavailable:
            applyButton(result)
        case .computing:
            applyButton(result)
                .disabled(true)
                .opacity(0.5)
        case .notImproved:
            Button { discard() } label: {
                Text("common.done")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressableScaleButtonStyle(scale: 0.97, pressedBrightness: -0.03, pressedOpacity: 0.96))
        }
    }

    /// 全宽主 CTA（accent 实心）。离开走导航栏常驻「取消」，不在底部重复取消。
    private func applyButton(_ result: RouteOptimizer.Result) -> some View {
        Button {
            apply(result)
        } label: {
            Text("itinerary.optimize.apply")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(CarryAccent.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle(scale: 0.97, pressedBrightness: -0.03, pressedOpacity: 0.96))
    }

    // MARK: Already optimal

    private var alreadyOptimal: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(CarryAccent.color)
            Text("itinerary.optimize.optimal.title")
                .font(.system(.headline, design: .rounded))
            Text("itinerary.optimize.optimal.subtitle")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("common.done") { discard() }
                .buttonStyle(.bordered)
                .tint(CarryAccent.color)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Map

    @ViewBuilder
    private var routeMap: some View {
        let coords = optimizedStops.compactMap(\.coordinate)
        Map(initialPosition: .region(region(for: coords))) {
            // 自定义圆形序号针（accent 实心 + 白序号 + 白描边 + 阴影），与行程主图 stopMarker 同语言，
            // 不用系统 Marker 气泡（两张地图两套针不一致）。
            ForEach(Array(optimizedStops.enumerated()), id: \.element.id) { index, stop in
                if let coord = stop.coordinate {
                    Annotation(stop.name, coordinate: coord) {
                        optimizeMarker(index: index + 1)
                    }
                }
            }
            MapPolyline(coordinates: coords)
                .stroke(CarryAccent.color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }

    /// 圆形序号针：accent 实心 + 白序号 + 白描边 + 阴影。与 ItineraryMapView.stopMarker 同规格。
    private func optimizeMarker(index: Int) -> some View {
        ZStack {
            Circle().fill(CarryAccent.color)
            Circle().strokeBorder(.white, lineWidth: 1.5)
            Text("\(index)")
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
    }

    // MARK: Actions

    private func apply(_ result: RouteOptimizer.Result) {
        // 坐标点按优化顺序 + 无坐标点按原序追加末尾，构成完整新顺序。
        let nonCoord = stops.filter { !$0.hasCoordinate }.map(\.id)
        store.reorderItineraryStops(tripId: tripId, dayId: dayId, newOrder: result.orderedStopIDs + nonCoord)
        CarryLogger.shared.log(.itineraryOptimizeApplied, context: "saved_m=\(Int(result.savedMeters))")
        dismiss()
    }

    private func discard() {
        CarryLogger.shared.log(.itineraryOptimizeDiscarded)
        dismiss()
    }

    // MARK: Helpers

    private func distanceString(_ meters: Double) -> String {
        let fmt = MKDistanceFormatter()
        fmt.unitStyle = .abbreviated
        return fmt.string(fromDistance: meters)
    }

    private func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
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
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.02),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.02)
            )
        )
    }
}
