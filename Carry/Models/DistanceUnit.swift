//
//  DistanceUnit.swift
//  Carry
//
//  用户可选的距离单位偏好（自动 / 公里 / 英里）。
//  与 AppearanceMode 同范式：存 @AppStorage("distance_unit")，
//  「自动」交回 MKDistanceFormatter 的 locale 默认行为。
//

import MapKit
import SwiftUI

enum DistanceUnit: String, CaseIterable, Identifiable {
    case automatic   // 跟随设备地区（MKDistanceFormatter 默认 locale 行为）
    case kilometers
    case miles

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .automatic:  return "distance_unit.automatic"
        case .kilometers: return "distance_unit.kilometers"
        case .miles:      return "distance_unit.miles"
        }
    }

    /// 施加到 MKDistanceFormatter 的单位制；automatic → .default（交回 locale）。
    var formatterUnits: MKDistanceFormatter.Units {
        switch self {
        case .automatic:  return .default
        case .kilometers: return .metric
        case .miles:      return .imperial
        }
    }
}

/// 每个单位制一个固定的缓存 formatter（全局 `let`，建一次、不可变）。
/// `legLabel` 在 body 里每条 leg 调一次、列表滚动会反复触发，故不每次 new。
/// 每单位独立实例 → 无 `.units` 跨调用 mutation、无竞态，又免重复分配。
private func makeDistanceFormatter(_ units: MKDistanceFormatter.Units) -> MKDistanceFormatter {
    let f = MKDistanceFormatter()
    f.unitStyle = .abbreviated
    f.units = units
    return f
}
private let metricDistanceFormatter   = makeDistanceFormatter(.metric)
private let imperialDistanceFormatter = makeDistanceFormatter(.imperial)
private let defaultDistanceFormatter  = makeDistanceFormatter(.default)

/// 全 App 距离展示的单一格式化入口，让所有显示点共用同一份单位偏好。
enum CarryDistanceFormat {
    /// 按给定单位偏好把米格式化为「12 km / 8 mi」等缩写。
    static func string(meters: CLLocationDistance, unit: DistanceUnit) -> String {
        let formatter: MKDistanceFormatter
        switch unit {
        case .kilometers: formatter = metricDistanceFormatter
        case .miles:      formatter = imperialDistanceFormatter
        case .automatic:  formatter = defaultDistanceFormatter
        }
        return formatter.string(fromDistance: meters)
    }
}
