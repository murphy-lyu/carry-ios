import Foundation
import SwiftData

nonisolated struct CarryNativeJournalChangeSnapshot: Sendable, Equatable {
    let id: UUID
    let ordinal: Int
    let entityID: UUID
    let kind: String
    let action: String
    let source: CarryNativeSourceMetadata
    let previousSource: CarryNativeSourceMetadata?
    let observed: CarryGraphEntity?
    let changedFields: [String]
    let parentChanged: Bool
    let thumbnailChanged: Bool
    let thumbnailData: Data?

    var requiresAssetPreparation: Bool {
        guard action != "delete" else { return false }
        if thumbnailChanged || source.fileReferences != (previousSource?.fileReferences ?? [:]) { return true }
        if kind == "trip", changedFields.contains("backgroundsData"), !source.fileReferences.isEmpty { return true }
        if kind == "photo", changedFields.contains("assetLocalIdentifier") {
            return source.fields["assetLocalIdentifier"] != .string("") || previousSource?.fields["assetLocalIdentifier"] != .string("")
        }
        return false
    }
}

nonisolated struct CarryNativeJournalBatch: Sendable, Equatable {
    let accountID: UUID
    let id: UUID
    let sequence: Int64
    let createdAt: Date
    let changes: [CarryNativeJournalChangeSnapshot]
}
nonisolated enum CarryNativeJournalApplyResult: Sendable, Equatable { case consumed, deferred }
nonisolated struct CarryNativeResolvedFields: Sendable {
    var fields: [String: CarryGraphValue] = [:]
    /// Immutable prior local bindings, not a newer downloaded server snapshot.
    var previousFields: [String: CarryGraphValue] = [:]
}
enum CarryNativeJournalBridgeFailure: Error { case invalidState, wrongAccount, staleBatch, assetsDeferred }

/// The immutable business journal is the source of user intent. This bridge
/// never reads a newer wire baseline to reinterpret what the user had seen.
@MainActor
final class CarryNativeJournalBridge {
    typealias ResolveFields = (CarryNativeJournalChangeSnapshot, ModelContext) throws -> CarryNativeResolvedFields
    private let replica: CarryAccountReplica
    private let decoder = JSONDecoder()
    private static let rank = ["trip": 0, "libraryItem": 0, "section": 1, "day": 1, "lodging": 1,
        "packingItem": 2, "stop": 2, "transport": 2, "photo": 3, "attachment": 3]
    private static let assetFields: Set<String> = ["fileName", "fileAssetID", "thumbnailAssetID", "backgroundsData", "backgroundAssetIDs", "originalAssetID"]
    init(replica: CarryAccountReplica) { self.replica = replica }

    /// A fresh read context avoids retaining business objects or stale journal
    /// faults while asynchronous asset preparation runs outside the UI actor.
    func nextBatch() throws -> CarryNativeJournalBatch? {
        try readBatch(in: ModelContext(replica.context.container))
    }

