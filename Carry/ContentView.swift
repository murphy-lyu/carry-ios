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
    case scenePicker(TripInfo)
    case packingList(UUID)
    case editScenes(UUID)
    case autoPackPicker(TripInfo, sceneKeys: [String])
}

// MARK: - Navigation Router

final class NavigationRouter: ObservableObject {
    @Published var path = NavigationPath()
    @Published var showMapFullscreen = false
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var router: NavigationRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab = 0
    @State private var didApplyStartupReset = false
    @State private var didRefreshOnLaunch = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: UUID.self) { id in
                        PackingListView(tripId: id)
                    }
                    .navigationDestination(for: CreationRoute.self) { route in
                        switch route {
                        case .tripInfo(let routeID, let startInMyItems):
                            TripInfoView(routeID: routeID, startInMyItems: startInMyItems)
                                .toolbar(.hidden, for: .tabBar)
                        case .itemPicker(let info, let startInMyItems):
                            ItemPickerView(tripInfo: info, startInMyItems: startInMyItems)
                                .toolbar(.hidden, for: .tabBar)
                        case .addItems(let tripId):
                            ItemPickerView(tripId: tripId)
                        case .scenePicker(let info):
                            ScenePickerView(tripInfo: info)
                                .toolbar(.hidden, for: .tabBar)
                        case .packingList(let id):
                            PackingListView(tripId: id, isNewTrip: true)
                                .toolbar(.hidden, for: .tabBar)
                        case .editScenes(let id):
                            ScenePickerView(editingTripId: id)
                        case .autoPackPicker(let info, let sceneKeys):
                            ItemPickerView(autoPackTripInfo: info, sceneKeys: sceneKeys)
                                .id(sceneKeys.sorted().joined(separator: ","))
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
            }
            .tabItem {
                Label("Trips", systemImage: "suitcase")
            }
            .tag(0)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(1)
        }
        .tint(.primary)
        .toolbarBackground(
            colorScheme == .dark
                ? Color(red: 0.11, green: 0.11, blue: 0.12)
                : Color(UIColor.systemBackground),
            for: .tabBar
        )
        .toolbarBackground(.visible, for: .tabBar)
        .environmentObject(store)
        .environmentObject(router)
        .onAppear {
            applyStartupResetIfNeeded()
            if !didRefreshOnLaunch {
                didRefreshOnLaunch = true
                store.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                applyStartupResetIfNeeded()
                store.refresh()
                if didApplyStartupReset {
                    handlePendingShortcut()
                }
            }
        }
        // React to UserDefaults changes written by an AppIntent perform(),
        // which can arrive slightly after scenePhase turns .active.
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification)
        ) { _ in
            if didApplyStartupReset {
                handlePendingShortcut()
            }
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

        // Small delay so NavigationStack is fully settled before we push.
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
