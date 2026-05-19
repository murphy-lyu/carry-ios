//
//  Scene.swift
//  Carry
//

import Foundation

struct SceneGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [String]
}

let defaultSceneGroups: [SceneGroup] = [
    SceneGroup(title: "How you're getting there", items: [
        "🚗 Road trip", "✈️ Long-haul flight", "🚢 Cruise"
    ]),
    SceneGroup(title: "Weather & terrain", items: [
        "☀️ Tropical / beach", "🌧 Rainy city", "⛰ High altitude", "❄️ Winter / cold"
    ]),
    SceneGroup(title: "Trip type", items: [
        "💼 Business", "👶 Travelling with kids", "🥾 Hiking / camping", "💍 Honeymoon"
    ]),
    SceneGroup(title: "About you", items: [
        "🩸 Near period", "☕ Coffee lover", "🍵 Tea lover", "💊 Daily medication"
    ]),
]
