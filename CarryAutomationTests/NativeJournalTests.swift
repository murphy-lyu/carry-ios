import XCTest
import SwiftData
@testable import Carry

@MainActor
final class NativeJournalTests: XCTestCase {
    private enum Injected: Error { case failed }
    private func database() throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryNativeJournal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Do not unlink SQLite handles retained by SwiftData's run-loop processing.
        return try CarryAccountReplica.container(at: directory.appendingPathComponent("account.store"))
    }
    private func trip() -> (TripBundle, PackingItem) {
        let item = PackingItem(name: "Synthetic passport", isAlert: false, sortOrder: 0)
        let value = TripBundle(name: "Synthetic", destinationCity: "", days: 0, dateRange: "", isDateless: true,
            sections: [PackingSection(title: "Synthetic", items: [item])])
        return (value, item)
    }
    private func changes(_ context: ModelContext) throws -> [CarryNativeChange] {
        try context.fetch(FetchDescriptor<CarryNativeChange>()).sorted { $0.ordinal < $1.ordinal }
    }
    private func transactions(_ context: ModelContext) throws -> [CarryNativeTransaction] {
        try context.fetch(FetchDescriptor<CarryNativeTransaction>(sortBy: [SortDescriptor(\.sequence)]))
    }

    func testBusinessGraphAndImmutableChangesCommitTogetherAndSurviveReopen() throws {
        let container = try database(), context = ModelContext(container), journal = CarryNativeChangeJournal(accountID: UUID())
        let (trip, item) = trip(); context.insert(trip)
        try CarryPersistence.commit(context, using: journal.captureAndSave)
        let reader = ModelContext(container)
        XCTAssertEqual(try transactions(reader).map(\.sequence), [1])
        XCTAssertEqual(try changes(reader).count, 3)
        XCTAssertEqual(try transactions(reader).first?.changeCount, 3)
        XCTAssertEqual(Set(try changes(reader).map(\.kind)), ["trip", "section", "packingItem"])
        item.isPacked = true
        XCTAssertEqual(try transactions(ModelContext(container)).count, 1, "Unsaved native edits cannot publish journal entries")
        try CarryPersistence.commit(context, using: journal.captureAndSave)
        let reopened = ModelContext(container)
        let second = try XCTUnwrap(transactions(reopened).last)
        let update = try XCTUnwrap(changes(reopened).first { $0.transactionID == second.id })
        XCTAssertEqual(second.sequence, 2); XCTAssertEqual(second.changeCount, 1)
        XCTAssertEqual(update.entityID, item.id); XCTAssertEqual(update.changedFields, ["isPacked"])
        XCTAssertFalse(update.thumbnailChanged)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<TripBundle>()).first?.packedCount, 1)
    }

    func testRejectedCaptureCannotPersistBusinessChangesOrAdvanceJournalSequence() throws {
        let container = try database(), context = ModelContext(container), owner = UUID()
        let journal = CarryNativeChangeJournal(accountID: owner), (trip, item) = trip()
        context.insert(trip); try CarryPersistence.commit(context, using: journal.captureAndSave)
        item.quantity = 8
        XCTAssertThrowsError(try CarryPersistence.commit(context, using: { transaction in
            try journal.capture(in: transaction)
            throw Injected.failed
        }))
        let fresh = ModelContext(container)
        XCTAssertEqual(try transactions(fresh).map(\.sequence), [1])
        let persisted = try XCTUnwrap(fresh.fetch(FetchDescriptor<PackingItem>()).first)
        XCTAssertEqual(persisted.quantity, 1)
        persisted.quantity = 3
        try CarryPersistence.commit(fresh, using: journal.captureAndSave)
        XCTAssertEqual(try transactions(ModelContext(container)).map(\.sequence), [1, 2])
    }

    func testHotPackingCaptureDoesNotDecodeAnUnrelatedTripSnapshotOrReadAnyFile() throws {
        let container = try database(), context = ModelContext(container), journal = CarryNativeChangeJournal(accountID: UUID())
        let (trip, item) = trip(); context.insert(trip)
        try CarryPersistence.commit(context, using: journal.captureAndSave)
        let rootID = trip.id
        let root = try XCTUnwrap(context.fetch(FetchDescriptor<CarryNativeMaterialization>(predicate: #Predicate { $0.id == rootID })).first)
        root.sourceData = Data([0xff]) // An accidental whole-trip decode must fail this test.
        try context.save()
        item.isPacked = true
        try CarryPersistence.commit(context, using: journal.captureAndSave)
        let last = try XCTUnwrap(transactions(context).last)
        XCTAssertEqual(last.changeCount, 1)
        XCTAssertEqual(try changes(context).first { $0.transactionID == last.id }?.changedFields, ["isPacked"])
    }

    func testDeletionRetainsDurableIntentAfterTheNativeModelDisappears() throws {
        let container = try database(), context = ModelContext(container), journal = CarryNativeChangeJournal(accountID: UUID())
        let (trip, _) = trip(), id = trip.id
        context.insert(trip); try CarryPersistence.commit(context, using: journal.captureAndSave)
        context.delete(trip)
        try CarryPersistence.commit(context, using: journal.captureAndSave)
        let fresh = ModelContext(container)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<TripBundle>()).isEmpty)
        let event = try XCTUnwrap(changes(fresh).first { $0.entityID == id && $0.action == "delete" })
        let source = try JSONDecoder().decode(CarryNativeSourceMetadata.self, from: event.sourceData)
        XCTAssertEqual(source.fields["name"], .string("Synthetic"))
        XCTAssertTrue(try XCTUnwrap(fresh.fetch(FetchDescriptor<CarryNativeMaterialization>(predicate: #Predicate { $0.id == id })).first).locallyDeleted)
    }

    func testFullBackupRestoreWithTheSameUUIDsCapturesSurvivingReplacementsAsEdits() throws {
        let container = try database(), context = ModelContext(container), journal = CarryNativeChangeJournal(accountID: UUID())
        let (original, item) = trip()
        context.insert(original); try CarryPersistence.commit(context, using: journal.captureAndSave)
        let section = try XCTUnwrap(original.safeSections.first)
        let tripID = original.id, itemID = item.id, sectionID = section.id
        let packet = CarryBackup(version: DataBackupManager.currentBackupVersion, createdAt: Date(), trips: [BackupTrip(
            id: tripID, name: "Restored name", destinationCity: original.destinationCity, days: original.days,
            dateRange: original.dateRange, departureDate: original.departureDate, isDateless: original.isDateless,
            createdAt: original.createdAt, selectedSceneKeys: original.selectedSceneKeys,
            dismissedSurpriseNames: original.dismissedSurpriseNames, sceneCardDismissed: original.sceneCardDismissed,
            remindersEnabled: original.remindersEnabled, reminderConfigData: original.reminderConfigData,
            countryCode: original.countryCode, latitude: original.latitude, longitude: original.longitude,
            additionalDestinationsData: nil, backgroundsData: nil,
            sections: [BackupPackingSection(id: sectionID, title: section.title, sortOrder: section.sortOrder,
                items: [BackupPackingItem(id: itemID, name: item.name, quantity: 3, isPacked: true,
                    isAlert: item.isAlert, sortOrder: item.sortOrder)])], itineraryDays: [], lodgingStays: [])], myItems: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        _ = try DataBackupManager.shared.restoreFromData(encoder.encode(packet), into: context, save: journal.captureAndSave)
        let reopened = ModelContext(container)
        let restored = try XCTUnwrap(reopened.fetch(FetchDescriptor<TripBundle>()).first)
        XCTAssertEqual(restored.id, tripID); XCTAssertEqual(restored.name, "Restored name")
        let restoredItem = try XCTUnwrap(restored.safeSections.first?.items?.first)
        XCTAssertEqual(restoredItem.id, itemID); XCTAssertEqual(restoredItem.quantity, 3); XCTAssertTrue(restoredItem.isPacked)
        let latest = try XCTUnwrap(transactions(reopened).last)
        let edits = try changes(reopened).filter { $0.transactionID == latest.id }
        XCTAssertEqual(latest.sequence, 2); XCTAssertEqual(latest.changeCount, 2)
        XCTAssertEqual(Set(edits.map(\.entityID)), [tripID, itemID])
        XCTAssertTrue(edits.allSatisfy { $0.action == "upsert" })
        XCTAssertEqual(edits.first { $0.entityID == tripID }?.changedFields, ["name"])
        XCTAssertEqual(edits.first { $0.entityID == itemID }?.changedFields, ["isPacked", "quantity"])
        XCTAssertTrue(try reopened.fetch(FetchDescriptor<CarryNativeMaterialization>()).allSatisfy { !$0.locallyDeleted })
    }

    func testCaptureRejectsMultipleLiveInstancesAndReplacementWithAnotherKind() throws {
        for replacingDeleted in [false, true] {
            let container = try database(), context = ModelContext(container), journal = CarryNativeChangeJournal(accountID: UUID())
            let first = MyItem(name: "Synthetic", category: "Synthetic")
            context.insert(first); try CarryPersistence.commit(context, using: journal.captureAndSave)
            if replacingDeleted {
                let id = first.id
                context.delete(first)
                let replacement = TripBundle(name: "Wrong kind", destinationCity: "", days: 0, dateRange: "")
                replacement.id = id; context.insert(replacement)
            } else {
                let duplicate = MyItem(name: "Duplicate", category: "Synthetic"); duplicate.id = first.id; context.insert(duplicate)
            }
            XCTAssertThrowsError(try CarryPersistence.commit(context, using: journal.captureAndSave))
            let reader = ModelContext(container)
            XCTAssertEqual(try reader.fetch(FetchDescriptor<MyItem>()).map(\.name), ["Synthetic"])
            XCTAssertTrue(try reader.fetch(FetchDescriptor<TripBundle>()).isEmpty)
            XCTAssertEqual(try transactions(reader).map(\.sequence), [1])
        }
    }

    func testAccountOwnerAndNativeSchemaAreMandatoryAndUnknownBaselineCannotBecomeACreate() throws {
        let container = try database(), context = ModelContext(container), owner = UUID()
        let journal = CarryNativeChangeJournal(accountID: owner), (trip, item) = trip()
        context.insert(trip); try CarryPersistence.commit(context, using: journal.captureAndSave)
        XCTAssertThrowsError(try CarryNativeChangeJournal(accountID: UUID()).capture(in: ModelContext(container)))
        let orphanContainer = try database(), orphanContext = ModelContext(orphanContainer)
        let (untracked, untrackedItem) = self.trip(); orphanContext.insert(untracked); try orphanContext.save()
        untrackedItem.quantity = 2
        XCTAssertThrowsError(try journal.capture(in: orphanContext))
        let schema = Schema(SchemaV1.models)
        let device = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        XCTAssertThrowsError(try journal.capture(in: ModelContext(device)))
        XCTAssertEqual(item.quantity, 1)
    }

    func testProjectionBaselineCannotErasePendingEditsAndBinaryThumbnailStaysBinary() throws {
        let container = try database(), context = ModelContext(container), journal = CarryNativeChangeJournal(accountID: UUID())
        let (trip, _) = trip()
        let photo = StopPhoto(assetLocalIdentifier: "synthetic-library-id", thumbnailData: Data([1, 2, 3]))
        let stop = ItineraryStop(name: "Synthetic"); stop.photos = [photo]
        trip.itineraryDays = [ItineraryDay(stops: [stop])]
        context.insert(trip); try CarryPersistence.commit(context, using: journal.captureAndSave)
        let event = try XCTUnwrap(changes(context).first { $0.kind == "photo" })
        XCTAssertEqual(event.thumbnailData, Data([1, 2, 3]))
        let metadata = try JSONDecoder().decode(CarryNativeSourceMetadata.self, from: event.sourceData)
        XCTAssertNil(metadata.fields["thumbnailData"])
        let source = try XCTUnwrap(CarryNativeSourceCodec.capture(photo))
        let remote = CarryGraphEntity(id: photo.id, kind: "photo", parentID: source.metadata.parentID, version: 1,
            subtreeVersion: 1, fields: source.metadata.fields, fieldVersions: [:])
        XCTAssertThrowsError(try journal.noteMaterialized(source, observed: remote, in: context))
        XCTAssertEqual(try transactions(context).count, 1)
    }
}
