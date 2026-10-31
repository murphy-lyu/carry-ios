import Foundation
import SwiftData

enum CarryAccountAssetRetentionFailure: Error { case wrongAccount, dirtyContext, changedSnapshot, invalidReference, missingAsset }

nonisolated enum CarryAccountAssetReferences {
    static func ids(in fields: [String: CarryGraphValue]) throws -> Set<UUID> {
        func references(_ value: CarryGraphValue) throws -> Set<UUID> {
            switch value {
            case .null: return []
            case .string(let raw):
                if raw.isEmpty { return [] }
                guard let id = UUID(uuidString: raw) else { throw CarryAccountAssetRetentionFailure.invalidReference }
                return [id]
            case .object(let values): return try values.values.reduce(into: Set<UUID>()) { $0.formUnion(try references($1)) }
            case .array(let values): return try values.reduce(into: Set<UUID>()) { $0.formUnion(try references($1)) }
            default: throw CarryAccountAssetRetentionFailure.invalidReference
            }
        }
        var result: Set<UUID> = []
        for key in ["fileAssetID", "thumbnailAssetID", "originalAssetID", "backgroundAssetIDs"] {
            if let value = fields[key] { result.formUnion(try references(value)) }
        }
        return result
    }
}

/// Reclamation is deliberately not scheduled by this component. The caller must
/// hold an exclusive lease blocking business saves, imports, uploads, downloads,
/// projection and cache preparation across the whole async operation. A pair of
/// equal scans without that writer gate is insufficient to authorize deletion.
@MainActor
final class CarryAccountAssetRetention {
    struct Pins: Sendable {
        var tokens: Set<CarryAccountAssetToken> = []
        var assetIDs: Set<UUID> = []
    }
    struct Result: Sendable {
        let retiredBindings: Int
        let retiredJobs: Int
        let removedFiles: [CarryAccountAssetToken]
    }
    /// The issuer owns the workspace's actual writer gate. Its validity check
    /// must stay true while all writers are paused, including during actor IO.
    struct ExclusiveLease {
        let accountID: UUID
        let isValid: () -> Bool
    }
    private struct Mark: Equatable {
        let revision: Int64
        let tokens: Set<CarryAccountAssetToken>
        let ids: Set<UUID>
        let journalIDs: Set<UUID>
        let bindingKeys: Set<String>
        let jobStates: Set<String>
    }
    private let accountID: UUID
    private let replica: CarryAccountReplica
    private let cache: CarryAccountAssetCache
    private let pins: () throws -> Pins
    init(accountID: UUID, replica: CarryAccountReplica, cache: CarryAccountAssetCache,
         pins: @escaping () throws -> Pins) throws {
        guard replica.accountID == accountID, cache.accountID == accountID else { throw CarryAccountAssetRetentionFailure.wrongAccount }
        self.accountID = accountID; self.replica = replica; self.cache = cache; self.pins = pins
    }

    func collect(lease: ExclusiveLease) async throws -> Result {
        try validate(lease)
        let first = try await mark()
        await Task.yield()
        try validate(lease)
        let second = try await mark()
        guard first == second else { throw CarryAccountAssetRetentionFailure.changedSnapshot }
        let context = ModelContext(replica.context.container)
        context.autosaveEnabled = false
        let queue = CarryAccountAssetQueue(accountID: accountID)
        let jobsBefore = try context.fetch(FetchDescriptor<CarryAccountAssetJob>())
        let bindings = try context.fetch(FetchDescriptor<CarryAccountAssetBinding>())
        var removedBindings = 0
        do {
            for binding in bindings where !second.ids.contains(binding.assetID) {
                guard binding.accountID == accountID else { throw CarryAccountAssetRetentionFailure.wrongAccount }
                context.delete(binding); removedBindings += 1
            }
            // Raw or journal roots can outlive their last current binding.
            // Keep their jobs by temporary exclusion from the orphan sweep.
            let bound = Set(bindings.filter { second.ids.contains($0.assetID) }.map(\.assetID))
            for job in jobsBefore where !bound.contains(job.assetID) && !second.ids.contains(job.assetID)
                && job.frozenRequestIDs.isEmpty && job.phase != "uploading" {
                context.delete(job)
            }
            try validate(lease)
            try context.save()
        } catch { context.rollback(); throw error }
        let keep = try queue.retainedTokens(in: context).union(second.tokens)
        // queue validation may install its owner in a brand-new empty cache.
        if context.hasChanges { try context.save() }
        try validate(lease)
        let removed = try await cache.collect(keeping: keep)
        try validate(lease)
        let remaining = try context.fetch(FetchDescriptor<CarryAccountAssetJob>()).count
        return Result(retiredBindings: removedBindings, retiredJobs: jobsBefore.count - remaining, removedFiles: removed)
    }

