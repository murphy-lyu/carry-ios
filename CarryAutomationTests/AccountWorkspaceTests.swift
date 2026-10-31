import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AccountWorkspaceTests: XCTestCase {
    private final class Transport: CarryGraphTransporting {
        var applications: [CarryGraphCommand] = []
        var pulls = 0
        var received: [CarryGraphChange] = []
        var holdPull = false
        var onPull: () -> Void = {}
        var pendingPull: CheckedContinuation<CarryGraphPage, Never>?
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
            applications.append(command)
            let changes = command.mutations.map { mutation in
                CarryGraphChange(sequence: 1, entity: CarryGraphEntity(id: mutation.id, kind: mutation.kind,
                    parentID: mutation.parentID, version: 1, subtreeVersion: 1, fields: mutation.fields ?? [:],
                    fieldVersions: (mutation.fields ?? [:]).mapValues { _ in 1 }))
            }
            return CarryGraphReceipt(status: "saved_to_account", requestID: command.requestID, changes: changes, cursor: changes.count)
        }
        func pull(cursor: Int) async throws -> CarryGraphPage {
            pulls += 1
            if holdPull {
                return await withCheckedContinuation { continuation in pendingPull = continuation; onPull() }
            }
            let changes = received.filter { $0.sequence > cursor }
            return CarryGraphPage(changes: changes, cursor: changes.last?.sequence ?? cursor, hasMore: false)
        }
    }
    private func container() throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryWorkspace-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try CarryAccountReplica.container(at: directory.appendingPathComponent("cache.store"))
    }
    private func entity(name: String = "Synthetic account") throws -> CarryGraphEntity {
        let trip = TripBundle(name: name, destinationCity: "", days: 1, dateRange: "", isDateless: true)
        let source = try XCTUnwrap(CarryNativeSourceCodec.capture(trip))
        return CarryGraphEntity(id: trip.id, kind: "trip", parentID: nil, version: 1, subtreeVersion: 1,
            fields: source.metadata.fields, fieldVersions: source.metadata.fields.mapValues { _ in 1 })
    }

    func testCreationDoesNotReadOrUploadGuestDataAndRequiresExplicitEnablement() async throws {
        let database = try container(), business = ModelContext(database), transport = Transport()
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport, businessContext: { business })
        XCTAssertEqual(workspace.state, .paused)
        XCTAssertTrue(try workspace.replica.localEntities().isEmpty)
        do { _ = try await workspace.synchronize(); XCTFail("Sync requires explicit enablement") }
        catch CarryAccountWorkspaceFailure.synchronizationDisabled { }
        XCTAssertEqual(transport.pulls, 0); XCTAssertTrue(transport.applications.isEmpty)
    }

    func testWriterPersistsBusinessAndJournalTogetherWithoutNetwork() throws {
        let database = try container(), business = ModelContext(database), transport = Transport()
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport, businessContext: { business })
        business.insert(TripBundle(name: "Synthetic offline", destinationCity: "", days: 1, dateRange: "", isDateless: true))
        try CarryPersistence.commit(business, using: workspace.businessSave)
        let fresh = ModelContext(database)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<TripBundle>()).count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CarryNativeTransaction>()).count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CarryNativeChange>()).count, 1)
        XCTAssertTrue(transport.applications.isEmpty)
        XCTAssertEqual(transport.pulls, 0)
    }

    func testAccountTripStoreUsesActualJournalSyncAndProjectionChain() async throws {
        let database = try container(), initialContext = ModelContext(database), transport = Transport()
        var store: TripStore?
        var hooks = CarryAccountWorkspace.Hooks()
        hooks.didProject = { _ in store?.refresh() }
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport,
            businessContext: { store?.businessContext ?? initialContext }, hooks: hooks)
        store = TripStore(context: initialContext, persistenceSave: workspace.businessSave, scope: .account(didChange: {}))
        let child = try XCTUnwrap(store), trip = TripBundle(name: "Synthetic connected chain", destinationCity: "", days: 1, dateRange: "", isDateless: true)
        child.addTrip(trip)
        XCTAssertNotNil(try workspace.bridge.nextBatch())
        XCTAssertTrue(transport.applications.isEmpty)
        workspace.enableSynchronization()
        let complete = try await workspace.synchronize()
        XCTAssertTrue(complete); XCTAssertEqual(workspace.state, .synchronized)
        XCTAssertNil(try workspace.bridge.nextBatch())
        XCTAssertEqual(transport.applications.count, 1)
        XCTAssertEqual(transport.applications.first?.mutations.first?.id, trip.id)
        XCTAssertEqual(child.trips.first?.name, "Synthetic connected chain")
        XCTAssertTrue(child.trips.first === trip, "A sync ACK must preserve live business object identity")
        XCTAssertTrue(try workspace.replica.projectionCandidates().isEmpty)
        XCTAssertNil(try workspace.replica.nextCommand())
    }

    func testWriterRejectsAnotherAccountContainerBeforeSaving() throws {
        let database = try container(), business = ModelContext(database), transport = Transport()
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport, businessContext: { business })
        let other = try container(), wrong = ModelContext(other)
        wrong.insert(TripBundle(name: "Never saved", destinationCity: "", days: 1, dateRange: "", isDateless: true))
        XCTAssertThrowsError(try workspace.businessSave(wrong))
        XCTAssertTrue(try ModelContext(other).fetch(FetchDescriptor<TripBundle>()).isEmpty)
    }

    func testCompletePullProjectsThenAcknowledgesDirtySet() async throws {
        let database = try container(), business = ModelContext(database), transport = Transport(), remote = try entity()
        transport.received = [CarryGraphChange(sequence: 1, entity: remote)]
        var projections = 0
        var hooks = CarryAccountWorkspace.Hooks()
        hooks.didProject = { result in projections += 1; XCTAssertEqual(result.changedTripIDs, [remote.id]) }
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport,
            businessContext: { business }, hooks: hooks)
        workspace.enableSynchronization()
        let complete = try await workspace.synchronize()
        XCTAssertTrue(complete); XCTAssertEqual(workspace.state, .synchronized)
        XCTAssertEqual(try business.fetch(FetchDescriptor<TripBundle>()).first?.id, remote.id)
        XCTAssertTrue(try workspace.replica.projectionCandidates().isEmpty)
        XCTAssertEqual(projections, 1)
    }

    func testCurrentContextProviderSupportsPersistenceRecoveryReplacement() async throws {
        let database = try container(), transport = Transport(), remote = try entity()
        var current = ModelContext(database)
        let stale = current
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport, businessContext: { current })
        current = ModelContext(database)
        transport.received = [CarryGraphChange(sequence: 1, entity: remote)]
        workspace.enableSynchronization()
        let complete = try await workspace.synchronize()
        XCTAssertTrue(complete); XCTAssertFalse(current === stale)
        XCTAssertEqual(try current.fetch(FetchDescriptor<TripBundle>()).first?.id, remote.id)
    }

    func testCancellationIgnoringTransportCannotAcceptDataAfterPause() async throws {
        let database = try container(), business = ModelContext(database), transport = Transport(), remote = try entity()
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport, businessContext: { business })
        workspace.enableSynchronization(); transport.holdPull = true
        var syncing: Task<Bool, Error>?
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            transport.onPull = { entered.resume() }
            syncing = Task { try await workspace.synchronize() }
        }
        let pausing = Task { await workspace.pauseAndWait() }
        for _ in 0..<100 where workspace.state != .paused { await Task.yield() }
        XCTAssertEqual(workspace.state, .paused)
        transport.pendingPull?.resume(returning: CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: remote)], cursor: 1, hasMore: false))
        await pausing.value
        do { _ = try await XCTUnwrap(syncing).value; XCTFail("Cancelled lease must reject a late response") }
        catch is CancellationError { }
        XCTAssertEqual(try workspace.replica.cursor, 0)
        XCTAssertTrue(try workspace.replica.localEntities().isEmpty)
        XCTAssertTrue(try business.fetch(FetchDescriptor<TripBundle>()).isEmpty)
        XCTAssertEqual(workspace.state, .paused)
    }

    func testUnconfiguredAssetPublicationNeverCallsNetwork() async throws {
        let database = try container(), business = ModelContext(database), transport = Transport()
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport, businessContext: { business })
        var remote = try entity()
        remote.version = 0; remote.subtreeVersion = 0; remote.fieldVersions = [:]
        remote.fields["thumbnailAssetID"] = .string(UUID().uuidString)
        try workspace.replica.edit(remote)
        workspace.enableSynchronization()
        do { _ = try await workspace.synchronize(); XCTFail("Unverified assets cannot be published") }
        catch CarryAccountWorkspaceFailure.assetsUnavailable { }
        XCTAssertTrue(transport.applications.isEmpty)
        XCTAssertNotNil(try workspace.replica.nextCommand())
        XCTAssertEqual(workspace.state, .failed)
    }

    func testAccountChildStoreDoesNotCollectGlobalFilesOrEnableLegacyAutomation() async throws {
        let database = try container(), context = ModelContext(database), journal = CarryNativeChangeJournal(accountID: UUID())
        let sentinel = try AttachmentStore.writeImportedFile(Data("Synthetic global file".utf8), ext: "txt")
        defer { do { try FileManager.default.removeItem(at: sentinel) } catch { XCTFail("Synthetic cleanup failed: \(error)") } }
        var changes = 0
        let store = TripStore(context: context, persistenceSave: journal.captureAndSave,
            scope: .account(didChange: { changes += 1 }))
        store.refresh()
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(store.automationReady)
        XCTAssertEqual(store.automationInvalidationVersion, 0)
        XCTAssertTrue(store.businessContext === context)
        store.addTrip(TripBundle(name: "Synthetic child", destinationCity: "", days: 1, dateRange: "", isDateless: true))
        XCTAssertEqual(store.trips.count, 1)
        XCTAssertGreaterThan(changes, 0)
        try store.eraseAllData()
        XCTAssertTrue(store.trips.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(store.automationInvalidationVersion, 0)
        XCTAssertThrowsError(try store.resetAllData())
        XCTAssertThrowsError(try store.restoreFromBackup())
    }

    func testAccountTripDeletionRetainsAssetBytesUntilDurableQueueCollection() throws {
        let database = try container(), context = ModelContext(database), journal = CarryNativeChangeJournal(accountID: UUID())
        let sentinel = try AttachmentStore.writeImportedFile(Data("Synthetic retained original".utf8), ext: "txt")
        defer { do { try FileManager.default.removeItem(at: sentinel) } catch { XCTFail("Synthetic cleanup failed: \(error)") } }
        let stop = ItineraryStop(name: "Synthetic stop"), attachment = ItineraryAttachment(kind: .file,
            displayName: "Synthetic", fileName: sentinel.lastPathComponent)
        stop.attachments = [attachment]; attachment.stop = stop
        let day = ItineraryDay(stops: [stop])
        let trip = TripBundle(name: "Synthetic retained", destinationCity: "", days: 1, dateRange: "", isDateless: true)
        trip.itineraryDays = [day]; day.bundle = trip; stop.day = day
        let store = TripStore(context: context, persistenceSave: journal.captureAndSave, scope: .account(didChange: {}))
        store.addTrip(trip)
        store.removeTrip(withId: trip.id)
        XCTAssertTrue(store.trips.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        let persisted = ModelContext(database)
        XCTAssertTrue(try persisted.fetch(FetchDescriptor<TripBundle>()).isEmpty)
        XCTAssertEqual(try persisted.fetch(FetchDescriptor<CarryNativeTransaction>()).count, 2)
    }

    func testUnresolvedDeletionRetainsConflictStateAndContinuesPulling() async throws {
        let database = try container(), business = ModelContext(database), transport = Transport()
        var original = try entity()
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: database, transport: transport, businessContext: { business })
        try workspace.replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        original.fields["name"] = .string("My offline title")
        try workspace.replica.edit(original)
        var deleted = original
        deleted.fields["name"] = .string("Synthetic account")
        deleted.version = 2; deleted.subtreeVersion = 2; deleted.deletedAt = "2026-10-31T00:00:00Z"; deleted.deletionBatch = UUID()
        try workspace.replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 2, entity: deleted)], cursor: 2, hasMore: false))
        workspace.enableSynchronization()
        for _ in 0..<2 {
            let complete = try await workspace.synchronize()
            XCTAssertFalse(complete); XCTAssertEqual(workspace.state, .conflict)
        }
        XCTAssertEqual(transport.pulls, 2)
        XCTAssertTrue(transport.applications.isEmpty)
        XCTAssertTrue(try business.fetch(FetchDescriptor<TripBundle>()).isEmpty)
        XCTAssertEqual(try workspace.replica.deletionConflicts().count, 1)
    }
}
