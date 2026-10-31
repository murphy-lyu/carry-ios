import Foundation
import SwiftData

nonisolated struct CarryNativeAssetSourceRequest: Sendable {
    let accountID: UUID
    let entityID: UUID
    let entityKind: String
    let slot: String
    let reference: String
}

enum CarryNativeAssetCoordinatorFailure: Error {
    case wrongAccount, invalidState, sourceUnavailable, publicationNotReady, busy, closed
}

private nonisolated struct CarryNativePreparedAsset: Sendable {
    let slot: String
    let sourceReference: String?
    let snapshot: CarryAccountAssetSnapshot
    let contentType: String
}

private nonisolated struct CarryNativePreparedAssetChange: Sendable {
    let change: CarryNativeJournalChangeSnapshot
    let assets: [CarryNativePreparedAsset]
    let replacedSlots: Set<String>
}

/// The journal owns intent; this coordinator owns asynchronous byte preparation.
/// resolveFields is deliberately synchronous and performs metadata operations
/// only, so the bridge can commit bindings and intent in one RAW transaction.
@MainActor
final class CarryNativeAssetCoordinator {
    typealias ResolveSource = @Sendable (CarryNativeAssetSourceRequest) async throws -> URL
    typealias Upload = @Sendable (CarryAssetDescriptor, URL) async throws -> Void
    let accountID: UUID
    private let cache: CarryAccountAssetCache
    private let queue: CarryAccountAssetQueue
    private let resolveSource: ResolveSource
    private let upload: Upload
    private var preparedBatch: CarryNativeJournalBatch?
    private var prepared: [UUID: CarryNativePreparedAssetChange] = [:]
    private var generation = UUID()
    private var preparing = false
    private var uploading = false
    private var closed = false

    init(accountID: UUID, cache: CarryAccountAssetCache,
         resolveSource: @escaping ResolveSource, upload: @escaping Upload) throws {
        guard cache.accountID == accountID else { throw CarryNativeAssetCoordinatorFailure.wrongAccount }
        self.accountID = accountID; self.cache = cache
        queue = CarryAccountAssetQueue(accountID: accountID)
        self.resolveSource = resolveSource; self.upload = upload
    }

    /// Cancellation/switching invalidates all in-progress completions. The
    /// workspace also awaits its sync task and closes the transfer transport.
    func close() { closed = true; generation = UUID(); preparedBatch = nil; prepared = [:] }

    func prepareJournal(_ batch: CarryNativeJournalBatch) async throws {
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        guard batch.accountID == accountID else { throw CarryNativeAssetCoordinatorFailure.wrongAccount }
        guard !preparing else { throw CarryNativeAssetCoordinatorFailure.busy }
        if preparedBatch == batch { return }
        preparing = true; defer { preparing = false }
        let operation = generation
        var output: [UUID: CarryNativePreparedAssetChange] = [:]
        for change in batch.changes where change.requiresAssetPreparation {
            try Task.checkCancellation()
            var assets: [CarryNativePreparedAsset] = [], slots = Set<String>()
            if change.thumbnailChanged {
                slots.insert("thumbnail")
                if let bytes = change.thumbnailData {
                    let snapshot = try await cache.snapshot(data: bytes, entityID: change.entityID, slot: "thumbnail")
                    assets.append(.init(slot: "thumbnail", sourceReference: nil, snapshot: snapshot, contentType: "application/octet-stream"))
                }
            }
            let previousReferences = change.previousSource?.fileReferences ?? [:]
            for slot in Set(change.source.fileReferences.keys).union(previousReferences.keys).sorted() {
                // Re-encode background bindings whenever the list changes:
                // destination/index slot identities are part of the wire map.
                guard change.source.fileReferences[slot] != previousReferences[slot] ||
                        (change.kind == "trip" && change.changedFields.contains("backgroundsData")) else { continue }
                slots.insert(slot)
                if let reference = change.source.fileReferences[slot] {
                    let url = try await resolveSource(.init(accountID: accountID, entityID: change.entityID,
                        entityKind: change.kind, slot: slot, reference: reference))
                    let snapshot = try await cache.snapshot(fileURL: url, entityID: change.entityID, slot: slot)
                    assets.append(.init(slot: slot, sourceReference: reference, snapshot: snapshot, contentType: "application/octet-stream"))
                }
            }
            if change.kind == "photo", change.changedFields.contains("assetLocalIdentifier") {
                slots.insert("original")
                if case .string(let reference) = change.source.fields["assetLocalIdentifier"], !reference.isEmpty {
                    let url = try await resolveSource(.init(accountID: accountID, entityID: change.entityID,
                        entityKind: change.kind, slot: "original", reference: reference))
                    let snapshot = try await cache.snapshot(fileURL: url, entityID: change.entityID, slot: "original")
                    assets.append(.init(slot: "original", sourceReference: reference, snapshot: snapshot, contentType: "application/octet-stream"))
                }
            }
            output[change.id] = .init(change: change, assets: assets, replacedSlots: slots)
        }
        try Task.checkCancellation()
        guard !closed, generation == operation else { throw CarryNativeAssetCoordinatorFailure.closed }
        preparedBatch = batch; prepared = output
    }

