//
//  TripStore.swift
//  Carry
//

import Foundation
import Combine
import SwiftData
import CoreLocation

// MARK: - DestinationEntry

/// A single resolved destination (countryCode + coordinates).
/// Used to store the 2nd, 3rd… cities of a multi-destination trip.
struct DestinationEntry: Codable {
    let countryCode: String
    let latitude: Double
    let longitude: Double
}

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
    /// JSON-encoded [DestinationEntry] for the 2nd+ cities in a multi-destination trip.
    var additionalDestinationsData: Data = Data()
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

    /// Decoded list of extra destinations (2nd city onward) for multi-destination trips.
    var additionalDestinations: [DestinationEntry] {
        get {
            guard !additionalDestinationsData.isEmpty else { return [] }
            do {
                return try JSONDecoder().decode([DestinationEntry].self, from: additionalDestinationsData)
            } catch {
                CarryLogger.shared.log(.destinationDecodeFailed,
                    context: "error=\(error.localizedDescription)")
                return []
            }
        }
        set {
            additionalDestinationsData = (try? JSONEncoder().encode(newValue)) ?? Data()
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
    @Published var pendingPackingToast: String?

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

    // MARK: - Backup & Restore

    /// Restore all data from the automatic device-local JSON backup.
    @discardableResult
    func restoreFromBackup() throws -> (trips: Int, myItems: Int) {
        let result = try DataBackupManager.shared.restore(into: context)
        fetchTrips()
        return result
    }

    /// Restore all data from raw JSON data read from a user-selected file.
    @discardableResult
    func restoreFromData(_ data: Data) throws -> (trips: Int, myItems: Int) {
        let result = try DataBackupManager.shared.restoreFromData(data, into: context)
        fetchTrips()
        return result
    }

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
            // Keep the JSON backup in sync after every data load.
            // Encoding a few trips worth of JSON is sub-millisecond, so doing it
            // inline here is safe and ensures the backup is always up-to-date.
            DataBackupManager.shared.backup(trips: fetchedTrips, myItems: fetchedMyItems)
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

    private func save(_ caller: String = #function) {
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.persistFailed, context: "caller=\(caller)")
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
        CarryLogger.shared.log(.tripCompleted)
    }

    func markTripUncompleted(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            for item in section.items ?? [] {
                item.isPacked = false
            }
        }
        save()
        CarryLogger.shared.log(.tripUncompleted)
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
        CarryLogger.shared.log(.sectionAdded)
        return section
    }

    func removeSection(tripId: UUID, sectionId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let section = trip.safeSections.first(where: { $0.id == sectionId }) else { return }
        context.delete(section)
        trip.sections?.removeAll { $0.id == sectionId }
        save()
        CarryLogger.shared.log(.sectionDeleted)
    }

    func renameSection(tripId: UUID, sectionId: UUID, newName: String) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let section = trip.safeSections.first(where: { $0.id == sectionId }) else { return }
        section.title = newName
        save()
        CarryLogger.shared.log(.sectionRenamed)
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
        CarryLogger.shared.log(.myItemAdded)
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
        CarryLogger.shared.log(.myItemDeleted)
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

    // MARK: - City lookup table

    /// Local city → (countryCode, lat, lon) table.
    /// Covers ~600 cities/regions in Chinese and English names.
    /// Used as the primary resolver so the globe works without network access.
    private static let cityLookup: [String: (code: String, lat: Double, lon: Double)] = {
        // (cityName, countryCode, lat, lon)
        let entries: [(String, String, Double, Double)] = [

            // ── 中国大陆 ──────────────────────────────────────────────────────
            ("北京",    "CN",  39.91, 116.39), ("上海",    "CN",  31.23, 121.47),
            ("广州",    "CN",  23.13, 113.27), ("深圳",    "CN",  22.54, 114.06),
            ("成都",    "CN",  30.66, 104.08), ("杭州",    "CN",  30.25, 120.16),
            ("武汉",    "CN",  30.59, 114.31), ("西安",    "CN",  34.27, 108.95),
            ("南京",    "CN",  32.06, 118.80), ("重庆",    "CN",  29.56, 106.55),
            ("天津",    "CN",  39.13, 117.20), ("苏州",    "CN",  31.30, 120.62),
            ("青岛",    "CN",  36.07, 120.37), ("大连",    "CN",  38.91, 121.60),
            ("厦门",    "CN",  24.48, 118.09), ("哈尔滨",  "CN",  45.75, 126.63),
            ("长春",    "CN",  43.88, 125.32), ("沈阳",    "CN",  41.81, 123.43),
            ("济南",    "CN",  36.67, 116.99), ("郑州",    "CN",  34.75, 113.63),
            ("昆明",    "CN",  25.04, 102.71), ("贵阳",    "CN",  26.58, 106.71),
            ("南昌",    "CN",  28.69, 115.86), ("合肥",    "CN",  31.86, 117.28),
            ("福州",    "CN",  26.08, 119.30), ("石家庄",  "CN",  38.05, 114.48),
            ("太原",    "CN",  37.87, 112.55), ("南宁",    "CN",  22.82, 108.32),
            ("长沙",    "CN",  28.23, 112.94), ("乌鲁木齐","CN",  43.83,  87.62),
            ("拉萨",    "CN",  29.65,  91.13), ("兰州",    "CN",  36.06, 103.83),
            ("西宁",    "CN",  36.62, 101.78), ("银川",    "CN",  38.47, 106.27),
            ("呼和浩特","CN",  40.84, 111.75), ("海口",    "CN",  20.04, 110.32),
            ("南通",    "CN",  31.98, 120.89), ("无锡",    "CN",  31.57, 120.30),
            ("宁波",    "CN",  29.87, 121.54), ("温州",    "CN",  28.00, 120.67),
            ("义乌",    "CN",  29.31, 120.07), ("嘉兴",    "CN",  30.75, 120.76),
            ("绍兴",    "CN",  29.99, 120.54), ("舟山",    "CN",  29.98, 122.21),
            ("南阳",    "CN",  33.00, 112.53), ("洛阳",    "CN",  34.62, 112.45),
            ("烟台",    "CN",  37.54, 121.39), ("威海",    "CN",  37.52, 122.12),
            ("潍坊",    "CN",  36.71, 119.16), ("临沂",    "CN",  35.10, 118.36),
            ("唐山",    "CN",  39.63, 118.18), ("保定",    "CN",  38.87, 115.46),
            ("邯郸",    "CN",  36.62, 114.53), ("廊坊",    "CN",  39.54, 116.69),
            ("东莞",    "CN",  23.02, 113.75), ("佛山",    "CN",  23.02, 113.12),
            ("珠海",    "CN",  22.27, 113.56), ("汕头",    "CN",  23.35, 116.68),
            ("中山",    "CN",  22.52, 113.39), ("惠州",    "CN",  23.11, 114.42),
            ("揭阳",    "CN",  23.55, 116.37), ("湛江",    "CN",  21.27, 110.36),
            ("泉州",    "CN",  24.87, 118.68), ("漳州",    "CN",  24.51, 117.65),
            ("南宁",    "CN",  22.82, 108.32), ("柳州",    "CN",  24.33, 109.41),
            ("桂林",    "CN",  25.27, 110.29), ("三亚",    "CN",  18.25, 109.51),
            ("丽江",    "CN",  26.87, 100.23), ("张家界",  "CN",  29.12, 110.48),
            ("九寨沟",  "CN",  33.26, 103.92), ("黄山",    "CN",  29.72, 118.33),
            ("香格里拉","CN",  27.83,  99.71), ("西双版纳","CN",  22.01, 100.80),
            ("大理",    "CN",  25.60, 100.27), ("腾冲",    "CN",  25.02,  98.49),
            ("敦煌",    "CN",  40.14,  94.66), ("喀什",    "CN",  39.47,  75.98),
            ("伊犁",    "CN",  43.92,  81.32), ("吐鲁番",  "CN",  42.95,  89.19),
            ("额尔古纳","CN",  50.24, 120.19), ("呼伦贝尔","CN",  49.22, 119.74),
            ("稻城",    "CN",  29.04, 100.30), ("色达",    "CN",  32.27, 100.34),
            ("甘南",    "CN",  34.99, 102.91), ("阿坝",    "CN",  32.90, 101.70),
            ("峨眉山",  "CN",  29.60, 103.48), ("乐山",    "CN",  29.56, 103.77),
            ("都江堰",  "CN",  31.00, 103.62), ("黄龙",    "CN",  32.75, 103.82),
            ("武夷山",  "CN",  27.77, 118.05), ("庐山",    "CN",  29.57, 116.04),
            ("张掖",    "CN",  38.93, 100.46), ("嘉峪关",  "CN",  39.77,  98.29),

            // ── 港澳台 ──────────────────────────────────────────────────────
            ("香港",    "HK",  22.40, 114.11), ("澳门",    "MO",  22.20, 113.55),
            ("台北",    "TW",  25.05, 121.56), ("高雄",    "TW",  22.63, 120.30),
            ("台中",    "TW",  24.15, 120.67), ("台南",    "TW",  22.99, 120.21),
            ("花莲",    "TW",  23.99, 121.60), ("垦丁",    "TW",  21.94, 120.82),

            // ── 日本 ────────────────────────────────────────────────────────
            ("东京",    "JP",  35.69, 139.69), ("大阪",    "JP",  34.69, 135.50),
            ("京都",    "JP",  35.01, 135.77), ("福冈",    "JP",  33.59, 130.40),
            ("札幌",    "JP",  43.06, 141.35), ("冲绳",    "JP",  26.21, 127.68),
            ("那霸",    "JP",  26.21, 127.68), ("名古屋",  "JP",  35.18, 136.91),
            ("横滨",    "JP",  35.44, 139.64), ("神户",    "JP",  34.69, 135.20),
            ("奈良",    "JP",  34.68, 135.83), ("广岛",    "JP",  34.39, 132.46),
            ("仙台",    "JP",  38.27, 140.87), ("金泽",    "JP",  36.56, 136.66),
            ("长崎",    "JP",  32.74, 129.87), ("熊本",    "JP",  32.80, 130.71),
            ("箱根",    "JP",  35.23, 139.11), ("轻井泽",  "JP",  36.35, 138.60),
            ("富士山",  "JP",  35.36, 138.73), ("白川乡",  "JP",  36.26, 136.91),
            ("镰仓",    "JP",  35.32, 139.55), ("日光",    "JP",  36.75, 139.60),

            // ── 韩国 ────────────────────────────────────────────────────────
            ("首尔",    "KR",  37.57, 126.98), ("釜山",    "KR",  35.10, 129.04),
            ("济州岛",  "KR",  33.49, 126.53), ("仁川",    "KR",  37.46, 126.71),
            ("大邱",    "KR",  35.87, 128.60), ("光州",    "KR",  35.16, 126.85),
            ("庆州",    "KR",  35.86, 129.22), ("全州",    "KR",  35.82, 127.15),

            // ── 东南亚 ──────────────────────────────────────────────────────
            ("曼谷",    "TH",  13.75, 100.52), ("清迈",    "TH",  18.79,  98.98),
            ("普吉",    "TH",   7.89,  98.40), ("普吉岛",  "TH",   7.89,  98.40),
            ("芭提雅",  "TH",  12.93, 100.88), ("苏梅岛",  "TH",   9.53,  99.93),
            ("甲米",    "TH",   8.09,  98.91), ("清莱",    "TH",  19.91,  99.83),
            ("河内",    "VN",  21.03, 105.85), ("胡志明",  "VN",  10.82, 106.63),
            ("胡志明市","VN",  10.82, 106.63), ("岘港",    "VN",  16.05, 108.22),
            ("会安",    "VN",  15.88, 108.34), ("芽庄",    "VN",  12.24, 109.19),
            ("下龙湾",  "VN",  20.95, 107.06), ("顺化",    "VN",  16.47, 107.59),
            ("富国岛",  "VN",  10.29, 103.98), ("大叻",    "VN",  11.94, 108.44),
            ("新加坡",  "SG",   1.35, 103.82),
            ("吉隆坡",  "MY",   3.14, 101.69), ("槟城",    "MY",   5.41, 100.33),
            ("兰卡威",  "MY",   6.35, 100.13), ("亚庇",    "MY",   5.98, 116.07),
            ("古晋",    "MY",   1.55, 110.34), ("马六甲",  "MY",   2.19, 102.25),
            ("雅加达",  "ID",  -6.21, 106.85), ("巴厘",    "ID",  -8.34, 115.09),
            ("巴厘岛",  "ID",  -8.34, 115.09), ("日惹",    "ID",  -7.80, 110.36),
            ("苏拉巴亚","ID",  -7.25, 112.75), ("龙目岛",  "ID",  -8.57, 116.35),
            ("科莫多",  "ID",  -8.55, 119.49), ("望加锡",  "ID",  -5.13, 119.42),
            ("马尼拉",  "PH",  14.60, 120.98), ("宿务",    "PH",  10.32, 123.89),
            ("长滩岛",  "PH",  11.96, 121.92), ("巴拉望",  "PH",   9.84, 118.74),
            ("仰光",    "MM",  16.87,  96.19), ("蒲甘",    "MM",  21.17,  94.86),
            ("曼德勒",  "MM",  21.97,  96.08), ("茵莱湖",  "MM",  20.58,  96.90),
            ("金边",    "KH",  11.56, 104.92), ("暹粒",    "KH",  13.36, 103.86),
            ("吴哥",    "KH",  13.41, 103.87),
            ("万象",    "LA",  17.97, 102.60), ("琅勃拉邦","LA",  19.89, 102.14),
            ("科伦坡",  "LK",   6.93,  79.85), ("康提",    "LK",   7.29,  80.63),
            ("加德满都","NP",  27.72,  85.32), ("博卡拉",  "NP",  28.21,  83.99),
            ("达卡",    "BD",  23.81,  90.41),

            // ── 南亚 ────────────────────────────────────────────────────────
            ("孟买",    "IN",  19.08,  72.88), ("新德里",  "IN",  28.61,  77.21),
            ("德里",    "IN",  28.61,  77.21), ("班加罗尔","IN",  12.97,  77.59),
            ("金奈",    "IN",  13.08,  80.27), ("加尔各答","IN",  22.57,  88.36),
            ("海得拉巴","IN",  17.39,  78.49), ("斋浦尔",  "IN",  26.91,  75.79),
            ("阿格拉",  "IN",  27.18,  78.01), ("瓦拉纳西","IN",  25.32,  83.01),
            ("果阿",    "IN",  15.30,  74.08), ("科钦",    "IN",   9.93,  76.26),
            ("乌代浦尔","IN",  24.57,  73.68), ("焦特布尔","IN",  26.29,  73.03),
            ("卡朱拉霍","IN",  24.85,  79.92), ("迈索尔",  "IN",  12.30,  76.65),
            ("伊斯兰堡","PK",  33.72,  73.04), ("卡拉奇",  "PK",  24.86,  67.01),
            ("拉合尔",  "PK",  31.55,  74.34),

            // ── 中东 ────────────────────────────────────────────────────────
            ("迪拜",    "AE",  25.20,  55.27), ("阿布扎比","AE",  24.47,  54.37),
            ("沙迦",    "AE",  25.36,  55.39),
            ("多哈",    "QA",  25.29,  51.53),
            ("科威特城","KW",  29.37,  47.98),
            ("利雅得",  "SA",  24.69,  46.72), ("吉达",    "SA",  21.49,  39.19),
            ("麦加",    "SA",  21.39,  39.86), ("麦地那",  "SA",  24.47,  39.61),
            ("马斯喀特","OM",  23.61,  58.59),
            ("巴林",    "BH",  26.21,  50.59),
            ("特拉维夫","IL",  32.08,  34.78), ("耶路撒冷","IL",  31.78,  35.22),
            ("安曼",    "JO",  31.95,  35.93), ("佩特拉",  "JO",  30.33,  35.48),
            ("瓦迪拉姆","JO",  29.57,  35.42),
            ("贝鲁特",  "LB",  33.89,  35.50),
            ("伊斯坦布尔","TR",41.01,  28.95), ("安卡拉",  "TR",  39.93,  32.86),
            ("安塔利亚","TR",  36.90,  30.70), ("卡帕多西亚","TR",38.67, 34.85),
            ("博德鲁姆","TR",  37.03,  27.43), ("伊兹密尔","TR",  38.42,  27.14),
            ("德黑兰",  "IR",  35.69,  51.39), ("伊斯法罕","IR",  32.66,  51.68),
            ("设拉子",  "IR",  29.61,  52.53),

            // ── 非洲 ────────────────────────────────────────────────────────
            ("开罗",    "EG",  30.04,  31.24), ("卢克索",  "EG",  25.69,  32.64),
            ("亚历山大","EG",  31.20,  29.92), ("阿斯旺",  "EG",  24.09,  32.90),
            ("马拉喀什","MA",  31.63,  -7.99), ("卡萨布兰卡","MA",33.59,  -7.62),
            ("非斯",    "MA",  34.04,  -5.00), ("舍夫沙万","MA",  35.17,  -5.27),
            ("拉巴特",  "MA",  34.02,  -6.84), ("阿加迪尔","MA",  30.43,  -9.60),
            ("突尼斯",  "TN",  36.82,  10.18), ("杰尔巴岛","TN",  33.87,  10.90),
            ("的黎波里","LY",  32.89,  13.18),
            ("开普敦",  "ZA", -33.93,  18.42), ("约翰内斯堡","ZA",-26.20, 28.04),
            ("德班",    "ZA", -29.86,  31.02), ("克鲁格",  "ZA", -24.00,  31.50),
            ("内罗毕",  "KE",  -1.29,  36.82), ("蒙巴萨",  "KE",  -4.05,  39.66),
            ("马赛马拉","KE",  -1.52,  35.14),
            ("坦桑尼亚","TZ",  -6.37,  34.89), ("桑给巴尔","TZ",  -6.16,  39.19),
            ("塞伦盖蒂","TZ",  -2.33,  34.83), ("乞力马扎罗","TZ",-3.07,  37.35),
            ("阿鲁沙",  "TZ",  -3.37,  36.68),
            ("亚的斯亚贝巴","ET",9.03,  38.74),
            ("拉各斯",  "NG",   6.46,   3.39), ("阿布贾",  "NG",   9.06,   7.49),
            ("达喀尔",  "SN",  14.72, -17.47),
            ("阿克拉",  "GH",   5.56,  -0.20),
            ("卢萨卡",  "ZM", -15.42,  28.28), ("利文斯顿","ZM", -17.85,  25.87),
            ("哈拉雷",  "ZW", -17.83,  31.05),
            ("卢旺达",  "RW",  -1.94,  29.87), ("基加利",  "RW",  -1.94,  30.06),
            ("马达加斯加","MG",-18.77,  46.87),

            // ── 俄罗斯/中亚 ─────────────────────────────────────────────────
            ("莫斯科",  "RU",  55.75,  37.62), ("圣彼得堡","RU",  59.94,  30.32),
            ("符拉迪沃斯托克","RU",43.12,131.90),("贝加尔湖","RU",53.50,108.17),
            ("叶卡捷琳堡","RU",56.84, 60.60),
            ("阿拉木图","KZ",  43.24,  76.89), ("努尔苏丹","KZ",  51.18,  71.45),
            ("塔什干",  "UZ",  41.30,  69.24), ("撒马尔罕","UZ",  39.65,  66.98),
            ("布哈拉",  "UZ",  39.77,  64.42),
            ("比什凯克","KG",  42.87,  74.59),
            ("杜尚别",  "TJ",  38.56,  68.77),
            ("阿什哈巴德","TM",37.95, 58.38),

            // ── 欧洲 ────────────────────────────────────────────────────────
            ("巴黎",    "FR",  48.86,   2.35), ("尼斯",    "FR",  43.71,   7.26),
            ("马赛",    "FR",  43.30,   5.37), ("里昂",    "FR",  45.75,   4.83),
            ("波尔多",  "FR",  44.84,  -0.58), ("斯特拉斯堡","FR",48.57,  7.75),
            ("蒙特卡洛","MC",  43.73,   7.42),
            ("伦敦",    "GB",  51.51,  -0.13), ("爱丁堡",  "GB",  55.95,  -3.19),
            ("曼彻斯特","GB",  53.48,  -2.24), ("利物浦",  "GB",  53.41,  -2.99),
            ("牛津",    "GB",  51.75,  -1.26), ("剑桥",    "GB",  52.21,   0.12),
            ("巴斯",    "GB",  51.38,  -2.36), ("约克",    "GB",  53.96,  -1.08),
            ("罗马",    "IT",  41.90,  12.50), ("米兰",    "IT",  45.46,   9.19),
            ("威尼斯",  "IT",  45.44,  12.33), ("佛罗伦萨","IT",  43.77,  11.25),
            ("那不勒斯","IT",  40.84,  14.25), ("西西里",  "IT",  37.60,  14.02),
            ("博洛尼亚","IT",  44.50,  11.34), ("都灵",    "IT",  45.07,   7.69),
            ("五渔村",  "IT",  44.13,   9.73), ("阿马尔菲","IT",  40.63,  14.60),
            ("马德里",  "ES",  40.42,  -3.70), ("巴塞罗那","ES",  41.39,   2.15),
            ("塞维利亚","ES",  37.39,  -5.99), ("格拉纳达","ES",  37.18,  -3.60),
            ("瓦伦西亚","ES",  39.47,  -0.38), ("毕尔巴鄂","ES",  43.26,  -2.93),
            ("马略卡岛","ES",  39.70,   2.99), ("特内里费","ES",  28.29, -16.63),
            ("柏林",    "DE",  52.52,  13.40), ("慕尼黑",  "DE",  48.14,  11.58),
            ("汉堡",    "DE",  53.55,   9.99), ("法兰克福","DE",  50.11,   8.68),
            ("科隆",    "DE",  50.94,   6.96), ("德累斯顿","DE",  51.05,  13.74),
            ("海德堡",  "DE",  49.40,   8.69), ("罗滕堡",  "DE",  49.38,  10.18),
            ("维也纳",  "AT",  48.21,  16.37), ("萨尔茨堡","AT",  47.80,  13.04),
            ("因斯布鲁克","AT",47.27,  11.39), ("哈尔施塔特","AT",47.56,13.65),
            ("苏黎世",  "CH",  47.38,   8.54), ("日内瓦",  "CH",  46.20,   6.14),
            ("伯尔尼",  "CH",  46.95,   7.45), ("琉森",    "CH",  47.05,   8.31),
            ("因特拉肯","CH",  46.69,   7.86), ("泽马特",  "CH",  46.02,   7.75),
            ("格林德瓦","CH",  46.62,   8.04),
            ("阿姆斯特丹","NL",52.37,   4.90), ("鹿特丹",  "NL",  51.92,   4.48),
            ("海牙",    "NL",  52.08,   4.31), ("乌得勒支","NL",  52.09,   5.12),
            ("布鲁塞尔","BE",  50.85,   4.35), ("布鲁日",  "BE",  51.21,   3.22),
            ("根特",    "BE",  51.05,   3.72),
            ("布拉格",  "CZ",  50.08,  14.44), ("克鲁姆洛夫","CZ",48.81, 14.32),
            ("布达佩斯","HU",  47.50,  19.04),
            ("华沙",    "PL",  52.23,  21.01), ("克拉科夫","PL",  50.06,  19.94),
            ("格但斯克","PL",  54.35,  18.65), ("弗罗茨瓦夫","PL",51.11, 17.04),
            ("雅典",    "GR",  37.98,  23.73), ("圣托里尼","GR",  36.39,  25.46),
            ("米科诺斯","GR",  37.45,  25.37), ("克里特岛","GR",  35.24,  24.81),
            ("罗德岛",  "GR",  36.44,  28.22), ("科孚岛",  "GR",  39.62,  19.92),
            ("里斯本",  "PT",  38.72,  -9.14), ("波尔图",  "PT",  41.15,  -8.61),
            ("阿尔加维","PT",  37.13,  -7.98), ("马德拉",  "PT",  32.75, -17.00),
            ("赫尔辛基","FI",  60.17,  24.94), ("罗瓦涅米","FI",  66.50,  25.72),
            ("斯德哥尔摩","SE",59.33,  18.07), ("哥德堡",  "SE",  57.71,  11.97),
            ("哥本哈根","DK",  55.68,  12.57), ("奥尔胡斯","DK",  56.16,  10.21),
            ("奥斯陆",  "NO",  59.91,  10.75), ("卑尔根",  "NO",  60.39,   5.32),
            ("特罗姆瑟","NO",  69.65,  18.96),
            ("雷克雅未克","IS",64.13, -21.94),
            ("都柏林",  "IE",  53.33,  -6.25), ("戈尔韦",  "IE",  53.27,  -9.06),
            ("萨格勒布","HR",  45.81,  15.98), ("杜布罗夫尼克","HR",42.65,18.09),
            ("斯普利特","HR",  43.51,  16.44), ("赫瓦尔岛","HR",  43.17,  16.44),
            ("布拉迪斯拉发","SK",48.15, 17.11),
            ("布加勒斯特","RO",44.44,  26.10), ("锡纳亚",  "RO",  45.35,  25.54),
            ("布拉索夫","RO",  45.65,  25.61),
            ("索菲亚",  "BG",  42.70,  23.32), ("大特尔诺沃","BG",43.08, 25.62),
            ("基辅",    "UA",  50.45,  30.52), ("利沃夫",  "UA",  49.84,  24.03),
            ("卢布尔雅那","SI",46.05,  14.51), ("布莱德",  "SI",  46.37,  14.09),
            ("斯科普里","MK",  41.99,  21.43),
            ("贝尔格莱德","RS",44.80,  20.46),
            ("萨拉热窝","BA",  43.85,  18.42),
            ("地拉那",  "AL",  41.33,  19.83),
            ("科托尔",  "ME",  42.42,  18.77),
            ("里加",    "LV",  56.95,  24.11), ("塔林",    "EE",  59.44,  24.75),
            ("维尔纽斯","LT",  54.69,  25.28),
            ("华沙",    "PL",  52.23,  21.01),
            ("卢森堡",  "LU",  49.61,   6.13),
            ("安道尔",  "AD",  42.51,   1.52),
            ("梵蒂冈",  "VA",  41.90,  12.45),
            ("摩纳哥",  "MC",  43.73,   7.42),
            ("直布罗陀","GI",  36.14,  -5.35),

            // ── 北美洲 ──────────────────────────────────────────────────────
            ("纽约",    "US",  40.71, -74.01), ("洛杉矶",  "US",  34.05,-118.24),
            ("旧金山",  "US",  37.77,-122.42), ("拉斯维加斯","US",36.17,-115.14),
            ("芝加哥",  "US",  41.88, -87.63), ("波士顿",  "US",  42.36, -71.06),
            ("西雅图",  "US",  47.61,-122.33), ("迈阿密",  "US",  25.77, -80.19),
            ("华盛顿",  "US",  38.91, -77.04), ("奥兰多",  "US",  28.54, -81.38),
            ("檀香山",  "US",  21.31,-157.86), ("夏威夷",  "US",  21.31,-157.86),
            ("纳什维尔","US",  36.17, -86.78), ("新奥尔良","US",  29.95, -90.07),
            ("丹佛",    "US",  39.74,-104.98), ("凤凰城",  "US",  33.45,-112.07),
            ("圣地亚哥","US",  32.72,-117.16), ("波特兰",  "US",  45.52,-122.68),
            ("奥斯汀",  "US",  30.27, -97.74), ("达拉斯",  "US",  32.78, -96.80),
            ("休斯顿",  "US",  29.76, -95.37), ("亚特兰大","US",  33.75, -84.39),
            ("明尼阿波利斯","US",44.98,-93.27),("圣路易斯","US",  38.63, -90.20),
            ("大峡谷",  "US",  36.10,-112.11), ("黄石",    "US",  44.43,-110.59),
            ("优胜美地","US",  37.75,-119.59), ("阿拉斯加","US",  64.20,-153.00),
            ("多伦多",  "CA",  43.65, -79.38), ("温哥华",  "CA",  49.26,-123.11),
            ("蒙特利尔","CA",  45.50, -73.57), ("班夫",    "CA",  51.18,-115.57),
            ("魁北克",  "CA",  46.81, -71.21), ("卡尔加里","CA",  51.05,-114.06),
            ("维多利亚","CA",  48.43,-123.37), ("惠斯勒",  "CA",  50.12,-122.96),
            ("尼亚加拉","CA",  43.10, -79.07),
            ("墨西哥城","MX",  19.43, -99.13), ("坎昆",    "MX",  21.16, -86.85),
            ("洛斯卡沃斯","MX",22.89,-109.92), ("瓦哈卡",  "MX",  17.07, -96.72),
            ("危地马拉城","GT",14.63,-90.51),
            ("哈瓦那",  "CU",  23.13, -82.38),
            ("圣多明各","DO",  18.47, -69.90),
            ("拿骚",    "BS",  25.05, -77.34),

            // ── 加勒比海/中美洲 ─────────────────────────────────────────────
            ("圣胡安",  "PR",  18.47, -66.11),
            ("金斯敦",  "JM",  17.99, -76.79),
            ("圣卢西亚","LC",  13.91, -60.98),
            ("巴巴多斯","BB",  13.19, -59.54),

            // ── 南美洲 ──────────────────────────────────────────────────────
            ("布宜诺斯艾利斯","AR",-34.60,-58.38),
            ("巴塔哥尼亚","AR",-45.00,-70.00), ("门多萨",  "AR", -32.89, -68.83),
            ("圣保罗",  "BR", -23.55, -46.63), ("里约",    "BR", -22.91, -43.17),
            ("里约热内卢","BR",-22.91,-43.17), ("萨尔瓦多","BR", -12.97, -38.51),
            ("福塔雷萨","BR",  -3.73, -38.52), ("马瑙斯",  "BR",  -3.10, -60.03),
            ("伊瓜苏",  "BR", -25.69, -54.44),
            ("利马",    "PE", -12.04, -77.03), ("库斯科",  "PE", -13.52, -71.97),
            ("马丘比丘","PE", -13.16, -72.54),
            ("波哥大",  "CO",   4.71, -74.07), ("卡塔赫纳","CO",  10.40, -75.52),
            ("麦德林",  "CO",   6.25, -75.57),
            ("基多",    "EC",  -0.22, -78.51), ("加拉帕戈斯","EC",-0.80,-90.97),
            ("圣地亚哥","CL", -33.46, -70.65), ("巴塔哥尼亚","CL",-51.00,-73.00),
            ("拉巴斯",  "BO", -16.50, -68.15), ("玻利维亚盐湖","BO",-20.14,-67.49),
            ("蒙得维的亚","UY",-34.91,-56.19),
            ("阿松森",  "PY", -25.28, -57.63),

            // ── 大洋洲 ──────────────────────────────────────────────────────
            ("悉尼",    "AU", -33.87, 151.21), ("墨尔本",  "AU", -37.81, 144.96),
            ("布里斯班","AU", -27.47, 153.02), ("黄金海岸","AU", -28.02, 153.40),
            ("凯恩斯",  "AU", -16.92, 145.77), ("珀斯",    "AU", -31.95, 115.86),
            ("阿德莱德","AU", -34.93, 138.60), ("达尔文",  "AU", -12.46, 130.84),
            ("乌鲁鲁",  "AU", -25.34, 131.04), ("大堡礁",  "AU", -18.29, 147.70),
            ("奥克兰",  "NZ", -36.86, 174.77), ("皇后镇",  "NZ", -45.03, 168.66),
            ("惠灵顿",  "NZ", -41.29, 174.78), ("基督城",  "NZ", -43.53, 172.64),
            ("罗托鲁瓦","NZ", -38.14, 176.25),
            ("斐济",    "FJ",  -17.71, 178.06), ("楠迪",   "FJ",  -17.78, 177.41),
            ("瓦努阿图","VU", -15.37, 166.96),
            ("大溪地",  "PF", -17.65,-149.43),
            ("马尔代夫","MV",   3.20,  73.22), ("马累",    "MV",   4.18,  73.51),
        ]

        var dict: [String: (code: String, lat: Double, lon: Double)] = [:]
        for (city, code, lat, lon) in entries {
            dict[city]                = (code, lat, lon)
            dict[city.lowercased()]   = (code, lat, lon)
        }

        // English / pinyin names (stored lowercase, already unique)
        let latin: [(String, String, Double, Double)] = [
            // East Asia
            ("beijing","CN",39.91,116.39),("shanghai","CN",31.23,121.47),
            ("guangzhou","CN",23.13,113.27),("shenzhen","CN",22.54,114.06),
            ("chengdu","CN",30.66,104.08),("hangzhou","CN",30.25,120.16),
            ("wuhan","CN",30.59,114.31),("xian","CN",34.27,108.95),
            ("xi'an","CN",34.27,108.95),("nanjing","CN",32.06,118.80),
            ("chongqing","CN",29.56,106.55),("tianjin","CN",39.13,117.20),
            ("qingdao","CN",36.07,120.37),("dalian","CN",38.91,121.60),
            ("xiamen","CN",24.48,118.09),("harbin","CN",45.75,126.63),
            ("shenyang","CN",41.81,123.43),("suzhou","CN",31.30,120.62),
            ("zhengzhou","CN",34.75,113.63),("kunming","CN",25.04,102.71),
            ("sanya","CN",18.25,109.51),("guilin","CN",25.27,110.29),
            ("lijiang","CN",26.87,100.23),("zhangjiajie","CN",29.12,110.48),
            ("jiuzhaigou","CN",33.26,103.92),("huangshan","CN",29.72,118.33),
            ("shangri-la","CN",27.83,99.71),("xishuangbanna","CN",22.01,100.80),
            ("dali","CN",25.60,100.27),("dunhuang","CN",40.14,94.66),
            ("kashgar","CN",39.47,75.98),("yili","CN",43.92,81.32),
            ("urumqi","CN",43.83,87.62),("lhasa","CN",29.65,91.13),
            ("hong kong","HK",22.40,114.11),("macau","MO",22.20,113.55),
            ("taipei","TW",25.05,121.56),("kaohsiung","TW",22.63,120.30),
            ("taichung","TW",24.15,120.67),
            ("tokyo","JP",35.69,139.69),("osaka","JP",34.69,135.50),
            ("kyoto","JP",35.01,135.77),("fukuoka","JP",33.59,130.40),
            ("sapporo","JP",43.06,141.35),("okinawa","JP",26.21,127.68),
            ("naha","JP",26.21,127.68),("nagoya","JP",35.18,136.91),
            ("yokohama","JP",35.44,139.64),("kobe","JP",34.69,135.20),
            ("nara","JP",34.68,135.83),("hiroshima","JP",34.39,132.46),
            ("sendai","JP",38.27,140.87),("nagasaki","JP",32.74,129.87),
            ("hakone","JP",35.23,139.11),("mount fuji","JP",35.36,138.73),
            ("seoul","KR",37.57,126.98),("busan","KR",35.10,129.04),
            ("jeju","KR",33.49,126.53),("incheon","KR",37.46,126.71),
            ("gyeongju","KR",35.86,129.22),
            // Southeast Asia
            ("bangkok","TH",13.75,100.52),("chiang mai","TH",18.79,98.98),
            ("phuket","TH",7.89,98.40),("pattaya","TH",12.93,100.88),
            ("koh samui","TH",9.53,99.93),("krabi","TH",8.09,98.91),
            ("hanoi","VN",21.03,105.85),("ho chi minh","VN",10.82,106.63),
            ("ho chi minh city","VN",10.82,106.63),("saigon","VN",10.82,106.63),
            ("da nang","VN",16.05,108.22),("hoi an","VN",15.88,108.34),
            ("nha trang","VN",12.24,109.19),("halong bay","VN",20.95,107.06),
            ("singapore","SG",1.35,103.82),
            ("kuala lumpur","MY",3.14,101.69),("kl","MY",3.14,101.69),
            ("penang","MY",5.41,100.33),("langkawi","MY",6.35,100.13),
            ("kota kinabalu","MY",5.98,116.07),
            ("jakarta","ID",-6.21,106.85),("bali","ID",-8.34,115.09),
            ("yogyakarta","ID",-7.80,110.36),("lombok","ID",-8.57,116.35),
            ("komodo","ID",-8.55,119.49),
            ("manila","PH",14.60,120.98),("cebu","PH",10.32,123.89),
            ("boracay","PH",11.96,121.92),("palawan","PH",9.84,118.74),
            ("yangon","MM",16.87,96.19),("bagan","MM",21.17,94.86),
            ("mandalay","MM",21.97,96.08),
            ("phnom penh","KH",11.56,104.92),("siem reap","KH",13.36,103.86),
            ("angkor","KH",13.41,103.87),
            ("vientiane","LA",17.97,102.60),("luang prabang","LA",19.89,102.14),
            ("colombo","LK",6.93,79.85),("kandy","LK",7.29,80.63),
            ("kathmandu","NP",27.72,85.32),("pokhara","NP",28.21,83.99),
            ("dhaka","BD",23.81,90.41),
            // South Asia
            ("mumbai","IN",19.08,72.88),("new delhi","IN",28.61,77.21),
            ("delhi","IN",28.61,77.21),("bangalore","IN",12.97,77.59),
            ("bengaluru","IN",12.97,77.59),("chennai","IN",13.08,80.27),
            ("kolkata","IN",22.57,88.36),("hyderabad","IN",17.39,78.49),
            ("jaipur","IN",26.91,75.79),("agra","IN",27.18,78.01),
            ("varanasi","IN",25.32,83.01),("goa","IN",15.30,74.08),
            ("udaipur","IN",24.57,73.68),
            ("islamabad","PK",33.72,73.04),("karachi","PK",24.86,67.01),
            ("lahore","PK",31.55,74.34),
            // Middle East
            ("dubai","AE",25.20,55.27),("abu dhabi","AE",24.47,54.37),
            ("doha","QA",25.29,51.53),
            ("riyadh","SA",24.69,46.72),("jeddah","SA",21.49,39.19),
            ("mecca","SA",21.39,39.86),
            ("muscat","OM",23.61,58.59),
            ("tel aviv","IL",32.08,34.78),("jerusalem","IL",31.78,35.22),
            ("amman","JO",31.95,35.93),("petra","JO",30.33,35.48),
            ("beirut","LB",33.89,35.50),
            ("istanbul","TR",41.01,28.95),("ankara","TR",39.93,32.86),
            ("antalya","TR",36.90,30.70),("cappadocia","TR",38.67,34.85),
            ("bodrum","TR",37.03,27.43),
            ("tehran","IR",35.69,51.39),("isfahan","IR",32.66,51.68),
            // Africa
            ("cairo","EG",30.04,31.24),("luxor","EG",25.69,32.64),
            ("alexandria","EG",31.20,29.92),("aswan","EG",24.09,32.90),
            ("marrakech","MA",31.63,-7.99),("marrakesh","MA",31.63,-7.99),
            ("casablanca","MA",33.59,-7.62),("fez","MA",34.04,-5.00),
            ("chefchaouen","MA",35.17,-5.27),("rabat","MA",34.02,-6.84),
            ("cape town","ZA",-33.93,18.42),("johannesburg","ZA",-26.20,28.04),
            ("durban","ZA",-29.86,31.02),
            ("nairobi","KE",-1.29,36.82),("mombasa","KE",-4.05,39.66),
            ("masai mara","KE",-1.52,35.14),
            ("zanzibar","TZ",-6.16,39.19),("serengeti","TZ",-2.33,34.83),
            ("kilimanjaro","TZ",-3.07,37.35),
            ("addis ababa","ET",9.03,38.74),
            ("lagos","NG",6.46,3.39),("abuja","NG",9.06,7.49),
            ("dakar","SN",14.72,-17.47),("accra","GH",5.56,-0.20),
            ("lusaka","ZM",-15.42,28.28),("livingstone","ZM",-17.85,25.87),
            ("kigali","RW",-1.94,30.06),
            // Russia / Central Asia
            ("moscow","RU",55.75,37.62),("saint petersburg","RU",59.94,30.32),
            ("st petersburg","RU",59.94,30.32),("st. petersburg","RU",59.94,30.32),
            ("lake baikal","RU",53.50,108.17),
            ("almaty","KZ",43.24,76.89),("nur-sultan","KZ",51.18,71.45),
            ("astana","KZ",51.18,71.45),
            ("tashkent","UZ",41.30,69.24),("samarkand","UZ",39.65,66.98),
            ("bukhara","UZ",39.77,64.42),
            // Europe
            ("paris","FR",48.86,2.35),("nice","FR",43.71,7.26),
            ("lyon","FR",45.75,4.83),("marseille","FR",43.30,5.37),
            ("bordeaux","FR",44.84,-0.58),("strasbourg","FR",48.57,7.75),
            ("london","GB",51.51,-0.13),("edinburgh","GB",55.95,-3.19),
            ("manchester","GB",53.48,-2.24),("liverpool","GB",53.41,-2.99),
            ("oxford","GB",51.75,-1.26),("cambridge","GB",52.21,0.12),
            ("bath","GB",51.38,-2.36),
            ("rome","IT",41.90,12.50),("milan","IT",45.46,9.19),
            ("venice","IT",45.44,12.33),("florence","IT",43.77,11.25),
            ("naples","IT",40.84,14.25),("sicily","IT",37.60,14.02),
            ("bologna","IT",44.50,11.34),("turin","IT",45.07,7.69),
            ("cinque terre","IT",44.13,9.73),("amalfi","IT",40.63,14.60),
            ("madrid","ES",40.42,-3.70),("barcelona","ES",41.39,2.15),
            ("seville","ES",37.39,-5.99),("granada","ES",37.18,-3.60),
            ("valencia","ES",39.47,-0.38),("bilbao","ES",43.26,-2.93),
            ("mallorca","ES",39.70,2.99),("majorca","ES",39.70,2.99),
            ("ibiza","ES",38.91,1.43),("tenerife","ES",28.29,-16.63),
            ("berlin","DE",52.52,13.40),("munich","DE",48.14,11.58),
            ("hamburg","DE",53.55,9.99),("frankfurt","DE",50.11,8.68),
            ("cologne","DE",50.94,6.96),("dresden","DE",51.05,13.74),
            ("heidelberg","DE",49.40,8.69),("rothenburg","DE",49.38,10.18),
            ("vienna","AT",48.21,16.37),("salzburg","AT",47.80,13.04),
            ("innsbruck","AT",47.27,11.39),("hallstatt","AT",47.56,13.65),
            ("zurich","CH",47.38,8.54),("geneva","CH",46.20,6.14),
            ("bern","CH",46.95,7.45),("lucerne","CH",47.05,8.31),
            ("interlaken","CH",46.69,7.86),("zermatt","CH",46.02,7.75),
            ("grindelwald","CH",46.62,8.04),
            ("amsterdam","NL",52.37,4.90),("rotterdam","NL",51.92,4.48),
            ("the hague","NL",52.08,4.31),("utrecht","NL",52.09,5.12),
            ("brussels","BE",50.85,4.35),("bruges","BE",51.21,3.22),
            ("ghent","BE",51.05,3.72),
            ("prague","CZ",50.08,14.44),("cesky krumlov","CZ",48.81,14.32),
            ("budapest","HU",47.50,19.04),
            ("warsaw","PL",52.23,21.01),("krakow","PL",50.06,19.94),
            ("gdansk","PL",54.35,18.65),("wroclaw","PL",51.11,17.04),
            ("athens","GR",37.98,23.73),("santorini","GR",36.39,25.46),
            ("mykonos","GR",37.45,25.37),("crete","GR",35.24,24.81),
            ("rhodes","GR",36.44,28.22),("corfu","GR",39.62,19.92),
            ("lisbon","PT",38.72,-9.14),("porto","PT",41.15,-8.61),
            ("algarve","PT",37.13,-7.98),("madeira","PT",32.75,-17.00),
            ("helsinki","FI",60.17,24.94),("rovaniemi","FI",66.50,25.72),
            ("stockholm","SE",59.33,18.07),("gothenburg","SE",57.71,11.97),
            ("copenhagen","DK",55.68,12.57),
            ("oslo","NO",59.91,10.75),("bergen","NO",60.39,5.32),
            ("tromso","NO",69.65,18.96),("tromsø","NO",69.65,18.96),
            ("reykjavik","IS",64.13,-21.94),
            ("dublin","IE",53.33,-6.25),("galway","IE",53.27,-9.06),
            ("zagreb","HR",45.81,15.98),("dubrovnik","HR",42.65,18.09),
            ("split","HR",43.51,16.44),("hvar","HR",43.17,16.44),
            ("bratislava","SK",48.15,17.11),
            ("bucharest","RO",44.44,26.10),("brasov","RO",45.65,25.61),
            ("sofia","BG",42.70,23.32),
            ("kyiv","UA",50.45,30.52),("kiev","UA",50.45,30.52),
            ("lviv","UA",49.84,24.03),
            ("ljubljana","SI",46.05,14.51),("bled","SI",46.37,14.09),
            ("skopje","MK",41.99,21.43),
            ("belgrade","RS",44.80,20.46),("sarajevo","BA",43.85,18.42),
            ("tirana","AL",41.33,19.83),("kotor","ME",42.42,18.77),
            ("riga","LV",56.95,24.11),("tallinn","EE",59.44,24.75),
            ("vilnius","LT",54.69,25.28),("luxembourg","LU",49.61,6.13),
            ("monaco","MC",43.73,7.42),("andorra","AD",42.51,1.52),
            ("monte carlo","MC",43.73,7.42),
            // Americas
            ("new york","US",40.71,-74.01),("los angeles","US",34.05,-118.24),
            ("san francisco","US",37.77,-122.42),("las vegas","US",36.17,-115.14),
            ("chicago","US",41.88,-87.63),("boston","US",42.36,-71.06),
            ("seattle","US",47.61,-122.33),("miami","US",25.77,-80.19),
            ("washington","US",38.91,-77.04),("orlando","US",28.54,-81.38),
            ("honolulu","US",21.31,-157.86),("hawaii","US",21.31,-157.86),
            ("nashville","US",36.17,-86.78),("new orleans","US",29.95,-90.07),
            ("denver","US",39.74,-104.98),("phoenix","US",33.45,-112.07),
            ("san diego","US",32.72,-117.16),("portland","US",45.52,-122.68),
            ("austin","US",30.27,-97.74),("dallas","US",32.78,-96.80),
            ("houston","US",29.76,-95.37),("atlanta","US",33.75,-84.39),
            ("grand canyon","US",36.10,-112.11),("yellowstone","US",44.43,-110.59),
            ("yosemite","US",37.75,-119.59),("alaska","US",64.20,-153.00),
            ("toronto","CA",43.65,-79.38),("vancouver","CA",49.26,-123.11),
            ("montreal","CA",45.50,-73.57),("banff","CA",51.18,-115.57),
            ("quebec","CA",46.81,-71.21),("calgary","CA",51.05,-114.06),
            ("victoria","CA",48.43,-123.37),("whistler","CA",50.12,-122.96),
            ("niagara falls","CA",43.10,-79.07),
            ("mexico city","MX",19.43,-99.13),("cancun","MX",21.16,-86.85),
            ("cabo","MX",22.89,-109.92),("oaxaca","MX",17.07,-96.72),
            ("havana","CU",23.13,-82.38),("santo domingo","DO",18.47,-69.90),
            ("nassau","BS",25.05,-77.34),
            ("buenos aires","AR",-34.60,-58.38),("patagonia","AR",-45.00,-70.00),
            ("mendoza","AR",-32.89,-68.83),
            ("sao paulo","BR",-23.55,-46.63),("rio de janeiro","BR",-22.91,-43.17),
            ("rio","BR",-22.91,-43.17),("salvador","BR",-12.97,-38.51),
            ("manaus","BR",-3.10,-60.03),("iguazu","BR",-25.69,-54.44),
            ("lima","PE",-12.04,-77.03),("cusco","PE",-13.52,-71.97),
            ("machu picchu","PE",-13.16,-72.54),
            ("bogota","CO",4.71,-74.07),("cartagena","CO",10.40,-75.52),
            ("medellin","CO",6.25,-75.57),
            ("quito","EC",-0.22,-78.51),("galapagos","EC",-0.80,-90.97),
            ("santiago","CL",-33.46,-70.65),
            ("la paz","BO",-16.50,-68.15),("bolivian salt flats","BO",-20.14,-67.49),
            ("montevideo","UY",-34.91,-56.19),
            // Oceania
            ("sydney","AU",-33.87,151.21),("melbourne","AU",-37.81,144.96),
            ("brisbane","AU",-27.47,153.02),("gold coast","AU",-28.02,153.40),
            ("cairns","AU",-16.92,145.77),("perth","AU",-31.95,115.86),
            ("adelaide","AU",-34.93,138.60),("darwin","AU",-12.46,130.84),
            ("uluru","AU",-25.34,131.04),("great barrier reef","AU",-18.29,147.70),
            ("auckland","NZ",-36.86,174.77),("queenstown","NZ",-45.03,168.66),
            ("wellington","NZ",-41.29,174.78),("christchurch","NZ",-43.53,172.64),
            ("rotorua","NZ",-38.14,176.25),
            ("fiji","FJ",-17.71,178.06),("nadi","FJ",-17.78,177.41),
            ("tahiti","PF",-17.65,-149.43),
            ("maldives","MV",3.20,73.22),("male","MV",4.18,73.51),
        ]
        for (city, code, lat, lon) in latin {
            dict[city] = (code, lat, lon)
        }
        return dict
    }()

    /// Chinese country/region keywords → (code, lat, lon).
    /// Used to resolve compound inputs like "泰国曼谷" or "意大利罗马" when
    /// the exact city name isn't in cityLookup.
    private static let countryKeywords: [(keyword: String, code: String, lat: Double, lon: Double)] = [
        // sorted longest-first so "澳大利亚" matches before "澳"
        ("澳大利亚","AU",-25.27,133.78), ("新西兰",  "NZ",-40.90,174.89),
        ("新加坡",  "SG",  1.35,103.82), ("菲律宾",  "PH", 12.88,121.77),
        ("印度尼西亚","ID",-0.79,113.92),("马来西亚","MY",  4.21,108.10),
        ("越南",    "VN", 14.06,108.28), ("泰国",    "TH", 15.87,100.99),
        ("缅甸",    "MM", 16.87, 96.19), ("柬埔寨",  "KH", 12.57,104.99),
        ("老挝",    "LA", 17.96,102.60), ("斯里兰卡","LK",  7.87, 80.77),
        ("尼泊尔",  "NP", 28.39, 84.12), ("孟加拉国","BD", 23.68, 90.36),
        ("巴基斯坦","PK", 30.38, 69.35), ("印度",    "IN", 20.59, 78.96),
        ("日本",    "JP", 36.20,138.25), ("韩国",    "KR", 35.91,127.77),
        ("朝鲜",    "KP", 40.34,127.51), ("蒙古",    "MN", 46.86,103.85),
        ("哈萨克斯坦","KZ",48.02,66.92),("乌兹别克斯坦","UZ",41.38,63.97),
        ("吉尔吉斯斯坦","KG",41.20,74.77),
        ("土库曼斯坦","TM",38.97,59.56),("塔吉克斯坦","TJ",38.86,71.28),
        ("阿富汗",  "AF", 33.93, 67.71),
        ("伊朗",    "IR", 32.43, 53.69), ("伊拉克",  "IQ", 33.22, 43.68),
        ("叙利亚",  "SY", 34.80, 38.99), ("黎巴嫩",  "LB", 33.85, 35.86),
        ("约旦",    "JO", 30.59, 36.24), ("以色列",  "IL", 31.05, 34.85),
        ("沙特阿拉伯","SA",23.89,45.08),("也门",    "YE", 15.55, 48.52),
        ("阿联酋",  "AE", 23.42, 53.85), ("卡塔尔",  "QA", 25.35, 51.18),
        ("科威特",  "KW", 29.31, 47.48), ("巴林",    "BH", 26.21, 50.59),
        ("阿曼",    "OM", 21.51, 55.92), ("土耳其",  "TR", 38.96, 35.24),
        ("俄罗斯",  "RU", 61.52,105.32), ("乌克兰",  "UA", 48.38, 31.17),
        ("白俄罗斯","BY", 53.71, 27.95), ("摩尔多瓦","MD", 47.41, 28.37),
        ("格鲁吉亚","GE", 42.32, 43.36), ("亚美尼亚","AM", 40.07, 45.04),
        ("阿塞拜疆","AZ", 40.14, 47.58),
        ("法国",    "FR", 46.23,  2.21), ("英国",    "GB", 55.38, -3.44),
        ("德国",    "DE", 51.17, 10.45), ("意大利",  "IT", 41.87, 12.57),
        ("西班牙",  "ES", 40.46, -3.75), ("葡萄牙",  "PT", 39.40, -8.22),
        ("荷兰",    "NL", 52.13,  5.29), ("比利时",  "BE", 50.50,  4.47),
        ("瑞士",    "CH", 46.82,  8.23), ("奥地利",  "AT", 47.52, 14.55),
        ("希腊",    "GR", 39.07, 21.82), ("捷克",    "CZ", 49.82, 15.47),
        ("匈牙利",  "HU", 47.16, 19.50), ("波兰",    "PL", 51.92, 19.15),
        ("罗马尼亚","RO", 45.94, 24.97), ("保加利亚","BG", 42.73, 25.49),
        ("克罗地亚","HR", 45.10, 15.20), ("斯洛文尼亚","SI",46.15,14.99),
        ("塞尔维亚","RS", 44.02, 21.01), ("黑山",    "ME", 42.71, 19.37),
        ("北马其顿","MK", 41.61, 21.75), ("波黑",    "BA", 43.92, 17.68),
        ("阿尔巴尼亚","AL",41.15,20.17),("科索沃",  "XK", 42.60, 20.90),
        ("斯洛伐克","SK", 48.67, 19.70), ("挪威",    "NO", 60.47,  8.47),
        ("瑞典",    "SE", 60.13, 18.64), ("丹麦",    "DK", 56.26,  9.50),
        ("芬兰",    "FI", 61.92, 25.75), ("冰岛",    "IS", 64.96,-19.02),
        ("爱尔兰",  "IE", 53.41, -8.24), ("苏格兰",  "GB", 56.49, -4.20),
        ("埃及",    "EG", 26.82, 30.80), ("摩洛哥",  "MA", 31.79, -7.09),
        ("突尼斯",  "TN", 33.89,  9.54), ("阿尔及利亚","DZ",28.03, 1.66),
        ("利比亚",  "LY", 26.34, 17.23), ("埃塞俄比亚","ET",9.15, 40.49),
        ("肯尼亚",  "KE", -0.02, 37.91), ("坦桑尼亚","TZ", -6.37, 34.89),
        ("南非",    "ZA",-30.56, 22.94), ("尼日利亚","NG",  9.08,  8.68),
        ("加纳",    "GH",  7.95, -1.02), ("塞内加尔","SN", 14.50,-14.45),
        ("卢旺达",  "RW", -1.94, 29.87), ("津巴布韦","ZW",-19.02, 29.15),
        ("赞比亚",  "ZM",-13.13, 27.85), ("莫桑比克","MZ",-18.67, 35.53),
        ("马达加斯加","MG",-18.77,46.87),("坦桑尼亚","TZ", -6.37, 34.89),
        ("美国",    "US", 37.09,-95.71), ("加拿大",  "CA", 56.13,-106.35),
        ("墨西哥",  "MX", 23.63,-102.55),("古巴",    "CU", 21.52,-77.78),
        ("巴西",    "BR",-14.24,-51.93), ("阿根廷",  "AR",-38.42,-63.62),
        ("智利",    "CL",-35.68,-71.54), ("秘鲁",    "PE", -9.19,-75.02),
        ("哥伦比亚","CO",  4.57,-74.30), ("厄瓜多尔","EC", -1.83,-78.18),
        ("玻利维亚","BO",-16.29,-63.59), ("乌拉圭",  "UY",-32.52,-55.77),
        ("巴拉圭",  "PY",-23.44,-58.44), ("委内瑞拉","VE",  6.42,-66.59),
        ("斐济",    "FJ",-17.71,178.06), ("马尔代夫","MV",  3.20, 73.22),
        ("大溪地",  "PF",-17.65,-149.43),("夏威夷",  "US", 21.31,-157.86),
        // 中国省份/地区关键词 (handles "新疆伊犁", "西藏拉萨" etc.)
        ("新疆",    "CN", 43.45, 85.00), ("西藏",    "CN", 31.00, 88.00),
        ("内蒙古",  "CN", 44.09,113.95), ("广西",    "CN", 23.73,108.90),
        ("宁夏",    "CN", 37.20,106.20), ("青海",    "CN", 35.74, 96.40),
        ("甘肃",    "CN", 36.06,103.83), ("云南",    "CN", 24.97,101.49),
        ("贵州",    "CN", 26.82,106.87), ("四川",    "CN", 30.66,103.00),
        ("西藏",    "CN", 31.00, 88.00), ("海南",    "CN", 20.04,110.32),
        ("黑龙江",  "CN", 45.75,126.64), ("吉林",    "CN", 43.88,125.32),
        ("辽宁",    "CN", 41.81,123.43), ("山东",    "CN", 36.67,117.00),
        ("河南",    "CN", 34.75,113.63), ("湖北",    "CN", 30.59,114.31),
        ("湖南",    "CN", 28.23,112.94), ("江西",    "CN", 28.69,115.86),
        ("安徽",    "CN", 31.86,117.28), ("福建",    "CN", 26.08,119.30),
        ("浙江",    "CN", 30.25,120.16), ("江苏",    "CN", 32.06,118.76),
        ("山西",    "CN", 37.87,112.55), ("河北",    "CN", 38.05,114.48),
        ("陕西",    "CN", 34.27,108.95), ("中国",    "CN", 35.86,104.20),
    ]

    // MARK: - Multi-city splitting

    /// Splits a free-form destination string into individual city tokens.
    /// Handles: comma variants, slash, ampersand, plus, " and ", " 和 ".
    /// Deliberately avoids splitting on bare "和" to protect city names like "和田".
    private func splitCities(_ input: String) -> [String] {
        var tokens = [input]
        // Multi-char separators first (order matters)
        for sep in [" and ", " And ", " AND ", " 和 "] {
            tokens = tokens.flatMap { $0.components(separatedBy: sep) }
        }
        // Single-char separators
        for sep in [",", "，", "、", "/", "／", "&", "＆", "+", "＋"] {
            tokens = tokens.flatMap { $0.components(separatedBy: sep) }
        }
        return tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private func lookupCity(_ city: String) -> (code: String, lat: Double, lon: Double)? {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        // 1. Exact match (original case or lowercased)
        if let r = Self.cityLookup[trimmed] ?? Self.cityLookup[trimmed.lowercased()] {
            return r
        }

        // 2. Country/province keyword prefix: handles "泰国曼谷", "新疆伊犁", "意大利罗马" etc.
        for entry in Self.countryKeywords where trimmed.contains(entry.keyword) {
            let remainder = trimmed
                .replacingOccurrences(of: entry.keyword, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // If the remaining part is a known city, use city coords for precision
            if !remainder.isEmpty,
               let cityResult = Self.cityLookup[remainder] ?? Self.cityLookup[remainder.lowercased()] {
                return cityResult
            }
            // Otherwise fall back to country/province centroid
            return (entry.code, entry.lat, entry.lon)
        }

        return nil
    }

    // MARK: - Country centroids

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
        let tokens = splitCities(city)
        guard !tokens.isEmpty else { return }

        // Fast path: every token resolves from local table, no network needed.
        let localResults = tokens.compactMap { lookupCity($0) }
        if localResults.count == tokens.count {
            guard let bundle = bundle(for: tripId) else { return }
            bundle.countryCode = localResults[0].code
            bundle.latitude    = localResults[0].lat
            bundle.longitude   = localResults[0].lon
            bundle.additionalDestinations = localResults.dropFirst().map {
                DestinationEntry(countryCode: $0.code, latitude: $0.lat, longitude: $0.lon)
            }
            do { try context.save() } catch {
                CarryLogger.shared.log(.persistFailed, context: "caller=updateCountryCode")
            }
            CarryLogger.shared.log(.geocodeResolved,
                context: "tokens=\(tokens.count) resolved=\(localResults.count) city=\(city)")
            return
        }

        // Slow path: at least one token needs CLGeocoder.
        Task {
            let geocoder = CLGeocoder()
            var resolved: [(code: String, lat: Double, lon: Double)] = []
            var geocodedCount = 0

            for token in tokens {
                // Try local lookup first (instant, no network)
                if let local = lookupCity(token) {
                    resolved.append((local.code, local.lat, local.lon))
                    continue
                }
                // Rate limit: respect CLGeocoder's ~1 req/s recommendation
                if geocodedCount > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                geocodedCount += 1
                guard let placemark = try? await geocoder.geocodeAddressString(token).first else {
                    CarryLogger.shared.log(.geocodeFailed, context: "city=\(token)")
                    continue
                }
                let code = placemark.isoCountryCode ?? ""
                if let loc = placemark.location, loc.coordinate.latitude != 0 {
                    resolved.append((code, loc.coordinate.latitude, loc.coordinate.longitude))
                } else if !code.isEmpty, let centroid = coordinatesForCountry(code) {
                    resolved.append((code, centroid.lat, centroid.lon))
                }
            }

            guard !resolved.isEmpty else { return }
            await MainActor.run {
                guard let bundle = self.bundle(for: tripId) else { return }
                bundle.countryCode = resolved[0].code
                bundle.latitude    = resolved[0].lat
                bundle.longitude   = resolved[0].lon
                bundle.additionalDestinations = Array(resolved.dropFirst()).map {
                    DestinationEntry(countryCode: $0.code, latitude: $0.lat, longitude: $0.lon)
                }
                do { try self.context.save() } catch {
                    CarryLogger.shared.log(.persistFailed, context: "caller=updateCountryCode_async")
                }
                CarryLogger.shared.log(.geocodeResolved,
                    context: "tokens=\(tokens.count) resolved=\(resolved.count) city=\(city)")
            }
        }
    }

    /// Corrects trips whose countryCode / coordinates were set incorrectly by
    /// an old CLGeocoder call. Uses the local city lookup table as the source
    /// of truth: if the table disagrees with the stored countryCode, overwrite.
    func correctMisgecodedTrips() {
        var changed = false
        for trip in trips {
            guard !trip.destinationCity.isEmpty else { continue }
            let tokens = splitCities(trip.destinationCity)
            guard let primaryToken = tokens.first,
                  let local = lookupCity(primaryToken),
                  trip.countryCode.uppercased() != local.code.uppercased() else { continue }
            trip.countryCode = local.code
            trip.latitude    = local.lat
            trip.longitude   = local.lon
            trip.additionalDestinations = tokens.dropFirst().compactMap { token in
                guard let r = lookupCity(token) else { return nil }
                return DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon)
            }
            changed = true
        }
        if changed {
            do { try context.save() } catch {
                CarryLogger.shared.log(.persistFailed, context: "caller=correctMisgecodedTrips")
            }
            fetchTrips()
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
        // Also pick up multi-destination trips whose extras haven't been resolved yet.
        let missingExtras = trips.filter {
            !$0.destinationCity.isEmpty &&
            !$0.countryCode.isEmpty &&
            $0.latitude != 0 &&
            $0.additionalDestinationsData.isEmpty &&
            splitCities($0.destinationCity).count > 1
        }

        guard !missing.isEmpty || !missingExtras.isEmpty else { return }

        Task {
            let geocoder = CLGeocoder()
            var geocodedCount = 0

            // Helper: geocode a single token with rate limiting
            func geocodeToken(_ token: String) async -> (code: String, lat: Double, lon: Double)? {
                if geocodedCount > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                geocodedCount += 1
                guard let placemark = try? await geocoder.geocodeAddressString(token).first else {
                    CarryLogger.shared.log(.geocodeFailed, context: "city=\(token)")
                    return nil
                }
                let code = placemark.isoCountryCode ?? ""
                if let loc = placemark.location, loc.coordinate.latitude != 0 {
                    return (code, loc.coordinate.latitude, loc.coordinate.longitude)
                } else if !code.isEmpty, let centroid = coordinatesForCountry(code) {
                    return (code, centroid.lat, centroid.lon)
                }
                return nil
            }

            // 1. Trips with no primary country resolved yet
            for trip in missing {
                let tokens = splitCities(trip.destinationCity)
                guard let primaryToken = tokens.first else { continue }

                // Try local table first
                if let local = lookupCity(primaryToken) {
                    let extras = tokens.dropFirst().compactMap { token -> DestinationEntry? in
                        guard let r = lookupCity(token) else { return nil }
                        return DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon)
                    }
                    await MainActor.run {
                        guard let bundle = self.bundle(for: trip.id) else { return }
                        bundle.countryCode = local.code
                        bundle.latitude    = local.lat
                        bundle.longitude   = local.lon
                        bundle.additionalDestinations = extras
                        do { try self.context.save() } catch {
                            CarryLogger.shared.log(.persistFailed, context: "caller=geocodeMissingTrips_local")
                        }
                    }
                    continue
                }

                // Fall back to CLGeocoder for primary
                guard let primary = await geocodeToken(primaryToken) else { continue }

                // Resolve extras (local then geocoder)
                var extras: [DestinationEntry] = []
                for token in tokens.dropFirst() {
                    if let r = lookupCity(token) {
                        extras.append(DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon))
                    } else if let r = await geocodeToken(token) {
                        extras.append(DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon))
                    }
                }

                await MainActor.run {
                    guard let bundle = self.bundle(for: trip.id) else { return }
                    if !primary.code.isEmpty { bundle.countryCode = primary.code }
                    bundle.latitude  = primary.lat
                    bundle.longitude = primary.lon
                    bundle.additionalDestinations = extras
                    do { try self.context.save() } catch {
                        CarryLogger.shared.log(.persistFailed, context: "caller=geocodeMissingTrips_geocoder")
                    }
                }
            }

            // 2. Trips whose primary is already resolved but extras are missing
            for trip in missingExtras {
                let tokens = splitCities(trip.destinationCity)
                var extras: [DestinationEntry] = []
                for token in tokens.dropFirst() {
                    if let r = lookupCity(token) {
                        extras.append(DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon))
                    } else if let r = await geocodeToken(token) {
                        extras.append(DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon))
                    }
                }
                guard !extras.isEmpty else { continue }
                await MainActor.run {
                    guard let bundle = self.bundle(for: trip.id) else { return }
                    bundle.additionalDestinations = extras
                    do { try self.context.save() } catch {
                        CarryLogger.shared.log(.persistFailed, context: "caller=geocodeMissingTrips_extras")
                    }
                }
            }
        }
    }
}
