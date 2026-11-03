import Foundation
import SwiftData

// All journal models belong exclusively to an account's CloudKit.none cache.
@Model
final class CarryNativeJournalOwner {
    @Attribute(.unique) var key: String
    var accountID: UUID
    var sequence: Int64
    init(accountID: UUID) { key = "account"; self.accountID = accountID; sequence = 0 }
}

@Model
final class CarryNativeMaterialization {
    @Attribute(.unique) var id: UUID
    var sourceData: Data
    var thumbnailData: Data?
    var observedGraphData: Data?
    var locallyDeleted: Bool
    init(source: CarryNativeEntitySource, sourceData: Data, observedGraphData: Data? = nil) {
        id = source.metadata.id; self.sourceData = sourceData; thumbnailData = source.thumbnailData
        self.observedGraphData = observedGraphData; locallyDeleted = false
    }
}

@Model
final class CarryNativeTransaction {
    @Attribute(.unique) var id: UUID
    var sequence: Int64
    var createdAt: Date
    var changeCount: Int
    init(id: UUID, sequence: Int64, changeCount: Int) {
        self.id = id; self.sequence = sequence; self.changeCount = changeCount; createdAt = Date()
    }
}

@Model
final class CarryNativeChange {
    @Attribute(.unique) var id: UUID
    var transactionID: UUID
    var ordinal: Int
    var entityID: UUID
    var kind: String
    var action: String
    var sourceData: Data
    var previousSourceData: Data?
    var observedGraphData: Data?
    var changedFields: [String]
    var parentChanged: Bool
    var thumbnailChanged: Bool
    var thumbnailData: Data?
    init(transactionID: UUID, ordinal: Int, entityID: UUID, kind: String, action: String,
         sourceData: Data, previousSourceData: Data?, observedGraphData: Data?, changedFields: [String],
         parentChanged: Bool, thumbnailChanged: Bool, thumbnailData: Data?) {
        id = UUID(); self.transactionID = transactionID; self.ordinal = ordinal; self.entityID = entityID
        self.kind = kind; self.action = action; self.sourceData = sourceData; self.previousSourceData = previousSourceData
        self.observedGraphData = observedGraphData; self.changedFields = changedFields; self.parentChanged = parentChanged
        self.thumbnailChanged = thumbnailChanged; self.thumbnailData = thumbnailData
    }
}

enum CarryNativeJournalFailure: Error { case wrongContainer, accountMismatch, invalidState, missingBaseline, exhaustedSequence }

