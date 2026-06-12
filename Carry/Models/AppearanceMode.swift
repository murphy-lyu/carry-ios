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
/// muted, dark-mode-adaptive hue. Day 1 keeps the brand smoky blue (CarryAccent) for continuity;
/// the rest cycle through a restrained palette. Used ONLY by itinerary planning — nowhere else
/// may introduce non-accent colours.
enum ItineraryDayPalette {
    private static let palette: [UIColor] = [
        CarryAccent.uiColor,                                                   // Day 1 — 烟蓝 (brand)
        adaptive(light: (0.710, 0.443, 0.353), dark: (0.788, 0.557, 0.471)),  // 陶土 terracotta
        adaptive(light: (0.369, 0.541, 0.431), dark: (0.486, 0.659, 0.549)),  // 鼠尾草绿 sage
        adaptive(light: (0.541, 0.416, 0.576), dark: (0.663, 0.553, 0.694)),  // 梅紫 plum
        adaptive(light: (0.690, 0.537, 0.290), dark: (0.788, 0.659, 0.416)),  // 赭黄 ochre
        adaptive(light: (0.369, 0.420, 0.588), dark: (0.510, 0.565, 0.722)),  // 暮蓝 slate indigo
        adaptive(light: (0.690, 0.416, 0.510), dark: (0.788, 0.553, 0.627)),  // 玫灰 dusty rose
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
