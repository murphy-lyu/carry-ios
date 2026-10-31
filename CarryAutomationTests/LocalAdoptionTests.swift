import XCTest
import SwiftData
@testable import Carry

@MainActor
final class LocalAdoptionTests: XCTestCase {
    private enum Failure: Error { case forbiddenWrite, unusedAsset, injectedSave }
    private final class SaveControl { var fail = false }
    private final class ReadOnlyServer: CarryGraphTransporting {
        var changes: [CarryGraphChange]
        var writes = 0
        init(_ entities: [CarryGraphEntity]) {
            changes = entities.enumerated().map { offset, value in
                CarryGraphChange(sequence: offset + 1, entity: CarryGraphEntity(id: value.id, kind: value.kind, parentID: value.parentID,
                    version: 1, subtreeVersion: offset + 1, fields: value.fields, fieldVersions: value.fields.mapValues { _ in 1 }))
            }
        }
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt { writes += 1; throw Failure.forbiddenWrite }
        func pull(cursor: Int) async throws -> CarryGraphPage { CarryGraphPage(changes: changes.filter { $0.sequence > cursor }, cursor: changes.count, hasMore: false) }
    }
    private struct Fixture {
        let root: URL
        let accountID: UUID
        let local: TripStore
        let library: CarryWorkspaceLibrary
        let controller: CarryAccountWorkspaceController
        let server: ReadOnlyServer
        let tripID: UUID
        let itemID: UUID
        let saves: SaveControl
    }
    private func fixture(withIncompletePhoto: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CarryLocalAdoption-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try CarryAccountReplica.container(at: root.appendingPathComponent("local.store"))
        let saves = SaveControl()
        let local = TripStore(context: ModelContext(container), persistenceSave: { context in
            if saves.fail { throw Failure.injectedSave }; try context.save()
        }, scope: .account(didChange: {}))
        let source = TripBundle(name: "Local source", destinationCity: "", days: 2, isDateless: true,
            sections: [PackingSection(title: "Camera", items: [PackingItem(name: "Lens", quantity: 3, isPacked: true)])])
        if withIncompletePhoto {
            let day = ItineraryDay(title: "Photo day"), stop = ItineraryStop(name: "Photo stop"), photo = StopPhoto()
            photo.assetLocalIdentifier = ""; stop.photos = [photo]; photo.stop = stop
            day.stops = [stop]; stop.day = day; source.itineraryDays = [day]; day.bundle = source
        }
        local.addTrip(source)
        let item = try XCTUnwrap(local.addMyItem(name: "Local item", defaultQuantity: 4))
        let backup = DataBackupManager.shared.migrationSnapshot(trips: [source], myItems: [item]), owner = UUID()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let portable = try decoder.decode(CarryBackup.self, from: encoder.encode(backup))
        let packet = try CarryGraphMigrationCodec.prepare(portable, accountID: owner, migrationID: UUID(), tripIDs: [source.id], includeLibrary: true)
        var entities = packet.entities
        for index in entities.indices where entities[index].kind == "trip" { entities[index].fields["name"] = .string("Account plan") }
        let server = ReadOnlyServer(entities), library = CarryWorkspaceLibrary(local: local)
        let controller = makeController(root: root, library: library, server: server)
        return Fixture(root: root, accountID: owner, local: local, library: library, controller: controller, server: server, tripID: source.id, itemID: item.id, saves: saves)
    }
    private func makeController(root: URL, library: CarryWorkspaceLibrary, server: ReadOnlyServer) -> CarryAccountWorkspaceController {
        CarryAccountWorkspaceController(library: library, rootDirectory: root.appendingPathComponent("accounts"), access: CarryAccountFileAccess(), factory: { _, _ in
            .init(transport: server, manifest: { _ in throw Failure.unusedAsset }, download: { _ in throw Failure.unusedAsset }, upload: { _, _ in throw Failure.forbiddenWrite }, close: {})
        })
    }
    private func open(_ fixture: Fixture) async throws {
        try await fixture.controller.enable(accountID: fixture.accountID)
        let workspace = try XCTUnwrap(fixture.controller.workspace)
        let complete = try await workspace.synchronize(); XCTAssertTrue(complete)
    }
    func testSecondDeviceCollisionReviewAdoptsWithoutAnyCloudMutationAndKeepsFullCopy() async throws {
        let fixture = try fixture(); try await open(fixture)
        XCTAssertEqual(Set(fixture.controller.localAccountCollisions.map(\.rootID)), [fixture.tripID, fixture.itemID])
        XCTAssertTrue(fixture.library.owningStore(for: fixture.tripID) === fixture.local)
        let review = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        try await fixture.controller.adoptLocalAccountCollision(review)
        let account = try XCTUnwrap(fixture.library.account)
        XCTAssertTrue(fixture.library.owningStore(for: fixture.tripID) === account)
        XCTAssertEqual(account.trips.first?.name, "Account plan")
        let copies = fixture.local.trips.filter { $0.id != fixture.tripID }
        XCTAssertEqual(copies.count, 1); XCTAssertEqual(copies.first?.name, "Local source")
        XCTAssertEqual(copies.first?.safeSections.first?.items?.first?.isPacked, true)
        XCTAssertEqual(copies.first?.safeSections.first?.items?.first?.quantity, 3)
        XCTAssertTrue(fixture.local.migrationWriteGuard.isProtected(fixture.tripID))
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
        XCTAssertFalse(fixture.library.visibleTrips.contains { $0.id == fixture.tripID })
    }
    func testLibraryAdoptionRetainsLocalCopyAndHidesTheImmutableSourceOnSignOut() async throws {
        let fixture = try fixture(); try await open(fixture)
        let review = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.itemID, kind: "libraryItem")
        try await fixture.controller.adoptLocalAccountCollision(review)
        XCTAssertEqual(fixture.local.myItems.count, 2)
        XCTAssertEqual(fixture.local.visibleMyItems.count, 1)
        XCTAssertNotEqual(fixture.local.visibleMyItems.first?.id, fixture.itemID)
        XCTAssertEqual(fixture.local.visibleMyItems.first?.defaultQuantity, 4)
        try await fixture.controller.close()
        XCTAssertEqual(fixture.local.visibleMyItems.count, 1)
        XCTAssertEqual(fixture.server.writes, 0)
    }
    func testColdStartAccountWithSameUUIDStillOffersReviewAndPersistedAdoptionReopensOffline() async throws {
        let fixture = try fixture(); try await open(fixture); try await fixture.controller.close()
        let library = CarryWorkspaceLibrary(local: fixture.local), controller = makeController(root: fixture.root, library: library, server: fixture.server)
        let opened = try await controller.openCached(accountID: fixture.accountID); XCTAssertTrue(opened)
        XCTAssertNotNil(controller.workspace)
        XCTAssertTrue(controller.localAccountCollisions.contains { $0.rootID == fixture.tripID })
        try await controller.enable(accountID: fixture.accountID)
        let review = try await controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        try await controller.adoptLocalAccountCollision(review); try await controller.close()
        let reopenedLibrary = CarryWorkspaceLibrary(local: fixture.local), reopened = makeController(root: fixture.root, library: reopenedLibrary, server: fixture.server)
        let didReopen = try await reopened.openCached(accountID: fixture.accountID); XCTAssertTrue(didReopen)
        XCTAssertTrue(reopenedLibrary.owningStore(for: fixture.tripID) === reopenedLibrary.account)
        XCTAssertFalse(reopened.localAccountCollisions.contains { $0.rootID == fixture.tripID })
        XCTAssertEqual(fixture.local.trips.count, 2)
        XCTAssertEqual(fixture.server.writes, 0)
        try await reopened.close()
    }
    func testChangedSourceAfterReviewDoesNotCreateCopyOrChangeOwnership() async throws {
        let fixture = try fixture(); try await open(fixture)
        let review = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        let source = try XCTUnwrap(fixture.local.trips.first); source.name = "Later local edit"; try fixture.local.businessContext.save()
        do { try await fixture.controller.adoptLocalAccountCollision(review); XCTFail("Stale review must fail") } catch { }
        XCTAssertEqual(fixture.local.trips.count, 1)
        XCTAssertTrue(fixture.library.owningStore(for: fixture.tripID) === fixture.local)
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }
    func testChangedAccountAfterReviewRejectsLocalAdoptionWithoutUploading() async throws {
        let fixture = try fixture(); try await open(fixture)
        let review = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        await fixture.controller.suspend()
        let old = try XCTUnwrap(fixture.server.changes.first { $0.entity.id == fixture.tripID })
        var fields = old.entity.fields; fields["name"] = .string("New account edit")
        let sequence = fixture.server.changes.count + 1
        fixture.server.changes.append(CarryGraphChange(sequence: sequence, entity: CarryGraphEntity(id: old.entity.id, kind: old.entity.kind,
            parentID: old.entity.parentID, version: 2, subtreeVersion: sequence, fields: fields, fieldVersions: fields.mapValues { _ in 2 })))
        try await fixture.controller.enable(accountID: fixture.accountID)
        let workspace = try XCTUnwrap(fixture.controller.workspace)
        let complete = try await workspace.synchronize(); XCTAssertTrue(complete)
        let account = try XCTUnwrap(fixture.library.account)
        XCTAssertEqual(account.trips.first?.name, "New account edit", "The changed account must be materialized before testing a stale review")
        let raw = ModelContext(account.businessContext.container), rootID = fixture.tripID
        XCTAssertEqual(try raw.fetch(FetchDescriptor<CarryReplicaCheckpoint>()).first?.cursor, sequence)
        let baseline = try XCTUnwrap(raw.fetch(FetchDescriptor<CarryNativeMaterialization>(predicate: #Predicate { $0.id == rootID })).first)
        let observed = try JSONDecoder().decode(CarryGraphEntity.self, from: XCTUnwrap(baseline.observedGraphData))
        XCTAssertEqual(observed.version, 2)
        XCTAssertEqual(observed.fields["name"], .string("New account edit"))
        do { try await fixture.controller.adoptLocalAccountCollision(review); XCTFail("Changed account evidence must be reviewed again") } catch { }
        XCTAssertEqual(fixture.local.trips.count, 1)
        XCTAssertEqual(fixture.library.account?.trips.first?.name, "New account edit")
        XCTAssertTrue(fixture.library.owningStore(for: fixture.tripID) === fixture.local)
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }
    func testPhotoWithoutVerifiedOriginalCannotBeAdopted() async throws {
        let fixture = try fixture(withIncompletePhoto: true); try await open(fixture)
        do { _ = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip"); XCTFail("A thumbnail or photo record is not an original") } catch { }
        XCTAssertEqual(fixture.local.trips.count, 1)
        XCTAssertTrue(fixture.library.owningStore(for: fixture.tripID) === fixture.local)
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }
    func testDirtyNativeAccountCannotBeUsedAsVerifiedAdoptionEvidence() async throws {
        let fixture = try fixture(); try await open(fixture)
        let account = try XCTUnwrap(fixture.library.account), trip = try XCTUnwrap(fixture.library.account?.trips.first)
        trip.name = "Unsaved native account edit"
        do { _ = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip"); XCTFail("Dirty native account cannot certify the server state") } catch { }
        account.businessContext.rollback()
        XCTAssertEqual(fixture.server.writes, 0)
        XCTAssertEqual(fixture.local.trips.count, 1)
        try await fixture.controller.close()
    }
    func testIncompleteNativeProjectionIsRejectedEvenWhenTheRootIsVisible() async throws {
        let fixture = try fixture(); try await open(fixture)
        let account = try XCTUnwrap(fixture.library.account), container = account.businessContext.container
        let isolated = ModelContext(container), sections = try isolated.fetch(FetchDescriptor<PackingSection>())
        for section in sections { isolated.delete(section) }; try isolated.save()
        do { _ = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip"); XCTFail("The root alone is not a complete account graph") } catch { }
        XCTAssertEqual(fixture.local.trips.count, 1)
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }

    func testRecoveryNamespaceDiffersAcrossDevicesButSurvivesTheSameCacheReopening() async throws {
        let fixture = try fixture(); try await open(fixture)
        let first = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        let account = try XCTUnwrap(fixture.library.account)
        let reopened = try CarryAccountLocalAdoption(accountID: fixture.accountID, context: ModelContext(account.businessContext.container))
        XCTAssertEqual(try reopened.review(source: first.source).id, first.id)
        let secondContainer = try CarryAccountReplica.container(at: fixture.root.appendingPathComponent("second-device.store"))
        let replica = try CarryAccountReplica(container: secondContainer, accountID: fixture.accountID)
        try replica.receive(CarryGraphPage(changes: fixture.server.changes, cursor: fixture.server.changes.count, hasMore: false))
        _ = try CarryNativeGraphProjector(accountID: fixture.accountID).project(snapshot: replica.projectionSnapshot(), in: ModelContext(secondContainer))
        let second = try CarryAccountLocalAdoption(accountID: fixture.accountID, context: ModelContext(secondContainer)).review(source: first.source)
        XCTAssertNotEqual(first.id, second.id)
        let fingerprint = try first.source.fingerprint()
        XCTAssertNotEqual(CarryMigrationSourceSnapshot.recoveryID(batchID: first.id, sourceFingerprint: fingerprint, entityID: fixture.tripID),
                          CarryMigrationSourceSnapshot.recoveryID(batchID: second.id, sourceFingerprint: fingerprint, entityID: fixture.tripID))
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }

    func testUnrelatedCorruptReplicaPayloadDoesNotBlockSelectedAdoptionReview() async throws {
        let fixture = try fixture(); try await open(fixture)
        await fixture.controller.suspend()
        let account = try XCTUnwrap(fixture.library.account), context = ModelContext(account.businessContext.container)
        let unrelated = CarryReplicaRecord(id: UUID(), payload: Data("broken unrelated payload".utf8), hasPendingChanges: false)
        unrelated.needsProjection = false; context.insert(unrelated); try context.save()
        let source = try CarryMigrationSourceSnapshot.capture(trip: XCTUnwrap(fixture.local.trips.first))
        let engine = try CarryAccountLocalAdoption(accountID: fixture.accountID, context: ModelContext(context.container))
        let review = try engine.review(source: source)
        XCTAssertEqual(review.source.rootID, fixture.tripID)
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }

    private func verifiedPhotoFixture() async throws -> (Fixture, CarryLocalAdoptionReview, CarryAccountAssetCache, URL) {
        let fixture = try fixture(withIncompletePhoto: true); try await open(fixture); await fixture.controller.suspend()
        let account = try XCTUnwrap(fixture.library.account), container = account.businessContext.container
        let photo = try XCTUnwrap(fixture.server.changes.first { $0.entity.kind == "photo" })
        let cacheRoot = fixture.root.appendingPathComponent("accounts").appendingPathComponent(fixture.accountID.uuidString.lowercased()).appendingPathComponent("assets")
        let cache = try CarryAccountAssetCache(root: cacheRoot, accountID: fixture.accountID)
        let snapshot = try await cache.snapshot(data: Data("Synthetic full original bytes".utf8), entityID: photo.entity.id, slot: "original")
        var fields = photo.entity.fields; fields["originalAssetID"] = .string(snapshot.token.assetID.uuidString.lowercased())
        let sequence = fixture.server.changes.count + 1
        let updated = CarryGraphChange(sequence: sequence, entity: CarryGraphEntity(id: photo.entity.id, kind: "photo", parentID: photo.entity.parentID,
            version: 2, subtreeVersion: sequence, fields: fields, fieldVersions: fields.mapValues { _ in 2 }))
        let replica = try CarryAccountReplica(container: container, accountID: fixture.accountID)
        try replica.receive(CarryGraphPage(changes: [updated], cursor: sequence, hasMore: false))
        let native = ModelContext(container)
        let projector = CarryNativeGraphProjector(accountID: fixture.accountID, resolveAssets: { entity, _ in
            if entity.id == photo.entity.id { return .init(originalFileName: snapshot.token.rawValue, readyAssetIDs: [snapshot.token.assetID]) }
            return .init()
        })
        _ = try projector.project(snapshot: replica.projectionSnapshot(), in: native, save: { context in
            let queue = CarryAccountAssetQueue(accountID: fixture.accountID)
            _ = try queue.bind(snapshot, entityID: photo.entity.id, entityKind: "photo", slot: "original", contentType: "image/jpeg", sourceReference: snapshot.token.rawValue, in: context)
            try queue.markVerified(snapshot.token.assetID, in: context); try context.save()
        })
        account.refresh()
        let source = try CarryMigrationSourceSnapshot.capture(trip: XCTUnwrap(fixture.local.trips.first))
        let engine = try CarryAccountLocalAdoption(accountID: fixture.accountID, context: ModelContext(container)), review = try engine.review(source: source)
        _ = try await engine.verify(review, cache: cache)
        return (fixture, review, cache, try await cache.verify(snapshot))
    }
    func testMissingVerifiedOriginalBytesRejectsAdoptionEvidence() async throws {
        let (fixture, review, cache, url) = try await verifiedPhotoFixture()
        try FileManager.default.removeItem(at: url)
        let account = try XCTUnwrap(fixture.library.account)
        let engine = try CarryAccountLocalAdoption(accountID: fixture.accountID, context: ModelContext(account.businessContext.container))
        do { _ = try await engine.verify(review, cache: cache); XCTFail("A verified metadata row does not replace actual original bytes") } catch { }
        XCTAssertEqual(fixture.server.writes, 0)
        XCTAssertEqual(fixture.local.trips.count, 1)
        try await fixture.controller.close()
    }
    func testWrongOriginalBindingCannotCertifyAnAccountPhoto() async throws {
        let (fixture, review, _, _) = try await verifiedPhotoFixture()
        let account = try XCTUnwrap(fixture.library.account), context = ModelContext(account.businessContext.container)
        let binding = try XCTUnwrap(context.fetch(FetchDescriptor<CarryAccountAssetBinding>()).first)
        binding.entityID = UUID(); try context.save()
        let engine = try CarryAccountLocalAdoption(accountID: fixture.accountID, context: ModelContext(context.container))
        XCTAssertThrowsError(try engine.review(source: review.source))
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }
    func testPrivateArchiveTamperingIsRejectedBeforeSourceAdoption() async throws {
        let fixture = try fixture(); try await open(fixture)
        let review = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        let source = try XCTUnwrap(fixture.local.trips.first)
        let backup = DataBackupManager.shared.migrationSnapshot(trips: [source], myItems: [])
        let directory = fixture.root.appendingPathComponent("CarryMigrationPreparation-" + UUID().uuidString)
        let prepared = try await CarryMigrationBackupPreparation.prepare(backup, attachments: [:], backgrounds: [:], originalPhotos: [:], directory: directory)
        let root = fixture.root.appendingPathComponent("private-archive")
        let archive = try await CarryLocalAdoptionArchive.create(prepared, root: root, review: review)
        _ = try await archive.verify(in: root, review: review)
        let path = root.appendingPathComponent(archive.relativeDirectory).appendingPathComponent("source.json")
        try Data("Corrupt backup".utf8).write(to: path, options: .atomic)
        do { _ = try await archive.verify(in: root, review: review); XCTFail("A corrupt private backup cannot permit adoption") } catch { }
        XCTAssertEqual(fixture.local.trips.count, 1)
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }

    func testFailedLocalCopyCanCancelStagedAdoptionAndResumeLocalEditing() async throws {
        let fixture = try fixture(); try await open(fixture)
        let review = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        fixture.saves.fail = true
        do { try await fixture.controller.adoptLocalAccountCollision(review); XCTFail("Injected local save must fail") } catch { }
        XCTAssertTrue(fixture.controller.isLocalAdoptionStaged(rootID: fixture.tripID))
        XCTAssertTrue(fixture.local.migrationWriteGuard.isProtected(fixture.tripID))
        XCTAssertEqual(fixture.local.trips.count, 1)
        fixture.saves.fail = false
        try fixture.controller.cancelLocalAdoption(rootID: fixture.tripID)
        XCTAssertFalse(fixture.controller.isLocalAdoptionStaged(rootID: fixture.tripID))
        XCTAssertFalse(fixture.local.migrationWriteGuard.isProtected(fixture.tripID))
        let source = try XCTUnwrap(fixture.local.trips.first); source.name = "Local editing restored"
        XCTAssertNoThrow(try fixture.local.migrationWriteGuard.validate(fixture.local.businessContext))
        fixture.local.businessContext.rollback()
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }

    func testFailedLocalCopyCanRetryTheSameAdoptionWithoutDuplicateRecoveryRoots() async throws {
        let fixture = try fixture(); try await open(fixture)
        let review = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        fixture.saves.fail = true
        do { try await fixture.controller.adoptLocalAccountCollision(review); XCTFail("Injected save must fail") } catch { }
        fixture.saves.fail = false
        try await fixture.controller.adoptLocalAccountCollision(review)
        XCTAssertEqual(fixture.local.trips.count, 2)
        XCTAssertTrue(fixture.library.owningStore(for: fixture.tripID) === fixture.library.account)
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }
    func testArchiveRetryIgnoresBackupTimestampButKeepsTheFirstVerifiedBackup() async throws {
        let fixture = try fixture(); try await open(fixture)
        let review = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        var backup = DataBackupManager.shared.migrationSnapshot(trips: [try XCTUnwrap(fixture.local.trips.first)], myItems: [])
        backup.createdAt = Date(timeIntervalSince1970: 1000)
        let firstDirectory = fixture.root.appendingPathComponent("CarryMigrationPreparation-first")
        let first = try await CarryMigrationBackupPreparation.prepare(backup, attachments: [:], backgrounds: [:], originalPhotos: [:], directory: firstDirectory)
        let root = fixture.root.appendingPathComponent("retry-archive")
        let original = try await CarryLocalAdoptionArchive.create(first, root: root, review: review)
        backup.createdAt = Date(timeIntervalSince1970: 2000); backup.defaultReminderOffsets = [99]
        let secondDirectory = fixture.root.appendingPathComponent("CarryMigrationPreparation-second")
        let second = try await CarryMigrationBackupPreparation.prepare(backup, attachments: [:], backgrounds: [:], originalPhotos: [:], directory: secondDirectory)
        let retried = try await CarryLocalAdoptionArchive.create(second, root: root, review: review)
        XCTAssertEqual(original, retried)
        _ = try await retried.verify(in: root, review: review)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(CarryBackup.self, from: Data(contentsOf: root.appendingPathComponent(original.relativeDirectory).appendingPathComponent("source.json")))
        XCTAssertEqual(saved.createdAt, Date(timeIntervalSince1970: 1000))
        try await fixture.controller.close()
    }
    func testDuplicateSelectedLocalUUIDThrowsInsteadOfTrappingDuringForkOrCollisionReview() async throws {
        let fixture = try fixture(); try await open(fixture)
        let source = try XCTUnwrap(fixture.local.trips.first), snapshot = try CarryMigrationSourceSnapshot.capture(trip: source)
        let account = try XCTUnwrap(fixture.library.account), raw = ModelContext(account.businessContext.container), batch = UUID()
        try CarryAccountMigrationOwnership(accountID: fixture.accountID, context: raw).stage(batchID: batch, snapshots: [snapshot]); try raw.save()
        let duplicate = TripBundle(id: fixture.tripID, name: "Duplicate CK record", isDateless: true)
        fixture.local.businessContext.insert(duplicate); try fixture.local.businessContext.save(); fixture.local.refresh()
        XCTAssertThrowsError(try fixture.controller.migrationForkReview(batchID: batch))
        do { _ = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip"); XCTFail("Ambiguous local identity must fail safely") } catch { }
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }
    func testUnrelatedDuplicateLocalUUIDDoesNotBlockSelectedSourceReview() async throws {
        let fixture = try fixture(); try await open(fixture)
        let source = try XCTUnwrap(fixture.local.trips.first), snapshot = try CarryMigrationSourceSnapshot.capture(trip: source)
        let account = try XCTUnwrap(fixture.library.account), raw = ModelContext(account.businessContext.container), batch = UUID()
        try CarryAccountMigrationOwnership(accountID: fixture.accountID, context: raw).stage(batchID: batch, snapshots: [snapshot]); try raw.save()
        let unrelatedID = UUID()
        for index in 0..<2 {
            let unrelated = TripBundle(id: unrelatedID, name: "Unrelated duplicate \(index)", isDateless: true)
            unrelated.backgroundsData = Data("Unrelated malformed background JSON".utf8)
            fixture.local.businessContext.insert(unrelated)
        }
        try fixture.local.businessContext.save(); fixture.local.refresh()
        let reviewed = try fixture.controller.migrationForkReview(batchID: batch)
        XCTAssertEqual(reviewed.sources, [snapshot])
        let collision = try await fixture.controller.reviewLocalAccountCollision(rootID: fixture.tripID, kind: "trip")
        XCTAssertEqual(collision.source, snapshot)
        XCTAssertEqual(fixture.server.writes, 0)
        try await fixture.controller.close()
    }

}
