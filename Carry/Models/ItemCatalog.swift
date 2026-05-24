//
//  ItemCatalog.swift
//  Carry
//

import Foundation

enum ItemCategory: String, CaseIterable {
    case documents = "Documents"
    case clothing = "Clothing"
    case electronics = "Electronics"
    case toiletries = "Toiletries"
    case travelAccessories = "Travel Accessories"
    case essentials = "Essentials"
    case health = "Health"
    case makeup = "Makeup"
    case jewellery = "Jewellery"
    case leisure = "Leisure"
    case healthWellness = "Health & Wellness"
    case winterTravel = "Winter Travel"
    case beachOutdoor = "Beach & Outdoor"

    static func catalogCategory(named name: String) -> ItemCategory? {
        switch name {
        case "Documents": return .documents
        case "Clothing": return .clothing
        case "Electronics": return .electronics
        case "Toiletries": return .toiletries
        case "Travel Accessories": return .travelAccessories
        case "Essentials": return .essentials
        case "Health": return .health
        case "Makeup": return .makeup
        case "Jewellery": return .jewellery
        case "Leisure": return .leisure
        case "Health & Wellness": return .healthWellness
        case "Winter Travel": return .winterTravel
        case "Beach & Outdoor": return .beachOutdoor
        default: return nil
        }
    }
}

private let itemNameAliases: [String: String] = [
    "Driver's licence": "Driver's license",
    "Cash (local currency)": "Cash",
    "Reusable water bottle": "Water bottle",
    "Sunscreen SPF 50+": "Sunscreen",
    "Portable Bluetooth speaker": "Bluetooth speaker",
    "Motion sickness pills": "Motion sickness tablets",
    "Pain relievers": "Painkillers",
    "Sanitary pads / tampons": "Feminine hygiene products",
    "Overseas SIM / portable WiFi": "Portable WiFi device",
]

func canonicalItemName(_ name: String) -> String {
    itemNameAliases[name] ?? name
}

struct ItemPickerCategory {
    let name: String
    let items: [String]
}

