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
        "✈️ Long-haul flight", "🚗 Road trip", "🚢 Cruise"
    ]),
    SceneGroup(title: "Weather & terrain", items: [
        "☀️ Tropical / beach", "❄️ Winter / cold", "🌧 Rainy city", "⛰ High altitude"
    ]),
    SceneGroup(title: "Trip type", items: [
        "🏨 City break", "💍 Honeymoon", "🎒 Backpacking", "🥾 Hiking / camping",
        "💼 Business", "💻 Remote work", "👶 Travelling with kids"
    ]),
    SceneGroup(title: "About you", items: [
        "💊 Daily medication", "🌸 On / near period", "🔒 Personal (private)"
    ]),
]
