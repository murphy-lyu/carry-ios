//
//  PackingList.swift
//  Carry
//

import SwiftUI
import SwiftData

// MARK: - PackingItem

@Model
final class PackingItem {
    var id: UUID = UUID()
    var name: String = ""
    var isPacked: Bool = false
    var isAlert: Bool = false
    var sortOrder: Int = 0
    var section: PackingSection?

    init(name: String = "", isPacked: Bool = false, isAlert: Bool = false, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.isPacked = isPacked
        self.isAlert = isAlert
        self.sortOrder = sortOrder
    }
}

// MARK: - PackingSection

@Model
final class PackingSection {
    var id: UUID = UUID()
    var title: String = ""
    @Relationship(deleteRule: .cascade, inverse: \PackingItem.section) var items: [PackingItem]? = []
    var bundle: TripBundle?

    init(title: String = "", items: [PackingItem] = []) {
        self.id = UUID()
        self.title = title
        self.items = items
    }

    var sortedItems: [PackingItem] {
        (items ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }
}

// MARK: - Color Extension

extension Color {
    static let alertOrange = Color(red: 216 / 255, green: 90 / 255, blue: 48 / 255)
}
