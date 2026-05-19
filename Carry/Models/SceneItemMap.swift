//
//  SceneItemMap.swift
//  Carry
//

import Foundation

// MARK: - Types

enum ItemCategory: String, CaseIterable {
    case clothing    = "Clothing"
    case essentials  = "Essentials"
    case documents   = "Documents"
    case electronics = "Electronics"
    case health      = "Health"
    case toiletries  = "Toiletries"
}

struct SceneItem {
    let name: String
    let category: ItemCategory
    let isAlert: Bool
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
    "👶 Travelling with kids":  "kids",
    "🥾 Hiking / camping":      "hiking",
    "💍 Honeymoon":             "honeymoon",
    "🎒 Backpacking":           "backpacking",
    "🏨 City break":            "city_break",
    "🏝 Resort holiday":        "resort_holiday",
    "🩸 Near period":           "personal_period",
    "☕ Coffee lover":           "personal_coffee",
    "🍵 Tea lover":             "personal_tea",
    "💊 Daily medication":      "personal_medication",
]

// MARK: - Base items (every trip)

let baseItems: [SceneItem] = [
    SceneItem(name: "Passport",             category: .documents,   isAlert: true),
    SceneItem(name: "Wallet",               category: .essentials,  isAlert: false),
    SceneItem(name: "Cash (local currency)", category: .essentials, isAlert: false),
    SceneItem(name: "Phone charger",        category: .electronics, isAlert: false),
    SceneItem(name: "Underwear",            category: .clothing,    isAlert: false),
    SceneItem(name: "Socks",                category: .clothing,    isAlert: false),
    SceneItem(name: "Toothbrush",           category: .toiletries,  isAlert: false),
    SceneItem(name: "Toothpaste",           category: .toiletries,  isAlert: false),
    SceneItem(name: "Deodorant",            category: .toiletries,  isAlert: false),
]

// MARK: - Scene → item map

