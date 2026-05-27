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

enum SurpriseRankingMode {
    case manualFirst
    case sceneFirst
}

// MARK: - Scene → surprise item map

let surpriseItemMap: [String: [SurpriseItem]] = [
    "road_trip": [
        SurpriseItem(name: "Car phone mount",
                     note: "Hands-free navigation is the law in most places — and your co-pilot won't always be awake",
                     category: .essentials),
        SurpriseItem(name: "Window sunshade",
                     note: "Parked in the sun, your steering wheel becomes untouchable — costs almost nothing to prevent",
                     category: .essentials),
        SurpriseItem(name: "Flat shoes",
                     note: "Driving in heels reduces pedal feel and reaction time — a pair of flats to swap into before getting behind the wheel makes a real difference on long stretches",
                     category: .clothing),
        SurpriseItem(name: "Car air freshener",
                     note: "A long drive in a stale car is draining — a subtle scent changes the whole atmosphere",
                     category: .essentials),
        SurpriseItem(name: "Car travel blanket",
                     note: "Passenger-seat naps are so much better with a real blanket — one that lives in the boot ready to go",
                     category: .essentials),
    ],
    "long_haul_flight": [
        SurpriseItem(name: "Steam eye mask",
                     note: "Ten minutes of warm darkness mid-flight feels like a reset — most people who try one become converts",
                     category: .toiletries),
        SurpriseItem(name: "Blister patches",
                     note: "Fast airport transfers and long terminal walks can shred your heels — applying one early can save your first day",
                     category: .health),
        SurpriseItem(name: "Mint gum",
                     note: "Chewing one before landing helps with dry cabin mouth and makes you feel fresher on arrival",
                     category: .essentials),
        SurpriseItem(name: "Hand cream",
                     note: "Cabin air is brutally dry — hands suffer first, and most people only notice once they're already cracked",
                     category: .toiletries),
        SurpriseItem(name: "Disposable slippers",
                     note: "Shoes off, slippers on — a small ritual that makes a long flight feel far more civilised",
                     category: .essentials),
        SurpriseItem(name: "Flight snacks",
                     note: "Airline food timing rarely matches when you're actually hungry",
                     category: .essentials),
    ],
    "honeymoon": [
        SurpriseItem(name: "Scented candle",
                     note: "A small candle transforms a hotel room — that smell will mean 'the honeymoon' for years afterwards",
                     category: .toiletries),
        SurpriseItem(name: "Massage oil",
                     note: "Small, travel-friendly, and creates its own atmosphere — worth the space",
                     category: .toiletries),
        SurpriseItem(name: "Instax / instant camera",
                     note: "A photo you hold in your hands sixty seconds after taking it is a different kind of memory",
                     category: .electronics),
        SurpriseItem(name: "Journey journal",
                     note: "Somewhere to write down the small details before they blur together into just 'the honeymoon'",
                     category: .essentials),
    ],
    "backpacking": [
        SurpriseItem(name: "Ziplock bags",
                     note: "Waterproofing documents, organising small items, separating wet clothes — endlessly useful",
                     category: .essentials),
        SurpriseItem(name: "Mini clips",
                     note: "Tiny but surprisingly versatile: clip wet socks to dry, seal snack bags, or secure loose small items",
                     category: .essentials),
        SurpriseItem(name: "Headlamp + batteries",
                     note: "Essential for hostel dorm access in the dark without waking eight strangers",
                     category: .essentials),
    ],
    "city_break": [
        SurpriseItem(name: "Comfort insoles",
                     note: "City days can hit 20k+ steps — insoles can save your feet by day two",
                     category: .clothing),
        SurpriseItem(name: "Collapsible tote bag",
                     note: "You will buy something at a market or deli — saves scrambling for a bag at the checkout",
                     category: .essentials),
        SurpriseItem(name: "Collapsible insulated bag",
                     note: "For market hauls, picnic supplies, or keeping café pastries intact — packs flat when not in use",
                     category: .essentials),
        SurpriseItem(name: "Stain remover pen",
                     note: "When coffee or sauce lands on light clothes, a quick swipe can save you from a whole day of awkward stains",
                     category: .toiletries),
        SurpriseItem(name: "Pocket tissues",
                     note: "Public restrooms and small shops do not always have tissues — this tiny backup saves the moment more often than you think",
                     category: .essentials),
    ],
    "tropical": [
        SurpriseItem(name: "Snorkel mask",
                     note: "A full-face snorkel mask changes the experience entirely — clear vision, easy breathing, no learning curve",
                     category: .essentials),
        SurpriseItem(name: "Reef-safe sunscreen",
                     note: "Regular sunscreen damages coral reefs — worth switching in tropical waters",
                     category: .health),
    ],
    "winter": [
        SurpriseItem(name: "Portable electric kettle",
                     note: "Hot water on demand in your hotel room — instant noodles at midnight, morning tea without waiting for room service",
                     category: .essentials),
    ],
    "hiking": [
        SurpriseItem(name: "Energy gel / dark chocolate",
                     note: "Real hunger hits on a long ascent — something dense and rewarding at the summit makes the whole climb feel worth it",
                     category: .essentials),
        SurpriseItem(name: "Foldable hiking stool",
                     note: "Somewhere to sit at the viewpoint — standing and looking is fine, sitting and looking is something else",
                     category: .essentials),
        SurpriseItem(name: "Duct tape (small roll)",
                     note: "Fixes a broken boot sole, a torn strap, or a blister spot — worth the 30g",
                     category: .essentials),
    ],
    "cruise": [
        SurpriseItem(name: "Magnetic hooks",
                     note: "Cruise cabin walls are magnetic — hang bags and coats with no damage",
                     category: .essentials),
        SurpriseItem(name: "Formal accessories",
                     note: "A tie clip or silk scarf — the details that make a formal dinner outfit feel considered rather than thrown together",
                     category: .clothing),
        SurpriseItem(name: "Portable fan",
                     note: "Cabins can get warm, especially in tropical ports — a small USB fan is a real sleep improvement",
                     category: .essentials),
        SurpriseItem(name: "Acupressure wristbands",
                     note: "Worn on the pressure point above the wrist — more stylish than patches and surprisingly effective for mild seasickness",
                     category: .health),
    ],
    "business": [
        SurpriseItem(name: "Wrinkle-release spray",
                     note: "Meeting clothes out of a suitcase always need a refresh — no iron required",
                     category: .toiletries),
        SurpriseItem(name: "Travel steamer",
                     note: "De-creases a shirt in two minutes — more effective than an iron on most fabrics, and takes up almost no space",
                     category: .essentials),
        SurpriseItem(name: "Shoe care kit",
                     note: "Scuffed shoes undermine an otherwise sharp outfit — a quick buff before a client meeting takes thirty seconds",
                     category: .essentials),
        SurpriseItem(name: "Foldable hangers",
                     note: "Hotel rooms never have enough — three extra hangers solve the whole wardrobe problem",
                     category: .essentials),
    ],
    "kids": [
        SurpriseItem(name: "Magnetic drawing board",
                     note: "Mess-free drawing that resets instantly — endlessly reusable on long journeys",
                     category: .essentials),
        SurpriseItem(name: "Kids headphones",
                     note: "Volume-limited and properly sized — lets them watch their shows without disturbing everyone around them",
                     category: .electronics),
        SurpriseItem(name: "Night light",
                     note: "New rooms are dark in unfamiliar ways — a simple plug-in night light prevents middle-of-the-night panic",
                     category: .essentials),
        SurpriseItem(name: "Familiar snacks from home",
                     note: "Picky eaters + unfamiliar food = avoidable stress — come prepared",
                     category: .essentials),
        SurpriseItem(name: "Sticker book or activity pad",
                     note: "For the unavoidable waiting — restaurants, airports, long car journeys",
                     category: .essentials),
    ],
    "high_altitude": [
        SurpriseItem(name: "Portable oxygen can",
                     note: "Compact enough to slip in a day bag — a quick few breaths at altitude does genuinely help, and the peace of mind is worth it",
                     category: .health),
    ],
    "rainy_city": [
        SurpriseItem(name: "Disposable rain poncho",
                     note: "Packs to the size of a biscuit, costs almost nothing — for when the umbrella is in the bag and the rain starts now",
                     category: .clothing),
        SurpriseItem(name: "Waterproof shoe covers",
                     note: "Pull on over any shoes in seconds — keeps feet dry without having to plan your footwear around the forecast",
                     category: .clothing),
        SurpriseItem(name: "Waterproof zip pouch",
                     note: "In heavy rain, putting your phone, cards, and tickets inside removes a lot of avoidable stress",
                     category: .essentials),
    ],
    "personal_period": [
        SurpriseItem(name: "Dark-coloured bottoms",
                     note: "One pair of dark trousers or a dark skirt — a quiet confidence on heavier days",
                     category: .clothing),
        SurpriseItem(name: "Portable hot water bottle",
                     note: "Fill from the hotel kettle — a hot water bottle on cramps is still the most effective thing, wherever you are",
                     category: .essentials),
        SurpriseItem(name: "Brown sugar ginger tea",
                     note: "A hot cup of this does things for cramp and mood that no tablet quite matches — harder to find abroad than you'd think",
                     category: .essentials),
        SurpriseItem(name: "Disposable toilet seat covers",
                     note: "During long days out, these make unfamiliar public restrooms feel much more comfortable",
                     category: .essentials),
    ],
    "personal_medication": [
        SurpriseItem(name: "Pill organiser",
                     note: "Easier and lighter than carrying full bottles — one for each day",
                     category: .health),
    ],
]

