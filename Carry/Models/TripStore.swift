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
    var dismissedSurpriseNames: [String] = []
    var nudgeShown: Bool = false
    var sceneCardDismissed: Bool = false
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

    var safeSections: [PackingSection] { (sections ?? []).sorted { $0.sortOrder < $1.sortOrder } }
    var packedCount: Int { safeSections.flatMap { $0.items ?? [] }.filter { $0.isPacked && !$0.name.isEmpty }.count }
    var totalCount:  Int { safeSections.flatMap { $0.items ?? [] }.filter { !$0.name.isEmpty }.count }

    /// Locale-aware date range, computed at display time so it follows the current app language.
    var localizedDateRange: String {
        let returnDate = Calendar.current.date(byAdding: .day, value: days, to: departureDate) ?? departureDate
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(fmt.string(from: departureDate)) – \(fmt.string(from: returnDate))"
    }
}

// MARK: - TripStore

final class TripStore: ObservableObject {
    @Published var trips: [TripBundle] = []

    private let context: ModelContext

    init() {
        self.context = ModelContext(CarryApp.container)
        Task { @MainActor in
            fetchTrips()
        }
    }

    // MARK: - Persistence

    func refresh() { fetchTrips() }

    private func fetchTrips() {
        let descriptor = FetchDescriptor<TripBundle>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        do {
            trips = try context.fetch(descriptor)
            for trip in trips {
                if trip.sections == nil {
                    CarryLogger.shared.log(.dataCorrupted, context: "context=fetchTrips_nil_sections")
                } else if trip.sections?.isEmpty == true {
                    CarryLogger.shared.log(.orphanTrip)
                } else {
                    for section in trip.safeSections where (section.items ?? []).isEmpty {
                        CarryLogger.shared.log(.orphanSection)
                    }
                }
            }
        } catch {
            CarryLogger.shared.log(.loadFailed, context: "context=fetchTrips")
            trips = []
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.persistFailed, context: "context=save")
        }
        fetchTrips()
    }

    // MARK: - Mutations

    func addTrip(_ bundle: TripBundle) {
        context.insert(bundle)
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.tripSaveFailed)
        }
        fetchTrips()
        NotificationManager.scheduleReminders(for: bundle)
        CarryLogger.shared.log(.tripCreated)
    }

    func removeTrip(withId id: UUID) {
        guard let trip = trips.first(where: { $0.id == id }) else { return }
        NotificationManager.cancelReminders(forTripId: id)
        context.delete(trip)
        save()
        CarryLogger.shared.log(.tripDeleted)
    }

    @discardableResult
    func duplicateTrip(withId id: UUID) -> UUID? {
        guard let originalIndex = trips.firstIndex(where: { $0.id == id }) else {
            CarryLogger.shared.log(.duplicateFailed, context: "context=trip_not_found")
            return nil
        }
        let original = trips[originalIndex]
        let copySuffix = NSLocalizedString("trip.copy_suffix", comment: "")
        let newSections = original.safeSections.map { section -> PackingSection in
            let items = section.sortedItems
                .filter { !$0.name.isEmpty }
                .enumerated()
                .map { idx, item in
                    PackingItem(name: item.name, quantity: item.quantity, isPacked: false, isAlert: item.isAlert, sortOrder: idx)
                }
            return PackingSection(title: section.title, items: items, sortOrder: section.sortOrder)
        }
        let newBundle = TripBundle(
            name: original.name + copySuffix,
            destinationCity: original.destinationCity,
            days: original.days,
            dateRange: original.dateRange,
            departureDate: original.departureDate,
            createdAt: Date(),
            selectedSceneKeys: original.selectedSceneKeys,
            sections: newSections
        )
        context.insert(newBundle)
        // Insert in-memory first to avoid full-list refetch jumpiness in UI.
        let insertIndex = min(originalIndex + 1, trips.count)
        trips.insert(newBundle, at: insertIndex)
        DispatchQueue.main.async {
            do {
                try self.context.save()
            } catch {
                CarryLogger.shared.log(.duplicateFailed, context: "context=save_failed")
            }
        }
        CarryLogger.shared.log(.tripDuplicated)
        return newBundle.id
    }

    func updateTripInfo(tripId: UUID, info: TripInfo) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.name = info.name
        trip.destinationCity = info.destinationCity
        trip.departureDate = info.departureDate
        trip.days = info.durationDays
        trip.dateRange = info.dateRangeDisplay
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.tripEditSaveFailed)
        }
        fetchTrips()
        NotificationManager.scheduleReminders(for: trip)
    }

    func toggleItem(tripId: UUID, itemId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                item.isPacked.toggle()
                CarryLogger.shared.log(item.isPacked ? .itemChecked : .itemUnchecked)
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
        fetchTrips()  // refresh UI without persisting the empty item to disk
        return newItem.id
    }

    func updateItemName(tripId: UUID, itemId: UUID, name: String) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                let wasNew = item.name.isEmpty
                item.name = name
                do {
                    try context.save()
                } catch {
                    CarryLogger.shared.log(wasNew ? .itemAddFailed : .persistFailed,
                                           context: "context=updateItemName")
                }
                fetchTrips()
                if wasNew && !name.isEmpty {
                    CarryLogger.shared.log(.itemAdded)
                }
                return
            }
        }
    }

    func updateItemQuantity(tripId: UUID, itemId: UUID, quantity: Int) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let clamped = max(1, quantity)
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                guard item.quantity != clamped else { return }
                item.quantity = clamped
                save()
                return
            }
        }
    }

    func removeItem(tripId: UUID, itemId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                let wasNamed = !item.name.isEmpty
                context.delete(item)
                section.items?.removeAll { $0.id == itemId }
                do {
                    try context.save()
                } catch {
                    CarryLogger.shared.log(.itemDeleteFailed, context: "context=removeItem")
                }
                fetchTrips()
                if wasNamed { CarryLogger.shared.log(.itemDeleted) }
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
        if newOrder.count > items.count {
            CarryLogger.shared.log(.sortIndexOutOfBounds,
                                   context: "index=\(newOrder.count) count=\(items.count)")
        }
        for (index, id) in newOrder.enumerated() {
            if let item = items.first(where: { $0.id == id }) {
                item.sortOrder = index
            }
        }
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.reorderSaveFailed, context: "context=reorderItems")
        }
        fetchTrips()
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
        var customItemsBySection: [String: [(name: String, quantity: Int, isPacked: Bool)]] = [:]
        let presetNames = Set(presetItemNames(forSceneKeys: keys).map { $0.lowercased() })

        for section in trip.safeSections {
            for item in section.items ?? [] {
                let key = item.name.lowercased()
                oldPackedByName[key] = item.isPacked
                if !presetNames.contains(key) {
                    customItemsBySection[section.title, default: []].append((item.name, item.quantity, item.isPacked))
                }
            }
        }

        // Build fresh sections (sortOrder assigned by generatePackingSections position)
        let newSections = generatePackingSections(selectedScenes: keys, tripDays: trip.days)
        for (index, section) in newSections.enumerated() { section.sortOrder = index }

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
                        quantity: custom.quantity,
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
        CarryLogger.shared.log(.autoPackTriggered, context: "scenes=\(keys.count)")
    }

    /// Returns all unique preset item names for the given scene keys (including base items).
    private func presetItemNames(forSceneKeys keys: [String]) -> [String] {
        var names = Set<String>()
        baseItems.forEach { names.insert($0.name) }
        keys.compactMap { sceneItemMap[$0] }.flatMap { $0 }.forEach { names.insert($0.name) }
        return Array(names)
    }

    func reorderSections(tripId: UUID, newOrder: [UUID]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let sectionCount = trip.safeSections.count
        if newOrder.count > sectionCount {
            CarryLogger.shared.log(.sortIndexOutOfBounds,
                                   context: "index=\(newOrder.count) count=\(sectionCount)")
        }
        for (index, id) in newOrder.enumerated() {
            if let section = trip.safeSections.first(where: { $0.id == id }) {
                section.sortOrder = index
            }
        }
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.reorderSaveFailed, context: "context=reorderSections")
        }
        fetchTrips()
        CarryLogger.shared.log(.sectionReordered)
    }

    @discardableResult
    func addSection(tripId: UUID, name: String) -> PackingSection? {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return nil }
        let nextOrder = (trip.safeSections.map(\.sortOrder).max() ?? -1) + 1
        let blankItem = PackingItem(name: "", isAlert: false, sortOrder: 0)
        let section = PackingSection(title: name, items: [blankItem], sortOrder: nextOrder)
        context.insert(blankItem)
        context.insert(section)
        if trip.sections == nil { trip.sections = [] }
        trip.sections?.append(section)
        save()
        return section
    }

    func removeSection(tripId: UUID, sectionId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let section = trip.safeSections.first(where: { $0.id == sectionId }) else { return }
        context.delete(section)
        trip.sections?.removeAll { $0.id == sectionId }
        save()
    }

    func renameSection(tripId: UUID, sectionId: UUID, newName: String) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let section = trip.safeSections.first(where: { $0.id == sectionId }) else { return }
        section.title = newName
        save()
    }

    func insertPendingSections(tripId: UUID, sections: [PackingSection]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in sections {
            context.insert(section)
            for item in section.items ?? [] {
                context.insert(item)
            }
            if trip.sections == nil { trip.sections = [] }
            trip.sections?.append(section)
        }
        save()
    }

    /// Adds scene keys to a trip and merges the supplied sections.
    /// Used by the suggestion preview flow so scene context is saved alongside the items.
    func addScenesAndMerge(tripId: UUID, keys: [String], sections: [PackingSection]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let existing = Set(trip.selectedSceneKeys)
        trip.selectedSceneKeys.append(contentsOf: keys.filter { !existing.contains($0) })
        mergeItems(tripId: tripId, sections: sections)
    }

    /// Merges additional items into an existing trip.
    /// Sections with a matching title have items appended (skipping name duplicates).
    /// Sections with no matching title are appended as new sections.
    func mergeItems(tripId: UUID, sections newSections: [PackingSection]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let existing = trip.safeSections
        var nextSectionOrder = (existing.map(\.sortOrder).max() ?? -1) + 1

        for newSection in newSections {
            if let existingSection = existing.first(where: { $0.title == newSection.title }) {
                let existingNames = Set((existingSection.items ?? []).map { $0.name.lowercased() })
                let maxOrder = ((existingSection.items ?? []).map(\.sortOrder).max() ?? -1)
                var offset = 0
                for item in (newSection.items ?? []) {
                    guard !existingNames.contains(item.name.lowercased()) else { continue }
                    item.sortOrder = maxOrder + 1 + offset
                    offset += 1
                    context.insert(item)
                    existingSection.items?.append(item)
                }
            } else {
                newSection.sortOrder = nextSectionOrder
                nextSectionOrder += 1
                context.insert(newSection)
                for item in newSection.items ?? [] {
                    context.insert(item)
                }
                if trip.sections == nil { trip.sections = [] }
                trip.sections?.append(newSection)
            }
        }
        save()
    }

    func dismissSurpriseItem(tripId: UUID, itemName: String) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              !trip.dismissedSurpriseNames.contains(itemName) else { return }
        trip.dismissedSurpriseNames.append(itemName)
        save()
    }

    func markNudgeShown(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.nudgeShown = true
        save()
    }

    func dismissSceneCard(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.sceneCardDismissed = true
        save()
    }

    /// Adds a surprise item to the most relevant existing section, or creates a new one.
    func addSurpriseItem(tripId: UUID, item: SurpriseItem) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let categoryTitle = item.category.rawValue
        if let section = trip.safeSections.first(where: { $0.title == categoryTitle }) {
            let existing = section.items ?? []
            let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
            let newItem = PackingItem(name: item.name, isAlert: false, sortOrder: nextOrder)
            context.insert(newItem)
            section.items?.append(newItem)
        } else {
            let nextSectionOrder = (trip.safeSections.map(\.sortOrder).max() ?? -1) + 1
            let newItem = PackingItem(name: item.name, isAlert: false, sortOrder: 0)
            let newSection = PackingSection(title: categoryTitle, items: [newItem], sortOrder: nextSectionOrder)
            context.insert(newItem)
            context.insert(newSection)
            if trip.sections == nil { trip.sections = [] }
            trip.sections?.append(newSection)
        }
        dismissSurpriseItem(tripId: tripId, itemName: item.name)
        save()
    }

    // MARK: - Queries

    func bundle(for id: UUID) -> TripBundle? {
        trips.first(where: { $0.id == id })
    }
}
