//
//  RouteOptimizer.swift
//  Carry
//
//  单日智能重排（spec: itinerary-route-planning.md, Phase 3–4）。
//  给定当天「有坐标」的停靠点，给出总移动更省的访问顺序——纯本地、可解释、毫秒级。
//  方法：最近邻构造 + 2-opt 局部优化；距离用 Haversine 直线距离做排序代理
//  （真实道路距离仅用于「预览展示」，见 RouteDistanceService）。
//
//  锚点：首尾两个停靠点固定不动（往返日两端是酒店/机场，单程日末尾通常是机场）；
//  中间所有地点无论是否设了时间，均参与路径优化。
//

import Foundation
import CoreLocation

enum RouteOptimizer {

    struct Result {
        /// 优化后的访问顺序（仅含有坐标的停靠点 id）。
        let orderedStopIDs: [UUID]
        let originalDistanceMeters: Double
        let optimizedDistanceMeters: Double

        /// 优化是否带来可感知的缩短（直线口径）。
        var isImprovement: Bool {
            RouteOptimizer.isImprovement(original: originalDistanceMeters, optimized: optimizedDistanceMeters)
        }

        var savedMeters: Double { max(0, originalDistanceMeters - optimizedDistanceMeters) }
    }

    /// 是否带来可感知的缩短：省 >1% 且 >50m，避免把噪声当成改进。
    /// 直线（排序口径）与道路（展示/判定口径）共用同一阈值，保证两口径一致。
    static func isImprovement(original: Double, optimized: Double) -> Bool {
        guard original > 0 else { return false }
        let saved = original - optimized
        return saved > 50 && saved / original > 0.01
    }

    /// 当天有坐标停靠点 ≥ 3 才有意义（2 个点无可重排）。返回 nil 表示不适用。
    static func optimize(stops: [ItineraryStop]) -> Result? {
        let coordStops = stops.filter { $0.hasCoordinate }
        guard coordStops.count >= 3 else { return nil }

        let ids = coordStops.map(\.id)
        let coords = coordStops.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        // 锚点 = 首 ∪ 尾 ∪ 设了时间的停靠点（方案 A：固定首尾、只优化中间）。
        // 往返日「酒店→…→酒店」把酒店放在首尾即两端钉死；单程日末尾点（如机场）也不被挪走。
        let anchors: Set<Int> = [0, coordStops.count - 1]

        let original = pathDistance(Array(coords.indices), coords)
        let route = optimizeWithAnchors(coords: coords, anchors: anchors)
        let optimized = pathDistance(route, coords)

        return Result(
            orderedStopIDs: route.map { ids[$0] },
            originalDistanceMeters: original,
            optimizedDistanceMeters: optimized
        )
    }

    // MARK: - Distance

    /// 两坐标间的大圆距离（米）。
    static func haversineMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// 开放路径（不闭环）按给定索引顺序的总距离。
    private static func pathDistance(_ order: [Int], _ coords: [CLLocationCoordinate2D]) -> Double {
        guard order.count >= 2 else { return 0 }
        var total = 0.0
        for k in 0..<(order.count - 1) {
            total += haversineMeters(coords[order[k]], coords[order[k + 1]])
        }
        return total
    }

    // MARK: - Anchored optimization

    /// 锚点固定在原位；每段连续的非锚点用「端点固定」的 NN+2-opt 重排。
    private static func optimizeWithAnchors(coords: [CLLocationCoordinate2D], anchors: Set<Int>) -> [Int] {
        let n = coords.count
        var result = Array(0..<n)   // 恒等起点；锚点天然保持原位
        var i = 0
        while i < n {
            if anchors.contains(i) { i += 1; continue }
            // 找到一段连续的自由位置 [i, j)
            var j = i
            while j < n && !anchors.contains(j) { j += 1 }
            let members = Array(i..<j)            // 该段的索引值（与位置同值，因起点为恒等）
            let left = i - 1                       // 左端锚点位置（i≥1，因位置0必为锚点）
            let right = (j < n) ? j : nil          // 右端锚点位置（段在末尾则无）
            let ordered = orderSegment(members: members, left: left >= 0 ? left : nil, right: right, coords: coords)
            for (offset, value) in ordered.enumerated() { result[i + offset] = value }
            i = j
        }
        return result
    }

    /// 在两端坐标固定的前提下，重排 members 使 [left]→members→[right] 总距离最小。
    private static func orderSegment(members: [Int], left: Int?, right: Int?, coords: [CLLocationCoordinate2D]) -> [Int] {
        guard members.count > 1 else { return members }

        func augmentedDistance(_ order: [Int]) -> Double {
            var full: [Int] = []
            if let left { full.append(left) }
            full.append(contentsOf: order)
            if let right { full.append(right) }
            return pathDistance(full, coords)
        }

        // 最近邻：从左锚点（若有）出发，否则从段内首个点。
        var remaining = members
        var route: [Int] = []
        var current: CLLocationCoordinate2D
        if let left {
            current = coords[left]
        } else {
            let first = remaining.removeFirst()
            route.append(first)
            current = coords[first]
        }
        while !remaining.isEmpty {
            let next = remaining.min {
                haversineMeters(current, coords[$0]) < haversineMeters(current, coords[$1])
            }!
            route.append(next)
            remaining.removeAll { $0 == next }
            current = coords[next]
        }

        // 2-opt：只反转段内子区间，目标是含固定端点的增广路径最短。
        var improved = true
        while improved {
            improved = false
            for a in 0..<route.count {
                for b in (a + 1)..<route.count {
                    var candidate = route
                    candidate[a...b].reverse()
                    if augmentedDistance(candidate) + 1e-6 < augmentedDistance(route) {
                        route = candidate
                        improved = true
                    }
                }
            }
        }
        return route
    }
}
