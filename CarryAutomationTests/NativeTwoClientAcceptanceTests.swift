import XCTest
import SwiftData
@testable import Carry

/// Real loopback HTTP / PostgreSQL graph core with two independent on-disk
/// native stores. This is not evidence of two physical Apple devices.
@MainActor
final class NativeTwoClientAcceptanceTests: XCTestCase {
    private struct Identity: Decodable { let accountID: UUID; let bearer: String }
    @MainActor private final class StoreReference { weak var value: TripStore? }
    @MainActor private final class Transport: CarryGraphStreamingTransporting {
        let base: any CarryGraphStreamingTransporting
        var applications = 0
        init(base: any CarryGraphStreamingTransporting) { self.base = base }
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
            applications += 1
            return try await base.apply(command)
        }
        func pull(cursor: Int) async throws -> CarryGraphPage { try await base.pull(cursor: cursor) }
        func applyStreaming(_ command: CarryGraphCommand, progress: CarryGraphReceiptProgress?,
            receive: @MainActor (CarryGraphReceiptSummary, CarryGraphReceiptPage, Int) async throws -> Void) async throws {
            applications += 1
            try await base.applyStreaming(command, progress: progress) { summary, page, bytes in
                try await receive(summary, page, bytes)
            }
        }
    }
    @MainActor private final class Client {
        let store: TripStore
        let workspace: CarryAccountWorkspace
        let transport: Transport
        init(path: URL, identity: Identity, endpoint: URL) throws {
            let database = try CarryAccountReplica.container(at: path)
            let context = ModelContext(database), reference = StoreReference()
            var hooks = CarryAccountWorkspace.Hooks()
            hooks.didProject = { _ in reference.value?.refresh() }
            let transport = Transport(base: CarryGraphTransport(configuration: .init(projectURL: endpoint,
                publishableKey: "sb_publishable_synthetic_only"), accessToken: { identity.bearer }))
            self.transport = transport
            let workspace = try CarryAccountWorkspace(accountID: identity.accountID, container: database,
                transport: transport, businessContext: { reference.value?.businessContext ?? context }, hooks: hooks)
            self.workspace = workspace
            store = TripStore(context: context, persistenceSave: workspace.businessSave, scope: .account(didChange: {}))
            reference.value = store
            store.refresh()
        }
        func save() throws { try CarryPersistence.commit(store.businessContext, using: workspace.businessSave) }
        func sync() async throws {
            let finished = try await workspace.synchronize()
            XCTAssertTrue(finished)
            XCTAssertEqual(workspace.state, .synchronized)
        }
    }
    private func fixture() async throws -> (Identity, URL, URL) {
        let port = ProcessInfo.processInfo.environment["CARRY_TWO_CLIENT_QA_PORT"] ?? "8891"
        guard let numeric = Int(port), (1...65535).contains(numeric) else { throw CarryGraphTransportFailure.invalidResponse }
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(numeric)"))
        var request = URLRequest(url: endpoint.appendingPathComponent("__fixture")); request.httpMethod = "POST"
        let (bytes, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        let identity = try JSONDecoder().decode(Identity.self, from: bytes)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CarryTwoClient-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Do not unlink databases still retained by SwiftData / SQLite.
        return (identity, endpoint, root)
    }
    private func trip() -> TripBundle {
        TripBundle(name: "Synthetic two-client", destinationCity: "Tokyo", days: 1,
            dateRange: "", isDateless: true, sections: [])
    }

    func testOfflineColdReopenMergesIndependentFieldsAcrossTwoNativeStores() async throws {
        let (identity, endpoint, root) = try await fixture()
        var first: Client? = try Client(path: root.appendingPathComponent("first.store"), identity: identity, endpoint: endpoint)
        let second = try Client(path: root.appendingPathComponent("second.store"), identity: identity, endpoint: endpoint)
        let original = trip(), id = original.id
        first?.store.addTrip(original)
        first?.workspace.enableSynchronization(); second.workspace.enableSynchronization()
        try await first?.sync(); try await second.sync()
        let remote = try XCTUnwrap(second.store.trips.first)
        XCTAssertEqual(remote.id, id)
        await first?.workspace.pauseAndWait()
        original.name = "Saved offline on first"
        try first?.save()
        remote.destinationCity = "Osaka"; try second.save(); try await second.sync()
        first?.workspace.revokeWriterLease(); first = nil
        let reopened = try Client(path: root.appendingPathComponent("first.store"), identity: identity, endpoint: endpoint)
        XCTAssertEqual(reopened.workspace.state, .paused)
        XCTAssertEqual(reopened.store.trips.first?.name, "Saved offline on first")
        XCTAssertNotNil(try reopened.workspace.bridge.nextBatch())
        reopened.workspace.enableSynchronization()
        try await reopened.sync(); try await second.sync()
        for client in [reopened, second] {
            XCTAssertEqual(client.store.trips.count, 1)
            XCTAssertEqual(client.store.trips.first?.id, id)
            XCTAssertEqual(client.store.trips.first?.name, "Saved offline on first")
            XCTAssertEqual(client.store.trips.first?.destinationCity, "Osaka")
            XCTAssertNil(try client.workspace.replica.nextCommand())
            await client.workspace.pauseAndWait()
        }
    }

    func testReviewedConflictKeepsOtherOfflineFieldsAndConvergesInBothNativeStores() async throws {
        let (identity, endpoint, root) = try await fixture()
        let first = try Client(path: root.appendingPathComponent("first.store"), identity: identity, endpoint: endpoint)
        let second = try Client(path: root.appendingPathComponent("second.store"), identity: identity, endpoint: endpoint)
        first.store.addTrip(trip())
        first.workspace.enableSynchronization(); second.workspace.enableSynchronization()
        try await first.sync(); try await second.sync()
        let left = try XCTUnwrap(first.store.trips.first), right = try XCTUnwrap(second.store.trips.first)
        left.name = "First offline draft"; left.destinationCity = "Kyoto"; try first.save()
        right.name = "Second published title"; try second.save(); try await second.sync()
        let priorWrites = first.transport.applications
        let completed = try await first.workspace.synchronize()
        XCTAssertFalse(completed, "Same-field concurrent writes require review")
        XCTAssertEqual(first.transport.applications, priorWrites + 1, "Readback must not resend the rejected mutation")
        XCTAssertEqual(first.workspace.state, .conflict, "A business conflict must show its review on the first response")
        let review = try XCTUnwrap(first.workspace.replica.conflictReview())
        XCTAssertEqual(review.local.fields["name"], .string("First offline draft"))
        XCTAssertEqual(review.current.fields["name"], .string("Second published title"))
        try first.workspace.replica.resolveReviewedConflict(review, fields: ["name": .remote])
        try await first.sync(); try await second.sync()
        for client in [first, second] {
            XCTAssertEqual(client.store.trips.first?.name, "Second published title")
            XCTAssertEqual(client.store.trips.first?.destinationCity, "Kyoto")
            XCTAssertNil(try client.workspace.replica.pendingFailure)
            await client.workspace.pauseAndWait()
        }
    }

    func testRemoteDeletionPreservesOfflineDraftUntilExplicitReviewedRestore() async throws {
        let (identity, endpoint, root) = try await fixture()
        let first = try Client(path: root.appendingPathComponent("first.store"), identity: identity, endpoint: endpoint)
        let second = try Client(path: root.appendingPathComponent("second.store"), identity: identity, endpoint: endpoint)
        let source = trip(); first.store.addTrip(source)
        first.workspace.enableSynchronization(); second.workspace.enableSynchronization()
        try await first.sync(); try await second.sync()
        source.name = "Retained offline deletion draft"; try first.save()
        second.store.removeTrip(withId: source.id); try await second.sync()
        let priorWrites = first.transport.applications
        let completed = try await first.workspace.synchronize()
        XCTAssertFalse(completed)
        XCTAssertEqual(first.transport.applications, priorWrites + 1, "Deletion review must not resend the rejected mutation")
        XCTAssertEqual(first.workspace.state, .conflict, "Remote deletion needs an immediate review, not a service-error retry")
        let review = try XCTUnwrap(first.workspace.replica.deletionConflicts().first)
        XCTAssertEqual(review.local.fields["name"], .string("Retained offline deletion draft"))
        XCTAssertEqual(first.store.trips.first?.name, "Retained offline deletion draft")
        XCTAssertTrue(second.store.trips.isEmpty)
        try first.workspace.replica.resolveDeletion(review, restore: true)
        try await first.sync(); try await second.sync()
        XCTAssertEqual(second.store.trips.first?.name, "Retained offline deletion draft")
        XCTAssertEqual(second.store.trips.first?.id, source.id)
        for client in [first, second] { await client.workspace.pauseAndWait() }
    }

    func testExplicitControllerMigrationIsEditableOnSecondStoreAndSourceStaysProtected() async throws {
        let (identity, endpoint, root) = try await fixture()
        let localDB = try CarryAccountReplica.container(at: root.appendingPathComponent("guest.store"))
        let local = TripStore(context: ModelContext(localDB), scope: .account(didChange: {}))
        let item = PackingItem(name: "Synthetic shirt", quantity: 2, isPacked: true)
        let source = TripBundle(name: "Synthetic migration", destinationCity: "Tokyo", days: 1,
            sections: [PackingSection(title: "Synthetic clothes", items: [item])])
        local.addTrip(source)
        let before = try CarryMigrationSourceSnapshot.capture(trip: source)
        let library = CarryWorkspaceLibrary(local: local)
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: root.appendingPathComponent("accounts"),
            access: CarryAccountFileAccess(), factory: { _, _ in
                .init(transport: CarryGraphTransport(configuration: .init(projectURL: endpoint,
                    publishableKey: "sb_publishable_synthetic_only"), accessToken: { identity.bearer }),
                    manifest: { _ in throw CarryAccountWorkspaceControllerFailure.unavailable },
                    download: { _ in throw CarryAccountWorkspaceControllerFailure.unavailable },
                    upload: { _, _ in throw CarryAccountWorkspaceControllerFailure.unavailable }, close: {})
            })
        try await controller.enable(accountID: identity.accountID)
        try await controller.migrate(tripIDs: [source.id], includeLibrary: false)
        XCTAssertTrue(controller.migrationFinished)
        XCTAssertEqual(try CarryMigrationSourceSnapshot.capture(trip: source), before)
        XCTAssertTrue(local.migrationWriteGuard.isProtected(source.id))
        let second = try Client(path: root.appendingPathComponent("second.store"), identity: identity, endpoint: endpoint)
        second.workspace.enableSynchronization(); try await second.sync()
        let migrated = try XCTUnwrap(second.store.trips.first)
        XCTAssertEqual(migrated.id, source.id)
        XCTAssertEqual(migrated.safeSections.first?.sortedItems.first?.quantity, 2)
        XCTAssertEqual(migrated.safeSections.first?.sortedItems.first?.isPacked, true)
        // End the controller's automatic pass before publishing from the other client.
        // Resuming below must start a new read after that publication.
        await controller.suspend()
        migrated.name = "Edited after migration on second"
        try second.save(); try await second.sync()
        try await controller.enable(accountID: identity.accountID)
        _ = try await controller.workspace?.synchronize()
        XCTAssertEqual(library.account?.trips.first?.name, "Edited after migration on second")
        XCTAssertEqual(try CarryMigrationSourceSnapshot.capture(trip: source), before)
        await second.workspace.pauseAndWait(); try await controller.close()
    }
}
