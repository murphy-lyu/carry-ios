//
//  TripInfo.swift
//  Carry
//

import Foundation

struct TripInfo: Hashable {
    var name: String = ""
    var destinationCity: String = ""
    var departureDate: Date
    var returnDate: Date
    /// 无日期「规划中」行程。为真时 departureDate/returnDate 为占位值，调用方不应读取。
    var isDateless: Bool = false
    /// 「输入即解析」捕获的权威 ISO 国家码（alpha-2，大写）+ 坐标。非空时 createTrip 直接写入、
    /// 跳过文本反解析（updateCountryCode），让地图点亮语言无关、零 geocode 往返。仅主目的地；
    /// 多城市的其余城市仍走文本兜底（geocodeMissingTrips 的 missingExtras 自愈）。默认 nil = 维持原文本路径。
    var resolvedCountryCode: String? = nil
    var resolvedLatitude: Double? = nil
    var resolvedLongitude: Double? = nil

    init(
        name: String = "",
        destinationCity: String = "",
        departureDate: Date? = nil,
        returnDate: Date? = nil,
        isDateless: Bool = false,
        resolvedCountryCode: String? = nil,
        resolvedLatitude: Double? = nil,
        resolvedLongitude: Double? = nil
    ) {
        self.name = name
        self.destinationCity = destinationCity
        self.isDateless = isDateless
        self.resolvedCountryCode = resolvedCountryCode
        self.resolvedLatitude = resolvedLatitude
        self.resolvedLongitude = resolvedLongitude

        let calendar = Calendar.current
        let base = calendar.startOfDay(for: departureDate ?? Date())
        let computedReturn = calendar.date(byAdding: .day, value: 6, to: base) ?? base

        self.departureDate = base
        self.returnDate = calendar.startOfDay(for: returnDate ?? computedReturn)
    }

    var durationDays: Int {
        max(1, Calendar.current.dateComponents([.day], from: departureDate, to: returnDate).day ?? 1)
    }

    var dateRangeDisplay: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: departureDate)) – \(fmt.string(from: returnDate))"
    }
}
