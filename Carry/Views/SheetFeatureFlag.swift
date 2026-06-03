//
//  SheetFeatureFlag.swift
//  Carry
//
//  Single configuration point for sheet A/B.
//  Default is .ultimate (CarryBottomSheetFX, side + bottom scaling) since 2026-06-03,
//  after the FX variant reached parity + buttery-smooth (pure Core Animation snap).
//  CarryBottomSheet (fallback) is kept as the Dev Options A/B alternative.
//  To fully retire the fallback later:
//    1. Delete CarryBottomSheet.swift
//    2. Delete this file
//    3. Restore HomeView to call CarryBottomSheetFX directly
//    4. Remove the Sheet Implementation section in DeveloperModeView
//

import Foundation

enum SheetVariant: String {
    case fallback   // CarryBottomSheet — no scaling, A/B alternative
    case ultimate   // CarryBottomSheetFX — side + bottom scaling effects, current default
}

/// UserDefaults key shared by activeSheetVariant and @AppStorage in HomeView.
let sheetVariantDefaultsKey = "activeSheetVariant"

/// Returns the active variant. UserDefaults overrides compile-time default,
/// allowing the Dev Options toggle to switch without a rebuild.
var activeSheetVariant: SheetVariant {
    guard let raw = UserDefaults.standard.string(forKey: sheetVariantDefaultsKey),
          let v = SheetVariant(rawValue: raw) else {
        return .ultimate   // ← compile-time default (flip to .fallback only for A/B)
    }
    return v
}
