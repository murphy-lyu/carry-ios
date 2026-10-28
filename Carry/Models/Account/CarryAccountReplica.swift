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
    var failureData: Data?
    var blocked: Bool
    init(accountID: UUID) {
        key = "account"; self.accountID = accountID; cursor = 0; blocked = false
    }
}

private struct CarryReplicaPayload: Codable {
    var remote: CarryGraphEntity?
    var local: CarryGraphEntity
    /// Each pending field retains its original server baseline independently.
    /// A pull must never advance it and silently overwrite a competing edit.
    var intents: [String: Int]
    var structuralAction: String?
    var structuralVersion: Int? = nil
    var unconfirmedRemote: CarryGraphEntity? = nil
}

private struct CarryReplicaFlight: Codable {
    let command: CarryGraphCommand
    let desired: [UUID: CarryGraphEntity]
}

/// Durable account replica and outbox. The caller's native graph projection and
/// its synchronization intent share this context/save. No network is performed
/// inside a local transaction. Transport retries reuse the frozen request ID.
@MainActor
final class CarryAccountReplica {
    let context: ModelContext
    let accountID: UUID
    private let save: (ModelContext) throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(SchemaV1.models + [CarryReplicaRecord.self, CarryReplicaCheckpoint.self])
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
        let state = try checkpoint()
        guard state.accountID == accountID else { throw CarryReplicaFailure.accountMismatch }
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
        row.payload = try encoder.encode(value)
        row.hasPendingChanges = value.structuralAction != nil || !value.intents.isEmpty
    }

    private func payload(_ row: CarryReplicaRecord) throws -> CarryReplicaPayload {
        try decoder.decode(CarryReplicaPayload.self, from: row.payload)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            try save(context)
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    func localEntities() throws -> [CarryGraphEntity] {
        try rows().map { try payload($0).local }
    }

    var cursor: Int { get throws { try checkpoint().cursor } }

    var pendingFailure: Data? { get throws { try checkpoint().failureData } }

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
        guard desired.count <= 500 else { throw CarryReplicaFailure.tooManyChanges }
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
            guard value.local.kind == desired.kind, value.local.deletedAt == nil,
                  desired.deletedAt == nil else { throw CarryReplicaFailure.invalidState }
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
            value = CarryReplicaPayload(remote: nil, local: desired, intents: [:], structuralAction: "create")
        }
        if let row { try store(value, in: row) }
        else { context.insert(CarryReplicaRecord(id: desired.id, payload: try encoder.encode(value),
                                                 hasPendingChanges: true)) }
    }

    /// Freeze one account transaction. Subsequent local edits remain independent
    /// intentions until this immutable flight has a verified server receipt.
    func nextCommand() throws -> CarryGraphCommand? {
        try transaction {
            let state = try checkpoint()
            if state.blocked { throw CarryReplicaFailure.blocked }
            if let bytes = state.flight { return try decoder.decode(CarryReplicaFlight.self, from: bytes).command }
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
            for value in values {
                guard value.structuralAction != nil || !value.intents.isEmpty else { continue }
                guard order[value.local.kind] != nil else { throw CarryReplicaFailure.invalidState }
                let action = value.structuralAction ?? "patch"
                guard ["create", "patch", "move"].contains(action) else { throw CarryReplicaFailure.invalidState }
                let changes = action == "create" ? value.local.fields
                    : Dictionary(uniqueKeysWithValues: value.intents.keys.map { ($0, value.local.fields[$0] ?? .null) })
                // Older experimental caches without a move baseline must stop
                // for review, never infer consent to overwrite a newer parent.
                if action == "move", value.structuralVersion == nil { throw CarryReplicaFailure.invalidState }
                mutations.append(CarryGraphMutation(id: value.local.id, kind: value.local.kind,
                    action: action, baseVersion: action == "move" ? (value.structuralVersion ?? 0) : (value.remote?.version ?? 0),
                    baseSubtreeVersion: nil, parentID: action == "patch" ? nil : value.local.parentID,
                    fields: changes, fieldVersions: action == "create" ? nil : value.intents))
                desired[value.local.id] = value.local
            }
            guard mutations.count <= 500 else { throw CarryReplicaFailure.tooManyChanges }
            if mutations.isEmpty { return nil }
            let command = CarryGraphCommand(requestID: UUID(), mutations: mutations)
            state.flight = try encoder.encode(CarryReplicaFlight(command: command, desired: desired))
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
                  Set(flight.command.mutations.map(\.id)).isSubset(of: Set(receipt.changes.map { $0.entity.id })) else {
                throw CarryReplicaFailure.invalidReceipt
            }
            for (previous, next) in zip(receipt.changes, receipt.changes.dropFirst()) {
                guard previous.sequence < Int.max, next.sequence == previous.sequence + 1 else { throw CarryReplicaFailure.invalidReceipt }
            }
            let changed = try merge(receipt.changes, flight: flight)
            state.flight = nil
            state.failureData = nil
            state.blocked = false
            // A receipt can start after unseen edits by another client. Only a
            // contiguous pull advances the durable cursor, never an upload ACK.
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
            if !changed.isEmpty { try project(changed, context) }
            state.cursor = page.cursor
        }
    }

    private func merge(_ changes: [CarryGraphChange], flight: CarryReplicaFlight?) throws -> [CarryGraphEntity] {
        var changed: [CarryGraphEntity] = []
        // Process only the newest snapshot of each entity within this response.
        // Ancestor metadata updates can repeat an entity without a field revision.
        var latest: [UUID: CarryGraphEntity] = [:]
        for change in changes {
            guard change.entity.version > 0, change.sequence > 0,
                  change.entity.subtreeVersion == change.sequence else { throw CarryReplicaFailure.invalidReceipt }
            if let previous = latest[change.entity.id], previous.version > change.entity.version {
                throw CarryReplicaFailure.invalidReceipt
            }
            latest[change.entity.id] = change.entity
        }
        for incoming in latest.values {
            var remote = incoming
            if let row = try row(id: remote.id) {
                var value = try payload(row)
                guard value.local.kind == remote.kind else { throw CarryReplicaFailure.invalidReceipt }
                let sent = flight?.command.mutations.first { $0.id == remote.id }
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
                    let ownAccepted = sent?.fields?[key] != nil
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
                let unsentMove = sent == nil && value.structuralAction == "move"
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
                } else if sent != nil {
                    value.structuralAction = nil
                    value.structuralVersion = nil
                }
                value.remote = remote
                value.local = local
                try store(value, in: row)
                changed.append(local)
            } else {
                let value = CarryReplicaPayload(remote: remote, local: remote, intents: [:], structuralAction: nil)
                let row = CarryReplicaRecord(id: remote.id, payload: try encoder.encode(value),
                                             hasPendingChanges: false)
                context.insert(row)
                changed.append(remote)
            }
        }
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
            state.flight = nil
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
            state.flight = nil
            state.failureData = nil
            state.blocked = false
            try project([value.local], context)
        }
    }

}
