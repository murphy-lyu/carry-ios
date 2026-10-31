import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AccountAssetRetentionTests: XCTestCase {
    private struct Fixture {
        let owner: UUID
        let replica: CarryAccountReplica
        let cache: CarryAccountAssetCache
        let queue: CarryAccountAssetQueue
    }
    private func fixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CarryRetention-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let owner = UUID(), container = try CarryAccountReplica.container(at: folder.appendingPathComponent("account.store"))
        return Fixture(owner: owner, replica: try CarryAccountReplica(container: container, accountID: owner),
            cache: try CarryAccountAssetCache(root: folder.appendingPathComponent("assets"), accountID: owner),
            queue: CarryAccountAssetQueue(accountID: owner))
    }
    private func bind(_ fixture: Fixture, entityID: UUID = UUID()) async throws -> CarryAccountAssetSnapshot {
        let snapshot = try await fixture.cache.snapshot(data: Data("Synthetic \(entityID)".utf8), entityID: entityID, slot: "file")
        _ = try fixture.queue.bind(snapshot, entityID: entityID, entityKind: "attachment", slot: "file", in: fixture.replica.context)
        try fixture.replica.context.save()
        return snapshot
    }
    private func keepInRaw(_ fixture: Fixture, _ snapshot: CarryAccountAssetSnapshot) throws {
        try fixture.replica.edit(CarryGraphEntity(id: UUID(), kind: "attachment", parentID: UUID(), version: 0, subtreeVersion: 0,
            fields: ["fileAssetID": .string(snapshot.token.assetID.uuidString)], fieldVersions: [:]))
    }

    func testOnlyUnreferencedUnfrozenAccountBytesAreCollected() async throws {
        let fixture = try fixture(), live = try await bind(fixture), pinned = try await bind(fixture), frozen = try await bind(fixture), orphan = try await bind(fixture)
        try keepInRaw(fixture, live)
        _ = try fixture.queue.freeze(assetIDs: [frozen.token.assetID], requestID: UUID(), in: fixture.replica.context)
        try fixture.replica.context.save()
        let retention = try CarryAccountAssetRetention(accountID: fixture.owner, replica: fixture.replica, cache: fixture.cache,
            pins: { CarryAccountAssetRetention.Pins(tokens: [pinned.token]) })
        let result = try await retention.collect(lease: .init(accountID: fixture.owner, isValid: { true }))
        XCTAssertEqual(result.removedFiles, [orphan.token])
        XCTAssertEqual(result.retiredBindings, 1); XCTAssertEqual(result.retiredJobs, 1)
        _ = try await fixture.cache.verify(live); _ = try await fixture.cache.verify(pinned); _ = try await fixture.cache.verify(frozen)
        do { _ = try await fixture.cache.verify(orphan); XCTFail("Unreferenced bytes remain") } catch { }
    }

    func testRawTombstoneAndFrozenRequestRetainHistoricalAssets() async throws {
        let fixture = try fixture(), asset = try await bind(fixture), entityID = UUID(), batch = UUID()
        var entity = CarryGraphEntity(id: entityID, kind: "attachment", parentID: UUID(), version: 1, subtreeVersion: 1,
            fields: ["fileAssetID": .string(asset.token.assetID.uuidString)], fieldVersions: ["fileAssetID": 1])
        entity.deletedAt = "2000-01-01T00:00:00Z"; entity.deletionBatch = batch
        try fixture.replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: entity)], cursor: 1, hasMore: false))
        let retention = try CarryAccountAssetRetention(accountID: fixture.owner, replica: fixture.replica, cache: fixture.cache, pins: { .init() })
        let result = try await retention.collect(lease: .init(accountID: fixture.owner, isValid: { true }))
        XCTAssertTrue(result.removedFiles.isEmpty, "Device timestamps cannot prove server permanent purge")
        _ = try await fixture.cache.verify(asset)
        XCTAssertTrue(try fixture.replica.assetRetentionReferences().contains(asset.token.assetID))
    }

    func testUnconsumedJournalSourceAndPreviousSourceRetainBothFiles() async throws {
        let fixture = try fixture(), old = try await bind(fixture), new = try await bind(fixture), transactionID = UUID(), entityID = UUID()
        let before = CarryNativeSourceMetadata(id: entityID, kind: "attachment", parentID: UUID(), fields: [:], fileReferences: ["file": old.token.rawValue])
        let after = CarryNativeSourceMetadata(id: entityID, kind: "attachment", parentID: before.parentID, fields: [:], fileReferences: ["file": new.token.rawValue])
        fixture.replica.context.insert(CarryNativeJournalOwner(accountID: fixture.owner))
        fixture.replica.context.insert(CarryNativeTransaction(id: transactionID, sequence: 1, changeCount: 1))
        fixture.replica.context.insert(CarryNativeChange(transactionID: transactionID, ordinal: 0, entityID: entityID, kind: "attachment", action: "upsert",
            sourceData: try JSONEncoder().encode(after), previousSourceData: try JSONEncoder().encode(before), observedGraphData: nil,
            changedFields: [], parentChanged: false, thumbnailChanged: false, thumbnailData: nil))
        try fixture.replica.context.save()
        let retention = try CarryAccountAssetRetention(accountID: fixture.owner, replica: fixture.replica, cache: fixture.cache, pins: { .init() })
        let result = try await retention.collect(lease: .init(accountID: fixture.owner, isValid: { true }))
        XCTAssertTrue(result.removedFiles.isEmpty)
        _ = try await fixture.cache.verify(old); _ = try await fixture.cache.verify(new)
    }

    func testMissingExclusiveWriterLeaseNeverDeletesFiles() async throws {
        let fixture = try fixture(), orphan = try await bind(fixture)
        let retention = try CarryAccountAssetRetention(accountID: fixture.owner, replica: fixture.replica, cache: fixture.cache, pins: { .init() })
        do { _ = try await retention.collect(lease: .init(accountID: fixture.owner, isValid: { false })); XCTFail("No writer lease") }
        catch CarryAccountAssetRetentionFailure.changedSnapshot { }
        _ = try await fixture.cache.verify(orphan)
    }

    func testChangedPreparedPinsBetweenMarksAbortCollection() async throws {
        let fixture = try fixture(), orphan = try await bind(fixture)
        var reads = 0
        let retention = try CarryAccountAssetRetention(accountID: fixture.owner, replica: fixture.replica, cache: fixture.cache, pins: {
            reads += 1
            return .init(tokens: reads == 1 ? [] : [orphan.token])
        })
        do { _ = try await retention.collect(lease: .init(accountID: fixture.owner, isValid: { true })); XCTFail("Unstable snapshot") }
        catch CarryAccountAssetRetentionFailure.changedSnapshot { }
        _ = try await fixture.cache.verify(orphan)
    }

    func testMalformedAssetReferenceFailsClosedBeforeMetadataOrFileDeletion() async throws {
        let fixture = try fixture(), orphan = try await bind(fixture)
        try fixture.replica.edit(CarryGraphEntity(id: UUID(), kind: "attachment", parentID: UUID(), version: 0, subtreeVersion: 0,
            fields: ["fileAssetID": .string("untrusted-path")], fieldVersions: [:]))
        let retention = try CarryAccountAssetRetention(accountID: fixture.owner, replica: fixture.replica, cache: fixture.cache, pins: { .init() })
        do { _ = try await retention.collect(lease: .init(accountID: fixture.owner, isValid: { true })); XCTFail("Malformed reference") }
        catch CarryAccountAssetRetentionFailure.invalidReference { }
        _ = try await fixture.cache.verify(orphan)
        XCTAssertEqual(try fixture.replica.context.fetch(FetchDescriptor<CarryAccountAssetBinding>()).count, 1)
    }
}
