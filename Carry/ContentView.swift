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
}

// MARK: - Navigation Router

final class NavigationRouter: ObservableObject {
    @Published var path = NavigationPath()
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var router: NavigationRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var didApplyStartupReset = false

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
                        case .itemPicker(let info, let startInMyItems):
                            ItemPickerView(tripInfo: info, startInMyItems: startInMyItems)
                        case .addItems(let tripId):
                            ItemPickerView(tripId: tripId)
                        case .scenePicker(let info):
                            ScenePickerView(tripInfo: info)
                        case .packingList(let id):
                            PackingListView(tripId: id, isNewTrip: true)
                        case .editScenes(let id):
                            ScenePickerView(editingTripId: id)
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
        .environmentObject(store)
        .environmentObject(router)
        .onAppear {
            applyStartupResetIfNeeded()
            store.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                applyStartupResetIfNeeded()
                store.refresh()
            }
        }
    }

    private func applyStartupResetIfNeeded() {
        guard !didApplyStartupReset else { return }
        // Prevent iOS state restoration from reopening stale navigation/sheet routes.
        selectedTab = 0
        router.path = NavigationPath()
        didApplyStartupReset = true
    }
}

#Preview {
    ContentView()
}
