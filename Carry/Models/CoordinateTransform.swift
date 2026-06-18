//
//  CoordinateTransform.swift
//  Carry
//
//  WGS-84 ⇄ GCJ-02 坐标转换（spec: photo-trip-reconstruction.md）。
//
//  为什么需要：照片 EXIF 的 GPS 是 WGS-84 原始值；而项目内坐标在大陆 storefront
//  下统一存 GCJ-02（Apple/高德直传，见 MapNavigationService）。若把 EXIF 坐标
//  原样写库，境内照片会在地图上整体偏移几百米、反向地理编码也会编到隔壁街区。
//
//  本文件只做**纯几何**转换，不感知 storefront——是否应用转换由调用方按
//  `isChinaStorefront`（SceneItemMap.swift）决定：仅大陆 storefront + 坐标落在
//  中国境内时才转，其余保持 WGS-84 原值。设计为 nonisolated，可在 async Task
//  中自由调用、并可独立单测已知坐标对。
//

import Foundation
import CoreLocation

nonisolated enum CoordinateTransform {

    // 克拉索夫斯基椭球参数（GCJ-02 偏移算法所用，业界标准常量）。
    private static let a = 6_378_245.0                  // 长半轴
    private static let ee = 0.006_693_421_622_965_943   // 偏心率平方

    /// 坐标是否落在中国大致包络框外。框外不做偏移（GCJ-02 仅覆盖中国境内）。
    static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        if longitude < 72.004 || longitude > 137.8347 { return true }
        if latitude < 0.8293 || latitude > 55.8271 { return true }
        return false
    }

    /// WGS-84 → GCJ-02。境外坐标原样返回。
    static func wgs84ToGcj02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !isOutOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }
        var dLat = transformLat(x: longitude - 105.0, y: latitude - 35.0)
        var dLon = transformLon(x: longitude - 105.0, y: latitude - 35.0)
        let radLat = latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (latitude + dLat, longitude + dLon)
    }

    /// CLLocationCoordinate2D 便捷重载。
    static func wgs84ToGcj02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let r = wgs84ToGcj02(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)
    }

    // MARK: - 偏移多项式（业界标准 eviltransform 实现）

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