let itemPickerCatalog: [ItemPickerCategory] = [
    ItemPickerCategory(name: "Documents", items: [
        "Passport", "ID card", "Visa",
        "Hotel booking", "Travel insurance", "Itinerary",
        "Driver's license", "International driving permit",
        "HK & Macao permit", "Taiwan permit",
        "Vaccination certificate",
        "Flight tickets", "Boarding pass", "Children's passport / ID", "Photo ID copy",
    ]),
    ItemPickerCategory(name: "Clothing", items: [
        "Underwear", "Socks",
        "T-shirt", "Jeans", "Long pants", "Pajamas",
        "Shirt", "Cardigan", "Hoodie",
        "Bra", "Sports bra", "Leggings", "Tights", "Disposable underwear",
        "Shorts",
        "Dress", "Skirt", "Hat", "Belt",
        "Formal wear", "Sweater", "Rain jacket", "Swimsuit", "Nipple covers",
        "Compression socks", "Formal dinner outfit", "Sun hat", "Light rain jacket",
        "Waterproof jacket", "Waterproof shoes", "Warm base layer", "Thermal socks",
        "Windproof jacket", "Heavy winter coat", "Beanie", "Beanie / hat",
        "Formal shirt / blouse", "Dress shoes", "Change of clothes (extra)",
        "Backpack rain cover", "Quick-dry clothing", "Comfortable walking shoes",
    ]),
    ItemPickerCategory(name: "Electronics", items: [
        "Phone charger", "Charging cable", "Portable charger", "Smart watch charger", "Travel adapter",
        "Car charger", "Earphones", "Noise-cancelling headphones",
        "Tablet", "Laptop", "Laptop charger", "E-reader",
        "Camera", "Camera charger", "Pocket camera", "Action camera", "Drone", "Memory card",
        "Selfie stick", "Tripod", "Power strip", "Bluetooth speaker", "Portable Bluetooth speaker",
        "Portable WiFi device", "Waterproof phone case", "Universal adapter",
        "Camera / extra memory card",
    ]),
    ItemPickerCategory(name: "Toiletries", items: [
        "Makeup remover / cleansing oil", "Cotton pads", "Face wash", "Face mask", "Toner", "Serum", "Eye cream", "Facial oil", "Lotion", "Moisturiser",
        "Body lotion",
        "Lip balm", "Sunscreen", "Sunscreen SPF 50+", "Sunscreen for kids",
        "Hair ties", "Comb", "Hair straightener", "Dry shampoo", "Perfume", "Perfume / cologne",
        "Dental floss", "Toothbrush", "Toothpaste", "Mouthwash",
        "Shampoo", "Conditioner", "Body wash",
        "Razor", "Nail clippers",
        "Acne patches", "Deodorant",
    ]),
    ItemPickerCategory(name: "Travel Accessories", items: [
        "Card holder", "Wallet", "Cash",
        "Sunglasses", "Umbrella", "Compact umbrella", "Water bottle",
        "Travel pillow", "Neck pillow", "Eye mask", "Earplugs",
        "Pen", "Packing cubes", "Laundry bag", "Travel towel", "Quick-dry towel", "Microfibre towel",
        "Foldable chair", "Picnic mat", "Headlamp + batteries", "Padlock",
        "Crossbody bag", "Transit card / app", "Snacks", "Nuts", "Trail snacks / energy bars",
        "Business cards", "Favourite toy / comfort item", "Snacks for kids",
    ]),
    ItemPickerCategory(name: "Makeup", items: [
        "Primer", "Foundation", "Concealer",
        "Eyebrow pencil", "Mascara", "Lipstick / Lip gloss", "Eyeliner", "Eyeshadow",
        "Blush", "Highlighter",
        "Setting powder",
        "Makeup brushes", "Makeup sponge",
        "Eyelash curler", "False eyelashes",
        "Colored contacts",
    ]),
    ItemPickerCategory(name: "Jewellery", items: [
        "Earrings", "Necklace", "Ring", "Bracelet", "Watch", "Hair clip",
    ]),
    ItemPickerCategory(name: "Leisure", items: [
        "Book",
        "Gum", "Instant coffee", "Tea bags",
        "Travel board game",
    ]),
    ItemPickerCategory(name: "Health & Wellness", items: [
        "Painkillers", "Cold & flu medicine", "Stomach medicine",
        "Motion sickness tablets", "Antihistamines",
        "Prescription medication", "Daily medication", "Children's medication",
        "Contact lenses",
        "Disposable face masks", "Hand sanitiser", "First aid kit", "Wet wipes",
        "Eye drops", "Throat lozenges",
        "Feminine hygiene products",
        "Vitamin C", "Vitamin D", "Multivitamins", "Probiotics", "Melatonin",
        "Birth control pills", "Condoms", "Anti-diarrhea",
        "Altitude sickness pills", "Insect repellent",
    ]),
    ItemPickerCategory(name: "Winter Travel", items: [
        "Thermal underwear",
        "Wool coat",
        "Snow boots",
        "Gloves", "Beanie", "Scarf",
        "Hand warmers", "Heat patches",
    ]),
    ItemPickerCategory(name: "Beach & Outdoor", items: [
        "Flip flops", "Beach towel", "Waterproof bag",
        "Rash guard", "Swimming goggles",
        "Hiking boots", "Trekking poles",
    ]),
]

private let itemCategoryLookup: [String: ItemCategory] = {
    var lookup: [String: ItemCategory] = [:]
    for category in itemPickerCatalog {
        guard let resolvedCategory = ItemCategory.catalogCategory(named: category.name) else { continue }
        for item in category.items {
            lookup[item] = resolvedCategory
            lookup[canonicalItemName(item)] = resolvedCategory
        }
    }
    return lookup
}()

func categoryForCatalogItem(_ itemName: String) -> ItemCategory? {
    itemCategoryLookup[canonicalItemName(itemName)]
}

func allCatalogItemNames() -> [String] {
    itemPickerCatalog.flatMap(\.items).map(canonicalItemName)
}
