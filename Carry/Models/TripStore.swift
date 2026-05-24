//
//  TripStore.swift
//  Carry
//

import Foundation
import Combine
import SwiftData
import CoreLocation

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
    var remindersEnabled: Bool = true
    var reminderConfigData: Data = Data()
    var countryCode: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    @Relationship(deleteRule: .cascade, inverse: \PackingSection.bundle) var sections: [PackingSection]? = []

    var reminderConfigs: [TripReminderConfig] {
        get {
            guard !reminderConfigData.isEmpty else { return TripReminderConfig.defaults }
            return (try? JSONDecoder().decode([TripReminderConfig].self, from: reminderConfigData)) ?? TripReminderConfig.defaults
        }
        set {
            reminderConfigData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

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
    @Published var myItems: [MyItem] = []
    @Published var isSceneCardDismissedGlobally: Bool
    @Published var isHomeEmptyStateMockEnabled: Bool
    @Published private(set) var draftTrip: TripBundle?

    private let context: ModelContext
    private let defaults = UserDefaults.standard
    private static let sceneCardDismissedGlobalKey = "scene_card_dismissed_global"
    private static let homeEmptyStateMockKey = "home_empty_state_mock_enabled"
    private var didCleanupCorruptedData = false

    init() {
        self.context = ModelContext(CarryApp.container)
        self.isSceneCardDismissedGlobally = defaults.bool(forKey: Self.sceneCardDismissedGlobalKey)
        self.isHomeEmptyStateMockEnabled = defaults.bool(forKey: Self.homeEmptyStateMockKey)
        Task { @MainActor in
            fetchTrips()
        }
    }

    func setHomeEmptyStateMockEnabled(_ enabled: Bool) {
        isHomeEmptyStateMockEnabled = enabled
        defaults.set(enabled, forKey: Self.homeEmptyStateMockKey)
    }

    // MARK: - Persistence

    func refresh() { fetchTrips() }

    func setDraftTrip(_ trip: TripBundle?) {
        draftTrip = trip
    }

    func commitDraftTrip() {
        guard let trip = draftTrip else { return }
        trip.createdAt = Date()
        context.insert(trip)
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.tripSaveFailed)
        }
        draftTrip = nil
        fetchTrips()
        NotificationManager.scheduleReminders(for: trip)
        CarryLogger.shared.log(.tripCreated)
    }

    private func fetchTrips() {
        let descriptor = FetchDescriptor<TripBundle>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let myItemDescriptor = FetchDescriptor<MyItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward), SortDescriptor(\.createdAt, order: .forward)]
        )
        do {
            var fetchedTrips = try context.fetch(descriptor)
            var fetchedMyItems = try context.fetch(myItemDescriptor)

            if !didCleanupCorruptedData && cleanupCorruptedData(trips: fetchedTrips, myItems: fetchedMyItems) {
                didCleanupCorruptedData = true
                try context.save()
                fetchedTrips = try context.fetch(descriptor)
                fetchedMyItems = try context.fetch(myItemDescriptor)
            }

            trips = fetchedTrips
            myItems = fetchedMyItems
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
            myItems = []
        }
    }

    private func cleanupCorruptedData(trips: [TripBundle], myItems: [MyItem]) -> Bool {
        var didDelete = false

        for item in myItems where item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.delete(item)
            didDelete = true
        }

        for trip in trips {
            for section in trip.safeSections {
                let invalidItems = (section.items ?? []).filter {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if !invalidItems.isEmpty {
                    invalidItems.forEach { context.delete($0) }
                    didDelete = true
                }

                let remainingItems = (section.items ?? []).filter {
                    !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if remainingItems.isEmpty {
                    context.delete(section)
                    didDelete = true
                }
            }
        }

        return didDelete
    }

    private func save() {
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.persistFailed, context: "context=save")
        }
        fetchTrips()
    }

    private let defaultMyItemCollection = "Default"

    private func normalizedCollectionName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultMyItemCollection : trimmed
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
        if trip.remindersEnabled {
            NotificationManager.scheduleReminders(for: trip)
        }
    }

    func setRemindersEnabled(_ enabled: Bool, tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.remindersEnabled = enabled
        save()
        if enabled {
            NotificationManager.scheduleReminders(for: trip)
        } else {
            NotificationManager.cancelReminders(forTripId: tripId)
        }
    }

    func addReminder(_ config: TripReminderConfig, tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        var configs = trip.reminderConfigs
        guard !configs.contains(where: { $0.isSameTrigger(as: config) }) else { return }
        configs.append(config)
        trip.reminderConfigs = configs
        save()
        NotificationManager.scheduleReminder(for: trip, config: config)
    }

    func removeReminder(configId: UUID, tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        var configs = trip.reminderConfigs
        configs.removeAll { $0.id == configId }
        trip.reminderConfigs = configs
        save()
        NotificationManager.cancelReminder(tripId: tripId, configId: configId)
    }

    func updateReminderTime(configId: UUID, hour: Int, minute: Int, tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        var configs = trip.reminderConfigs
        guard let index = configs.firstIndex(where: { $0.id == configId }) else { return }
        NotificationManager.cancelReminder(tripId: tripId, configId: configId)
        configs[index].hour = hour
        configs[index].minute = minute
        trip.reminderConfigs = configs
        save()
        NotificationManager.scheduleReminder(for: trip, config: configs[index])
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

    func markTripCompleted(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            for item in section.items ?? [] {
                item.isPacked = true
            }
        }
        save()
        CarryLogger.shared.log(.itemChecked, context: "bulk=all")
    }

    func markTripUncompleted(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            for item in section.items ?? [] {
                item.isPacked = false
            }
        }
        save()
        CarryLogger.shared.log(.itemUnchecked, context: "bulk=all")
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
        let clamped = min(9_999, max(1, quantity))
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
        if !isSceneCardDismissedGlobally {
            isSceneCardDismissedGlobally = true
            defaults.set(true, forKey: Self.sceneCardDismissedGlobalKey)
        }
        save()
    }

    func setSelectedSceneKeys(tripId: UUID, keys: [String]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.selectedSceneKeys = keys
        save()
    }

