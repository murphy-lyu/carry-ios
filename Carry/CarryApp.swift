//
//  CarryApp.swift
//  Carry
//
//  Created by shmilvtian5 on 2026/5/14.
//

import SwiftUI
import SwiftData
import AppIntents
import UserNotifications

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

    private let notificationDelegate = PackReminderNotificationDelegate()

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
                    CarryAppShortcuts.updateAppShortcutParameters()
                    // 注册通知委托，让打包提醒点击后直接跳到对应行程
                    notificationDelegate.router = router
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                }
                .onOpenURL { url in
                    guard url.scheme == "carry",
                          let uuidString = url.pathComponents.dropFirst().first,
                          let id = UUID(uuidString: uuidString) else { return }
                    // carry://trip/{uuid} 或 carry://packing/{uuid}
                    router.pendingTripId = id
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
                    // 出发日检查：若已到出发当天则结束 Live Activity
#if !targetEnvironment(macCatalyst)
                    Task { @MainActor in LiveActivityManager.shared.endIfDeparted() }
#endif
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

// MARK: - 打包提醒通知点击处理

final class PackReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var router: NavigationRouter?

    /// 用户点击通知时调用：解析 tripId 并跳转到对应行程打包清单
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let tripId = NotificationManager.tripId(fromIdentifier: response.notification.request.identifier) {
            DispatchQueue.main.async { [weak self] in
                self?.router?.pendingTripId = tripId
            }
        }
        completionHandler()
    }

    /// App 在前台时也展示 banner
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
