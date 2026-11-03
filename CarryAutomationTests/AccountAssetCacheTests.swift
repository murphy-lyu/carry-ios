import XCTest
import SwiftData
import CryptoKit
@testable import Carry

@MainActor
final class AccountAssetCacheTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarryAssetCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func database() throws -> ModelContainer {
        let schema = Schema(CarryAccountAssetQueue.models + [CarryReplicaCheckpoint.self, CarryNativeJournalOwner.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: folder().appendingPathComponent("queue.store"), cloudKitDatabase: .none)])
    }
    private func snapshot(accountID: UUID, entityID: UUID, slot: String, sha256: String = String(repeating: "a", count: 64)) throws -> CarryAccountAssetSnapshot {
        let id = try CarryAccountAssetIdentity.id(accountID: accountID, entityID: entityID, slot: slot, sha256: sha256)
        return .init(token: try .init(accountID: accountID, assetID: id, sha256: sha256), byteCount: 3)
    }

    func testBoundSnapshotUsesTheServerIdentityAndCanBeQueuedWithoutFileReads() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")), entity = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let cache = try CarryAccountAssetCache(root: root, accountID: owner)
        let item = try await cache.snapshot(data: Data("synthetic".utf8), entityID: entity, slot: "file")
        XCTAssertEqual(item.token.assetID.uuidString.lowercased(), "7caa67d2-bca0-33db-977e-0a785800563f")
        let container = try database(), context = ModelContext(container), queue = CarryAccountAssetQueue(accountID: owner)
        let work = try queue.bind(item, entityID: entity, entityKind: "attachment", slot: "file", in: context)
        try context.save()
        XCTAssertEqual(work.descriptor.id, item.token.assetID)
        XCTAssertFalse(work.isVerified)
        XCTAssertEqual(try queue.pendingWork(in: ModelContext(container)).count, 1)
    }

    func testTokensAreCanonicalAndCannotResolveAnotherAccountOrAPath() async throws {
        let owner = UUID(), other = UUID(), root = try folder()
        let token = try CarryAccountAssetToken(accountID: owner, assetID: UUID(), sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(try CarryAccountAssetToken(rawValue: token.rawValue), token)
        for invalid in ["../" + token.rawValue, token.rawValue.uppercased(), token.rawValue + "/x", "carryasset1_../a.blob"] {
            XCTAssertThrowsError(try CarryAccountAssetToken(rawValue: invalid))
        }
        let cache = try CarryAccountAssetCache(root: root, accountID: other)
        do { _ = try await cache.url(for: token); XCTFail("Cross-account resolution must fail") }
        catch CarryAccountAssetCacheFailure.wrongAccount {}
    }

    func testSnapshotRetainsFrozenBytesAndIdentityCannotBeOverwritten() async throws {
        let root = try folder(), owner = UUID(), assetID = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original.bin"), bytes = Data("original private snapshot".utf8)
        try bytes.write(to: input)
        let cache = try CarryAccountAssetCache(root: root.appendingPathComponent("cache"), accountID: owner)
        let first = try await cache.snapshot(fileURL: input, assetID: assetID)
        let firstURL = try await cache.verify(first)
        XCTAssertEqual(first.byteCount, bytes.count)
        XCTAssertEqual(first.token.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try Data("changed original".utf8).write(to: input)
        do { _ = try await cache.snapshot(fileURL: input, assetID: assetID); XCTFail("An asset ID is immutable") }
        catch CarryAccountAssetCacheFailure.immutableIdentity {}
        XCTAssertEqual(try Data(contentsOf: firstURL), bytes)
        XCTAssertEqual(try Data(contentsOf: input), Data("changed original".utf8))
        let second = try await cache.snapshot(fileURL: input)
        XCTAssertNotEqual(first.token, second.token)
        let names = try FileManager.default.contentsOfDirectory(atPath: firstURL.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".stage-") })
    }

    func testOversizeAndSymlinkSourcesNeverPublishAndCancellationKeepsOthers() async throws {
        let root = try folder(), owner = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try CarryAccountAssetCache(root: root.appendingPathComponent("cache"), accountID: owner)
        let keep = try await cache.snapshot(data: Data("keep".utf8))
        let large = root.appendingPathComponent("large")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(CarryAccountAssetCache.maximumBytes + 1)); try handle.close()
        do { _ = try await cache.snapshot(fileURL: large); XCTFail("Oversize input must fail") } catch {}
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: large)
        do { _ = try await cache.snapshot(fileURL: link); XCTFail("Symlink input must fail") } catch {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.snapshot(data: Data("cancel".utf8))
        }
        do { _ = try await task.value; XCTFail("Cancelled input must fail") } catch is CancellationError {}
        _ = try await cache.verify(keep)
        let keptURL = try await cache.url(for: keep.token)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: keptURL.deletingLastPathComponent().path), [keep.token.rawValue])
    }

    func testGCOnlyRemovesUnretainedSnapshotsInsideItsAccount() async throws {
        let root = try folder(), owner = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try CarryAccountAssetCache(root: root, accountID: owner)
        let other = try CarryAccountAssetCache(root: root, accountID: UUID())
        let retained = try await cache.snapshot(data: Data("retain".utf8))
        let removed = try await cache.snapshot(data: Data("remove".utf8))
        let separate = try await other.snapshot(data: Data("other account".utf8))
        let collected = try await cache.collect(keeping: [retained.token])
        XCTAssertEqual(collected, [removed.token])
        _ = try await cache.verify(retained); _ = try await other.verify(separate)
    }

    func testBindingAndFrozenWorkSurviveRestartAndRetainReplacedBytesUntilRelease() throws {
        let container = try database(), context = ModelContext(container), owner = UUID(), entity = UUID(), request = UUID()
        context.autosaveEnabled = false
        let queue = CarryAccountAssetQueue(accountID: owner)
        let first = try snapshot(accountID: owner, entityID: entity, slot: "file")
        let second = try snapshot(accountID: owner, entityID: entity, slot: "file", sha256: String(repeating: "b", count: 64))
        try queue.bind(first, entityID: entity, entityKind: "attachment", slot: "file", in: context)
        let frozen = try queue.freeze(assetIDs: [first.token.assetID], requestID: request, in: context)
        try queue.bind(second, entityID: entity, entityKind: "attachment", slot: "file", in: context)
        try context.save()
        let reader = ModelContext(container)
        XCTAssertEqual(try queue.binding(entityID: entity, slot: "file", in: reader)?.snapshot.token, second.token)
        try queue.retireUnboundJobs(in: reader)
        XCTAssertEqual(try queue.retainedTokens(in: reader), [first.token, second.token])
        XCTAssertEqual(frozen.first?.snapshot.token, first.token)
        try queue.release(requestID: request, in: reader)
        try queue.retireUnboundJobs(in: reader); try reader.save()
        XCTAssertEqual(try queue.retainedTokens(in: ModelContext(container)), [second.token])
    }

    func testFailedBindingTransactionDoesNotPublishAndUploadingJobCannotBeRetired() throws {
        let container = try database(), context = ModelContext(container), owner = UUID(), entity = UUID()
        context.autosaveEnabled = false
        let queue = CarryAccountAssetQueue(accountID: owner), item = try snapshot(accountID: owner, entityID: entity, slot: "thumbnail")
        try queue.bind(item, entityID: entity, entityKind: "photo", slot: "thumbnail", in: context)
        context.rollback()
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CarryAccountAssetJob>()).isEmpty)
        let fresh = ModelContext(container)
        try queue.bind(item, entityID: entity, entityKind: "photo", slot: "thumbnail", in: fresh)
        try queue.markUploading(item.token.assetID, in: fresh)
        try queue.unbind(entityID: entity, slot: "thumbnail", in: fresh)
        try queue.retireUnboundJobs(in: fresh)
        XCTAssertEqual(try queue.retainedTokens(in: fresh), [item.token])
        try queue.requeue(item.token.assetID, in: fresh)
        try queue.retireUnboundJobs(in: fresh)
        XCTAssertTrue(try queue.retainedTokens(in: fresh).isEmpty)
    }

    func testQueueRejectsOtherJournalOwnerAndImmutableAssetReuse() throws {
        let container = try database(), context = ModelContext(container), owner = UUID()
        context.insert(CarryNativeJournalOwner(accountID: owner)); try context.save()
        let otherQueue = CarryAccountAssetQueue(accountID: UUID())
        XCTAssertThrowsError(try otherQueue.bind(snapshot(accountID: otherQueue.accountID, entityID: UUID(), slot: "thumbnail"), entityID: UUID(), entityKind: "photo", slot: "thumbnail", in: context))
        context.rollback()
        let queue = CarryAccountAssetQueue(accountID: owner), entity = UUID()
        let item = try snapshot(accountID: owner, entityID: entity, slot: "thumbnail")
        try queue.bind(item, entityID: entity, entityKind: "photo", slot: "thumbnail", in: context); try context.save()
        XCTAssertThrowsError(try queue.bind(item, entityID: UUID(), entityKind: "photo", slot: "thumbnail", in: context))
    }
}