let sceneItemMap: [String: [SceneItem]] = [
    "road_trip": [
        SceneItem(name: "Driver's licence",        category: .documents,   isAlert: true),
        SceneItem(name: "Car insurance docs",       category: .documents,   isAlert: true),
        SceneItem(name: "Car charger",              category: .electronics, isAlert: true),
        SceneItem(name: "Sunglasses",               category: .health,      isAlert: true),
        SceneItem(name: "Portable power bank",      category: .electronics, isAlert: false),
        SceneItem(name: "Reusable water bottle",    category: .essentials,  isAlert: false),
        SceneItem(name: "Snacks",                   category: .essentials,  isAlert: false),
        SceneItem(name: "Paper map / offline map",  category: .essentials,  isAlert: false),
    ],
    "long_haul_flight": [
        SceneItem(name: "Passport",                 category: .documents,   isAlert: true),
        SceneItem(name: "Flight tickets",           category: .documents,   isAlert: true),
        SceneItem(name: "Neck pillow",              category: .essentials,  isAlert: true),
        SceneItem(name: "Noise-cancelling headphones", category: .electronics, isAlert: true),
        SceneItem(name: "Eye mask",                 category: .essentials,  isAlert: false),
        SceneItem(name: "Earplugs",                 category: .essentials,  isAlert: false),
        SceneItem(name: "Compression socks",        category: .clothing,    isAlert: false),
        SceneItem(name: "Lip balm",                 category: .toiletries,  isAlert: false),
        SceneItem(name: "Hand sanitiser",           category: .health,      isAlert: false),
        SceneItem(name: "Portable charger",         category: .electronics, isAlert: false),
    ],
    "cruise": [
        SceneItem(name: "Passport",                 category: .documents,   isAlert: true),
        SceneItem(name: "Boarding pass",            category: .documents,   isAlert: true),
        SceneItem(name: "Motion sickness pills",    category: .health,      isAlert: true),
        SceneItem(name: "Formal dinner outfit",     category: .clothing,    isAlert: true),
        SceneItem(name: "Swimwear",                 category: .clothing,    isAlert: false),
        SceneItem(name: "Sunscreen SPF 50+",        category: .health,      isAlert: false),
        SceneItem(name: "Waterproof sandals",       category: .clothing,    isAlert: false),
        SceneItem(name: "Power strip",              category: .electronics, isAlert: false),
    ],
    "tropical": [
        SceneItem(name: "Sunscreen SPF 50+",        category: .health,      isAlert: true),
        SceneItem(name: "Sunglasses",               category: .health,      isAlert: true),
        SceneItem(name: "Sun hat",                  category: .clothing,    isAlert: true),
        SceneItem(name: "Insect repellent",         category: .health,      isAlert: true),
        SceneItem(name: "Light rain jacket",        category: .clothing,    isAlert: true),
        SceneItem(name: "Swimwear",                 category: .clothing,    isAlert: false),
        SceneItem(name: "After-sun lotion",         category: .health,      isAlert: false),
        SceneItem(name: "Waterproof sandals",       category: .clothing,    isAlert: false),
        SceneItem(name: "Reusable water bottle",    category: .essentials,  isAlert: false),
    ],
    "rainy_city": [
        SceneItem(name: "Compact umbrella",         category: .essentials,  isAlert: true),
        SceneItem(name: "Waterproof jacket",        category: .clothing,    isAlert: true),
        SceneItem(name: "Waterproof shoes",         category: .clothing,    isAlert: true),
        SceneItem(name: "Waterproof phone case",    category: .electronics, isAlert: false),
        SceneItem(name: "Quick-dry towel",          category: .essentials,  isAlert: false),
    ],
    "high_altitude": [
        SceneItem(name: "Altitude sickness pills",  category: .health,      isAlert: true),
        SceneItem(name: "Warm base layer",          category: .clothing,    isAlert: true),
        SceneItem(name: "Lip balm with SPF",        category: .toiletries,  isAlert: true),
        SceneItem(name: "Sunscreen SPF 50+",        category: .health,      isAlert: true),
        SceneItem(name: "Sunglasses",               category: .health,      isAlert: true),
        SceneItem(name: "Thermal socks",            category: .clothing,    isAlert: false),
        SceneItem(name: "Windproof jacket",         category: .clothing,    isAlert: false),
        SceneItem(name: "Reusable water bottle",    category: .essentials,  isAlert: false),
    ],
    "winter": [
        SceneItem(name: "Thermal underwear",        category: .clothing,    isAlert: true),
        SceneItem(name: "Heavy winter coat",        category: .clothing,    isAlert: true),
        SceneItem(name: "Gloves",                   category: .clothing,    isAlert: true),
        SceneItem(name: "Beanie / hat",             category: .clothing,    isAlert: true),
        SceneItem(name: "Scarf",                    category: .clothing,    isAlert: false),
        SceneItem(name: "Thermal socks",            category: .clothing,    isAlert: false),
        SceneItem(name: "Lip balm",                 category: .toiletries,  isAlert: false),
        SceneItem(name: "Hand cream",               category: .toiletries,  isAlert: false),
        SceneItem(name: "Snow boots",               category: .clothing,    isAlert: false),
    ],
    "business": [
        SceneItem(name: "Business cards",           category: .essentials,  isAlert: true),
        SceneItem(name: "Laptop",                   category: .electronics, isAlert: true),
        SceneItem(name: "Laptop charger",           category: .electronics, isAlert: true),
        SceneItem(name: "Formal shirt / blouse",    category: .clothing,    isAlert: true),
        SceneItem(name: "Dress shoes",              category: .clothing,    isAlert: true),
        SceneItem(name: "Notebook & pen",           category: .essentials,  isAlert: false),
        SceneItem(name: "Universal adapter",        category: .electronics, isAlert: false),
        SceneItem(name: "Portable charger",         category: .electronics, isAlert: false),
    ],
    "kids": [
        SceneItem(name: "Children's passport / ID", category: .documents,   isAlert: true),
        SceneItem(name: "Children's medication",    category: .health,      isAlert: true),
        SceneItem(name: "Wet wipes",                category: .essentials,  isAlert: true),
        SceneItem(name: "Snacks for kids",          category: .essentials,  isAlert: true),
        SceneItem(name: "Favourite toy / comfort item", category: .essentials, isAlert: true),
        SceneItem(name: "Change of clothes (extra)", category: .clothing,   isAlert: false),
        SceneItem(name: "Sunscreen for kids",       category: .health,      isAlert: false),
        SceneItem(name: "Portable white noise device", category: .electronics, isAlert: false),
    ],
    "hiking": [
        SceneItem(name: "Hiking boots",             category: .clothing,    isAlert: true),
        SceneItem(name: "First aid kit",            category: .health,      isAlert: true),
        SceneItem(name: "Headlamp + batteries",     category: .essentials,  isAlert: true),
        SceneItem(name: "Sunscreen SPF 50+",        category: .health,      isAlert: true),
        SceneItem(name: "Insect repellent",         category: .health,      isAlert: true),
        SceneItem(name: "Reusable water bottle",    category: .essentials,  isAlert: true),
        SceneItem(name: "Offline maps downloaded",  category: .essentials,  isAlert: true),
        SceneItem(name: "Trekking poles",           category: .essentials,  isAlert: false),
        SceneItem(name: "Trail snacks / energy bars", category: .essentials, isAlert: false),
        SceneItem(name: "Moisture-wicking socks",   category: .clothing,    isAlert: false),
        SceneItem(name: "Rain poncho",              category: .clothing,    isAlert: false),
    ],
    "honeymoon": [
        SceneItem(name: "Passport",                 category: .documents,   isAlert: true),
        SceneItem(name: "Dressy outfit",            category: .clothing,    isAlert: true),
        SceneItem(name: "Camera / extra memory card", category: .electronics, isAlert: false),
        SceneItem(name: "Portable Bluetooth speaker", category: .electronics, isAlert: false),
        SceneItem(name: "Perfume / cologne",        category: .toiletries,  isAlert: false),
        SceneItem(name: "Marriage certificate (if needed)", category: .documents, isAlert: false),
    ],
    "backpacking": [
        SceneItem(name: "Backpack rain cover",      category: .clothing,    isAlert: true),
        SceneItem(name: "Microfibre towel",         category: .essentials,  isAlert: true),
        SceneItem(name: "Packing cubes",            category: .essentials,  isAlert: false),
        SceneItem(name: "Quick-dry clothing",       category: .clothing,    isAlert: true),
        SceneItem(name: "Padlock",                  category: .essentials,  isAlert: true),
        SceneItem(name: "Power bank",               category: .electronics, isAlert: false),
        SceneItem(name: "Reusable water bottle",    category: .essentials,  isAlert: false),
    ],
    "city_break": [
        SceneItem(name: "Comfortable walking shoes", category: .clothing,   isAlert: true),
        SceneItem(name: "Crossbody bag",             category: .essentials, isAlert: true),
        SceneItem(name: "Transit card / app",        category: .essentials, isAlert: false),
        SceneItem(name: "Portable charger",          category: .electronics, isAlert: false),
        SceneItem(name: "Umbrella",                  category: .essentials, isAlert: false),
        SceneItem(name: "Photo ID copy",             category: .documents,  isAlert: true),
    ],
    "resort_holiday": [
        SceneItem(name: "Swimwear",                 category: .clothing,    isAlert: true),
        SceneItem(name: "Flip flops",               category: .clothing,    isAlert: false),
        SceneItem(name: "Sunscreen SPF 50+",        category: .health,      isAlert: true),
        SceneItem(name: "Sunglasses",               category: .health,      isAlert: true),
        SceneItem(name: "Beach bag",                category: .essentials,  isAlert: false),
        SceneItem(name: "After-sun lotion",         category: .toiletries,  isAlert: false),
    ],
    "personal_period": [
        SceneItem(name: "Sanitary pads / tampons",  category: .health,      isAlert: true),
        SceneItem(name: "Pain relievers",           category: .health,      isAlert: true),
    ],
    "personal_coffee": [
        SceneItem(name: "Instant coffee packets",   category: .essentials,  isAlert: false),
    ],
    "personal_tea": [
        SceneItem(name: "Tea bags",                 category: .essentials,  isAlert: false),
    ],
    "personal_medication": [
        SceneItem(name: "Daily medication",         category: .health,      isAlert: true),
    ],
]