// MARK: - Generation

private let surpriseCategoryOrder: [ItemCategory] = [.toiletries, .electronics, .clothing, .essentials, .health, .documents]

private let surpriseUniversalScore: [String: Double] = [
    "Hand cream": 0.90,
    "Ziplock bags": 0.90,
    "Pill organiser": 0.88,
    "Travel steamer": 0.74,
    "Collapsible tote bag": 0.82,
    "Collapsible insulated bag": 0.75,
    "Disposable rain poncho": 0.86,
    "Waterproof shoe covers": 0.70,
    "Headlamp + batteries": 0.78,
]

private let surpriseDelightScore: [String: Double] = [
    "Scented candle": 0.96,
    "Journey journal": 0.86,
    "Instax / instant camera": 0.94,
    "Portable electric kettle": 0.78,
    "Car air freshener": 0.70,
    "Car travel blanket": 0.76,
    "Brown sugar ginger tea": 0.84,
]

private let surpriseSceneStrength: [String: Double] = [
    "Magnetic hooks": 0.98,
    "Acupressure wristbands": 0.92,
    "Portable oxygen can": 0.98,
    "Disposable rain poncho": 0.94,
    "Waterproof shoe covers": 0.94,
    "Reef-safe sunscreen": 0.92,
    "Snorkel mask": 0.90,
    "Kids headphones": 0.92,
    "Night light": 0.90,
]

