//
//  MapNavigationService.swift
//  Carry
//
//  调起第三方导航 App 做「当前位置 → 停靠点」驾车导航。
//  iOS 无系统级导航选择器，故自建：探测已安装 App → 各家 deep link 调起。
//  坐标来自 Apple MKLocalSearch（国内 GCJ-02 / 境外 WGS-84）：Apple/高德直传、百度需转 BD-09。
//  spec: specs/itinerary-stop-navigation.md
//

import Foundation
import UIKit
import MapKit
import CoreLocation

/// 支持的导航 App。`allCases` 顺序即菜单顺序（百度按产品要求置末位）。
enum MapNavigationApp: String, CaseIterable, Identifiable {
    case apple
    case amap
    case google
    case baidu

    var id: String { rawValue }

    /// 本地化显示名的 key（在视图层包成 `LocalizedStringKey`，本文件不依赖 SwiftUI）。
    var nameKey: String {
        switch self {
        case .apple:  return "itinerary.nav.app.apple"
        case .amap:   return "itinerary.nav.app.amap"
        case .google: return "itinerary.nav.app.google"
        case .baidu:  return "itinerary.nav.app.baidu"
        }
    }

    /// 探测用 scheme；Apple 地图永远可用（`nil` = 无需探测）。
    private var probeURL: URL? {
        switch self {
        case .apple:  return nil
        case .amap:   return URL(string: "iosamap://")
        case .google: return URL(string: "comgooglemaps://")
        case .baidu:  return URL(string: "baidumap://")
        }
    }

    @MainActor
    var isInstalled: Bool {
        guard let probeURL else { return true }   // Apple 地图
        return UIApplication.shared.canOpenURL(probeURL)
    }

    /// 该 App 是否支持此交通方式。仅 **Apple 地图不支持骑行**（其 deep link / 启动选项无骑行项；
    /// MKDirections 亦无 cycling）——选骑行时 Apple 地图从可用列表过滤掉，其余地图照常。
    /// 公交（transit）四家 deep-link 文档上均支持（Apple `MKLaunchOptionsDirectionsModeTransit`、
    /// 高德 t=1、Google transit、百度 transit），故暂不过滤；待真机实测后若某家不灵再在此精修。
    func supports(_ mode: MapNavigationMode) -> Bool {
        switch (self, mode) {
        case (.apple, .cycling): return false
        default: return true
        }
    }
}

/// 导航交通方式（驾车 / 公交 / 步行 / 骑行）。默认驾车。`allCases` 顺序即选择器顺序。
enum MapNavigationMode: String, CaseIterable, Identifiable {
    case driving
    case transit
    case walking
    case cycling

    var id: String { rawValue }

    /// 本地化显示名 key（视图层包成 `LocalizedStringKey`；本文件不依赖 SwiftUI）。
    var nameKey: String {
        switch self {
        case .driving: return "itinerary.nav.mode.driving"
        case .transit: return "itinerary.nav.mode.transit"
        case .cycling: return "itinerary.nav.mode.cycling"
        case .walking: return "itinerary.nav.mode.walking"
        }
    }

    var symbolName: String {
        switch self {
        case .driving: return "car.fill"
        case .transit: return "bus.fill"
        case .cycling: return "bicycle"
        case .walking: return "figure.walk"
        }
    }
}

@MainActor
enum MapNavigationService {

    /// 设备上已安装的导航 App（按 `MapNavigationApp.allCases` 顺序，Apple 永远在列）。
    static func availableApps() -> [MapNavigationApp] {
        MapNavigationApp.allCases.filter { $0.isInstalled }
    }

    /// 已安装且支持指定交通方式的导航 App（骑行时 Apple 地图被过滤）。
    static func availableApps(for mode: MapNavigationMode) -> [MapNavigationApp] {
        availableApps().filter { $0.supports(mode) }
    }

    /// 调起指定 App、用指定交通方式导航至坐标（起点 = 各 App 自身当前定位）。
    /// 骑行不应传入 `.apple`（上层已按 `supports` 过滤）；若误传，Apple 退化为驾车。
    static func open(_ app: MapNavigationApp, coordinate: CLLocationCoordinate2D, name: String, mode: MapNavigationMode) {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch app {
        case .apple:
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = name
            // Apple 有驾车/步行/公交，无骑行（骑行已被过滤，保险起见退化驾车）。
            let appleMode: String
            switch mode {
            case .walking: appleMode = MKLaunchOptionsDirectionsModeWalking
            case .transit: appleMode = MKLaunchOptionsDirectionsModeTransit
            default:       appleMode = MKLaunchOptionsDirectionsModeDriving
            }
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: appleMode])
        case .amap:
            // dev=0：坐标已是高德系（GCJ-02），不二次纠偏。t：驾车 0 / 公交 1 / 步行 2 / 骑行 3。起点留空 = 当前位置。
            let t: Int
            switch mode {
            case .driving: t = 0
            case .transit: t = 1
            case .walking: t = 2
            case .cycling: t = 3
            }
            open("iosamap://path?sourceApplication=Carry&dlat=\(coordinate.latitude)&dlon=\(coordinate.longitude)&dname=\(encodedName)&dev=0&t=\(t)")
        case .google:
            let gm: String
            switch mode {
            case .driving: gm = "driving"
            case .transit: gm = "transit"
            case .walking: gm = "walking"
            case .cycling: gm = "bicycling"
            }
            open("comgooglemaps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&directionsmode=\(gm)")
        case .baidu:
            // 百度用 BD-09，需从 GCJ-02 转换；coord_type=bd09ll 告知百度坐标已是 BD-09。mode：driving/transit/walking/riding。
            let bd = gcj02ToBd09(coordinate)
            let bm: String
            switch mode {
            case .driving: bm = "driving"
            case .transit: bm = "transit"
            case .walking: bm = "walking"
            case .cycling: bm = "riding"
            }
            open("baidumap://map/direction?destination=latlng:\(bd.latitude),\(bd.longitude)|name:\(encodedName)&mode=\(bm)&coord_type=bd09ll&src=com.murphy.carry")
        }
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }

    /// GCJ-02 → BD-09（百度坐标系）。公开标准算法。
    nonisolated private static func gcj02ToBd09(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let xPi = Double.pi * 3000.0 / 180.0
        let x = c.longitude
        let y = c.latitude
        let z = (x * x + y * y).squareRoot() + 0.00002 * sin(y * xPi)
        let theta = atan2(y, x) + 0.000003 * cos(x * xPi)
        return CLLocationCoordinate2D(latitude: z * sin(theta) + 0.006,
                                      longitude: z * cos(theta) + 0.0065)
    }
}
