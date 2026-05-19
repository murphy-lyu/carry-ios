//
//  SurpriseItemMap.swift
//  Carry
//

import Foundation

// MARK: - SurpriseItem

struct SurpriseItem: Identifiable {
    var id: String { name }
    let name: String
    let note: String
    let category: ItemCategory
}

// MARK: - Scene → surprise item map

let surpriseItemMap: [String: [SurpriseItem]] = [
    "road_trip": [
        SurpriseItem(name: "Instant coffee packets",
                     note: "Long drives get drowsy — just add hot water at any rest stop",
                     category: .essentials),
        SurpriseItem(name: "Emergency blanket",
                     note: "Paper-thin foil blanket that fits in a pocket — invaluable if you break down",
                     category: .essentials),
        SurpriseItem(name: "Wet wipes",
                     note: "Gas station stops, sticky snacks, impromptu cleanups",
                     category: .essentials),
        SurpriseItem(name: "First aid kit",
                     note: "Minor incidents happen far from pharmacies on road trips",
                     category: .health),
    ],
    "long_haul_flight": [
        SurpriseItem(name: "Melatonin",
                     note: "Helps reset your body clock faster at the destination",
                     category: .health),
        SurpriseItem(name: "Breath mints",
                     note: "Cabin air is dry and recycled — your seatmates will appreciate it",
                     category: .essentials),
        SurpriseItem(name: "Moisturiser",
                     note: "Cabin humidity drops to under 20% — your skin will beg for this mid-flight",
                     category: .toiletries),
        SurpriseItem(name: "Flight snacks",
                     note: "Airline food timing rarely matches when you're actually hungry",
                     category: .essentials),
    ],
    "honeymoon": [
        SurpriseItem(name: "Condoms",
                     note: "Better to have them and not need them",
                     category: .health),
        SurpriseItem(name: "Tea light candles",
                     note: "A handful of small candles can completely transform a hotel room",
                     category: .essentials),
        SurpriseItem(name: "Printed couple photo",
                     note: "A small printed photo makes any hotel room feel personal and yours",
                     category: .essentials),
    ],
    "tropical": [
        SurpriseItem(name: "Oral rehydration salts",
                     note: "Heat + unfamiliar food can hit hard — these are a quiet lifesaver",
                     category: .health),
        SurpriseItem(name: "Anti-diarrheal tablets",
                     note: "New environments, new bacteria — best to be prepared discreetly",
                     category: .health),
        SurpriseItem(name: "Reef-safe sunscreen",
                     note: "Regular sunscreen damages coral reefs — worth switching in tropical waters",
                     category: .health),
    ],
    "winter": [
        SurpriseItem(name: "Hand warmers",
                     note: "Disposable heat packs — slip into gloves or pockets when it really bites",
                     category: .essentials),
        SurpriseItem(name: "Vaseline / petroleum jelly",
                     note: "Apply to exposed skin before heading out — stops windburn instantly",
                     category: .toiletries),
    ],
    "hiking": [
        SurpriseItem(name: "Blister plasters",
                     note: "New boots + long trails = blisters — these prevent the worst",
                     category: .health),
        SurpriseItem(name: "Electrolyte tablets",
                     note: "Water alone doesn't replace what you sweat out on a long hike",
                     category: .health),
        SurpriseItem(name: "Emergency whistle",
                     note: "Three blasts is the universal distress signal — and it weighs almost nothing",
                     category: .essentials),
    ],
    "cruise": [
        SurpriseItem(name: "Magnetic hooks",
                     note: "Cruise cabin walls are magnetic — hang bags and coats with no damage",
                     category: .essentials),
        SurpriseItem(name: "Acupressure wristbands",
                     note: "Drug-free and surprisingly effective for seasickness — wear from day one",
                     category: .health),
    ],
    "business": [
        SurpriseItem(name: "Spare pens × 2",
                     note: "Your pen always runs out the moment you need to sign something important",
                     category: .essentials),
        SurpriseItem(name: "Phone stand",
                     note: "Frees your hands during video calls from hotel rooms",
                     category: .electronics),
    ],
    "kids": [
        SurpriseItem(name: "Extra outfit in carry-on",
                     note: "For spills at 30,000 feet — before you can access your checked luggage",
                     category: .clothing),
        SurpriseItem(name: "Familiar snacks from home",
                     note: "Picky eaters + unfamiliar food = avoidable stress — come prepared",
                     category: .essentials),
    ],
    "high_altitude": [
        SurpriseItem(name: "Coca tea bags",
                     note: "Traditional remedy for altitude sickness — widely available and effective in the Andes",
                     category: .health),
        SurpriseItem(name: "Hydration tablets",
                     note: "Altitude causes faster dehydration — these help you stay on top of it",
                     category: .health),
    ],
    "rainy_city": [
        SurpriseItem(name: "Waterproof pouch",
                     note: "Keeps your phone and wallet genuinely dry in a downpour",
                     category: .essentials),
        SurpriseItem(name: "Spare socks",
                     note: "Wet feet are miserable — a dry pair tucked in your bag is pure relief",
                     category: .clothing),
    ],
    "personal_period": [
        SurpriseItem(name: "Stick-on heat patches",
                     note: "Discreet and hands-free for cramp relief anywhere, anytime",
                     category: .health),
        SurpriseItem(name: "Spare underwear (extra set)",
                     note: "Always pack at least one extra set during this time — peace of mind",
                     category: .clothing),
        SurpriseItem(name: "Dark-coloured bottoms",
                     note: "One pair of dark trousers or a dark skirt — a quiet confidence on heavier days",
                     category: .clothing),
    ],
    "personal_coffee": [
        SurpriseItem(name: "Travel mug",
                     note: "Keeps coffee hot for hours — works equally well for cold brew",
                     category: .essentials),
        SurpriseItem(name: "Collapsible coffee dripper",
                     note: "Hotel kettle + your own grounds = decent coffee anywhere",
                     category: .essentials),
    ],
    "personal_tea": [
        SurpriseItem(name: "Travel mug",
                     note: "Keeps tea hot for hours — hotel kettles are everywhere",
                     category: .essentials),
        SurpriseItem(name: "Tea variety pack",
                     note: "Bring your favourites from home — hotel tea bags rarely satisfy",
                     category: .essentials),
    ],
    "personal_medication": [
        SurpriseItem(name: "Prescription copy / letter",
                     note: "Some countries require proof for controlled medications at customs",
                     category: .documents),
        SurpriseItem(name: "Pill organiser",
                     note: "Easier and lighter than carrying full bottles — one for each day",
                     category: .health),
    ],
]

// MARK: - Generation

/// Returns surprise items for the given scene keys, excluding anything already in the packing list.
func computeSurpriseItems(for sceneKeys: [String], existingNames: Set<String>) -> [SurpriseItem] {
    var seen = Set<String>()
    var result: [SurpriseItem] = []
    for key in sceneKeys {
        for item in surpriseItemMap[key] ?? [] {
            let lower = item.name.lowercased()
            guard !seen.contains(lower), !existingNames.contains(lower) else { continue }
            seen.insert(lower)
            result.append(item)
        }
    }
    return result
}
