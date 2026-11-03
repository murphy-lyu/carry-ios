import XCTest
import SwiftData
@testable import Carry

@MainActor
final class NativeJournalBridgeTests: XCTestCase {
    private enum Injected: Error { case failed }
    private func database() throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryNativeBridge-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try CarryAccountReplica.container(at: directory.appendingPathComponent("account.store"))
    }
    private func seed(_ context: ModelContext, journal: CarryNativeChangeJournal) throws -> (TripBundle, PackingItem) {
        let item = PackingItem(name: "Synthetic passport")
        let trip = TripBundle(name: "Synthetic trip", destinationCity: "Tokyo", days: 0, dateRange: "", isDateless: true)
        trip.sections = [PackingSection(title: "Synthetic", items: [item])]
        context.insert(trip); try CarryPersistence.commit(context, using: journal.captureAndSave)
        return (trip, item)
    }
    private func acceptCreation(_ replica: CarryAccountReplica) throws {
        let command = try XCTUnwrap(replica.nextCommand())
        let changes = command.mutations.enumerated().map { index, mutation in
            CarryGraphChange(sequence: index + 1, entity: CarryGraphEntity(id: mutation.id, kind: mutation.kind, parentID: mutation.parentID,
                version: 1, subtreeVersion: index + 1, fields: mutation.fields ?? [:], fieldVersions: (mutation.fields ?? [:]).mapValues { _ in 1 }))
        }
        try replica.accept(CarryGraphReceipt(status: "saved_to_account", requestID: command.requestID, changes: changes, cursor: changes.count))
    }
    private func makeRemote(_ container: ModelContainer, context: ModelContext, owner: UUID,
                            replica: CarryAccountReplica, bridge: CarryNativeJournalBridge) throws {
        XCTAssertEqual(try bridge.apply(batch: XCTUnwrap(bridge.nextBatch())), .consumed)
        try acceptCreation(replica)
        _ = try CarryNativeGraphProjector(accountID: owner).project(snapshot: replica.projectionSnapshot(), in: context)
    }

    func testTransactionsConsumeStrictlyInOrderAndRestartPreservesTheNextImmutableBatch() throws {
        let container = try database(), context = ModelContext(container), owner = UUID(), journal = CarryNativeChangeJournal(accountID: owner)
        let (_, item) = try seed(context, journal: journal)
        item.isPacked = true; try CarryPersistence.commit(context, using: journal.captureAndSave)
        let replica = try CarryAccountReplica(container: container, accountID: owner), bridge = CarryNativeJournalBridge(replica: replica)
        let first = try XCTUnwrap(bridge.nextBatch())
        XCTAssertEqual(first.sequence, 1); XCTAssertEqual(first.changes.count, 3)
        XCTAssertEqual(try bridge.apply(batch: first), .consumed)
        let reopened = try CarryAccountReplica(container: container, accountID: owner), resumed = CarryNativeJournalBridge(replica: reopened)
        let second = try XCTUnwrap(resumed.nextBatch())
        XCTAssertEqual(second.sequence, 2); XCTAssertEqual(second.changes.map(\.changedFields), [["isPacked"]])
        XCTAssertThrowsError(try resumed.apply(batch: first))
        var calls = 0
        XCTAssertEqual(try resumed.apply(batch: second, resolveFields: { _, _ in calls += 1; return CarryNativeResolvedFields() }), .consumed)
        XCTAssertEqual(calls, 0, "Metadata-only packing edits must not resolve or read assets")
        XCTAssertNil(try resumed.nextBatch())
        let mutation = try XCTUnwrap(reopened.nextCommand()?.mutations.first { $0.id == item.id })
        XCTAssertEqual(mutation.fields?["isPacked"], .bool(true))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CarryNativeChange>()).isEmpty)
    }

    func testRawSaveFailureRestoresJournalAndEveryGraphIntentionForRetry() throws {
        let container = try database(), context = ModelContext(container), owner = UUID(), journal = CarryNativeChangeJournal(accountID: owner)
        _ = try seed(context, journal: journal)
        var reject = false
        let replica = try CarryAccountReplica(container: container, accountID: owner, save: { raw in if reject { throw Injected.failed }; try raw.save() })
        let bridge = CarryNativeJournalBridge(replica: replica), batch = try XCTUnwrap(bridge.nextBatch())
        reject = true
        XCTAssertThrowsError(try bridge.apply(batch: batch))
        XCTAssertEqual(try bridge.nextBatch(), batch)
        XCTAssertTrue(try replica.localEntities().isEmpty)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CarryNativeChange>()).count, 3)
        reject = false
        XCTAssertEqual(try bridge.apply(batch: batch), .consumed)
        XCTAssertEqual(try replica.localEntities().count, 3); XCTAssertNil(try bridge.nextBatch())
    }

    func testDeferredAssetRetainsTheWholeTransactionAndRollsBackPreparedBindings() throws {
        let container = try database(), context = ModelContext(container), owner = UUID(), journal = CarryNativeChangeJournal(accountID: owner)
        let (trip, _) = try seed(context, journal: journal)
        let stop = ItineraryStop(name: "Synthetic stop"), photo = StopPhoto(thumbnailData: Data([1, 2, 3]))
        stop.photos = [photo]; trip.itineraryDays = [ItineraryDay(stops: [stop])]
        try CarryPersistence.commit(context, using: journal.captureAndSave)
        let replica = try CarryAccountReplica(container: container, accountID: owner), bridge = CarryNativeJournalBridge(replica: replica)
        _ = try bridge.apply(batch: XCTUnwrap(bridge.nextBatch()))
        let batch = try XCTUnwrap(bridge.nextBatch())
        XCTAssertEqual(try bridge.apply(batch: batch), .deferred)
        let markerID = UUID()
        XCTAssertEqual(try bridge.apply(batch: batch, resolveFields: { change, raw in
            XCTAssertEqual(change.thumbnailData, Data([1, 2, 3]))
            raw.insert(CarryNativeProjectionCheckpoint(id: markerID, desiredData: Data("must rollback".utf8)))
            throw CarryNativeJournalBridgeFailure.assetsDeferred
        }), .deferred)
        XCTAssertEqual(try bridge.nextBatch(), batch)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CarryNativeProjectionCheckpoint>()).isEmpty)
        XCTAssertEqual(try replica.localEntities().count, 3)
        let asset = UUID()
        XCTAssertEqual(try bridge.apply(batch: batch, resolveFields: { _, _ in
            CarryNativeResolvedFields(fields: ["thumbnailAssetID": .string(asset.uuidString)])
        }), .consumed)
        XCTAssertEqual(try replica.localEntities().first { $0.id == photo.id }?.fields["thumbnailAssetID"], .string(asset.uuidString))
    }

    func testCascadeDeleteFormsOneRootButIndependentlyDeletedChildRemainsSeparate() throws {
        for independentChild in [false, true] {
            let container = try database(), context = ModelContext(container), owner = UUID(), journal = CarryNativeChangeJournal(accountID: owner)
            let (trip, item) = try seed(context, journal: journal)
            let itemID = item.id
            let replica = try CarryAccountReplica(container: container, accountID: owner), bridge = CarryNativeJournalBridge(replica: replica)
            try makeRemote(container, context: context, owner: owner, replica: replica, bridge: bridge)
            if independentChild {
                context.delete(item); try CarryPersistence.commit(context, using: journal.captureAndSave)
                let childBatch = try XCTUnwrap(bridge.nextBatch())
                XCTAssertEqual(childBatch.changes.map(\.entityID), [itemID])
                _ = try bridge.apply(batch: childBatch)
            }
            let rootID = trip.id
            context.delete(trip); try CarryPersistence.commit(context, using: journal.captureAndSave)
            let batch = try XCTUnwrap(bridge.nextBatch())
            XCTAssertEqual(batch.changes.count, independentChild ? 2 : 3)
            _ = try bridge.apply(batch: batch)
            let command = try XCTUnwrap(replica.nextCommand())
            XCTAssertEqual(command.mutations.count, independentChild ? 2 : 1)
            XCTAssertTrue(command.mutations.allSatisfy { $0.action == "delete" })
            XCTAssertTrue(command.mutations.contains { $0.id == rootID })
            if independentChild { XCTAssertTrue(command.mutations.contains { $0.id == itemID }) }
        }
    }

    func testChangedImmutableBatchAndWrongAccountCannotBeConsumed() throws {
        let container = try database(), context = ModelContext(container), owner = UUID(), journal = CarryNativeChangeJournal(accountID: owner)
        _ = try seed(context, journal: journal)
        let replica = try CarryAccountReplica(container: container, accountID: owner), bridge = CarryNativeJournalBridge(replica: replica)
        let batch = try XCTUnwrap(bridge.nextBatch())
        let wrong = CarryNativeJournalBatch(accountID: UUID(), id: batch.id, sequence: batch.sequence, createdAt: batch.createdAt, changes: batch.changes)
        XCTAssertThrowsError(try bridge.apply(batch: wrong))
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<CarryNativeChange>()).first)
        row.parentChanged.toggle(); try context.save()
        XCTAssertThrowsError(try bridge.apply(batch: batch))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CarryNativeTransaction>()).count, 1)
        XCTAssertTrue(try replica.localEntities().isEmpty)
    }

    func testRestorationCoalescesOnlyMembersWithTheSameObservedDeletionBatch() throws {
        for independentChild in [false, true] {
            let container = try database(), owner = UUID(), rootID = UUID(), sectionID = UUID(), itemID = UUID(), deletionBatch = UUID()
            let replica = try CarryAccountReplica(container: container, accountID: owner)
            let root = CarryGraphEntity(id: rootID, kind: "trip", parentID: nil, version: 2, subtreeVersion: 1,
                fields: ["name": .string("Synthetic")], fieldVersions: ["name": 1], deletedAt: "2026-10-30T00:00:00Z", deletionBatch: deletionBatch)
            let section = CarryGraphEntity(id: sectionID, kind: "section", parentID: rootID, version: 2, subtreeVersion: 2,
                fields: ["title": .string("Synthetic")], fieldVersions: ["title": 1], deletedAt: root.deletedAt, deletionBatch: deletionBatch)
            let item = CarryGraphEntity(id: itemID, kind: "packingItem", parentID: sectionID, version: 2, subtreeVersion: 3,
                fields: ["name": .string("Synthetic")], fieldVersions: ["name": 1], deletedAt: root.deletedAt, deletionBatch: independentChild ? UUID() : deletionBatch)
            let tombstones = [root, section, item]
            try replica.receive(CarryGraphPage(changes: tombstones.enumerated().map { CarryGraphChange(sequence: $0.offset + 1, entity: $0.element) }, cursor: 3, hasMore: false))
            let context = ModelContext(container), journalOwner = CarryNativeJournalOwner(accountID: owner), transactionID = UUID()
            journalOwner.sequence = 1; context.insert(journalOwner)
            context.insert(CarryNativeTransaction(id: transactionID, sequence: 1, changeCount: 3))
            let encoder = JSONEncoder()
            for (index, entity) in tombstones.enumerated() {
                let metadata = CarryNativeSourceMetadata(id: entity.id, kind: entity.kind, parentID: entity.parentID, fields: entity.fields, fileReferences: [:])
                let bytes = try encoder.encode(metadata)
                context.insert(CarryNativeChange(transactionID: transactionID, ordinal: index, entityID: entity.id, kind: entity.kind,
                    action: "restore", sourceData: bytes, previousSourceData: bytes, observedGraphData: try encoder.encode(entity),
                    changedFields: [], parentChanged: false, thumbnailChanged: false, thumbnailData: nil))
            }
            try context.save()
            let bridge = CarryNativeJournalBridge(replica: replica)
            XCTAssertEqual(try bridge.apply(batch: XCTUnwrap(bridge.nextBatch())), .consumed)
            let command = try XCTUnwrap(replica.nextCommand())
            XCTAssertEqual(command.mutations.count, independentChild ? 2 : 1)
            XCTAssertTrue(command.mutations.allSatisfy { $0.action == "restore" })
            XCTAssertTrue(command.mutations.contains { $0.id == rootID })
            if independentChild { XCTAssertTrue(command.mutations.contains { $0.id == itemID }) }
        }
    }

    func testLongLivedBusinessAndReplicaContextsConsumeSuccessiveSavesWithoutStaleJournalState() throws {
        let container = try database(), business = ModelContext(container), owner = UUID()
        let journal = CarryNativeChangeJournal(accountID: owner)
        let (_, item) = try seed(business, journal: journal)
        let replica = try CarryAccountReplica(container: container, accountID: owner)
        let bridge = CarryNativeJournalBridge(replica: replica)
        let first = try XCTUnwrap(bridge.nextBatch())
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(try bridge.apply(batch: first), .consumed)
        XCTAssertNil(try bridge.nextBatch())
        item.isPacked = true
        try CarryPersistence.commit(business, using: journal.captureAndSave)
        let packed = try XCTUnwrap(bridge.nextBatch())
        XCTAssertEqual(packed.sequence, 2); XCTAssertEqual(packed.changes.map(\.changedFields), [["isPacked"]])
        XCTAssertEqual(try bridge.apply(batch: packed), .consumed)
        XCTAssertNil(try bridge.nextBatch())
        item.quantity = 4
        try CarryPersistence.commit(business, using: journal.captureAndSave)
        let quantity = try XCTUnwrap(bridge.nextBatch())
        XCTAssertEqual(quantity.sequence, 3); XCTAssertEqual(quantity.changes.map(\.changedFields), [["quantity"]])
        XCTAssertEqual(try bridge.apply(batch: quantity), .consumed)
        XCTAssertNil(try bridge.nextBatch())
        let queued = try XCTUnwrap(replica.localEntities().first { $0.id == item.id })
        XCTAssertEqual(queued.fields["isPacked"], .bool(true)); XCTAssertEqual(queued.fields["quantity"], .integer(4))
        XCTAssertThrowsError(try bridge.apply(batch: packed))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CarryNativeTransaction>()).isEmpty)
    }
}
