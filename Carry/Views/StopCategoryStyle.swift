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
