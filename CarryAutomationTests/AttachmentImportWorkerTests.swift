import XCTest
@testable import Carry

final class AttachmentImportWorkerTests: XCTestCase {
    func testAdvertisedOversizeIsRejectedBeforeReading() throws {
        var reads = 0
        XCTAssertThrowsError(try AttachmentImportWorker.readBounded(advertisedLength: 101, maxBytes: 100) { _ in
            reads += 1; return Data([1])
        })
        XCTAssertEqual(reads, 0)
    }

    func testGrowingOrUnknownLengthInputStopsAtTheLimit() throws {
        var requested = 0
        XCTAssertThrowsError(try AttachmentImportWorker.readBounded(advertisedLength: nil, maxBytes: 100) { length in
            requested += length; return Data(repeating: 1, count: length)
        })
        XCTAssertEqual(requested, 101)
        var chunks = [Data(repeating: 2, count: 100), Data()]
        let accepted = try AttachmentImportWorker.readBounded(advertisedLength: 100, maxBytes: 100) { _ in chunks.removeFirst() }
        XCTAssertEqual(accepted.count, 100)
    }

    func testPreparedFileCanBeDiscardedOrExplicitlyAdopted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentImport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("Synthetic attachment".utf8)
        let prepared = try await AttachmentImportWorker.prepare(data: bytes, ext: "dat", directory: directory)
        XCTAssertEqual(try Data(contentsOf: prepared.fileURL), bytes)
        try await prepared.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        let adopted = try await AttachmentImportWorker.prepare(data: bytes, ext: "dat", directory: directory)
        adopted.adopt()
        try await adopted.discard()
        XCTAssertEqual(try Data(contentsOf: adopted.fileURL), bytes)
    }

    func testCancelledReadAndInvalidDestinationPublishNoFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentImportCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AttachmentImportWorker.readBounded(advertisedLength: 1) { _ in XCTFail("Cancelled read"); return Data() }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let blocker = directory.appendingPathComponent("file")
        try Data([1]).write(to: blocker)
        do {
            _ = try await AttachmentImportWorker.prepare(data: Data([2]), ext: "dat", directory: blocker)
            XCTFail("Expected invalid directory")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file"])
    }
}