private let surpriseNichePenalty: [String: Double] = [
    "Snorkel mask": 0.65,
    "Portable oxygen can": 0.60,
    "Foldable hiking stool": 0.58,
    "Magnetic hooks": 0.52,
    "Portable electric kettle": 0.50,
]

private let surpriseFunctionalOverlapKeywords: [String: [String]] = [
    "Car phone mount": ["phone mount", "car mount"],
    "Window sunshade": ["sunshade"],
    "Steam eye mask": ["eye mask"],
    "Hand cream": ["cream", "lotion"],
    "Disposable slippers": ["slippers"],
    "Flight snacks": ["snacks", "trail snacks"],
    "Scented candle": ["candle"],
    "Massage oil": ["massage oil", "facial oil"],
    "Instax / instant camera": ["camera"],
    "Journey journal": ["journal", "notebook"],
    "Headlamp + batteries": ["headlamp", "flashlight"],
    "Snorkel mask": ["snorkel", "swimming goggles"],
    "Reef-safe sunscreen": ["sunscreen"],
    "Magnetic hooks": ["hooks"],
    "Formal accessories": ["formal wear", "tie", "scarf"],
    "Portable fan": ["fan"],
    "Wrinkle-release spray": ["wrinkle-release spray"],
    "Travel steamer": ["steamer"],
    "Shoe care kit": ["shoe care", "shoe polish"],
    "Foldable hangers": ["hangers"],
    "Kids headphones": ["headphones"],
    "Night light": ["night light"],
    "Disposable rain poncho": ["rain poncho", "rain jacket"],
    "Waterproof shoe covers": ["waterproof shoes", "shoe covers"],
    "Portable hot water bottle": ["hot water bottle"],
    "Brown sugar ginger tea": ["ginger tea", "tea"],
]