    private func validate(_ lease: ExclusiveLease) throws {
        try Task.checkCancellation()
        guard lease.accountID == accountID else { throw CarryAccountAssetRetentionFailure.wrongAccount }
        guard lease.isValid() else { throw CarryAccountAssetRetentionFailure.changedSnapshot }
        guard !replica.context.hasChanges else { throw CarryAccountAssetRetentionFailure.dirtyContext }
    }
    private func mark() async throws -> Mark {
        let revision = try replica.retentionRevision
        var ids = try await replica.assetRetentionReferencesAsync()
        let context = ModelContext(replica.context.container)
        let owners = try context.fetch(FetchDescriptor<CarryNativeJournalOwner>())
        guard owners.count <= 1, owners.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetRetentionFailure.wrongAccount }
        let changes = try context.fetch(FetchDescriptor<CarryNativeChange>())
        let materialized = try context.fetch(FetchDescriptor<CarryNativeMaterialization>())
        let projection = try context.fetch(FetchDescriptor<CarryNativeProjectionCheckpoint>())
        let historicalGraphs = materialized.compactMap(\.observedGraphData) + changes.compactMap(\.observedGraphData)
        ids.formUnion(try await Self.historicalReferences(graphs: historicalGraphs, projections: projection.map(\.desiredData)))
        let sources = materialized.map(\.sourceData) + changes.flatMap { [$0.sourceData] + ($0.previousSourceData.map { [$0] } ?? []) }
        var tokens = try await Self.nativeTokens(sources, accountID: accountID)
        // Include current committed native files as well as historical displayed
        // baselines; a journal checkpoint alone never proves a file is obsolete.
        for model in try context.fetch(FetchDescriptor<TripBundle>()) {
            for name in model.backgrounds.compactMap(\.localFileName) { tokens.insert(try Self.token(name, accountID: accountID)) }
        }
        for attachment in try context.fetch(FetchDescriptor<ItineraryAttachment>()) where !attachment.fileName.isEmpty {
            tokens.insert(try Self.token(attachment.fileName, accountID: accountID))
        }
        for photo in try context.fetch(FetchDescriptor<StopPhoto>()) where CarryAccountFileAccess.isAccountReference(photo.assetLocalIdentifier) {
            tokens.insert(try Self.token(photo.assetLocalIdentifier, accountID: accountID))
        }
        let extra = try pins()
        guard extra.tokens.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetRetentionFailure.wrongAccount }
        tokens.formUnion(extra.tokens); ids.formUnion(extra.assetIDs); ids.formUnion(tokens.map(\.assetID))
        let jobs = try context.fetch(FetchDescriptor<CarryAccountAssetJob>())
        guard jobs.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetRetentionFailure.wrongAccount }
        for job in jobs where job.phase == "uploading" || !job.frozenRequestIDs.isEmpty { ids.insert(job.assetID) }
        let bindings = try context.fetch(FetchDescriptor<CarryAccountAssetBinding>())
        guard bindings.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetRetentionFailure.wrongAccount }
        guard try replica.retentionRevision == revision else { throw CarryAccountAssetRetentionFailure.changedSnapshot }
        return Mark(revision: revision, tokens: tokens, ids: ids, journalIDs: Set(changes.map(\.id)),
            bindingKeys: Set(bindings.map { "\($0.key)|\($0.assetID)|\($0.sourceReference ?? "")" }),
            jobStates: Set(jobs.map { "\($0.assetID)|\($0.fileToken)|\($0.phase)|\($0.frozenRequestIDs.map(\.uuidString).sorted().joined(separator: ","))" }))
    }
    nonisolated private static func token(_ raw: String, accountID: UUID) throws -> CarryAccountAssetToken {
        let token = try CarryAccountAssetToken(rawValue: raw)
        guard token.accountID == accountID else { throw CarryAccountAssetRetentionFailure.wrongAccount }
        return token
    }
    @concurrent nonisolated private static func nativeTokens(_ sources: [Data], accountID: UUID) async throws -> Set<CarryAccountAssetToken> {
        var result: Set<CarryAccountAssetToken> = []
        for bytes in sources {
            try Task.checkCancellation()
            let source = try JSONDecoder().decode(CarryNativeSourceMetadata.self, from: bytes)
            for name in source.fileReferences.values { result.insert(try token(name, accountID: accountID)) }
            if source.kind == "photo", case .string(let name) = source.fields["assetLocalIdentifier"], CarryAccountFileAccess.isAccountReference(name) {
                result.insert(try token(name, accountID: accountID))
            }
        }
        return result
    }
    @concurrent nonisolated private static func historicalReferences(graphs: [Data], projections: [Data]) async throws -> Set<UUID> {
        struct Projection: Decodable { let fields: [String: CarryGraphValue] }
        let decoder = JSONDecoder()
        var result: Set<UUID> = []
        for bytes in graphs {
            try Task.checkCancellation()
            result.formUnion(try CarryAccountAssetReferences.ids(in: decoder.decode(CarryGraphEntity.self, from: bytes).fields))
        }
        for bytes in projections {
            try Task.checkCancellation()
            result.formUnion(try CarryAccountAssetReferences.ids(in: decoder.decode(Projection.self, from: bytes).fields))
        }
        return result
    }
}