    /// Resolver may install already-prepared local bindings/jobs in this RAW
    /// transaction. It must do no network or filesystem work. A deferred asset
    /// rolls all those bindings back and retains the entire immutable journal.
    func apply(batch: CarryNativeJournalBatch, resolveFields: ResolveFields? = nil) throws -> CarryNativeJournalApplyResult {
        guard batch.accountID == replica.accountID else { throw CarryNativeJournalBridgeFailure.wrongAccount }
        do {
            try replica.consumeNative(prepare: { context in
                guard let current = try self.readBatch(in: context), current == batch else { throw CarryNativeJournalBridgeFailure.staleBatch }
                return try self.plan(current, in: context, resolveFields: resolveFields)
            }, consume: { context in
                guard let current = try self.readBatch(in: context), current == batch else { throw CarryNativeJournalBridgeFailure.staleBatch }
                let transactionID = batch.id
                let rows = try context.fetch(FetchDescriptor<CarryNativeChange>(predicate: #Predicate { $0.transactionID == transactionID }))
                for row in rows { context.delete(row) }
                let transactions = try context.fetch(FetchDescriptor<CarryNativeTransaction>(predicate: #Predicate { $0.id == transactionID }))
                guard transactions.count == 1 else { throw CarryNativeJournalBridgeFailure.staleBatch }
                context.delete(transactions[0])
            })
            return .consumed
        } catch CarryNativeJournalBridgeFailure.assetsDeferred { return .deferred }
    }

    private func readBatch(in context: ModelContext) throws -> CarryNativeJournalBatch? {
        let owners = try context.fetch(FetchDescriptor<CarryNativeJournalOwner>())
        let checkpoints = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
        guard owners.count <= 1, checkpoints.count <= 1,
              owners.allSatisfy({ $0.accountID == replica.accountID }), checkpoints.allSatisfy({ $0.accountID == replica.accountID }) else {
            throw CarryNativeJournalBridgeFailure.wrongAccount
        }
        var request = FetchDescriptor<CarryNativeTransaction>(sortBy: [SortDescriptor(\.sequence)])
        request.fetchLimit = 2
        let transactions = try context.fetch(request)
        guard let transaction = transactions.first else {
            var orphan = FetchDescriptor<CarryNativeChange>(); orphan.fetchLimit = 1
            guard try context.fetch(orphan).isEmpty else { throw CarryNativeJournalBridgeFailure.invalidState }
            return nil
        }
        guard let owner = owners.first, transaction.sequence > 0, owner.sequence >= transaction.sequence,
              transaction.changeCount > 0, transaction.changeCount <= 20000,
              transactions.count < 2 || transactions[1].sequence > transaction.sequence else { throw CarryNativeJournalBridgeFailure.invalidState }
        let transactionID = transaction.id
        var changes = FetchDescriptor<CarryNativeChange>(predicate: #Predicate { $0.transactionID == transactionID }, sortBy: [SortDescriptor(\.ordinal)])
        changes.fetchLimit = 20001
        let rows = try context.fetch(changes)
        guard rows.count == transaction.changeCount, Set(rows.map(\.entityID)).count == rows.count else { throw CarryNativeJournalBridgeFailure.invalidState }
        let decoded = try rows.enumerated().map { index, row -> CarryNativeJournalChangeSnapshot in
            guard row.ordinal == index, Self.rank[row.kind] != nil, ["upsert", "delete", "restore"].contains(row.action),
                  Set(row.changedFields).count == row.changedFields.count else { throw CarryNativeJournalBridgeFailure.invalidState }
            let source = try decoder.decode(CarryNativeSourceMetadata.self, from: row.sourceData)
            let previous = try row.previousSourceData.map { try decoder.decode(CarryNativeSourceMetadata.self, from: $0) }
            let observed = try row.observedGraphData.map { try decoder.decode(CarryGraphEntity.self, from: $0) }
            guard source.id == row.entityID, source.kind == row.kind,
                  previous == nil || previous?.id == row.entityID && previous?.kind == row.kind,
                  observed == nil || observed?.id == row.entityID && observed?.kind == row.kind && (observed?.version ?? 0) > 0,
                  row.changedFields.allSatisfy({ source.fields[$0] != nil }) else { throw CarryNativeJournalBridgeFailure.invalidState }
            return CarryNativeJournalChangeSnapshot(id: row.id, ordinal: row.ordinal, entityID: row.entityID, kind: row.kind,
                action: row.action, source: source, previousSource: previous, observed: observed, changedFields: row.changedFields,
                parentChanged: row.parentChanged, thumbnailChanged: row.thumbnailChanged, thumbnailData: row.thumbnailData)
        }
        return CarryNativeJournalBatch(accountID: replica.accountID, id: transaction.id, sequence: transaction.sequence,
            createdAt: transaction.createdAt, changes: decoded)
    }

    private func plan(_ batch: CarryNativeJournalBatch, in context: ModelContext, resolveFields: ResolveFields?) throws -> CarryNativeReplicaTransaction {
        var edits: [CarryNativeObservedEdit] = []
        for change in batch.changes where change.action != "delete" {
            var fields: [String: CarryGraphValue] = [:]
            var previousFields: [String: CarryGraphValue] = [:]
            for key in change.changedFields { fields[key] = change.source.fields[key] }
            for key in fields.keys { previousFields[key] = change.previousSource?.fields[key] }
            if change.requiresAssetPreparation {
                guard let resolveFields else { throw CarryNativeJournalBridgeFailure.assetsDeferred }
                let resolved = try resolveFields(change, context)
                guard Set(resolved.fields.keys).isSubset(of: Self.assetFields),
                      Set(resolved.previousFields.keys).isSubset(of: Set(resolved.fields.keys)) else { throw CarryNativeJournalBridgeFailure.invalidState }
                func requireReference(_ key: String, hasBytes: Bool) throws {
                    guard let reference = resolved.fields[key] else { throw CarryNativeJournalBridgeFailure.assetsDeferred }
                    if hasBytes {
                        guard case .string(let raw) = reference, UUID(uuidString: raw) != nil else { throw CarryNativeJournalBridgeFailure.invalidState }
                    } else if reference != .null { throw CarryNativeJournalBridgeFailure.invalidState }
                }
                if change.thumbnailChanged { try requireReference("thumbnailAssetID", hasBytes: change.thumbnailData != nil) }
                if change.source.fileReferences["file"] != change.previousSource?.fileReferences["file"] {
                    try requireReference("fileAssetID", hasBytes: change.source.fileReferences["file"] != nil)
                }
                fields.merge(resolved.fields) { _, replacement in replacement }
                for key in resolved.fields.keys {
                    previousFields[key] = resolved.previousFields[key] ?? change.observed?.fields[key] ?? previousFields[key]
                }
            }
            edits.append(CarryNativeObservedEdit(id: change.entityID, kind: change.kind,
                isCreation: change.previousSource == nil && change.observed == nil, fields: fields, previousFields: previousFields,
                parentID: change.source.parentID, previousParentID: change.previousSource?.parentID,
                parentChanged: change.parentChanged, observed: change.observed))
        }
        edits.sort {
            let a = Self.rank[$0.kind] ?? 99, b = Self.rank[$1.kind] ?? 99
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
        let structural = Dictionary(uniqueKeysWithValues: batch.changes.filter { $0.action == "delete" || $0.action == "restore" }.map { ($0.entityID, $0) })
        func belongsToSameCascade(_ child: CarryNativeJournalChangeSnapshot, _ parent: CarryNativeJournalChangeSnapshot) -> Bool {
            guard child.action == parent.action else { return false }
            if child.action == "delete" { return true }
            guard let batch = child.observed?.deletionBatch else { return false }
            return parent.observed?.deletionBatch == batch
        }
        func root(of change: CarryNativeJournalChangeSnapshot) throws -> UUID {
            var current = change, visited: Set<UUID> = []
            while let parentID = current.source.parentID, let parent = structural[parentID], belongsToSameCascade(current, parent) {
                guard visited.insert(current.entityID).inserted else { throw CarryNativeJournalBridgeFailure.invalidState }
                current = parent
            }
            return current.entityID
        }
        var grouped: [UUID: [CarryNativeJournalChangeSnapshot]] = [:]
        for change in structural.values { grouped[try root(of: change), default: []].append(change) }
        var trees: [CarryNativeObservedTreeChange] = []
        for (id, members) in grouped {
            guard let source = structural[id] else { throw CarryNativeJournalBridgeFailure.invalidState }
            let baselines = Dictionary(uniqueKeysWithValues: members.compactMap { member in member.observed.map { (member.entityID, $0) } })
            trees.append(CarryNativeObservedTreeChange(id: id, kind: source.kind, isDeleted: source.action == "delete",
                observed: source.observed, memberIDs: members.map(\.entityID).sorted { $0.uuidString < $1.uuidString }, memberBaselines: baselines))
        }
        trees.sort {
            let a = Self.rank[$0.kind] ?? 99, b = Self.rank[$1.kind] ?? 99
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
        return CarryNativeReplicaTransaction(edits: edits, trees: trees)
    }
}
