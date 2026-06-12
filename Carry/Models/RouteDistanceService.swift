//
//  RouteDistanceService.swift
//  Carry
//
//  真实道路距离（spec: itinerary-route-planning.md, Phase 4）。
//  仅用于「优化预览」的展示数字——把 Haversine 直线距离换成 MKDirections 实际驾车距离。
//  排序本身仍用 Haversine（即时、离线可用）；本服务异步、可失败，失败即回退直线。
//
//  防 MKDirections 速率限制：请求**串行**发出（actor 天然序列化 + for 循环逐段 await），
//  并按「起点→终点」坐标键做**会话级缓存**，避免拖动/重复计算时重复请求。
//

import Foundation
import MapKit

actor RouteDistanceService {
    static let shared = RouteDistanceService()
    private init() {}

    /// 会话内分段距离缓存（米），键为四舍五入后的 from→to 坐标。
    private var cache: [String: Double] = [:]

    /// 有序坐标的总驾车距离（米）。任一段失败（离线/无路线/限流）→ 返回 nil，调用方回退 Haversine。
    func totalRoadDistance(coordinates: [CLLocationCoordinate2D]) async -> Double? {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for k in 0..<(coordinates.count - 1) {
            guard let segment = await segmentDistance(from: coordinates[k], to: coordinates[k + 1]) else {
                return nil
            }
            total += segment
        }
        return total
    }

    private func segmentDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> Double? {
        let key = "\(round5(from.latitude)),\(round5(from.longitude))->\(round5(to.latitude)),\(round5(to.longitude))"
        if let cached = cache[key] { return cached }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile

        do {
            // calculateETA 比 calculate 轻量（不返回完整 polyline），只取距离/耗时即可。
            let response = try await MKDirections(request: request).calculateETA()
            cache[key] = response.distance
            return response.distance
        } catch {
            return nil
        }
    }

    private func round5(_ x: Double) -> Double { (x * 1e5).rounded() / 1e5 }
}
