import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AccountBackupLeaseTests: XCTestCase {
    private enum Unexpected: Error { case network }
    private final class Transport: CarryGraphTransporting {
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt { throw Unexpected.network }
        func pull(cursor: Int) async throws -> CarryGraphPage { throw Unexpected.network }
    }
    private func emptyBackup() throws -> Data {
        let value = CarryBackup(version: 1, createdAt: Date(), trips: [], myItems: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(value)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarryBackupLease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func container() throws -> ModelContainer {
        let schema = CarryAccountReplica.schema
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    func testAccountAsyncBackupFailsClosedWithoutImporterAndAfterImporterClose() async throws {
        let folder = try directory(); defer { do { try FileManager.default.removeItem(at: folder) } catch { XCTFail("Owned fixture cleanup") } }
        let owner = UUID(), container = try self.container()
        _ = try CarryAccountReplica(container: container, accountID: owner)
        let context = ModelContext(container), store = TripStore(context: context, scope: .account(didChange: {})), data = try emptyBackup()
        do { _ = try await store.mergeFromDataAsync(data); XCTFail("Account importer is required") }
        catch TripStoreScopeFailure.accountOperationUnavailable { }
        let access = CarryAccountFileAccess(), lease = try access.begin(accountID: owner)
        defer { access.revoke(lease) }
        let importer = try CarryAccountImportService(accountID: owner, cache: CarryAccountAssetCache(root: folder.appendingPathComponent("cache"), accountID: owner), access: access, lease: lease)
        store.assetImporter = importer; try importer.assertActive(); importer.close()
        do { _ = try await store.mergeFromDataAsync(data); XCTFail("Closed importer") }
        catch CarryNativeAssetCoordinatorFailure.closed { }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
    }
    func testRevokedLeaseAtFinalFenceRejectsMetadataOnlyRestore() async throws {
        let folder = try directory(); defer { do { try FileManager.default.removeItem(at: folder) } catch { XCTFail("Owned fixture cleanup") } }
        let owner = UUID(), container = try self.container()
        _ = try CarryAccountReplica(container: container, accountID: owner)
        let context = ModelContext(container), access = CarryAccountFileAccess(), lease = try access.begin(accountID: owner)
        let importer = try CarryAccountImportService(accountID: owner, cache: CarryAccountAssetCache(root: folder.appendingPathComponent("cache"), accountID: owner), access: access, lease: lease)
        let manager = DataBackupManager(backupURL: folder.appendingPathComponent("backup.json"))
        do {
            _ = try await manager.restoreFromDataAsync(emptyBackup(), into: context, preCommit: { access.revoke(lease); try importer.assertActive() })
            XCTFail("A metadata-only backup cannot outlive account logout")
        } catch CarryAccountFileAccessFailure.inactiveLease { }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
    }
    func testPausedOfflineWriterRemainsAvailableButPermanentCloseRejectsRetainedWriter() async throws {
        let folder = try directory(); defer { do { try FileManager.default.removeItem(at: folder) } catch { XCTFail("Owned fixture cleanup") } }
        let container = try self.container(), context = ModelContext(container)
        let workspace = try CarryAccountWorkspace(accountID: UUID(), container: container, transport: Transport(), businessContext: { context })
        let retained = workspace.businessSave
        await workspace.pauseAndWait()
        context.insert(TripBundle(name: "Allowed offline", destinationCity: "", days: 1, sections: []))
        try CarryPersistence.commit(context, using: retained)
        workspace.revokeWriterLease()
        context.insert(TripBundle(name: "Rejected after close", destinationCity: "", days: 1, sections: []))
        XCTAssertThrowsError(try CarryPersistence.commit(context, using: retained))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).map(\.name), ["Allowed offline"])
        workspace.enableSynchronization()
        do { _ = try await workspace.synchronize(); XCTFail("Closed workspace cannot resume") } catch CarryAccountWorkspaceFailure.writerClosed { }
    }
}
