import XCTest
import UIKit
@testable import Carry

final class AccountPhotoPixelsTests: XCTestCase {
    func testOriginalDecodeHasBoundedPixelsAndRetainsCorrectAspectRatio() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 1024), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".blob")
        try data.write(to: file)
        defer { do { try FileManager.default.removeItem(at: file) } catch { XCTFail("Fixture cleanup") } }
        let decoded = try CarryAccountPhotoPixels.image(at: file, maxPixel: 256)
        XCTAssertEqual(decoded.cgImage?.width, 256); XCTAssertEqual(decoded.cgImage?.height, 128)
        XCTAssertThrowsError(try CarryAccountPhotoPixels.image(at: file, maxPixel: 100000))
    }
    func testCorruptOriginalCannotBeDisplayedAsVerifiedPixels() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Not an image".utf8).write(to: file)
        defer { do { try FileManager.default.removeItem(at: file) } catch { XCTFail("Fixture cleanup") } }
        XCTAssertThrowsError(try CarryAccountPhotoPixels.image(at: file, maxPixel: 256))
    }
}