#if DEBUG
    func debugResetSceneCardDismissState() {
        isSceneCardDismissedGlobally = false
        defaults.set(false, forKey: Self.sceneCardDismissedGlobalKey)
        for trip in trips {
            trip.sceneCardDismissed = false
        }
        save()
    }
#endif

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

    // MARK: - My Items

    func myItemCollections() -> [String] {
        let names = Set(myItems.map { normalizedCollectionName($0.collectionName) })
        return [defaultMyItemCollection] + names.filter { $0 != defaultMyItemCollection }.sorted()
    }

    func myItems(in collectionName: String? = nil) -> [MyItem] {
        let target = normalizedCollectionName(collectionName ?? defaultMyItemCollection)
        return myItems.filter { normalizedCollectionName($0.collectionName) == target }
    }

    @discardableResult
    func addMyItem(
        name: String,
        category: String = "",
        defaultQuantity: Int = 1,
        quantityMode: MyItemQuantityMode = .fixed,
        quantityIntervalDays: Int = 2,
        collectionName: String = "Default"
    ) -> MyItem {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MyItem(name: "", collectionName: normalizedCollectionName(collectionName), category: "", defaultQuantity: 1, quantityMode: quantityMode, quantityIntervalDays: quantityIntervalDays)
        }
        let targetCollection = normalizedCollectionName(collectionName)
        if let existing = myItems.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            && $0.category.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(category.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            && normalizedCollectionName($0.collectionName) == targetCollection
        }) {
            existing.defaultQuantity = max(1, defaultQuantity)
            existing.quantityMode = quantityMode
            existing.quantityIntervalDays = max(1, quantityIntervalDays)
            existing.updatedAt = Date()
            save()
            return existing
        }
        let nextOrder = (myItems.map(\.sortOrder).max() ?? -1) + 1
        let item = MyItem(
            name: trimmed,
            collectionName: targetCollection,
            category: category,
            defaultQuantity: defaultQuantity,
            quantityMode: quantityMode,
            quantityIntervalDays: quantityIntervalDays,
            sortOrder: nextOrder
        )
        context.insert(item)
        save()
        return item
    }

    func copyMyItem(_ item: MyItem) {
        let baseName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = NSLocalizedString("trip.copy_suffix", comment: "")
        let nextOrder = (myItems.map(\.sortOrder).max() ?? -1) + 1
        let copy = MyItem(
            name: baseName + suffix,
            collectionName: normalizedCollectionName(item.collectionName),
            category: item.category,
            defaultQuantity: item.defaultQuantity,
            quantityMode: item.quantityMode,
            quantityIntervalDays: item.quantityIntervalDays,
            sortOrder: nextOrder
        )
        context.insert(copy)
        save()
    }

    func updateMyItem(
        _ item: MyItem,
        name: String,
        category: String,
        defaultQuantity: Int,
        quantityMode: MyItemQuantityMode? = nil,
        quantityIntervalDays: Int? = nil,
        collectionName: String? = nil
    ) {
        item.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.category = category
        item.defaultQuantity = max(1, defaultQuantity)
        if let quantityMode {
            item.quantityMode = quantityMode
        }
        if let quantityIntervalDays {
            item.quantityIntervalDays = max(1, quantityIntervalDays)
        }
        if let collectionName {
            item.collectionName = normalizedCollectionName(collectionName)
        }
        item.updatedAt = Date()
        save()
    }

    func removeMyItem(id: UUID) {
        guard let item = myItems.first(where: { $0.id == id }) else { return }
        context.delete(item)
        save()
    }

    func reorderMyItems(newOrder: [UUID]) {
        let orderedItems = newOrder.compactMap { id in myItems.first(where: { $0.id == id }) }
        let remainingItems = myItems
            .filter { !newOrder.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.createdAt < rhs.createdAt
            }
        let finalOrder = orderedItems + remainingItems
        for (index, item) in finalOrder.enumerated() {
            item.sortOrder = index
        }
        save()
    }

    func addMyItemsToTrip(tripId: UUID, items: [MyItem]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        var sectionsByTitle: [String: PackingSection] = Dictionary(
            uniqueKeysWithValues: trip.safeSections.map { ($0.title, $0) }
        )
        var nextSectionOrder = (trip.safeSections.map(\.sortOrder).max() ?? -1) + 1

        for source in items {
            let sectionTitle = source.category.isEmpty ? "Essentials" : source.category
            let section: PackingSection
            if let existing = sectionsByTitle[sectionTitle] {
                section = existing
            } else {
                section = PackingSection(title: sectionTitle, items: [], sortOrder: nextSectionOrder)
                nextSectionOrder += 1
                sectionsByTitle[sectionTitle] = section
                context.insert(section)
                if trip.sections == nil { trip.sections = [] }
                trip.sections?.append(section)
            }

            let existingNames = Set((section.items ?? []).map { $0.name.lowercased() })
            guard !existingNames.contains(source.name.lowercased()) else { continue }
            let nextOrder = ((section.items ?? []).map(\.sortOrder).max() ?? -1) + 1
            let item = PackingItem(
                name: source.name,
                quantity: source.defaultQuantity,
                isAlert: false,
                sortOrder: nextOrder
            )
            context.insert(item)
            section.items?.append(item)
        }
        save()
    }

    // MARK: - Queries

    func bundle(for id: UUID) -> TripBundle? {
        if let draftTrip, draftTrip.id == id {
            return draftTrip
        }
        return trips.first(where: { $0.id == id })
    }

    // MARK: - Geocoding

    /// Approximate country centroids used as a fallback when CLGeocoder returns
    /// a valid isoCountryCode but a nil CLLocation (can happen for broad queries).
    private static let countryCentroids: [String: (lat: Double, lon: Double)] = [
        "AF": (33.93, 67.71), "AL": (41.15, 20.17), "DZ": (28.03, 1.66),
        "AO": (-11.20, 17.87), "AR": (-38.42, -63.62), "AU": (-25.27, 133.78),
        "AT": (47.52, 14.55), "AZ": (40.14, 47.58), "BD": (23.68, 90.36),
        "BE": (50.50, 4.47), "BR": (-14.24, -51.93), "BG": (42.73, 25.49),
        "CA": (56.13, -106.35), "CL": (-35.68, -71.54), "CN": (35.86, 104.20),
        "CO": (4.57, -74.30), "HR": (45.10, 15.20), "CZ": (49.82, 15.47),
        "DK": (56.26, 9.50), "EG": (26.82, 30.80), "ET": (9.15, 40.49),
        "FI": (61.92, 25.75), "FR": (46.23, 2.21), "DE": (51.17, 10.45),
        "GH": (7.95, -1.02), "GR": (39.07, 21.82), "HK": (22.40, 114.11),
        "HU": (47.16, 19.50), "IN": (20.59, 78.96), "ID": (-0.79, 113.92),
        "IQ": (33.22, 43.68), "IE": (53.41, -8.24), "IL": (31.05, 34.85),
        "IT": (41.87, 12.57), "JP": (36.20, 138.25), "JO": (30.59, 36.24),
        "KZ": (48.02, 66.92), "KE": (-0.02, 37.91), "KR": (35.91, 127.77),
        "KW": (29.31, 47.48), "MY": (4.21, 108.10), "MX": (23.63, -102.55),
        "MA": (31.79, -7.09), "MZ": (-18.67, 35.53), "MM": (16.87, 96.19),
        "NP": (28.39, 84.12), "NL": (52.13, 5.29), "NZ": (-40.90, 174.89),
        "NG": (9.08, 8.68), "NO": (60.47, 8.47), "PK": (30.38, 69.35),
        "PE": (-9.19, -75.02), "PH": (12.88, 121.77), "PL": (51.92, 19.15),
        "PT": (39.40, -8.22), "QA": (25.35, 51.18), "RO": (45.94, 24.97),
        "RU": (61.52, 105.32), "SA": (23.89, 45.08), "SN": (14.50, -14.45),
        "RS": (44.02, 21.01), "SG": (1.35, 103.82), "ZA": (-30.56, 22.94),
        "ES": (40.46, -3.75), "LK": (7.87, 80.77), "SD": (12.86, 30.22),
        "SE": (60.13, 18.64), "CH": (46.82, 8.23), "SY": (34.80, 38.99),
        "TW": (23.70, 121.00), "TZ": (-6.37, 34.89), "TH": (15.87, 100.99),
        "TN": (33.89, 9.54), "TR": (38.96, 35.24), "UA": (48.38, 31.17),
        "AE": (23.42, 53.85), "GB": (55.38, -3.44), "US": (37.09, -95.71),
        "UZ": (41.38, 63.97), "VE": (6.42, -66.59), "VN": (14.06, 108.28),
        "YE": (15.55, 48.52), "ZM": (-13.13, 27.85), "ZW": (-19.02, 29.15),
    ]

    private func coordinatesForCountry(_ code: String) -> (lat: Double, lon: Double)? {
        Self.countryCentroids[code.uppercased()]
    }

    func updateCountryCode(for tripId: UUID, city: String) {
        Task {
            let geocoder = CLGeocoder()
            guard let placemark = try? await geocoder.geocodeAddressString(city).first else { return }
            let code = placemark.isoCountryCode ?? ""
            // Prefer the precise placemark location; fall back to country centroid.
            let coordinate: (lat: Double, lon: Double)?
            if let loc = placemark.location, loc.coordinate.latitude != 0 {
                coordinate = (loc.coordinate.latitude, loc.coordinate.longitude)
            } else if !code.isEmpty, let centroid = coordinatesForCountry(code) {
                coordinate = centroid
            } else {
                coordinate = nil
            }
            guard let coord = coordinate else { return }
            await MainActor.run {
                guard let bundle = bundle(for: tripId) else { return }
                if !code.isEmpty { bundle.countryCode = code }
                bundle.latitude  = coord.lat
                bundle.longitude = coord.lon
                try? context.save()
            }
        }
    }

    func geocodeMissingTrips() {
        // Re-geocode if countryCode is missing OR if coordinates are still zero.
        // The second condition catches the case where a previous geocode call
        // resolved isoCountryCode but returned a nil location, leaving latitude = 0
        // and permanently hiding the country from the map.
        let missing = trips.filter {
            !$0.destinationCity.isEmpty && ($0.countryCode.isEmpty || $0.latitude == 0)
        }
        guard !missing.isEmpty else { return }
        Task {
            let geocoder = CLGeocoder()
            for trip in missing {
                guard let placemark = try? await geocoder.geocodeAddressString(trip.destinationCity).first else { continue }
                let code = placemark.isoCountryCode ?? ""
                // Prefer the precise placemark location; fall back to country centroid
                // so we always save usable coordinates even when CLGeocoder returns a
                // valid country code but a nil CLLocation.
                let coordinate: (lat: Double, lon: Double)?
                if let loc = placemark.location, loc.coordinate.latitude != 0 {
                    coordinate = (loc.coordinate.latitude, loc.coordinate.longitude)
                } else if !code.isEmpty, let centroid = coordinatesForCountry(code) {
                    coordinate = centroid
                } else {
                    coordinate = nil
                }
                guard let coord = coordinate else { continue }
                await MainActor.run {
                    guard let bundle = self.bundle(for: trip.id) else { return }
                    if !code.isEmpty { bundle.countryCode = code }
                    bundle.latitude  = coord.lat
                    bundle.longitude = coord.lon
                    try? self.context.save()
                }
                // Respect CLGeocoder's recommended 1 req/s rate limit
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}
