import XCTest
import SwiftData
@testable import Carry

@MainActor
final class NativePersistenceTests: XCTestCase {
    private enum Injected: Error { case rejected }

    private func database() throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryNativeSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // SwiftData can keep SQLite handles through a deferred run-loop turn.
        // Keep this process-local fixture in simulator temporary storage rather
        // than unlink a still-open SQLite database during XCTest teardown.
        let schema = Schema(SchemaV1.models + [CarryReplicaRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("native.store"), cloudKitDatabase: .none)])
    }

    private func seed(_ context: ModelContext) throws -> (TripBundle, PackingItem) {
        let item = PackingItem(name: "Synthetic passport", isAlert: false, sortOrder: 0)
        let trip = TripBundle(name: "Synthetic", destinationCity: "", days: 0, dateRange: "", isDateless: true)
        trip.sections = [PackingSection(title: "Synthetic", items: [item])]
        context.insert(trip); try context.save()
        return (trip, item)
    }

    func testOrdinaryAndDirectBusinessWritesCommitTheirCapturedIntentTogether() async throws {
        let container = try database(), context = ModelContext(container)
        context.autosaveEnabled = false
        let (trip, item) = try seed(context)
        var captures = 0
        let store = TripStore(context: context, persistenceSave: { transaction in
            XCTAssertTrue(transaction === context)
            transaction.insert(CarryReplicaRecord(id: UUID(), payload: Data("synthetic-outbox".utf8), hasPendingChanges: true))
            try transaction.save(); captures += 1
        })
        for _ in 0..<1000 where !store.automationReady { await Task.yield() }
        XCTAssertTrue(store.automationReady)
        let before = captures
        store.toggleItem(tripId: trip.id, itemId: item.id)
        store.updateItemName(tripId: trip.id, itemId: item.id, name: "Renamed offline")
        store.updateItemQuantity(tripId: trip.id, itemId: item.id, quantity: 3)
        XCTAssertEqual(captures - before, 3)
        let persisted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first?.safeSections.first?.items?.first)
        XCTAssertTrue(persisted.isPacked); XCTAssertEqual(persisted.name, "Renamed offline"); XCTAssertEqual(persisted.quantity, 3)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CarryReplicaRecord>()).count, captures)
    }

    func testRejectedCaptureRollsBackBusinessEditsAndOutboxInBothSavePaths() async throws {
        let container = try database(), context = ModelContext(container)
        context.autosaveEnabled = false
        let (trip, item) = try seed(context)
        var reject = false
        let store = TripStore(context: context, persistenceSave: { transaction in
            if reject {
                transaction.insert(CarryReplicaRecord(id: UUID(), payload: Data("must-rollback".utf8), hasPendingChanges: true))
                throw Injected.rejected
            }
            try transaction.save()
        })
        for _ in 0..<1000 where !store.automationReady { await Task.yield() }
        XCTAssertTrue(store.automationReady)
        reject = true
        store.toggleItem(tripId: trip.id, itemId: item.id)
        store.updateItemName(tripId: trip.id, itemId: item.id, name: "Must not persist")
        store.updateItemQuantity(tripId: trip.id, itemId: item.id, quantity: 9)
        let current = try XCTUnwrap(store.trips.first?.safeSections.first?.items?.first)
        XCTAssertFalse(current.isPacked); XCTAssertEqual(current.name, "Synthetic passport"); XCTAssertEqual(current.quantity, 1)
        XCTAssertFalse(context.autosaveEnabled)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CarryReplicaRecord>()).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first?.safeSections.first?.items?.first?.name, "Synthetic passport")
        reject = false
        store.toggleItem(tripId: trip.id, itemId: item.id)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first?.packedCount, 1)
    }

    func testRejectedDeleteKeepsOriginalFilesAndRetryCommitsOnlyOnce() async throws {
        let container = try database(), context = ModelContext(container)
        context.autosaveEnabled = false
        let (trip, _) = try seed(context)
        let name = UUID().uuidString + ".jpg"
        let bytes = Data("synthetic-original-file".utf8)
        XCTAssertTrue(BackgroundImageStore.write(data: bytes, named: name))
        addTeardownBlock { await MainActor.run { BackgroundImageStore.delete(named: name) } }
        trip.backgrounds = [TripBackgroundEntry(source: .local, localFileName: name, destinationIndex: 0)]
        try context.save()
        var reject = false, writes = 0
        let store = TripStore(context: context, persistenceSave: { transaction in
            if reject { throw Injected.rejected }
            try transaction.save(); writes += 1
        })
        for _ in 0..<1000 where !store.automationReady { await Task.yield() }
        reject = true
        store.clearBackground(forTripId: trip.id)
        XCTAssertEqual(BackgroundImageStore.data(named: name), bytes)
        XCTAssertEqual(store.trips.first?.primaryBackground?.localFileName, name)
        store.removeTrip(withId: trip.id)
        XCTAssertEqual(store.trips.count, 1)
        XCTAssertEqual(BackgroundImageStore.data(named: name), bytes)
        XCTAssertThrowsError(try store.mergeBackup(backup()))
        XCTAssertEqual(store.trips.count, 1)
        reject = false
        let before = writes
        store.removeTrip(withId: trip.id)
        XCTAssertEqual(writes - before, 1)
        XCTAssertTrue(store.trips.isEmpty)
        XCTAssertNil(BackgroundImageStore.data(named: name))
    }

    func testRejectedDraftCanRetryWithoutReusingInvalidatedModelsOrChangingIdentities() async throws {
        let container = try database(), context = ModelContext(container)
        var reject = false
        let store = TripStore(context: context, persistenceSave: { transaction in
            if reject { throw Injected.rejected }
            try transaction.save()
        })
        for _ in 0..<1000 where !store.automationReady { await Task.yield() }
        let item = PackingItem(name: "Synthetic", quantity: 3, isPacked: true, isAlert: false, sortOrder: 4)
        let section = PackingSection(title: "Synthetic", items: [item], sortOrder: 2)
        let draft = TripBundle(name: "Retry me", destinationCity: "", days: 0, dateRange: "", isDateless: true,
            sections: [section])
        let tripID = draft.id, sectionID = section.id, itemID = item.id
        store.setDraftTrip(draft)
        reject = true
        XCTAssertFalse(store.commitDraftTrip())
        let recovered = try XCTUnwrap(store.draftTrip)
        XCTAssertFalse(recovered === draft)
        XCTAssertEqual(recovered.id, tripID)
        XCTAssertEqual(recovered.safeSections.first?.id, sectionID)
        XCTAssertEqual(recovered.safeSections.first?.items?.first?.id, itemID)
        XCTAssertEqual(recovered.packedCount, 1)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
        reject = false
        XCTAssertTrue(store.commitDraftTrip())
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first)
        XCTAssertEqual(saved.id, tripID)
        XCTAssertEqual(saved.safeSections.first?.items?.first?.quantity, 3)
        XCTAssertEqual(saved.packedCount, 1)
    }

    func testRejectedFullRestoreKeepsOriginalGraphAndRemainsRetryable() async throws {
        let container = try database(), context = ModelContext(container)
        let (original, _) = try seed(context)
        let originalID = original.id
        var reject = false
        let store = TripStore(context: context, persistenceSave: { transaction in
            if reject { throw Injected.rejected }
            try transaction.save()
        })
        for _ in 0..<1000 where !store.automationReady { await Task.yield() }
        let incoming = backup()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(incoming)
        reject = true
        XCTAssertThrowsError(try store.restoreFromData(bytes))
        XCTAssertEqual(store.trips.map(\.id), [originalID])
        XCTAssertEqual(store.trips.first?.totalCount, 1)
        reject = false
        _ = try store.restoreFromData(bytes)
        XCTAssertEqual(store.trips.map(\.id), incoming.trips.map(\.id))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).count, 1)
    }

    private func backup() -> CarryBackup {
        CarryBackup(version: DataBackupManager.currentBackupVersion, createdAt: Date(), trips: [BackupTrip(
            id: UUID(), name: "Synthetic imported", destinationCity: "", days: 0, dateRange: "", departureDate: Date(),
            isDateless: true, createdAt: Date(), selectedSceneKeys: [], dismissedSurpriseNames: [],
            sceneCardDismissed: false, remindersEnabled: false, reminderConfigData: Data(), countryCode: "", latitude: 0,
            longitude: 0, additionalDestinationsData: nil, backgroundsData: nil, sections: [], itineraryDays: [], lodgingStays: [])], myItems: [])
    }

    func testEveryBackupEntryPassesItsFinalTransactionToTheWriterAndPropagatesRejection() throws {
        let priorOffsets = ReminderPreferences.enabledOffsets
        defer { ReminderPreferences.enabledOffsets = priorOffsets }
        var packet = backup()
        packet.defaultReminderOffsets = priorOffsets == [0] ? [1] : [0]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(packet)
        for operation in 0..<4 {
            let container = try database(), context = ModelContext(container)
            context.autosaveEnabled = false
            var calls = 0
            let writer: CarryPersistence.Save = { transaction in
                XCTAssertTrue(transaction === context)
                XCTAssertEqual(try transaction.fetch(FetchDescriptor<TripBundle>()).count, 1)
                transaction.insert(CarryReplicaRecord(id: UUID(), payload: Data(), hasPendingChanges: true))
                calls += 1
                throw Injected.rejected
            }
            XCTAssertThrowsError(try {
                switch operation {
                case 0: _ = try DataBackupManager.shared.merge(packet, into: context, save: writer)
                case 1: _ = try DataBackupManager.shared.mergeFromData(bytes, into: context, save: writer)
                case 2: _ = try DataBackupManager.shared.restoreFromData(bytes, into: context, save: writer)
                default: _ = try DataBackupManager.shared.importSharedTrip(from: bytes, into: context, save: writer)
                }
            }())
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(ReminderPreferences.enabledOffsets, priorOffsets)
            XCTAssertThrowsError(try CarryPersistence.commit(context, using: writer))
            XCTAssertEqual(calls, 1, "A rejected context must never commit on a later retry")
            XCTAssertFalse(context.autosaveEnabled)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CarryReplicaRecord>()).isEmpty)
        }
    }
}
