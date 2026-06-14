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
        case .lodging:     return "bed.double"
        case .train:       return "train.side.front.car"
        case .carRental:   return "car.fill"
        case .flight:      return "airplane"
        case .cruise:      return "ferry.fill"
        case .activity:    return "figure.walk"
        case .shopping:    return "bag"
        case .other:       return "mappin"
        }
    }

    /// 本地化标题 key（itinerary.category.<raw>，已在 Localizable.xcstrings 显式写 en）。
    var titleKey: LocalizedStringKey { LocalizedStringKey(localizationKey) }
}
