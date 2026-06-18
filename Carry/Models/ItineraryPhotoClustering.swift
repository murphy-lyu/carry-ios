//
//  ItineraryPhotoClustering.swift
//  Carry
//
//  照片回溯行程的聚类内核（spec: photo-trip-reconstruction.md §聚类算法）。
//
//  纯函数、值类型进出、不碰 SwiftData / UI——便于单测与离线验证聚类质量。
//  输入：已转坐标系（境内 GCJ-02）、已剔除无 GPS、已按行程日期区间过滤的照片点。
//  输出：[Day → [Place(质心, 起止时间, 成员照片)]]，天与天内地点皆按时间升序。
//
//  「待整理」抽屉的喂料（无 GPS / 截图 / 日期越界）发生在本函数**上游**——
//  那些照片根本不进入这里的输入；本内核只负责把合法地理点攒成时间轴。
//

import Foundation
import CoreLocation

// MARK: - 输入

/// 一张参与聚类的照片点（已转坐标系、已在日期区间内）。
nonisolated struct PhotoPoint: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D

    init(id: UUID = UUID(), timestamp: Date, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.timestamp = timestamp
        self.coordinate = coordinate
    }

    static func == (lhs: PhotoPoint, rhs: PhotoPoint) -> Bool {
        lhs.id == rhs.id
            && lhs.timestamp == rhs.timestamp
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

// MARK: - 阈值配置

/// 聚类阈值。预览页给「松 / 中 / 紧」三档，用户可一键切换重算。
nonisolated struct PhotoClusterConfig: Equatable {
    /// 地点半径：多近算「同一个地方」。
    var placeRadius: CLLocationDistance
    /// 折返时窗：短暂走开多久内算没离开（大景区里逛动几百米不被切碎）。
    var returnWindow: TimeInterval
    /// 凌晨切点（小时）：该点之前的照片归前一天（夜生活/凌晨看日出不被劈成两天）。
    var dayCutoffHour: Int
    /// 区域半径（预留第二层「景区→地点」折叠，本版不实现）。
    var areaRadius: CLLocationDistance

    static let medium = PhotoClusterConfig(placeRadius: 200, returnWindow: 15 * 60, dayCutoffHour: 4, areaRadius: 3_000)
    static let loose  = PhotoClusterConfig(placeRadius: 400, returnWindow: 25 * 60, dayCutoffHour: 4, areaRadius: 5_000)
    static let tight  = PhotoClusterConfig(placeRadius: 120, returnWindow: 8 * 60,  dayCutoffHour: 4, areaRadius: 2_000)
}

// MARK: - 输出

/// 一个地点簇：一段时间内停留在同一处的若干照片。
nonisolated struct PlaceCluster: Identifiable, Equatable {
    let id: UUID
    /// 成员照片的几何质心（平均经纬度，城市尺度足够）。
    var centroid: CLLocationCoordinate2D
    var firstTime: Date
    var lastTime: Date
    /// 成员照片在原始输入数组中的下标（按时间升序）。
    var photoIndices: [Int]

    init(id: UUID = UUID(), centroid: CLLocationCoordinate2D, firstTime: Date, lastTime: Date, photoIndices: [Int]) {
        self.id = id
        self.centroid = centroid
        self.firstTime = firstTime
        self.lastTime = lastTime
        self.photoIndices = photoIndices
    }

    var photoCount: Int { photoIndices.count }

    static func == (lhs: PlaceCluster, rhs: PlaceCluster) -> Bool {
        lhs.id == rhs.id && lhs.photoIndices == rhs.photoIndices
    }
}

/// 一天：按时间升序的若干地点。
nonisolated struct DayCluster: Equatable {
    /// 第几天，0-based，对齐 ItineraryDay.sortOrder。
    var dayOrder: Int
    var places: [PlaceCluster]
}

// MARK: - 聚类内核

nonisolated enum ItineraryPhotoClustering {

    /// 把照片点聚成 [Day → [Place]]。
    ///
    /// - Parameters:
    ///   - points: 合法地理点（已转坐标系、已在区间内、已剔除无 GPS）。无需预排序。
    ///   - departureDay: 行程出发日（取其 startOfDay 作为 dayOrder 基线）。
    ///   - config: 阈值档位。
    ///   - calendar: 用于分天的日历（含时区）。默认 .current。
    static func clusters(
        from points: [PhotoPoint],
        departureDay: Date,
        config: PhotoClusterConfig = .medium,
        calendar: Calendar = .current
    ) -> [DayCluster] {
        guard !points.isEmpty else { return [] }

        // 1. 按时间升序，保留「原始下标」供输出引用。
        let ordered = points.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }

        // 2. 按「逻辑日」（应用凌晨 cutoff）分天，dayOrder 相对出发日。
        let baseline = calendar.startOfDay(for: departureDay)
        var dayBuckets: [Int: [(index: Int, point: PhotoPoint)]] = [:]
        var dayOrderSequence: [Int] = []   // 保持首次出现顺序
        for entry in ordered {
            let logical = logicalDay(for: entry.element.timestamp, cutoffHour: config.dayCutoffHour, calendar: calendar)
            let order = calendar.dateComponents([.day], from: baseline, to: logical).day ?? 0
            if dayBuckets[order] == nil {
                dayBuckets[order] = []
                dayOrderSequence.append(order)
            }
            dayBuckets[order]?.append((entry.offset, entry.element))
        }

        // 3. 每天内做地点切分；天与天内地点皆已按时间升序（因 ordered 全局有序）。
        var result: [DayCluster] = []
        for order in dayOrderSequence.sorted() {
            guard let bucket = dayBuckets[order], !bucket.isEmpty else { continue }
            let places = segmentPlaces(in: bucket, config: config)
            result.append(DayCluster(dayOrder: order, places: places))
        }
        return result
    }

    // MARK: 分天

    /// 应用凌晨 cutoff 后该照片归属的「逻辑日」（当天 startOfDay）。
    /// 例：cutoff=4 时，凌晨 03:00 的照片减 4h 落到前一天 → 归前一天。
    static func logicalDay(for date: Date, cutoffHour: Int, calendar: Calendar) -> Date {
        let shifted = date.addingTimeInterval(-Double(cutoffHour) * 3600)
        return calendar.startOfDay(for: shifted)
    }

    // MARK: 地点切分（时空一起判）

    /// 在一天的时间有序点序列里切分地点。
    ///
    /// 沿时间轴走，维护「当前地点」成员与质心：
    /// - 距质心 ≤ R → 并入。
    /// - 距质心 > R 但在 returnWindow 内又折返到质心附近 → 视为地点内走动，并入。
    /// - 距质心 > R 且持续远离（超出 returnWindow 未折返）→ 关闭当前地点，缓冲的远离点开新地点。
    private static func segmentPlaces(
        in bucket: [(index: Int, point: PhotoPoint)],
        config: PhotoClusterConfig
    ) -> [PlaceCluster] {
        var places: [PlaceCluster] = []

        var current: [(index: Int, point: PhotoPoint)] = []
        var away: [(index: Int, point: PhotoPoint)] = []   // 暂离质心、尚未判定的点
        var awayStart: Date?                                // 暂离起始时间（判 returnWindow 用）

        func centroid(of members: [(index: Int, point: PhotoPoint)]) -> CLLocationCoordinate2D {
            let n = Double(members.count)
            let lat = members.reduce(0.0) { $0 + $1.point.coordinate.latitude } / n
            let lon = members.reduce(0.0) { $0 + $1.point.coordinate.longitude } / n
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        func flushCurrent() {
            guard !current.isEmpty else { return }
            let c = centroid(of: current)
            let times = current.map(\.point.timestamp)
            places.append(PlaceCluster(
                centroid: c,
                firstTime: times.min() ?? current[0].point.timestamp,
                lastTime: times.max() ?? current[0].point.timestamp,
                photoIndices: current.map(\.index)
            ))
            current.removeAll()
        }

        for entry in bucket {
            if current.isEmpty {
                current = [entry]
                away.removeAll(); awayStart = nil
                continue
            }
            let c = centroid(of: current)
            let d = distance(c, entry.point.coordinate)

            if d <= config.placeRadius {
                // 回到质心附近：把暂离的点当作「地点内走动」一并吸收。
                if !away.isEmpty { current.append(contentsOf: away); away.removeAll(); awayStart = nil }
                current.append(entry)
            } else {
                // 超出半径。
                if away.isEmpty { awayStart = entry.point.timestamp }
                if let start = awayStart, entry.point.timestamp.timeIntervalSince(start) <= config.returnWindow {
                    // 仍在折返时窗内，暂存观望。
                    away.append(entry)
                } else {
                    // 超窗未折返：当前地点收尾，缓冲的远离点 + 当前点开新地点。
                    flushCurrent()
                    current = away + [entry]
                    away.removeAll(); awayStart = nil
                }
            }
        }

        // 收尾：仍在观望的暂离点若没等到折返，自成一个新地点。
        if away.isEmpty {
            flushCurrent()
        } else {
            flushCurrent()
            let c = centroid(of: away)
            let times = away.map(\.point.timestamp)
            places.append(PlaceCluster(
                centroid: c,
                firstTime: times.min() ?? away[0].point.timestamp,
                lastTime: times.max() ?? away[0].point.timestamp,
                photoIndices: away.map(\.index)
            ))
        }
        return places
    }

    // MARK: 距离

    /// 两坐标间大圆距离（米）。
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
