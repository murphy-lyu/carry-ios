//
//  MyItem.swift
//  Carry
//

import Foundation
import SwiftData

enum MyItemQuantityMode: String, Codable, CaseIterable {
    case fixed
    case tripDays
    case everyNDays
}

@Model
final class MyItem {
    var id: UUID = UUID()
    var name: String = ""
    var collectionName: String = "Default"
    var category: String = ""
    var defaultQuantity: Int = 1
    var quantityModeRaw: String = MyItemQuantityMode.fixed.rawValue
    var quantityIntervalDays: Int = 2
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        collectionName: String = "Default",
        category: String,
        defaultQuantity: Int = 1,
        quantityMode: MyItemQuantityMode = .fixed,
        quantityIntervalDays: Int = 2,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.collectionName = collectionName.isEmpty ? "Default" : collectionName
        self.category = category
        self.defaultQuantity = max(1, defaultQuantity)
        self.quantityModeRaw = quantityMode.rawValue
        self.quantityIntervalDays = max(1, quantityIntervalDays)
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var quantityMode: MyItemQuantityMode {
        get {
            MyItemQuantityMode(rawValue: quantityModeRaw) ?? .fixed
        }
        set {
            quantityModeRaw = newValue.rawValue
        }
    }

    func resolvedDefaultQuantity(tripDays: Int) -> Int {
        switch quantityMode {
        case .fixed:
            return max(1, defaultQuantity)
        case .tripDays:
            return max(1, tripDays)
        case .everyNDays:
            let interval = max(1, quantityIntervalDays)
            return max(1, Int(ceil(Double(max(1, tripDays)) / Double(interval))))
        }
    }
}
