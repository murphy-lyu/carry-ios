//
//  TripBookStats.swift
//  Carry
//
//  「我的行程册」聚合统计（纯函数，可脱离 SwiftData 单测）。
//  全部基于 TripBundle 已有数据，无新增录入。口径见 specs/trip-book.md。
//

import Foundation

enum Season: String, CaseIterable {
    case spring, summer, autumn, winter
}

/// 单个行程喂给统计的轻量快照——刻意不依赖 SwiftData `TripBundle`，便于纯函数单测。
struct TripStatInput {
    var days: Int
    var isDateless: Bool
    var countsAsVisited: Bool
    /// 主目的地 + 附加目的地的原始 countryCode（未归并、未大写）。
    var countryCodes: [String]
    /// 主目的地纬度（判南北半球；0/未知按北半球）。
    var latitude: Double
    /// 出发月份 1–12；无日期行程为 nil（不计入季节）。
    var departureMonth: Int?
    /// 出发年份；无日期行程为 nil（不计入「自 X 起旅行」）。
    var departureYear: Int? = nil
    var packedItems: Int = 0
    var totalItems: Int = 0

    // 航班统计（仅 flight 段；航班号查询/手填回填，缺则 0/空）。spec 前提反转见 trip-book.md。
    var flightDistanceMeters: Double = 0   // Σ 大圆里程（米）
    var flightDurationMinutes: Int = 0     // Σ 飞行时长（分钟）
    var aircraftTypes: [String] = []       // 非空机型，每航段一条（可重复，用于计数）
    var airportCodes: [String] = []        // flight 段 from/to IATA 码（非空、已大写）
    /// 累计住宿晚数（Σ stay.nights）；住宿改「入住日 + 退房日」后可派生。
    var lodgingNights: Int = 0
}

struct CountryTally: Equatable {
    let code: String   // 归并后的展示码
    let count: Int     // 含该国家/地区的（已到访）行程数
}

/// 通用「标签 → 次数」计数项（机型 / 机场），按 count 降序、同数按 label 字母序。
struct LabelTally: Equatable {
    let label: String
    let count: Int     // 出现次数（按航段计，一趟多段各计一次）
}

struct TripBookStats: Equatable {
    var tripCount: Int = 0
    var totalDays: Int = 0
    var visitedCountryCount: Int = 0
    var globalCountryTotal: Int = CountryData.continentByAlpha2.count
    /// 全部到访国家/地区，按行程数降序（同数按码字母序）。
    var countryTallies: [CountryTally] = []
    /// 最早一次（有日期）行程的年份，用于「自 X 起旅行」。
    var firstTravelYear: Int? = nil
    var continentCounts: [Continent: Int] = [:]
    var domesticCount: Int = 0
    var internationalCount: Int = 0
    var unknownScopeCount: Int = 0
    var seasonCounts: [Season: Int] = [:]
    var packedItems: Int = 0
    var totalItems: Int = 0

    // 航班 / 住宿（部分覆盖：仅加了航班/住宿的行程有数；无数据时 UI 整块隐藏）。
    var flightDistanceMeters: Double = 0
    var flightDurationMinutes: Int = 0
    var aircraftTallies: [LabelTally] = []   // 机型 → 航段次，降序
    var airportTallies: [LabelTally] = []    // IATA 码 → 经停次，降序
    var totalNights: Int = 0

    var visitedContinentCount: Int { continentCounts.keys.count }
    var packingCompletion: Double { totalItems > 0 ? Double(packedItems) / Double(totalItems) : 0 }

    /// 是否有可展示的飞行数据（里程或时长任一 > 0）→ 决定飞行卡是否出现。
    var hasFlightStats: Bool { flightDistanceMeters > 0 || flightDurationMinutes > 0 }
    /// 坐过的不同机型数。
    var distinctAircraftCount: Int { aircraftTallies.count }

