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
import UIKit

@main
struct CarryApp: App {
    // Bridges UIKit app/scene lifecycle for home-screen Quick Actions, which have
    // no native SwiftUI hook. The scene delegate (set in CarryAppDelegate) receives
    // the quick-action callbacks; the adaptor itself does not alter SwiftUI's
    // window management.
    @UIApplicationDelegateAdaptor(CarryAppDelegate.self) private var appDelegate

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

    init() {
        // App-wide UIKit tint so system-presented UI (confirmationDialogs, alerts, context
        // menus) uses the single accent too — SwiftUI's `.tint()` doesn't reach these.
        UIWindow.appearance().tintColor = CarryAccent.uiColor
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
                    Self.installQuickActions()
                    store.writeWidgetSnapshot()
                    // 预热汇率：让费用录入时能就地捕获本位币快照（spec: itinerary-cost-tracking.md）
                    ExchangeRateManager.shared.fetchIfNeeded()
                    // 注册通知委托，让打包提醒点击后直接跳到对应行程
                    notificationDelegate.router = router
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                    // 注：冷启动的通知重排放在 TripStore.init 的 Task 里（fetchTrips 之后、trips 已加载时），
                    // 不在此处——否则 trips 还空就重排会把已排通知全删（spec: notification-budget.md）。
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification)
                ) { _ in
                    // 回前台滚动补位（此时 trips 早已加载；冷启动由 TripStore.init 覆盖、不在此重复）。
                    store.refreshNotifications()
                }
                .onOpenURL { url in
                    // 同行者发来的行程文件（.carrytrip）：读摘要 → 交给 ContentView 弹确认导入。
                    if url.isFileURL {
                        guard url.pathExtension.lowercased() == "carrytrip" else { return }
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if let data = try? Data(contentsOf: url),
                           let summary = DataBackupManager.shared.readSharedTripSummary(from: data) {
                            router.pendingSharedTrip = summary
                        }
                        return
                    }
                    guard url.scheme == "carry",
                          let uuidString = url.pathComponents.dropFirst().first,
                          let id = UUID(uuidString: uuidString) else { return }
                    // carry://trip/{uuid} 或 carry://packing/{uuid}。后者按语义落「打包」脸；
                    // 前者（及 Widget）保持「上次看的脸」（face=nil）。spec: notification-deeplink-routing.md。
                    let face: TripDetailFace? = url.host == "packing" ? .packing : nil
                    router.pendingTrip = TripDeepLink(tripId: id, face: face)
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
                    // Refresh the home-screen widget with the latest trip data.
                    store.writeWidgetSnapshot()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification)
                ) { _ in
                    CarryLogger.shared.log(.appWillEnterForeground)
                    // Re-arm the session flag when returning to foreground
                    UserDefaults.standard.set(true, forKey: "carry_session_active")
                    // 出发日检查：若已到出发当天则结束 Live Activity
#if !targetEnvironment(macCatalyst)
                    Task { @MainActor in
                        LiveActivityManager.shared.endIfDeparted()
                        // 交通「下一程」LA（spec: widget-transit-live-activity.md）：已抵达则结束、
                        // 再按当下扫一遍是否该为最临近的一程自动起（A）。
                        LiveActivityManager.shared.endTransitIfArrived()
                        LiveActivityManager.shared.startTransitIfNeeded(trips: store.trips)
                    }
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

    /// Installs the three home-screen Quick Actions. Content is fixed; icons reuse
    /// the SF Symbols from CarryAppShortcuts and titles come from Localizable.xcstrings.
    /// NOTE: iOS shows the FIRST array item closest to the app icon, so with the icon in the
    /// lower half of the screen (the common case — dock / lower rows) the menu opens upward and
    /// the list reads bottom-up. We therefore define the array in reverse (footprint → nearest →
    /// new trip) so it reads top-to-bottom as: New Trip · Nearest Trip · Footprint.
    private static func installQuickActions() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: CarryQuickAction.footprint,
                localizedTitle: NSLocalizedString("Footprint", comment: "Quick action title"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "globe.asia.australia"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: CarryQuickAction.nearestTrip,
                localizedTitle: NSLocalizedString("Nearest Trip", comment: "Quick action title"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "suitcase"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: CarryQuickAction.newTrip,
                localizedTitle: NSLocalizedString("New Trip", comment: "Quick action title"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "plus.circle"),
                userInfo: nil
            )
        ]
    }
}

// MARK: - Quick Action lifecycle bridge

/// Minimal app delegate that points new scenes at CarrySceneDelegate so home-screen
/// Quick Actions can be received. Does not otherwise touch app/window setup.
final class CarryAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = CarrySceneDelegate.self
        return config
    }
}

/// Receives home-screen Quick Action callbacks. Deliberately does NOT create a
/// UIWindow — SwiftUI's WindowGroup owns the window; this delegate only forwards
/// the tapped action into the shared UserDefaults that ContentView observes.
final class CarrySceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: app was not running and was started by a Quick Action.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let item = connectionOptions.shortcutItem {
            CarryQuickAction.handle(type: item.type)
        }
    }

    /// Warm launch: app was already running in the background.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        CarryQuickAction.handle(type: shortcutItem.type)
        completionHandler(true)
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
        let identifier = response.notification.request.identifier
        if let link = NotificationManager.deepLink(fromIdentifier: identifier) {
            CarryLogger.shared.log(.notificationTapped, context: "tripId=\(link.tripId)")
            // 天气预警点击单独记一笔（spec: weather-aware-packing.md, Part 2）
            if identifier.contains(".weather") {
                CarryLogger.shared.log(.weatherAlertFired, context: "tripId=\(link.tripId)")
            }
            // 富目标承载「该落哪张脸 + 锚点」（spec: notification-deeplink-routing.md），
            // 由 ContentView.handlePendingTrip 选脸 + 拆 modal + 滚到对应天。
            DispatchQueue.main.async { [weak self] in
                self?.router?.pendingTrip = link
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
