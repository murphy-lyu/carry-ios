//
//  AppearanceMode.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - CarryAccent

/// The app's single accent colour — "烟蓝" (smoky blue), adapting to light/dark.
/// Applied once globally via `.tint(CarryAccent.color)`; everything reading `Color.accentColor`
/// (FAB, progress, toggles, selected states, date picker, …) inherits it.
enum CarryAccent {
    /// Dynamic UIColor — also set as the UIWindow tint so UIKit-presented system UI
    /// (confirmationDialogs, alerts, context menus) matches the SwiftUI `.tint()`.
    static let uiColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.478, green: 0.612, blue: 0.722, alpha: 1)   // #7A9CB8 (dark)
            : UIColor(red: 0.357, green: 0.478, blue: 0.588, alpha: 1)   // #5B7A96 (light)
    }
    static let color = Color(uiColor)
}

// MARK: - ItineraryDayPalette

/// Per-day colours for itinerary route planning (map pins + routes + timeline nodes).
/// This is a DELIBERATE, scoped exception to the single-accent rule (see decisions.md 2026-06-13):
/// a multi-day route drawn in one accent is an unreadable tangle, so each day gets a distinct,
/// dark-mode-adaptive hue. A warm, sunny "going on a trip" palette. Day 1 leads with palm green
/// (chosen for the going-out mood, by request — brand continuity at Day 1 was deliberately
/// dropped); the brand smoky blue moves to Day 3. Used ONLY by itinerary planning — nowhere else
/// may introduce non-accent colours.
///
/// 7 colours, cycled by `sortOrder % 7` (see decisions.md 2026-06-20). The hues are spread right
/// around the wheel — blue / orange / green / violet / raspberry / teal / terracotta — so every day
/// reads as a clearly different colour name (an earlier warm-only set had three look-alike pinks).
/// Day 1 leads with the brand smoky blue (CarryAccent); green sits at Day 3.
/// The order is solved (CIEDE2000 over both light & dark): all 7 are mutually distinct (min ΔE ≈
/// 14.7) and the order maximises adjacent-day separation (worst neighbour ΔE ≈ 20). With N=7 the
/// 5-day window can't hide any pair, so the floor IS the global min — keep all 7 well apart.
///
/// NOTE on legibility: some hues are light enough to fall below WCAG 3:1 on white. Foreground marks
/// must therefore NOT assume the colour is dark — e.g. map-pin numbers use `Color.legibleInk`
/// (adaptive dark/white) instead of hard-coded white. Do NOT "fix" contrast by darkening the
/// palette: light values carry the separation (deepening collapses ΔE — tried, failed).
/// Re-run `scripts/itinerary-day-palette-solve.py` to re-verify before any change.
enum ItineraryDayPalette {
    private static let palette: [UIColor] = [
        CarryAccent.uiColor,                                                   // 0 · Day 1 — 烟蓝 smoky blue (brand)
        adaptive(light: (0.863, 0.549, 0.235), dark: (0.910, 0.659, 0.404)),  // 1 · Day 2 — 万寿菊 marigold
        adaptive(light: (0.455, 0.675, 0.333), dark: (0.573, 0.757, 0.475)),  // 2 · Day 3 — 棕榈绿 palm green
        adaptive(light: (0.561, 0.420, 0.733), dark: (0.675, 0.561, 0.812)),  // 3 · Day 4 — 雪青 amethyst
        adaptive(light: (0.780, 0.314, 0.431), dark: (0.859, 0.471, 0.569)),  // 4 · Day 5 — 覆盆子 raspberry
        adaptive(light: (0.176, 0.659, 0.620), dark: (0.357, 0.745, 0.706)),  // 5 · Day 6 — 青绿 teal
        adaptive(light: (0.773, 0.420, 0.290), dark: (0.855, 0.549, 0.451)),  // 6 · Day 7 — 赤陶 clay
    ]

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat),
                                 dark: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    /// Stable colour for a day by its 0-based `sortOrder`; cycles for trips longer than the palette.
    static func uiColor(forDayIndex index: Int) -> UIColor {
        palette[((index % palette.count) + palette.count) % palette.count]
    }

    static func color(forDayIndex index: Int) -> Color {
        Color(uiColor(forDayIndex: index))
    }
}

// MARK: - Legible label colour

extension Color {
    /// A high-contrast label colour (near-white or near-black) for text/symbols drawn ON TOP of
    /// `self` — e.g. the number on a map pin whose fill is a day colour. Resolves per appearance,
    /// so it flips correctly when the fill has light/dark variants. Picks by WCAG luminance: the
    /// white↔black crossover sits at L≈0.18; the 0.20 threshold biases toward dark ink on the
    /// lighter, cheerful day hues (coral, blush, marigold…) where hard-coded white would vanish.
    var legibleInk: Color {
        Color(UIColor { traits in
            let resolved = UIColor(self).resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let luminance = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
            return luminance > 0.20 ? UIColor(white: 0.13, alpha: 1) : .white
        })
    }
}

// MARK: - AppearanceMode

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: return "appearance.system"
        case .light:  return "appearance.light"
        case .dark:   return "appearance.dark"
        }
    }
}
