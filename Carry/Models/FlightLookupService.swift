//
//  FlightLookupService.swift
//  Carry
//
//  航班号查询（spec: itinerary-flight-lookup.md）。
//
//  调自家 Cloudflare Worker 代理（藏 key + 缓存）→ 解析 AeroDataBox 响应 → 映射成 FlightLookupResult。
//  「尽力填」：每个字段可空，国际航班通常全、大陆国内出发端常缺（覆盖现实见 spec）→ 缺的留用户手填。
//  纯数据层，不碰 SwiftData/UI；与现有 AirportDatabase 配合（按 IATA 补坐标/时区）。
//

import Foundation
import CoreLocation

// MARK: - 配置

nonisolated enum FlightLookupConfig {
    /// 航班查询代理地址（你的 Cloudflare Worker）。公开、无敏感；换数据市场只改 Worker、不改这里。
    static let proxyURLString = "https://carry-flight.murphy-latte.workers.dev/flight"
    /// 与 Worker 的 APP_TOKEN secret 对应；非空则随请求发 X-App-Token 头，挡住盗用 Worker。
    /// 注：这是低安全级的「门槛」、客户端可提取（非真密钥，真 key 只在 Worker）；要轮换时两边同步改。
    static let appToken = "3d54d002389110a3f05c8c18eec71eb6fefd199ee09ec012"

    /// 是否已配置（避免占位 URL 时白发请求）。
    static var isConfigured: Bool {
        proxyURLString.hasPrefix("https://") && !proxyURLString.contains("REPLACE_ME")
    }
}

// MARK: - 结果（尽力填，字段可空）

nonisolated struct FlightLookupResult: Equatable {
    var airlineName: String = ""
    var flightNumber: String = ""     // 规整后（去空格大写），如 "MU5101"
    var aircraftType: String = ""     // 机型，如 "Boeing 787-9"
    var distanceMeters: Double = 0    // 航程，取自接口 greatCircleDistance
    var durationMinutes: Int = 0      // 飞行时长，取自接口起降时刻差（绝对时刻，跨时区准确）
    var from = Endpoint()
    var to = Endpoint()

    /// 一端（出发或到达）。`iata` 空表示这端没查到（如大陆国内的出发端）。
    nonisolated struct Endpoint: Equatable {
        var iata: String = ""
        var name: String = ""
        var latitude: Double = 0
        var longitude: Double = 0
        var timeZoneId: String = ""
        var terminal: String = ""
        /// 计划时刻的绝对时间点（由 "local"含偏移 解析）；nil = 缺。
        var scheduledLocal: Date?

        var hasAirport: Bool { !iata.isEmpty }
    }
}

// MARK: - 错误

nonisolated enum FlightLookupError: Error {
    case notConfigured
    case badInput
    case network
    case server
    case notFound      // 查到了但没这趟航班
}

// MARK: - 服务

