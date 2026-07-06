import Foundation

/// 航站楼「是否需要数字前缀」判断：仅航班、且值以数字开头时需要加「T」前缀（2 → T2，国际通用记法）。
/// 其余交通方式（火车站台等字母开头，如 "A" / 已带 "T2"）不需要、应原样显示。
///
/// 只共享判断逻辑、不共享本地化文案——Widget target 用自己的 `CarryWidget/Localizable.xcstrings`
/// （key `widget.transit.terminal_prefix`），主 App 用 `Carry/Localizable.xcstrings`
/// （key `itinerary.transport.field.terminal_prefix`），两边本地化表不互通（Widget 本地化约定），
/// 若在这里直接做 `String(localized:)` 查找会在其中一个 target 里查不到 key。
/// 主 App（`TransportDetailView`/`ItineraryView`）与 Widget（`CarryWidgetLiveActivity`）
/// 均按 `TransportMode.rawValue` 字符串比较——Widget target 拿不到主 App 的 `TransportMode` enum，
/// 但两边都能引用 `SharedSources/`，故以 rawValue 而非 enum 类型作为跨 target 的公共接口。
enum TransportModeDisplay {
    /// 返回需要加前缀的裁剪后数字值；返回 nil 表示不需要前缀，调用方应显示裁剪后的原值。
    static func numericTerminalNeedingPrefix(modeRaw: String, rawTerminal: String) -> String? {
        let t = rawTerminal.trimmingCharacters(in: .whitespaces)
        guard modeRaw == "flight", let first = t.first, first.isNumber else { return nil }
        return t
    }
}
