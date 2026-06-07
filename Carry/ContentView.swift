//
//  ContentView.swift
//  Carry
//

import SwiftUI
import Combine

// MARK: - Creation Route

enum CreationRoute: Hashable {
    case tripInfo(UUID, startInMyItems: Bool)
    case itemPicker(TripInfo, startInMyItems: Bool)
    case addItems(UUID)
    case packingList(UUID)
    case editScenes(UUID)
    case autoPackPicker(TripInfo, sceneKeys: [String])
}

// MARK: - Navigation Router

final class NavigationRouter: ObservableObject {
    @Published var path = NavigationPath()
    @Published var showMapFullscreen = false
    @Published var pendingTripId: UUID? = nil
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var router: NavigationRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab = 0
    // Settings 二级导航路径，提到外层用 isEmpty 驱动 tab bar 显隐，
    // 与 Trips 链路同构，避免「挂在目标视图上」导致返回时 tab bar 慢半拍。
    @State private var settingsPath = NavigationPath()
    @State private var didApplyStartupReset = false
    @State private var didRefreshOnLaunch = false
    @State private var showSettingsOnMac = false

    var body: some View {
        #if targetEnvironment(macCatalyst)
        macLayout
        #else
        iPhoneLayout
        #endif
    }

    // MARK: - Mac layout

