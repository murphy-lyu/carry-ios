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
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    static let container: ModelContainer = {
        let schema = Schema(versionedSchema: CarrySchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Never auto-delete user data. Fallback to in-memory store for this launch only.
            let memoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [memoryConfiguration])
            } catch {
                fatalError("Failed to initialize SwiftData container: \(error)")
            }
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
        }
        .modelContainer(Self.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: UIApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }
}
