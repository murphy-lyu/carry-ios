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

    /// 按**指定语言键**取名：命中 `nm` 对应语言则用之，否则回落英文 `name`；键为 nil = 英文。
    /// 显式键让「App 内显示（设备语言）」与「导出（所选语言）」共用同一解析、各传各的键。
    func localizedName(for languageKey: String?) -> String {
        guard let key = languageKey else { return name }
        return nm?[key] ?? name
    }

    /// 按**设备**语言取显示名（App 内显示用）。导出按**所选语言**改走 `localizedName(for:)`。
    /// 复用机场库的 AirportLocale（设备语言 → nm 键映射，通用、不重复造）。
    var displayName: String { localizedName(for: AirportLocale.languageKey) }
}

/// 全球航司目录。**不可变参考数据 → 无需 actor 隔离**：`airlines.json`（~225 KB，~986 条）经
/// `static let` 一次性、线程安全地懒加载进 IATA 索引，之后随处**同步** O(1) 读取（首次访问触发解码，
/// 表小、耗时可忽略）。搜索（识别航司）与显示（按界面语言查名，时间轴行 / 详情 / 搜索卡）共用**这一份**，
/// 不重复加载。`displayName` 按调用时 locale 取名，故缓存一份即可随界面语言变化。
/// 单一数据源说明见 spec: itinerary-flight-name-localization.md。
enum AirlineDatabase {
    private static let logger = Logger(subsystem: "com.carry.app", category: "AirlineDatabase")

    /// IATA 码 → 航司，一次性懒加载。是 bundle 内资源、有效构建必有，故（理论上不会发生的）读失败回落空表。
    private static let byIATA: [String: Airline] = {
        guard let url = Bundle.main.url(forResource: "airlines", withExtension: "json") else {
            logger.error("airlines.json missing from bundle")
            return [:]
        }
        do {
            let list = try JSONDecoder().decode([Airline].self, from: Data(contentsOf: url))
            return Dictionary(list.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            logger.error("airlines.json decode failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }()

    /// 启动时后台预热：强制解码进内存，避免首个航班行渲染时的一次性小解码（225K，~ms 级）。
    static func preload() { _ = byIATA }

    /// 按 IATA 航司码（2 位，大小写不敏感）查航司，无则 nil。
    static func airline(forIATA code: String) -> Airline? {
        let key = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard key.count == 2 else { return nil }
        return byIATA[key]
    }

    /// 航班号 → 按 `languageKey` 的航司名（"MU5801" → 中国东方航空），号解析不出航司则 nil。
    /// 键 = nil 时回落英文；App 内显示传 `AirportLocale.languageKey`（设备语言），导出传所选语言键。
    /// **仅航班用**——调用方须 gate 在 `.flight`（火车号 "G403" 会被 `split` 误拆成航司 "G4"）。
    static func airlineName(forFlightNumber number: String, languageKey: String?) -> String? {
        guard let parts = FlightNumberParser.split(number) else { return nil }
        return byIATA[parts.airline]?.localizedName(for: languageKey)  // split 已返回大写前缀，与 iata 键一致
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
