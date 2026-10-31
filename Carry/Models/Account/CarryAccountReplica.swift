import Foundation
import SwiftData

// These models live ONLY in the account container (CloudKit .none). Existing
// SchemaV1 / iCloud stores are never expanded with local outbox/session metadata.
@Model
final class CarryReplicaRecord {
    @Attribute(.unique) var id: UUID
    var payload: Data
    // Default true also repairs caches written before this materialized queue
    // flag existed. The next queue pass normalizes those records once.
    var hasPendingChanges: Bool = true
    var acknowledgedRequestID: UUID? = nil
    var hasTreeIntent: Bool = false
    var needsProjection: Bool = true
    var remoteDeletionBatch: UUID? = nil
    var localParentID: UUID? = nil
    var remoteParentID: UUID? = nil
    var hasLocalTreeOverlay: Bool = false
    var localDeletionOverlay: Bool? = nil
    var remoteDeleted: Bool = false
    init(id: UUID, payload: Data, hasPendingChanges: Bool) {
        self.id = id; self.payload = payload; self.hasPendingChanges = hasPendingChanges
    }
}

@Model
final class CarryReplicaCheckpoint {
    @Attribute(.unique) var key: String
    var accountID: UUID
    var cursor: Int
    var flight: Data?
    var flightID: UUID? = nil
    var failureData: Data?
    var blocked: Bool
    var localRecoveryNamespace: UUID? = nil
    var relationshipMetadataVersion: Int = 0
    var revision: Int64 = 0
    var abandonedRequests: [UUID] = []
    init(accountID: UUID) {
        key = "account"; self.accountID = accountID; cursor = 0; blocked = false
    }
}

@Model
final class CarryReplicaReceiptCheckpoint {
    @Attribute(.unique) var requestID: UUID
    var cursor: Int
    var changeCount: Int
    var nextOffset: Int
    var lastSequence: Int
    init(summary: CarryGraphReceiptSummary) {
        requestID = summary.requestID; cursor = summary.cursor; changeCount = summary.changeCount
        nextOffset = 0; lastSequence = 0
    }
}

private nonisolated struct CarryReplicaAcceptedField: Codable, Sendable {
    let value: CarryGraphValue
    let version: Int
}

private nonisolated struct CarryReplicaAcceptedStructure: Codable, Sendable {
    let version: Int
    let continuousBase: Int
    let parentID: UUID?
}

private nonisolated struct CarryReplicaAcceptedTree: Codable, Sendable {
    let baseVersion: Int
    let baseSubtreeVersion: Int
    var current: CarryGraphEntity

    func includes(_ observed: CarryGraphEntity) -> Bool {
        observed.id == current.id && observed.kind == current.kind &&
        observed.version >= baseVersion && observed.version <= current.version &&
        observed.subtreeVersion >= baseSubtreeVersion && observed.subtreeVersion <= current.subtreeVersion
    }
}

private nonisolated struct CarryReplicaTreeIntent: Codable, Sendable {
    let id: UUID
    var desiredDeleted: Bool
    var baseline: CarryGraphEntity?
    var members: [UUID]
}

private nonisolated struct CarryReplicaPayload: Codable, Sendable {
    var remote: CarryGraphEntity?
    var local: CarryGraphEntity
    /// Each pending field retains its original server baseline independently.
    /// A pull must never advance it and silently overwrite a competing edit.
    var intents: [String: Int]
    var structuralAction: String?
    var structuralVersion: Int? = nil
    var unconfirmedRemote: CarryGraphEntity? = nil
    var localCreation: Bool? = nil
    var acceptedFields: [String: CarryReplicaAcceptedField]? = nil
    var acceptedStructure: CarryReplicaAcceptedStructure? = nil
    var acceptedTree: CarryReplicaAcceptedTree? = nil
    var treeIntent: CarryReplicaTreeIntent? = nil
    var localDeletion: Bool? = nil
}

private nonisolated struct CarryReplicaFlight: Codable, Sendable {
    let command: CarryGraphCommand
    let desired: [UUID: CarryGraphEntity]
    var treeOperations: [UUID: CarryReplicaTreeIntent]? = nil
}

