import Foundation
import SwiftData
import CryptoKit

nonisolated struct CarryAccountMigrationProof: Codable, Equatable, Sendable {
    let accountID: UUID
    let batchID: UUID
    let tripIDs: Set<UUID>
    let libraryIDs: Set<UUID>
    let sourceFingerprints: [UUID: String]
    let graphDigest: String
    let receiptCursor: Int
    let assetDigest: String
}

enum CarryMigrationOwnershipFailure: Error {
    case wrongAccount, invalidScope, invalidState, invalidProof, sourceReadOnly, sourceChanged
}

@Model
final class CarryAccountMigrationOwnershipRecord {
    @Attribute(.unique) var rootID: UUID
    var accountID: UUID
    var batchID: UUID
    var kind: String
    var sourceFingerprint: String
    var sourceEntityIDs: [UUID]
    var sourceSnapshot: Data
    var active: Bool
    var proofData: Data?
    var reviewedSourceFingerprint: String?
    var reviewedSourceSnapshot: Data?
    init(rootID: UUID, accountID: UUID, batchID: UUID, kind: String, sourceFingerprint: String,
         sourceEntityIDs: [UUID], sourceSnapshot: Data) {
        self.rootID = rootID; self.accountID = accountID; self.batchID = batchID; self.kind = kind
        self.sourceFingerprint = sourceFingerprint; self.sourceEntityIDs = sourceEntityIDs
        self.sourceSnapshot = sourceSnapshot; active = false
    }
}

/// An immutable native snapshot includes relationships, scalar values, local
/// file references and thumbnail hashes, without reading files on the UI actor.
nonisolated struct CarryMigrationSourceSnapshot: Codable, Equatable, Sendable {
    struct Entity: Codable, Equatable, Sendable {
        let metadata: CarryNativeSourceMetadata
        let thumbnailSHA256: String?
    }
    let rootID: UUID
    let kind: String
    let entities: [Entity]
    var entityIDs: Set<UUID> { Set(entities.map { $0.metadata.id }) }
    var fileNames: Set<String> {
        var names = entities.reduce(into: Set<String>()) { $0.formUnion($1.metadata.fileReferences.values) }
        for entity in entities where entity.metadata.kind == "photo" {
            if case .string(let name) = entity.metadata.fields["assetLocalIdentifier"], name.hasPrefix("carryphoto1_") { names.insert(name) }
        }
        return names
    }
    static func recoveryID(batchID: UUID, sourceFingerprint: String, entityID: UUID) -> UUID {
        let seed = "CarryMigrationRecovery:v1:" + batchID.uuidString.lowercased() + ":" + sourceFingerprint + ":" + entityID.uuidString.lowercased()
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    func fingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
    @MainActor static func capture(trip: TripBundle) throws -> Self {
        try capture(rootID: trip.id, kind: "trip", models: models(trip: trip))
    }
    @MainActor static func models(trip: TripBundle) -> [any PersistentModel] {
        var models: [any PersistentModel] = [trip]
        for section in trip.safeSections { models.append(section); models += section.items ?? [] }
        for day in trip.safeItineraryDays {
            models.append(day)
            for stop in day.stops ?? [] { models.append(stop); models += stop.photos ?? []; models += stop.attachments ?? [] }
            for segment in day.segments ?? [] { models.append(segment); models += segment.attachments ?? [] }
        }
        for stay in trip.safeLodgingStays { models.append(stay); models += stay.attachments ?? [] }
        return models
    }
    @MainActor static func capture(item: MyItem) throws -> Self { try capture(rootID: item.id, kind: "libraryItem", models: [item]) }
    @MainActor private static func capture(rootID: UUID, kind: String, models: [any PersistentModel]) throws -> Self {
        var ids = Set<UUID>(), entities: [Entity] = []
        for model in models {
            guard let source = try CarryNativeSourceCodec.capture(model), ids.insert(source.metadata.id).inserted else {
                throw CarryMigrationOwnershipFailure.invalidScope
            }
            entities.append(Entity(metadata: source.metadata, thumbnailSHA256: source.thumbnailData.map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            }))
        }
        entities.sort { $0.metadata.id.uuidString < $1.metadata.id.uuidString }
        return Self(rootID: rootID, kind: kind, entities: entities)
    }
}

nonisolated struct CarryMigrationSourceDifference: Identifiable, Equatable, Sendable {
    var id: UUID { entityID }
    let entityID: UUID
    let title: String
    let kind: String
    let change: String
    let fields: [String]
    let before: [String: CarryGraphValue]
    let after: [String: CarryGraphValue]
}

