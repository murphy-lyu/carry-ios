//
//  WeatherPackingSignals.swift
//  Carry
//
//  天气感知打包建议的「信号引擎」（spec: weather-aware-packing.md）。
//  纯逻辑：把行程窗口内的真实预报（DayWeatherInfo）提炼成离散信号，再映射到
//  现有 SceneItemMap 的场景（rainy_city / winter / tropical），物品复用场景库、不新建。
//  例外驱动：只产出「未被已选/气候推断覆盖」的场景，避免重复打扰（见 notableSceneKeys）。
//

import Foundation

/// 行程窗口内值得提醒的天气信号。
enum WeatherSignal: String, CaseIterable {
    case rain        // 有雨（含雷暴/雨夹雪）或高降水概率
    case snow        // 有雪
    case heat        // 高温
    case cold        // 低温
    case bigSwing    // 早晚温差大
}

enum WeatherPackingSignals {

    // MARK: 阈值（初值——上线前按真机校准，spec 开放问题①）

    /// 高温：任一天高温 ≥ 此值（℃）
    static let heatHighC: Double = 32
    /// 低温：任一天低温 ≤ 此值（℃）
    static let coldLowC: Double = 5
    /// 降水：任一天降水概率 ≥ 此值（0...1），即便天气状况未直接判为雨
    static let rainChance: Double = 0.6
    /// 温差：窗口内 max(高温) − min(低温) ≥ 此值（℃）
    static let swingC: Double = 12

    // MARK: 信号提炼

    /// 从行程那几天的预报提炼显著信号。空预报 → 空集（优雅降级）。
    static func signals(for days: [DayWeatherInfo]) -> Set<WeatherSignal> {
        guard !days.isEmpty else { return [] }
        var result: Set<WeatherSignal> = []

        if days.contains(where: { isRainy($0) }) { result.insert(.rain) }
        if days.contains(where: { $0.category == .snow }) { result.insert(.snow) }
        if days.contains(where: { $0.highC >= heatHighC }) { result.insert(.heat) }
        if days.contains(where: { $0.lowC <= coldLowC }) { result.insert(.cold) }

        if let hi = days.map(\.highC).max(), let lo = days.map(\.lowC).min(),
           hi - lo >= swingC {
            result.insert(.bigSwing)
        }
        return result
    }

    private static func isRainy(_ day: DayWeatherInfo) -> Bool {
        switch day.category {
        case .rain, .storm, .sleet: return true
        default: return day.precipChance >= rainChance
        }
    }

    // MARK: 信号 → 场景（复用 SceneItemMap 的场景键）

    /// 单个信号映射到的现有场景键；无对应场景的信号返回 nil。
    /// `bigSwing` 暂不映射独立场景（保留给将来「多带一件外套」的单品建议），返回 nil。
    static func sceneKey(for signal: WeatherSignal) -> String? {
        switch signal {
        case .rain:     return "rainy_city"
        case .snow:     return "winter"
        case .cold:     return "winter"
        case .heat:     return "tropical"
        case .bigSwing: return nil
        }
    }

    /// 值得提醒的场景键：信号 → 场景，去重，并**剔除已被覆盖的场景**
    /// （`alreadyCovered` = 用户已选场景 ∪ ClimateInference 已推断场景）。
    /// 顺序固定（rain → winter → tropical），便于呈现稳定。
    static func notableSceneKeys(days: [DayWeatherInfo], alreadyCovered: Set<String>) -> [String] {
        let signals = signals(for: days)
        let ordered: [WeatherSignal] = [.rain, .snow, .cold, .heat]   // 决定输出先后；snow/cold 同映 winter，自然去重
        var seen = Set<String>()
        var result: [String] = []
        for s in ordered where signals.contains(s) {
            guard let key = sceneKey(for: s) else { continue }
            guard !alreadyCovered.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(key)
        }
        return result
    }
}
