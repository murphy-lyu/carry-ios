//
//  PlugCatalog.swift
//  Carry
//

import Foundation

// MARK: - PlugInfo

struct PlugInfo {
    /// Plug type letters used in this country, e.g. ["A", "B"] or ["C", "F"]
    let types: [String]
    /// Mains voltage in volts, e.g. 230
    let voltage: Int
    /// Mains frequency in Hz, e.g. 50
    let frequency: Int
}

// MARK: - PlugCatalog

/// Static country-code → plug / voltage lookup.
/// Source: world.plugs.online  (ISO 3166-1 alpha-2 keys)
/// Coverage: ~110 common travel destinations.
enum PlugCatalog {
    static func info(for countryCode: String) -> PlugInfo? {
        return catalog[countryCode.uppercased()]
    }

    /// Returns the union of plug types across multiple destinations, de-duplicated.
    static func mergedTypes(for countryCodes: [String]) -> [String] {
        var seen = Set<String>()
        return countryCodes
            .compactMap { catalog[$0.uppercased()] }
            .flatMap { $0.types }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Data

    private static let catalog: [String: PlugInfo] = [

        // ── East Asia ──────────────────────────────────────────────────────────
        "CN": PlugInfo(types: ["A", "C", "I"],   voltage: 220, frequency: 50),
        "JP": PlugInfo(types: ["A", "B"],         voltage: 100, frequency: 50), // 50Hz East / 60Hz West; 50 is conservative
        "KR": PlugInfo(types: ["C", "F"],         voltage: 220, frequency: 60),
        "TW": PlugInfo(types: ["A", "B"],         voltage: 110, frequency: 60),
        "HK": PlugInfo(types: ["G"],              voltage: 220, frequency: 50),
        "MO": PlugInfo(types: ["G"],              voltage: 220, frequency: 50),
        "MN": PlugInfo(types: ["C", "E", "F"],   voltage: 220, frequency: 50),

        // ── Southeast Asia ─────────────────────────────────────────────────────
        "TH": PlugInfo(types: ["A", "B", "C"],   voltage: 220, frequency: 50),
        "VN": PlugInfo(types: ["A", "C"],         voltage: 220, frequency: 50),
        "SG": PlugInfo(types: ["G"],              voltage: 230, frequency: 50),
        "MY": PlugInfo(types: ["G"],              voltage: 240, frequency: 50),
        "ID": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "PH": PlugInfo(types: ["A", "B", "C"],   voltage: 220, frequency: 60),
        "BN": PlugInfo(types: ["G"],              voltage: 240, frequency: 50),
        "KH": PlugInfo(types: ["A", "C"],         voltage: 230, frequency: 50),
        "LA": PlugInfo(types: ["A", "B", "C"],   voltage: 230, frequency: 50),
        "MM": PlugInfo(types: ["C", "D", "G"],   voltage: 230, frequency: 50),

        // ── South Asia ─────────────────────────────────────────────────────────
        "IN": PlugInfo(types: ["C", "D", "M"],   voltage: 230, frequency: 50),
        "LK": PlugInfo(types: ["D", "G", "M"],   voltage: 230, frequency: 50),
        "NP": PlugInfo(types: ["C", "D", "M"],   voltage: 230, frequency: 50),
        "PK": PlugInfo(types: ["C", "D", "G"],   voltage: 230, frequency: 50),
        "BD": PlugInfo(types: ["C", "D", "G"],   voltage: 220, frequency: 50),
        "BT": PlugInfo(types: ["D", "F"],         voltage: 230, frequency: 50),
        "MV": PlugInfo(types: ["D", "G", "J", "K", "L"],
                                                  voltage: 230, frequency: 50),

        // ── Middle East ────────────────────────────────────────────────────────
        "AE": PlugInfo(types: ["C", "G"],         voltage: 220, frequency: 50),
        "SA": PlugInfo(types: ["A", "B", "G"],   voltage: 220, frequency: 60),
        "QA": PlugInfo(types: ["D", "G"],         voltage: 240, frequency: 50),
        "KW": PlugInfo(types: ["C", "G"],         voltage: 240, frequency: 50),
        "BH": PlugInfo(types: ["G"],              voltage: 230, frequency: 50),
        "OM": PlugInfo(types: ["C", "G"],         voltage: 240, frequency: 50),
        "JO": PlugInfo(types: ["B", "C", "D", "F", "G"],
                                                  voltage: 230, frequency: 50),
        "IL": PlugInfo(types: ["C", "H"],         voltage: 230, frequency: 50),
        "TR": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),

        // ── Central Asia ───────────────────────────────────────────────────────
        "KZ": PlugInfo(types: ["C", "F"],         voltage: 220, frequency: 50),
        "KG": PlugInfo(types: ["C", "F"],         voltage: 220, frequency: 50),
        "TJ": PlugInfo(types: ["C", "F"],         voltage: 220, frequency: 50),
        "UZ": PlugInfo(types: ["C", "F"],         voltage: 220, frequency: 50),

        // ── Western Europe ─────────────────────────────────────────────────────
        "GB": PlugInfo(types: ["G"],              voltage: 230, frequency: 50),
        "IE": PlugInfo(types: ["G"],              voltage: 230, frequency: 50),
        "FR": PlugInfo(types: ["C", "E"],         voltage: 230, frequency: 50),
        "DE": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "IT": PlugInfo(types: ["C", "F", "L"],   voltage: 230, frequency: 50),
        "ES": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "PT": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "NL": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "BE": PlugInfo(types: ["C", "E"],         voltage: 230, frequency: 50),
        "CH": PlugInfo(types: ["C", "J"],         voltage: 230, frequency: 50),
        "AT": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "LU": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),

