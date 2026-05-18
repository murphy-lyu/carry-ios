//
//  CarryApp.swift
//  Carry
//
//  Created by shmilvtian5 on 2026/5/14.
//

import SwiftUI
import SwiftData

@main
struct CarryApp: App {
    static let container: ModelContainer = {
        try! ModelContainer(for: TripBundle.self)
    }()

    @AppStorage("appearance_mode") private var appearanceModeRaw = AppearanceMode.system.rawValue

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            SplashView()
                .tint(.primary)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .modelContainer(Self.container)
    }
}
