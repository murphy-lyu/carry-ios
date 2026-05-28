//
//  SceneItemMap.swift
//  Carry
//

import Foundation

struct SceneItem {
    let name: String
    let category: ItemCategory
    let isAlert: Bool
    var internationalOnly: Bool = false
}

private func makeSceneItem(_ name: String, isAlert: Bool, internationalOnly: Bool = false) -> SceneItem {
    let canonicalName = canonicalItemName(name)
    let category = categoryForCatalogItem(canonicalName) ?? .essentials
    return SceneItem(name: canonicalName, category: category, isAlert: isAlert, internationalOnly: internationalOnly)
}

func defaultQuantity(for itemName: String, tripDays: Int) -> Int {
    let days = max(1, tripDays)
    let lower = itemName.lowercased()

    if lower.contains("spare") || lower.contains("extra") {
        return 1
    }
    if lower == "underwear"
        || lower == "socks"
        || lower == "disposable underwear"
        || lower == "disposable face masks"
        || lower == "heat patches"
        || lower == "instant coffee"
        || lower == "tea bags"
        || lower == "cotton pads"
        || lower == "face mask"
        || lower == "dental floss"
        || lower == "probiotics" {
        return min(days, 99)
    }
    if lower == "daily medication"
        || lower == "children's medication" {
        return min(days, 99)
    }
    return 1
}

// MARK: - Chip label → scene key

let sceneLabelToKey: [String: String] = [
    "🚗 Road trip":             "road_trip",
    "✈️ Long-haul flight":      "long_haul_flight",
    "🚢 Cruise":                "cruise",
    "☀️ Tropical / beach":      "tropical",
    "🌧 Rainy city":            "rainy_city",
    "⛰ High altitude":         "high_altitude",
    "❄️ Winter / cold":         "winter",
    "💼 Business":              "business",
    "💻 Remote work":           "remote_work",
    "👶 Travelling with kids":  "kids",
    "🥾 Hiking / camping":      "hiking",
    "💍 Honeymoon":             "honeymoon",
    "🎒 Backpacking":           "backpacking",
    "🏨 City break":            "city_break",
    "🌸 On / near period":      "personal_period",
    "💊 Daily medication":      "personal_medication",
]

// MARK: - Base items (every trip)

let baseItems: [SceneItem] = [
    makeSceneItem("Passport", isAlert: true, internationalOnly: true),
    makeSceneItem("Wallet", isAlert: false),
    makeSceneItem("Cash", isAlert: false),
    makeSceneItem("Phone charger", isAlert: false),
    makeSceneItem("Underwear", isAlert: false),
    makeSceneItem("Socks", isAlert: false),
    makeSceneItem("Toothbrush", isAlert: false),
    makeSceneItem("Toothpaste", isAlert: false),
    makeSceneItem("Deodorant", isAlert: false),
]

// MARK: - Scene → item map

