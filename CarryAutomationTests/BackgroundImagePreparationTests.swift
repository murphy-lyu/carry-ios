import XCTest
import UIKit
@testable import Carry

@MainActor
final class BackgroundImagePreparationTests: XCTestCase {
    private func bytes(width: Int = 2800, height: Int = 1400, color: UIColor = .red) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.85))
    }

    func testColdCoverIsPreparedUprightWithinStoredPixelBudgetAndWarmReadUsesCache() async throws {
        let name = UUID().uuidString + ".jpg"
        XCTAssertTrue(BackgroundImageStore.write(data: try bytes(), named: name))
        defer { BackgroundImageStore.delete(named: name) }
        XCTAssertNil(BackgroundImageStore.cachedImage(named: name), "Writing compressed bytes must not decode during a body lookup")
        let prepared = await BackgroundImageStore.preparedImage(named: name)
        let image = try XCTUnwrap(prepared)
        XCTAssertEqual(image.imageOrientation, .up)
        XCTAssertEqual(image.cgImage?.width, 1400)
        XCTAssertEqual(image.cgImage?.height, 700)
        XCTAssertTrue(BackgroundImageStore.cachedImage(named: name) === image)
        let warm = await BackgroundImageStore.preparedImage(named: name)
        XCTAssertTrue(warm === image)
    }

    func testReplacementAndDeletionInvalidatePreparedPixels() async throws {
        let name = UUID().uuidString + ".jpg"
        XCTAssertTrue(BackgroundImageStore.write(data: try bytes(width: 120, height: 60), named: name))
        let prepared = await BackgroundImageStore.preparedImage(named: name)
        let initial = try XCTUnwrap(prepared)
        XCTAssertEqual(initial.cgImage?.width, 120)
        XCTAssertTrue(BackgroundImageStore.write(data: try bytes(width: 80, height: 160, color: .blue), named: name))
        XCTAssertNil(BackgroundImageStore.cachedImage(named: name))
        let replacement = await BackgroundImageStore.preparedImage(named: name)
        let replaced = try XCTUnwrap(replacement)
        XCTAssertEqual(replaced.cgImage?.height, 160)
        XCTAssertFalse(replaced === initial)
        BackgroundImageStore.delete(named: name)
        XCTAssertNil(BackgroundImageStore.cachedImage(named: name))
        let deleted = await BackgroundImageStore.preparedImage(named: name)
        XCTAssertNil(deleted)
    }

    func testCancelledMissingCorruptAndEscapingRequestsNeverPublishPixels() async throws {
        let name = UUID().uuidString + ".jpg"
        XCTAssertTrue(BackgroundImageStore.write(data: Data([1, 2, 3]), named: name))
        defer { BackgroundImageStore.delete(named: name) }
        let corrupt = await BackgroundImageStore.preparedImage(named: name)
        let missing = await BackgroundImageStore.preparedImage(named: UUID().uuidString + ".jpg")
        let escaping = await BackgroundImageStore.preparedImage(named: "../escape.jpg")
        XCTAssertNil(corrupt)
        XCTAssertNil(missing)
        XCTAssertNil(escaping)
        let cancelled = Task { await BackgroundImageStore.preparedImage(named: name) }
        cancelled.cancel()
        let cancelledImage = await cancelled.value
        XCTAssertNil(cancelledImage)
        XCTAssertNil(BackgroundImageStore.cachedImage(named: name))
    }

    func testDeletingDuringColdPreparationCannotResurrectCachedPixels() async throws {
        let name = UUID().uuidString + ".jpg"
        XCTAssertTrue(BackgroundImageStore.write(data: try bytes(), named: name))
        let load = Task { await BackgroundImageStore.preparedImage(named: name) }
        await Task.yield()
        BackgroundImageStore.delete(named: name)
        _ = await load.value
        XCTAssertNil(BackgroundImageStore.cachedImage(named: name))
    }

    func testAccountRevocationRejectsEvenWarmPreparedImage() async throws {
        let owner = UUID(), token = try CarryAccountAssetToken(accountID: owner, assetID: UUID(), sha256: String(repeating: "a", count: 64))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: folder) } catch { XCTFail("Synthetic fixture cleanup failed") } }
        let url = folder.appendingPathComponent(token.rawValue)
        try bytes(width: 80, height: 40).write(to: url)
        let lease = try CarryAccountFileAccess.shared.begin(accountID: owner)
        defer { CarryAccountFileAccess.shared.revoke(lease) }
        try CarryAccountFileAccess.shared.publish([token.rawValue: url], lease: lease)
        let prepared = await BackgroundImageStore.preparedImage(named: token.rawValue)
        XCTAssertNotNil(prepared)
        XCTAssertNotNil(BackgroundImageStore.cachedImage(named: token.rawValue))
        CarryAccountFileAccess.shared.revoke(lease)
        XCTAssertNil(BackgroundImageStore.cachedImage(named: token.rawValue))
        let revoked = await BackgroundImageStore.preparedImage(named: token.rawValue)
        XCTAssertNil(revoked)
    }
}
