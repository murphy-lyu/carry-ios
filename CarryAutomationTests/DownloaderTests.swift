import XCTest
import CryptoKit
@testable import Carry

@MainActor
final class DownloaderTests: XCTestCase {
    private let project = URL(string: "http://127.0.0.1:8893")

    private func fixture(mode: String = "normal") async throws -> (URL, CarryAssetDownload, CarryAssetDownloader) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryDownloadQA-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let asset = CarryAssetDownload(id: UUID(), accountID: UUID(),
            sha256: SHA256.hash(data: Data(repeating: 0x57, count: 128 * 1024)).map { String(format: "%02x", $0) }.joined(),
            byteCount: 128 * 1024)
        var request = URLRequest(url: try XCTUnwrap(project).appendingPathComponent("__fixture"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": asset.id.uuidString.lowercased(), "mode": mode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        let downloader = try CarryAssetDownloader(accountID: asset.accountID, projectURL: XCTUnwrap(project),
            directory: directory, publishableKey: "sb_publishable_synthetic_only", accessToken: { "synthetic-download-token" })
        return (directory, asset, downloader)
    }

    func testVerifiedBytesPublishInsideOnlyTheirAccountAndSurviveReopen() async throws {
        let (directory, asset, downloader) = try await fixture()
        let url = try await downloader.download(asset)
        XCTAssertTrue(url.path.contains(asset.accountID.uuidString.lowercased()))
        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 0x57, count: asset.byteCount))
        let cached = try await downloader.cached(asset)
        XCTAssertEqual(cached, url)
        try await downloader.close()
        let reopened = try CarryAssetDownloader(accountID: asset.accountID, projectURL: XCTUnwrap(project),
            directory: directory, publishableKey: "sb_publishable_synthetic_only", accessToken: { "synthetic-download-token" })
        let recovered = try await reopened.cached(asset)
        XCTAssertEqual(recovered, url)
        try await reopened.close(discardCache: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptionTruncationAndRedirectNeverPublishCache() async throws {
        for mode in ["corrupt", "truncated", "redirect", "expired"] {
            let (directory, asset, downloader) = try await fixture(mode: mode)
            do { _ = try await downloader.download(asset); XCTFail("Must reject \(mode)") }
            catch { /* The fixture deliberately violates the download contract. */ }
            let cached = try await downloader.cached(asset)
            XCTAssertNil(cached)
            let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            XCTAssertFalse(files.contains { $0.hasSuffix(".partial") || $0.hasSuffix(".asset") })
            try await downloader.close(discardCache: true)
        }
    }

    func testWrongAccountAndClosedInstanceCannotReadOrFetch() async throws {
        let (_, asset, downloader) = try await fixture()
        let wrong = CarryAssetDownload(id: asset.id, accountID: UUID(), sha256: asset.sha256, byteCount: asset.byteCount)
        do { _ = try await downloader.download(wrong); XCTFail("Must reject owner") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .invalidSource) }
        try await downloader.close()
        do { _ = try await downloader.download(asset); XCTFail("Must reject closed downloader") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .sessionExpired) }
        do { _ = try await downloader.cached(asset); XCTFail("Must reject closed cache") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .sessionExpired) }
    }

    func testCloseCancelsWriterBeforeRemovingOnlyOwnCache() async throws {
        let (directory, asset, downloader) = try await fixture(mode: "slow")
        let other = directory.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let sentinel = other.appendingPathComponent("retained.asset")
        try Data([9]).write(to: sentinel)
        let task = Task { try await downloader.download(asset) }
        try await Task.sleep(for: .milliseconds(80))
        try await downloader.close(discardCache: true)
        do { _ = try await task.value; XCTFail("Closing must cancel the download") }
        catch { /* Cancellation or a closed-session error are both valid. */ }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("downloads").appendingPathComponent(asset.accountID.uuidString.lowercased()).path))
    }

    func testOfflineCacheChecksHashAndRejectsSymbolicLinks() async throws {
        let (directory, asset, downloader) = try await fixture()
        let url = try await downloader.download(asset)
        try Data(repeating: 0, count: asset.byteCount).write(to: url)
        do { _ = try await downloader.cached(asset); XCTFail("Must detect cache corruption") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .invalidResponse) }
        // A fresh authorized download atomically repairs a corrupt cached copy.
        _ = try await downloader.download(asset)
        let outside = directory.appendingPathComponent("sentinel")
        try Data([1, 2, 3]).write(to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        do { _ = try await downloader.cached(asset); XCTFail("Must refuse symlink") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .invalidResponse) }
        try await downloader.close(discardCache: true)
        XCTAssertEqual(try Data(contentsOf: outside), Data([1, 2, 3]))
    }
}
