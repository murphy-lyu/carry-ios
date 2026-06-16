//
//  CurrencyCatalog.swift
//  Carry
//

import Foundation

// MARK: - CurrencyInfo

struct CurrencyInfo {
    /// ISO 4217 currency code, e.g. "JPY"
    let code: String
    /// Common symbol, e.g. "¥"
    let symbol: String
}

// MARK: - CurrencyCatalog

/// Static country-code → currency lookup.
/// Displays code + symbol only. Full localised names deferred to a future update
/// (can be automated via Locale rather than manual xcstrings maintenance).
/// Coverage: ~110 common travel destinations.
enum CurrencyCatalog {
    static func info(for countryCode: String) -> CurrencyInfo? {
        return catalog[countryCode.uppercased()]
    }

    /// Returns de-duplicated currency infos for a list of country codes.
    static func merged(for countryCodes: [String]) -> [CurrencyInfo] {
        var seen = Set<String>()
        return countryCodes
            .compactMap { catalog[$0.uppercased()] }
            .filter { seen.insert($0.code).inserted }
    }

    // MARK: - Code → symbol (reverse map)

    /// ISO 4217 code（大写）→ 符号，由 catalog 反查去重得到。catalog 未覆盖的币种
    /// 回退到 NumberFormatter / code 本身（见 `symbol(for:)`）。
    static let symbolByCode: [String: String] = {
        var map: [String: String] = [:]
        for info in catalog.values where map[info.code] == nil {
            map[info.code] = info.symbol
        }
        return map
    }()

    // MARK: - 展示助手（spec: itinerary-cost-tracking.md）。币种名走 `Locale`，不进 xcstrings。

    /// 设备 locale 推导的默认本位币；取不到回退 USD。
    static var deviceDefaultCode: String {
        Locale.current.currency?.identifier.uppercased() ?? "USD"
    }

    /// 当前本位币（用户选定 / 未选则设备默认）。读 UserDefaults，任意线程可用。
    static var homeCurrencyCode: String {
        let raw = UserDefaults.standard.string(forKey: ExchangeRateManager.preferredCurrencyDefaultsKey) ?? ""
        return raw.isEmpty ? deviceDefaultCode : raw.uppercased()
    }

    /// 金额 → 录入框文本：整数不带小数（"1280"），否则原样（"12.5"）。
    static func amountText(_ amount: Double) -> String {
        amount == amount.rounded() ? String(Int(amount)) : String(amount)
    }

    /// 全部可选币种（ISO 4217 常用码），按当前 locale 的本地化名排序。
    /// 缓存为 `static let`：~150 项排序只算一次，避免选择器搜索时每次按键重排（locale 单次启动内稳定）。
    static let allCodes: [String] = Locale.commonISOCurrencyCodes
        .map { $0.uppercased() }
        .sorted { localizedName(for: $0).localizedCaseInsensitiveCompare(localizedName(for: $1)) == .orderedAscending }

