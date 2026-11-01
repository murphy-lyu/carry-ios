import XCTest
import SwiftData
@testable import Carry

@MainActor
final class TripMigrationTests: XCTestCase {
    private enum Injected: Error { case lostResponse, activationFailed, unexpectedUpload }
    private final class Server: CarryGraphStreamingTransporting {
        var command: CarryGraphCommand?
        var changes: [CarryGraphChange] = []
        var attempts = 0
        var loseAfterPage = false
        var corruptReadback = false
        var onApply: (() -> Void)?
        var startingOffsets: [Int] = []
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
            throw Injected.unexpectedUpload
        }
        func applyStreaming(_ next: CarryGraphCommand, progress: CarryGraphReceiptProgress?,
                            receive: @MainActor (CarryGraphReceiptSummary, CarryGraphReceiptPage, Int) async throws -> Void) async throws {
            attempts += 1
            if let command { XCTAssertEqual(command, next) }
            else {
                command = next
                changes = next.mutations.enumerated().map { offset, mutation in
                    CarryGraphChange(sequence: offset + 1, entity: CarryGraphEntity(id: mutation.id, kind: mutation.kind,
                        parentID: mutation.parentID, version: 1, subtreeVersion: offset + 1, fields: mutation.fields ?? [:],
                        fieldVersions: (mutation.fields ?? [:]).mapValues { _ in 1 }))
                }
            }
            onApply?()
            let offset = progress?.nextOffset ?? 0; startingOffsets.append(offset)
            let summary = CarryGraphReceiptSummary(status: "saved_to_account", requestID: next.requestID,
                cursor: changes.count, changeCount: changes.count)
            for index in offset..<changes.count {
                try await receive(summary, CarryGraphReceiptPage(requestID: next.requestID, cursor: changes.count,
                    changes: [changes[index]], nextOffset: index + 1, hasMore: index + 1 < changes.count, changeCount: changes.count), 100)
                if loseAfterPage { loseAfterPage = false; throw Injected.lostResponse }
            }
        }
        func pull(cursor: Int) async throws -> CarryGraphPage {
            var result = Array(changes.dropFirst(cursor))
            if corruptReadback, let first = result.first {
                var entity = first.entity; entity.fields["name"] = .string("Unexpected remote edit")
                result[0] = CarryGraphChange(sequence: first.sequence, entity: entity)
            }
            return CarryGraphPage(changes: result, cursor: changes.count, hasMore: false)
        }
    }
    private struct Fixture {
        let directory: URL
        let owner: UUID
        let container: ModelContainer
        let engine: CarryAccountTripMigration
        let packet: CarryGraphMigrationPacket
        let fingerprints: [UUID: String]
        let backupURL: URL
    }
    private func fixture(withPhoto: Bool = false, embeddedOriginal: Bool = false, accountID: UUID? = nil) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CarryTripMigration-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let owner = accountID ?? UUID(), container = try CarryAccountReplica.container(at: folder.appendingPathComponent("account.store"))
        _ = try CarryAccountReplica(container: container, accountID: owner)
        let context = ModelContext(container)
        let trip = TripBundle(name: "Synthetic Tokyo", destinationCity: "Tokyo", days: 2,
            sections: [PackingSection(title: "Clothes", items: [PackingItem(name: "Shirt", quantity: 2, isPacked: true)])])
        if withPhoto {
            let day = ItineraryDay(title: "Arrival"), stop = ItineraryStop(name: "Museum")
            let photo = StopPhoto(); photo.assetLocalIdentifier = "synthetic-device-id"
            stop.photos = [photo]; photo.stop = stop; day.stops = [stop]; stop.day = day
            trip.itineraryDays = [day]; day.bundle = trip
        }
        var backup = DataBackupManager.shared.migrationSnapshot(trips: [trip], myItems: [])
        if embeddedOriginal, let photo = trip.safeItineraryDays.first?.stops?.first?.photos?.first {
            backup.photoOriginals = [photo.id.uuidString.lowercased(): Data("Synthetic original bytes".utf8)]
        }
        let encoder = CarryBackupDates.encoder()
        let backupURL = folder.appendingPathComponent("source-backup.json"); try encoder.encode(backup).write(to: backupURL)
        // The portable DTO is decoded exactly as a real persisted JSON backup.
        let decoder = CarryBackupDates.decoder()
        let portable = try decoder.decode(CarryBackup.self, from: Data(contentsOf: backupURL))
        let packet = try CarryGraphMigrationCodec.prepare(portable, accountID: owner, migrationID: UUID(), tripIDs: [trip.id], includeLibrary: false)
        let snapshot = try CarryMigrationSourceSnapshot.capture(trip: trip)
        let fingerprints = [trip.id: try snapshot.fingerprint()]
        let cache = try CarryAccountAssetCache(root: folder.appendingPathComponent("assets"), accountID: owner)
        let engine = try CarryAccountTripMigration(accountID: owner, context: context, cache: cache, backupRoot: folder.appendingPathComponent("backups"))
        return Fixture(directory: folder, owner: owner, container: container, engine: engine, packet: packet,
            fingerprints: fingerprints, backupURL: backupURL)
    }
    private func prepare(_ fixture: Fixture) async throws -> UUID {
        try await fixture.engine.prepare(packet: fixture.packet, sourceFingerprints: fixture.fingerprints, backupURL: fixture.backupURL)
    }
    private func run(_ fixture: Fixture, _ id: UUID, server: Server, source: [UUID: String]? = nil,
                     activate: @escaping @MainActor (CarryAccountMigrationProof, ModelContext) throws -> Void = { proof, context in
                         try CarryAccountTripMigration.validateActivationProof(proof, in: context)
                     }) async throws -> CarryAccountMigrationProof {
        try await fixture.engine.run(batchID: id, transport: server, upload: { _, _ in throw Injected.unexpectedUpload },
            manifest: { _ in throw Injected.unexpectedUpload }, validateSource: { source ?? fixture.fingerprints }, activate: activate)
    }

    func testFullReadbackPrecedesAtomicActivationAndRepeatDoesNotWriteAgain() async throws {
        let fixture = try fixture(), id = try await prepare(fixture), server = Server()
        var activations = 0
        let proof = try await run(fixture, id, server: server, activate: { proof, context in
            try CarryAccountTripMigration.validateActivationProof(proof, in: context)
            activations += 1
        })
        XCTAssertEqual(proof.batchID, id); XCTAssertEqual(proof.tripIDs, Set(fixture.fingerprints.keys))
        XCTAssertEqual(activations, 1); XCTAssertEqual(try fixture.engine.batches().first?.phase, "activated")
        _ = try await run(fixture, id, server: server)
        XCTAssertEqual(server.attempts, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backupURL.path))
    }
    func testLostReceiptResumesItsPersistedOffsetAndSameImmutableCommandAfterReopen() async throws {
        let fixture = try fixture(), id = try await prepare(fixture), server = Server(); server.loseAfterPage = true
        do { _ = try await run(fixture, id, server: server); XCTFail("Lost response") } catch Injected.lostResponse { }
        let first = try XCTUnwrap(fixture.engine.batches().first)
        XCTAssertEqual(first.nextReceiptOffset, 1); XCTAssertTrue(first.publicationStarted)
        let reopened = try CarryAccountTripMigration(accountID: fixture.owner, context: ModelContext(fixture.container),
            cache: CarryAccountAssetCache(root: fixture.directory.appendingPathComponent("assets"), accountID: fixture.owner),
            backupRoot: fixture.directory.appendingPathComponent("backups"))
        _ = try await reopened.run(batchID: id, transport: server, upload: { _, _ in throw Injected.unexpectedUpload },
            manifest: { _ in throw Injected.unexpectedUpload }, validateSource: { fixture.fingerprints }, activate: { _, _ in })
        XCTAssertEqual(server.startingOffsets, [0, 1]); XCTAssertEqual(server.attempts, 2)
    }
    func testSourceChangeStopsBeforePublicationAndRetainsBackup() async throws {
        let fixture = try fixture(), id = try await prepare(fixture), server = Server()
        do { _ = try await run(fixture, id, server: server, source: fixture.fingerprints.mapValues { _ in String(repeating: "b", count: 64) }); XCTFail("Source changed") }
        catch CarryAccountTripMigrationFailure.sourceChanged { }
        XCTAssertEqual(server.attempts, 0); XCTAssertEqual(try fixture.engine.batches().first?.phase, "sourceChanged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backupURL.path))
    }
    func testChangedReadbackDoesNotActivateOrForceOverwriteRemoteEdit() async throws {
        let fixture = try fixture(), id = try await prepare(fixture), server = Server(); server.corruptReadback = true
        var activated = false
        do { _ = try await run(fixture, id, server: server, activate: { _, _ in activated = true }); XCTFail("Readback mismatch") }
        catch CarryAccountTripMigrationFailure.readbackMismatch { }
        XCTAssertFalse(activated); XCTAssertNotEqual(try fixture.engine.batches().first?.phase, "activated")
        XCTAssertEqual(server.attempts, 1)
    }
    func testActivationFailureRollsBackOwnershipAndKeepsConfirmedReceiptForRetry() async throws {
        let fixture = try fixture(), id = try await prepare(fixture), server = Server()
        do { _ = try await run(fixture, id, server: server, activate: { _, _ in throw Injected.activationFailed }); XCTFail("Activation failed") }
        catch Injected.activationFailed { }
        XCTAssertNotEqual(try fixture.engine.batches().first?.phase, "activated")
        _ = try await run(fixture, id, server: server)
        XCTAssertEqual(server.attempts, 1)
    }
    func testIncompleteDurableReceiptCannotAuthorizeOwnershipActivation() async throws {
        let fixture = try fixture(), id = try await prepare(fixture), server = Server()
        let proof = try await run(fixture, id, server: server)
        let batch = try XCTUnwrap(fixture.engine.batches().first)
        batch.receiptCursor += 1
        XCTAssertThrowsError(try CarryAccountTripMigration.validateActivationProof(proof, in: fixture.engine.context))
        batch.receiptCursor = proof.receiptCursor
        batch.lastReceiptSequence -= 1
        XCTAssertThrowsError(try CarryAccountTripMigration.validateActivationProof(proof, in: fixture.engine.context))
        batch.lastReceiptSequence = proof.receiptCursor
        batch.publicationStarted = false
        XCTAssertThrowsError(try CarryAccountTripMigration.validateActivationProof(proof, in: fixture.engine.context))
        fixture.engine.context.rollback()
    }
    func testDevicePhotosIdentifierRequiresActualOriginalBeforeAnyUpload() async throws {
        let fixture = try fixture(withPhoto: true)
        do { _ = try await prepare(fixture); XCTFail("Original required") }
        catch CarryAccountTripMigrationFailure.originalPhotosRequired { }
        XCTAssertTrue(try fixture.engine.batches().isEmpty)
    }
    func testWrongBackupCannotBeAcceptedAsRecoveryMaterial() async throws {
        let fixture = try fixture()
        let wrong = fixture.directory.appendingPathComponent("wrong.json"); try Data("{}".utf8).write(to: wrong)
        do { _ = try await fixture.engine.prepare(packet: fixture.packet, sourceFingerprints: fixture.fingerprints, backupURL: wrong); XCTFail("Invalid backup") }
        catch { }
        XCTAssertTrue(try fixture.engine.batches().isEmpty)
    }
    func testActualHTTPDatabaseMigrationReadsBackEveryFieldBeforeActivation() async throws {
        struct ServerFixture: Decodable { let accountID: UUID; let bearer: String }
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:8891"))
        var request = URLRequest(url: endpoint.appendingPathComponent("__fixture")); request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        let identity = try JSONDecoder().decode(ServerFixture.self, from: data)
        let fixture = try fixture(accountID: identity.accountID), id = try await prepare(fixture)
        let transport = CarryGraphTransport(configuration: CarryAccountConfiguration(projectURL: endpoint,
            publishableKey: "sb_publishable_synthetic_only"), accessToken: { identity.bearer })
        var activated = false
        let proof = try await fixture.engine.run(batchID: id, transport: transport,
            upload: { _, _ in throw Injected.unexpectedUpload }, manifest: { _ in throw Injected.unexpectedUpload },
            validateSource: { fixture.fingerprints }, activate: { proof, context in
                try CarryAccountTripMigration.validateActivationProof(proof, in: context); activated = true
            })
        XCTAssertTrue(activated); XCTAssertGreaterThan(proof.receiptCursor, fixture.packet.entities.count)
        XCTAssertEqual(try fixture.engine.batches().first?.phase, "activated")
    }

    func testEmbeddedOriginalIsArchivedUploadedVerifiedAndPublishedWithPortablePointer() async throws {
        actor Ledger {
            let owner: UUID
            var files: [UUID: CarryAssetDescriptor] = [:]
            init(owner: UUID) { self.owner = owner }
            func upload(_ descriptor: CarryAssetDescriptor, url: URL) throws {
                let bytes = try Data(contentsOf: url)
                guard bytes.count == descriptor.byteCount else { throw Injected.unexpectedUpload }
                files[descriptor.id] = descriptor
            }
            func manifest(_ id: UUID) throws -> CarryAccountAssetManifest {
                guard let file = files[id] else { throw Injected.unexpectedUpload }
                return CarryAccountAssetManifest(accountID: owner, assetID: id, entityID: file.entityID, kind: file.entityKind,
                    slot: file.slot, sha256: file.sha256, byteCount: file.byteCount, providerVersion: UUID())
            }
            func count() -> Int { files.count }
        }
        let fixture = try fixture(withPhoto: true, embeddedOriginal: true), id = try await prepare(fixture)
        // A prepared batch must survive cache eviction: originals are kept in
        // its separately verified immutable recovery archive.
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("assets"))
        let ledger = Ledger(owner: fixture.owner), server = Server()
        _ = try await fixture.engine.run(batchID: id, transport: server,
            upload: { descriptor, url in try await ledger.upload(descriptor, url: url) },
            manifest: { try await ledger.manifest($0) }, validateSource: { fixture.fingerprints }, activate: { _, _ in })
        let uploaded = await ledger.count(); XCTAssertEqual(uploaded, 1)
        let photo = try XCTUnwrap(server.command?.mutations.first { $0.kind == "photo" })
        XCTAssertEqual(photo.fields?["assetLocalIdentifier"], .string("")); XCTAssertNotNil(photo.fields?["originalAssetID"])
        let archive = fixture.directory.appendingPathComponent("backups/" + id.uuidString.lowercased())
        let files = try FileManager.default.contentsOfDirectory(atPath: archive.path)
        XCTAssertTrue(files.contains { $0.hasSuffix(".blob") }); XCTAssertTrue(files.contains { $0.hasPrefix("manifest-") })
    }

    func testReviewedForkRequiresAnExactDurableRecoveryCopyAndDoesNotRewriteCloud() async throws {
        let fixture = try fixture(), id = try await prepare(fixture), server = Server()
        let rootID = try XCTUnwrap(fixture.fingerprints.keys.first)
        var entities = fixture.packet.entities.map { entity in
            CarryMigrationSourceSnapshot.Entity(metadata: CarryNativeSourceMetadata(id: entity.id, kind: entity.kind,
                parentID: entity.parentID, fields: entity.fields, fileReferences: [:]), thumbnailSHA256: nil)
        }
        let rootIndex = try XCTUnwrap(entities.firstIndex { $0.metadata.id == rootID })
        var edited = entities[rootIndex].metadata; edited.fields["name"] = .string("New source edit during publication")
        entities[rootIndex] = .init(metadata: edited, thumbnailSHA256: nil)
        let source = CarryMigrationSourceSnapshot(rootID: rootID, kind: "trip", entities: entities)
        let mapping = Dictionary(uniqueKeysWithValues: entities.map { ($0.metadata.id, UUID()) })
        let copied = entities.map { entity in
            CarryMigrationSourceSnapshot.Entity(metadata: CarryNativeSourceMetadata(id: mapping[entity.metadata.id] ?? UUID(),
                kind: entity.metadata.kind, parentID: entity.metadata.parentID.flatMap { mapping[$0] },
                fields: entity.metadata.fields, fileReferences: entity.metadata.fileReferences), thumbnailSHA256: entity.thumbnailSHA256)
        }
        let copy = CarryMigrationSourceSnapshot(rootID: try XCTUnwrap(mapping[rootID]), kind: "trip", entities: copied)
        let evidence = CarryMigrationRecoveryEvidence(source: source, copy: copy, identityMap: mapping)
        var fingerprints = fixture.fingerprints
        let updated = [rootID: try source.fingerprint()]
        server.onApply = { fingerprints = updated }
        do {
            _ = try await fixture.engine.run(batchID: id, transport: server, upload: { _, _ in throw Injected.unexpectedUpload },
                manifest: { _ in throw Injected.unexpectedUpload }, validateSource: { fingerprints }, activate: { _, _ in XCTFail("Unreviewed fork") })
            XCTFail("Source changed")
        } catch CarryAccountTripMigrationFailure.sourceChanged { }
        XCTAssertEqual(try fixture.engine.batches().first?.phase, "sourceChanged")
        try fixture.engine.approveFork(batchID: id, evidence: [evidence], validateEvidence: { [evidence] })
        _ = try await fixture.engine.run(batchID: id, transport: server, upload: { _, _ in throw Injected.unexpectedUpload },
            manifest: { _ in throw Injected.unexpectedUpload }, validateSource: { fingerprints }, validateRecovery: { [evidence] },
            activate: { proof, context in try CarryAccountTripMigration.validateActivationProof(proof, in: context) })
        XCTAssertEqual(server.attempts, 1)
        XCTAssertEqual(server.command?.mutations.first { $0.id == rootID }?.fields?["name"], .string("Synthetic Tokyo"))
    }

    func testRecoveryEvidenceRejectsPackingStateLossAndManyToOneMappings() throws {
        let root = UUID(), item = UUID(), newRoot = UUID(), newItem = UUID()
        let source = CarryMigrationSourceSnapshot(rootID: root, kind: "trip", entities: [
            .init(metadata: .init(id: root, kind: "trip", parentID: nil, fields: [:], fileReferences: [:]), thumbnailSHA256: nil),
            .init(metadata: .init(id: item, kind: "packingItem", parentID: root, fields: ["isPacked": .bool(true)], fileReferences: [:]), thumbnailSHA256: nil)])
        let copy = CarryMigrationSourceSnapshot(rootID: newRoot, kind: "trip", entities: [
            .init(metadata: .init(id: newRoot, kind: "trip", parentID: nil, fields: [:], fileReferences: [:]), thumbnailSHA256: nil),
            .init(metadata: .init(id: newItem, kind: "packingItem", parentID: newRoot, fields: ["isPacked": .bool(false)], fileReferences: [:]), thumbnailSHA256: nil)])
        XCTAssertThrowsError(try CarryMigrationRecoveryEvidence(source: source, copy: copy, identityMap: [root: newRoot, item: newItem]).validate())
        XCTAssertThrowsError(try CarryMigrationRecoveryEvidence(source: source, copy: copy, identityMap: [root: newRoot, item: newRoot]).validate())
    }

    func testUnknownAccountCannotOpenMigrationContainer() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try CarryAccountTripMigration(accountID: UUID(), context: ModelContext(fixture.container),
            cache: CarryAccountAssetCache(root: fixture.directory.appendingPathComponent("other"), accountID: UUID()),
            backupRoot: fixture.directory.appendingPathComponent("backups")))
    }
}