    #if targetEnvironment(macCatalyst)
    @ViewBuilder
    private var macLayout: some View {
        ZStack(alignment: .leading) {
            // Globe fills the entire window background
            MacGlobePanel()
                .ignoresSafeArea()

            // Left panel floats over the globe as a card with breathing room
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: UUID.self) { id in
                        PackingListView(tripId: id)
                    }
                    .navigationDestination(for: CreationRoute.self) { route in
                        routeDestination(route)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showSettingsOnMac = true } label: {
                                Image(systemName: "gear")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
            }
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark
                        ? Color(red: 0.09, green: 0.09, blue: 0.10)
                        : Color(UIColor.systemBackground))
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 32, x: 0, y: 8)
            .padding(.leading, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .sheet(isPresented: $showSettingsOnMac) {
                NavigationStack(path: $settingsPath) { SettingsView(path: $settingsPath) }
                    .frame(minWidth: 420, minHeight: 560)
            }
        }
        .tint(CarryAccent.color)
        .environmentObject(store)
        .environmentObject(router)
        .onAppear { onAppearCommon() }
        .onChange(of: router.pendingTripId) { _, tripId in handlePendingTripId(tripId) }
        .onChange(of: scenePhase) { _, phase in onScenePhaseChange(phase) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if didApplyStartupReset { handlePendingShortcut() }
        }
    }
    #endif

    // MARK: - iPhone layout

    @ViewBuilder
    private var iPhoneLayout: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: UUID.self) { id in
                        PackingListView(tripId: id)
                    }
                    .navigationDestination(for: CreationRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .toolbar(router.path.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem { Label("Trips", systemImage: "suitcase") }
            .tag(0)

            NavigationStack(path: $settingsPath) {
                SettingsView(path: $settingsPath)
            }
            .toolbar(settingsPath.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(1)
        }
        .tint(CarryAccent.color)
        .toolbarBackground(
            colorScheme == .dark
                ? Color(red: 0.11, green: 0.11, blue: 0.12)
                : Color(UIColor.systemGray6).opacity(0.92),
            for: .tabBar
        )
        .toolbarBackground(.visible, for: .tabBar)
        .environmentObject(store)
        .environmentObject(router)
        .onAppear { onAppearCommon() }
        .onChange(of: router.pendingTripId) { _, tripId in
            guard let tripId else { return }
            selectedTab = 0
            router.path = NavigationPath()
            router.path.append(tripId)
            router.pendingTripId = nil
        }
        .onChange(of: scenePhase) { _, phase in onScenePhaseChange(phase) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if didApplyStartupReset { handlePendingShortcut() }
        }
    }

    // MARK: - Shared helpers

    @ViewBuilder
    private func routeDestination(_ route: CreationRoute) -> some View {
        switch route {
        case .tripInfo(let routeID, let startInMyItems):
            TripInfoView(routeID: routeID, startInMyItems: startInMyItems)
        case .itemPicker(let info, let startInMyItems):
            ItemPickerView(tripInfo: info, startInMyItems: startInMyItems)
        case .addItems(let tripId):
            ItemPickerView(tripId: tripId)
        case .packingList(let id):
            PackingListView(tripId: id, isNewTrip: true)
        case .editScenes(let id):
            ScenePickerView(editingTripId: id)
        case .autoPackPicker(let info, let sceneKeys):
            ItemPickerView(
                autoPackTripInfo: info,
                sceneKeys: sceneKeys,
                isInternational: store.inferIsInternational(for: info.destinationCity),
                destinationCodes: store.inferCountryCodes(for: info.destinationCity)
            )
            .id(sceneKeys.sorted().joined(separator: ","))
        }
    }

    private func onAppearCommon() {
        applyStartupResetIfNeeded()
        if !didRefreshOnLaunch {
            didRefreshOnLaunch = true
            store.refresh()
        }
        // 深链冷启动保护：CarryApp.onOpenURL 在 SplashView 阶段就可能把 pendingTripId
        // 设上（Widget/通知/Universal Link 冷启动），那时 ContentView 还没 mount，
        // onChange(of: pendingTripId) 不会重放历史值——直接丢失。这里主动消费一次。
        // 见 memory project_carry_deeplink_timing.md。
        if let id = router.pendingTripId {
            handlePendingTripId(id)
        }
    }

    private func handlePendingTripId(_ tripId: UUID?) {
        guard let tripId else { return }
        selectedTab = 0
        router.path = NavigationPath()
        router.path.append(tripId)
        router.pendingTripId = nil
    }

    private func onScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
            applyStartupResetIfNeeded()
            store.refresh()
            if didApplyStartupReset { handlePendingShortcut() }
        }
    }

    private func applyStartupResetIfNeeded() {
        guard !didApplyStartupReset else { return }
        // Prevent iOS state restoration from reopening stale navigation/sheet routes.
        selectedTab = 0
        router.path = NavigationPath()
        didApplyStartupReset = true
        // Handle any Spotlight / Siri shortcut that launched the app.
        handlePendingShortcut()
    }

    /// Reads a pending shortcut action written by a CarryAppIntent and navigates accordingly.
    /// Safe to call multiple times — clears UserDefaults immediately so it's a no-op on repeat.
    func handlePendingShortcut() {
        let defaults = UserDefaults.standard
        guard let action = defaults.string(forKey: "carry_shortcut_action") else { return }
        defaults.removeObject(forKey: "carry_shortcut_action")

        // ⚠️ asyncAfter 反模式（CLAUDE.md 点名），但此处保留：SplashView 淡出 + ContentView
        // 完全 attach + NavigationStack ready 三者的"就绪事件"在 SwiftUI 里没有可观察的钩子。
        // 改为 0 ms 立即 push 在老机型/慢启动场景下会让 NavigationStack 错过这次 push。
        // 真正消除此延迟需重构为"路径就绪通知 → 消费 pending"——超出本次 QA 修复范围。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            switch action {
            case "create_trip":
                router.path.append(CreationRoute.tripInfo(UUID(), startInMyItems: false))
            case "open_trip":
                if let idStr = defaults.string(forKey: "carry_shortcut_trip_id"),
                   let id = UUID(uuidString: idStr) {
                    defaults.removeObject(forKey: "carry_shortcut_trip_id")
                    router.path.append(id)
                }
            case "show_map":
                router.path = NavigationPath()   // go to HomeView root
                router.showMapFullscreen = true  // signal HomeView to collapse sheet
            default:
                break
            }
        }
    }
}
