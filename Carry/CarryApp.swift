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
                    // Register App Shortcuts with Siri / Spotlight.
                    CarryAppShortcuts.updateAppShortcutParameters()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification)
                ) { _ in
                    CarryLogger.shared.log(.memoryWarning)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification)
                ) { _ in
                    CarryLogger.shared.log(.appDidEnterBackground)
                    CarryLogger.shared.markSessionEnded()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification)
                ) { _ in
                    CarryLogger.shared.log(.appWillEnterForeground)
                    // Re-arm the session flag when returning to foreground
                    UserDefaults.standard.set(true, forKey: "carry_session_active")
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willTerminateNotification)
                ) { _ in
                    CarryLogger.shared.log(.appWillTerminate)
                    CarryLogger.shared.markSessionEnded()
                }
        }
        .modelContainer(Self.container)
    }
}
