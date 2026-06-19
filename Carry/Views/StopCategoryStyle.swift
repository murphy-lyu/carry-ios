//
//  StopCategoryStyle.swift
//  Carry
//
//  StopCategory 的 UI 映射（图标/标题）。放在 View 层，模型保持纯数据。
//

import SwiftUI

extension StopCategory {
    /// SF Symbol 名（技术常量，非用户文案）。
    var symbolName: String {
        switch self {
        case .sightseeing: return "binoculars"
        case .food:        return "fork.knife"
        case .activity:    return "figure.walk"
        case .shopping:    return "bag"
        case .lodging:     return "bed.double"
        case .flight:      return "airplane"
        case .train:       return "train.side.front.car"
        case .carRental:   return "car.fill"
        case .cruise:      return "ferry.fill"
        case .other:       return "mappin"
        }
    }

    /// 本地化标题 key（itinerary.category.<raw>，已在 Localizable.xcstrings 显式写 en）。
    var titleKey: LocalizedStringKey { LocalizedStringKey(localizationKey) }
}

extension TransportMode {
    /// 类型选择的**单一有序数据源**（= 常用 + 更多）。表单内类型选择器用整份（编辑时可改成任意类型）；
    /// 「+」菜单把它拆成「常用直列 + 更多收进子菜单」，外层保持轻、低频也能直接落位。spec: itinerary-car-rental.md。
    static let commonModes: [TransportMode] = [.flight, .train, .carRental]
    static let moreModes: [TransportMode] = [.bus, .ferry, .other]
    static let ordered: [TransportMode] = commonModes + moreModes

    /// SF Symbol 名（技术常量，非用户文案）。
    var symbolName: String {
        switch self {
        case .flight:    return "airplane"
        case .train:     return "train.side.front.car"
        case .bus:       return "bus"
        case .ferry:     return "ferry.fill"
        case .carRental: return "car.fill"
        case .other:     return "arrow.triangle.swap"
        }
    }

    /// 本地化标题 key（itinerary.transport.mode.<raw>，已在 Localizable.xcstrings 显式写 en）。
    var titleKey: LocalizedStringKey { LocalizedStringKey(localizationKey) }
}
