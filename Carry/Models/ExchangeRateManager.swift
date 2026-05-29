//
//  ExchangeRateManager.swift
//  Carry
//
//  Data source: https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest
//  Free, no API key, updated daily, no rate limits.
//

import Foundation
import Combine

// MARK: - ExchangeRateManager

@MainActor
final class ExchangeRateManager: ObservableObject {

    // MARK: Published

    /// Rates keyed by lowercase ISO 4217 code (e.g. "jpy": 149.8).
    /// Base currency is `baseCurrencyCode`. Empty until first successful fetch.
    @Published private(set) var rates: [String: Double] = [:]

    // MARK: Properties

    /// Uppercase code of the device's home currency, e.g. "USD", "CNY".
    let baseCurrencyCode: String

    // MARK: Private

    private let defaults = UserDefaults.standard
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Init

    init() {
        // Derive home currency from device locale; fall back to USD
        self.baseCurrencyCode = Locale.current.currency?.identifier.uppercased() ?? "USD"
        loadCachedRates()
    }

    // MARK: - Public API

    /// Returns a display-ready rate string for the given destination currency,
    /// e.g. "149.8" when base=USD and destination=JPY.
    /// Returns nil when rate is unavailable or base == destination.
    func formattedRate(for destinationCode: String) -> String? {
        let dest = destinationCode.lowercased()
        let base = baseCurrencyCode.lowercased()
        guard dest != base, let rate = rates[dest] else { return nil }

        switch rate {
        case 100...:   return String(format: "%.0f", rate)
        case 10...:    return String(format: "%.1f", rate)
        case 1...:     return String(format: "%.2f", rate)
        default:       return String(format: "%.4f", rate)
        }
    }

    /// Triggers a network fetch if today's rates aren't cached yet.
    func fetchIfNeeded() {
        guard rates.isEmpty else { return }   // already loaded from cache
        Task { await fetchRates() }
    }

    // MARK: - Cache

    private func cacheKey(for date: String) -> String {
        "carry_exrates_\(baseCurrencyCode.lowercased())_\(date)"
    }

    private func loadCachedRates() {
        let today = Self.todayString()
        guard
            let json = defaults.string(forKey: cacheKey(for: today)),
            let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return }
        rates = parsed
    }

    private func cacheRates(_ newRates: [String: Double]) {
        let today = Self.todayString()
        guard
            let data = try? JSONSerialization.data(withJSONObject: newRates),
            let json = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(json, forKey: cacheKey(for: today))
        pruneOldCache(keepDate: today)
    }

    /// Removes stale cache entries to avoid UserDefaults bloat.
    private func pruneOldCache(keepDate: String) {
        let prefix = "carry_exrates_\(baseCurrencyCode.lowercased())_"
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) && !$0.hasSuffix(keepDate) }
            .forEach { defaults.removeObject(forKey: $0) }
    }

    // MARK: - Network

    private func fetchRates() async {
        let base = baseCurrencyCode.lowercased()
        let urlString = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/\(base).json"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ratesDict = json[base] as? [String: Double]
            else { return }
            rates = ratesDict
            cacheRates(ratesDict)
        } catch {
            // Fail silently — currency card degrades to showing code + symbol only
        }
    }

    // MARK: - Helpers

    private static func todayString() -> String {
        dateFormatter.string(from: Date())
    }
}
