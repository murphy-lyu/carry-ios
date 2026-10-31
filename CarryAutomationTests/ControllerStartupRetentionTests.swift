import XCTest
import SwiftData
@testable import Carry

@MainActor
final class ControllerStartupRetentionTests: XCTestCase {
    private final class Transport: CarryGraphTransporting {
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
            XCTFail("Opening an account must not publish guest data")
            throw CarryAccountWorkspaceControllerFailure.unavailable
        }
        func pull(cursor: Int) async throws -> CarryGraphPage { .init(changes: [], cursor: cursor, hasMore: false) }
    }
    func testReclamationFinishesBeforeTheNewAccountFactoryAndStoreAreExposed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryStartupRetention-" + UUID().uuidString)
        let owner = UUID(), accounts = directory.appendingPathComponent("accounts")
        let account = accounts.appendingPathComponent(owner.uuidString.lowercased())
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let container = try CarryAccountReplica.container(at: account.appendingPathComponent("account.store"))
        let replica = try CarryAccountReplica(container: container, accountID: owner)
        let cache = try CarryAccountAssetCache(root: account.appendingPathComponent("assets"), accountID: owner)
        let entityID = UUID()
        let pending = try await cache.snapshot(data: Data("Pending immutable upload".utf8), entityID: entityID, slot: "file")
        let orphan = try await cache.snapshot(data: Data("Unreferenced bytes".utf8), entityID: UUID(), slot: "file")
        let queue = CarryAccountAssetQueue(accountID: owner)
        _ = try queue.bind(pending, entityID: entityID, entityKind: "attachment", slot: "file", in: replica.context)
        _ = try queue.freeze(assetIDs: [pending.token.assetID], requestID: UUID(), in: replica.context)
        try replica.context.save()
        let schema = Schema(SchemaV1.models)
        let localContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let local = TripStore(context: ModelContext(localContainer), scope: .account(didChange: {}))
        let library = CarryWorkspaceLibrary(local: local)
        var called = false
        let controller = CarryAccountWorkspaceController(library: library, rootDirectory: accounts, access: CarryAccountFileAccess(), factory: { _, _ in
            called = true
            XCTAssertNil(library.account)
            _ = try await cache.verify(pending)
            do { _ = try await cache.verify(orphan); XCTFail("Orphan survived the exclusive startup collection") } catch { }
            return .init(transport: Transport(), manifest: { _ in throw CarryAccountWorkspaceControllerFailure.unavailable },
                download: { _ in throw CarryAccountWorkspaceControllerFailure.unavailable },
                upload: { _, _ in throw CarryAccountWorkspaceControllerFailure.unavailable }, close: {})
        })
        try await controller.enable(accountID: owner)
        XCTAssertTrue(called)
        let runtimeContainer = try XCTUnwrap(library.account?.businessContext.container)
        try await controller.close()
        // XCTest teardown runs after method locals are released. SwiftData may
        // still retain a store for queued framework work; never unlink an open
        // SQLite store. Such fixtures stay in the disposable simulator temp area.
        addTeardownBlock { [weak container, weak runtimeContainer] in
            guard container == nil, runtimeContainer == nil else { return }
            do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("Synthetic retention cleanup failed") }
        }
    }
}