    /// Called only by CarryNativeJournalBridge.apply. It never saves, starts a
    /// Task, reads a file, or advances a baseline to a newer RAW remote value.
    func resolveFields(_ change: CarryNativeJournalChangeSnapshot, in context: ModelContext) throws -> CarryNativeResolvedFields {
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        guard let value = prepared[change.id], value.change == change,
              preparedBatch?.accountID == accountID else { throw CarryNativeJournalBridgeFailure.assetsDeferred }
        var result = CarryNativeResolvedFields()
        let assets = Dictionary(uniqueKeysWithValues: value.assets.map { ($0.slot, $0) })
        var backgroundIDs: [String: CarryGraphValue] = [:]
        var previousBackgroundIDs: [String: CarryGraphValue] = [:]
        if case .object(let observed) = change.observed?.fields["backgroundAssetIDs"] {
            let priorSlots = Set(change.previousSource?.fileReferences.keys ?? Dictionary<String, String>().keys)
            previousBackgroundIDs = observed.filter { priorSlots.contains($0.key) }
        }
        for slot in change.previousSource?.fileReferences.keys ?? Dictionary<String, String>().keys where slot.hasPrefix("background:") {
            if let bound = try queue.binding(entityID: change.entityID, slot: slot, in: context) {
                previousBackgroundIDs[slot] = .string(bound.descriptor.id.uuidString.lowercased())
            }
        }
        for slot in value.replacedSlots.sorted() {
            let old = try queue.binding(entityID: change.entityID, slot: slot, in: context)
            let field: String
            switch slot {
            case "thumbnail": field = "thumbnailAssetID"
            case "file": field = "fileAssetID"
            case "original": field = "originalAssetID"
            default:
                guard change.kind == "trip", slot.hasPrefix("background:") else { throw CarryNativeAssetCoordinatorFailure.invalidState }
                field = "backgroundAssetIDs"
            }
            let previous = old.map { CarryGraphValue.string($0.descriptor.id.uuidString.lowercased()) }
            let current: CarryGraphValue
            if let asset = assets[slot] {
                let work = try queue.bind(asset.snapshot, entityID: change.entityID, entityKind: change.kind,
                    slot: slot, contentType: asset.contentType, sourceReference: asset.sourceReference, in: context)
                current = .string(work.descriptor.id.uuidString.lowercased())
            } else {
                try queue.unbind(entityID: change.entityID, slot: slot, in: context)
                current = .null
            }
            if field == "backgroundAssetIDs" {
                if current != .null { backgroundIDs[slot] = current }
                if let previous { previousBackgroundIDs[slot] = previous }
            } else {
                result.fields[field] = current
                if slot == "thumbnail", let prior = change.previousSource, prior.thumbnailPresent == nil,
                   previous == nil, let observed = change.observed?.fields[field], observed != .null {
                    // Old journal metadata has no proof whether a local removal
                    // preceded this replacement. Keep it for explicit recovery.
                    throw CarryNativeJournalBridgeFailure.assetsDeferred
                }
                let previouslyAbsent = slot == "file" ? change.previousSource?.fileReferences[slot] == nil :
                    (slot == "original" ? change.previousSource?.fields["assetLocalIdentifier"] == .string("") || change.previousSource == nil :
                        change.previousSource == nil || change.previousSource?.thumbnailPresent == false)
                result.previousFields[field] = previouslyAbsent ? .null : (previous ?? change.observed?.fields[field] ?? .null)
            }
        }
        if change.kind == "trip", change.changedFields.contains("backgroundsData") {
            // Include surviving slots, not merely files replaced in this edit.
            for slot in change.source.fileReferences.keys where backgroundIDs[slot] == nil {
                guard let bound = try queue.binding(entityID: change.entityID, slot: slot, in: context) else {
                    throw CarryNativeJournalBridgeFailure.assetsDeferred
                }
                backgroundIDs[slot] = .string(bound.descriptor.id.uuidString.lowercased())
            }
            result.fields["backgroundAssetIDs"] = .object(backgroundIDs)
            result.previousFields["backgroundAssetIDs"] = .object(previousBackgroundIDs)
        }
        return result
    }

