import Foundation
import SwiftData
import CryptoKit

@Model
final class CarryAccountMigrationBatch {
    @Attribute(.unique) var id: UUID
    var accountID: UUID
    var phase: String
    var createdAt: Date
    var payload: Data
    var receiptSummaryData: Data?
    var activationProofData: Data?
    var identityData: Data?
    var forkApprovalData: Data?
    var nextReceiptOffset: Int = 0
    var lastReceiptSequence: Int = 0
    var receiptCursor: Int = 0
    var publicationStarted: Bool = false
    var errorCode: String?
    init(id: UUID, accountID: UUID, payload: Data) {
        self.id = id; self.accountID = accountID; self.payload = payload
        phase = "prepared"; createdAt = Date()
    }
}

enum CarryAccountTripMigrationFailure: Error, Equatable {
    case wrongAccount, invalidPlan, originalPhotosRequired, backupMissing, sourceChanged
    case invalidReceipt, readbackMismatch, invalidAsset, busy, cancelled, notFound
}

nonisolated struct CarryMigrationRecoveryEvidence: Codable, Equatable, Sendable {
    let source: CarryMigrationSourceSnapshot
    let copy: CarryMigrationSourceSnapshot
    let identityMap: [UUID: UUID]

    func validate() throws {
        if source.entities.isEmpty || copy.entities.isEmpty {
            guard source.entities.isEmpty, copy.entities.isEmpty, source.rootID == copy.rootID,
                  source.kind == copy.kind, ["trip", "libraryItem"].contains(source.kind), identityMap.isEmpty else {
                throw CarryAccountTripMigrationFailure.invalidPlan
            }
            return
        }
        guard source.kind == copy.kind, source.entityIDs.count == source.entities.count,
              copy.entityIDs.count == copy.entities.count, Set(identityMap.keys) == source.entityIDs,
              Set(identityMap.values) == copy.entityIDs, Set(identityMap.values).count == identityMap.count,
              source.entityIDs.isDisjoint(with: copy.entityIDs), identityMap[source.rootID] == copy.rootID else {
            throw CarryAccountTripMigrationFailure.invalidPlan
        }
        let copied = Dictionary(uniqueKeysWithValues: copy.entities.map { ($0.metadata.id, $0) })
        for entity in source.entities {
            guard let mapped = identityMap[entity.metadata.id], let next = copied[mapped],
                  entity.metadata.kind == next.metadata.kind,
                  entity.metadata.parentID.flatMap({ identityMap[$0] }) == next.metadata.parentID,
                  entity.metadata.fields == next.metadata.fields,
                  entity.metadata.fileReferences == next.metadata.fileReferences,
                  entity.metadata.thumbnailPresent == next.metadata.thumbnailPresent,
                  entity.thumbnailSHA256 == next.thumbnailSHA256 else { throw CarryAccountTripMigrationFailure.readbackMismatch }
        }
    }
}

private nonisolated struct CarryMigrationForkApproval: Codable, Sendable {
    let evidence: [CarryMigrationRecoveryEvidence]
    var sourceFingerprints: [UUID: String] { get throws {
        try Dictionary(uniqueKeysWithValues: evidence.map { ($0.source.rootID, try $0.source.fingerprint()) })
    } }
}

private nonisolated struct CarryMigrationFile: Codable, Sendable {
    let descriptor: CarryAssetDescriptor
    let snapshot: CarryAccountAssetSnapshot
}
private nonisolated struct CarryTripMigrationPlan: Codable, Sendable {
    let accountID: UUID
    let id: UUID
    let sourceFingerprints: [UUID: String]
    let inputGraphDigest: String
    let entities: [CarryGraphEntity]
    let files: [CarryMigrationFile]
    let graphDigest: String
    let assetDigest: String
    let backupName: String
    let backupSHA256: String
    let archiveManifestName: String
    let archiveManifestSHA256: String
}

