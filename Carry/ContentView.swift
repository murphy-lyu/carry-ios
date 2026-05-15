//
//  ContentView.swift
//  Carry
//

import SwiftUI
import Combine

// MARK: - Creation Route

enum CreationRoute: Hashable {
    case tripInfo
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
    @StateObject private var store = TripStore()
    @StateObject private var router = NavigationRouter()

    var body: some View {
        TabView {
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: UUID.self) { id in
                        PackingListView(tripId: id)
                    }
                    .navigationDestination(for: CreationRoute.self) { route in
                        switch route {
                        case .tripInfo:
                            TripInfoView()
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

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .environmentObject(store)
        .environmentObject(router)
    }
}

#Preview {
    ContentView()
}
