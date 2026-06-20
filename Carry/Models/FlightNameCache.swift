//
//  FlightNameCache.swift
//  Carry
//
//  Synchronous, locale-aware airline-name lookup for DISPLAY in SwiftUI bodies.
//  spec: itinerary-flight-name-localization.md
//

import Foundation

/// `AirlineDatabase` is an `actor` (async — right for fuzzy search), but a timeline list row
/// renders synchronously and can't `await`. This loads the small `airlines.json` (~225 KB) once,
/// lazily & memoised, so render-time name resolution is synchronous and correct on the first frame.
///
/// Airports use the 1.6 MB `airports.json`; those names appear only in the on-demand transport
/// detail sheet and are resolved asynchronously via `AirportDatabase.airport(forIATA:)` there — no
/// need to sync-load the big file into a list path.
///
/// Why resolve at render time instead of storing a localized name: the flight number IS the
/// airline's stable identity (`MU5801` → `MU`). Resolving the name on display makes it follow the
/// device language — including when the user changes it later; a stored fixed-language string can't.
/// Reuses `Airline` + `AirportLocale` from `AirlineDatabase.swift` / `AirportDatabase.swift`.
enum FlightNameCache {
    /// Loaded once, lazily & thread-safely (`static let` init runs exactly once). It's a bundled
    /// resource — always present in a valid build — so memoising an empty table on the (impossible)
    /// read failure is acceptable. `displayName` is read per call, so names follow the live locale.
    private static let byIATA: [String: Airline] = {
        guard let url = Bundle.main.url(forResource: "airlines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Airline].self, from: data) else {
            return [:]
        }
        return Dictionary(list.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    /// Localized airline name for a flight number (`"MU5801"` → 中国东方航空 on a zh device), or nil
    /// if the number doesn't resolve to a known 2-letter IATA airline. FLIGHT use only — callers
    /// must gate on `.flight` (a train no. like `"G403"` would falsely split to airline code `"G4"`).
    static func airlineName(forFlightNumber number: String) -> String? {
        guard let parts = FlightNumberParser.split(number) else { return nil }
        return byIATA[parts.airline.uppercased()]?.displayName
    }

    /// Carrier label for display: the localized airline name for flights (resolved from the flight
    /// number), else the stored free-text carrier — which covers non-flights, charters / unrecognized
    /// numbers, and any carrier the user typed by hand. Trimmed.
    static func displayCarrier(for segment: TransportSegment) -> String {
        if segment.mode == .flight, let name = airlineName(forFlightNumber: segment.number) {
            return name
        }
        return segment.carrier.trimmingCharacters(in: .whitespaces)
    }
}
