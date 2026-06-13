//
//  TripBookStats+Trips.swift
//  Carry
//
//  TripBundle（SwiftData）→ TripBookStats 适配器。核心聚合在 TripBookStats.swift
//  保持纯净（可独立单测），此处只做模型到轻量输入的映射。
//

import Foundation

extension TripBookStats {
    /// 从 SwiftData 行程映射为纯输入并聚合。UI 调用此入口。
    static func from(trips: [TripBundle]) -> TripBookStats {
        let inputs = trips.map { t -> TripStatInput in
            let codes = [t.countryCode] + t.additionalDestinations.map(\.countryCode)
            let cal = Calendar.current
            let month: Int? = t.isDateless ? nil : cal.component(.month, from: t.departureDate)
            let year: Int? = t.isDateless ? nil : cal.component(.year, from: t.departureDate)
            return TripStatInput(
                days: t.spanDays,   // 旅行天数 = 含两端实际天数（非晚数）；与首页/行程页同口径
                isDateless: t.isDateless,
                countsAsVisited: t.countsAsVisited,
                countryCodes: codes,
                latitude: t.latitude,
                departureMonth: month,
                departureYear: year,
                packedItems: t.packedCount,
                totalItems: t.totalCount
            )
        }
        return compute(inputs: inputs)
    }
}