    /// 纯聚合。`homeCountry`/`normalize` 默认取全局 storefront 口径，单测时可注入。
    static func compute(
        inputs: [TripStatInput],
        homeCountry: String = homeCountryCode,
        normalize: (String) -> String = normalizedCountryCode
    ) -> TripBookStats {
        var s = TripBookStats()

        var countryTrips: [String: Int] = [:]      // 归并码 → 含它的已到访行程数
        var continentTrips: [Continent: Int] = [:]  // 大洲 → 含它的已到访行程数
        var visited = Set<String>()
        var aircraftCounts: [String: Int] = [:]     // 机型 → 航段次
        var airportCounts: [String: Int] = [:]      // IATA 码 → 经停次

        for t in inputs {
            // 行程册 = 旅行「回顾」：所有统计只算**已发生**的行程（已出发 + 进行中），
            // 排除未来日期与无日期规划——前瞻性内容留在首页，不污染回顾，也避免
            // 「旅行数算了未来、国家数只算去过」的内部不一致。
            guard t.countsAsVisited else { continue }
            s.tripCount += 1
            s.totalDays += t.days
            s.packedItems += t.packedItems
            s.totalItems += t.totalItems

            if let y = t.departureYear {
                s.firstTravelYear = min(s.firstTravelYear ?? y, y)
            }

            // 国内/国际：基准 = 本国；任一目的地不在本国即国际；无码 = 未知。
            let codes = t.countryCodes.filter { !$0.isEmpty }.map { $0.uppercased() }
            if codes.isEmpty {
                s.unknownScopeCount += 1
            } else if codes.contains(where: { $0 != homeCountry }) {
                s.internationalCount += 1
            } else {
                s.domesticCount += 1
            }

            // 季节：按目的地纬度判半球。
            if let m = t.departureMonth,
               let season = Self.season(month: m, latitude: t.latitude) {
                s.seasonCounts[season, default: 0] += 1
            }

            // 国家/地区 + 大洲：按归并码去重（每行程每国/洲只计一次）。
            let normalized = Set(codes.map(normalize).filter { !$0.isEmpty })
            for code in normalized {
                visited.insert(code)
                countryTrips[code, default: 0] += 1
            }
            let continents = Set(normalized.compactMap { CountryData.continentByAlpha2[$0] })
            for c in continents { continentTrips[c, default: 0] += 1 }

            // 航班 / 住宿：按航段累计（一趟多段各计一次）；缺失字段贡献 0/空、不污染。
            s.flightDistanceMeters += t.flightDistanceMeters
            s.flightDurationMinutes += t.flightDurationMinutes
            s.totalNights += t.lodgingNights
            for a in t.aircraftTypes { aircraftCounts[a, default: 0] += 1 }
            for code in t.airportCodes { airportCounts[code, default: 0] += 1 }
        }

        s.visitedCountryCount = visited.count
        s.continentCounts = continentTrips
        // 全部到访国家：按行程数降序，同数按码字母序稳定排序。
        s.countryTallies = countryTrips
            .map { CountryTally(code: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
        // 机型 / 机场：按次数降序，同数按 label 字母序稳定排序。
        let sortTally: ([String: Int]) -> [LabelTally] = { dict in
            dict.map { LabelTally(label: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        }
        s.aircraftTallies = sortTally(aircraftCounts)
        s.airportTallies = sortTally(airportCounts)
        return s
    }

    /// 北半球：3–5 春 / 6–8 夏 / 9–11 秋 / 12,1,2 冬；南半球（纬度<0）对调。
    static func season(month: Int, latitude: Double) -> Season? {
        guard (1...12).contains(month) else { return nil }
        let northern: Season
        switch month {
        case 3...5:   northern = .spring
        case 6...8:   northern = .summer
        case 9...11:  northern = .autumn
        default:      northern = .winter   // 12, 1, 2
        }
        guard latitude < 0 else { return northern }
        switch northern {
        case .spring: return .autumn
        case .autumn: return .spring
        case .summer: return .winter
        case .winter: return .summer
        }
    }
}

