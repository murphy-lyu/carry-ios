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
            .navigationTitle(Text("itinerary.optimize.title"))
            .navigationBarTitleDisplayMode(.inline)
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

    /// 异步算两条顺序的真实道路距离；任一失败保留 Haversine 展示。
    private func loadRoadDistances() async {
        guard let result, result.isImprovement else { return }
        roadLoading = true
        defer { roadLoading = false }
        let byId = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let originalCoords = stops.filter { $0.hasCoordinate }.compactMap(\.coordinate)
        let optimizedCoords = result.orderedStopIDs.compactMap { byId[$0]?.coordinate }
        let original = await RouteDistanceService.shared.totalRoadDistance(coordinates: originalCoords)
        let optimized = await RouteDistanceService.shared.totalRoadDistance(coordinates: optimizedCoords)
        if let original, let optimized {
            roadOriginal = original
            roadOptimized = optimized
        } else {
            CarryLogger.shared.log(.itineraryRouteCalcFailed)
        }
    }

    // 展示用距离：有道路数据用道路，否则回退 Haversine。
    private var displayOriginal: Double { roadOriginal ?? (result?.originalDistanceMeters ?? 0) }
    private var displayOptimized: Double { roadOptimized ?? (result?.optimizedDistanceMeters ?? 0) }
    private var displaySaved: Double { max(0, displayOriginal - displayOptimized) }
    private var usingRoad: Bool { roadOriginal != nil && roadOptimized != nil }

    // MARK: Improvement

    private func improvementContent(_ result: RouteOptimizer.Result) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dayTitle)
                                .font(.headline.weight(.semibold))
                            Text("itinerary.optimize.title")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("itinerary.optimize.preview_subtitle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(distanceString(displaySaved))
                                .font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(CarryAccent.color)
                            Text("itinerary.optimize.saved_short")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    routeMap
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    distanceBar

                    distanceCaption

                    VStack(alignment: .leading, spacing: 10) {
                        Text("itinerary.optimize.new_order")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(optimizedStops.enumerated()), id: \.element.id) { index, stop in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(CarryAccent.color)
                                    .frame(width: 24, height: 24)
                                    .background(CarryAccent.color.opacity(0.10), in: Circle())
                                Image(systemName: stop.category.symbolName)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stop.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    if stop.plannedStartMinutes >= 0 {
                                        Text(timeLabel(dayMinutes: stop.plannedStartMinutes))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(.top, 2)

                    // 让用户理解为何首尾不动（方案 A：固定首尾、只优化中间）。
                    Label("itinerary.optimize.endpoints_fixed", systemImage: "pin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(UIColor.systemBackground).opacity(0.72))
                )
                .padding(.horizontal, 16)

                actionRow(result)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .padding(.top, 12)
        }
        .background(CarrySubtleBackground())
    }

    private var distanceBar: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("itinerary.optimize.current")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(distanceString(displayOriginal))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("itinerary.optimize.optimized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(distanceString(displayOptimized))
                        .font(.headline)
                        .foregroundStyle(CarryAccent.color)
                }
                Spacer()
                if displaySaved > 0 {
                    Text(String(format: NSLocalizedString("itinerary.optimize.saved", comment: ""),
                                distanceString(displaySaved)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CarryAccent.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(CarryAccent.color.opacity(0.12), in: Capsule())
                }
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func actionRow(_ result: RouteOptimizer.Result) -> some View {
        HStack(spacing: 12) {
            Button {
                discard()
            } label: {
                Text("common.cancel")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.bordered)
            .tint(CarryAccent.color)

            Button {
                apply(result)
            } label: {
                Text("itinerary.optimize.apply")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(CarryAccent.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressableScaleButtonStyle(scale: 0.97, pressedBrightness: -0.03, pressedOpacity: 0.96))
        }
    }

    // MARK: Already optimal

    private var alreadyOptimal: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(CarryAccent.color)
            Text("itinerary.optimize.optimal.title")
                .font(.headline)
            Text("itinerary.optimize.optimal.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("common.done") { discard() }
                .buttonStyle(.bordered)
                .tint(CarryAccent.color)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CarrySubtleBackground())
    }

    // MARK: Map

    @ViewBuilder
    private var routeMap: some View {
        let coords = optimizedStops.compactMap(\.coordinate)
        Map(initialPosition: .region(region(for: coords))) {
            ForEach(Array(optimizedStops.enumerated()), id: \.element.id) { index, stop in
                if let coord = stop.coordinate {
                    Marker("\(index + 1)", coordinate: coord)
                        .tint(CarryAccent.color)
                }
            }
            MapPolyline(coordinates: coords)
                .stroke(CarryAccent.color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
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
