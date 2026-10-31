import Foundation
import SwiftData

nonisolated struct CarryAccountAssetManifest: Codable, Sendable {
    let accountID: UUID
    let assetID: UUID
    let entityID: UUID
    let kind: String
    let slot: String
    let sha256: String
    let byteCount: Int
    let providerVersion: UUID
}

enum CarryAccountWorkspaceAssetFailure: Error {
    case wrongAccount, invalidManifest, missingReference, preparationPending, staleProjection, thumbnailBudget, closed, busy
}

/// Metadata comes from the authenticated native endpoint, never graph text or a
/// caller-supplied provider URL. The response contains no storage credentials.
actor CarryAccountAssetManifestClient {
    private let accountID: UUID
    private let endpoint: URL
    private let publishableKey: String
    private let accessToken: @Sendable () async throws -> String
    private let session: URLSession
    private let noRedirect = CarryAccountNoRedirect()
    private var closed = false
    init(accountID: UUID, projectURL: URL, publishableKey: String,
         accessToken: @escaping @Sendable () async throws -> String) throws {
        var secure = projectURL.scheme == "https"
        #if DEBUG
        secure = secure || projectURL.scheme == "http" && projectURL.host == "127.0.0.1"
        #endif
        guard secure, projectURL.host != nil, projectURL.user == nil, projectURL.password == nil,
              projectURL.query == nil, projectURL.fragment == nil, ["", "/"].contains(projectURL.path),
              publishableKey.hasPrefix("sb_publishable_") else { throw CarryAssetTransferFailure.invalidConfiguration }
        self.accountID = accountID; self.publishableKey = publishableKey; self.accessToken = accessToken
        endpoint = projectURL.appendingPathComponent("functions/v1/carry-assets/manifest")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }
    func close() { closed = true; session.invalidateAndCancel() }
    func manifest(_ assetID: UUID) async throws -> CarryAccountAssetManifest {
        guard !closed else { throw CarryAccountWorkspaceAssetFailure.closed }
        var request = URLRequest(url: endpoint.appendingPathComponent(assetID.uuidString.lowercased()))
        request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        guard !closed else { throw CarryAccountWorkspaceAssetFailure.closed }
        let (bytes, response) = try await session.bytes(for: request, delegate: noRedirect)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw CarryAssetTransferFailure.invalidResponse }
        if [401, 403].contains(http.statusCode) { throw CarryAssetTransferFailure.sessionExpired }
        if http.statusCode == 429 || http.statusCode >= 500 { throw CarryAssetTransferFailure.unavailable }
        guard http.statusCode == 200, response.url == request.url, response.expectedContentLength <= 64 * 1024 else {
            throw CarryAssetTransferFailure.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 64 * 1024 else { throw CarryAssetTransferFailure.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !closed else { throw CarryAccountWorkspaceAssetFailure.closed }
        let result = try JSONDecoder().decode(CarryAccountAssetManifest.self, from: data)
        guard result.accountID == accountID, result.assetID == assetID else { throw CarryAccountWorkspaceAssetFailure.wrongAccount }
        return result
    }
}

private actor CarryWorkspaceAssetBytes {
    func thumbnail(at url: URL, byteCount: Int) throws -> Data {
        // Thumbnails are bounded separately from 50 MiB originals. Never load an
        // arbitrary original into the main actor to satisfy a thumbnail field.
        guard byteCount > 0, byteCount <= 5 * 1024 * 1024 else { throw CarryAccountWorkspaceAssetFailure.thumbnailBudget }
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        guard data.count == byteCount else { throw CarryAccountWorkspaceAssetFailure.invalidManifest }
        return data
    }
}

/// Verified downloads stay in the account cache. Preparation does no Context
/// mutation; resolver does no IO. Bindings commit with the business projection.
@MainActor
final class CarryAccountWorkspaceAssets {
    typealias Manifest = @Sendable (UUID) async throws -> CarryAccountAssetManifest
    typealias Download = @Sendable (CarryAssetDownload) async throws -> URL
    private struct Reference: Equatable {
        let id: UUID
        let entityID: UUID
        let kind: String
        let slot: String
    }
    private struct Prepared {
        let reference: Reference
        let snapshot: CarryAccountAssetSnapshot
        let thumbnail: Data?
        let contentType: String
        let verifiedURL: URL
    }
    private struct EntityPlan {
        let kind: String
        let signature: [String: CarryGraphValue]
        let references: [String: Reference]
    }
    private struct ProjectionCheckpoint: Decodable { let fields: [String: CarryGraphValue] }
    private static let signatureKeys: Set<String> = ["fileName", "backgroundsData", "fileAssetID", "thumbnailAssetID", "originalAssetID", "backgroundAssetIDs"]
    let accountID: UUID
    private let cache: CarryAccountAssetCache
    private let manifest: Manifest
    private let download: Download
    private let bytes = CarryWorkspaceAssetBytes()
    private let queue: CarryAccountAssetQueue
    private var prepared: [UUID: Prepared] = [:]
    private var plans: [UUID: EntityPlan] = [:]
    private var active = false
    private var closed = false
    private var generation = UUID()

    init(accountID: UUID, cache: CarryAccountAssetCache, manifest: @escaping Manifest, download: @escaping Download) throws {
        guard cache.accountID == accountID else { throw CarryAccountWorkspaceAssetFailure.wrongAccount }
        self.accountID = accountID; self.cache = cache; self.manifest = manifest; self.download = download
        queue = CarryAccountAssetQueue(accountID: accountID)
    }
    var retainedTokens: Set<CarryAccountAssetToken> { Set(prepared.values.map(\.snapshot.token)) }
    var preparedReadyURLs: [String: URL] { Dictionary(uniqueKeysWithValues: prepared.values.map { ($0.snapshot.token.rawValue, $0.verifiedURL) }) }
    func close() { closed = true; generation = UUID(); prepared = [:]; plans = [:]; downloadedRemote = [] }

    /// At most 32 new immutable assets are verified per pass. A larger first
    /// sync returns pending and resumes with the already verified copies pinned.
    func prepare(snapshot: [CarryNativeProjectionEntity], candidateIDs: Set<UUID>, in context: ModelContext) async throws {
        guard !closed else { throw CarryAccountWorkspaceAssetFailure.closed }
        guard !active else { throw CarryAccountWorkspaceAssetFailure.busy }
        active = true; defer { active = false }
        let operation = generation
        try validateOwner(context)
        var nextPlans: [UUID: EntityPlan] = [:], wanted: [UUID: Reference] = [:]
        for entry in snapshot where candidateIDs.contains(entry.local.id) && entry.local.deletedAt == nil {
            let plan = try Self.plan(entry.local)
            nextPlans[entry.local.id] = plan
            for reference in plan.references.values {
                if let old = wanted.updateValue(reference, forKey: reference.id), old != reference { throw CarryAccountWorkspaceAssetFailure.invalidManifest }
            }
        }
        prepared = prepared.filter { wanted[$0.key] == $0.value.reference }
        downloadedRemote.formIntersection(Set(wanted.keys))
        plans = nextPlans
        var processed = 0
        var retainedThumbnailBytes = prepared.values.reduce(0) { $0 + ($1.thumbnail?.count ?? 0) }
        for reference in wanted.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where prepared[reference.id] == nil {
            guard processed < 32 else { throw CarryAccountWorkspaceAssetFailure.preparationPending }
            processed += 1
            try Task.checkCancellation()
            let local = try localSnapshot(reference, in: context)
            let snapshot: CarryAccountAssetSnapshot, url: URL, contentType: String
            if let local {
                snapshot = local.snapshot; contentType = local.contentType
                url = try await cache.verify(local.snapshot)
            } else {
                let metadata = try await manifest(reference.id)
                try Self.validate(metadata, reference: reference, accountID: accountID)
                let downloaded = try await download(CarryAssetDownload(id: metadata.assetID, accountID: accountID,
                    sha256: metadata.sha256, byteCount: metadata.byteCount))
                snapshot = try await cache.snapshot(fileURL: downloaded, assetID: reference.id,
                    expectedSHA256: metadata.sha256, expectedByteCount: metadata.byteCount)
                guard snapshot.token.sha256 == metadata.sha256, snapshot.byteCount == metadata.byteCount else {
                    throw CarryAccountWorkspaceAssetFailure.invalidManifest
                }
                url = try await cache.verify(snapshot)
                contentType = "application/octet-stream"
            }
            let thumbnail = reference.slot == "thumbnail" ? try await bytes.thumbnail(at: url, byteCount: snapshot.byteCount) : nil
            guard retainedThumbnailBytes + (thumbnail?.count ?? 0) <= 32 * 1024 * 1024 else { throw CarryAccountWorkspaceAssetFailure.thumbnailBudget }
            retainedThumbnailBytes += thumbnail?.count ?? 0
            try Task.checkCancellation()
            guard !closed, generation == operation else { throw CarryAccountWorkspaceAssetFailure.closed }
            if local == nil { downloadedRemote.insert(reference.id) }
            prepared[reference.id] = Prepared(reference: reference, snapshot: snapshot, thumbnail: thumbnail,
                contentType: contentType, verifiedURL: url)
        }
    }

    /// Pure metadata/ready-byte lookup, safe inside the projector's actor.
    func resolve(_ entity: CarryGraphEntity, existing: CarryNativeEntitySource?) throws -> CarryNativeProjectionAssets {
        guard !closed else { throw CarryAccountWorkspaceAssetFailure.closed }
        let current = try Self.plan(entity)
        guard current.references.isEmpty || plans[entity.id]?.signature == current.signature else { throw CarryAccountWorkspaceAssetFailure.staleProjection }
        var result = CarryNativeProjectionAssets()
        for (slot, reference) in current.references {
            guard let asset = prepared[reference.id], asset.reference == reference else { throw CarryNativeProjectionFailure.assetUnavailable }
            result.readyAssetIDs.insert(reference.id)
            if slot == "file" { result.localFileName = asset.snapshot.token.rawValue }
            if slot == "original" { result.originalFileName = asset.snapshot.token.rawValue }
            if slot == "thumbnail" { result.thumbnailData = asset.thumbnail }
        }
        if case .string(let raw) = entity.fields["fileName"], !raw.isEmpty, current.references["file"] == nil {
            throw CarryAccountWorkspaceAssetFailure.missingReference
        }
        if let encoded = entity.fields["backgroundsData"] {
            var backgrounds = try Self.backgrounds(encoded)
            for index in backgrounds.indices where backgrounds[index].localFileName != nil {
                let slot = "background:\(backgrounds[index].destinationIndex):\(index)"
                guard let reference = current.references[slot], let asset = prepared[reference.id] else { throw CarryAccountWorkspaceAssetFailure.missingReference }
                backgrounds[index].localFileName = asset.snapshot.token.rawValue
            }
            if !backgrounds.isEmpty { result.backgroundsData = try JSONEncoder().encode(backgrounds) }
        }
        return result
    }

    /// Inject as Workspace.Hooks.projectionSave. The projector has already
    /// installed its desired checkpoint in this same transaction. A different
    /// local edit cannot accidentally receive a previously prepared binding.
    func saveProjection(_ context: ModelContext, save: CarryPersistence.Save? = nil) throws {
        guard !closed else { throw CarryAccountWorkspaceAssetFailure.closed }
        try validateOwner(context)
        for (entityID, plan) in plans where !plan.references.isEmpty {
            var query = FetchDescriptor<CarryNativeProjectionCheckpoint>(predicate: #Predicate { $0.id == entityID })
            query.fetchLimit = 1
            guard let row = try context.fetch(query).first else { throw CarryAccountWorkspaceAssetFailure.staleProjection }
            let fields = try JSONDecoder().decode(ProjectionCheckpoint.self, from: row.desiredData).fields
            guard fields.filter({ Self.signatureKeys.contains($0.key) }) == plan.signature else { throw CarryAccountWorkspaceAssetFailure.staleProjection }
            for (slot, reference) in plan.references {
                guard let asset = prepared[reference.id] else { throw CarryNativeProjectionFailure.assetUnavailable }
                let work = try queue.bind(asset.snapshot, entityID: entityID, entityKind: plan.kind, slot: slot,
                    contentType: asset.contentType, sourceReference: asset.snapshot.token.rawValue, in: context)
                // Local queued edits retain upload status; downloading a server
                // manifest certifies remote jobs. Do not mark local jobs verified.
                if work.isVerified || downloadedRemote.contains(reference.id) { try queue.markVerified(reference.id, in: context) }
            }
        }
        if let save { try save(context) } else { try context.save() }
    }

    private var downloadedRemote: Set<UUID> = []

    /// A UI reader must present the active account identity; parsing the opaque
    /// token alone never grants access to another workspace's cached bytes.
    func fileURL(for token: String, in context: ModelContext) async throws -> URL {
        guard !closed else { throw CarryAccountWorkspaceAssetFailure.closed }
        let parsed = try CarryAccountAssetToken(rawValue: token)
        guard parsed.accountID == accountID else { throw CarryAccountWorkspaceAssetFailure.wrongAccount }
        try validateOwner(context)
        let snapshot: CarryAccountAssetSnapshot
        if let asset = prepared[parsed.assetID], asset.snapshot.token == parsed { snapshot = asset.snapshot }
        else {
            let assetID = parsed.assetID
            var query = FetchDescriptor<CarryAccountAssetJob>(predicate: #Predicate { $0.assetID == assetID }); query.fetchLimit = 1
            guard let job = try context.fetch(query).first else { throw CarryNativeProjectionFailure.assetUnavailable }
            let reference = Reference(id: assetID, entityID: job.entityID, kind: job.entityKind, slot: job.slot)
            guard let local = try localSnapshot(reference, in: context), local.snapshot.token == parsed else { throw CarryNativeProjectionFailure.assetUnavailable }
            snapshot = local.snapshot
        }
        let operation = generation
        let url = try await cache.verify(snapshot)
        guard !closed, generation == operation else { throw CarryAccountWorkspaceAssetFailure.closed }
        return url
    }

    private func validateOwner(_ context: ModelContext) throws {
        guard context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else { throw CarryAccountWorkspaceAssetFailure.wrongAccount }
        let owners = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
        guard owners.count <= 1, owners.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountWorkspaceAssetFailure.wrongAccount }
        let journals = try context.fetch(FetchDescriptor<CarryNativeJournalOwner>())
        guard journals.count <= 1, journals.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountWorkspaceAssetFailure.wrongAccount }
    }
    private func localSnapshot(_ reference: Reference, in context: ModelContext) throws -> (snapshot: CarryAccountAssetSnapshot, contentType: String)? {
        let assetID = reference.id
        var query = FetchDescriptor<CarryAccountAssetJob>(predicate: #Predicate { $0.assetID == assetID }); query.fetchLimit = 1
        guard let job = try context.fetch(query).first else { return nil }
        let token = try CarryAccountAssetToken(rawValue: job.fileToken)
        guard job.accountID == accountID, token.accountID == accountID, job.entityID == reference.entityID,
              job.entityKind == reference.kind, job.slot == reference.slot, token.assetID == reference.id,
              token.sha256 == job.sha256, (1...CarryAccountAssetCache.maximumBytes).contains(job.byteCount),
              ["queued", "uploading", "verified"].contains(job.phase),
              try CarryAccountAssetIdentity.id(accountID: accountID, entityID: job.entityID, slot: job.slot, sha256: job.sha256) == reference.id else {
            throw CarryAccountWorkspaceAssetFailure.invalidManifest
        }
        return (CarryAccountAssetSnapshot(token: token, byteCount: job.byteCount), job.contentType)
    }
    private static func validate(_ manifest: CarryAccountAssetManifest, reference: Reference, accountID: UUID) throws {
        guard manifest.accountID == accountID else { throw CarryAccountWorkspaceAssetFailure.wrongAccount }
        guard manifest.assetID == reference.id, manifest.entityID == reference.entityID, manifest.kind == reference.kind,
              manifest.slot == reference.slot, (1...CarryAccountAssetCache.maximumBytes).contains(manifest.byteCount),
              (try CarryAccountAssetIdentity.id(accountID: accountID, entityID: reference.entityID, slot: reference.slot,
                  sha256: manifest.sha256)) == reference.id else { throw CarryAccountWorkspaceAssetFailure.invalidManifest }
        _ = try CarryAccountAssetToken(accountID: accountID, assetID: reference.id, sha256: manifest.sha256)
    }
    private static func plan(_ entity: CarryGraphEntity) throws -> EntityPlan {
        var references: [String: Reference] = [:]
        func add(_ value: CarryGraphValue?, slot: String) throws {
            guard let value, value != .null, value != .string("") else { return }
            guard case .string(let raw) = value, let id = UUID(uuidString: raw) else { throw CarryAccountWorkspaceAssetFailure.invalidManifest }
            references[slot] = Reference(id: id, entityID: entity.id, kind: entity.kind, slot: slot)
        }
        try add(entity.fields["fileAssetID"], slot: "file")
        try add(entity.fields["thumbnailAssetID"], slot: "thumbnail")
        try add(entity.fields["originalAssetID"], slot: "original")
        if let map = entity.fields["backgroundAssetIDs"], map != .null {
            guard case .object(let values) = map else { throw CarryAccountWorkspaceAssetFailure.invalidManifest }
            for (slot, value) in values {
                guard entity.kind == "trip", slot.hasPrefix("background:") else { throw CarryAccountWorkspaceAssetFailure.invalidManifest }
                try add(value, slot: slot)
            }
        }
        for reference in references.values {
            let valid = reference.kind == "trip" && reference.slot.hasPrefix("background:") ||
                reference.kind == "attachment" && ["file", "thumbnail"].contains(reference.slot) ||
                reference.kind == "photo" && ["thumbnail", "original"].contains(reference.slot)
            guard valid else { throw CarryAccountWorkspaceAssetFailure.invalidManifest }
        }
        return EntityPlan(kind: entity.kind, signature: entity.fields.filter { signatureKeys.contains($0.key) }, references: references)
    }
    private static func backgrounds(_ value: CarryGraphValue) throws -> [TripBackgroundEntry] {
        guard value != .null else { return [] }
        guard case .string(let text) = value, let data = Data(base64Encoded: text) else { throw CarryAccountWorkspaceAssetFailure.invalidManifest }
        return data.isEmpty ? [] : try JSONDecoder().decode([TripBackgroundEntry].self, from: data)
    }
}