    /// locale 感知地解析金额输入框文本 → Double。`decimalPad` 在逗号小数 locale 下显示逗号，
    /// `Double("12,5")` 会得 nil → 必须用 NumberFormatter；再兜底把逗号当小数点。空/非法 → 0。
    static func parseAmount(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale.current
        if let n = f.number(from: trimmed) { return n.doubleValue }
        return Double(trimmed.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// 金额输入净化（locale 感知）：只保留数字 + 单一**小数点**（当前 locale 的）+ 至多 2 位小数；
    /// 其它字符（字母/符号/空格/分组符）一律丢弃。这是「编辑态」的规范形（无千分位分组）。
    /// 在数据层兜住——硬件键盘（模拟器）、粘贴、异常 locale 都进不来非法字符（而非只靠
    /// `.decimalPad` 的软键盘约束）。幂等。
    static func sanitizeAmountInput(_ text: String) -> String {
        let sep: Character = (Locale.current.decimalSeparator ?? ".").first ?? "."
        var out = ""
        var hasSep = false
        var fractionDigits = 0
        for ch in text {
            if ch.isASCII && ch.isNumber {
                if hasSep {
                    guard fractionDigits < 2 else { continue }   // 限 2 位小数
                    fractionDigits += 1
                }
                out.append(ch)
            } else if ch == sep {               // 仅当前 locale 的小数点；分组符与其它一律丢
                guard !hasSep else { continue } // 只允许一个
                if out.isEmpty { out.append("0") }   // 前导小数点 → "0."
                out.append(sep)
                hasSep = true
            }
        }
        return out
    }

    /// 「展示态」：给规范金额串加千分位分组（如 "1234.5" → "1,234.5"）。整数部分手动分组、
    /// 原样保留用户输入的小数位（不强制补/截尾），失焦时用于展示；聚焦编辑时退回 `sanitizeAmountInput`。
    static func groupForDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let sep = String((Locale.current.decimalSeparator ?? ".").first ?? ".")
        let groupSep = Locale.current.groupingSeparator ?? ","
        let parts = trimmed.components(separatedBy: sep)
        let intDigits = Array(parts[0].filter { $0.isASCII && $0.isNumber })
        var grouped = ""
        let n = intDigits.count
        for (i, ch) in intDigits.enumerated() {
            if i > 0 && (n - i) % 3 == 0 { grouped += groupSep }
            grouped.append(ch)
        }
        if grouped.isEmpty { grouped = "0" }     // ".5" → "0.5"
        return parts.count > 1 ? grouped + sep + parts[1] : grouped
    }

    /// 币种本地化名（"日元" / "Japanese Yen"）；取不到回退 code。
    static func localizedName(for code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code.uppercased()) ?? code.uppercased()
    }

    /// 币种符号。先查 catalog 反查表，再退 NumberFormatter，最后退 code 本身。
    static func symbol(for code: String) -> String {
        let upper = code.uppercased()
        if let s = CurrencyCatalog.symbolByCode[upper] { return s }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = upper
        if let s = f.currencySymbol, s != upper { return s }
        return upper
    }

