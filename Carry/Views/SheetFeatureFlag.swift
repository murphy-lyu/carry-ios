//
//  SheetFeatureFlag.swift
//  Carry
//
//  Single configuration point for sheet A/B.
//  To ship the fallback: leave activeSheetVariant = .fallback (default).
//  To clean up after ultimate is stable:
//    1. Delete CarryBottomSheetFallback.swift
//    2. Delete this file
//    3. Restore HomeView to call CarryBottomSheet directly
//    4. Remove the Sheet Implementation section in DeveloperModeView
//

import Foundation

enum SheetVariant: String {
    case fallback   // no scaling, stable
    case ultimate   // side + bottom scaling effects
}

/// UserDefaults key shared by activeSheetVariant and @AppStorage in HomeView.
let sheetVariantDefaultsKey = "activeSheetVariant"

/// Returns the active variant. UserDefaults overrides compile-time default,
/// allowing the Dev Options toggle to switch without a rebuild.
var activeSheetVariant: SheetVariant {
    guard let raw = UserDefaults.standard.string(forKey: sheetVariantDefaultsKey),
          let v = SheetVariant(rawValue: raw) else {
        return .fallback   // ← change this line when flipping the compile-time default
    }
    return v
}
