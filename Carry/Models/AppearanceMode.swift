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