/// Small immutable identity used by the no-suspension activation transaction.
/// The full graph stays off the UI actor during decoding and hashing.
private nonisolated struct CarryMigrationPlanIdentity: Codable, Sendable {
    let accountID: UUID
    let id: UUID
    let sourceFingerprints: [UUID: String]
    let tripIDs: Set<UUID>
    let libraryIDs: Set<UUID>
    let graphDigest: String
    let assetDigest: String
    init(_ plan: CarryTripMigrationPlan) {
        accountID = plan.accountID; id = plan.id; sourceFingerprints = plan.sourceFingerprints
        tripIDs = Set(plan.entities.filter { $0.kind == "trip" }.map(\.id))
        libraryIDs = Set(plan.entities.filter { $0.kind == "libraryItem" }.map(\.id))
        graphDigest = plan.graphDigest; assetDigest = plan.assetDigest
    }
}

/// A migration is a durable account transaction, not a series of phone edits.
/// It never removes the original store. Its immutable backup/asset snapshots
/// precede every request; ownership changes only after readback and source check.
@MainActor
final class CarryAccountTripMigration {
    static let models: [any PersistentModel.Type] = [CarryAccountMigrationBatch.self]
    let context: ModelContext
    let accountID: UUID
    private let cache: CarryAccountAssetCache
    private let backupRoot: URL
    private var running = false
    private let encoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder }()
    private let decoder = JSONDecoder()

    init(accountID: UUID, context: ModelContext, cache: CarryAccountAssetCache, backupRoot: URL) throws {
        guard cache.accountID == accountID, backupRoot.isFileURL,
              context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else {
            throw CarryAccountTripMigrationFailure.wrongAccount
        }
        let owners = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
        guard owners.count <= 1, owners.allSatisfy({ $0.accountID == accountID }) else {
            throw CarryAccountTripMigrationFailure.wrongAccount
        }
        self.accountID = accountID; self.context = context; self.cache = cache; self.backupRoot = backupRoot
        context.autosaveEnabled = false
    }
    func batches() throws -> [CarryAccountMigrationBatch] {
        let values = try context.fetch(FetchDescriptor<CarryAccountMigrationBatch>())
        guard values.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountTripMigrationFailure.wrongAccount }
        return values.sorted { $0.createdAt < $1.createdAt }
    }
    private func batch(_ id: UUID) throws -> CarryAccountMigrationBatch {
        var query = FetchDescriptor<CarryAccountMigrationBatch>(predicate: #Predicate { $0.id == id }); query.fetchLimit = 1
        guard let value = try context.fetch(query).first, value.accountID == accountID else { throw CarryAccountTripMigrationFailure.notFound }
        return value
    }
    private func save() throws {
        do { try context.save() } catch { context.rollback(); throw error }
    }
    private func set(_ phase: String, on batch: CarryAccountMigrationBatch) throws {
        try Task.checkCancellation(); batch.phase = phase; batch.errorCode = nil; try save()
    }

    func prepare(packet: CarryGraphMigrationPacket, sourceFingerprints: [UUID: String], backupURL: URL,
                 originalPhotos: [UUID: URL] = [:]) async throws -> UUID {
        guard !running else { throw CarryAccountTripMigrationFailure.busy }
        running = true; defer { running = false }
        guard packet.accountID == accountID, !packet.entities.isEmpty, packet.entities.count <= 20000,
              packet.entities.allSatisfy({ $0.version == 0 && $0.deletedAt == nil }),
              Set(packet.entities.map(\.id)).count == packet.entities.count else { throw CarryAccountTripMigrationFailure.invalidPlan }
        let roots = Set(packet.entities.filter { $0.parentID == nil }.map(\.id))
        guard Set(sourceFingerprints.keys) == roots,
              sourceFingerprints.values.allSatisfy(Self.isDigest) else { throw CarryAccountTripMigrationFailure.invalidPlan }
        let originals = Set(packet.photosRequiringOriginalCollection)
        let embeddedOriginals = try await Self.validateBackup(backupURL, packet: packet)
        guard Set(originalPhotos.keys).isSubset(of: originals),
              originals.isSubset(of: Set(originalPhotos.keys).union(embeddedOriginals.keys)) else {
            throw CarryAccountTripMigrationFailure.originalPhotosRequired
        }
        // Validate the complete portable graph and every embedded file before
        // materializing a plan. This is detached from the persistence/UI actor.
        try await Self.validatePacket(packet)
        if let existing = try batches().first(where: { $0.id == packet.migrationID }) {
            let plan = try await Self.decodePlan(existing.payload)
            guard plan.sourceFingerprints == sourceFingerprints,
                  try await Self.graphDigest(packet.entities) == plan.inputGraphDigest else {
                throw CarryAccountTripMigrationFailure.invalidPlan
            }
            return existing.id
        }
        let copied = try await Self.copyBackup(backupURL, to: backupRoot, id: packet.migrationID)
        var files: [CarryMigrationFile] = []
        var entities = packet.entities
        for asset in packet.assets {
            try Task.checkCancellation()
            guard let entity = entities.first(where: { $0.id == asset.entityID }) else { throw CarryAccountTripMigrationFailure.invalidPlan }
            let snapshot = try await cache.snapshot(data: asset.bytes, entityID: asset.entityID, slot: asset.slot)
            guard snapshot.token.assetID == asset.id, snapshot.token.sha256 == asset.sha256 else { throw CarryAccountTripMigrationFailure.invalidAsset }
            files.append(CarryMigrationFile(descriptor: CarryAssetDescriptor(id: asset.id, entityID: asset.entityID,
                entityKind: entity.kind, slot: asset.slot, sha256: asset.sha256, byteCount: asset.bytes.count), snapshot: snapshot))
        }
        for entityID in originals.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            guard let index = entities.firstIndex(where: { $0.id == entityID && $0.kind == "photo" }) else {
                throw CarryAccountTripMigrationFailure.invalidPlan
            }
            let snapshot: CarryAccountAssetSnapshot
            if let source = originalPhotos[entityID] { snapshot = try await cache.snapshot(fileURL: source, entityID: entityID, slot: "original") }
            else if let data = embeddedOriginals[entityID] { snapshot = try await cache.snapshot(data: data, entityID: entityID, slot: "original") }
            else { throw CarryAccountTripMigrationFailure.originalPhotosRequired }
            files.append(CarryMigrationFile(descriptor: CarryAssetDescriptor(id: snapshot.token.assetID, entityID: entityID,
                entityKind: "photo", slot: "original", sha256: snapshot.token.sha256, byteCount: snapshot.byteCount), snapshot: snapshot))
            entities[index].fields["originalAssetID"] = .string(snapshot.token.assetID.uuidString.lowercased())
            // Device Photos IDs are provenance, not a portable original pointer.
            entities[index].fields["assetLocalIdentifier"] = .string("")
        }
        var verifiedPaths: [UUID: URL] = [:]
        for file in files { verifiedPaths[file.descriptor.id] = try await cache.verify(file.snapshot) }
        let archive = try await Self.archiveFiles(files, verifiedPaths: verifiedPaths, root: backupRoot, id: packet.migrationID)
        let graphDigest = try await Self.graphDigest(entities)
        let assetDigest = try await Self.fileDigest(files)
        let plan = CarryTripMigrationPlan(accountID: accountID, id: packet.migrationID, sourceFingerprints: sourceFingerprints, inputGraphDigest: try await Self.graphDigest(packet.entities),
            entities: entities, files: files, graphDigest: graphDigest, assetDigest: assetDigest,
            backupName: copied.name, backupSHA256: copied.digest,
            archiveManifestName: archive.name, archiveManifestSHA256: archive.digest)
        let data = try await Self.encodePlan(plan)
        try Task.checkCancellation()
        let record = CarryAccountMigrationBatch(id: plan.id, accountID: accountID, payload: data)
        record.identityData = try encodedIdentity(plan)
        context.insert(record)
        try save()
        return plan.id
    }

    /// Resuming reuses the same immutable command and receipt offset. Lost
    /// responses cannot create duplicates or silently adopt another account.
    func run(batchID: UUID, transport: any CarryGraphStreamingTransporting,
             upload: @Sendable (CarryAssetDescriptor, URL) async throws -> Void,
             manifest: @Sendable (UUID) async throws -> CarryAccountAssetManifest,
             validateSource: () throws -> [UUID: String],
             validateRecovery: (() throws -> [CarryMigrationRecoveryEvidence])? = nil,
             activate: (CarryAccountMigrationProof, ModelContext) throws -> Void) async throws -> CarryAccountMigrationProof {
        guard !running else { throw CarryAccountTripMigrationFailure.busy }
        running = true; defer { running = false }
        let record = try batch(batchID), plan = try await Self.decodePlan(record.payload)
        guard record.phase != "cancelled" else { throw CarryAccountTripMigrationFailure.cancelled }
        guard plan.accountID == accountID, plan.id == batchID,
              plan.graphDigest == (try await Self.graphDigest(plan.entities)),
              plan.assetDigest == (try await Self.fileDigest(plan.files)) else { throw CarryAccountTripMigrationFailure.invalidPlan }
        if record.phase == "activated", let bytes = record.activationProofData {
            let proof = try decoder.decode(CarryAccountMigrationProof.self, from: bytes)
            try Self.validateActivationProof(proof, in: context)
            return proof
        }
        try await Self.verifyBackup(backupRoot.appendingPathComponent(plan.backupName), digest: plan.backupSHA256)
        try await Self.verifyArchive(plan, root: backupRoot)
        try validateCurrentSource(plan: plan, record: record, validateSource: validateSource, validateRecovery: validateRecovery)
        do {
            if record.receiptSummaryData == nil {
                try set("uploading", on: record)
                for file in plan.files {
                    try Task.checkCancellation()
                    // Recovery uploads use the verified durable archive. Cache
                    // eviction must not make a prepared migration unrecoverable.
                    let url = backupRoot.appendingPathComponent(plan.id.uuidString.lowercased(), isDirectory: true)
                        .appendingPathComponent(file.descriptor.id.uuidString.lowercased() + ".blob")
                    try await upload(file.descriptor, url)
                }
            }
            try validateCurrentSource(plan: plan, record: record, validateSource: validateSource, validateRecovery: validateRecovery)
            var summary = try record.receiptSummaryData.map { try decoder.decode(CarryGraphReceiptSummary.self, from: $0) }
            if summary == nil || record.nextReceiptOffset < (summary?.changeCount ?? 0) {
                record.publicationStarted = true
                try set("publishing", on: record)
                let progress = summary.map { CarryGraphReceiptProgress(requestID: $0.requestID, cursor: $0.cursor,
                    changeCount: $0.changeCount, nextOffset: record.nextReceiptOffset) }
                let command = CarryGraphCommand(requestID: plan.id, mutations: plan.entities.map {
                    CarryGraphMutation(id: $0.id, kind: $0.kind, action: "create", baseVersion: 0, parentID: $0.parentID, fields: $0.fields)
                })
                try await transport.applyStreaming(command, progress: progress) { received, page, _ in
                    try Task.checkCancellation()
                    guard received.requestID == plan.id, received.status == "saved_to_account", received.changeCount > 0,
                          received.cursor >= received.changeCount, summary == nil || summary == received,
                          page.requestID == plan.id, page.cursor == received.cursor, page.changeCount == received.changeCount,
                          page.nextOffset == record.nextReceiptOffset + page.changes.count,
                          page.nextOffset <= received.changeCount, page.hasMore == (page.nextOffset < received.changeCount),
                          !page.changes.isEmpty else { throw CarryAccountTripMigrationFailure.invalidReceipt }
                    var sequence = record.lastReceiptSequence
                    for change in page.changes {
                        guard change.sequence > sequence, change.entity.subtreeVersion == change.sequence else { throw CarryAccountTripMigrationFailure.invalidReceipt }
                        sequence = change.sequence
                    }
                    summary = received; record.receiptSummaryData = try self.encoder.encode(received)
                    record.nextReceiptOffset = page.nextOffset; record.lastReceiptSequence = sequence
                    record.receiptCursor = received.cursor; try self.save()
                }
            }
            guard let summary, record.nextReceiptOffset == summary.changeCount else { throw CarryAccountTripMigrationFailure.invalidReceipt }
            try set("verifying", on: record)
            let actual = try await readBack(plan: plan, transport: transport)
            guard try await Self.graphDigest(actual) == plan.graphDigest else { throw CarryAccountTripMigrationFailure.readbackMismatch }
            for file in plan.files {
                try Task.checkCancellation()
                let current = try await manifest(file.descriptor.id)
                guard current.accountID == accountID, current.assetID == file.descriptor.id,
                      current.entityID == file.descriptor.entityID, current.kind == file.descriptor.entityKind,
                      current.slot == file.descriptor.slot, current.sha256 == file.descriptor.sha256,
                      current.byteCount == file.descriptor.byteCount else { throw CarryAccountTripMigrationFailure.invalidAsset }
            }
            try Task.checkCancellation()
            try validateCurrentSource(plan: plan, record: record, validateSource: validateSource, validateRecovery: validateRecovery)
            let proof = CarryAccountMigrationProof(accountID: accountID, batchID: batchID,
                tripIDs: Set(plan.entities.filter { $0.kind == "trip" }.map(\.id)),
                libraryIDs: Set(plan.entities.filter { $0.kind == "libraryItem" }.map(\.id)),
                sourceFingerprints: plan.sourceFingerprints, graphDigest: plan.graphDigest,
                receiptCursor: summary.cursor, assetDigest: plan.assetDigest)
            // No suspension between final source check, activation and save.
            record.phase = "verified"; record.errorCode = nil
            do {
                try activate(proof, context)
                record.activationProofData = try encoder.encode(proof)
                record.phase = "activated"; try save()
            }
            catch { context.rollback(); throw error }
            return proof
        } catch {
            // A failed receipt save is uncertain. Its immutable request remains
            // retryable; never remove uploaded bytes or guess success locally.
            let latest = try batch(batchID)
            latest.errorCode = error is CancellationError ? "cancelled" :
                (error as? CarryAccountTripMigrationFailure == .sourceChanged ? "source_changed" : "migration_failed")
            if error as? CarryAccountTripMigrationFailure == .sourceChanged { latest.phase = "sourceChanged" }
            try save()
            throw error
        }
    }

    func approveFork(batchID: UUID, evidence: [CarryMigrationRecoveryEvidence],
                     validateEvidence: () throws -> [CarryMigrationRecoveryEvidence]) throws {
        guard !running else { throw CarryAccountTripMigrationFailure.busy }
        let record = try batch(batchID)
        guard record.phase == "sourceChanged", record.publicationStarted, !evidence.isEmpty,
              Set(evidence.map { $0.source.rootID }).count == evidence.count else { throw CarryAccountTripMigrationFailure.invalidPlan }
        let sorted = evidence.sorted { $0.source.rootID.uuidString < $1.source.rootID.uuidString }
        guard try validateEvidence().sorted(by: { $0.source.rootID.uuidString < $1.source.rootID.uuidString }) == sorted else {
            throw CarryAccountTripMigrationFailure.sourceChanged
        }
        let identity = try Self.identity(record)
        guard Set(sorted.map { $0.source.rootID }) == Set(identity.sourceFingerprints.keys) else { throw CarryAccountTripMigrationFailure.invalidPlan }
        for item in sorted { try item.validate() }
        record.forkApprovalData = try encoder.encode(CarryMigrationForkApproval(evidence: sorted))
        record.errorCode = nil
        try save()
    }

    func approvedRecoveryEvidence(batchID: UUID) throws -> [CarryMigrationRecoveryEvidence]? {
        try batch(batchID).forkApprovalData.map { try decoder.decode(CarryMigrationForkApproval.self, from: $0).evidence }
    }
    private func validateCurrentSource(plan: CarryTripMigrationPlan, record: CarryAccountMigrationBatch,
                                       validateSource: () throws -> [UUID: String],
                                       validateRecovery: (() throws -> [CarryMigrationRecoveryEvidence])?) throws {
        let current = try validateSource()
        if let bytes = record.forkApprovalData {
            let approval = try decoder.decode(CarryMigrationForkApproval.self, from: bytes)
            guard current == (try approval.sourceFingerprints), let validateRecovery,
                  try validateRecovery().sorted(by: { $0.source.rootID.uuidString < $1.source.rootID.uuidString }) == approval.evidence else {
                record.phase = "sourceChanged"; try save(); throw CarryAccountTripMigrationFailure.sourceChanged
            }
            for item in approval.evidence { try item.validate() }
        } else if current != plan.sourceFingerprints {
            record.phase = "sourceChanged"; try save(); throw CarryAccountTripMigrationFailure.sourceChanged
        }
    }

    private func readBack(plan: CarryTripMigrationPlan, transport: any CarryGraphTransporting) async throws -> [CarryGraphEntity] {
        var cursor = 0, graph: [UUID: CarryGraphEntity] = [:]
        for _ in 0..<10000 {
            try Task.checkCancellation()
            let page = try await transport.pull(cursor: cursor)
            guard !page.hasMore || !page.changes.isEmpty else { throw CarryAccountTripMigrationFailure.invalidReceipt }
            for change in page.changes {
                guard change.sequence == cursor + 1, change.entity.subtreeVersion == change.sequence else {
                    throw CarryAccountTripMigrationFailure.invalidReceipt
                }
                cursor = change.sequence
                var incoming = change.entity
                if change.metadataOnly == true {
                    guard incoming.fields.isEmpty, incoming.fieldVersions.isEmpty,
                          let known = graph[incoming.id], known.kind == incoming.kind, known.version == incoming.version,
                          known.parentID == incoming.parentID, known.deletedAt == incoming.deletedAt,
                          known.deletionBatch == incoming.deletionBatch else { throw CarryAccountTripMigrationFailure.invalidReceipt }
                    incoming.fields = known.fields; incoming.fieldVersions = known.fieldVersions
                }
                graph[incoming.id] = incoming
                guard graph.count <= 100000 else { throw CarryAccountTripMigrationFailure.invalidPlan }
            }
            guard page.cursor == cursor else { throw CarryAccountTripMigrationFailure.invalidReceipt }
            if !page.hasMore {
                let roots = Set(plan.entities.filter { $0.parentID == nil }.map(\.id))
                return try await Self.selectedGraph(graph, roots: roots)
            }
        }
        throw CarryAccountTripMigrationFailure.readbackMismatch
    }

    @concurrent nonisolated private static func selectedGraph(_ graph: [UUID: CarryGraphEntity], roots: Set<UUID>) async throws -> [CarryGraphEntity] {
        var selected: [CarryGraphEntity] = []
        for value in graph.values where value.deletedAt == nil {
            try Task.checkCancellation()
            var node: CarryGraphEntity? = value, seen = Set<UUID>()
            while let current = node {
                guard seen.insert(current.id).inserted else { throw CarryAccountTripMigrationFailure.invalidReceipt }
                if roots.contains(current.id) { selected.append(value); break }
                node = current.parentID.flatMap { graph[$0] }
            }
        }
        return selected
    }

    static func validateActivationProof(_ proof: CarryAccountMigrationProof, in context: ModelContext) throws {
        let id = proof.batchID
        var query = FetchDescriptor<CarryAccountMigrationBatch>(predicate: #Predicate { $0.id == id }); query.fetchLimit = 1
        guard let record = try context.fetch(query).first,
              ["verified", "activated"].contains(record.phase), record.accountID == proof.accountID,
              let summaryData = record.receiptSummaryData else { throw CarryAccountTripMigrationFailure.invalidReceipt }
        let plan = try identity(record)
        let receipt = try JSONDecoder().decode(CarryGraphReceiptSummary.self, from: summaryData)
        guard plan.accountID == proof.accountID, plan.id == proof.batchID,
              plan.graphDigest == proof.graphDigest, plan.assetDigest == proof.assetDigest,
              plan.sourceFingerprints == proof.sourceFingerprints, receipt.requestID == proof.batchID,
              receipt.cursor == proof.receiptCursor, receipt.status == "saved_to_account",
              record.publicationStarted, receipt.changeCount > 0, receipt.cursor >= receipt.changeCount,
              record.nextReceiptOffset == receipt.changeCount, record.receiptCursor == receipt.cursor,
              record.lastReceiptSequence == receipt.cursor,
              plan.tripIDs == proof.tripIDs, plan.libraryIDs == proof.libraryIDs else {
            throw CarryAccountTripMigrationFailure.invalidReceipt
        }
    }

    @concurrent nonisolated static func retainedTokens(payloads: [Data]) async throws -> Set<CarryAccountAssetToken> {
        try payloads.reduce(into: Set<CarryAccountAssetToken>()) { result, bytes in
            let plan = try JSONDecoder().decode(CarryTripMigrationPlan.self, from: bytes)
            guard plan.files.allSatisfy({ $0.snapshot.token.accountID == plan.accountID }) else { throw CarryAccountTripMigrationFailure.wrongAccount }
            result.formUnion(plan.files.map { $0.snapshot.token })
        }
    }

    @concurrent nonisolated private static func validateBackup(_ source: URL, packet: CarryGraphMigrationPacket) async throws -> [UUID: Data] {
        _ = try digestFile(source)
        let decoder = CarryBackupDates.decoder()
        let backup = try decoder.decode(CarryBackup.self, from: Data(contentsOf: source, options: .mappedIfSafe))
        let roots = Set(packet.entities.filter { $0.kind == "trip" }.map(\.id))
        let restored = try CarryGraphMigrationCodec.prepare(backup, accountID: packet.accountID, migrationID: packet.migrationID,
            tripIDs: roots, includeLibrary: packet.entities.contains { $0.kind == "libraryItem" })
        let restoredDigest = try await graphDigest(restored.entities)
        let packetDigest = try await graphDigest(packet.entities)
        guard restoredDigest == packetDigest,
              Dictionary(uniqueKeysWithValues: restored.assets.map { ($0.id, $0.sha256) }) ==
                Dictionary(uniqueKeysWithValues: packet.assets.map { ($0.id, $0.sha256) }) else {
            throw CarryAccountTripMigrationFailure.backupMissing
        }
        var result: [UUID: Data] = [:]
        let photos = Set(packet.entities.filter { $0.kind == "photo" }.map(\.id))
        for (key, data) in backup.photoOriginals ?? [:] {
            guard let id = UUID(uuidString: key), key == id.uuidString.lowercased(), !data.isEmpty,
                  data.count <= CarryAccountAssetCache.maximumBytes else { throw CarryAccountTripMigrationFailure.invalidAsset }
            if photos.contains(id) { result[id] = data }
        }
        for entry in backup.assetManifest ?? [] where entry.slot == "original" && photos.contains(entry.entityID) {
            guard let data = result[entry.entityID], entry.byteCount == data.count, entry.sha256 == hash(data) else { throw CarryAccountTripMigrationFailure.invalidAsset }
        }
        return result
    }

    private nonisolated static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = CarryBackupDates.encoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    @concurrent nonisolated private static func graphDigest(_ values: [CarryGraphEntity]) async throws -> String {
        // Versions are transport concurrency metadata, not a lossy substitute
        // for checking every native field and every exact parent relation.
        let normalized = values.sorted { $0.id.uuidString < $1.id.uuidString }.map { entity in
            CarryGraphEntity(id: entity.id, kind: entity.kind, parentID: entity.parentID,
                version: 0, subtreeVersion: 0, fields: entity.fields, fieldVersions: [:])
        }
        return try hash(encoded(normalized))
    }
    @concurrent nonisolated private static func fileDigest(_ files: [CarryMigrationFile]) async throws -> String {
        try hash(encoded(files.sorted { $0.descriptor.id.uuidString < $1.descriptor.id.uuidString }))
    }
    @concurrent nonisolated private static func encodePlan(_ plan: CarryTripMigrationPlan) async throws -> Data { try encoded(plan) }
    @concurrent nonisolated private static func decodePlan(_ data: Data) async throws -> CarryTripMigrationPlan {
        try Task.checkCancellation()
        return try JSONDecoder().decode(CarryTripMigrationPlan.self, from: data)
    }
    private func encodedIdentity(_ plan: CarryTripMigrationPlan) throws -> Data {
        try encoder.encode(CarryMigrationPlanIdentity(plan))
    }
    private static func identity(_ record: CarryAccountMigrationBatch) throws -> CarryMigrationPlanIdentity {
        if let data = record.identityData { return try JSONDecoder().decode(CarryMigrationPlanIdentity.self, from: data) }
        // Compatibility with interrupted development batches written before the
        // small identity index existed; new batches never decode their graph here.
        return CarryMigrationPlanIdentity(try JSONDecoder().decode(CarryTripMigrationPlan.self, from: record.payload))
    }
    @concurrent nonisolated private static func validatePacket(_ packet: CarryGraphMigrationPacket) async throws {
        _ = try CarryGraphMigrationCodec.restore(packet, accountID: packet.accountID)
    }
    @concurrent nonisolated private static func verifyBackup(_ url: URL, digest: String) async throws {
        guard try digestFile(url) == digest else { throw CarryAccountTripMigrationFailure.backupMissing }
    }
    private nonisolated static func digestFile(_ url: URL) throws -> String {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let count = info.fileSize,
              count > 0, count <= 1024 * 1024 * 1024 else { throw CarryAccountTripMigrationFailure.backupMissing }
        let handle = try FileHandle(forReadingFrom: url)
        var result = SHA256(), total = 0
        do {
            while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
                try Task.checkCancellation(); total += bytes.count
                guard total <= count else { throw CarryAccountTripMigrationFailure.backupMissing }
                result.update(data: bytes)
            }
            try handle.close()
        } catch {
            do { try handle.close() } catch { /* Preserve the original verification failure. */ }
            throw error
        }
        guard total == count else { throw CarryAccountTripMigrationFailure.backupMissing }
        return result.finalize().map { String(format: "%02x", $0) }.joined()
    }
    @concurrent nonisolated private static func archiveFiles(_ files: [CarryMigrationFile], verifiedPaths: [UUID: URL], root: URL,
                                                            id: UUID) async throws -> (name: String, digest: String) {
        let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CarryAccountTripMigrationFailure.backupMissing }
        for file in files {
            try Task.checkCancellation()
            guard let source = verifiedPaths[file.descriptor.id] else { throw CarryAccountTripMigrationFailure.backupMissing }
            let target = folder.appendingPathComponent(file.descriptor.id.uuidString.lowercased() + ".blob")
            if !FileManager.default.fileExists(atPath: target.path) {
                // Link immutable bytes when possible; copying is only a fallback
                // across filesystems. The archive is independent of cache GC.
                do { try FileManager.default.linkItem(at: source, to: target) }
                catch { try FileManager.default.copyItem(at: source, to: target) }
            }
            guard try digestFile(target) == file.descriptor.sha256 else { throw CarryAccountTripMigrationFailure.backupMissing }
        }
        let data = try encoded(files.sorted { $0.descriptor.id.uuidString < $1.descriptor.id.uuidString }.map(\.descriptor))
        let digest = hash(data), name = id.uuidString.lowercased() + "/manifest-" + digest + ".json"
        let manifest = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard try digestFile(manifest) == digest else { throw CarryAccountTripMigrationFailure.backupMissing }
        } else {
            try data.write(to: manifest, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: manifest.path)
        }
        return (name, digest)
    }
    @concurrent nonisolated private static func verifyArchive(_ plan: CarryTripMigrationPlan, root: URL) async throws {
        guard try digestFile(root.appendingPathComponent(plan.archiveManifestName)) == plan.archiveManifestSHA256 else {
            throw CarryAccountTripMigrationFailure.backupMissing
        }
        for file in plan.files {
            let path = root.appendingPathComponent(plan.id.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(file.descriptor.id.uuidString.lowercased() + ".blob")
            guard try digestFile(path) == file.descriptor.sha256 else { throw CarryAccountTripMigrationFailure.backupMissing }
        }
    }

    @concurrent nonisolated private static func copyBackup(_ source: URL, to root: URL, id: UUID) async throws -> (name: String, digest: String) {
        guard source.isFileURL, root.isFileURL else { throw CarryAccountTripMigrationFailure.backupMissing }
        let digest = try digestFile(source)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw CarryAccountTripMigrationFailure.backupMissing }
        let name = id.uuidString.lowercased() + "-" + digest + ".json", destination = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try digestFile(destination) == digest else { throw CarryAccountTripMigrationFailure.backupMissing }
        } else {
            let stage = root.appendingPathComponent(".stage-" + UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: source, to: stage)
                guard try digestFile(stage) == digest else { throw CarryAccountTripMigrationFailure.backupMissing }
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: stage.path)
                try FileManager.default.moveItem(at: stage, to: destination)
            } catch {
                if FileManager.default.fileExists(atPath: stage.path) {
                    do { try FileManager.default.removeItem(at: stage) }
                    catch { Task { @MainActor in CarryLogger.shared.log(.persistFailed, context: "migration_backup_stage_cleanup") } }
                }
                throw error
            }
        }
        return (name, digest)
    }
}
