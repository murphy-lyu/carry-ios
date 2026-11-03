import Foundation
import SwiftData
import CryptoKit

@Model
final class CarryAccountLocalAdoptionRecord {
    @Attribute(.unique) var rootID: UUID
    var id: UUID
    var accountID: UUID
    var kind: String
    var phase: String
    var reviewData: Data
    var recoveryData: Data?
    var archiveData: Data
    init(review: CarryLocalAdoptionReview, archive: Data) throws {
        rootID = review.source.rootID; id = review.id; accountID = review.accountID; kind = review.source.kind
        phase = "staged"; reviewData = try JSONEncoder().encode(review); archiveData = archive
    }
}

nonisolated struct CarryLocalAdoptionReview: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let accountID: UUID
    let source: CarryMigrationSourceSnapshot
    let account: CarryMigrationSourceSnapshot
    let observed: [CarryGraphEntity]
    let assets: [Asset]
    struct Asset: Codable, Equatable, Sendable {
        let entityID: UUID
        let kind: String
        let slot: String
        let token: CarryAccountAssetToken
        let byteCount: Int
    }
}

/// A local adoption never calls apply/synchronize. Its evidence comes from an
/// already authenticated, completely materialized account snapshot.
@MainActor
final class CarryAccountLocalAdoption {
    static let models: [any PersistentModel.Type] = [CarryAccountLocalAdoptionRecord.self]
    let accountID: UUID
    let context: ModelContext
    private let recoveryNamespace: UUID
    init(accountID: UUID, context: ModelContext) throws {
        guard context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else { throw CarryMigrationOwnershipFailure.wrongAccount }
        let owners = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
        guard owners.count == 1, owners[0].accountID == accountID else { throw CarryMigrationOwnershipFailure.wrongAccount }
        let metadata = ModelContext(context.container); metadata.autosaveEnabled = false
        guard let checkpoint = try metadata.fetch(FetchDescriptor<CarryReplicaCheckpoint>()).first, checkpoint.accountID == accountID else { throw CarryMigrationOwnershipFailure.wrongAccount }
        if let namespace = checkpoint.localRecoveryNamespace { recoveryNamespace = namespace }
        else {
            let namespace = UUID(); checkpoint.localRecoveryNamespace = namespace
            try metadata.save(); recoveryNamespace = namespace
        }
        self.accountID = accountID; self.context = context; context.autosaveEnabled = false
    }
    func records() throws -> [CarryAccountLocalAdoptionRecord] {
        let rows = try context.fetch(FetchDescriptor<CarryAccountLocalAdoptionRecord>())
        guard rows.allSatisfy({ $0.accountID == accountID }) else { throw CarryMigrationOwnershipFailure.wrongAccount }
        for row in rows {
            let review = try JSONDecoder().decode(CarryLocalAdoptionReview.self, from: row.reviewData)
            guard row.id == review.id, row.rootID == review.source.rootID, row.kind == review.source.kind,
                  review.accountID == accountID, ["trip", "libraryItem"].contains(row.kind), ["staged", "activated"].contains(row.phase) else { throw CarryMigrationOwnershipFailure.invalidState }
            _ = try JSONDecoder().decode(CarryLocalAdoptionArchive.self, from: row.archiveData)
            if row.phase == "activated" {
                guard let bytes = row.recoveryData else { throw CarryMigrationOwnershipFailure.invalidProof }
                let evidence = try JSONDecoder().decode(CarryMigrationRecoveryEvidence.self, from: bytes)
                guard evidence.source == review.source else { throw CarryMigrationOwnershipFailure.invalidProof }
                try evidence.validate()
            }
        }
        return rows
    }
    func review(source: CarryMigrationSourceSnapshot) throws -> CarryLocalAdoptionReview {
        let replica = try CarryAccountReplica(container: context.container, accountID: accountID)
        let all = try replica.projectionSnapshot(rootID: source.rootID)
        let account = try Self.capture(rootID: source.rootID, kind: source.kind, context: context)
        let graph = Dictionary(uniqueKeysWithValues: all.map { ($0.local.id, $0) })
        var selected: [CarryGraphEntity] = []
        for value in all where value.local.deletedAt == nil {
            var node: CarryGraphEntity? = value.local, visited = Set<UUID>()
            while let current = node {
                guard visited.insert(current.id).inserted else { throw CarryMigrationOwnershipFailure.invalidState }
                if current.id == source.rootID {
                    guard let observed = value.observed, value.local == observed else { throw CarryMigrationOwnershipFailure.sourceChanged }
                    selected.append(observed); break
                }
                node = current.parentID.flatMap { graph[$0]?.local }
            }
        }
        guard Set(selected.map(\.id)) == account.entityIDs,
              selected.first(where: { $0.id == source.rootID })?.kind == source.kind else { throw CarryMigrationOwnershipFailure.invalidScope }
        let ids = Array(account.entityIDs)
        var changes: [CarryNativeChange] = [], materializedRows: [CarryNativeMaterialization] = []
        var bindings: [CarryAccountAssetBinding] = [], jobRows: [CarryAccountAssetJob] = []
        for offset in stride(from: 0, to: ids.count, by: 256) {
            let scope = Array(ids[offset..<min(offset + 256, ids.count)])
            changes += try context.fetch(FetchDescriptor<CarryNativeChange>(predicate: #Predicate { scope.contains($0.entityID) }))
            materializedRows += try context.fetch(FetchDescriptor<CarryNativeMaterialization>(predicate: #Predicate { scope.contains($0.id) }))
            bindings += try context.fetch(FetchDescriptor<CarryAccountAssetBinding>(predicate: #Predicate { scope.contains($0.entityID) }))
            jobRows += try context.fetch(FetchDescriptor<CarryAccountAssetJob>(predicate: #Predicate { scope.contains($0.entityID) }))
        }
        guard changes.isEmpty else { throw CarryMigrationOwnershipFailure.sourceChanged }
        let materialized = Dictionary(uniqueKeysWithValues: materializedRows.map { ($0.id, $0) })
        for entity in account.entities {
            guard let baseline = materialized[entity.metadata.id], !baseline.locallyDeleted,
                  let observed = baseline.observedGraphData,
                  try JSONDecoder().decode(CarryGraphEntity.self, from: observed) == selected.first(where: { $0.id == entity.metadata.id }),
                  try JSONDecoder().decode(CarryNativeSourceMetadata.self, from: baseline.sourceData) == entity.metadata,
                  Self.thumbnailHash(baseline.thumbnailData) == entity.thumbnailSHA256 else { throw CarryMigrationOwnershipFailure.sourceChanged }
        }
        let jobs = Dictionary(uniqueKeysWithValues: jobRows.map { ($0.assetID, $0) })
        var assets: [CarryLocalAdoptionReview.Asset] = []
        for entity in selected {
            var references: [String: UUID] = [:]
            func add(_ value: CarryGraphValue?, slot: String) throws {
                guard let value, value != .null else { return }
                guard case .string(let raw) = value, let id = UUID(uuidString: raw) else { throw CarryMigrationOwnershipFailure.invalidState }
                references[slot] = id
            }
            try add(entity.fields["fileAssetID"], slot: "file")
            try add(entity.fields["thumbnailAssetID"], slot: "thumbnail")
            try add(entity.fields["originalAssetID"], slot: "original")
            if let value = entity.fields["backgroundAssetIDs"], value != .null {
                guard case .object(let backgrounds) = value, entity.kind == "trip" else { throw CarryMigrationOwnershipFailure.invalidProof }
                for (slot, value) in backgrounds { try add(value, slot: slot) }
            }
            guard let native = account.entities.first(where: { $0.metadata.id == entity.id }), native.metadata.kind == entity.kind,
                  native.metadata.parentID == entity.parentID else { throw CarryMigrationOwnershipFailure.invalidProof }
            var nativeFiles = native.metadata.fileReferences
            if entity.kind == "photo" {
                guard case .string(let original) = native.metadata.fields["assetLocalIdentifier"], CarryAccountFileAccess.isAccountReference(original), references["original"] != nil else { throw CarryMigrationOwnershipFailure.invalidProof }
                nativeFiles["original"] = original
            }
            let expectedSlots = Set(nativeFiles.keys).union(native.metadata.thumbnailPresent == true ? ["thumbnail"] : [])
            guard Set(references.keys) == expectedSlots else { throw CarryMigrationOwnershipFailure.invalidProof }
            for (slot, id) in references {
                guard let binding = bindings.first(where: { $0.entityID == entity.id && $0.slot == slot }), binding.accountID == accountID,
                      binding.entityKind == entity.kind, binding.assetID == id, let job = jobs[id], job.accountID == accountID,
                      job.entityID == entity.id, job.entityKind == entity.kind, job.slot == slot, job.phase == "verified" else { throw CarryMigrationOwnershipFailure.invalidState }
                let token = try CarryAccountAssetToken(rawValue: job.fileToken)
                guard token.accountID == accountID, token.assetID == id, token.sha256 == job.sha256,
                      try CarryAccountAssetIdentity.id(accountID: accountID, entityID: entity.id, slot: slot, sha256: job.sha256) == id else { throw CarryMigrationOwnershipFailure.invalidProof }
                if slot == "thumbnail" {
                    guard native.thumbnailSHA256 == token.sha256 else { throw CarryMigrationOwnershipFailure.invalidProof }
                } else {
                    guard nativeFiles[slot] == token.rawValue, binding.sourceReference == token.rawValue else { throw CarryMigrationOwnershipFailure.invalidProof }
                }
                assets.append(.init(entityID: entity.id, kind: entity.kind, slot: slot, token: token, byteCount: job.byteCount))
            }
        }
        let id = CarryMigrationSourceSnapshot.recoveryID(batchID: recoveryNamespace, sourceFingerprint: try source.fingerprint(), entityID: source.rootID)
        return .init(id: id, accountID: accountID, source: source, account: account,
                     observed: selected.sorted { $0.id.uuidString < $1.id.uuidString }, assets: assets.sorted { $0.token.rawValue < $1.token.rawValue })
    }
    struct Verified {
        fileprivate let review: CarryLocalAdoptionReview
    }
    func verify(_ review: CarryLocalAdoptionReview, cache: CarryAccountAssetCache) async throws -> Verified {
        guard review.accountID == accountID, cache.accountID == accountID, try self.review(source: review.source) == review else { throw CarryMigrationOwnershipFailure.sourceChanged }
        for asset in review.assets { _ = try await cache.verify(CarryAccountAssetSnapshot(token: asset.token, byteCount: asset.byteCount)) }
        try Task.checkCancellation()
        let fresh = try CarryAccountLocalAdoption(accountID: accountID, context: ModelContext(context.container))
        guard try fresh.review(source: review.source) == review else { throw CarryMigrationOwnershipFailure.sourceChanged }
        return Verified(review: review)
    }
    func stage(_ review: CarryLocalAdoptionReview, archive: CarryLocalAdoptionArchive.Verified) throws {
        guard archive.sourceFingerprint == (try review.source.fingerprint()) else { throw CarryMigrationOwnershipFailure.invalidProof }
        let archive = try JSONEncoder().encode(archive.descriptor)
        guard review.accountID == accountID else { throw CarryMigrationOwnershipFailure.wrongAccount }
        if let previous = try records().first(where: { $0.rootID == review.source.rootID }) {
            guard previous.phase != "activated" else { throw CarryMigrationOwnershipFailure.invalidState }
            if try JSONDecoder().decode(CarryLocalAdoptionReview.self, from: previous.reviewData) == review { return }
            previous.id = review.id; previous.kind = review.source.kind
            previous.reviewData = try JSONEncoder().encode(review); previous.archiveData = archive; previous.recoveryData = nil
            try context.save(); return
        }
        context.insert(try CarryAccountLocalAdoptionRecord(review: review, archive: archive))
        try context.save()
    }
    func activate(_ verified: Verified, evidence: CarryMigrationRecoveryEvidence, validateSource: () throws -> CarryMigrationSourceSnapshot,
                  validateCopy: () throws -> CarryMigrationSourceSnapshot) throws {
        let review = verified.review
        guard try self.review(source: review.source) == review, try validateSource() == review.source,
              evidence.source == review.source, try validateCopy() == evidence.copy else { throw CarryMigrationOwnershipFailure.sourceChanged }
        try evidence.validate()
        guard let row = try records().first(where: { $0.id == review.id }), row.phase == "staged",
              try JSONDecoder().decode(CarryLocalAdoptionReview.self, from: row.reviewData) == review else { throw CarryMigrationOwnershipFailure.invalidState }
        row.recoveryData = try JSONEncoder().encode(evidence); row.phase = "activated"
        do { try context.save() } catch { context.rollback(); throw error }
    }
    func cancel(rootID: UUID) throws {
        guard let row = try records().first(where: { $0.rootID == rootID }), row.phase == "staged" else { throw CarryMigrationOwnershipFailure.invalidState }
        context.delete(row); try context.save()
    }
    static func verifiedDeletedRoots(in context: ModelContext) throws -> Set<UUID> {
        let checkpoints = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
        guard checkpoints.count == 1 else { return [] }
        let known = Set(try context.fetch(FetchDescriptor<CarryAccountMigrationOwnershipRecord>()).map(\.rootID))
            .union(try context.fetch(FetchDescriptor<CarryAccountLocalAdoptionRecord>()).map(\.rootID))
        guard !known.isEmpty else { return [] }
        let replica = try CarryAccountReplica(container: context.container, accountID: checkpoints[0].accountID)
        var deleted: Set<UUID> = []
        for id in known {
            guard let raw = try context.fetch(FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.id == id })).first, raw.remoteDeleted else { continue }
            let scope = try replica.projectionSnapshot(rootID: id)
            guard let entry = scope.first(where: { $0.local.id == id }), ["trip", "libraryItem"].contains(entry.local.kind),
                  let remote = entry.observed, remote.deletedAt != nil, remote.version > 0,
                  scope.allSatisfy({ $0.local == $0.observed && $0.observed?.deletedAt != nil }),
                  try context.fetch(FetchDescriptor<TripBundle>(predicate: #Predicate { $0.id == id })).isEmpty,
                  try context.fetch(FetchDescriptor<MyItem>(predicate: #Predicate { $0.id == id })).isEmpty,
                  let baseline = try context.fetch(FetchDescriptor<CarryNativeMaterialization>(predicate: #Predicate { $0.id == id })).first,
                  baseline.locallyDeleted, let observed = baseline.observedGraphData,
                  try JSONDecoder().decode(CarryGraphEntity.self, from: observed) == remote else { continue }
            let scopeIDs = Set(scope.map { $0.local.id })
            let pending = try context.fetch(FetchDescriptor<CarryNativeChange>())
            guard !pending.contains(where: { scopeIDs.contains($0.entityID) }) else { continue }
            deleted.insert(id)
        }
        return deleted
    }
    static func capture(rootID: UUID, kind: String, context: ModelContext) throws -> CarryMigrationSourceSnapshot {
        if kind == "trip" {
            let values = try context.fetch(FetchDescriptor<TripBundle>(predicate: #Predicate { $0.id == rootID }))
            guard values.count == 1, let value = values.first else { throw CarryMigrationOwnershipFailure.invalidScope }
            return try .capture(trip: value)
        }
        if kind == "libraryItem" {
            let values = try context.fetch(FetchDescriptor<MyItem>(predicate: #Predicate { $0.id == rootID }))
            guard values.count == 1, let value = values.first else { throw CarryMigrationOwnershipFailure.invalidScope }
            return try .capture(item: value)
        }
        throw CarryMigrationOwnershipFailure.invalidScope
    }
    private static func thumbnailHash(_ bytes: Data?) -> String? { bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
}

nonisolated struct CarryLocalAdoptionArchive: Codable, Equatable, Sendable {
    let relativeDirectory: String
    let backupDigest: String
    let originals: [UUID: String]
    struct Verified: Sendable {
        fileprivate let descriptor: CarryLocalAdoptionArchive
        fileprivate let sourceFingerprint: String
    }
    @concurrent static func create(_ prepared: CarryMigrationPreparedBackup, root: URL, review: CarryLocalAdoptionReview) async throws -> Self {
        let currentAssets = try validateBackup(prepared.backup, source: review.source, accountID: review.accountID)
        guard Set(prepared.originalPhotos.keys) == Set(review.source.entities.filter { $0.metadata.kind == "photo" }.map { $0.metadata.id }) else { throw CarryMigrationBackupFailure.photoUnavailable }
        let id = review.id
        let folder = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CarryMigrationBackupFailure.invalidFile }
        func preserve(_ source: URL, _ name: String) throws -> String {
            let digest = try hashFile(source), target = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) {
                guard try hashFile(target) == digest else { throw CarryMigrationBackupFailure.invalidFile }
            } else {
                try FileManager.default.copyItem(at: source, to: target)
                guard try hashFile(target) == digest else { throw CarryMigrationBackupFailure.invalidFile }
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
            }
            return digest
        }
        let saved = folder.appendingPathComponent("source.json")
        let backup: String
        if FileManager.default.fileExists(atPath: saved.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let previous = try decoder.decode(CarryBackup.self, from: Data(contentsOf: saved, options: .mappedIfSafe))
            guard try validateBackup(previous, source: review.source, accountID: review.accountID) == currentAssets else { throw CarryMigrationBackupFailure.invalidFile }
            // The first immutable backup keeps its real creation time and its
            // then-current global preferences. Only selected source semantics
            // and every selected file digest authorize reuse on a retry.
            backup = try hashFile(saved)
        } else { backup = try preserve(prepared.url, "source.json") }
        var originals: [UUID: String] = [:]
        for (photoID, url) in prepared.originalPhotos { originals[photoID] = try preserve(url, photoID.uuidString.lowercased() + ".original") }
        let result = Self(relativeDirectory: id.uuidString.lowercased(), backupDigest: backup, originals: originals)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try encoder.encode(result).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        return result
    }
    @concurrent func verify(in root: URL, review: CarryLocalAdoptionReview) async throws -> Verified {
        guard let id = UUID(uuidString: relativeDirectory), relativeDirectory == id.uuidString.lowercased() else { throw CarryMigrationBackupFailure.invalidFile }
        let folder = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try Self.hashFile(folder.appendingPathComponent("source.json")) == backupDigest else { throw CarryMigrationBackupFailure.invalidFile }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(CarryBackup.self, from: Data(contentsOf: folder.appendingPathComponent("source.json"), options: .mappedIfSafe))
        try Self.validateBackup(backup, source: review.source, accountID: review.accountID)
        guard Set(originals.keys) == Set(review.source.entities.filter { $0.metadata.kind == "photo" }.map { $0.metadata.id }) else { throw CarryMigrationBackupFailure.photoUnavailable }
        for (id, digest) in originals {
            guard try Self.hashFile(folder.appendingPathComponent(id.uuidString.lowercased() + ".original")) == digest else { throw CarryMigrationBackupFailure.invalidFile }
        }
        return Verified(descriptor: self, sourceFingerprint: try review.source.fingerprint())
    }
    @discardableResult private static func validateBackup(_ backup: CarryBackup, source: CarryMigrationSourceSnapshot, accountID: UUID) throws -> [UUID: String] {
        guard backup.trips.count == (source.kind == "trip" ? 1 : 0), backup.myItems.count == (source.kind == "libraryItem" ? 1 : 0) else { throw CarryMigrationOwnershipFailure.invalidScope }
        let packet = try CarryGraphMigrationCodec.prepare(backup, accountID: accountID, migrationID: UUID(),
            tripIDs: source.kind == "trip" ? [source.rootID] : [], includeLibrary: source.kind == "libraryItem")
        guard Set(packet.entities.map(\.id)) == source.entityIDs else { throw CarryMigrationOwnershipFailure.invalidProof }
        for expected in source.entities {
            guard let actual = packet.entities.first(where: { $0.id == expected.metadata.id }), actual.kind == expected.metadata.kind,
                  actual.parentID == expected.metadata.parentID else { throw CarryMigrationOwnershipFailure.invalidProof }
            var fields = actual.fields
            fields.removeValue(forKey: "thumbnailAssetID"); fields.removeValue(forKey: "fileAssetID"); fields.removeValue(forKey: "backgroundAssetIDs")
            for (key, value) in expected.metadata.fields where value == .null && fields[key] == nil { fields[key] = .null }
            guard fields == expected.metadata.fields else { throw CarryMigrationOwnershipFailure.invalidProof }
            let thumbnail = packet.assets.first { $0.entityID == actual.id && $0.slot == "thumbnail" }
            guard thumbnail?.sha256 == expected.thumbnailSHA256 else { throw CarryMigrationOwnershipFailure.invalidProof }
            for asset in packet.assets where asset.entityID == actual.id && asset.slot != "thumbnail" {
                guard expected.metadata.fileReferences[asset.slot] == asset.fileName else { throw CarryMigrationOwnershipFailure.invalidProof }
            }
        }
        return Dictionary(uniqueKeysWithValues: packet.assets.map { ($0.id, $0.sha256) })
    }
    private static func hashFile(_ url: URL) throws -> String {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let expected = info.fileSize, expected > 0, expected <= 1024 * 1024 * 1024 else { throw CarryMigrationBackupFailure.invalidFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try Task.checkCancellation(); count += bytes.count
            guard count <= expected else { throw CarryMigrationBackupFailure.invalidFile }
            hash.update(data: bytes)
        }
        guard count == expected else { throw CarryMigrationBackupFailure.invalidFile }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