nonisolated enum FlightLookupService {

    /// 查航班。`number` 航班号；`dateString` = "yyyy-MM-dd"（出发日，用于查询 + 多实例挑选）。
    static func lookup(number rawNumber: String, dateString: String) async throws -> FlightLookupResult {
        guard FlightLookupConfig.isConfigured else { throw FlightLookupError.notConfigured }
        let number = rawNumber.uppercased().replacingOccurrences(of: " ", with: "")
        guard !number.isEmpty, dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw FlightLookupError.badInput
        }
        guard var comps = URLComponents(string: FlightLookupConfig.proxyURLString) else {
            throw FlightLookupError.notConfigured
        }
        comps.queryItems = [.init(name: "number", value: number), .init(name: "date", value: dateString)]
        guard let url = comps.url else { throw FlightLookupError.badInput }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if !FlightLookupConfig.appToken.isEmpty {
            request.setValue(FlightLookupConfig.appToken, forHTTPHeaderField: "X-App-Token")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FlightLookupError.network
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FlightLookupError.server
        }
        guard let decoded = try? JSONDecoder().decode(ProxyResponse.self, from: data) else {
            throw FlightLookupError.server
        }
        guard let flight = pickFlight(decoded.flights, matching: dateString) else {
            throw FlightLookupError.notFound
        }
        return map(flight)
    }

    // MARK: 多实例挑选

    /// 查一个日期可能返回多班（不同日/经停）→ 挑出发日期匹配的；缺出发时刻则退到达日期、再退第一条。
    private static func pickFlight(_ flights: [FlightDTO], matching dateString: String) -> FlightDTO? {
        guard !flights.isEmpty else { return nil }
        func localDate(_ end: EndDTO?) -> String? {
            guard let s = end?.scheduledTime?.local, let d = parseOffsetDate(s) else { return nil }
            return outputDateString(d, offsetSample: s)
        }
        if let m = flights.first(where: { localDate($0.departure) == dateString }) { return m }
        if let m = flights.first(where: { localDate($0.arrival) == dateString }) { return m }
        return flights.first
    }

    // MARK: 映射

    private static func map(_ f: FlightDTO) -> FlightLookupResult {
        var r = FlightLookupResult()
        r.airlineName = f.airline?.name ?? ""
        r.flightNumber = (f.number ?? "").uppercased().replacingOccurrences(of: " ", with: "")
        r.aircraftType = f.aircraft?.model ?? ""
        r.distanceMeters = f.greatCircleDistance?.meter ?? 0   // 航程，接口直接给
        r.from = endpoint(f.departure)
        r.to = endpoint(f.arrival)
        // 飞行时长：接口给的起降「local 含偏移」即绝对时刻，两者相减跨时区也准确（不必自己拼时区）。
        if let dep = r.from.scheduledLocal, let arr = r.to.scheduledLocal {
            let mins = Int(arr.timeIntervalSince(dep) / 60)
            if mins > 0 { r.durationMinutes = mins }
        }
        return r
    }

    private static func endpoint(_ e: EndDTO?) -> FlightLookupResult.Endpoint {
        var ep = FlightLookupResult.Endpoint()
        guard let e else { return ep }
        if let a = e.airport {
            ep.iata = a.iata ?? ""
            ep.name = a.name ?? a.municipalityName ?? ""
            ep.latitude = a.location?.lat ?? 0
            ep.longitude = a.location?.lon ?? 0
            ep.timeZoneId = a.timeZone ?? ""
        }
        ep.terminal = e.terminal ?? ""
        if let s = e.scheduledTime?.local { ep.scheduledLocal = parseOffsetDate(s) }
        return ep
    }

    // MARK: 时间解析（"2026-06-19 18:05-04:00"）

    private static let offsetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mmZZZZZ"   // ZZZZZ 解析 "-04:00"/"+08:00"/"Z"
        return f
    }()

    private static func parseOffsetDate(_ s: String) -> Date? { offsetFormatter.date(from: s) }

    /// 用该时刻自身的时区偏移，得到「本地日历日」字符串，用于按出发日匹配。
    private static func outputDateString(_ date: Date, offsetSample: String) -> String {
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "yyyy-MM-dd"
        // 偏移取自原始串尾部（如 "+08:00"）→ 用对应秒数构造 tz，保证「当地日」正确。
        out.timeZone = timeZone(fromOffsetSuffix: offsetSample)
        return out.string(from: date)
    }

    private static func timeZone(fromOffsetSuffix s: String) -> TimeZone {
        if s.hasSuffix("Z") { return TimeZone(identifier: "UTC") ?? .current }
        // 取末尾 ±HH:MM
        guard let r = s.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) else { return .current }
        let off = String(s[r])
        let sign = off.hasPrefix("-") ? -1 : 1
        let hm = off.dropFirst().split(separator: ":")
        let secs = sign * ((Int(hm.first ?? "0") ?? 0) * 3600 + (Int(hm.last ?? "0") ?? 0) * 60)
        return TimeZone(secondsFromGMT: secs) ?? .current
    }
}

// MARK: - 上游 DTO（Worker 透传的 AeroDataBox 结构，只取我们要的字段）

private struct ProxyResponse: Decodable { let flights: [FlightDTO] }

private struct FlightDTO: Decodable {
    let number: String?
    let aircraft: AircraftDTO?
    let airline: AirlineDTO?
    let departure: EndDTO?
    let arrival: EndDTO?
    let greatCircleDistance: DistanceDTO?
}
private struct DistanceDTO: Decodable { let meter: Double? }
private struct AircraftDTO: Decodable { let model: String? }
private struct AirlineDTO: Decodable { let name: String?; let iata: String?; let icao: String? }
private struct EndDTO: Decodable { let airport: AirportDTO?; let scheduledTime: TimeDTO?; let terminal: String? }
private struct AirportDTO: Decodable {
    let iata: String?; let icao: String?; let name: String?; let shortName: String?
    let municipalityName: String?; let location: LocDTO?; let countryCode: String?; let timeZone: String?
}
private struct LocDTO: Decodable { let lat: Double?; let lon: Double? }
private struct TimeDTO: Decodable { let utc: String?; let local: String? }
