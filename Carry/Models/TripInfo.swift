//
//  TripInfo.swift
//  Carry
//

import Foundation

/// 一个结构化解析后的目的地（来自检索建议选中，或编辑页从既有行程回填）。
/// 顺序即优先级：数组首项 = 主目的地（写 `TripBundle.countryCode/latitude/longitude`），
/// 其余 → `additionalDestinations`。`countryCode` 为空 = 未解析（自由文本/旧数据），
/// 保存时回落 `splitCities + updateCountryCode` 文本路径补全。
struct ResolvedDestination: Identifiable, Hashable {
    let id: UUID
    var name: String
    /// 权威 ISO 国家码（alpha-2，大写）；空 = 未解析。
    var countryCode: String
    var latitude: Double
    var longitude: Double

    init(
        id: UUID = UUID(),
        name: String,
        countryCode: String = "",
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        self.id = id
        self.name = name
        self.countryCode = countryCode.uppercased()
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 是否携带权威结构化结果（可跳过文本反查）。
    var isResolved: Bool { !countryCode.isEmpty }
}

struct TripInfo: Hashable {
    var name: String = ""
    var destinationCity: String = ""
    var departureDate: Date
    var returnDate: Date
    /// 无日期「规划中」行程。为真时 departureDate/returnDate 为占位值，调用方不应读取。
    var isDateless: Bool = false
    /// 「输入即解析」捕获的有序结构化目的地（首=主，其余=additionalDestinations）。
    /// **仅当全部已解析（且无未提交自由文本）时**才由调用方填入 → createTrip/updateTripInfo
    /// 直接写 countryCode + additionalDestinations、跳过文本反解析，让地图点亮语言无关、零 geocode 往返。
    /// 为空（含「部分未解析 / 有自由文本」）时维持原 `destinationCity` 文本路径（updateCountryCode +
    /// geocodeMissingTrips 自愈）。
    var resolvedDestinations: [ResolvedDestination] = []

    init(
        name: String = "",
        destinationCity: String = "",
        departureDate: Date? = nil,
        returnDate: Date? = nil,
        isDateless: Bool = false,
        resolvedDestinations: [ResolvedDestination] = []
    ) {
        self.name = name
        self.destinationCity = destinationCity
        self.isDateless = isDateless
        self.resolvedDestinations = resolvedDestinations

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