    /// 把金额按指定币种格式化（符号 + 分组），如 "¥1,280" / "JPY 50,000"。
    /// 整数金额不显示小数位；非整数显示 2 位。
    static func format(_ amount: Double, code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code.uppercased()
        f.locale = Locale.current
        let isWhole = amount.rounded() == amount
        f.maximumFractionDigits = isWhole ? 0 : 2
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: amount)) ?? "\(symbol(for: code))\(Int(amount))"
    }

    // MARK: - Data

    private static let catalog: [String: CurrencyInfo] = [

        // ── East Asia ──────────────────────────────────────────────────────────
        "CN": CurrencyInfo(code: "CNY", symbol: "¥"),
        "JP": CurrencyInfo(code: "JPY", symbol: "¥"),
        "KR": CurrencyInfo(code: "KRW", symbol: "₩"),
        "TW": CurrencyInfo(code: "TWD", symbol: "NT$"),
        "HK": CurrencyInfo(code: "HKD", symbol: "HK$"),
        "MO": CurrencyInfo(code: "MOP", symbol: "MOP$"),
        "MN": CurrencyInfo(code: "MNT", symbol: "₮"),

        // ── Southeast Asia ─────────────────────────────────────────────────────
        "TH": CurrencyInfo(code: "THB", symbol: "฿"),
        "VN": CurrencyInfo(code: "VND", symbol: "₫"),
        "SG": CurrencyInfo(code: "SGD", symbol: "S$"),
        "MY": CurrencyInfo(code: "MYR", symbol: "RM"),
        "ID": CurrencyInfo(code: "IDR", symbol: "Rp"),
        "PH": CurrencyInfo(code: "PHP", symbol: "₱"),
        "BN": CurrencyInfo(code: "BND", symbol: "B$"),
        "KH": CurrencyInfo(code: "KHR", symbol: "៛"),
        "LA": CurrencyInfo(code: "LAK", symbol: "₭"),
        "MM": CurrencyInfo(code: "MMK", symbol: "K"),

        // ── South Asia ─────────────────────────────────────────────────────────
        "IN": CurrencyInfo(code: "INR",  symbol: "₹"),
        "LK": CurrencyInfo(code: "LKR",  symbol: "Rs"),
        "NP": CurrencyInfo(code: "NPR",  symbol: "Rs"),
        "PK": CurrencyInfo(code: "PKR",  symbol: "Rs"),
        "BD": CurrencyInfo(code: "BDT",  symbol: "৳"),
        "BT": CurrencyInfo(code: "BTN",  symbol: "Nu"),
        "MV": CurrencyInfo(code: "MVR",  symbol: "Rf"),

        // ── Middle East ────────────────────────────────────────────────────────
        "AE": CurrencyInfo(code: "AED", symbol: "د.إ"),
        "SA": CurrencyInfo(code: "SAR", symbol: "﷼"),
        "QA": CurrencyInfo(code: "QAR", symbol: "﷼"),
        "KW": CurrencyInfo(code: "KWD", symbol: "د.ك"),
        "BH": CurrencyInfo(code: "BHD", symbol: ".د.ب"),
        "OM": CurrencyInfo(code: "OMR", symbol: "﷼"),
        "JO": CurrencyInfo(code: "JOD", symbol: "JD"),
        "IL": CurrencyInfo(code: "ILS", symbol: "₪"),
        "TR": CurrencyInfo(code: "TRY", symbol: "₺"),

        // ── Central Asia ───────────────────────────────────────────────────────
        "KZ": CurrencyInfo(code: "KZT", symbol: "₸"),
        "KG": CurrencyInfo(code: "KGS", symbol: "с"),
        "TJ": CurrencyInfo(code: "TJS", symbol: "SM"),
        "UZ": CurrencyInfo(code: "UZS", symbol: "so'm"),

        // ── Eurozone ───────────────────────────────────────────────────────────
        "FR": CurrencyInfo(code: "EUR", symbol: "€"),
        "DE": CurrencyInfo(code: "EUR", symbol: "€"),
        "IT": CurrencyInfo(code: "EUR", symbol: "€"),
        "ES": CurrencyInfo(code: "EUR", symbol: "€"),
        "PT": CurrencyInfo(code: "EUR", symbol: "€"),
        "NL": CurrencyInfo(code: "EUR", symbol: "€"),
        "BE": CurrencyInfo(code: "EUR", symbol: "€"),
        "AT": CurrencyInfo(code: "EUR", symbol: "€"),
        "LU": CurrencyInfo(code: "EUR", symbol: "€"),
        "SE": CurrencyInfo(code: "SEK", symbol: "kr"),
        "FI": CurrencyInfo(code: "EUR", symbol: "€"),
        "GR": CurrencyInfo(code: "EUR", symbol: "€"),
        "IE": CurrencyInfo(code: "EUR", symbol: "€"),
        "SI": CurrencyInfo(code: "EUR", symbol: "€"),
        "SK": CurrencyInfo(code: "EUR", symbol: "€"),
        "EE": CurrencyInfo(code: "EUR", symbol: "€"),
        "LV": CurrencyInfo(code: "EUR", symbol: "€"),
        "LT": CurrencyInfo(code: "EUR", symbol: "€"),
        "HR": CurrencyInfo(code: "EUR", symbol: "€"),

        // ── Non-Eurozone Europe ────────────────────────────────────────────────
        "GB": CurrencyInfo(code: "GBP", symbol: "£"),
        "CH": CurrencyInfo(code: "CHF", symbol: "Fr"),
        "NO": CurrencyInfo(code: "NOK", symbol: "kr"),
        "DK": CurrencyInfo(code: "DKK", symbol: "kr"),
        "IS": CurrencyInfo(code: "ISK", symbol: "kr"),
        "PL": CurrencyInfo(code: "PLN", symbol: "zł"),
        "CZ": CurrencyInfo(code: "CZK", symbol: "Kč"),
        "HU": CurrencyInfo(code: "HUF", symbol: "Ft"),
        "RO": CurrencyInfo(code: "RON", symbol: "lei"),
        "BG": CurrencyInfo(code: "BGN", symbol: "лв"),
        "RS": CurrencyInfo(code: "RSD", symbol: "din"),
        "UA": CurrencyInfo(code: "UAH", symbol: "₴"),
        "BY": CurrencyInfo(code: "BYN", symbol: "Br"),

        // ── Russia ─────────────────────────────────────────────────────────────
        "RU": CurrencyInfo(code: "RUB", symbol: "₽"),

        // ── North America ──────────────────────────────────────────────────────
        "US": CurrencyInfo(code: "USD", symbol: "$"),
        "CA": CurrencyInfo(code: "CAD", symbol: "CA$"),
        "MX": CurrencyInfo(code: "MXN", symbol: "$"),

        // ── Central America & Caribbean ────────────────────────────────────────
        "CR": CurrencyInfo(code: "CRC", symbol: "₡"),
        "PA": CurrencyInfo(code: "PAB", symbol: "B/."),
        "GT": CurrencyInfo(code: "GTQ", symbol: "Q"),
        "BZ": CurrencyInfo(code: "BZD", symbol: "BZ$"),
        "CU": CurrencyInfo(code: "CUP", symbol: "$"),
        "DO": CurrencyInfo(code: "DOP", symbol: "RD$"),
        "JM": CurrencyInfo(code: "JMD", symbol: "J$"),
        "BS": CurrencyInfo(code: "BSD", symbol: "B$"),
        "BB": CurrencyInfo(code: "BBD", symbol: "Bds$"),
        "TT": CurrencyInfo(code: "TTD", symbol: "TT$"),

        // ── South America ──────────────────────────────────────────────────────
        "BR": CurrencyInfo(code: "BRL", symbol: "R$"),
        "AR": CurrencyInfo(code: "ARS", symbol: "$"),
        "CL": CurrencyInfo(code: "CLP", symbol: "$"),
        "CO": CurrencyInfo(code: "COP", symbol: "$"),
        "PE": CurrencyInfo(code: "PEN", symbol: "S/."),
        "EC": CurrencyInfo(code: "USD", symbol: "$"),
        "BO": CurrencyInfo(code: "BOB", symbol: "Bs."),
        "UY": CurrencyInfo(code: "UYU", symbol: "$U"),

        // ── Oceania ────────────────────────────────────────────────────────────
        "AU": CurrencyInfo(code: "AUD", symbol: "A$"),
        "NZ": CurrencyInfo(code: "NZD", symbol: "NZ$"),
        "FJ": CurrencyInfo(code: "FJD", symbol: "FJ$"),
        "PF": CurrencyInfo(code: "XPF", symbol: "Fr"),

        // ── Africa ─────────────────────────────────────────────────────────────
        "ZA": CurrencyInfo(code: "ZAR", symbol: "R"),
        "EG": CurrencyInfo(code: "EGP", symbol: "£"),
        "MA": CurrencyInfo(code: "MAD", symbol: "د.م."),
        "TN": CurrencyInfo(code: "TND", symbol: "DT"),
        "KE": CurrencyInfo(code: "KES", symbol: "KSh"),
        "TZ": CurrencyInfo(code: "TZS", symbol: "TSh"),
        "ET": CurrencyInfo(code: "ETB", symbol: "Br"),
        "GH": CurrencyInfo(code: "GHS", symbol: "₵"),
        "NG": CurrencyInfo(code: "NGN", symbol: "₦"),
        "MU": CurrencyInfo(code: "MUR", symbol: "Rs"),
        "SC": CurrencyInfo(code: "SCR", symbol: "Rs"),
        "MG": CurrencyInfo(code: "MGA", symbol: "Ar"),
        "CV": CurrencyInfo(code: "CVE", symbol: "$"),
    ]
}
