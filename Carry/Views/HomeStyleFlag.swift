//
//  HomeStyleFlag.swift
//  Carry
//
//  Home trip-card visual style. 2·Map is the shipping style; 4·Map (live destination map
//  fallback) is kept as a Dev Options experiment to keep exploring — NOT for release
//  (see docs/decisions.md: small-tile Apple Maps attribution can't be made compliant).
//

import SwiftUI

/// Home trip-card visual style.
enum HomeCardStyle: String, CaseIterable, Identifiable {
    case featured   // 2·Map: original card; a user photo (if set) fills it — the shipping style
    case glass      // 4·Map: no-photo trips show a live destination map — experimental only

    var id: String { rawValue }

    /// Dev-only label (internal switcher, not user-facing → plain text is fine).
    var devLabel: String {
        switch self {
        case .featured: return "2·Map"
        case .glass:    return "4·Map"
        }
    }
}

/// UserDefaults key shared by the Dev Options picker and TripCard's @AppStorage.
let homeCardStyleKey = "homeCardStyle"
