//
//  AppearanceMode.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - ThemeAccent

enum ThemeAccent: String, CaseIterable, Identifiable {
    case classic // 默认：黑白 chrome + 蓝色 Toggle（过渡用，确定主题色后移除特殊处理）
    case smoky   // 烟蓝 #5B7A96 ★推荐
    case sand    // 暖砂 #8A6E52
    case moss    // 苔绿 #4A7A5C
    case blue    // 天空蓝
    case teal    // 海湾青
    case amber   // 暖橙金
    case indigo  // 薰衣草紫
    case haze    // 雾霾蓝
    case sage    // 鼠尾草绿
    case dusk    // 暮紫

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smoky:   return "烟蓝"
        case .sand:    return "暖砂"
        case .moss:    return "苔绿"
        case .classic: return "默认"
        case .blue:    return "天空蓝"
        case .teal:    return "海湾青"
        case .amber:   return "暖橙金"
        case .indigo:  return "薰衣草"
        case .haze:    return "雾霾蓝"
        case .sage:    return "鼠尾草"
        case .dusk:    return "暮紫"
        }
    }

    /// Dynamic color that adapts to light/dark mode — use as .tint() value.
    var color: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkUIColor : lightUIColor
        })
    }

    /// Static swatch for preview display.
    var swatch: Color { Color(uiColor: lightUIColor) }

    private var lightUIColor: UIColor {
        switch self {
        case .smoky:   return UIColor(red: 0.357, green: 0.478, blue: 0.588, alpha: 1) // #5B7A96
        case .sand:    return UIColor(red: 0.541, green: 0.431, blue: 0.322, alpha: 1) // #8A6E52
        case .moss:    return UIColor(red: 0.290, green: 0.478, blue: 0.361, alpha: 1) // #4A7A5C
        case .classic: return .label
        case .blue:    return UIColor(red: 0.180, green: 0.557, blue: 0.831, alpha: 1) // #2E8ED4
        case .teal:    return UIColor(red: 0.165, green: 0.627, blue: 0.565, alpha: 1) // #2AA090
        case .amber:   return UIColor(red: 0.851, green: 0.471, blue: 0.157, alpha: 1) // #D97828
        case .indigo:  return UIColor(red: 0.400, green: 0.329, blue: 0.839, alpha: 1) // #6654D6
        case .haze:    return UIColor(red: 0.243, green: 0.431, blue: 0.588, alpha: 1) // #3E6E96
        case .sage:    return UIColor(red: 0.180, green: 0.478, blue: 0.369, alpha: 1) // #2E7A5E
        case .dusk:    return UIColor(red: 0.384, green: 0.314, blue: 0.627, alpha: 1) // #6250A0
        }
    }

    private var darkUIColor: UIColor {
        switch self {
        case .smoky:   return UIColor(red: 0.478, green: 0.612, blue: 0.722, alpha: 1) // #7A9CB8
        case .sand:    return UIColor(red: 0.651, green: 0.533, blue: 0.408, alpha: 1) // #A68868
        case .moss:    return UIColor(red: 0.369, green: 0.604, blue: 0.455, alpha: 1) // #5E9A74
        case .classic: return .label
        case .blue:    return UIColor(red: 0.314, green: 0.659, blue: 0.910, alpha: 1) // #50A8E8
        case .teal:    return UIColor(red: 0.235, green: 0.737, blue: 0.651, alpha: 1) // #3CBCA6
        case .amber:   return UIColor(red: 0.941, green: 0.549, blue: 0.235, alpha: 1) // #F08C3C
        case .indigo:  return UIColor(red: 0.502, green: 0.439, blue: 0.894, alpha: 1) // #8070E4
        case .haze:    return UIColor(red: 0.353, green: 0.549, blue: 0.722, alpha: 1) // #5A8CB8
        case .sage:    return UIColor(red: 0.290, green: 0.604, blue: 0.455, alpha: 1) // #4A9A74
        case .dusk:    return UIColor(red: 0.502, green: 0.400, blue: 0.753, alpha: 1) // #8066C0
        }
    }
}

// MARK: - Toggle Tint EnvironmentKey
// classic 模式下 Toggle 单独用系统蓝，其余颜色继承全局 tint。
// 确定主题色后删除此 key 及相关 @Environment 注入即可。

private struct ToggleTintKey: EnvironmentKey {
    static let defaultValue: Color = Color(.systemBlue)
}

extension EnvironmentValues {
    var toggleTint: Color {
        get { self[ToggleTintKey.self] }
        set { self[ToggleTintKey.self] = newValue }
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
