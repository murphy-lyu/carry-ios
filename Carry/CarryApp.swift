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
        do {
            // Use the versioned schema + migration plan so future schema changes
            // can be applied without corrupting existing user data.
            return try ModelContainer(
                for: TripBundle.self, MyItem.self,
                migrationPlan: CarryMigrationPlan.self
            )
        } catch {
            CarryLogger.shared.log(.dbInitFailed, context: "error=\(error.localizedDescription)")
            // Fall back to an in-memory store so the app stays alive.
            return try! ModelContainer(
                for: TripBundle.self, MyItem.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }()

    @StateObject private var store = TripStore()
    @StateObject private var router = NavigationRouter()

    @AppStorage("appearance_mode") private var appearanceModeRaw = AppearanceMode.system.rawValue

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            SplashView()
                .environmentObject(store)
                .environmentObject(router)
                .preferredColorScheme(appearanceMode.colorScheme)
                .onAppear {
                    CarryLogger.shared.log(.appLaunched)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    CarryLogger.shared.log(.memoryWarning)
                }
        }
        .modelContainer(Self.container)
    }
}
