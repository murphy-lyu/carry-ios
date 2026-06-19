//
//  AirlineDatabase.swift
//  Carry
//
//  内置航司数据库（OpenFlights airlines.dat + Wikidata 多语言名，离线打包）。
//  用途：添加航班时按航班号前缀即时识别航司（MU5431 → China Eastern Airlines / 中国东方航空）。
//  spec: itinerary-flight-search-first.md。
//
//  数据来源 airlines.json（Carry/Resources/）：active 且有 2 位 IATA 航司码的航司，
//  每条含 iata / icao / 英文名 / 多语言名。英文名优先 Wikidata（OpenFlights 名过时）。
//

import Foundation
import OSLog

/// 单条航司记录。`nm` 缺失时显示回落英文原名。
struct Airline: Decodable, Identifiable, Hashable, Sendable {
    let iata: String
    let icao: String
    let name: String
    /// 本地化航司名，键为客户端语言：zh-Hans/zh-Hant/de/es/fr/ja/ko/pt-BR（en 用 `name`）。某语言缺失则省略。
    let nm: [String: String]?

    var id: String { iata }

    /// 按设备语言选显示名：命中 nm 对应语言则用之，否则回落英文原名。
    /// 复用机场库的 AirportLocale（设备语言 → nm 键映射，通用、不重复造）。
    var displayName: String {
        guard let key = AirportLocale.languageKey else { return name }
        return nm?[key] ?? name
    }
}

/// 全球航司查询。actor 隔离状态：JSON 在首次查询时于后台执行器懒加载、解码，不阻塞主线程。
/// 表小（~986 条），全量驻内存并建 IATA 索引，按航班号前缀 O(1) 命中。
actor AirlineDatabase {
    static let shared = AirlineDatabase()

    private var byIATA: [String: Airline] = [:]
    private var loaded = false
    private static let logger = Logger(subsystem: "com.carry.app", category: "AirlineDatabase")

    private init() {}

    private func ensureLoaded() {
        guard !loaded else { return }
        guard let url = Bundle.main.url(forResource: "airlines", withExtension: "json") else {
            Self.logger.error("airlines.json missing from bundle")
            return  // 不置 loaded：万一失败也不永久失能，下次查询可重试。
        }
        do {
            let data = try Data(contentsOf: url)
            let list = try JSONDecoder().decode([Airline].self, from: data)
            byIATA = Dictionary(list.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
            loaded = true  // 仅解码成功后置位：失败时下次重试，避免整生命周期静默返回空。
        } catch {
            Self.logger.error("airlines.json decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 按 IATA 航司码（2 位，大小写不敏感）查航司，无则 nil。
    func airline(forIATA code: String) -> Airline? {
        ensureLoaded()
        let key = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard key.count == 2 else { return nil }
        return byIATA[key]
    }
}

/// 从航班号解析「航司 IATA 前缀 + 班次号」。如 "MU5431" → ("MU","5431")、"9C8888" → ("9C","8888")。
/// 航司码 = 前 2 位字母数字（IATA 规则：两位，可含一个数字如 9C/3U/U2）；其后必须是纯数字班次。
/// 解析不出（位数不足/格式不符）返回 nil。纯展示/识别用，不做严格校验（最终以查询结果为准）。
enum FlightNumberParser {
    static func split(_ raw: String) -> (airline: String, number: String)? {
        let s = raw.uppercased().filter { !$0.isWhitespace }
        guard s.count >= 3 else { return nil }
        let prefix = String(s.prefix(2))
        let rest = String(s.dropFirst(2))
        guard prefix.allSatisfy({ $0.isLetter || $0.isNumber }),
              prefix.contains(where: { $0.isLetter }),   // 至少一个字母，排除纯数字误判
              !rest.isEmpty, rest.allSatisfy({ $0.isNumber }) else { return nil }
        return (prefix, rest)
    }
}
