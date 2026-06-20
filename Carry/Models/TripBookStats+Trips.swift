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

            // 航班统计：只看 flight 段（里程/时长/机型由航班号查询回填，火车等不会有）。
            var flightMeters: Double = 0
            var flightMinutes = 0
            var aircraft: [String] = []
            var airports: [String] = []
            for day in t.safeItineraryDays {
                for seg in (day.segments ?? []) where seg.mode == .flight {
                    flightMeters += seg.distanceMeters
                    flightMinutes += seg.durationMinutes
                    // 剥品牌前缀归一（"Airbus A321"/"A321" 视为同一型号，正确计数 + 与展示一致）。
                    let model = aircraftModelDisplay(seg.aircraftType)
                    if !model.isEmpty { aircraft.append(model) }
                    for code in [seg.fromCode, seg.toCode] {
                        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
                        if !c.isEmpty { airports.append(c) }
                    }
                }
            }
            let nights = t.safeLodgingStays.reduce(0) { $0 + max(0, $1.nights) }

            return TripStatInput(
                days: t.spanDays,   // 旅行天数 = 含两端实际天数（非晚数）；与首页/行程页同口径
                isDateless: t.isDateless,
                countsAsVisited: t.countsAsVisited,
                countryCodes: codes,
                latitude: t.latitude,
                departureMonth: month,
                departureYear: year,
                packedItems: t.packedCount,
                totalItems: t.totalCount,
                flightDistanceMeters: flightMeters,
                flightDurationMinutes: flightMinutes,
                aircraftTypes: aircraft,
                airportCodes: airports,
                lodgingNights: nights
            )
        }
        return compute(inputs: inputs)
    }
}
