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

    /// 全 app 共享单例：费用录入快照、Trip Book 折算、目的地汇率屏共用同一份缓存与本位币口径。
    static let shared = ExchangeRateManager()

    /// 本位币 UserDefaults key（与设置页 `@AppStorage` 同名，单一真源）。
    static let preferredCurrencyDefaultsKey = "preferred_currency_code"

    // MARK: Published

    /// Rates keyed by lowercase ISO 4217 code (e.g. "jpy": 149.8).
    /// Base currency is `baseCurrencyCode`. Empty until first successful fetch.
    @Published private(set) var rates: [String: Double] = [:]

    /// 当前本位币（大写 ISO 4217）。改设置后经 `refreshBaseCurrency()` 同步。
    @Published private(set) var baseCurrencyCode: String

    // MARK: Private

    private let defaults = UserDefaults.standard
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 读「用户选定本位币」；未设则回退设备 locale 默认。
    private static func resolveBaseCurrency() -> String {
        if let stored = UserDefaults.standard.string(forKey: preferredCurrencyDefaultsKey),
           !stored.isEmpty {
            return stored.uppercased()
        }
        return CurrencyCatalog.deviceDefaultCode
    }

    // MARK: - Init

    init() {
        self.baseCurrencyCode = Self.resolveBaseCurrency()
        loadCachedRates()
    }

    // MARK: - Base currency

    /// 用户在设置里改了本位币后调用：若确有变化，切换 base、清空当前 rates 并重新按新 base 拉取。
    /// 返回是否真的变了（供调用方决定要不要重算费用快照）。
    @discardableResult
    func refreshBaseCurrency() -> Bool {
        let resolved = Self.resolveBaseCurrency()
        guard resolved != baseCurrencyCode else { return false }
        baseCurrencyCode = resolved
        rates = [:]
        loadCachedRates()          // 命中新 base 当日缓存则即时可用；否则由调用方 fetchNow()
        return true
    }

    /// 强制按当前 base 拉一次汇率（无视缓存是否为空）。改本位币后用它确保新 base 的 rates 就绪再重算快照。
    func fetchNow() async {
        await fetchRates()
    }

    /// 把 `amount`（`code` 币种）折算成本位币。rate 不可得返回 nil（调用方决定兜底 / 排除）。
    /// rates[dest] = 1 本位币可兑多少 dest → 1 dest = 1/rates[dest] 本位币。
    func convertToHome(_ amount: Double, from code: String) -> Double? {
        let upper = code.uppercased()
        if upper == baseCurrencyCode { return amount }
        guard let rate = rates[upper.lowercased()], rate > 0 else { return nil }
        return amount / rate
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
            else {
                CarryLogger.shared.log(.exchangeRateFetchFailed, context: "base=\(base) reason=parse")
                return
            }
            rates = ratesDict
            cacheRates(ratesDict)
        } catch {
            // 目的地汇率卡降级为只显 code+符号；费用折算退快照/标注未计入。埋点便于回收失败率。
            CarryLogger.shared.log(.exchangeRateFetchFailed, context: "base=\(base) reason=network")
        }
    }

    // MARK: - Helpers

    private static func todayString() -> String {
        dateFormatter.string(from: Date())
    }
}
