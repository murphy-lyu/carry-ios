import XCTest
import SwiftData
import CryptoKit
@testable import Carry

@MainActor
final class WorkspaceAssetTests: XCTestCase {
    private enum Injected: Error { case failed, unexpectedNetwork }
    private actor Provider {
        var manifests: [UUID: CarryAccountAssetManifest]
        let source: URL
        var metadataRequests = 0
        var downloads = 0
        init(manifests: [CarryAccountAssetManifest], source: URL) {
            self.manifests = Dictionary(uniqueKeysWithValues: manifests.map { ($0.assetID, $0) }); self.source = source
        }
        func manifest(_ id: UUID) throws -> CarryAccountAssetManifest {
            metadataRequests += 1
            guard let value = manifests[id] else { throw Injected.unexpectedNetwork }
            return value
        }
        func download(_ asset: CarryAssetDownload) throws -> URL {
            downloads += 1
            guard manifests[asset.id] != nil else { throw Injected.unexpectedNetwork }
            return source
        }
        func counts() -> (Int, Int) { (metadataRequests, downloads) }
    }
    private struct Fixture {
        let owner: UUID
        let directory: URL
        let container: ModelContainer
        let context: ModelContext
        let cache: CarryAccountAssetCache
        let source: URL
        let bytes: Data
        let snapshot: [CarryNativeProjectionEntity]
        let manifests: [CarryAccountAssetManifest]
    }
    private func fixture(count: Int = 1, thumbnail: Bool = false) throws -> Fixture {
        let owner = UUID(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryWorkspaceAssets-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try CarryAccountReplica.container(at: directory.appendingPathComponent("account.store"))
        _ = try CarryAccountReplica(container: container, accountID: owner)
        let context = ModelContext(container), data = Data(repeating: 0x58, count: 4096)
        let source = directory.appendingPathComponent("synthetic-source.bin")
        try data.write(to: source)
        let cache = try CarryAccountAssetCache(root: directory.appendingPathComponent("private-cache"), accountID: owner)
        let trip = TripBundle(name: "Synthetic", destinationCity: "", days: 1, dateRange: "", isDateless: true)
        let day = ItineraryDay(), stop = ItineraryStop(name: "Synthetic stop")
        trip.itineraryDays = [day]; day.bundle = trip; day.stops = [stop]; stop.day = day
        var models: [any PersistentModel] = [trip, day, stop]
        var manifests: [CarryAccountAssetManifest] = []
        var additions: [UUID: [String: CarryGraphValue]] = [:]
        for _ in 0..<count {
            let attachment = ItineraryAttachment(kind: .file, displayName: "Synthetic file", fileName: "wire-name.pdf")
            attachment.stop = stop
            if stop.attachments == nil { stop.attachments = [] }; stop.attachments?.append(attachment)
            models.append(attachment)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let slot = thumbnail ? "thumbnail" : "file"
            if thumbnail { attachment.fileName = "" }
            let id = try CarryAccountAssetIdentity.id(accountID: owner, entityID: attachment.id, slot: slot, sha256: hash)
            manifests.append(CarryAccountAssetManifest(accountID: owner, assetID: id, entityID: attachment.id,
                kind: "attachment", slot: slot, sha256: hash, byteCount: data.count, providerVersion: UUID()))
            additions[attachment.id] = [thumbnail ? "thumbnailAssetID" : "fileAssetID": .string(id.uuidString.lowercased())]
        }
        let snapshot = try models.map { model -> CarryNativeProjectionEntity in
            let source = try XCTUnwrap(CarryNativeSourceCodec.capture(model))
            var fields = source.metadata.fields
            fields.merge(additions[source.metadata.id] ?? [:]) { _, new in new }
            let entity = CarryGraphEntity(id: source.metadata.id, kind: source.metadata.kind, parentID: source.metadata.parentID,
                version: 1, subtreeVersion: 1, fields: fields, fieldVersions: fields.mapValues { _ in 1 })
            return CarryNativeProjectionEntity(local: entity, observed: entity)
        }
        return Fixture(owner: owner, directory: directory, container: container, context: context, cache: cache,
            source: source, bytes: data, snapshot: snapshot, manifests: manifests)
    }
    private func coordinator(_ value: Fixture, provider: Provider) throws -> CarryAccountWorkspaceAssets {
        try CarryAccountWorkspaceAssets(accountID: value.owner, cache: value.cache,
            manifest: { try await provider.manifest($0) }, download: { try await provider.download($0) })
    }
    private func project(_ fixture: Fixture, using assets: CarryAccountWorkspaceAssets,
                         context: ModelContext? = nil, rejectSave: Bool = false) throws {
        let projector = CarryNativeGraphProjector(accountID: fixture.owner, resolveAssets: assets.resolve)
        _ = try projector.project(snapshot: fixture.snapshot, in: context ?? fixture.context, save: { transaction in
            try assets.saveProjection(transaction, save: { transaction in
                if rejectSave { throw Injected.failed }
                try transaction.save()
            })
        })
    }

    func testRemoteDownloadBecomesPrivateTokenAndDurableOfflineBinding() async throws {
        let fixture = try fixture(), provider = Provider(manifests: fixture.manifests, source: fixture.source)
        let assets = try coordinator(fixture, provider: provider)
        try await assets.prepare(snapshot: fixture.snapshot, candidateIDs: Set(fixture.snapshot.map { $0.local.id }), in: fixture.context)
        XCTAssertFalse(fixture.context.hasChanges, "Asynchronous preparation must not replace local bindings")
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<CarryAccountAssetBinding>()).isEmpty)
        try project(fixture, using: assets)
        let attachment = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<ItineraryAttachment>()).first)
        let token = try CarryAccountAssetToken(rawValue: attachment.fileName)
        XCTAssertEqual(token.accountID, fixture.owner)
        XCTAssertNotEqual(attachment.fileName, "wire-name.pdf")
        let work = try XCTUnwrap(CarryAccountAssetQueue(accountID: fixture.owner).binding(entityID: attachment.id, slot: "file", in: fixture.context))
        XCTAssertTrue(work.isVerified)
        let reopened = try CarryAccountWorkspaceAssets(accountID: fixture.owner, cache: fixture.cache,
            manifest: { _ in throw Injected.unexpectedNetwork }, download: { _ in throw Injected.unexpectedNetwork })
        let file = try await reopened.fileURL(for: attachment.fileName, in: ModelContext(fixture.container))
        XCTAssertEqual(try Data(contentsOf: file), fixture.bytes)
        XCTAssertTrue(file.path.contains(fixture.owner.uuidString.lowercased()))
        let counts = await provider.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }

    func testLocalPendingAssetProjectsWithoutNetworkOrFalseServerVerification() async throws {
        let fixture = try fixture(), manifest = try XCTUnwrap(fixture.manifests.first)
        let snapshot = try await fixture.cache.snapshot(fileURL: fixture.source, entityID: manifest.entityID, slot: manifest.slot)
        let queue = CarryAccountAssetQueue(accountID: fixture.owner)
        _ = try queue.bind(snapshot, entityID: manifest.entityID, entityKind: manifest.kind, slot: manifest.slot,
            contentType: "application/pdf", in: fixture.context)
        try fixture.context.save()
        let assets = try CarryAccountWorkspaceAssets(accountID: fixture.owner, cache: fixture.cache,
            manifest: { _ in throw Injected.unexpectedNetwork }, download: { _ in throw Injected.unexpectedNetwork })
        try await assets.prepare(snapshot: fixture.snapshot, candidateIDs: Set(fixture.snapshot.map { $0.local.id }), in: fixture.context)
        try project(fixture, using: assets)
        let work = try XCTUnwrap(queue.binding(entityID: manifest.entityID, slot: manifest.slot, in: fixture.context))
        XCTAssertFalse(work.isVerified)
        XCTAssertEqual(work.descriptor.contentType, "application/pdf")
    }

    func testProjectionSaveFailureRollsBackBusinessAndAssetBindingsTogether() async throws {
        let fixture = try fixture(), provider = Provider(manifests: fixture.manifests, source: fixture.source)
        let assets = try coordinator(fixture, provider: provider)
        try await assets.prepare(snapshot: fixture.snapshot, candidateIDs: Set(fixture.snapshot.map { $0.local.id }), in: fixture.context)
        XCTAssertThrowsError(try project(fixture, using: assets, rejectSave: true))
        let fresh = ModelContext(fixture.container)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<TripBundle>()).isEmpty)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<CarryAccountAssetBinding>()).isEmpty)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<CarryAccountAssetJob>()).isEmpty)
        try project(fixture, using: assets, context: fresh)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<TripBundle>()).count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CarryAccountAssetBinding>()).count, 1)
    }

    func testWrongAccountManifestNeverPublishesNativeBindings() async throws {
        let fixture = try fixture(), original = try XCTUnwrap(fixture.manifests.first)
        let wrong = CarryAccountAssetManifest(accountID: UUID(), assetID: original.assetID, entityID: original.entityID,
            kind: original.kind, slot: original.slot, sha256: original.sha256, byteCount: original.byteCount, providerVersion: original.providerVersion)
        let provider = Provider(manifests: [wrong], source: fixture.source), assets = try coordinator(fixture, provider: provider)
        do { try await assets.prepare(snapshot: fixture.snapshot, candidateIDs: Set(fixture.snapshot.map { $0.local.id }), in: fixture.context); XCTFail("Wrong identity") }
        catch CarryAccountWorkspaceAssetFailure.wrongAccount { }
        XCTAssertTrue(assets.preparedReadyURLs.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<CarryAccountAssetBinding>()).isEmpty)
        let counts = await provider.counts(); XCTAssertEqual(counts.1, 0)
    }

    func testThumbnailBytesArePreparedOffActorBeforeSynchronousProjection() async throws {
        let fixture = try fixture(thumbnail: true), provider = Provider(manifests: fixture.manifests, source: fixture.source)
        let assets = try coordinator(fixture, provider: provider)
        try await assets.prepare(snapshot: fixture.snapshot, candidateIDs: Set(fixture.snapshot.map { $0.local.id }), in: fixture.context)
        try project(fixture, using: assets)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<ItineraryAttachment>()).first?.thumbnailData, fixture.bytes)
    }

    func testBoundedPreparationResumesWithoutRedownloadingVerifiedAssets() async throws {
        let fixture = try fixture(count: 33), provider = Provider(manifests: fixture.manifests, source: fixture.source)
        let assets = try coordinator(fixture, provider: provider), ids = Set(fixture.snapshot.map { $0.local.id })
        do { try await assets.prepare(snapshot: fixture.snapshot, candidateIDs: ids, in: fixture.context); XCTFail("Bounded continuation expected") }
        catch CarryAccountWorkspaceAssetFailure.preparationPending { }
        XCTAssertEqual(assets.preparedReadyURLs.count, 32)
        try await assets.prepare(snapshot: fixture.snapshot, candidateIDs: ids, in: fixture.context)
        XCTAssertEqual(assets.preparedReadyURLs.count, 33)
        let counts = await provider.counts(); XCTAssertEqual(counts.0, 33); XCTAssertEqual(counts.1, 33)
        try project(fixture, using: assets)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<ItineraryAttachment>()).count, 33)
    }

    func testUnpreparedNewReferenceCannotReuseEarlierReadyBytes() async throws {
        let fixture = try fixture(), provider = Provider(manifests: fixture.manifests, source: fixture.source)
        let assets = try coordinator(fixture, provider: provider)
        try await assets.prepare(snapshot: fixture.snapshot, candidateIDs: Set(fixture.snapshot.map { $0.local.id }), in: fixture.context)
        var entity = try XCTUnwrap(fixture.snapshot.last?.local)
        entity.fields["fileAssetID"] = .string(UUID().uuidString)
        XCTAssertThrowsError(try assets.resolve(entity, existing: nil))
        assets.close()
        XCTAssertTrue(assets.preparedReadyURLs.isEmpty)
        XCTAssertThrowsError(try assets.resolve(fixture.snapshot[0].local, existing: nil))
    }

    func testRejectedRemoteBytesDoNotPoisonImmutableCacheIdentity() async throws {
        let fixture = try fixture(), metadata = try XCTUnwrap(fixture.manifests.first)
        let bad = fixture.directory.appendingPathComponent("bad.bin")
        try Data(repeating: 0x59, count: fixture.bytes.count).write(to: bad)
        do { _ = try await fixture.cache.snapshot(fileURL: bad, assetID: metadata.assetID,
            expectedSHA256: metadata.sha256, expectedByteCount: metadata.byteCount); XCTFail("Corrupt input") }
        catch CarryAccountAssetCacheFailure.invalidSource { }
        let good = try await fixture.cache.snapshot(fileURL: fixture.source, assetID: metadata.assetID,
            expectedSHA256: metadata.sha256, expectedByteCount: metadata.byteCount)
        let file = try await fixture.cache.verify(good)
        XCTAssertEqual(try Data(contentsOf: file), fixture.bytes)
    }

    func testAuthenticatedExpectedBytesCanRepairCorruptSameTokenCache() async throws {
        let fixture = try fixture(), metadata = try XCTUnwrap(fixture.manifests.first)
        let snapshot = try await fixture.cache.snapshot(fileURL: fixture.source, assetID: metadata.assetID,
            expectedSHA256: metadata.sha256, expectedByteCount: metadata.byteCount)
        let file = try await fixture.cache.verify(snapshot)
        try Data(repeating: 0x59, count: fixture.bytes.count).write(to: file, options: .atomic)
        let repaired = try await fixture.cache.snapshot(fileURL: fixture.source, assetID: metadata.assetID,
            expectedSHA256: metadata.sha256, expectedByteCount: metadata.byteCount)
        XCTAssertEqual(repaired.token, snapshot.token)
        let recovered = try await fixture.cache.verify(repaired)
        XCTAssertEqual(try Data(contentsOf: recovered), fixture.bytes)
    }
}
