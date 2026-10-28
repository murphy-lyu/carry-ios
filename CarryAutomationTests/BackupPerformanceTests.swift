import XCTest
import os
import SwiftData
import UIKit
@testable import Carry

@MainActor
final class BackupPerformanceTests: XCTestCase {
    func testThumbnailDecodeUsesBoundedPixelsAndRejectsCorruptInput() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }
        let bytes = try XCTUnwrap(source.jpegData(compressionQuality: 0.9))
        let image = await Task.detached {
            AttachmentThumbnail.displayImage(from: bytes, maxPixel: 228)
        }.value
        let decoded = try XCTUnwrap(image?.cgImage)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 228)
        XCTAssertEqual(Double(decoded.width) / Double(decoded.height), 1.5, accuracy: 0.02)
        let filled = await Task.detached {
            AttachmentThumbnail.displayImage(from: bytes, maxPixel: 228, fillingSquare: true)
        }.value
        let squareSource = try XCTUnwrap(filled?.cgImage)
        XCTAssertGreaterThanOrEqual(min(squareSource.width, squareSource.height), 227,
            "A square crop must retain display density on its short edge")
        XCTAssertLessThanOrEqual(squareSource.width * squareSource.height, 1_048_576)
        XCTAssertNil(AttachmentThumbnail.displayImage(from: Data([0xff, 0x00]), maxPixel: 228))
        XCTAssertNil(AttachmentThumbnail.displayImage(from: bytes, maxPixel: 0))
    }

    func testPackingFastPathPersistsImmediatelyAndKeepsObservedGraph() async throws {
        let schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let item = PackingItem(name: "Passport", isAlert: false, sortOrder: 0)
        let trip = TripBundle(name: "Synthetic", destinationCity: "Tokyo", days: 3, dateRange: "")
        trip.sections = [PackingSection(title: "Essentials", items: [item])]
        context.insert(trip)
        try context.save()
        let store = TripStore(context: context)
        for _ in 0..<100 where !store.automationReady { await Task.yield() }
        XCTAssertTrue(store.automationReady)
        store.toggleItem(tripId: trip.id, itemId: item.id)
        XCTAssertTrue(store.trips.first === trip)
        let persisted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first)
        XCTAssertEqual(persisted.packedCount, 1)
        store.markTripUncompleted(tripId: trip.id)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first?.packedCount, 0)
        store.markTripCompleted(tripId: trip.id)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first?.packedCount, 1)
    }

    func testPackingCountsIgnoreDisplayOrderAndTrackChangesWithoutAStaleCache() {
        let packed = PackingItem(name: "Passport", isAlert: false, sortOrder: 0)
        packed.isPacked = true
        let empty = PackingItem(name: "", isAlert: false, sortOrder: 1)
        empty.isPacked = true
        let coat = PackingItem(name: "Coat", isAlert: false, sortOrder: 0)
        let trip = TripBundle(name: "Synthetic", destinationCity: "Tokyo", days: 3, dateRange: "")
        trip.sections = [PackingSection(title: "Second", items: [coat], sortOrder: 20),
                         PackingSection(title: "First", items: [empty, packed], sortOrder: 0)]
        XCTAssertEqual(trip.totalCount, 2)
        XCTAssertEqual(trip.packedCount, 1)
        coat.isPacked = true
        XCTAssertEqual(trip.packedCount, 2)
        packed.name = ""
        XCTAssertEqual(trip.totalCount, 1)
        XCTAssertEqual(trip.packedCount, 1)
        trip.sections = nil
        XCTAssertEqual(trip.totalCount, 0)
    }

    private func waitForStart(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }
    private func snapshot(_ version: Int) -> CarryBackup {
        CarryBackup(version: version, createdAt: Date(), trips: [], myItems: [])
    }

    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryBackupQA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("backup.json")
    }

    func testAutomaticBackupCoalescesModelReadsAndUsesLatestSource() async throws {
        let url = try location(), manager = DataBackupManager(backupURL: url)
        var reads = 0
        for _ in 0..<100 {
            manager.scheduleBackup { reads += 1; return ([], []) }
        }
        XCTAssertEqual(reads, 0, "Saving must not traverse the graph in the tap handler")
        await manager.flushPendingBackup()
        XCTAssertEqual(reads, 1)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(CarryBackup.self, from: data).trips.count, 0)
    }

    func testWriterEncodesOffMainAndCoalescesQueuedSnapshotsWithoutStaleOverwrite() async throws {
        let url = try location()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let encoded = OSAllocatedUnfairLock(initialState: [Int]())
        let onMain = OSAllocatedUnfairLock(initialState: false)
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let writer = CarryBackupWriter(encode: { value in
            if Thread.isMainThread { onMain.withLock { $0 = true } }
            encoded.withLock { $0.append(value.version) }
            if value.version == 1 { started.signal(); release.wait() }
            return Data(String(value.version).utf8)
        }, report: { _ in failures.withLock { $0 += 1 } })
        writer.submit(snapshot(1), to: url)
        await waitForStart(started)
        writer.submit(snapshot(2), to: url)
        writer.submit(snapshot(3), to: url)
        release.signal()
        await writer.flush()
        XCTAssertFalse(onMain.withLock { $0 })
        XCTAssertEqual(encoded.withLock { $0 }, [1, 3])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "3")
        XCTAssertEqual(failures.withLock { $0 }, 0)
    }

    func testErasureDiscardsQueuedAndInFlightBackupCannotResurrectFile() async throws {
        let url = try location()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let writer = CarryBackupWriter(encode: { value in
            if value.version == 1 { started.signal(); release.wait() }
            return Data(String(value.version).utf8)
        })
        writer.submit(snapshot(1), to: url)
        await waitForStart(started)
        writer.submit(snapshot(2), to: url)
        // Erasure completes even while the encoder is deliberately blocked.
        // Late completion must discard staging bytes instead of recreating data.
        try writer.clear(url)
        release.signal()
        await writer.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).isEmpty)
    }

    func testClearCancelsDeferredSnapshotBeforeReadingDeletedModels() async throws {
        let url = try location(), manager = DataBackupManager(backupURL: url)
        var reads = 0
        manager.scheduleBackup { reads += 1; return ([], []) }
        try manager.clearBackup()
        await manager.flushPendingBackup()
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearRemovesStagingBytesLeftByAnInterruptedProcess() async throws {
        let url = try location()
        let staging = url.deletingLastPathComponent().appendingPathComponent(".carry-backup-stage-synthetic-crash")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("synthetic private bytes".utf8).write(to: staging.appendingPathComponent("snapshot.json"))
        try Data("old backup".utf8).write(to: url)
        let writer = CarryBackupWriter()
        try writer.clear(url)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).isEmpty)
    }

    func testBackgroundEncodingPreservesPhotoAndAttachmentThumbnails() async throws {
        let url = try location(), manager = DataBackupManager(backupURL: url)
        let photoBytes = Data(repeating: 19, count: 256 * 1024)
        let attachmentBytes = Data(repeating: 23, count: 128 * 1024)
        let stop = ItineraryStop(name: "Synthetic", latitude: 35.7, longitude: 139.7)
        stop.photos = [StopPhoto(assetLocalIdentifier: "synthetic-photo", thumbnailData: photoBytes,
                                latitude: 35.7, longitude: 139.7)]
        let attachment = ItineraryAttachment(kind: .file, displayName: "Synthetic ticket", fileName: "synthetic.pdf", utiOrExt: "pdf")
        attachment.thumbnailData = attachmentBytes
        stop.attachments = [attachment]
        let trip = TripBundle(name: "Synthetic", destinationCity: "Tokyo", days: 3, dateRange: "")
        trip.itineraryDays = [ItineraryDay(sortOrder: 0, title: "Arrival", note: "", stops: [stop])]
        manager.scheduleBackup { ([trip], []) }
        await manager.flushPendingBackup()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(CarryBackup.self, from: Data(contentsOf: url))
        let saved = try XCTUnwrap(backup.trips.first?.itineraryDays?.first?.stops.first)
        XCTAssertEqual(saved.photos?.first?.thumbnailData, photoBytes)
        XCTAssertEqual(saved.attachments?.first?.thumbnailData, attachmentBytes)
        let availableInfo = await manager.latestBackupInfo()
        let info = try XCTUnwrap(availableInfo)
        XCTAssertEqual(info.tripCount, 1)
    }
}