private func functionalOverlapPenalty(
    itemName: String,
    existingNames: Set<String>
) -> Double {
    let lowerExisting = existingNames
    let keys = surpriseFunctionalOverlapKeywords[itemName] ?? []
    guard !keys.isEmpty else { return 0 }

    for existing in lowerExisting {
        for key in keys where existing.contains(key) {
            return 0.22
        }
    }
    return 0
}

private func scoreForSurpriseItem(
    _ item: SurpriseItem,
    mode: SurpriseRankingMode,
    existingNames: Set<String>
) -> Double {
    let universal = surpriseUniversalScore[item.name] ?? 0.62
    let delight = surpriseDelightScore[item.name] ?? 0.58
    let sceneFit = surpriseSceneStrength[item.name] ?? 0.72
    let niche = surpriseNichePenalty[item.name] ?? 0.20
    let overlapPenalty = functionalOverlapPenalty(itemName: item.name, existingNames: existingNames)

    switch mode {
    case .manualFirst:
        // For manual users, prioritize broadly useful + pleasant picks.
        return (universal * 0.45) + (delight * 0.35) + (sceneFit * 0.20) - (niche * 0.25) - overlapPenalty
    case .sceneFirst:
        // For scene-driven users, prioritize contextual relevance first.
        return (sceneFit * 0.70) + (universal * 0.20) + (delight * 0.10) - (niche * 0.30) - overlapPenalty
    }
}

/// Returns surprise items for the given scene keys, excluding anything already in the packing list.
/// Ranking mode:
/// - manualFirst: universal usefulness + delight first.
/// - sceneFirst: scene relevance first, then usefulness.
func computeSurpriseItems(
    for sceneKeys: [String],
    existingNames: Set<String>,
    rankingMode: SurpriseRankingMode = .sceneFirst
) -> [SurpriseItem] {
    var seen = Set<String>()
    var result: [SurpriseItem] = []

    let sourceKeys: [String]
    if sceneKeys.isEmpty, rankingMode == .manualFirst {
        sourceKeys = Array(surpriseItemMap.keys).sorted()
    } else {
        sourceKeys = sceneKeys
    }

    for key in sourceKeys {
        for item in surpriseItemMap[key] ?? [] {
            let lower = item.name.lowercased()
            guard !seen.contains(lower), !existingNames.contains(lower) else { continue }
            seen.insert(lower)
            result.append(item)
        }
    }

    let ranked = result.sorted {
        let ls = scoreForSurpriseItem($0, mode: rankingMode, existingNames: existingNames)
        let rs = scoreForSurpriseItem($1, mode: rankingMode, existingNames: existingNames)
        if ls != rs { return ls > rs }

        let l = surpriseCategoryOrder.firstIndex(of: $0.category) ?? surpriseCategoryOrder.count
        let r = surpriseCategoryOrder.firstIndex(of: $1.category) ?? surpriseCategoryOrder.count
        if l != r { return l < r }

        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }

    guard rankingMode == .sceneFirst, ranked.count > 3 else {
        return ranked
    }

    // Top-3 guardrail: keep at least 2 strongly scene-relevant items near the front.
    let strong = ranked.filter { (surpriseSceneStrength[$0.name] ?? 0.72) >= 0.88 }
    guard strong.count >= 2 else { return ranked }

    var top: [SurpriseItem] = Array(strong.prefix(2))
    let topNames = Set(top.map(\.name))
    if let bestNonStrong = ranked.first(where: { !topNames.contains($0.name) }) {
        top.append(bestNonStrong)
    }
    let remaining = ranked.filter { !Set(top.map(\.name)).contains($0.name) }
    return top + remaining
}