        // ── Northern Europe ────────────────────────────────────────────────────
        "SE": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "NO": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "DK": PlugInfo(types: ["C", "F", "K"],   voltage: 230, frequency: 50),
        "FI": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "IS": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),

        // ── Eastern & Central Europe ───────────────────────────────────────────
        "PL": PlugInfo(types: ["C", "E"],         voltage: 230, frequency: 50),
        "CZ": PlugInfo(types: ["C", "E"],         voltage: 230, frequency: 50),
        "SK": PlugInfo(types: ["C", "E"],         voltage: 230, frequency: 50),
        "HU": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "RO": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "BG": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "RS": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "HR": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "SI": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "EE": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "LV": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "LT": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "UA": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "BY": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),
        "GR": PlugInfo(types: ["C", "F"],         voltage: 230, frequency: 50),

        // ── Russia ─────────────────────────────────────────────────────────────
        "RU": PlugInfo(types: ["C", "F"],         voltage: 220, frequency: 50),

        // ── North America ──────────────────────────────────────────────────────
        "US": PlugInfo(types: ["A", "B"],         voltage: 120, frequency: 60),
        "CA": PlugInfo(types: ["A", "B"],         voltage: 120, frequency: 60),
        "MX": PlugInfo(types: ["A", "B"],         voltage: 127, frequency: 60),

        // ── Central America & Caribbean ────────────────────────────────────────
        "CR": PlugInfo(types: ["A", "B"],         voltage: 120, frequency: 60),
        "PA": PlugInfo(types: ["A", "B"],         voltage: 110, frequency: 60),
        "GT": PlugInfo(types: ["A", "B"],         voltage: 120, frequency: 60),
        "BZ": PlugInfo(types: ["A", "B"],         voltage: 110, frequency: 60),
        "CU": PlugInfo(types: ["A", "B", "C"],   voltage: 110, frequency: 60),
        "DO": PlugInfo(types: ["A", "B"],         voltage: 110, frequency: 60),
        "JM": PlugInfo(types: ["A", "B"],         voltage: 110, frequency: 50),
        "BS": PlugInfo(types: ["A", "B"],         voltage: 120, frequency: 60),
        "BB": PlugInfo(types: ["A", "B"],         voltage: 115, frequency: 50),
        "TT": PlugInfo(types: ["A", "B"],         voltage: 115, frequency: 60),

        // ── South America ──────────────────────────────────────────────────────
        "BR": PlugInfo(types: ["C", "N"],         voltage: 127, frequency: 60), // varies by city; some 220V
        "AR": PlugInfo(types: ["C", "I"],         voltage: 220, frequency: 50),
        "CL": PlugInfo(types: ["C", "L"],         voltage: 220, frequency: 50),
        "CO": PlugInfo(types: ["A", "B"],         voltage: 110, frequency: 60),
        "PE": PlugInfo(types: ["A", "B", "C"],   voltage: 220, frequency: 60),
        "EC": PlugInfo(types: ["A", "B"],         voltage: 120, frequency: 60),
        "BO": PlugInfo(types: ["A", "C"],         voltage: 220, frequency: 50),
        "UY": PlugInfo(types: ["C", "F", "L"],   voltage: 220, frequency: 50),

        // ── Oceania ────────────────────────────────────────────────────────────
        "AU": PlugInfo(types: ["I"],              voltage: 230, frequency: 50),
        "NZ": PlugInfo(types: ["I"],              voltage: 230, frequency: 50),
        "FJ": PlugInfo(types: ["I"],              voltage: 240, frequency: 50),
        "PF": PlugInfo(types: ["A", "B", "C"],   voltage: 220, frequency: 60),

        // ── Africa ─────────────────────────────────────────────────────────────
        "ZA": PlugInfo(types: ["C", "M", "N"],   voltage: 230, frequency: 50),
        "EG": PlugInfo(types: ["C"],              voltage: 220, frequency: 50),
        "MA": PlugInfo(types: ["C", "E"],         voltage: 220, frequency: 50),
        "TN": PlugInfo(types: ["C", "E"],         voltage: 230, frequency: 50),
        "KE": PlugInfo(types: ["G"],              voltage: 240, frequency: 50),
        "TZ": PlugInfo(types: ["D", "G"],         voltage: 230, frequency: 50),
        "ET": PlugInfo(types: ["C", "F", "L"],   voltage: 220, frequency: 50),
        "GH": PlugInfo(types: ["D", "G"],         voltage: 230, frequency: 50),
        "NG": PlugInfo(types: ["D", "G"],         voltage: 240, frequency: 50),
        "MU": PlugInfo(types: ["C", "G"],         voltage: 230, frequency: 50),
        "SC": PlugInfo(types: ["G"],              voltage: 240, frequency: 50),
        "MG": PlugInfo(types: ["C", "E"],         voltage: 220, frequency: 50),
        "CV": PlugInfo(types: ["C", "F"],         voltage: 220, frequency: 50),
    ]
}
