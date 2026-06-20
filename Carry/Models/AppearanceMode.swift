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
/// dark-mode-adaptive hue. Day 1 keeps the brand smoky blue (CarryAccent) for continuity;
/// the rest cycle through a warm, sunny "going on a trip" palette. Used ONLY by itinerary
/// planning — nowhere else may introduce non-accent colours.
///
/// 10 colours, cycled by `sortOrder % 10` (see decisions.md 2026-06-20). Warm-dominant (7 warm +
/// sea-teal/palm-green reliefs + brand blue) for a cheerful, vacation feel — a pure-warm set was
/// tried and rejected (warm hues span too little of the wheel, ΔE collapsed to ~8).
/// The ORDER is solved, not arbitrary: a CIEDE2000 search (over both light & dark) arranges the
/// hues so ANY 5 consecutive days are mutually distinct (guaranteed min ΔE ≈ 12.5), so long trips
/// (15, 31, …) never place look-alike colours near each other. The front 7 carry 6 distinct hue
/// families (near-duplicate pinks/golds pushed to days 8–10); palm green sits at Day 3 by request.
/// Do NOT reorder or add colours casually — re-run `scripts/itinerary-day-palette-solve.py` to
/// re-verify the 5-day-window guarantee first.
enum ItineraryDayPalette {
    private static let palette: [UIColor] = [
        CarryAccent.uiColor,                                                   // 0 · Day 1 — 烟蓝 smoky blue (brand)
        adaptive(light: (0.878, 0.478, 0.373), dark: (0.910, 0.596, 0.510)),  // 1 · 珊瑚 coral
        adaptive(light: (0.455, 0.675, 0.333), dark: (0.573, 0.757, 0.475)),  // 2 · 棕榈绿 palm green
        adaptive(light: (0.820, 0.580, 0.310), dark: (0.882, 0.682, 0.451)),  // 3 · 焦糖 caramel
        adaptive(light: (0.745, 0.412, 0.471), dark: (0.831, 0.541, 0.592)),  // 4 · 豆沙玫 rosewood
        adaptive(light: (0.239, 0.639, 0.604), dark: (0.404, 0.737, 0.706)),  // 5 · 海蓝绿 lagoon teal
        adaptive(light: (0.792, 0.451, 0.337), dark: (0.859, 0.565, 0.461)),  // 6 · 赤陶 clay
        adaptive(light: (0.925, 0.651, 0.690), dark: (0.949, 0.733, 0.761)),  // 7 · 胭脂粉 blush pink
        adaptive(light: (0.863, 0.549, 0.235), dark: (0.910, 0.659, 0.404)),  // 8 · 万寿菊 marigold
        adaptive(light: (0.760, 0.345, 0.420), dark: (0.835, 0.482, 0.553)),  // 9 · 浆果红 berry
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