let sceneItemMap: [String: [SceneItem]] = [
    "road_trip": [
        makeSceneItem("Driver's license", isAlert: true),
        makeSceneItem("Car insurance docs", isAlert: true),
        makeSceneItem("Car charger", isAlert: true),
        makeSceneItem("First aid kit", isAlert: true),
        makeSceneItem("Sunglasses", isAlert: true),
        makeSceneItem("Water bottle", isAlert: false),
        makeSceneItem("Snacks", isAlert: false),
    ],
    "long_haul_flight": [
        makeSceneItem("Passport", isAlert: true, internationalOnly: true),
        makeSceneItem("Neck pillow", isAlert: true),
        makeSceneItem("Noise-cancelling headphones", isAlert: true),
        makeSceneItem("Portable WiFi device", isAlert: false, internationalOnly: true),
        makeSceneItem("Eye mask", isAlert: false),
        makeSceneItem("Water bottle", isAlert: false),
    ],
    "cruise": [
        makeSceneItem("Passport", isAlert: true, internationalOnly: true),
        makeSceneItem("Motion sickness tablets", isAlert: true),
        makeSceneItem("Formal dinner outfit", isAlert: true),
        makeSceneItem("Travel adapter", isAlert: true, internationalOnly: true),
        makeSceneItem("Swimsuit", isAlert: false),
        makeSceneItem("Sunscreen", isAlert: true),
    ],
    "tropical": [
        makeSceneItem("Sunscreen", isAlert: true),
        makeSceneItem("Sunglasses", isAlert: true),
        makeSceneItem("Sun hat", isAlert: true),
        makeSceneItem("Insect repellent", isAlert: true),
        makeSceneItem("Swimsuit", isAlert: false),
        makeSceneItem("Flip flops", isAlert: false),
        makeSceneItem("After-sun lotion", isAlert: false),
        makeSceneItem("Waterproof bag", isAlert: false),
    ],
    "rainy_city": [
        makeSceneItem("Umbrella", isAlert: true),
        makeSceneItem("Waterproof jacket", isAlert: true),
        makeSceneItem("Waterproof shoes", isAlert: true),
    ],
    "high_altitude": [
        makeSceneItem("Altitude sickness pills", isAlert: true),
        makeSceneItem("Thermal underwear", isAlert: true),
        makeSceneItem("Sunscreen", isAlert: true),
        makeSceneItem("Sunglasses", isAlert: true),
        makeSceneItem("Water bottle", isAlert: false),
        makeSceneItem("Electrolyte tablets", isAlert: false),
        makeSceneItem("Thermal socks", isAlert: false),
        makeSceneItem("Windproof jacket", isAlert: false),
    ],
    "winter": [
        makeSceneItem("Thermal underwear", isAlert: true),
        makeSceneItem("Heavy winter coat", isAlert: true),
        makeSceneItem("Gloves", isAlert: true),
        makeSceneItem("Beanie", isAlert: true),
        makeSceneItem("Scarf", isAlert: false),
        makeSceneItem("Hand warmers", isAlert: false),
        makeSceneItem("Thermal socks", isAlert: false),
        makeSceneItem("Snow boots", isAlert: false),
    ],
    "business": [
        makeSceneItem("Business cards", isAlert: false),
        makeSceneItem("Laptop", isAlert: true),
        makeSceneItem("Laptop charger", isAlert: true),
        makeSceneItem("Formal shirt / blouse", isAlert: true),
        makeSceneItem("Formal wear", isAlert: true),
        makeSceneItem("Dress shoes", isAlert: true),
        makeSceneItem("Portable WiFi device", isAlert: false, internationalOnly: true),
    ],
    "remote_work": [
        makeSceneItem("Laptop", isAlert: true),
        makeSceneItem("Portable WiFi device", isAlert: true),
        makeSceneItem("Travel adapter", isAlert: true, internationalOnly: true),
        makeSceneItem("Laptop charger", isAlert: true),
        makeSceneItem("Noise-cancelling headphones", isAlert: true),
        makeSceneItem("Portable charger", isAlert: false),
    ],
    "kids": [
        makeSceneItem("Children's passport / ID", isAlert: true),
        makeSceneItem("Children's medication", isAlert: true),
        makeSceneItem("Wet wipes", isAlert: true),
        makeSceneItem("Snacks for kids", isAlert: true),
        makeSceneItem("Favourite toy / comfort item", isAlert: true),
        makeSceneItem("Change of clothes (extra)", isAlert: false),
        makeSceneItem("Sunscreen for kids", isAlert: false),
    ],
    "hiking": [
        makeSceneItem("Hiking boots", isAlert: true),
        makeSceneItem("First aid kit", isAlert: true),
        makeSceneItem("Headlamp + batteries", isAlert: true),
        makeSceneItem("Sunscreen", isAlert: true),
        makeSceneItem("Water bottle", isAlert: true),
        makeSceneItem("Trail snacks / energy bars", isAlert: false),
    ],
    "honeymoon": [
        makeSceneItem("Passport", isAlert: true, internationalOnly: true),
        makeSceneItem("Formal wear", isAlert: true),
        makeSceneItem("Dress shoes", isAlert: true),
        makeSceneItem("Travel adapter", isAlert: true, internationalOnly: true),
        makeSceneItem("Swimsuit", isAlert: false),
        makeSceneItem("Camera / extra memory card", isAlert: false),
        makeSceneItem("Perfume", isAlert: false),
    ],
    "backpacking": [
        makeSceneItem("Backpack rain cover", isAlert: true),
        makeSceneItem("Microfibre towel", isAlert: true),
        makeSceneItem("Quick-dry clothing", isAlert: true),
        makeSceneItem("First aid kit", isAlert: true),
        makeSceneItem("Travel adapter", isAlert: true, internationalOnly: true),
        makeSceneItem("Water bottle", isAlert: false),
        makeSceneItem("Portable charger", isAlert: false),
        makeSceneItem("Laundry bag", isAlert: false),
    ],
    "city_break": [
        makeSceneItem("Comfortable walking shoes", isAlert: true),
        makeSceneItem("Crossbody bag", isAlert: true),
        makeSceneItem("Portable charger", isAlert: true),
        makeSceneItem("Photo ID copy", isAlert: true),
        makeSceneItem("Transit card / app", isAlert: false),
        makeSceneItem("Sunscreen", isAlert: false),
        makeSceneItem("Umbrella", isAlert: false),
    ],
    "personal_period": [
        makeSceneItem("Feminine hygiene products", isAlert: true),
        makeSceneItem("Painkillers", isAlert: true),
    ],
    "personal_medication": [
        makeSceneItem("Daily medication", isAlert: true),
    ],
]

// MARK: - Scene item accessor

func sceneItems(for key: String) -> [SceneItem] {
    sceneItemMap[key] ?? []
}

// MARK: - Generation logic

/// Merges base items + selected scene items, deduplicates by name (alert wins),
/// then groups by category in a fixed order.
/// - Parameter isInternational: `true` = international trip, `false` = domestic, `nil` = unknown (show all).
func generatePackingSections(selectedScenes: [String], tripDays: Int = 1, isInternational: Bool? = nil) -> [PackingSection] {
    var merged: [(name: String, category: ItemCategory, isAlert: Bool)] = []
    var nameIndex: [String: Int] = [:]

    func insert(_ item: SceneItem) {
        if let intl = isInternational, !intl, item.internationalOnly { return }
        if let idx = nameIndex[item.name] {
            if item.isAlert { merged[idx] = (item.name, item.category, true) }
        } else {
            nameIndex[item.name] = merged.count
            merged.append((item.name, item.category, item.isAlert))
        }
    }

    baseItems.forEach { insert($0) }
    selectedScenes.flatMap { sceneItems(for: $0) }.forEach { insert($0) }

    let order: [ItemCategory] = [
        .documents,
        .clothing,
        .electronics,
        .travelAccessories,
        .toiletries,
        .essentials,
        .health,
        .healthWellness
    ]
    var sectionIndex = 0
    var result: [PackingSection] = []
    for category in order {
        let items = merged
            .filter { $0.category == category }
            .enumerated()
            .map { idx, t in
                PackingItem(
                    name: t.name,
                    quantity: defaultQuantity(for: t.name, tripDays: tripDays),
                    isAlert: t.isAlert,
                    sortOrder: idx
                )
            }
        guard !items.isEmpty else { continue }
        result.append(PackingSection(title: category.rawValue, items: items, sortOrder: sectionIndex))
        sectionIndex += 1
    }
    return result
}
