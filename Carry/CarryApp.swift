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

    var body: some Scene {
        WindowGroup {
            SplashView()
        }
        .modelContainer(Self.container)
    }
}
