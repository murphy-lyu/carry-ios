//
//  ClimateInference.swift
//  Carry
//

import Foundation

enum ClimateInference {

    // MARK: - Country sets

    private static let tropicalCountries: Set<String> = [
        "TH", "ID", "PH", "MY", "SG", "VN", "KH", "LA", "BN",   // SE Asia
        "MV", "LK",                                                // Indian Ocean
        "MG", "MU", "SC", "CV", "RE",                             // African/Indian Ocean islands
        "AE", "OM",                                                // Middle East (Dubai/Oman beach tourism)
        "FJ", "WS", "TO", "VU", "PF", "SB", "PW", "FM", "MH", "KI", // Pacific
        "NC", "GU", "MP",                                          // Pacific (New Caledonia, Guam, Saipan)
        "CU", "DO", "JM", "BS", "BB", "TT",                       // Caribbean
        "LC", "VC", "GD", "KN", "AG", "AW", "CW", "MQ", "GP", "TC", // Caribbean (cont.)
        "CR", "PA", "GT", "BZ", "HN", "NI", "SV",                 // Central America
    ]

    private static let alwaysColdCountries: Set<String> = [
        "IS", "GL",
    ]

    // Northern hemisphere: suggest winter if departure is Nov–Feb
    private static let seasonallyColdNorthernCountries: Set<String> = [
        "JP", "KR", "MN",                        // East Asia
        "NO", "SE", "FI", "DK",                  // Scandinavia
        "EE", "LV", "LT",                        // Baltics
        "PL", "CZ", "SK", "HU", "AT", "CH", "DE", "SI", // Central Europe
        "FR", "GB", "NL", "BE", "IT",            // Western Europe
        "RO", "BG",                              // Eastern Europe / Balkans ski
        "RU", "UA", "BY", "KZ",                  // Eastern Europe / Central Asia
        "CA",                                     // Canada
    ]

    private static let highAltitudeCountries: Set<String> = [
        "NP", "BT",         // Himalayas
        "PE", "BO",         // Andes (Machu Picchu, Titicaca)
        "EC", "CO",         // Ecuador (Quito), Colombia (Bogotá)
        "ET",               // Ethiopia (Addis Ababa 2355m)
        "KG", "TJ",         // Central Asia (Kyrgyzstan, Tajikistan / Pamir)
    ]

    // MARK: - Public API

    /// Returns scene keys implied by the destination and departure date.
    /// Already-selected scenes should be filtered by the caller.
    static func inferredSceneKeys(countryCode: String, departureDate: Date) -> [String] {
        guard !countryCode.isEmpty else { return [] }

        var keys: [String] = []

        if tropicalCountries.contains(countryCode) {
            keys.append("tropical")
        }

        if alwaysColdCountries.contains(countryCode) {
            keys.append("winter")
        } else if seasonallyColdNorthernCountries.contains(countryCode) {
            let month = Calendar.current.component(.month, from: departureDate)
            if [11, 12, 1, 2].contains(month) {
                keys.append("winter")
            }
        }

        if highAltitudeCountries.contains(countryCode) {
            keys.append("high_altitude")
        }

        return keys
    }
}
