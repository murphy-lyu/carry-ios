//
//  AirportDatabase.swift
//  Carry
//
//  内置机场数据库（OurAirports + OpenFlights 时区 + Wikidata 中文名，离线打包）。
//  航班的出发/到达机场选点专用，全球可搜、不依赖地图供应商或设备区域。
//  spec: itinerary-airport-search.md。
//
//  数据来源 airports.json（Carry/Resources/）：有定期航班的机场（含所有大型机场），
//  每条含 iata / icao / 英文名 / 城市 / 国家(ISO) / 坐标 / IANA 时区 / 简繁中文名。
//

import Foundation
import OSLog

/// 单条机场记录。`hans`/`hant` 为可选——缺失时显示回落英文原名。
struct Airport: Decodable, Identifiable, Hashable, Sendable {
    let iata: String
    let icao: String
    let name: String
    let city: String
    let country: String
    let lat: Double
    let lon: Double
    let tz: String
    let large: Bool
    let hans: String?
    let hant: String?
    /// 城市中文别名（如 JFK→["纽约","紐約"]），仅供搜索匹配、不用于显示。
    let cs: [String]?

    var id: String { iata }

    /// 按设备语言选显示名：简体中文→hans、繁体中文→hant、其它或缺失→英文原名。
    var displayName: String {
        switch AirportLocale.chineseScript {
        case .simplified:  return hans ?? name
        case .traditional: return hant ?? name
        case .none:        return name
        }
    }
}

/// 设备中文变体判定（与 zh-Hant 地区习惯一致：Hant / TW / HK / MO 视为繁体）。
enum AirportLocale {
    enum Script { case simplified, traditional, none }

    static var chineseScript: Script {
        let id = (Locale.preferredLanguages.first ?? "en").lowercased()
        guard id.hasPrefix("zh") else { return .none }
        if id.contains("hant") || id.contains("tw") || id.contains("hk") || id.contains("mo") {
            return .traditional
        }
        return .simplified
    }
}

/// 全球机场检索。actor 隔离状态：JSON 在首次检索时于后台执行器懒加载、解码，不阻塞主线程。
actor AirportDatabase {
    static let shared = AirportDatabase()

    private var airports: [Airport] = []
    private var loaded = false
    private static let logger = Logger(subsystem: "com.carry.app", category: "AirportDatabase")

    private init() {}

    private func ensureLoaded() {
        guard !loaded else { return }
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json") else {
            Self.logger.error("airports.json missing from bundle")
            return  // 不置 loaded：理论上不该发生，但万一失败也不永久失能，下次 search 可重试。
        }
        do {
            let data = try Data(contentsOf: url)
            airports = try JSONDecoder().decode([Airport].self, from: data)
            loaded = true  // 仅解码成功后置位：失败时下次 search 重试（快速失败），避免整生命周期静默返回空。
        } catch {
            Self.logger.error("airports.json decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 检索机场。匹配 IATA / ICAO / 英文名·城市 / 中文名，按相关性 + 大型机场优先排序。
    /// 全球范围，无区域过滤、无目的地偏置（境外搜不到的根因正是区域限制，这里不引入）。
    func search(_ raw: String, limit: Int = 40) -> [Airport] {
        ensureLoaded()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let upper = q.uppercased()
        let lower = q.lowercased()

        var scored: [(score: Int, airport: Airport)] = []
        for a in airports {
            if let s = Self.matchScore(a, query: q, upper: upper, lower: lower) {
                scored.append((s, a))
            }
        }
        scored.sort { l, r in
            if l.score != r.score { return l.score < r.score }
            if l.airport.large != r.airport.large { return l.airport.large }
            return l.airport.name < r.airport.name
        }
        return scored.prefix(limit).map(\.airport)
    }

    /// 越小越相关；nil = 不匹配。
    private static func matchScore(_ a: Airport, query q: String, upper: String, lower: String) -> Int? {
        if a.iata == upper { return 0 }
        if a.iata.hasPrefix(upper) { return 1 }
        if !a.icao.isEmpty, a.icao.hasPrefix(upper) { return 2 }
        let cityLower = a.city.lowercased()
        if cityLower.hasPrefix(lower) { return 3 }
        // 中文城市别名精确命中（如「纽约」→ JFK；机场英文名/中文名都不含中文城市时的关键补全）。
        if let cs = a.cs, cs.contains(q) { return 3 }
        // 中文名匹配（机场中文名含城市，如「昆明长水…」含「昆明」，城市搜索一并覆盖）。
        if let hans = a.hans, hans.contains(q) { return 4 }
        if let hant = a.hant, hant.contains(q) { return 4 }
        if let cs = a.cs, cs.contains(where: { $0.contains(q) }) { return 4 }
        if cityLower.contains(lower) { return 5 }
        if a.name.lowercased().contains(lower) { return 6 }
        return nil
    }
}