nonisolated struct CarryMigrationForkReview: Equatable, Sendable {
    let batchID: UUID
    let sources: [CarryMigrationSourceSnapshot]
    let differences: [CarryMigrationSourceDifference]
}

/// Private, account-owned durable source ownership. No method saves: stage and
/// activation must share the migration engine's transaction and final save.
@MainActor
final class CarryAccountMigrationOwnership {
    static let models: [any PersistentModel.Type] = [CarryAccountMigrationOwnershipRecord.self]
    let accountID: UUID
    let context: ModelContext
    init(accountID: UUID, context: ModelContext) throws {
        guard context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else {
            throw CarryMigrationOwnershipFailure.invalidState
        }
        self.accountID = accountID; self.context = context
        guard try records().allSatisfy({ $0.accountID == accountID }) else { throw CarryMigrationOwnershipFailure.wrongAccount }
    }
    func records() throws -> [CarryAccountMigrationOwnershipRecord] { try context.fetch(FetchDescriptor<CarryAccountMigrationOwnershipRecord>()) }
    func stage(batchID: UUID, snapshots: [CarryMigrationSourceSnapshot]) throws {
        guard !snapshots.isEmpty, Set(snapshots.map(\.rootID)).count == snapshots.count,
              snapshots.allSatisfy({ ["trip", "libraryItem"].contains($0.kind) && $0.entityIDs.contains($0.rootID) }) else {
            throw CarryMigrationOwnershipFailure.invalidScope
        }
        let existing = try Dictionary(uniqueKeysWithValues: records().map { ($0.rootID, $0) })
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for snapshot in snapshots {
            let digest = try snapshot.fingerprint(), bytes = try encoder.encode(snapshot)
            if let current = existing[snapshot.rootID] {
                guard current.accountID == accountID, current.batchID == batchID,
                      current.sourceFingerprint == digest, current.sourceSnapshot == bytes else {
                    throw CarryMigrationOwnershipFailure.invalidState
                }
                continue
            }
            context.insert(CarryAccountMigrationOwnershipRecord(rootID: snapshot.rootID, accountID: accountID, batchID: batchID,
                kind: snapshot.kind, sourceFingerprint: digest, sourceEntityIDs: snapshot.entityIDs.sorted { $0.uuidString < $1.uuidString }, sourceSnapshot: bytes))
        }
    }
    func activate(_ proof: CarryAccountMigrationProof) throws {
        try CarryAccountTripMigration.validateActivationProof(proof, in: context)
        guard proof.accountID == accountID, proof.receiptCursor > 0,
              Self.digest(proof.graphDigest), Self.digest(proof.assetDigest),
              proof.tripIDs.isDisjoint(with: proof.libraryIDs) else { throw CarryMigrationOwnershipFailure.invalidProof }
        let selected = try records().filter { $0.batchID == proof.batchID }
        guard !selected.isEmpty, Set(selected.filter { $0.kind == "trip" }.map(\.rootID)) == proof.tripIDs,
              Set(selected.filter { $0.kind == "libraryItem" }.map(\.rootID)) == proof.libraryIDs,
              Set(proof.sourceFingerprints.keys) == proof.tripIDs.union(proof.libraryIDs),
              selected.allSatisfy({ $0.accountID == accountID && proof.sourceFingerprints[$0.rootID] == $0.sourceFingerprint }) else {
            throw CarryMigrationOwnershipFailure.invalidProof
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(proof)
        struct Approval: Decodable { let evidence: [CarryMigrationRecoveryEvidence] }
        var query = FetchDescriptor<CarryAccountMigrationBatch>(predicate: #Predicate { $0.id == proof.batchID }); query.fetchLimit = 1
        let approved = try context.fetch(query).first?.forkApprovalData.map { try JSONDecoder().decode(Approval.self, from: $0).evidence } ?? []
        for row in selected {
            if let reviewed = approved.first(where: { $0.source.rootID == row.rootID }) {
                try reviewed.validate()
                row.reviewedSourceFingerprint = try reviewed.source.fingerprint()
                row.reviewedSourceSnapshot = try encoder.encode(reviewed.source)
                row.sourceEntityIDs = Array(Set(row.sourceEntityIDs).union(reviewed.source.entityIDs))
            }
            if row.active {
                guard let previous = row.proofData, try JSONDecoder().decode(CarryAccountMigrationProof.self, from: previous) == proof else {
                    throw CarryMigrationOwnershipFailure.invalidProof
                }
            } else { row.proofData = bytes; row.active = true }
        }
    }
    func cancel(batchID: UUID) throws {
        let selected = try records().filter { $0.batchID == batchID }
        guard selected.allSatisfy({ !$0.active }) else { throw CarryMigrationOwnershipFailure.invalidState }
        for row in selected { context.delete(row) }
    }
    var migratedTripIDs: Set<UUID> { get throws { Set(try records().filter { $0.active && $0.kind == "trip" }.map(\.rootID)) } }
    var pendingTripIDs: Set<UUID> { get throws { Set(try records().filter { !$0.active && $0.kind == "trip" }.map(\.rootID)) } }
    var migratedLibraryIDs: Set<UUID> { get throws { Set(try records().filter { $0.active && $0.kind == "libraryItem" }.map(\.rootID)) } }
    func differences(rootID: UUID, current: CarryMigrationSourceSnapshot) throws -> [CarryMigrationSourceDifference] {
        guard current.rootID == rootID, let record = try records().first(where: { $0.rootID == rootID }) else {
            throw CarryMigrationOwnershipFailure.invalidState
        }
        if let reviewed = record.reviewedSourceFingerprint, reviewed == (try current.fingerprint()) { return [] }
        let baseline = try JSONDecoder().decode(CarryMigrationSourceSnapshot.self, from: record.sourceSnapshot)
        return Self.differences(baseline: baseline, current: current)
    }
    static func differences(baseline: CarryMigrationSourceSnapshot, current: CarryMigrationSourceSnapshot) -> [CarryMigrationSourceDifference] {
        let previous = Dictionary(uniqueKeysWithValues: baseline.entities.map { ($0.metadata.id, $0) })
        let latest = Dictionary(uniqueKeysWithValues: current.entities.map { ($0.metadata.id, $0) })
        return Set(previous.keys).union(latest.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard previous[id] != latest[id], let entity = latest[id] ?? previous[id] else { return nil }
            var fields = Set(previous[id]?.metadata.fields.keys.map { $0 } ?? []).union(latest[id]?.metadata.fields.keys.map { $0 } ?? [])
            fields = Set(fields.filter { previous[id]?.metadata.fields[$0] != latest[id]?.metadata.fields[$0] })
            if previous[id]?.metadata.parentID != latest[id]?.metadata.parentID { fields.insert("parent") }
            if previous[id]?.metadata.fileReferences != latest[id]?.metadata.fileReferences || previous[id]?.thumbnailSHA256 != latest[id]?.thumbnailSHA256 { fields.insert("files") }
            let title: String
            if case .string(let name) = entity.metadata.fields["name"] ?? entity.metadata.fields["title"] ?? entity.metadata.fields["displayName"] { title = name }
            else { title = "" }
            func displayFields(_ value: CarryMigrationSourceSnapshot.Entity?, in snapshot: CarryMigrationSourceSnapshot) -> [String: CarryGraphValue] {
                guard let value else { return [:] }
                var result = value.metadata.fields
                if let parentID = value.metadata.parentID, let parent = snapshot.entities.first(where: { $0.metadata.id == parentID }) {
                    result["parent"] = parent.metadata.fields["name"] ?? parent.metadata.fields["title"] ?? parent.metadata.fields["displayName"] ?? .null
                }
                let fileCount = value.metadata.fileReferences.count + (value.thumbnailSHA256 == nil ? 0 : 1)
                    + (value.metadata.kind == "photo" && value.metadata.fields["assetLocalIdentifier"] != .string("") ? 1 : 0)
                result["files"] = .integer(Int64(fileCount))
                return result
            }
            return CarryMigrationSourceDifference(entityID: id, title: title, kind: entity.metadata.kind,
                change: previous[id] == nil ? "inserted" : latest[id] == nil ? "deleted" : "edited", fields: fields.sorted(),
                before: displayFields(previous[id], in: baseline), after: displayFields(latest[id], in: current))
        }
    }
    private static func digest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
}

/// Installed at every source-store save gate, including the isolated legacy
/// automation transaction. Incoming CloudKit changes are preserved as forks;
/// this guard only prevents this build from writing protected source objects.
@MainActor
final class CarryMigrationSourceWriteGuard {
    private var pending: [UUID: Set<UUID>] = [:]
    private var activeEntities: Set<UUID> = []
    private var activeRoots: Set<UUID> = []
    private var pendingRoots: [UUID: Set<UUID>] = [:]
    private var blocked = false
    private var activeFiles: Set<String> = []
    private var pendingFiles: [UUID: Set<String>] = [:]
    private func publishFiles() { CarryMigrationSourceFileRetention.replace(activeFiles.union(pendingFiles.values.reduce(into: Set<String>()) { $0.formUnion($1) })) }
    func blockAllWrites() { blocked = true }
    func isProtected(_ id: UUID) -> Bool { activeEntities.contains(id) || pending.values.contains(where: { $0.contains(id) }) || protectedRootIDs.contains(id) }
    func load(indexes: [CarryMigrationOwnershipIndex]) {
        activeRoots = Set(indexes.flatMap(\.roots).map(\.id))
        activeEntities = indexes.flatMap(\.roots).reduce(into: Set<UUID>()) { $0.formUnion($1.entityIDs) }
        activeFiles = indexes.flatMap(\.roots).reduce(into: Set<String>()) { $0.formUnion($1.fileReferences ?? []) }
        publishFiles()
        blocked = false
    }
    var protectedRootIDs: Set<UUID> { activeRoots.union(pendingRoots.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }) }
    func protect(batchID: UUID, snapshots: [CarryMigrationSourceSnapshot]) {
        pending[batchID] = snapshots.reduce(into: Set<UUID>()) { $0.formUnion($1.entityIDs) }
        pendingRoots[batchID] = Set(snapshots.map(\.rootID))
        pendingFiles[batchID] = snapshots.reduce(into: Set<String>()) { $0.formUnion($1.fileNames) }
        publishFiles()
    }
    func release(batchID: UUID) {
        pending.removeValue(forKey: batchID); pendingRoots.removeValue(forKey: batchID); pendingFiles.removeValue(forKey: batchID); publishFiles()
    }
    func load(_ records: [CarryAccountMigrationOwnershipRecord]) throws {
        var entities = Set<UUID>(), roots = Set<UUID>()
        for row in records where row.active {
            guard row.proofData != nil, !row.sourceEntityIDs.isEmpty else { throw CarryMigrationOwnershipFailure.invalidProof }
            entities.formUnion(row.sourceEntityIDs); roots.insert(row.rootID)
        }
        activeEntities = entities; activeRoots = roots
        activeFiles = try records.filter { $0.active }.reduce(into: Set<String>()) { names, row in
            names.formUnion(try JSONDecoder().decode(CarryMigrationSourceSnapshot.self, from: row.sourceSnapshot).fileNames)
            if let reviewed = row.reviewedSourceSnapshot { names.formUnion(try JSONDecoder().decode(CarryMigrationSourceSnapshot.self, from: reviewed).fileNames) }
        }
        publishFiles()
    }
    func validate(_ context: ModelContext) throws {
        guard !blocked else { throw CarryMigrationOwnershipFailure.invalidState }
        let locked = activeEntities.union(pending.values.reduce(into: Set<UUID>()) { $0.formUnion($1) })
        let roots = protectedRootIDs
        guard !locked.isEmpty || !roots.isEmpty else { return }
        context.processPendingChanges()
        for model in context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray {
            guard let identity = try CarryNativeSourceCodec.identity(of: model) else { continue }
            if locked.contains(identity.id) { throw CarryMigrationOwnershipFailure.sourceReadOnly }
            if let trip = Self.tripID(model), roots.contains(trip) { throw CarryMigrationOwnershipFailure.sourceReadOnly }
        }
    }
    private static func tripID(_ model: any PersistentModel) -> UUID? {
        switch model {
        case let value as TripBundle: return value.id
        case let value as PackingSection: return value.bundle?.id
        case let value as PackingItem: return value.section?.bundle?.id
        case let value as ItineraryDay: return value.bundle?.id
        case let value as ItineraryStop: return value.day?.bundle?.id
        case let value as TransportSegment: return value.day?.bundle?.id
        case let value as LodgingStay: return value.bundle?.id
        case let value as StopPhoto: return value.stop?.day?.bundle?.id
        case let value as ItineraryAttachment: return value.stop?.day?.bundle?.id ?? value.segment?.day?.bundle?.id ?? value.stay?.bundle?.id
        default: return nil
        }
    }
}

/// A small recovery index contains identities only. It is written pending
/// before any upload and repaired from the account database after activation.
/// A crash between SQLite and file publication leaves source data read-only;
/// it never guesses that source deletion or ownership activation succeeded.
nonisolated struct CarryMigrationOwnershipIndex: Codable, Equatable, Sendable {
    struct Root: Codable, Equatable, Sendable {
        let id: UUID
        let batchID: UUID
        let kind: String
        let entityIDs: Set<UUID>
        let fingerprint: String
        let active: Bool
        var fileReferences: Set<String>? = nil
        var adoptionID: UUID? = nil
    }
    let accountID: UUID
    let roots: [Root]
    @MainActor init(accountID: UUID, records: [CarryAccountMigrationOwnershipRecord], adoptions: [CarryAccountLocalAdoptionRecord] = [], materializedRootIDs: Set<UUID>? = nil) throws {
        guard records.allSatisfy({ $0.accountID == accountID }) else { throw CarryMigrationOwnershipFailure.wrongAccount }
        self.accountID = accountID
        var combined = try records.map { Root(id: $0.rootID, batchID: $0.batchID, kind: $0.kind,
            entityIDs: Set($0.sourceEntityIDs), fingerprint: $0.sourceFingerprint, active: $0.active && (materializedRootIDs?.contains($0.rootID) ?? true),
            fileReferences: try JSONDecoder().decode(CarryMigrationSourceSnapshot.self, from: $0.sourceSnapshot).fileNames.union(
                $0.reviewedSourceSnapshot.map { try JSONDecoder().decode(CarryMigrationSourceSnapshot.self, from: $0).fileNames } ?? [])) }.sorted { $0.id.uuidString < $1.id.uuidString }
        for row in adoptions {
            guard row.accountID == accountID, !combined.contains(where: { $0.id == row.rootID }) else { throw CarryMigrationOwnershipFailure.invalidState }
            let review = try JSONDecoder().decode(CarryLocalAdoptionReview.self, from: row.reviewData)
            guard review.accountID == accountID, review.id == row.id, review.source.rootID == row.rootID, review.source.kind == row.kind else { throw CarryMigrationOwnershipFailure.invalidState }
            combined.append(Root(id: row.rootID, batchID: row.id, kind: row.kind, entityIDs: review.source.entityIDs,
                fingerprint: try review.source.fingerprint(), active: row.phase == "activated" && (materializedRootIDs?.contains(row.rootID) ?? false),
                fileReferences: review.source.fileNames, adoptionID: row.id))
        }
        roots = combined.sorted { $0.id.uuidString < $1.id.uuidString }
        try validate()
    }
    func validate() throws {
        guard roots.count <= 20000, Set(roots.map(\.id)).count == roots.count,
              roots.allSatisfy({ ["trip", "libraryItem"].contains($0.kind) && $0.entityIDs.contains($0.id)
                  && $0.entityIDs.count <= 20000 && ($0.fileReferences ?? []).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") && $0.utf8.count <= 255 }) && $0.fingerprint.count == 64 && $0.fingerprint.allSatisfy({ "0123456789abcdef".contains($0) }) }) else {
            throw CarryMigrationOwnershipFailure.invalidState
        }
    }
    @MainActor func write(in directory: URL) throws {
        try validate()
        let folder = directory.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folderInfo = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderInfo.isDirectory == true, folderInfo.isSymbolicLink != true else { throw CarryMigrationOwnershipFailure.invalidState }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        guard data.count <= 8 * 1024 * 1024 else { throw CarryMigrationOwnershipFailure.invalidState }
        let url = folder.appendingPathComponent("ownership-index.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var protected = url, values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
    }
    @MainActor static func readAll(in directory: URL) throws -> [Self] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var result: [Self] = []
        for folder in folders {
            guard let accountID = UUID(uuidString: folder.lastPathComponent) else { continue }
            let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw CarryMigrationOwnershipFailure.invalidState }
            let url = folder.appendingPathComponent("ownership-index.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let file = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard file.isRegularFile == true, file.isSymbolicLink != true, let count = file.fileSize, count <= 8 * 1024 * 1024 else {
                throw CarryMigrationOwnershipFailure.invalidState
            }
            let index = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard index.accountID == accountID else { throw CarryMigrationOwnershipFailure.wrongAccount }
            try index.validate(); result.append(index)
        }
        return result
    }
}


@MainActor
enum CarryMigrationSourceFileRetention {
    private static var names: Set<String> = []
    private static var providers: [UUID: () throws -> Set<String>?] = [:]
    private static var reportedFailures: Set<UUID> = []
    /// A nil result means the weak owner has gone away. Persisted index pins
    /// remain independent; a live source read failure always prevents deletion.
    @discardableResult static func register(_ provider: @escaping () throws -> Set<String>?) -> UUID {
        let id = UUID(); providers[id] = provider; return id
    }
    static func unregister(_ id: UUID) { providers.removeValue(forKey: id); reportedFailures.remove(id) }
    static func contains(named name: String) -> Bool {
        if names.contains(name) { return true }
        for (id, provider) in Array(providers) {
            do {
                guard let current = try provider() else { unregister(id); continue }
                reportedFailures.remove(id)
                if current.contains(name) { return true }
            } catch {
                if reportedFailures.insert(id).inserted {
                    CarryLogger.shared.log(.loadFailed, context: "migration_source_file_retention")
                }
                return true
            }
        }
        return false
    }
    fileprivate static func replace(_ kept: Set<String>) { names = kept }
}