    func didConsumeJournal(_ batch: CarryNativeJournalBatch) throws {
        guard preparedBatch == nil || preparedBatch == batch else { throw CarryNativeAssetCoordinatorFailure.invalidState }
        preparedBatch = nil; prepared = [:]
    }

    /// Prepared bytes are retained before their bindings have committed. Never
    /// run cache GC with only the queue's persisted jobs as the keep set.
    var preparedTokens: Set<CarryAccountAssetToken> {
        Set(prepared.values.flatMap(\.assets).map { $0.snapshot.token })
    }
    /// GC must also share the workspace's serial sync/ingestion gate. A false
    /// result alone cannot authorize collection while another owner captures.
    var isBusy: Bool { preparing || uploading }

    private func persist<T>(in context: ModelContext, _ body: () throws -> T) throws -> T {
        // Asset jobs must use the workspace's separate RAW context. Refuse to
        // accidentally save or roll back a view's unjournaled business edits.
        for model in context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray {
            if try CarryNativeSourceCodec.identity(of: model) != nil { throw CarryNativeAssetCoordinatorFailure.invalidState }
        }
        do { let result = try body(); try context.save(); return result }
        catch { context.rollback(); throw error }
    }

    func uploadPending(in context: ModelContext) async throws {
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        try await uploadWorks(queue.pendingWork(limit: 2, in: context), in: context)
    }

    private func uploadWorks(_ works: [CarryAccountAssetWork], in context: ModelContext) async throws {
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        guard !uploading else { throw CarryNativeAssetCoordinatorFailure.busy }
        uploading = true; defer { uploading = false }
        let operation = generation
        // Freeze this finite work list before suspension. New user imports do
        // not turn one sync pass into an indefinitely growing upload loop.
        for work in works where !work.isVerified {
            try Task.checkCancellation()
            try persist(in: context) { try queue.markUploading(work.descriptor.id, in: context) }
            do {
                let url = try await cache.verify(work.snapshot)
                try await upload(work.descriptor, url)
                try Task.checkCancellation()
                guard !closed, generation == operation else { throw CarryNativeAssetCoordinatorFailure.closed }
                try persist(in: context) { try queue.markVerified(work.descriptor.id, in: context) }
            } catch {
                // The failed HTTP operation may have completed remotely. Requeue
                // reuses the immutable asset ID; reserve/verify is idempotent.
                try persist(in: context) { try queue.requeue(work.descriptor.id, in: context) }
                throw error
            }
        }
    }

    /// Invoke for a frozen command before sending it. No graph request may
    /// publish an asset reference until its durable job is server-verified.
    /// Existing remote references need an explicit trusted verifier supplied by
    /// the workspace; a missing local job is never presumed to be uploaded.
    func preparePublication(_ command: CarryGraphCommand, in context: ModelContext,
        verifiedRemote: (UUID) throws -> Bool = { _ in false }) async throws {
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        let references = try Self.assetReferences(command)
        guard !references.isEmpty else { return }
        let localIDs = Set(try context.fetch(FetchDescriptor<CarryAccountAssetJob>()).map(\.assetID))
        for id in references.subtracting(localIDs) {
            guard try verifiedRemote(id) else { throw CarryNativeAssetCoordinatorFailure.publicationNotReady }
        }
        let local = references.intersection(localIDs)
        let pinned = try persist(in: context) { try queue.freeze(assetIDs: local, requestID: command.requestID, in: context) }
        try await uploadWorks(pinned, in: context)
        let work = try queue.freeze(assetIDs: local, requestID: command.requestID, in: context)
        guard work.allSatisfy(\.isVerified) else { throw CarryNativeAssetCoordinatorFailure.publicationNotReady }
    }

    func releasePublication(requestID: UUID, in context: ModelContext) throws {
        try persist(in: context) { try queue.release(requestID: requestID, in: context) }
    }

    nonisolated static func assetReferences(_ command: CarryGraphCommand) throws -> Set<UUID> {
        func references(_ value: CarryGraphValue) throws -> Set<UUID> {
            switch value {
            case .null: return []
            case .string(let text):
                guard let id = UUID(uuidString: text) else { throw CarryNativeAssetCoordinatorFailure.invalidState }
                return [id]
            case .object(let values): return try values.values.reduce(into: Set<UUID>()) { $0.formUnion(try references($1)) }
            case .array(let values): return try values.reduce(into: Set<UUID>()) { $0.formUnion(try references($1)) }
            default: throw CarryNativeAssetCoordinatorFailure.invalidState
            }
        }
        var result: Set<UUID> = []
        for mutation in command.mutations {
            for key in ["fileAssetID", "thumbnailAssetID", "originalAssetID", "backgroundAssetIDs"] {
                if let value = mutation.fields?[key] { result.formUnion(try references(value)) }
            }
        }
        return result
    }
}