/// Capture is synchronous, local and part of the BUSINESS save, never a didSave
/// observer. Consumption into the wire replica is a later durable transaction.
@MainActor
final class CarryNativeChangeJournal {
    static let models: [any PersistentModel.Type] = [CarryNativeJournalOwner.self, CarryNativeMaterialization.self,
        CarryNativeTransaction.self, CarryNativeChange.self]
    let accountID: UUID
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = .sortedKeys; return value }()
    private let decoder = JSONDecoder()

    init(accountID: UUID) { self.accountID = accountID }

    private func owner(in context: ModelContext) throws -> CarryNativeJournalOwner {
        guard context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }),
              context.container.schema.entities.contains(where: { $0.name == String(describing: CarryNativeChange.self) }) else {
            throw CarryNativeJournalFailure.wrongContainer
        }
        let checkpoints = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
        guard checkpoints.count <= 1, checkpoints.allSatisfy({ $0.accountID == accountID }) else {
            throw CarryNativeJournalFailure.accountMismatch
        }
        let owners = try context.fetch(FetchDescriptor<CarryNativeJournalOwner>())
        guard owners.count <= 1 else { throw CarryNativeJournalFailure.invalidState }
        if let owner = owners.first {
            guard owner.accountID == accountID else { throw CarryNativeJournalFailure.accountMismatch }
            return owner
        }
        let owner = CarryNativeJournalOwner(accountID: accountID); context.insert(owner); return owner
    }

    private func baseline(_ id: UUID, in context: ModelContext) throws -> CarryNativeMaterialization? {
        var query = FetchDescriptor<CarryNativeMaterialization>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    /// Used as TripStore.persistenceSave. The surrounding CarryPersistence gate
    /// handles failure/Context replacement; no save can precede capture.
    func captureAndSave(_ context: ModelContext) throws {
        try capture(in: context)
        try context.save()
    }

    func capture(in context: ModelContext) throws {
        context.autosaveEnabled = false
        context.processPendingChanges()
        let inserted = context.insertedModelsArray, updated = context.changedModelsArray, deleted = context.deletedModelsArray
        let state = try owner(in: context)
        var insertedIDs: Set<UUID> = []
        for model in inserted {
            if let identity = try CarryNativeSourceCodec.identity(of: model) { insertedIDs.insert(identity.id) }
        }
        var deletedIDs: [UUID: String] = [:]
        var deletedInstances: Set<ObjectIdentifier> = []
        for model in deleted {
            if let identity = try CarryNativeSourceCodec.identity(of: model) {
                guard deletedIDs[identity.id] == nil || deletedIDs[identity.id] == identity.kind else {
                    throw CarryNativeJournalFailure.invalidState
                }
                deletedIDs[identity.id] = identity.kind
                deletedInstances.insert(ObjectIdentifier(model))
            }
        }
        var sources: [UUID: CarryNativeEntitySource] = [:]
        var instances: [UUID: ObjectIdentifier] = [:]
        for model in inserted + updated {
            let object = ObjectIdentifier(model)
            guard !deletedInstances.contains(object), let identity = try CarryNativeSourceCodec.identity(of: model) else { continue }
            guard deletedIDs[identity.id] == nil || deletedIDs[identity.id] == identity.kind else {
                throw CarryNativeJournalFailure.invalidState
            }
            guard instances[identity.id] == nil || instances[identity.id] == object else { throw CarryNativeJournalFailure.invalidState }
            instances[identity.id] = object
            if let source = try CarryNativeSourceCodec.capture(model) { sources[identity.id] = source }
        }
        let transactionID = UUID()
        var count = 0
        for id in sources.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let source = sources[id] else { throw CarryNativeJournalFailure.invalidState }
            let previous = try baseline(id, in: context)
            guard previous != nil || insertedIDs.contains(id) else { throw CarryNativeJournalFailure.missingBaseline }
            if insertedIDs.contains(id), previous?.locallyDeleted == false, deletedIDs[id] == nil {
                // An active identity may be replaced only when its old instance
                // is deleted in this same transaction. Otherwise it is a second
                // live object, even if the first instance was not itself edited.
                throw CarryNativeJournalFailure.invalidState
            }
            let old = try previous.map { try decoder.decode(CarryNativeSourceMetadata.self, from: $0.sourceData) }
            guard old == nil || old?.kind == source.metadata.kind else { throw CarryNativeJournalFailure.invalidState }
            let fields = Set(old?.fields.keys.map { $0 } ?? []).union(source.metadata.fields.keys)
                .filter { old?.fields[$0] != source.metadata.fields[$0] }.sorted()
            let parentChanged = old?.parentID != source.metadata.parentID
            let thumbnailChanged = previous?.thumbnailData != source.thumbnailData
            let filesChanged = old?.fileReferences != source.metadata.fileReferences
            if previous != nil, previous?.locallyDeleted == false, fields.isEmpty, !parentChanged, !thumbnailChanged, !filesChanged { continue }
            let bytes = try encoder.encode(source.metadata)
            context.insert(CarryNativeChange(transactionID: transactionID, ordinal: count, entityID: id,
                kind: source.metadata.kind, action: previous?.locallyDeleted == true ? "restore" : "upsert", sourceData: bytes,
                previousSourceData: previous?.sourceData, observedGraphData: previous?.observedGraphData,
                changedFields: fields, parentChanged: parentChanged, thumbnailChanged: thumbnailChanged,
                thumbnailData: thumbnailChanged ? source.thumbnailData : nil))
            if let previous {
                previous.sourceData = bytes; previous.thumbnailData = source.thumbnailData; previous.locallyDeleted = false
            } else { context.insert(CarryNativeMaterialization(source: source, sourceData: bytes)) }
            count += 1
        }
        // Preserve deletion intent even after SwiftData removes the native model.
        // The protocol bridge decides subtree ordering and preview conflicts.
        for id in deletedIDs.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            // Backup restore replaces native instances while preserving UUIDs.
            // The final surviving instance above is an edit, not a deletion.
            if sources[id] != nil { continue }
            guard let previous = try baseline(id, in: context) else {
                // Objects created and removed before their first save never existed.
                if insertedIDs.contains(id) { continue }
                throw CarryNativeJournalFailure.missingBaseline
            }
            guard !previous.locallyDeleted else { continue }
            let metadata = try decoder.decode(CarryNativeSourceMetadata.self, from: previous.sourceData)
            guard metadata.kind == deletedIDs[id] else { throw CarryNativeJournalFailure.invalidState }
            context.insert(CarryNativeChange(transactionID: transactionID, ordinal: count, entityID: id,
                kind: metadata.kind, action: "delete", sourceData: previous.sourceData, previousSourceData: previous.sourceData,
                observedGraphData: previous.observedGraphData, changedFields: [], parentChanged: false,
                thumbnailChanged: false, thumbnailData: nil))
            previous.locallyDeleted = true
            count += 1
        }
        if count > 0 {
            guard state.sequence < Int64.max else { throw CarryNativeJournalFailure.exhaustedSequence }
            state.sequence += 1
            context.insert(CarryNativeTransaction(id: transactionID, sequence: state.sequence, changeCount: count))
        }
    }

    /// The projection calls this in its own native transaction, with the actual
    /// last displayed source and the trusted server version it was based on.
    /// It must first drain native journal entries; this is not an editing API.
    func noteMaterialized(_ source: CarryNativeEntitySource, observed: CarryGraphEntity, in context: ModelContext) throws {
        _ = try owner(in: context)
        guard observed.id == source.metadata.id, observed.kind == source.metadata.kind,
              observed.deletedAt == nil, observed.version > 0 else { throw CarryNativeJournalFailure.invalidState }
        let id = source.metadata.id
        var pending = FetchDescriptor<CarryNativeChange>(predicate: #Predicate { $0.entityID == id })
        pending.fetchLimit = 1
        guard try context.fetch(pending).isEmpty else { throw CarryNativeJournalFailure.invalidState }
        let bytes = try encoder.encode(source.metadata), graph = try encoder.encode(observed)
        if let previous = try baseline(id, in: context) {
            previous.sourceData = bytes; previous.thumbnailData = source.thumbnailData
            previous.observedGraphData = graph; previous.locallyDeleted = false
        } else { context.insert(CarryNativeMaterialization(source: source, sourceData: bytes, observedGraphData: graph)) }
    }
}
