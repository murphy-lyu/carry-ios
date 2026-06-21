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
    /// 本地化机场名，键为客户端语言：zh-Hans/zh-Hant/de/es/fr/ja/ko/pt-BR（en 用 `name`）。某语言缺失则省略。
    let nm: [String: String]?
    /// 城市别名（全语言，如 JFK→["纽约","뉴욕","ニューヨーク"…]），仅供搜索匹配、不用于显示。
    let cs: [String]?

    var id: String { iata }

    /// 按**指定语言键**取名：命中 `nm` 则用之，否则回落英文 `name`；键为 nil = 英文。
    /// 显式键让「App 内显示（设备语言）」与「导出（所选语言）」共用同一解析。
    func localizedName(for languageKey: String?) -> String {
        guard let key = languageKey else { return name }
        return nm?[key] ?? name
    }

    /// 按**设备**语言选显示名（App 内显示用）。导出按所选语言改走 `localizedName(for:)`。
    var displayName: String { localizedName(for: AirportLocale.languageKey) }
}

/// 设备语言 → 数据集 nm 键的映射。返回 nil = 英文（直接用 name）。
/// 中文按地区习惯区分简繁（Hant/TW/HK/MO 视为繁体）；pt 归 pt-BR。
enum AirportLocale {
    static var languageKey: String? {
        let id = (Locale.preferredLanguages.first ?? "en").lowercased()
        if id.hasPrefix("zh") {
            if id.contains("hant") || id.contains("tw") || id.contains("hk") || id.contains("mo") {
                return "zh-Hant"
            }
            return "zh-Hans"
        }
        if id.hasPrefix("pt") { return "pt-BR" }
        for code in ["de", "es", "fr", "ja", "ko"] where id.hasPrefix(code) {
            return code
        }
        return nil
    }
}

/// 机场**不可变参考数据**的单一来源：`airports.json`（~1.6 MB）经 `static let` 一次性、线程安全懒加载。
/// `all` 供搜索遍历、`byIATA` 供「码已知」O(1) 同步取名。搜索（`AirportDatabase` actor，后台扫表）与
/// 显示（详情按码同步取本地化名）**共用这一份**。1.6 MB 解码较重 → 启动 `preload()` 后台预热，避免首次
/// 访问卡主线程、并消除详情页机场名的异步刷新闪烁。spec: itinerary-flight-name-localization.md。
enum AirportCatalog {
    private static let logger = Logger(subsystem: "com.carry.app", category: "AirportCatalog")

    /// 全部机场（搜索遍历用）。bundle 内资源、有效构建必有，故（理论上不会发生的）读失败回落空。
    static let all: [Airport] = {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json") else {
            logger.error("airports.json missing from bundle"); return []
        }
        do { return try JSONDecoder().decode([Airport].self, from: Data(contentsOf: url)) }
        catch {
            logger.error("airports.json decode failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }()

    /// IATA 码（大写）→ 机场，供 O(1) 取名。
    static let byIATA: [String: Airport] = Dictionary(
        all.compactMap { $0.iata.isEmpty ? nil : ($0.iata.uppercased(), $0) },
        uniquingKeysWith: { a, _ in a })

    /// O(1) 精确按 IATA 码取机场（**同步**）——显示已保存航段时按码解析本地化机场名（`Airport.displayName`）。
    static func airport(forIATA code: String) -> Airport? {
        let key = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return nil }
        return byIATA[key]
    }

    /// 启动时后台预热：强制把 1.6 MB 库解码进内存，让后续搜索/显示同步直取、零卡顿、零闪。
    static func preload() { _ = byIATA }
}

/// 全球机场检索引擎。actor：模糊检索是逐键扫全表（CPU 重），放后台执行器、不卡主线程打字。
/// 数据本身在 `AirportCatalog`（单一同步源），此处只做匹配 / 排序。
actor AirportDatabase {
    static let shared = AirportDatabase()
    private init() {}

    /// 检索机场。匹配 IATA / ICAO / 英文名·城市 / 中文名，按相关性 + 大型机场优先排序。
    /// 全球范围，无区域过滤、无目的地偏置（境外搜不到的根因正是区域限制，这里不引入）。
    func search(_ raw: String, limit: Int = 40) -> [Airport] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let upper = q.uppercased()
        let lower = q.lowercased()

        var scored: [(score: Int, airport: Airport)] = []
        for a in AirportCatalog.all {
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

    /// 越小越相关；nil = 不匹配。`lower` = q 的小写（CJK 等无大小写时与 q 相同）。
    private static func matchScore(_ a: Airport, query q: String, upper: String, lower: String) -> Int? {
        if a.iata == upper { return 0 }
        if a.iata.hasPrefix(upper) { return 1 }
        if !a.icao.isEmpty, a.icao.hasPrefix(upper) { return 2 }
        let cityLower = a.city.lowercased()
        if cityLower.hasPrefix(lower) { return 3 }
        // 城市别名精确命中（如「纽约」/「뉴욕」/「ニューヨーク」→ JFK：机场名不含本地城市名时的关键补全）。
        if let cs = a.cs, cs.contains(where: { $0.lowercased() == lower }) { return 3 }
        // 本地化机场名子串（机场中文名含城市，如「昆明长水…」含「昆明」，城市搜索一并覆盖）。
        if let nm = a.nm, nm.values.contains(where: { $0.lowercased().contains(lower) }) { return 4 }
        if let cs = a.cs, cs.contains(where: { $0.lowercased().contains(lower) }) { return 4 }
        if cityLower.contains(lower) { return 5 }
        if a.name.lowercased().contains(lower) { return 6 }
        return nil
    }
}
