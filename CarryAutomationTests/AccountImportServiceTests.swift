import XCTest
@testable import Carry

@MainActor
final class AccountImportServiceTests: XCTestCase {
    func testAccountImportUsesImmutableAccountNamespaceAndPreallocatedEntityIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AccountImport-\(UUID())")
        let account = UUID(), entity = UUID(), access = CarryAccountFileAccess()
        let lease = try access.begin(accountID: account)
        defer { access.revoke(lease) }
        let cache = try CarryAccountAssetCache(root: root.appendingPathComponent("account"), accountID: account)
        let importer = try CarryAccountImportService(accountID: account, cache: cache, access: access, lease: lease)
        let temporary = try await AttachmentImportWorker.prepare(data: Data("private input".utf8), ext: "pdf", directory: root.appendingPathComponent("temporary"))
        let oldURL = temporary.fileURL
        let prepared = try await importer.attachment(from: temporary, entityID: entity)
        XCTAssertEqual(prepared.entityID, entity)
        let token = try CarryAccountAssetToken(rawValue: prepared.fileURL.lastPathComponent)
        XCTAssertEqual(token.accountID, account)
        XCTAssertEqual(token.assetID, try CarryAccountAssetIdentity.id(accountID: account, entityID: entity, slot: "file", sha256: token.sha256))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(access.url(named: token.rawValue), prepared.fileURL)
        XCTAssertTrue(importer.preparedTokens.contains(token))
        try await prepared.discard()
        // Discard releases this preparation pin; it cannot remove an immutable
        // snapshot that another journal/job may already reference.
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
    }

    func testPreviewAliasHasReadableExtensionAndDiscardPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AccountPreview-\(UUID())")
        let cache = try CarryAccountAssetCache(root: root, accountID: UUID())
        let bytes = Data("%PDF-1.4\nsynthetic\n%%EOF".utf8)
        let snapshot = try await cache.snapshot(data: bytes, entityID: UUID(), slot: "file")
        let original = try await cache.verify(snapshot)
        let alias = try await CarryAccountAttachmentPreview.prepare(url: original, ext: "com.adobe.pdf")
        XCTAssertEqual(alias.fileURL.pathExtension, "pdf")
        XCTAssertNotEqual(alias.fileURL, original)
        XCTAssertEqual(try Data(contentsOf: alias.fileURL), bytes)
        try await alias.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testClosedImporterAndWrongAccountLeaseCannotPublishNewFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AccountImportClosed-\(UUID())")
        let account = UUID(), access = CarryAccountFileAccess(), lease = try access.begin(accountID: UUID())
        let cache = try CarryAccountAssetCache(root: root, accountID: account)
        XCTAssertThrowsError(try CarryAccountImportService(accountID: account, cache: cache, access: access, lease: lease))
        access.revoke(lease)
        let correct = try access.begin(accountID: account)
        defer { access.revoke(correct) }
        let importer = try CarryAccountImportService(accountID: account, cache: cache, access: access, lease: correct)
        importer.close()
        do { _ = try await importer.originalPhoto(data: Data([1]), entityID: UUID()); XCTFail("Closed account") }
        catch CarryNativeAssetCoordinatorFailure.closed {}
        XCTAssertTrue(importer.preparedTokens.isEmpty)
    }
}
