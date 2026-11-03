import XCTest
import SwiftData
@testable import Carry

@MainActor
final class MigrationOwnershipTests: XCTestCase {
    private func store() throws -> TripStore {
        let schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        return TripStore(context: ModelContext(container), scope: .account(didChange: {}))
    }
    private func trip() -> TripBundle {
        TripBundle(name: "Synthetic source", destinationCity: "Tokyo", days: 3,
            sections: [PackingSection(title: "Camera", items: [PackingItem(name: "Lens", quantity: 3, isPacked: true, isAlert: true)])])
    }
    func testSourceFingerprintCoversNestedPackingStateAndStableRecapture() throws {
        let source = trip(), first = try CarryMigrationSourceSnapshot.capture(trip: source)
        XCTAssertEqual(try first.fingerprint(), try CarryMigrationSourceSnapshot.capture(trip: source).fingerprint())
        source.safeSections[0].items?[0].isPacked = false
        XCTAssertNotEqual(try first.fingerprint(), try CarryMigrationSourceSnapshot.capture(trip: source).fingerprint())
    }
    func testReadOnlyGateBlocksSavedSourceAndNewDescendantsButAllowsUnrelatedRoot() throws {
        let store = try store(), source = trip(), batch = UUID()
        store.addTrip(source)
        store.migrationWriteGuard.protect(batchID: batch, snapshots: [try .capture(trip: source)])
        source.name = "Forbidden"
        XCTAssertThrowsError(try store.migrationWriteGuard.validate(store.businessContext))
        store.businessContext.rollback()
        let fresh = TripBundle(name: "Allowed", destinationCity: "", days: 1, dateRange: "")
        store.businessContext.insert(fresh)
        XCTAssertNoThrow(try store.migrationWriteGuard.validate(store.businessContext))
        store.businessContext.rollback()
        let section = PackingSection(title: "New child", items: [])
        source.sections?.append(section)
        store.businessContext.insert(section)
        XCTAssertThrowsError(try store.migrationWriteGuard.validate(store.businessContext))
        store.businessContext.rollback()
        store.migrationWriteGuard.release(batchID: batch)
    }
    func testRecoveryCopyPreservesEveryFieldAndAllocatesIndependentIdentityGraph() throws {
        let store = try store(), source = trip(), batch = UUID()
        store.addTrip(source)
        let original = try CarryMigrationSourceSnapshot.capture(trip: source)
        store.migrationWriteGuard.protect(batchID: batch, snapshots: [original])
        let evidence = try XCTUnwrap(store.recoverMigrationSourceCopies(tripIDs: [source.id], libraryIDs: []).first)
        XCTAssertNoThrow(try evidence.validate())
        XCTAssertTrue(evidence.source.entityIDs.isDisjoint(with: evidence.copy.entityIDs))
        XCTAssertEqual(evidence.source, original)
        XCTAssertEqual(try CarryMigrationSourceSnapshot.capture(trip: source), original)
        let copy = try XCTUnwrap(store.trips.first { $0.id == evidence.copy.rootID })
        XCTAssertEqual(copy.safeSections.first?.items?.first?.quantity, 3)
        XCTAssertEqual(copy.safeSections.first?.items?.first?.isPacked, true)
        store.migrationWriteGuard.release(batchID: batch)
    }
    func testOwnershipRoutingWaitsForNativeMaterializationAndHidesLibraryAfterSignOut() throws {
        let local = try store(), account = try store(), original = trip(), owner = UUID(), batch = UUID()
        local.addTrip(original)
        let item = try XCTUnwrap(local.addMyItem(name: "Synthetic lens"))
        let snapshots = [try CarryMigrationSourceSnapshot.capture(trip: original), try .capture(item: item)]
        let rows = try snapshots.map { value in
            CarryAccountMigrationOwnershipRecord(rootID: value.rootID, accountID: owner, batchID: batch, kind: value.kind,
                sourceFingerprint: try value.fingerprint(), sourceEntityIDs: Array(value.entityIDs), sourceSnapshot: try JSONEncoder().encode(value))
        }
        rows.forEach { $0.active = true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryOwnershipTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = CarryWorkspaceLibrary(local: local)
        library.configureOwnershipIndex(directory: directory)
        try library.updateOwnership(accountID: owner, records: rows, materializedRootIDs: [])
        XCTAssertEqual(library.visibleTrips.map(\.id), [original.id], "The only native copy remains readable while account projection is pending")
        let projected = trip(); projected.id = original.id; account.addTrip(projected)
        try library.attach(account, accountID: owner)
        XCTAssertTrue(library.owningStore(for: original.id) === local)
        try library.updateOwnership(accountID: owner, records: rows, materializedRootIDs: [original.id, item.id])
        XCTAssertTrue(library.owningStore(for: original.id) === account)
        XCTAssertTrue(local.visibleMyItems.isEmpty)
        XCTAssertEqual(local.myItems.count, 1, "The immutable recovery source is retained")
        library.detach()
        XCTAssertTrue(library.visibleTrips.isEmpty)
        XCTAssertTrue(local.visibleMyItems.isEmpty)
        XCTAssertTrue(local.migrationWriteGuard.isProtected(item.id))
        XCTAssertEqual(try CarryMigrationOwnershipIndex.readAll(in: directory).first?.roots.count, 2)
    }
    func testIndexRejectsForeignOwner() throws {
        let source = trip(), owner = UUID(), snapshot = try CarryMigrationSourceSnapshot.capture(trip: source)
        let row = CarryAccountMigrationOwnershipRecord(rootID: source.id, accountID: owner, batchID: UUID(), kind: "trip",
            sourceFingerprint: try snapshot.fingerprint(), sourceEntityIDs: Array(snapshot.entityIDs), sourceSnapshot: try JSONEncoder().encode(snapshot))
        XCTAssertThrowsError(try CarryMigrationOwnershipIndex(accountID: UUID(), records: [row]))
    }
    func testIncomingSourceFileReferenceIsProtectedWithoutApprovingTheFork() throws {
        let store = try store(), source = trip(), batch = UUID()
        store.addTrip(source)
        let library = CarryWorkspaceLibrary(local: store)
        store.migrationWriteGuard.protect(batchID: batch, snapshots: [try .capture(trip: source)])
        let bytes = Data("Synthetic incoming immutable cover".utf8), name = UUID().uuidString + ".jpg"
        let url = BackgroundImageStore.fileURL(named: name)
        try bytes.write(to: url)
        defer { store.migrationWriteGuard.release(batchID: batch); try? FileManager.default.removeItem(at: url) }
        // Simulate an older CloudKit writer, which does not execute this build's
        // save guard. It introduces a reference not present in the staged plan.
        source.backgrounds = [TripBackgroundEntry(source: .local, localFileName: name)]
        try store.businessContext.save()
        XCTAssertTrue(CarryMigrationSourceFileRetention.contains(named: name))
        BackgroundImageStore.delete(named: name)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        withExtendedLifetime(library) { }
    }
    func testSourceFileReadFailurePreventsDeletionAndReleasedProviderDoesNotBlockOthers() throws {
        let file = try XCTUnwrap(AttachmentStore.save(Data("Synthetic retention guard".utf8), ext: "pdf"))
        let url = AttachmentStore.fileURL(named: file)
        let id = CarryMigrationSourceFileRetention.register { throw CarryMigrationOwnershipFailure.invalidState }
        XCTAssertTrue(CarryMigrationSourceFileRetention.contains(named: file))
        AttachmentStore.delete(named: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        CarryMigrationSourceFileRetention.unregister(id)
        let unrelated = UUID().uuidString + ".pdf"
        XCTAssertFalse(CarryMigrationSourceFileRetention.contains(named: unrelated))
        AttachmentStore.delete(named: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecoveryRetryUsesOneStableGraphAndNeverOverwritesAnEditedCopy() throws {
        let store = try store(), source = trip(), batch = UUID()
        store.addTrip(source)
        let snapshot = try CarryMigrationSourceSnapshot.capture(trip: source)
        let first = try XCTUnwrap(store.recoverMigrationSourceCopies(tripIDs: [source.id], libraryIDs: [], batchID: batch, expectedSources: [snapshot]).first)
        let second = try XCTUnwrap(store.recoverMigrationSourceCopies(tripIDs: [source.id], libraryIDs: [], batchID: batch, expectedSources: [snapshot]).first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.trips.count, 2)
        let copy = try XCTUnwrap(store.trips.first { $0.id == first.copy.rootID })
        copy.name = "User edited recovery copy"
        try store.businessContext.save()
        XCTAssertThrowsError(try store.recoverMigrationSourceCopies(tripIDs: [source.id], libraryIDs: [], batchID: batch, expectedSources: [snapshot]))
        XCTAssertEqual(store.trips.count, 2)
        XCTAssertEqual(store.trips.first { $0.id == copy.id }?.name, "User edited recovery copy")
    }
    func testRecoveryRejectsChangedSourceBeforeCreatingAnyCopy() throws {
        let store = try store(), source = trip()
        store.addTrip(source)
        let reviewed = try CarryMigrationSourceSnapshot.capture(trip: source)
        source.name = "Changed after review"; try store.businessContext.save()
        XCTAssertThrowsError(try store.recoverMigrationSourceCopies(tripIDs: [source.id], libraryIDs: [], batchID: UUID(), expectedSources: [reviewed]))
        XCTAssertEqual(store.trips.count, 1)
    }

    func testSourceDifferenceContainsConcreteBeforeAndAfterBusinessValues() throws {
        let schema = CarryAccountReplica.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let ownership = try CarryAccountMigrationOwnership(accountID: UUID(), context: ModelContext(container))
        let source = trip(), snapshot = try CarryMigrationSourceSnapshot.capture(trip: source)
        try ownership.stage(batchID: UUID(), snapshots: [snapshot])
        let item = try XCTUnwrap(source.safeSections.first?.items?.first)
        item.quantity = 8
        let differences = try ownership.differences(rootID: source.id, current: .capture(trip: source))
        let changed = try XCTUnwrap(differences.first { $0.entityID == item.id })
        XCTAssertEqual(changed.before["quantity"], .integer(3))
        XCTAssertEqual(changed.after["quantity"], .integer(8))
        XCTAssertEqual(changed.fields, ["quantity"])
    }

}
