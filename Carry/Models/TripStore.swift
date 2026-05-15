//
//  TripStore.swift
//  Carry
//

import Foundation
import Combine
import SwiftData

// MARK: - TripBundle

@Model
final class TripBundle {
    var id: UUID = UUID()
    var name: String = ""
    var destinationCity: String = ""
    var days: Int = 1
    var dateRange: String = ""
    var departureDate: Date = Date()
    var createdAt: Date = Date()
    var selectedSceneKeys: [String] = []
    @Relationship(deleteRule: .cascade, inverse: \PackingSection.bundle) var sections: [PackingSection]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        destinationCity: String = "",
        days: Int = 1,
        dateRange: String = "",
        departureDate: Date = Date(),
        createdAt: Date = Date(),
        selectedSceneKeys: [String] = [],
        sections: [PackingSection] = []
    ) {
        self.id = id
        self.name = name
        self.destinationCity = destinationCity
        self.days = days
        self.dateRange = dateRange
        self.departureDate = departureDate
        self.createdAt = createdAt
        self.selectedSceneKeys = selectedSceneKeys
        self.sections = sections
    }

    var safeSections: [PackingSection] { sections ?? [] }
    var packedCount: Int { safeSections.flatMap { $0.items ?? [] }.filter(\.isPacked).count }
    var totalCount:  Int { safeSections.flatMap { $0.items ?? [] }.count }
}

// MARK: - TripStore

final class TripStore: ObservableObject {
    @Published var trips: [TripBundle] = []

    private let context: ModelContext

    init() {
        self.context = ModelContext(CarryApp.container)
        fetchTrips()
    }

    // MARK: - Persistence

    private func fetchTrips() {
        let descriptor = FetchDescriptor<TripBundle>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        trips = (try? context.fetch(descriptor)) ?? []
    }

    private func save() {
        try? context.save()
        fetchTrips()
    }

    // MARK: - Mutations

    func addTrip(_ bundle: TripBundle) {
        context.insert(bundle)
        save()
        NotificationManager.scheduleReminders(for: bundle)
    }

    func removeTrip(withId id: UUID) {
        guard let trip = trips.first(where: { $0.id == id }) else { return }
        NotificationManager.cancelReminders(forTripId: id)
        context.delete(trip)
        save()
    }

    func updateTripInfo(tripId: UUID, info: TripInfo) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.name = info.name
        trip.destinationCity = info.destinationCity
        trip.departureDate = info.departureDate
        trip.days = info.durationDays
        trip.dateRange = info.dateRangeDisplay
        save()
        NotificationManager.scheduleReminders(for: trip)
    }

    func toggleItem(tripId: UUID, itemId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                item.isPacked.toggle()
                save()
                return
            }
        }
    }

    @discardableResult
    func addItem(tripId: UUID, sectionIndex: Int) -> UUID {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return UUID() }
        let sections = trip.safeSections
        guard sections.indices.contains(sectionIndex) else { return UUID() }
        let section = sections[sectionIndex]
        let existing = section.items ?? []
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let newItem = PackingItem(name: "", isAlert: false, sortOrder: nextOrder)
        context.insert(newItem)
        if section.items == nil { section.items = [] }
        section.items?.append(newItem)
        save()
        return newItem.id
    }

    func updateItemName(tripId: UUID, itemId: UUID, name: String) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                item.name = name
                save()
                return
            }
        }
    }

    func removeItem(tripId: UUID, itemId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                context.delete(item)
                section.items?.removeAll { $0.id == itemId }
                save()
                return
            }
        }
    }

    /// Reorders items within a section. `newOrder` is an array of item IDs in
    /// the desired final order. Items not in `newOrder` are left untouched at
    /// the end. Sort orders are rewritten as 0, 1, 2, … so subsequent inserts
    /// continue using `max + 1`.
    func reorderItems(tripId: UUID, sectionId: UUID, newOrder: [UUID]) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let section = trip.safeSections.first(where: { $0.id == sectionId }) else {
            return
        }
        let items = section.items ?? []
        for (index, id) in newOrder.enumerated() {
            if let item = items.first(where: { $0.id == id }) {
                item.sortOrder = index
            }
        }
        save()
    }

    /// Regenerates the trip's packing list based on a new scene selection.
    /// Strategy:
    /// - Build a name → isPacked map from the existing sections (case-insensitive)
    /// - Compute fresh sections from the new scene keys
    /// - Restore isPacked for any item whose name appears in the old map
    /// - Preserve user-added items (items whose names are not in the new
    ///   preset) by appending them to the section that matches their old
    ///   category title; if no matching section exists, drop them
    /// - Replace the trip's sections wholesale
    func regenerateScenes(tripId: UUID, keys: [String]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }

        // Capture old state
        var oldPackedByName: [String: Bool] = [:]
        var customItemsBySection: [String: [(name: String, isPacked: Bool)]] = [:]
        let presetNames = Set(presetItemNames(forSceneKeys: keys).map { $0.lowercased() })

        for section in trip.safeSections {
            for item in section.items ?? [] {
                let key = item.name.lowercased()
                oldPackedByName[key] = item.isPacked
                if !presetNames.contains(key) {
                    customItemsBySection[section.title, default: []].append((item.name, item.isPacked))
                }
            }
        }

        // Build fresh sections
        let newSections = generatePackingSections(selectedScenes: keys)

        // Restore packed states + append custom items to matching section
        for section in newSections {
            for item in section.items ?? [] {
                if let wasPacked = oldPackedByName[item.name.lowercased()] {
                    item.isPacked = wasPacked
                }
            }
            if let customs = customItemsBySection[section.title] {
                let nextOrderStart = ((section.items ?? []).map(\.sortOrder).max() ?? -1) + 1
                for (offset, custom) in customs.enumerated() {
                    let item = PackingItem(
                        name: custom.name,
                        isPacked: custom.isPacked,
                        isAlert: false,
                        sortOrder: nextOrderStart + offset
                    )
                    section.items?.append(item)
                }
            }
        }

        // Replace
        // Delete old sections explicitly (cascade should handle items)
        for section in trip.safeSections {
            context.delete(section)
        }
        // Insert new sections + their items
        for section in newSections {
            context.insert(section)
            for item in section.items ?? [] {
                context.insert(item)
            }
        }
        trip.sections = newSections
        trip.selectedSceneKeys = keys
        save()
    }

    /// Returns all unique preset item names for the given scene keys (including base items).
    private func presetItemNames(forSceneKeys keys: [String]) -> [String] {
        var names = Set<String>()
        baseItems.forEach { names.insert($0.name) }
        keys.compactMap { sceneItemMap[$0] }.flatMap { $0 }.forEach { names.insert($0.name) }
        return Array(names)
    }

    // MARK: - Queries

    func bundle(for id: UUID) -> TripBundle? {
        trips.first(where: { $0.id == id })
    }
}