/// Durable account replica and outbox. The caller's native graph projection and
/// its synchronization intent share this context/save. No network is performed
/// inside a local transaction. Transport retries reuse the frozen request ID.
@MainActor
final class CarryAccountReplica {
    let context: ModelContext
    let accountID: UUID
    private let save: (ModelContext) throws -> Void
    private let encoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder }()
    private let decoder = JSONDecoder()
    private var cachedFlight: CarryReplicaFlight?
    private var mutationIndex: (requestID: UUID, values: [UUID: CarryGraphMutation])?

    static var schema: Schema {
        Schema(SchemaV1.models + [CarryReplicaRecord.self, CarryReplicaCheckpoint.self, CarryReplicaReceiptCheckpoint.self]
            + CarryNativeChangeJournal.models + CarryAccountAssetQueue.models + CarryNativeGraphProjector.models
            + CarryAccountTripMigration.models + CarryAccountMigrationOwnership.models + CarryAccountLocalAdoption.models)
    }

    static func container(at url: URL) throws -> ModelContainer {
        let schema = Self.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        ])
    }

    init(container: ModelContainer, accountID: UUID,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else {
            throw CarryReplicaFailure.invalidState
        }
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        self.accountID = accountID
        self.save = save
        let journalOwners = try context.fetch(FetchDescriptor<CarryNativeJournalOwner>())
        guard journalOwners.count <= 1 else { throw CarryReplicaFailure.invalidState }
        guard journalOwners.allSatisfy({ $0.accountID == accountID }) else {
            throw CarryReplicaFailure.accountMismatch
        }
        let state = try checkpoint()
        guard state.accountID == accountID else { throw CarryReplicaFailure.accountMismatch }
        if state.relationshipMetadataVersion < 1 {
            for record in try rows() {
                let value = try payload(record)
                record.remoteDeletionBatch = value.remote?.deletionBatch
                record.localParentID = value.local.parentID; record.remoteParentID = value.remote?.parentID
                record.hasLocalTreeOverlay = value.localDeletion != nil
                record.localDeletionOverlay = value.localDeletion; record.remoteDeleted = value.remote?.deletedAt != nil
            }
            state.relationshipMetadataVersion = 1
        }
        try save(context)
    }

    private func checkpoint() throws -> CarryReplicaCheckpoint {
        let states = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
        guard states.count <= 1 else { throw CarryReplicaFailure.invalidState }
        if let state = states.first {
            guard state.accountID == accountID else { throw CarryReplicaFailure.accountMismatch }
            return state
        }
        let state = CarryReplicaCheckpoint(accountID: accountID)
        context.insert(state)
        return state
    }

    private func rows() throws -> [CarryReplicaRecord] {
        try context.fetch(FetchDescriptor<CarryReplicaRecord>())
    }

    private func row(id: UUID) throws -> CarryReplicaRecord? {
        var query = FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    private func pendingRows() throws -> [CarryReplicaRecord] {
        try context.fetch(FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.hasPendingChanges }))
    }

    private func store(_ value: CarryReplicaPayload, in row: CarryReplicaRecord) throws {
        let bytes = try encoder.encode(value)
        if row.payload != bytes { row.payload = bytes; row.needsProjection = true }
        if row.localParentID != value.local.parentID { row.localParentID = value.local.parentID }
        if row.remoteParentID != value.remote?.parentID { row.remoteParentID = value.remote?.parentID }
        if row.hasLocalTreeOverlay != (value.localDeletion != nil) { row.hasLocalTreeOverlay = value.localDeletion != nil }
        if row.localDeletionOverlay != value.localDeletion { row.localDeletionOverlay = value.localDeletion }
        if row.remoteDeleted != (value.remote?.deletedAt != nil) { row.remoteDeleted = value.remote?.deletedAt != nil }
        if row.remoteDeletionBatch != value.remote?.deletionBatch { row.remoteDeletionBatch = value.remote?.deletionBatch }
        if row.hasTreeIntent != (value.treeIntent != nil) { row.hasTreeIntent = value.treeIntent != nil }
        let pending = value.treeIntent != nil || value.structuralAction != nil || !value.intents.isEmpty
        if row.hasPendingChanges != pending { row.hasPendingChanges = pending }
    }

    private func payload(_ row: CarryReplicaRecord) throws -> CarryReplicaPayload {
        try decoder.decode(CarryReplicaPayload.self, from: row.payload)
    }

    private func frozenFlight(_ state: CarryReplicaCheckpoint) throws -> CarryReplicaFlight? {
        if let cachedFlight, state.flightID == cachedFlight.command.requestID { return cachedFlight }
        guard let bytes = state.flight else { return nil }
        let flight = try decoder.decode(CarryReplicaFlight.self, from: bytes)
        state.flightID = flight.command.requestID
        cachedFlight = flight
        return flight
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            if context.hasChanges {
                let state = try checkpoint()
                guard state.revision < Int64.max else { throw CarryReplicaFailure.invalidState }
                state.revision += 1
            }
            try save(context)
            return result
        } catch {
            context.rollback()
            cachedFlight = nil
            mutationIndex = nil
            throw error
        }
    }

    func localEntities() throws -> [CarryGraphEntity] {
        try rows().map { try payload($0).local }
    }

    func projectionSnapshot() throws -> [CarryNativeProjectionEntity] {
        guard try deletionConflicts().isEmpty else { throw CarryReplicaFailure.blocked }
        return try rows().map { let value = try payload($0); return CarryNativeProjectionEntity(local: value.local, observed: value.remote) }
    }

    /// Review one native root without decoding unrelated account payloads.
    /// Both indexed parent relations are traversed so an unsent move cannot
    /// conceal a child from the later exact local/observed equality check.
    func projectionSnapshot(rootID: UUID) throws -> [CarryNativeProjectionEntity] {
        guard try deletionConflicts().isEmpty, let root = try row(id: rootID) else { throw CarryReplicaFailure.blocked }
        var selected: [UUID: CarryReplicaRecord] = [rootID: root], pending = [rootID]
        while !pending.isEmpty {
            try Task.checkCancellation()
            let count = min(256, pending.count)
            let parents: [UUID?] = pending.prefix(count).map { Optional($0) }
            pending.removeFirst(count)
            let query = FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate {
                parents.contains($0.localParentID) || parents.contains($0.remoteParentID)
            })
            for record in try context.fetch(query) where selected[record.id] == nil {
                selected[record.id] = record; pending.append(record.id)
            }
            guard selected.count <= 20000 else { throw CarryReplicaFailure.invalidState }
        }
        return try selected.values.map {
            let value = try payload($0)
            return CarryNativeProjectionEntity(local: value.local, observed: value.remote)
        }
    }

    /// Snapshot only immutable Data while on the persistence actor. Decoding
    /// large account fields happens off the UI actor; an intervening edit makes
    /// the snapshot retryable instead of projecting an obsolete graph.
    func projectionSnapshotAsync() async throws -> [CarryNativeProjectionEntity] {
        guard try deletionConflicts().isEmpty else { throw CarryReplicaFailure.blocked }
        let revision = try checkpoint().revision
        let bytes = try rows().map(\.payload)
        let decode = Task.detached(priority: .utility) {
            let decoder = JSONDecoder()
            return try bytes.map { data in
                try Task.checkCancellation()
                let value = try decoder.decode(CarryReplicaPayload.self, from: data)
                return CarryNativeProjectionEntity(local: value.local, observed: value.remote)
            }
        }
        let snapshot = try await withTaskCancellationHandler(operation: { try await decode.value }, onCancel: { decode.cancel() })
        try Task.checkCancellation()
        guard try checkpoint().revision == revision else { throw CarryReplicaFailure.projectionChanged }
        return snapshot
    }

    func projectionCandidates() throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.needsProjection })).map(\.id))
    }

    /// Called synchronously after the business projection saved successfully.
    /// A crash before this second checkpoint only replays an idempotent project.
    func markProjected(_ ids: Set<UUID>) throws {
        try transaction { for id in ids { if let row = try row(id: id) { row.needsProjection = false } } }
    }

    var cursor: Int { get throws { try checkpoint().cursor } }

    var pendingFailure: Data? {
        get throws {
            if let failure = try checkpoint().failureData { return failure }
            let conflicts = try deletionConflicts()
            return conflicts.isEmpty ? nil : try encoder.encode(["error": "remote_deletion_conflict", "draftCount": String(conflicts.count)])
        }
    }

    /// Pending intentions remain durable when another device deletes their
    /// entity or destination ancestor. The review contains exactly the draft
    /// and remote versions displayed; later edits invalidate that review.
    func deletionConflicts() throws -> [CarryGraphDeletionConflict] {
        var result: [CarryGraphDeletionConflict] = []
        var cache: [UUID: CarryReplicaPayload] = [:]
        var impacts: [String: [CarryGraphEntity]] = [:]
        func load(_ id: UUID) throws -> CarryReplicaPayload? {
            if let value = cache[id] { return value }
            guard let record = try row(id: id) else { return nil }
            let value = try payload(record); cache[id] = value; return value
        }
        for record in try pendingRows() {
            let value = try payload(record)
            guard value.localDeletion != true,
                  value.structuralAction != nil || !value.intents.isEmpty else { continue }
            var currentID: UUID? = value.local.id
            var visited = Set<UUID>(), deleted: [CarryGraphEntity] = []
            while let id = currentID {
                guard visited.insert(id).inserted else { throw CarryReplicaFailure.invalidState }
                guard let node = try row(id: id) else { break }
                if node.localDeletionOverlay == true { deleted = []; break }
                if node.localDeletionOverlay != false, node.remoteDeleted, let remote = try load(id)?.remote {
                    deleted.append(remote)
                }
                currentID = node.localParentID
            }
            if !deleted.isEmpty {
                // Include every currently known row the requested restoration
                // would revive. The UI can show its complete impact, including
                // siblings, rather than only the edited draft's ancestors.
                let restorationRoots = deleted.reduce(into: [UUID: CarryGraphEntity]()) { roots, node in
                    if let batch = node.deletionBatch { roots[batch] = node }
                }
                let impactKey = restorationRoots.values.map { $0.id.uuidString }.sorted().joined(separator: ",")
                let impact: [CarryGraphEntity]
                if let known = impacts[impactKey] { impact = known }
                else {
                    var affected: [UUID: CarryReplicaPayload] = [:]
                    for batch in restorationRoots.keys {
                        let query = FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.remoteDeletionBatch == batch })
                        for record in try context.fetch(query) {
                            let value = try load(record.id)
                            if let value { affected[record.id] = value }
                        }
                    }
                    let roots = Dictionary(uniqueKeysWithValues: restorationRoots.values.map { ($0.id, $0.deletionBatch) })
                    impact = try affected.values.compactMap { candidate -> CarryGraphEntity? in
                        guard let remote = candidate.remote, remote.deletedAt != nil else { return nil }
                        var node: CarryGraphEntity? = remote, visited = Set<UUID>()
                        while let current = node {
                            guard visited.insert(current.id).inserted else { throw CarryReplicaFailure.invalidState }
                            if let batch = roots[current.id], batch != nil, batch == remote.deletionBatch { return remote }
                            node = try current.parentID.flatMap { try load($0)?.remote }
                        }
                        return nil
                    }.sorted { $0.id.uuidString < $1.id.uuidString }
                    impacts[impactKey] = impact
                }
                result.append(CarryGraphDeletionConflict(local: value.local, remote: value.remote,
                    fieldBaselines: value.intents, parentBaseline: value.structuralVersion,
                    action: value.structuralAction, deletedAncestors: deleted, restoreImpact: impact))
            }
        }
        return result.sorted { $0.local.id.uuidString < $1.local.id.uuidString }
    }

    /// Resolve a single reviewed draft without discarding a newer local edit.
    /// Restore uses exact reviewed deletion/subtree versions and field baselines.
    func resolveDeletion(_ review: CarryGraphDeletionConflict, restore: Bool) throws {
        try transaction {
            guard try frozenFlight(checkpoint()) == nil,
                  try deletionConflicts().contains(review), let record = try row(id: review.local.id) else {
                throw CarryReplicaFailure.invalidState
            }
            var value = try payload(record)
            if restore {
                // Each distinct deletion batch needs its own explicit restore.
                // Include descendants known now: the review's exact subtree
                // version protects against unseen remote changes at commit.
                let roots = review.deletedAncestors.reduce(into: [UUID: CarryGraphEntity]()) { result, entity in
                    if let batch = entity.deletionBatch { result[batch] = entity }
                }
                for ancestor in roots.values {
                    let members = review.restoreImpact.filter { $0.deletionBatch == ancestor.deletionBatch }.map(\.id)
                    try setTreeIntent(CarryNativeObservedTreeChange(id: ancestor.id, kind: ancestor.kind,
                        isDeleted: false, observed: ancestor, memberIDs: members))
                }
                // Only this reviewed draft is rebound. Other drafts retain
                // their own field conflicts and require separate review.
                for key in value.intents.keys { value.intents[key] = value.remote?.fieldVersions[key] ?? 0 }
                if value.structuralAction == "move" { value.structuralVersion = value.remote?.version }
                // setTreeIntent may have updated this very record.
                let updated = try payload(record)
                value.treeIntent = updated.treeIntent
                value.localDeletion = updated.localDeletion
                try store(value, in: record)
                _ = try overlayTreeIntents()
            } else {
                value.intents = [:]; value.structuralAction = nil; value.structuralVersion = nil
                if let remote = value.remote { value.local = remote; value.localDeletion = nil }
                else {
                    // Keep never-published creations as local trash, including
                    // their assets, instead of destroying the user's draft.
                    value.localDeletion = true; value.local.deletedAt = "1970-01-01T00:00:00Z"
                    value.structuralAction = "create"
                }
                try store(value, in: record)
            }
        }
    }

    /// Persist native business changes and their field intentions atomically.
    /// Projection must not call save() itself or contact a different container.
    func edit(_ desired: CarryGraphEntity,
              project: (ModelContext) throws -> Void = { _ in }) throws {
        try edit([desired], project: project)
    }

    /// Compound native operations project and enqueue in one database save.
    /// Callers must never build a plan through separately committed edit calls.
    func edit(_ desired: [CarryGraphEntity],
              project: (ModelContext) throws -> Void = { _ in }) throws {
        guard desired.count <= 20000 else { throw CarryReplicaFailure.tooManyChanges }
        guard Set(desired.map(\.id)).count == desired.count else { throw CarryReplicaFailure.invalidState }
        try transaction {
            _ = try checkpoint()
            for entity in desired { try upsert(entity) }
            try project(context)
        }
    }

    private func upsert(_ desired: CarryGraphEntity) throws {
        let row = try row(id: desired.id)
        var value: CarryReplicaPayload
        if let row {
            value = try payload(row)
            guard value.local.kind == desired.kind, value.localDeletion != true,
                  value.local.deletedAt == nil || value.remote?.deletedAt != nil,
                  desired.deletedAt == nil || desired.deletedAt == value.local.deletedAt else {
                throw CarryReplicaFailure.invalidState
            }
            let keys = Set(value.local.fields.keys).union(desired.fields.keys)
            for key in keys where value.local.fields[key] != desired.fields[key] {
                guard desired.fields[key] != nil else { throw CarryReplicaFailure.invalidState }
                if value.intents[key] == nil { value.intents[key] = value.remote?.fieldVersions[key] ?? 0 }
            }
            value.local.fields = desired.fields
            value.local.parentID = desired.parentID
            if let remote = value.remote {
                if desired.parentID != remote.parentID {
                    if value.structuralAction != "move" { value.structuralVersion = remote.version }
                    value.structuralAction = "move"
                } else {
                    value.structuralAction = nil
                    value.structuralVersion = nil
                }
            }
        } else {
            guard desired.version == 0, desired.deletedAt == nil else { throw CarryReplicaFailure.invalidState }
            value = CarryReplicaPayload(remote: nil, local: desired, intents: [:], structuralAction: "create", localCreation: true)
        }
        if let row { try store(value, in: row) }
        else {
            let record = CarryReplicaRecord(id: desired.id, payload: try encoder.encode(value), hasPendingChanges: true)
            try store(value, in: record); context.insert(record)
        }
    }

    /// Consume native field deltas and their journal records in one durable
    /// replica transaction. Caller passes only already-resolved asset references.
    func applyObserved(_ edits: [CarryNativeObservedEdit],
                       consume: (ModelContext) throws -> Void = { _ in }) throws {
        try applyObserved(prepare: { _ in edits }, consume: consume)
    }

    /// Asset bindings and upload jobs must commit with their graph intentions.
    /// Preparation is local only; uploads run after this durable transaction.
    func applyObserved(prepare: (ModelContext) throws -> [CarryNativeObservedEdit],
                       consume: (ModelContext) throws -> Void = { _ in }) throws {
        try consumeNative(prepare: { context in CarryNativeReplicaTransaction(edits: try prepare(context)) }, consume: consume)
    }

    func consumeNative(prepare: (ModelContext) throws -> CarryNativeReplicaTransaction,
                       consume: (ModelContext) throws -> Void = { _ in }) throws {
        try transaction {
            let native = try prepare(context), edits = native.edits
            guard edits.count <= 20000, Set(edits.map(\.id)).count == edits.count else {
                throw CarryReplicaFailure.invalidState
            }
            guard native.trees.count <= 20000, Set(native.trees.map(\.id)).count == native.trees.count else {
                throw CarryReplicaFailure.invalidState
            }
            for tree in native.trees where !tree.isDeleted { try setTreeIntent(tree) }
            if native.trees.contains(where: { !$0.isDeleted }) { _ = try overlayTreeIntents() }
            for edit in edits { try applyObserved(edit) }
            for tree in native.trees where tree.isDeleted { try setTreeIntent(tree) }
            _ = try overlayTreeIntents()
            try retireNeverPublishedTrees()
            try consume(context)
        }
    }

    func editTrees(_ changes: [CarryNativeObservedTreeChange]) throws {
        try consumeNative(prepare: { _ in CarryNativeReplicaTransaction(trees: changes) })
    }

    private func treeRows() throws -> [CarryReplicaRecord] {
        try context.fetch(FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.hasTreeIntent }))
    }

    private static func treeMetadata(_ entity: CarryGraphEntity) -> CarryGraphEntity {
        var metadata = entity; metadata.fields = [:]; metadata.fieldVersions = [:]
        return metadata
    }

    private func setTreeIntent(_ change: CarryNativeObservedTreeChange) throws {
        guard let record = try row(id: change.id), change.memberIDs.contains(change.id),
              Set(change.memberIDs).count == change.memberIDs.count, change.memberIDs.count <= 20000 else {
            throw CarryReplicaFailure.invalidState
        }
        var value = try payload(record)
        guard value.local.kind == change.kind else { throw CarryReplicaFailure.invalidState }
        guard Set(change.memberBaselines.keys).isSubset(of: Set(change.memberIDs)) else { throw CarryReplicaFailure.invalidState }
        for id in change.memberIDs {
            guard let member = try row(id: id) else { throw CarryReplicaFailure.missingBaseline }
            if let baseline = change.memberBaselines[id] {
                guard baseline.id == id, baseline.kind == (try payload(member).local.kind), baseline.version > 0 else {
                    throw CarryReplicaFailure.invalidState
                }
            }
        }
        if let observed = change.observed {
            guard observed.id == change.id, observed.kind == change.kind, observed.version > 0 else {
                throw CarryReplicaFailure.invalidState
            }
        } else if value.localCreation != true { throw CarryReplicaFailure.missingBaseline }
        let flight = try frozenFlight(checkpoint())
        let isTreeFrozen = flight?.treeOperations?[change.id] != nil ||
            flight?.command.mutations.contains { $0.id == change.id && ["delete", "restore"].contains($0.action) } == true
        if var intent = value.treeIntent {
            if intent.desiredDeleted == change.isDeleted { return }
            if !isTreeFrozen {
                value.treeIntent = nil
                try store(value, in: record)
                for id in intent.members {
                    guard let member = try row(id: id) else { throw CarryReplicaFailure.invalidState }
                    var child = try payload(member)
                    child.localDeletion = nil
                    child.local.deletedAt = child.remote?.deletedAt
                    child.local.deletionBatch = child.remote?.deletionBatch
                    try store(child, in: member)
                }
                try resetRemoteTreeOverlays()
                return
            }
            intent.desiredDeleted = change.isDeleted
            intent.members = Array(Set(intent.members).union(change.memberIDs))
            value.treeIntent = intent
        } else {
            if !change.isDeleted, value.remote?.deletedAt == nil {
                // Undo of a never-published local delete restores the queued
                // creation; no server-side restore or adopted version is needed.
                for id in change.memberIDs {
                    guard let member = try row(id: id) else { throw CarryReplicaFailure.invalidState }
                    var child = try payload(member)
                    child.localDeletion = nil; child.local.deletedAt = nil; child.local.deletionBatch = nil
                    try store(child, in: member)
                }
                return
            }
            value.treeIntent = CarryReplicaTreeIntent(id: UUID(), desiredDeleted: change.isDeleted,
                baseline: change.observed.map(Self.treeMetadata), members: change.memberIDs)
        }
        try store(value, in: record)
    }

    /// Explicit local deletion states survive incoming pages. Rare tree edits
    /// traverse the cached graph; normal packing ACKs with no active tree intent
    /// return immediately without decoding unrelated records.
    private func overlayTreeIntents() throws -> [CarryGraphEntity] {
        let roots = try treeRows()
        guard !roots.isEmpty else { return [] }
        // Relationship metadata is materialized separately from potentially
        // large photo/configuration payloads. Only affected subtrees are decoded.
        var indexed = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        func load(_ id: UUID) throws -> CarryReplicaRecord? {
            if let known = indexed[id] { return known }
            let record = try row(id: id)
            if let record { indexed[id] = record }
            return record
        }
        let rootValues = try roots.map { try payload($0) }
        func depth(_ value: CarryReplicaPayload) throws -> Int {
            var seen: Set<UUID> = [value.local.id], parent = value.local.parentID, result = 0
            while let id = parent {
                guard seen.insert(id).inserted else { throw CarryReplicaFailure.invalidState }
                result += 1; parent = try load(id)?.localParentID
            }
            return result
        }
        let ordered = try rootValues.map { (try depth($0), $0) }.sorted { $0.0 < $1.0 }
        var states: [UUID: Bool] = [:]
        for (_, root) in ordered {
            guard let intent = root.treeIntent else { throw CarryReplicaFailure.invalidState }
            var covered = Set(intent.members)
            if intent.desiredDeleted {
                covered = []; var pending = [root.local.id]
                while let id = pending.popLast() {
                    guard covered.insert(id).inserted else { throw CarryReplicaFailure.invalidState }
                    let query = FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.localParentID == id })
                    for child in try context.fetch(query) { indexed[child.id] = child; pending.append(child.id) }
                }
            }
            for id in covered {
                guard let record = try load(id) else { throw CarryReplicaFailure.invalidState }
                if !intent.desiredDeleted, let batch = root.remote?.deletionBatch,
                   let childBatch = record.remoteDeletionBatch, childBatch != batch { continue }
                states[id] = intent.desiredDeleted
            }
        }
        var changed: [CarryGraphEntity] = []
        for (id, deleted) in states {
            guard let record = indexed[id] else { throw CarryReplicaFailure.invalidState }
            var value = try payload(record)
            let old = value.local
            value.localDeletion = deleted
            value.local.deletedAt = deleted ? (value.remote?.deletedAt ?? "1970-01-01T00:00:00Z") : nil
            value.local.deletionBatch = deleted ? value.remote?.deletionBatch : nil
            try store(value, in: record)
            if old != value.local { changed.append(value.local) }
        }
        return changed
    }

    private func retireNeverPublishedTrees() throws {
        let flight = try frozenFlight(checkpoint())
        let flying = Set(flight?.command.mutations.map(\.id) ?? [])
        for record in try treeRows() {
            var value = try payload(record)
            guard let intent = value.treeIntent, intent.desiredDeleted, value.remote == nil,
                  flying.isDisjoint(with: intent.members) else { continue }
            var entirelyLocal = true
            for id in intent.members {
                guard let member = try row(id: id), try payload(member).remote == nil else { entirelyLocal = false; break }
            }
            if entirelyLocal { value.treeIntent = nil; try store(value, in: record) }
        }
    }

    private func settleSatisfiedTrees() throws {
        var settled = false
        for record in try treeRows() {
            var value = try payload(record)
            guard let intent = value.treeIntent, let remote = value.remote,
                  (remote.deletedAt != nil) == intent.desiredDeleted else { continue }
            var satisfied = true
            for id in intent.members {
                guard let member = try row(id: id) else { throw CarryReplicaFailure.invalidState }
                let child = try payload(member)
                if let state = child.remote, (state.deletedAt != nil) != intent.desiredDeleted { satisfied = false; break }
            }
            if satisfied { value.treeIntent = nil; try store(value, in: record); settled = true }
        }
        if settled { try resetRemoteTreeOverlays(); _ = try overlayTreeIntents() }
    }

    private func treeBaseline(_ value: CarryReplicaPayload) throws -> CarryGraphEntity? {
        guard let intent = value.treeIntent else { return nil }
        if let baseline = intent.baseline {
            if let chain = value.acceptedTree, chain.includes(baseline) { return chain.current }
            return baseline
        }
        if let chain = value.acceptedTree, chain.baseVersion == 0, chain.baseSubtreeVersion == 0 { return chain.current }
        guard value.remote == nil else { throw CarryReplicaFailure.missingBaseline }
        return nil
    }

    private func remotelyDescends(_ id: UUID, from ancestor: UUID) throws -> Bool {
        var current: UUID? = id, seen: Set<UUID> = []
        while let cursor = current {
            guard seen.insert(cursor).inserted else { throw CarryReplicaFailure.invalidState }
            if cursor == ancestor { return true }
            guard let record = try row(id: cursor) else { return false }
            current = record.remoteParentID
        }
        return false
    }

    /// Only the final receipt page can settle a destructive intention. An undo
    /// received while its delete was in flight keeps the desired live state and
    /// uses this exact delete ACK as the later restore baseline.
    private func finishTreeIntents(_ flight: CarryReplicaFlight) throws {
        var finished = false
        for (id, frozen) in flight.treeOperations ?? [:] {
            guard let record = try row(id: id) else { throw CarryReplicaFailure.invalidState }
            var value = try payload(record)
            guard var intent = value.treeIntent, let acknowledged = value.acceptedTree?.current,
                  (acknowledged.deletedAt != nil) == frozen.desiredDeleted else {
                throw CarryReplicaFailure.invalidReceipt
            }
            if intent.desiredDeleted == frozen.desiredDeleted { value.treeIntent = nil }
            else { intent.baseline = acknowledged; value.treeIntent = intent }
            try store(value, in: record)
            finished = true
        }
        guard finished else { return }
        try resetRemoteTreeOverlays()
        _ = try overlayTreeIntents()
    }

    private func resetRemoteTreeOverlays() throws {
        let query = FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.hasLocalTreeOverlay })
        for record in try context.fetch(query) {
            var value = try payload(record)
            guard value.localDeletion != nil else { continue }
            // A new child deleted before publication remains local trash; an
            // ancestor's ACK cannot accidentally enqueue its original create.
            if value.remote == nil, value.localDeletion == true { continue }
            value.localDeletion = nil
            value.local.deletedAt = value.remote?.deletedAt
            value.local.deletionBatch = value.remote?.deletionBatch
            try store(value, in: record)
        }
    }

    private func applyObserved(_ edit: CarryNativeObservedEdit) throws {
        guard !edit.isCreation || edit.observed == nil else { throw CarryReplicaFailure.invalidState }
        if let observed = edit.observed {
            guard observed.id == edit.id, observed.kind == edit.kind, observed.version > 0 else {
                throw CarryReplicaFailure.invalidState
            }
        }
        guard let existing = try row(id: edit.id) else {
            guard edit.isCreation, edit.observed == nil else { throw CarryReplicaFailure.missingBaseline }
            try upsert(CarryGraphEntity(id: edit.id, kind: edit.kind, parentID: edit.parentID,
                version: 0, subtreeVersion: 0, fields: edit.fields, fieldVersions: [:]))
            return
        }
        let before = try payload(existing)
        guard before.local.kind == edit.kind, before.localDeletion != true,
              before.local.deletedAt == nil || before.remote?.deletedAt != nil else {
            throw CarryReplicaFailure.invalidState
        }
        if edit.observed == nil {
            guard before.localCreation == true || before.remote == nil && before.structuralAction == "create" else {
                throw CarryReplicaFailure.invalidState
            }
        }
        if edit.isCreation {
            guard before.localCreation == true, before.remote == nil else { throw CarryReplicaFailure.invalidState }
        }
        var desired = before.local
        desired.fields.merge(edit.fields) { _, new in new }
        if edit.parentChanged { desired.parentID = edit.parentID }
        try upsert(desired)
        var value = try payload(existing)
        for key in edit.fields.keys where before.intents[key] == nil && value.intents[key] != nil {
            var baseline = edit.observed?.fieldVersions[key] ?? 0
            if let accepted = before.acceptedFields?[key], accepted.version > baseline,
               accepted.value == edit.previousFields[key] {
                // This advances only knowledge of OUR accepted value. A later
                // external pull is not permission to replace its field version.
                baseline = accepted.version
            }
            value.intents[key] = baseline
        }
        if edit.parentChanged, value.structuralAction == "move", before.structuralAction != "move" {
            var baseline = edit.observed?.version ?? 0
            if let accepted = before.acceptedStructure, accepted.parentID == edit.previousParentID,
               baseline >= accepted.continuousBase, baseline < accepted.version {
                baseline = accepted.version
            }
            guard baseline > 0 else { throw CarryReplicaFailure.missingBaseline }
            value.structuralVersion = baseline
        }
        try store(value, in: existing)
    }

    /// Freeze one account transaction. Subsequent local edits remain independent
    /// intentions until this immutable flight has a verified server receipt.
    func nextCommand() throws -> CarryGraphCommand? {
        try transaction {
            let state = try checkpoint()
            if state.blocked { throw CarryReplicaFailure.blocked }
            if let flight = try frozenFlight(state) { return flight.command }
            guard try deletionConflicts().isEmpty else { throw CarryReplicaFailure.blocked }
            try settleSatisfiedTrees()
            var mutations: [CarryGraphMutation] = []
            var desired: [UUID: CarryGraphEntity] = [:]
            let order = ["trip": 0, "libraryItem": 0, "section": 1, "day": 1, "lodging": 1,
                         "packingItem": 2, "stop": 2, "transport": 2, "photo": 3, "attachment": 3]
            var pendingValues: [CarryReplicaPayload] = []
            for row in try pendingRows() {
                var value = try payload(row)
                if let remote = value.remote {
                    for key in value.intents.keys where value.local.fields[key] == remote.fields[key] {
                        value.intents.removeValue(forKey: key)
                    }
                    if value.structuralAction == "move", value.local.parentID == remote.parentID {
                        value.structuralAction = nil
                        value.structuralVersion = nil
                    }
                    try store(value, in: row)
                }
                pendingValues.append(value)
            }
            let values = pendingValues.sorted {
                let lhs = order[$0.local.kind] ?? 99, rhs = order[$1.local.kind] ?? 99
                return lhs == rhs ? $0.local.id.uuidString < $1.local.id.uuidString : lhs < rhs
            }
            var treeOperations: [UUID: CarryReplicaTreeIntent] = [:]
            var treeBaselines: [UUID: CarryGraphEntity] = [:]
            let restoring = values.filter { $0.treeIntent?.desiredDeleted == false }
            for value in values where value.treeIntent != nil {
                guard let intent = value.treeIntent, let baseline = try treeBaseline(value),
                      baseline.version > 0, baseline.subtreeVersion > 0,
                      (baseline.deletedAt != nil) != intent.desiredDeleted else {
                    throw CarryReplicaFailure.missingBaseline
                }
                treeOperations[value.local.id] = intent
                treeBaselines[value.local.id] = baseline
            }
            var coveredRestores: Set<UUID> = []
            for value in restoring {
                for parent in restoring where parent.local.id != value.local.id {
                    if let batch = treeBaselines[parent.local.id]?.deletionBatch,
                       treeBaselines[value.local.id]?.deletionBatch == batch,
                       try remotelyDescends(value.local.id, from: parent.local.id) {
                        coveredRestores.insert(value.local.id); break
                    }
                }
            }
            let explicitRestores = Set(restoring.map { $0.local.id }).subtracting(coveredRestores)
            for value in values {
                guard let intent = value.treeIntent, let baseline = treeBaselines[value.local.id],
                      intent.desiredDeleted || !coveredRestores.contains(value.local.id) else { continue }
                let fields = Dictionary(uniqueKeysWithValues: value.intents.keys.map { ($0, value.local.fields[$0] ?? .null) })
                mutations.append(CarryGraphMutation(id: value.local.id, kind: value.local.kind,
                    action: intent.desiredDeleted ? "delete" : "restore", baseVersion: baseline.version,
                    baseSubtreeVersion: baseline.subtreeVersion,
                    parentID: !intent.desiredDeleted && value.local.parentID != baseline.parentID ? value.local.parentID : nil,
                    fields: !intent.desiredDeleted && !fields.isEmpty ? fields : nil))
                desired[value.local.id] = value.local
            }
            for value in values {
                guard value.local.deletedAt == nil, !explicitRestores.contains(value.local.id) else { continue }
                guard value.structuralAction != nil || !value.intents.isEmpty else { continue }
                guard order[value.local.kind] != nil else { throw CarryReplicaFailure.invalidState }
                let action = value.structuralAction ?? "patch"
                guard ["create", "patch", "move"].contains(action) else { throw CarryReplicaFailure.invalidState }
                let changes = action == "create" ? value.local.fields
                    : Dictionary(uniqueKeysWithValues: value.intents.keys.map { ($0, value.local.fields[$0] ?? .null) })
                // Older experimental caches without a move baseline must stop
                // for review, never infer consent to overwrite a newer parent.
                if action == "move", value.structuralVersion == nil { throw CarryReplicaFailure.invalidState }
                var moveVersion = value.structuralVersion ?? 0
                if action == "move", let remote = value.remote, remote.deletedAt != nil {
                    for parent in restoring {
                        if let batch = treeBaselines[parent.local.id]?.deletionBatch, remote.deletionBatch == batch,
                           try remotelyDescends(remote.id, from: parent.local.id) {
                            guard remote.version < Int.max else { throw CarryReplicaFailure.invalidState }
                            moveVersion = remote.version + 1; break
                        }
                    }
                }
                mutations.append(CarryGraphMutation(id: value.local.id, kind: value.local.kind,
                    action: action, baseVersion: action == "move" ? moveVersion : (value.remote?.version ?? 0),
                    baseSubtreeVersion: nil, parentID: action == "patch" ? nil : value.local.parentID,
                    fields: changes, fieldVersions: action == "create" ? nil : value.intents))
                desired[value.local.id] = value.local
            }
            mutations.sort {
                let ld = $0.action == "delete", rd = $1.action == "delete"
                if ld != rd { return !ld }
                let lhs = order[$0.kind] ?? 99, rhs = order[$1.kind] ?? 99
                if lhs != rhs { return ld ? lhs > rhs : lhs < rhs }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard Set(mutations.map(\.id)).count == mutations.count else { throw CarryReplicaFailure.invalidState }
            guard mutations.count <= 20000 else { throw CarryReplicaFailure.tooManyChanges }
            if mutations.isEmpty { return nil }
            let command = CarryGraphCommand(requestID: UUID(), mutations: mutations)
            let flight = CarryReplicaFlight(command: command, desired: desired, treeOperations: treeOperations.isEmpty ? nil : treeOperations)
            state.flight = try encoder.encode(flight)
            state.flightID = command.requestID
            cachedFlight = flight
            return command
        }
    }

    /// Projection receives only changed local snapshots, including tombstones.
    /// Consumers apply the whole delta atomically, not a replacement full graph.
    func accept(_ receipt: CarryGraphReceipt,
                project: ([CarryGraphEntity], ModelContext) throws -> Void = { _, _ in }) throws {
        try transaction {
            let state = try checkpoint()
            guard receipt.status == "saved_to_account", let bytes = state.flight else { throw CarryReplicaFailure.invalidReceipt }
            let flight = try decoder.decode(CarryReplicaFlight.self, from: bytes)
            guard flight.command.requestID == receipt.requestID,
                  !receipt.changes.isEmpty,
                  receipt.cursor == receipt.changes.last?.sequence,
                  Set(flight.command.mutations.map(\.id)).isSubset(of: Set(receipt.changes.filter { $0.metadataOnly != true }.map { $0.entity.id })) else {
                throw CarryReplicaFailure.invalidReceipt
            }
            for (previous, next) in zip(receipt.changes, receipt.changes.dropFirst()) {
                guard previous.sequence < Int.max, next.sequence == previous.sequence + 1 else { throw CarryReplicaFailure.invalidReceipt }
            }
            let changed = try merge(receipt.changes, flight: flight)
            try finishTreeIntents(flight)
            state.flight = nil
            state.flightID = nil
            cachedFlight = nil
            mutationIndex = nil
            state.failureData = nil
            state.blocked = false
            // A receipt can start after unseen edits by another client. Only a
            // contiguous pull advances the durable cursor, never an upload ACK.
            if !changed.isEmpty { try project(changed, context) }
        }
    }

    func receiptProgress(for requestID: UUID) throws -> CarryGraphReceiptProgress? {
        guard let progress = try receiptCheckpoint(requestID) else { return nil }
        return CarryGraphReceiptProgress(requestID: requestID, cursor: progress.cursor,
            changeCount: progress.changeCount, nextOffset: progress.nextOffset)
    }

    private func receiptCheckpoint(_ requestID: UUID) throws -> CarryReplicaReceiptCheckpoint? {
        var query = FetchDescriptor<CarryReplicaReceiptCheckpoint>(predicate: #Predicate { $0.requestID == requestID })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    /// Each page and its durable offset commit together. The original command
    /// remains frozen until every changed entity has an authenticated ACK.
    func accept(_ page: CarryGraphReceiptPage, summary: CarryGraphReceiptSummary,
                project: ([CarryGraphEntity], ModelContext) throws -> Void = { _, _ in }) throws {
        try transaction {
            let state = try checkpoint()
            guard summary.status == "saved_to_account", summary.changeCount > 0, summary.changeCount <= 1_000_000,
                  summary.cursor >= summary.changeCount,
                  summary.requestID == page.requestID, summary.cursor == page.cursor,
                  summary.changeCount == page.changeCount, let flight = try frozenFlight(state) else {
                throw CarryReplicaFailure.invalidReceipt
            }
            guard flight.command.requestID == summary.requestID else { throw CarryReplicaFailure.invalidReceipt }
            let progress: CarryReplicaReceiptCheckpoint
            if let previous = try receiptCheckpoint(summary.requestID) {
                guard previous.cursor == summary.cursor, previous.changeCount == summary.changeCount else {
                    throw CarryReplicaFailure.invalidReceipt
                }
                progress = previous
            } else {
                progress = CarryReplicaReceiptCheckpoint(summary: summary)
                context.insert(progress)
            }
            guard progress.nextOffset >= 0, progress.nextOffset <= summary.changeCount,
                  !page.changes.isEmpty, page.changes.count <= 500,
                  page.changes.count <= summary.changeCount - progress.nextOffset,
                  page.nextOffset == progress.nextOffset + page.changes.count,
                  page.nextOffset <= summary.changeCount, page.hasMore == (page.nextOffset < summary.changeCount) else {
                throw CarryReplicaFailure.invalidReceipt
            }
            var last = progress.lastSequence
            for change in page.changes {
                guard change.sequence > 0 else { throw CarryReplicaFailure.invalidReceipt }
                if progress.nextOffset == 0 && last == 0 { last = change.sequence - 1 }
                guard last < Int.max, change.sequence == last + 1 else { throw CarryReplicaFailure.invalidReceipt }
                last = change.sequence
            }
            let changed = try merge(page.changes, flight: flight)
            progress.nextOffset = page.nextOffset
            progress.lastSequence = last
            if !page.hasMore {
                guard last == summary.cursor else { throw CarryReplicaFailure.invalidReceipt }
                let requestID = summary.requestID
                let acknowledged = try context.fetch(FetchDescriptor<CarryReplicaRecord>(
                    predicate: #Predicate { $0.acknowledgedRequestID == requestID }))
                let ids = Set(acknowledged.map(\.id))
                guard Set(flight.command.mutations.map(\.id)).isSubset(of: ids) else { throw CarryReplicaFailure.invalidReceipt }
                try finishTreeIntents(flight)
                state.flight = nil
                state.flightID = nil
                cachedFlight = nil
                mutationIndex = nil
                state.failureData = nil
                state.blocked = false
                context.delete(progress)
            }
            if !changed.isEmpty { try project(changed, context) }
        }
    }

    func receive(_ page: CarryGraphPage,
                 project: ([CarryGraphEntity], ModelContext) throws -> Void = { _, _ in }) throws {
        try transaction {
            let state = try checkpoint()
            guard !page.hasMore || !page.changes.isEmpty else { throw CarryReplicaFailure.invalidCursor }
            var expected = state.cursor
            for change in page.changes {
                guard expected < Int.max else { throw CarryReplicaFailure.invalidCursor }
                expected += 1
                guard change.sequence == expected else { throw CarryReplicaFailure.invalidCursor }
            }
            guard page.cursor == expected else { throw CarryReplicaFailure.invalidCursor }
            let changed = try merge(page.changes, flight: nil)
            try retireRejectedDeletedFlight()
            if !changed.isEmpty, try deletionConflicts().isEmpty { try project(changed, context) }
            state.cursor = page.cursor
        }
    }

    private func merge(_ changes: [CarryGraphChange], flight: CarryReplicaFlight?) throws -> [CarryGraphEntity] {
        var changed: [CarryGraphEntity] = []
        let sentByID: [UUID: CarryGraphMutation]
        if let flight {
            if let mutationIndex, mutationIndex.requestID == flight.command.requestID {
                sentByID = mutationIndex.values
            } else {
                sentByID = Dictionary(uniqueKeysWithValues: flight.command.mutations.map { ($0.id, $0) })
                mutationIndex = (flight.command.requestID, sentByID)
            }
        } else { sentByID = [:] }
        let fullAcknowledgements = Set(changes.filter { $0.metadataOnly != true }.map { $0.entity.id })
        var acceptedTrees: [UUID: CarryReplicaAcceptedTree] = [:]
        // Process only the newest snapshot of each entity within this response.
        // Ancestor metadata updates can repeat an entity without a field revision.
        var latest: [UUID: CarryGraphEntity] = [:]
        for change in changes {
            guard change.entity.version > 0, change.sequence > 0,
                  change.entity.subtreeVersion == change.sequence else { throw CarryReplicaFailure.invalidReceipt }
            var incoming = change.entity
            if change.metadataOnly == true {
                guard incoming.fields.isEmpty, incoming.fieldVersions.isEmpty else { throw CarryReplicaFailure.invalidReceipt }
                var known = latest[incoming.id]
                if let known, known.version > incoming.version { throw CarryReplicaFailure.invalidReceipt }
                if known == nil || (known?.version ?? 0) < incoming.version,
                   let row = try row(id: incoming.id) {
                    let stored = try payload(row)
                    if let remote = stored.remote ?? stored.unconfirmedRemote,
                       known == nil || remote.version > (known?.version ?? 0) { known = remote }
                }
                // A later acknowledged field revision already includes this
                // older metadata-only event. It must never roll fields back.
                if let known, known.version > incoming.version { continue }
                guard let known, known.version == incoming.version else { throw CarryReplicaFailure.missingBaseline }
                guard known.kind == incoming.kind, known.parentID == incoming.parentID,
                      known.deletedAt == incoming.deletedAt, known.deletionBatch == incoming.deletionBatch else {
                    throw CarryReplicaFailure.invalidReceipt
                }
                incoming.fields = known.fields
                incoming.fieldVersions = known.fieldVersions
            }
            if let previous = latest[incoming.id], previous.version > incoming.version {
                throw CarryReplicaFailure.invalidReceipt
            }
            if flight != nil {
                let beforeVersion = change.previousVersion
                let beforeSubtree = change.previousSubtreeVersion
                let creating = change.metadataOnly != true && sentByID[incoming.id]?.action == "create"
                    && incoming.version == 1
                if let beforeVersion, let beforeSubtree {
                    guard beforeVersion > 0, beforeVersion <= incoming.version,
                          beforeSubtree > 0, beforeSubtree < incoming.subtreeVersion else {
                        throw CarryReplicaFailure.invalidReceipt
                    }
                    var previous = acceptedTrees[incoming.id]
                    if previous == nil, let record = try row(id: incoming.id) {
                        previous = try payload(record).acceptedTree
                    }
                    if var chain = previous, chain.current.version == beforeVersion,
                       chain.current.subtreeVersion == beforeSubtree {
                        chain.current = Self.treeMetadata(incoming); acceptedTrees[incoming.id] = chain
                    } else {
                        acceptedTrees[incoming.id] = CarryReplicaAcceptedTree(baseVersion: beforeVersion,
                            baseSubtreeVersion: beforeSubtree, current: Self.treeMetadata(incoming))
                    }
                } else if creating {
                    acceptedTrees[incoming.id] = CarryReplicaAcceptedTree(baseVersion: 0, baseSubtreeVersion: 0, current: Self.treeMetadata(incoming))
                }
            }
            latest[incoming.id] = incoming
        }
        for incoming in latest.values {
            var remote = incoming
            if let row = try row(id: remote.id) {
                var value = try payload(row)
                guard value.local.kind == remote.kind else { throw CarryReplicaFailure.invalidReceipt }
                let sent = sentByID[remote.id]
                let sentDesired = flight?.desired[remote.id]
                if value.remote == nil && value.structuralAction == "create" && sent?.action != "create" {
                    // Bind a UUID to our creation only through its own ACK, but
                    // retain newer pulls durably while that ACK is in flight.
                    // Advancing the cursor after discarding these snapshots
                    // would otherwise lose later remote edits permanently.
                    if value.unconfirmedRemote == nil ||
                        (value.unconfirmedRemote?.subtreeVersion ?? 0) < incoming.subtreeVersion {
                        value.unconfirmedRemote = incoming
                        try store(value, in: row)
                    }
                    continue
                }
                if let unconfirmed = value.unconfirmedRemote,
                   unconfirmed.version > remote.version || unconfirmed.subtreeVersion > remote.subtreeVersion {
                    remote = unconfirmed
                }
                if let previous = value.remote,
                   previous.version > remote.version || previous.subtreeVersion > remote.subtreeVersion {
                    if flight == nil { continue }
                    // Resolve accepted intentions using the ACK's versions,
                    // while retaining a newer already-pulled server snapshot.
                    remote = previous
                }
                value.unconfirmedRemote = nil
                var local = remote
                for (key, baseline) in value.intents {
                    let ownAccepted = sent?.fields?[key] != nil && fullAcknowledgements.contains(incoming.id)
                    if ownAccepted {
                        if value.local.fields[key] == sentDesired?.fields[key] {
                            value.intents.removeValue(forKey: key)
                        } else {
                            value.intents[key] = incoming.fieldVersions[key] ?? 0
                            local.fields[key] = value.local.fields[key]
                        }
                    } else {
                        value.intents[key] = baseline
                        local.fields[key] = value.local.fields[key]
                    }
                }
                // A local create has no initial field intents. Edits made after
                // its flight was frozen must survive the create acknowledgement.
                if let sentDesired, sent?.action == "create" {
                    for (key, desired) in value.local.fields where desired != sentDesired.fields[key] {
                        local.fields[key] = desired
                        value.intents[key] = incoming.fieldVersions[key] ?? 0
                    }
                }
                let movedAfterSend = sentDesired.map { value.local.parentID != $0.parentID } ?? false
                let unsentMove = (sent == nil || sent?.action == "delete") && value.structuralAction == "move"
                    && value.local.parentID != value.remote?.parentID
                if movedAfterSend || unsentMove {
                    local.parentID = value.local.parentID
                    value.structuralAction = "move"
                    // Our acknowledged operation provides a new baseline only
                    // for changes made AFTER that immutable flight. A remote
                    // pull cannot advance an earlier unsent structural intent.
                    if sent != nil,
                       incoming.parentID == sentDesired?.parentID ||
                        (value.structuralVersion == value.remote?.version && incoming.parentID == value.remote?.parentID) {
                        value.structuralVersion = incoming.version
                    }
                } else if sent != nil && sent?.action != "delete" {
                    value.structuralAction = nil
                    value.structuralVersion = nil
                }
                value.remote = remote
                if let deleted = value.localDeletion {
                    local.deletedAt = deleted ? (remote.deletedAt ?? "1970-01-01T00:00:00Z") : nil
                    local.deletionBatch = deleted ? remote.deletionBatch : nil
                }
                value.local = local
                if let chain = acceptedTrees[incoming.id] { value.acceptedTree = chain }
                if let flight, let sent, fullAcknowledgements.contains(incoming.id) {
                    row.acknowledgedRequestID = flight.command.requestID
                    var accepted = value.acceptedFields ?? [:]
                    for key in sent.fields?.keys.map({ $0 }) ?? [] {
                        if let field = incoming.fields[key], let version = incoming.fieldVersions[key],
                           version > (accepted[key]?.version ?? -1) {
                            accepted[key] = CarryReplicaAcceptedField(value: field, version: version)
                        }
                    }
                    value.acceptedFields = accepted
                    if incoming.version > (value.acceptedStructure?.version ?? 0) {
                        let base = value.acceptedStructure?.version == incoming.version - 1
                            ? (value.acceptedStructure?.continuousBase ?? incoming.version - 1) : incoming.version - 1
                        value.acceptedStructure = CarryReplicaAcceptedStructure(version: incoming.version,
                            continuousBase: base, parentID: incoming.parentID)
                    }
                }
                try store(value, in: row)
                changed.append(local)
            } else {
                var value = CarryReplicaPayload(remote: remote, local: remote, intents: [:], structuralAction: nil)
                value.acceptedTree = acceptedTrees[incoming.id]
                let row = CarryReplicaRecord(id: remote.id, payload: try encoder.encode(value),
                                             hasPendingChanges: false)
                row.remoteDeletionBatch = remote.deletionBatch
                row.localParentID = remote.parentID; row.remoteParentID = remote.parentID
                row.remoteDeleted = remote.deletedAt != nil
                context.insert(row)
                changed.append(remote)
            }
        }
        let overlaid = try overlayTreeIntents()
        let overlays = Dictionary(uniqueKeysWithValues: overlaid.map { ($0.id, $0) })
        var emitted = Set(changed.map(\.id))
        changed = changed.map { overlays[$0.id] ?? $0 }
        for entity in overlaid where emitted.insert(entity.id).inserted { changed.append(entity) }
        return changed
    }

    /// A permanent rejection stays visible until the user resolves it. A network
    /// timeout leaves the original flight intact for an exactly-once retry.
    func blockFlight(details: Data? = nil) throws {
        try transaction {
            guard details == nil || (details?.count ?? 0) <= 2 * 1024 * 1024 else {
                throw CarryReplicaFailure.invalidReceipt
            }
            let state = try checkpoint()
            state.blocked = true
            state.failureData = details
        }
    }

    func abandonedPublicationRequests() throws -> [UUID] { try checkpoint().abandonedRequests }

    var retentionRevision: Int64 { get throws { try checkpoint().revision } }

    /// Historical remote/local baselines and immutable requests remain roots
    /// until their own protocol lifecycle retires them. Tombstones are retained
    /// without guessing a purge deadline from the device's clock.
    func assetRetentionReferences() throws -> Set<UUID> {
        try Self.retainedAssetIDs(payloads: rows().map(\.payload), flight: checkpoint().flight)
    }

    func assetRetentionReferencesAsync() async throws -> Set<UUID> {
        let revision = try retentionRevision
        let bytes = try rows().map(\.payload), flight = try checkpoint().flight
        let result = try await Self.decodeRetainedAssetIDs(payloads: bytes, flight: flight)
        guard try retentionRevision == revision else { throw CarryReplicaFailure.projectionChanged }
        return result
    }

    @concurrent nonisolated private static func decodeRetainedAssetIDs(payloads: [Data], flight: Data?) async throws -> Set<UUID> {
        try retainedAssetIDs(payloads: payloads, flight: flight)
    }

    nonisolated private static func retainedAssetIDs(payloads: [Data], flight: Data?) throws -> Set<UUID> {
        let decoder = JSONDecoder()
        var result: Set<UUID> = []
        func collect(_ entity: CarryGraphEntity?) throws {
            if let entity { result.formUnion(try CarryAccountAssetReferences.ids(in: entity.fields)) }
        }
        for bytes in payloads {
            try Task.checkCancellation()
            let value = try decoder.decode(CarryReplicaPayload.self, from: bytes)
            try collect(value.local); try collect(value.remote); try collect(value.unconfirmedRemote)
            try collect(value.acceptedTree?.current); try collect(value.treeIntent?.baseline)
            let accepted = (value.acceptedFields ?? [:]).mapValues(\.value)
            result.formUnion(try CarryAccountAssetReferences.ids(in: accepted))
        }
        if let flight {
            let value = try decoder.decode(CarryReplicaFlight.self, from: flight)
            for mutation in value.command.mutations { result.formUnion(try CarryAccountAssetReferences.ids(in: mutation.fields ?? [:])) }
            for entity in value.desired.values { try collect(entity) }
            for tree in value.treeOperations?.values ?? Dictionary<UUID, CarryReplicaTreeIntent>().values { try collect(tree.baseline) }
        }
        return result
    }
    func didReleaseAbandonedPublication(_ id: UUID) throws {
        try transaction { let state = try checkpoint(); state.abandonedRequests.removeAll { $0 == id } }
    }
    private func abandon(_ request: UUID, state: CarryReplicaCheckpoint) {
        if !state.abandonedRequests.contains(request) { state.abandonedRequests.append(request) }
    }

    private func retireRejectedDeletedFlight() throws {
        struct Failure: Decodable { let error: String }
        let state = try checkpoint()
        guard state.blocked, let bytes = state.failureData,
              ["field_conflict", "move_conflict", "deleted_entity", "invalid_parent"].contains(try decoder.decode(Failure.self, from: bytes).error),
              let flight = try frozenFlight(state), try !deletionConflicts().isEmpty else { return }
        // A definitive atomic rejection applied nothing. Retain every draft,
        // but let its remote-deletion review replace the rejected request UI.
        abandon(flight.command.requestID, state: state)
        state.flight = nil; state.flightID = nil; state.failureData = nil; state.blocked = false
        cachedFlight = nil; mutationIndex = nil
    }

    func conflictReview() throws -> CarryGraphConflictReview? {
        struct Failure: Decodable { let error: String; let conflict: CarryGraphValue? }
        let state = try checkpoint()
        guard state.blocked, let bytes = state.failureData, let flight = try frozenFlight(state) else { return nil }
        let failure = try decoder.decode(Failure.self, from: bytes)
        let kind: CarryGraphConflictReviewKind
        let currentValue: CarryGraphValue
        var fields: [String] = []
        switch failure.error {
        case "field_conflict":
            guard case .object(let details) = failure.conflict, let current = details["current"],
                  case .array(let names) = details["fields"] else { throw CarryReplicaFailure.invalidState }
            kind = .field; currentValue = current
            fields = try names.map { value in
                guard case .string(let name) = value else { throw CarryReplicaFailure.invalidState }
                return name
            }.sorted()
        case "move_conflict", "subtree_conflict":
            guard let current = failure.conflict else { throw CarryReplicaFailure.invalidState }
            kind = failure.error == "move_conflict" ? .move : .subtree; currentValue = current
        default: return nil
        }
        var current = try decoder.decode(CarryGraphEntity.self, from: encoder.encode(currentValue))
        guard let record = try row(id: current.id), let mutation = flight.command.mutations.first(where: { $0.id == current.id }) else {
            throw CarryReplicaFailure.invalidState
        }
        let value = try payload(record)
        guard current.kind == mutation.kind, current.kind == value.local.kind,
              (kind != .field || ["patch", "move"].contains(mutation.action)),
              (kind != .move || mutation.action == "move"),
              (kind != .subtree || ["delete", "restore"].contains(mutation.action)),
              kind != .field || !fields.isEmpty && Set(fields).count == fields.count && fields.allSatisfy({ mutation.fields?[$0] != nil }) else {
            throw CarryReplicaFailure.invalidState
        }
        if let newer = value.remote, newer.version >= current.version, newer.subtreeVersion >= current.subtreeVersion { current = newer }
        var impact: [CarryGraphEntity] = []
        if kind == .subtree {
            var pending = [current.id], visited = Set<UUID>()
            while let id = pending.popLast() {
                guard visited.insert(id).inserted else { throw CarryReplicaFailure.invalidState }
                if let child = try row(id: id), let remote = try payload(child).remote { impact.append(remote) }
                let query = FetchDescriptor<CarryReplicaRecord>(predicate: #Predicate { $0.remoteParentID == id })
                pending.append(contentsOf: try context.fetch(query).map(\.id))
            }
        }
        return CarryGraphConflictReview(requestID: flight.command.requestID, kind: kind, action: mutation.action,
            local: value.local, current: current, fields: fields,
            impact: impact.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    /// Review equality binds BOTH the currently displayed draft and remote
    /// impact. Clearing a rejected request never clears unrelated draft intent.
    func resolveReviewedConflict(_ review: CarryGraphConflictReview,
                                 fields: [String: CarryGraphConflictChoice] = [:],
                                 parent: CarryGraphParentConflictChoice? = nil, tree: Bool? = nil) throws {
        try transaction {
            guard try conflictReview() == review, let record = try row(id: review.local.id) else {
                throw CarryReplicaFailure.invalidState
            }
            var value = try payload(record)
            let remote = review.current
            switch review.kind {
            case .field:
                guard remote.deletedAt == nil, Set(fields.keys) == Set(review.fields), parent == nil, tree == nil else {
                    throw CarryReplicaFailure.invalidState
                }
                for (key, choice) in fields {
                    switch choice {
                    case .local: value.intents[key] = remote.fieldVersions[key] ?? 0
                    case .remote: value.local.fields[key] = remote.fields[key] ?? .null; value.intents.removeValue(forKey: key)
                    case .edited(let replacement): value.local.fields[key] = replacement; value.intents[key] = remote.fieldVersions[key] ?? 0
                    }
                }
            case .move:
                guard remote.deletedAt == nil, fields.isEmpty, let parent, tree == nil else { throw CarryReplicaFailure.invalidState }
                switch parent {
                case .local: break
                case .remote: value.local.parentID = remote.parentID
                case .parent(let replacement): value.local.parentID = replacement
                }
                guard value.local.parentID != value.local.id else { throw CarryReplicaFailure.invalidState }
                value.structuralAction = value.local.parentID == remote.parentID ? nil : "move"
                value.structuralVersion = value.structuralAction == nil ? nil : remote.version
            case .subtree:
                guard fields.isEmpty, parent == nil, let tree, var intent = value.treeIntent else {
                    throw CarryReplicaFailure.invalidState
                }
                if tree {
                    intent.baseline = Self.treeMetadata(remote)
                    intent.members = Array(Set(intent.members).union(review.impact.map(\.id)))
                    value.treeIntent = intent
                } else { value.treeIntent = nil }
            }
            for (key, field) in remote.fields where value.intents[key] == nil { value.local.fields[key] = field }
            value.remote = remote; value.local.version = remote.version
            value.local.subtreeVersion = remote.subtreeVersion; value.local.fieldVersions = remote.fieldVersions
            try store(value, in: record)
            let state = try checkpoint()
            abandon(review.requestID, state: state)
            state.flight = nil; state.flightID = nil; state.failureData = nil; state.blocked = false
            cachedFlight = nil; mutationIndex = nil
            try resetRemoteTreeOverlays(); _ = try overlayTreeIntents()
        }
    }

    /// Resolve the exact field conflict the user reviewed. A new server edit
    /// after that version will conflict again, never receive a force overwrite.
    func resolveFields(requestID: UUID, serverVersion: Int,
                       choices: [String: CarryGraphConflictChoice],
                       project: ([CarryGraphEntity], ModelContext) throws -> Void = { _, _ in }) throws {
        struct Conflict: Decodable {
            let current: CarryGraphEntity
            let fields: [String]
        }
        struct Failure: Decodable { let error: String; let conflict: Conflict }
        try transaction {
            let state = try checkpoint()
            guard state.blocked, let failureData = state.failureData, let flightBytes = state.flight else {
                throw CarryReplicaFailure.invalidState
            }
            let failure = try decoder.decode(Failure.self, from: failureData)
            let flight = try decoder.decode(CarryReplicaFlight.self, from: flightBytes)
            let remote = failure.conflict.current
            guard failure.error == "field_conflict", flight.command.requestID == requestID,
                  remote.version == serverVersion,
                  Set(choices.keys) == Set(failure.conflict.fields),
                  let mutation = flight.command.mutations.first(where: { $0.id == remote.id }),
                  mutation.kind == remote.kind,
                  choices.keys.allSatisfy({ mutation.fields?[$0] != nil }),
                  let row = try row(id: remote.id) else {
                throw CarryReplicaFailure.invalidState
            }
            var value = try payload(row)
            guard value.remote == nil ||
                    (value.remote?.version ?? 0) <= remote.version &&
                    (value.remote?.subtreeVersion ?? 0) <= remote.subtreeVersion else {
                throw CarryReplicaFailure.invalidState
            }
            for (key, choice) in choices {
                switch choice {
                case .local:
                    value.intents[key] = remote.fieldVersions[key] ?? 0
                case .remote:
                    value.local.fields[key] = remote.fields[key] ?? .null
                    value.intents.removeValue(forKey: key)
                case .edited(let replacement):
                    value.local.fields[key] = replacement
                    value.intents[key] = remote.fieldVersions[key] ?? 0
                }
            }
            for (key, field) in remote.fields where value.intents[key] == nil { value.local.fields[key] = field }
            value.remote = remote
            value.local.version = remote.version
            value.local.subtreeVersion = remote.subtreeVersion
            value.local.fieldVersions = remote.fieldVersions
            try store(value, in: row)
            abandon(flight.command.requestID, state: state)
            state.flight = nil
            state.flightID = nil
            cachedFlight = nil
            mutationIndex = nil
            state.failureData = nil
            state.blocked = false
            try project([value.local], context)
        }
    }
    /// Rebind a reviewed move to the exact rejected request and server version.
    /// Reading a newer parent alone never grants permission to overwrite it.
    func resolveParent(requestID: UUID, serverVersion: Int, expectedLocalParentID: UUID?,
                       choice: CarryGraphParentConflictChoice,
                       project: ([CarryGraphEntity], ModelContext) throws -> Void = { _, _ in }) throws {
        struct Failure: Decodable { let error: String; let conflict: CarryGraphEntity }
        try transaction {
            let state = try checkpoint()
            guard state.blocked, let failureData = state.failureData, let flightBytes = state.flight else {
                throw CarryReplicaFailure.invalidState
            }
            let failure = try decoder.decode(Failure.self, from: failureData)
            let flight = try decoder.decode(CarryReplicaFlight.self, from: flightBytes)
            let remote = failure.conflict
            guard failure.error == "move_conflict", flight.command.requestID == requestID,
                  remote.version == serverVersion, remote.deletedAt == nil,
                  let mutation = flight.command.mutations.first(where: { $0.id == remote.id }),
                  mutation.action == "move", mutation.kind == remote.kind,
                  let row = try row(id: remote.id) else { throw CarryReplicaFailure.invalidState }
            var value = try payload(row)
            guard value.local.parentID == expectedLocalParentID,
                  value.remote == nil ||
                    (value.remote?.version ?? 0) <= remote.version &&
                    (value.remote?.subtreeVersion ?? 0) <= remote.subtreeVersion else {
                throw CarryReplicaFailure.invalidState
            }
            switch choice {
            case .local: break
            case .remote: value.local.parentID = remote.parentID
            case .parent(let parent): value.local.parentID = parent
            }
            guard value.local.parentID != value.local.id else { throw CarryReplicaFailure.invalidState }
            value.structuralAction = value.local.parentID == remote.parentID ? nil : "move"
            value.structuralVersion = value.structuralAction == nil ? nil : remote.version
            for (key, field) in remote.fields where value.intents[key] == nil { value.local.fields[key] = field }
            value.remote = remote
            value.local.version = remote.version
            value.local.subtreeVersion = remote.subtreeVersion
            value.local.fieldVersions = remote.fieldVersions
            try store(value, in: row)
            abandon(flight.command.requestID, state: state)
            state.flight = nil
            state.flightID = nil
            cachedFlight = nil
            mutationIndex = nil
            state.failureData = nil
            state.blocked = false
            try project([value.local], context)
        }
    }

}