// MARK: - Generation logic

/// Merges base items + selected scene items, deduplicates by name (alert wins),
/// then groups by category in a fixed order.
func generatePackingSections(selectedScenes: [String]) -> [PackingSection] {
    // name → (category, isAlert)
    var merged: [(name: String, category: ItemCategory, isAlert: Bool)] = []
    var nameIndex: [String: Int] = [:]

    func insert(_ item: SceneItem) {
        if let idx = nameIndex[item.name] {
            if item.isAlert { merged[idx] = (item.name, item.category, true) }
        } else {
            nameIndex[item.name] = merged.count
            merged.append((item.name, item.category, item.isAlert))
        }
    }

    baseItems.forEach { insert($0) }
    selectedScenes.compactMap { sceneItemMap[$0] }.flatMap { $0 }.forEach { insert($0) }

    // Group by category in a fixed display order, assigning section sortOrder by position
    let order: [ItemCategory] = [.documents, .essentials, .health, .electronics, .clothing, .toiletries]
    var sectionIndex = 0
    var result: [PackingSection] = []
    for category in order {
        let items = merged
            .filter { $0.category == category }
            .enumerated()
            .map { idx, t in PackingItem(name: t.name, isAlert: t.isAlert, sortOrder: idx) }
        guard !items.isEmpty else { continue }
        result.append(PackingSection(title: category.rawValue, items: items, sortOrder: sectionIndex))
        sectionIndex += 1
    }
    return result
}
