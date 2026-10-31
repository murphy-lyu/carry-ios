import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AccountWorkspaceControllerTests: XCTestCase {
    private final class Transport: CarryGraphTransporting {
        var applications: [CarryGraphCommand] = []
        var pulls = 0
        var keepsHistory = false
        var history: [CarryGraphChange] = []
        var onPull: () -> Void = {}
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
            applications.append(command)
            let offset = keepsHistory ? history.count : 0
            let changes = command.mutations.enumerated().map { index, mutation in
                CarryGraphChange(sequence: offset + index + 1, entity: CarryGraphEntity(id: mutation.id, kind: mutation.kind,
                    parentID: mutation.parentID, version: 1, subtreeVersion: index + 1,
                    fields: mutation.fields ?? [:], fieldVersions: (mutation.fields ?? [:]).mapValues { _ in 1 }))
            }
            if keepsHistory { history += changes }
            return CarryGraphReceipt(status: "saved_to_account", requestID: command.requestID, changes: changes, cursor: keepsHistory ? history.count : changes.count)
        }
        func pull(cursor: Int) async throws -> CarryGraphPage {
            pulls += 1
            onPull()
            return CarryGraphPage(changes: keepsHistory ? history.filter { $0.sequence > cursor } : [], cursor: keepsHistory ? history.count : cursor, hasMore: false)
        }
    }
    private func fixture() throws -> (URL, TripStore, CarryWorkspaceLibrary) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryController-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try CarryAccountReplica.container(at: directory.appendingPathComponent("local.store"))
        let local = TripStore(context: ModelContext(database), scope: .account(didChange: {}))
        local.addTrip(TripBundle(name: "Synthetic guest", destinationCity: "", days: 1, dateRange: "", isDateless: true))
        return (directory, local, CarryWorkspaceLibrary(local: local))
    }
    private func dependencies(_ transport: Transport, close: @escaping () -> Void = {}) -> CarryAccountWorkspaceController.Dependencies {
        CarryAccountWorkspaceController.Dependencies(transport: transport,
            manifest: { _ in throw CarryAccountWorkspaceControllerFailure.unavailable },
            download: { _ in throw CarryAccountWorkspaceControllerFailure.unavailable },
            upload: { _, _ in throw CarryAccountWorkspaceControllerFailure.unavailable }, close: { close() })
    }

    func testEnableCreatesSeparateEmptyAccountWithoutUploadingGuestTrips() async throws {
        let (directory, local, library) = try fixture(), transport = Transport(), owner = UUID(), access = CarryAccountFileAccess()
        var factories = 0, closed = 0, navigationClears = 0
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: access, factory: { id, _ in
                XCTAssertEqual(id, owner); factories += 1
                return self.dependencies(transport, close: { closed += 1 })
            }, clearAccountNavigation: { navigationClears += 1; XCTAssertNotNil(library.account) })
        XCTAssertNil(controller.workspace); XCTAssertEqual(factories, 0)
        try await controller.enable(accountID: owner)
        XCTAssertEqual(controller.accountID, owner)
        XCTAssertNotNil(library.account); XCTAssertTrue(library.account?.trips.isEmpty == true)
        XCTAssertEqual(library.visibleTrips.map(\.id), local.trips.map(\.id))
        XCTAssertTrue(transport.applications.isEmpty)
        XCTAssertNotNil(library.account?.assetImporter)
        try await controller.enable(accountID: owner)
        XCTAssertEqual(factories, 1, "Repeated enable must reuse identity-bound runtime")
        try await controller.close()
        XCTAssertNil(controller.workspace); XCTAssertNil(library.account)
        XCTAssertEqual(local.trips.count, 1); XCTAssertEqual(closed, 1); XCTAssertEqual(navigationClears, 1)
        let freshLease = try access.begin(accountID: UUID()); access.revoke(freshLease)
    }

    func testSwitchPreservesUnsyncedAccountJournalAndGuestData() async throws {
        let (directory, local, library) = try fixture(), firstOwner = UUID(), secondOwner = UUID(), access = CarryAccountFileAccess()
        var transports: [UUID: Transport] = [:], closures: [UUID] = []
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: access, factory: { id, _ in
                let transport = Transport(); transports[id] = transport
                return self.dependencies(transport, close: { closures.append(id) })
            })
        try await controller.enable(accountID: firstOwner)
        let first = try XCTUnwrap(library.account), pending = TripBundle(name: "Synthetic pending", destinationCity: "", days: 1, dateRange: "", isDateless: true)
        first.addTrip(pending)
        try await controller.enable(accountID: secondOwner)
        XCTAssertEqual(controller.accountID, secondOwner)
        XCTAssertTrue(library.account?.trips.isEmpty == true)
        XCTAssertEqual(local.trips.count, 1)
        XCTAssertEqual(closures, [firstOwner])
        try await controller.enable(accountID: firstOwner)
        XCTAssertEqual(library.account?.trips.first?.id, pending.id)
        XCTAssertEqual(local.trips.count, 1)
        try await controller.close()
    }

    func testFactoryFailureDoesNotAttachOrRemoveGuestData() async throws {
        let (directory, local, library) = try fixture()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in throw CarryAccountWorkspaceControllerFailure.unavailable })
        do { try await controller.enable(accountID: UUID()); XCTFail("Expected setup failure") }
        catch CarryAccountWorkspaceControllerFailure.unavailable { }
        XCTAssertNil(library.account); XCTAssertNil(controller.accountID)
        XCTAssertEqual(local.trips.count, 1)
    }

    func testCloseAwaitsAndCancelsInFlightEnableBeforeAttachingAccount() async throws {
        let (directory, local, library) = try fixture(), transport = Transport(), access = CarryAccountFileAccess()
        var factoryContinuation: CheckedContinuation<Void, Never>?
        var entered = false, closed = 0
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: access, factory: { _, _ in
                await withCheckedContinuation { factoryContinuation = $0; entered = true }
                return self.dependencies(transport, close: { closed += 1 })
            })
        let enabling = Task { try await controller.enable(accountID: UUID()) }
        while !entered { await Task.yield() }
        let closing = Task { try await controller.close() }
        await Task.yield()
        XCTAssertNil(library.account)
        factoryContinuation?.resume()
        try await closing.value
        do { try await enabling.value; XCTFail("Cancelled enable must not attach") }
        catch is CancellationError { }
        XCTAssertNil(controller.workspace); XCTAssertNil(library.account)
        XCTAssertEqual(closed, 1); XCTAssertEqual(local.trips.count, 1)
        let lease = try access.begin(accountID: UUID()); access.revoke(lease)
    }

    func testSuspendKeepsOfflineGraphAndSameOwnerEnableResumes() async throws {
        let (directory, _, library) = try fixture(), transport = Transport(), owner = UUID()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in self.dependencies(transport) })
        try await controller.enable(accountID: owner)
        await controller.suspend()
        let store = try XCTUnwrap(library.account)
        XCTAssertEqual(controller.workspace?.state, .paused)
        store.addTrip(TripBundle(name: "Synthetic offline edit", destinationCity: "", days: 1, dateRange: "", isDateless: true))
        XCTAssertTrue(transport.applications.isEmpty)
        try await controller.enable(accountID: owner)
        XCTAssertTrue(library.account === store)
        for _ in 0..<1000 where transport.applications.isEmpty { await Task.yield() }
        XCTAssertEqual(transport.applications.count, 1)
        try await controller.close()
    }

    func testNewEditDuringFinalPullIsCoalescedIntoSameSynchronizationTask() async throws {
        let (directory, _, library) = try fixture(), transport = Transport()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in self.dependencies(transport) })
        transport.onPull = {
            transport.onPull = {}
            library.account?.addTrip(TripBundle(name: "Synthetic during pull", destinationCity: "", days: 1, dateRange: "", isDateless: true))
        }
        try await controller.enable(accountID: UUID())
        for _ in 0..<1000 where transport.applications.isEmpty { await Task.yield() }
        XCTAssertEqual(transport.applications.count, 1)
        XCTAssertEqual(transport.applications.first?.mutations.first?.fields?["name"], .string("Synthetic during pull"))
        try await controller.close()
    }

    func testReopenWarmsJournalOnlyOriginalBeforeItsFirstAssetJobExists() async throws {
        let (directory, _, library) = try fixture(), owner = UUID(), root = directory.appendingPathComponent("accounts")
        let access = CarryAccountFileAccess(), transport = Transport()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: root, access: access,
            factory: { _, _ in self.dependencies(transport) })
        try await controller.enable(accountID: owner)
        await controller.suspend()
        let store = try XCTUnwrap(library.account), importer = try XCTUnwrap(store.assetImporter)
        let photoID = UUID()
        let lease = try await importer.originalPhoto(data: Data("Synthetic original".utf8), entityID: photoID)
        let token = lease.fileURL.lastPathComponent
        let photo = StopPhoto(assetLocalIdentifier: token)
        photo.id = photoID
        let stop = ItineraryStop(name: "Synthetic stop"), day = ItineraryDay(), trip = TripBundle(name: "Synthetic journal only", destinationCity: "", days: 1, dateRange: "", isDateless: true)
        stop.photos = [photo]; photo.stop = stop; day.stops = [stop]; stop.day = day; trip.itineraryDays = [day]; day.bundle = trip
        store.addTrip(trip)
        XCTAssertTrue(try store.businessContext.fetch(FetchDescriptor<CarryAccountAssetJob>()).isEmpty)
        try await lease.discard()
        try await controller.close()
        XCTAssertNil(access.url(named: token))
        try await controller.enable(accountID: owner)
        XCTAssertNotNil(access.url(named: token), "Persisted native journal must reopen its verified original before outbox consumption")
        XCTAssertEqual(library.account?.trips.first?.id, trip.id)
        try await controller.close()
    }

    func testOfflineColdOpenRetainsUnsentEditsWithoutAnyHTTP() async throws {
        let (directory, _, library) = try fixture(), owner = UUID(), transport = Transport()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in self.dependencies(transport) })
        try await controller.enable(accountID: owner)
        await controller.suspend()
        let pending = TripBundle(name: "Synthetic offline persisted", destinationCity: "", days: 1, dateRange: "", isDateless: true)
        library.account?.addTrip(pending)
        try await controller.close()
        let calls = transport.pulls
        let reopened = try await controller.openCached(accountID: owner)
        XCTAssertTrue(reopened)
        XCTAssertEqual(controller.workspace?.state, .paused)
        XCTAssertEqual(library.account?.trips.first?.id, pending.id)
        await Task.yield()
        XCTAssertEqual(transport.pulls, calls); XCTAssertTrue(transport.applications.isEmpty)
        XCTAssertNotNil(try controller.workspace?.bridge.nextBatch())
        try await controller.close()
        let nonexistent = try await controller.openCached(accountID: UUID())
        XCTAssertFalse(nonexistent); XCTAssertNil(library.account)
    }
    func testInvalidMigrationSelectionRestoresOrdinarySynchronization() async throws {
        let (directory, _, library) = try fixture(), transport = Transport(), owner = UUID()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in self.dependencies(transport) })
        try await controller.enable(accountID: owner)
        do { try await controller.migrate(tripIDs: [UUID()], includeLibrary: false); XCTFail("Invalid selection must fail") }
        catch { }
        XCTAssertFalse(controller.migrationBusy)
        let workspace = try XCTUnwrap(controller.workspace)
        let synchronized = try await workspace.synchronize()
        XCTAssertTrue(synchronized, "Validation failure must not leave synchronization paused")
        try await controller.close()
    }
    func testMissingMigrationResumeRestoresOrdinarySynchronization() async throws {
        let (directory, _, library) = try fixture(), transport = Transport(), owner = UUID()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in self.dependencies(transport) })
        try await controller.enable(accountID: owner)
        do { try await controller.resumeMigration(batchID: UUID()); XCTFail("Missing batch must fail") }
        catch { }
        XCTAssertFalse(controller.migrationBusy)
        let workspace = try XCTUnwrap(controller.workspace)
        let synchronized = try await workspace.synchronize()
        XCTAssertTrue(synchronized, "Even failure after pause must resume ordinary synchronization")
        try await controller.close()
    }
    func testDirtyMigrationSourceIsNotUploadedOrLeftSuspended() async throws {
        let (directory, local, library) = try fixture(), transport = Transport(), owner = UUID()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in self.dependencies(transport) })
        try await controller.enable(accountID: owner)
        let trip = try XCTUnwrap(local.trips.first); trip.name = "Unsaved edit"
        do { try await controller.migrate(tripIDs: [trip.id], includeLibrary: false); XCTFail("Dirty source must not migrate") }
        catch { }
        XCTAssertTrue(transport.applications.isEmpty)
        XCTAssertEqual(trip.name, "Unsaved edit")
        local.businessContext.rollback()
        let workspace = try XCTUnwrap(controller.workspace)
        let synchronized = try await workspace.synchronize()
        XCTAssertTrue(synchronized)
        try await controller.close()
    }

    func testExplicitMigrationMaterializesNativeGraphBeforeRoutingAndCompletion() async throws {
        let (directory, local, library) = try fixture(), transport = Transport(), owner = UUID()
        transport.keepsHistory = true
        let source = try XCTUnwrap(local.trips.first), originalID = source.id
        let original = try CarryMigrationSourceSnapshot.capture(trip: source)
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in self.dependencies(transport) })
        try await controller.enable(accountID: owner)
        XCTAssertTrue(transport.applications.isEmpty)
        try await controller.migrate(tripIDs: [originalID], includeLibrary: false)
        XCTAssertTrue(controller.migrationFinished)
        let account = try XCTUnwrap(library.account)
        XCTAssertEqual(account.trips.map(\.id), [originalID])
        XCTAssertTrue(library.owningStore(for: originalID) === account)
        XCTAssertEqual(library.visibleTrips.map(\.id), [originalID])
        XCTAssertEqual(try CarryMigrationSourceSnapshot.capture(trip: source), original)
        XCTAssertTrue(local.migrationWriteGuard.isProtected(originalID))
        let batch = try XCTUnwrap(controller.migrationBatches().first)
        XCTAssertTrue(controller.isMigrationMaterialized(batchID: batch.id))
        do { try await controller.migrate(tripIDs: [originalID], includeLibrary: false); XCTFail("An owned source must not be migrated again") }
        catch { }
        XCTAssertEqual(try controller.migrationBatches().count, 1)
        try await controller.close()
        XCTAssertEqual(local.trips.map(\.id), [originalID])
        XCTAssertTrue(library.visibleTrips.isEmpty)
    }

    func testControllerClosePermanentlyRevokesARetainedBusinessWriterButSuspendDoesNot() async throws {
        let (directory, _, library) = try fixture(), owner = UUID(), transport = Transport()
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: directory.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in self.dependencies(transport) })
        try await controller.enable(accountID: owner)
        await controller.suspend()
        let retainedStore = try XCTUnwrap(library.account), retainedWorkspace = try XCTUnwrap(controller.workspace)
        let writer = retainedWorkspace.businessSave
        retainedStore.addTrip(TripBundle(name: "Offline before close", destinationCity: "", days: 1, sections: []))
        XCTAssertEqual(retainedStore.trips.count, 1)
        try await controller.close()
        let context = retainedStore.businessContext
        context.insert(TripBundle(name: "Must not survive close", destinationCity: "", days: 1, sections: []))
        XCTAssertThrowsError(try CarryPersistence.commit(context, using: writer))
        XCTAssertEqual(try ModelContext(context.container).fetch(FetchDescriptor<TripBundle>()).map(\.name), ["Offline before close"])
        XCTAssertTrue(transport.applications.isEmpty)
    }

}
