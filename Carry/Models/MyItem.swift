//
//  MyItem.swift
//  Carry
//

import Foundation
import SwiftData

@Model
final class MyItem {
    var id: UUID = UUID()
    var name: String = ""
    var collectionName: String = "Default"
    var category: String = ""
    var defaultQuantity: Int = 1
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        collectionName: String = "Default",
        category: String,
        defaultQuantity: Int = 1,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.collectionName = collectionName.isEmpty ? "Default" : collectionName
        self.category = category
        self.defaultQuantity = max(1, defaultQuantity)
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
