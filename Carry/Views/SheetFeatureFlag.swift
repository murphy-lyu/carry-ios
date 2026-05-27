//
//  SheetFeatureFlag.swift
//  Carry
//
//  Single configuration point for sheet A/B.
//  Default is .fallback (CarryBottomSheet, no scaling).
//  To clean up after scaled variant is stable:
//    1. Delete CarryBottomSheetFX.swift
//    2. Delete this file
//    3. Restore HomeView to call CarryBottomSheet directly
//    4. Remove the Sheet Implementation section in DeveloperModeView
//

import Foundation

enum SheetVariant: String {
    case fallback   // CarryBottomSheet — no scaling, stable default
    case ultimate   // CarryBottomSheetFX — side + bottom scaling effects
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
