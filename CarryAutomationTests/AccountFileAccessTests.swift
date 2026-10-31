import XCTest
@testable import Carry

@MainActor
final class AccountFileAccessTests: XCTestCase {
    private func token(_ owner: UUID) throws -> CarryAccountAssetToken {
        try CarryAccountAssetToken(accountID: owner, assetID: UUID(), sha256: String(repeating: "a", count: 64))
    }
    func testTokenAloneNeverResolvesAndWrongOwnerPublicationIsAtomic() throws {
        let access = CarryAccountFileAccess(), owner = UUID(), own = try token(owner), other = try token(UUID())
        let lease = try access.begin(accountID: owner)
        XCTAssertNil(access.url(named: own.rawValue))
        XCTAssertThrowsError(try access.publish([own.rawValue: URL(fileURLWithPath: "/tmp/\(own.rawValue)"),
            other.rawValue: URL(fileURLWithPath: "/tmp/\(other.rawValue)")], lease: lease))
        XCTAssertNil(access.url(named: own.rawValue))
        XCTAssertThrowsError(try access.begin(accountID: owner))
    }
    func testRevokedLeaseCannotReadPublishOrRevokeNewLease() throws {
        let access = CarryAccountFileAccess(), owner = UUID(), own = try token(owner)
        let lease = try access.begin(accountID: owner), url = URL(fileURLWithPath: "/tmp/\(own.rawValue)")
        try access.publish([own.rawValue: url], lease: lease)
        XCTAssertEqual(access.url(named: own.rawValue), url)
        access.revoke(lease)
        XCTAssertNil(access.url(named: own.rawValue))
        let next = try access.begin(accountID: owner)
        XCTAssertThrowsError(try access.publish([own.rawValue: url], lease: lease))
        try access.publish([own.rawValue: url], lease: next)
        access.revoke(lease)
        XCTAssertEqual(access.url(named: own.rawValue), url)
    }
    func testLegacyFileMutationCannotOverwriteOrDeleteActiveAccountCache() throws {
        let owner = UUID(), own = try token(owner)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: folder) } catch { XCTFail("fixture cleanup") } }
        let url = folder.appendingPathComponent(own.rawValue), bytes = Data([1, 2, 3])
        try bytes.write(to: url)
        let lease = try CarryAccountFileAccess.shared.begin(accountID: owner)
        defer { CarryAccountFileAccess.shared.revoke(lease) }
        try CarryAccountFileAccess.shared.publish([own.rawValue: url], lease: lease)
        XCTAssertEqual(AttachmentStore.fileURL(named: own.rawValue), url)
        XCTAssertFalse(AttachmentStore.write(data: Data([9]), named: own.rawValue))
        XCTAssertFalse(BackgroundImageStore.write(data: Data([9]), named: own.rawValue))
        AttachmentStore.delete(named: own.rawValue); BackgroundImageStore.delete(named: own.rawValue)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        CarryAccountFileAccess.shared.revoke(lease)
        XCTAssertNotEqual(AttachmentStore.fileURL(named: own.rawValue), url)
    }
}
