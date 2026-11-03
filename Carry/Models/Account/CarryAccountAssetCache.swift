import Foundation
import CryptoKit
import SwiftData
import Darwin

nonisolated enum CarryAccountAssetCacheFailure: Error { case invalidToken, wrongAccount, invalidSource, immutableIdentity, invalidState, wrongContainer }

/// A routing token, not an authorization credential. A caller must still hold
/// this account's authenticated workspace before resolving its private file.
nonisolated struct CarryAccountAssetToken: Codable, Hashable, Sendable {
    let accountID: UUID
    let assetID: UUID
    let sha256: String
    var rawValue: String { "carryasset1_\(accountID.uuidString.lowercased())_\(assetID.uuidString.lowercased())_\(sha256).blob" }
    init(accountID: UUID, assetID: UUID, sha256: String) throws {
        guard sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CarryAccountAssetCacheFailure.invalidToken
        }
        self.accountID = accountID; self.assetID = assetID; self.sha256 = sha256
    }
    init(rawValue: String) throws {
        let parts = rawValue.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "carryasset1", parts[3].hasSuffix(".blob"),
              let account = UUID(uuidString: String(parts[1])), let asset = UUID(uuidString: String(parts[2])) else {
            throw CarryAccountAssetCacheFailure.invalidToken
        }
        try self.init(accountID: account, assetID: asset, sha256: String(parts[3].dropLast(5)))
        guard self.rawValue == rawValue else { throw CarryAccountAssetCacheFailure.invalidToken }
    }
    init(from decoder: Decoder) throws { try self.init(rawValue: decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

nonisolated enum CarryAccountAssetIdentity {
    /// Matches carry_private.asset_identity; these UUID bits are a hash, not a
    /// generated RFC version/variant. Do not rewrite any bits after hashing.
    static func id(accountID: UUID, entityID: UUID, slot: String, sha256: String) throws -> UUID {
        let input = "\(accountID.uuidString.lowercased())/\(entityID.uuidString.lowercased())/\(slot)/\(sha256)"
        let raw = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        var formatted = ""
        for (index, character) in raw.enumerated() {
            if [8, 12, 16, 20].contains(index) { formatted.append("-") }
            formatted.append(character)
        }
        guard let id = UUID(uuidString: formatted) else { throw CarryAccountAssetCacheFailure.invalidState }
        return id
    }
}

nonisolated struct CarryAccountAssetSnapshot: Codable, Sendable {
    let token: CarryAccountAssetToken
    let byteCount: Int
}

/// Synchronous disk work is isolated to this background actor. No API scans a
/// native trip, changes its original file, or overwrites a previous snapshot.
actor CarryAccountAssetCache {
    nonisolated static let maximumBytes = 50 * 1024 * 1024
    nonisolated let accountID: UUID
    private let root: URL
    private var directory: URL { root.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true) }
    init(root: URL, accountID: UUID) throws {
        guard root.isFileURL else { throw CarryAccountAssetCacheFailure.invalidSource }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.accountID = accountID
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw CarryAccountAssetCacheFailure.invalidSource }
        } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var folder = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    private func assetDirectory(_ id: UUID) throws -> URL {
        try prepareDirectory()
        let folder = directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw CarryAccountAssetCacheFailure.invalidSource }
        } else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return folder
    }
    func url(for token: CarryAccountAssetToken) throws -> URL {
        guard token.accountID == accountID else { throw CarryAccountAssetCacheFailure.wrongAccount }
        // Reparse even values decoded by other code before touching the filesystem.
        _ = try CarryAccountAssetToken(rawValue: token.rawValue)
        return try assetDirectory(token.assetID).appendingPathComponent(token.rawValue)
    }
    private func regularFile(_ url: URL, expectedBytes: Int? = nil) throws -> Int {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let count = info.fileSize,
              count > 0, count <= Self.maximumBytes, expectedBytes == nil || count == expectedBytes else {
            throw CarryAccountAssetCacheFailure.invalidSource
        }
        return count
    }
    private func close(_ handle: FileHandle) {
        do { try handle.close() }
        catch { Task { @MainActor in CarryLogger.shared.log(.attachmentSaveFailed, context: "account_cache_close") } }
    }
    private func digest(_ source: URL, expectedBytes: Int) throws -> String {
        _ = try regularFile(source, expectedBytes: expectedBytes)
        let handle = try FileHandle(forReadingFrom: source); defer { close(handle) }
        var hash = SHA256(), total = 0
        while true {
            try Task.checkCancellation()
            let bytes = try handle.read(upToCount: min(64 * 1024, expectedBytes - total + 1)) ?? Data()
            if bytes.isEmpty { break }
            total += bytes.count
            guard total <= expectedBytes else { throw CarryAccountAssetCacheFailure.invalidSource }
            hash.update(data: bytes)
        }
        guard total == expectedBytes else { throw CarryAccountAssetCacheFailure.invalidSource }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func verify(_ snapshot: CarryAccountAssetSnapshot) throws -> URL {
        let file = try url(for: snapshot.token)
        guard try digest(file, expectedBytes: snapshot.byteCount) == snapshot.token.sha256 else {
            throw CarryAccountAssetCacheFailure.invalidSource
        }
        return file
    }
    /// Reopen a crash-surviving import before its journal has produced a job.
    /// The token supplies only identity; actual bounded size and digest come
    /// from the private immutable file, on this background actor.
    func verify(_ token: CarryAccountAssetToken) throws -> CarryAccountAssetSnapshot {
        let file = try url(for: token)
        let count = try regularFile(file)
        guard try digest(file, expectedBytes: count) == token.sha256 else { throw CarryAccountAssetCacheFailure.invalidSource }
        return CarryAccountAssetSnapshot(token: token, byteCount: count)
    }
    func snapshot(fileURL: URL, assetID: UUID = UUID()) throws -> CarryAccountAssetSnapshot {
        try snapshotFile(fileURL, assetID: assetID, entityID: nil, slot: nil)
    }
    /// Remote identity is authenticated before import. Invalid bytes never
    /// reserve that immutable ID; a verified copy may repair its corrupt cache.
    func snapshot(fileURL: URL, assetID: UUID, expectedSHA256: String, expectedByteCount: Int) throws -> CarryAccountAssetSnapshot {
        _ = try CarryAccountAssetToken(accountID: accountID, assetID: assetID, sha256: expectedSHA256)
        guard (1...Self.maximumBytes).contains(expectedByteCount) else { throw CarryAccountAssetCacheFailure.invalidSource }
        return try snapshotFile(fileURL, assetID: assetID, entityID: nil, slot: nil,
            expectedSHA256: expectedSHA256, expectedByteCount: expectedByteCount)
    }
    func snapshot(fileURL: URL, entityID: UUID, slot: String) throws -> CarryAccountAssetSnapshot {
        try snapshotFile(fileURL, assetID: nil, entityID: entityID, slot: slot)
    }
    private func snapshotFile(_ fileURL: URL, assetID: UUID?, entityID: UUID?, slot: String?,
        expectedSHA256: String? = nil, expectedByteCount: Int? = nil) throws -> CarryAccountAssetSnapshot {
        try Task.checkCancellation()
        guard fileURL.isFileURL else { throw CarryAccountAssetCacheFailure.invalidSource }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        _ = try regularFile(fileURL)
        let input = try FileHandle(forReadingFrom: fileURL); defer { close(input) }
        return try copy(assetID: assetID, entityID: entityID, slot: slot, expectedSHA256: expectedSHA256,
            expectedByteCount: expectedByteCount) { try input.read(upToCount: $0) ?? Data() }
    }
    func snapshot(data: Data, assetID: UUID = UUID()) throws -> CarryAccountAssetSnapshot {
        try snapshotData(data, assetID: assetID, entityID: nil, slot: nil)
    }
    func snapshot(data: Data, entityID: UUID, slot: String) throws -> CarryAccountAssetSnapshot {
        try snapshotData(data, assetID: nil, entityID: entityID, slot: slot)
    }
    private func snapshotData(_ data: Data, assetID: UUID?, entityID: UUID?, slot: String?) throws -> CarryAccountAssetSnapshot {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw CarryAccountAssetCacheFailure.invalidSource }
        var offset = 0
        return try copy(assetID: assetID, entityID: entityID, slot: slot) { count in
            let end = min(data.count, offset + count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }
    private func copy(assetID: UUID?, entityID: UUID?, slot: String?, expectedSHA256: String? = nil,
        expectedByteCount: Int? = nil, read: (Int) throws -> Data) throws -> CarryAccountAssetSnapshot {
        try Task.checkCancellation(); try prepareDirectory()
        // This operation alone owns this random staging path. Cancellation never
        // enumerates/removes another operation's staging or uploader checkpoints.
        let stage = directory.appendingPathComponent(".stage-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: stage.path, contents: nil,
            attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: stage)
            var hash = SHA256(), total = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let bytes = try read(min(64 * 1024, Self.maximumBytes - total + 1))
                    if bytes.isEmpty { break }
                    total += bytes.count
                    guard total <= Self.maximumBytes else { throw CarryAccountAssetCacheFailure.invalidSource }
                    hash.update(data: bytes); try output.write(contentsOf: bytes)
                }
                guard total > 0 else { throw CarryAccountAssetCacheFailure.invalidSource }
                try output.synchronize(); try output.close()
            } catch { close(output); throw error }
            let sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard expectedSHA256 == nil || expectedSHA256 == sha256,
                  expectedByteCount == nil || expectedByteCount == total else { throw CarryAccountAssetCacheFailure.invalidSource }
            let resolvedID: UUID
            if let assetID { resolvedID = assetID }
            else if let entityID, let slot { resolvedID = try CarryAccountAssetIdentity.id(accountID: accountID, entityID: entityID, slot: slot, sha256: sha256) }
            else { throw CarryAccountAssetCacheFailure.invalidState }
            let target = try assetDirectory(resolvedID)
            let token = try CarryAccountAssetToken(accountID: accountID, assetID: resolvedID, sha256: sha256)
            let result = CarryAccountAssetSnapshot(token: token, byteCount: total)
            let final = target.appendingPathComponent(token.rawValue)
            let prefix = "carryasset1_\(accountID.uuidString.lowercased())_\(resolvedID.uuidString.lowercased())_"
            let existing = try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0.hasPrefix(prefix) }
            guard existing.allSatisfy({ $0 == token.rawValue }) else { throw CarryAccountAssetCacheFailure.immutableIdentity }
            try Task.checkCancellation()
            if existing.isEmpty {
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: stage.path)
                try FileManager.default.moveItem(at: stage, to: final)
            } else {
                do {
                    _ = try verify(result)
                    try FileManager.default.removeItem(at: stage)
                } catch CarryAccountAssetCacheFailure.invalidSource {
                    guard expectedSHA256 != nil, expectedByteCount != nil else { throw CarryAccountAssetCacheFailure.invalidSource }
                    let info = try final.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true else { throw CarryAccountAssetCacheFailure.invalidSource }
                    try Task.checkCancellation()
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: stage.path)
                    // Foundation's replacement tries to open the 0400 target
                    // for writing. POSIX rename atomically swaps directory
                    // entries without mutating the immutable file's bytes.
                    let status = stage.path.withCString { source in
                        final.path.withCString { destination in Darwin.rename(source, destination) }
                    }
                    guard status == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }
            return result
        } catch {
            if FileManager.default.fileExists(atPath: stage.path) {
                do { try FileManager.default.removeItem(at: stage) }
                catch { Task { @MainActor in CarryLogger.shared.log(.attachmentDeleteFailed, context: "account_cache_stage") } }
            }
            throw error
        }
    }
    /// Call only after synchronizers have paused or under the same coordinator
    /// gate used for capture/freeze. The keep set includes native references,
    /// unconsumed journal references, queued jobs and all frozen request pins.
    func collect(keeping: Set<CarryAccountAssetToken>) throws -> [CarryAccountAssetToken] {
        guard keeping.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetCacheFailure.wrongAccount }
        try Task.checkCancellation(); try prepareDirectory()
        var removed: [CarryAccountAssetToken] = []
        for folderName in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            guard let id = UUID(uuidString: folderName), id.uuidString.lowercased() == folderName else { continue }
            let folder = try assetDirectory(id)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                guard name.hasPrefix("carryasset1_") else { continue }
                let token = try CarryAccountAssetToken(rawValue: name)
                guard token.accountID == accountID, token.assetID == id else { throw CarryAccountAssetCacheFailure.wrongAccount }
                guard !keeping.contains(token) else { continue }
                try Task.checkCancellation()
                let file = folder.appendingPathComponent(name)
                _ = try regularFile(file)
                try FileManager.default.removeItem(at: file); removed.append(token)
            }
        }
        return removed
    }
}

// All three models are private account-cache metadata, never CloudKit SchemaV1.
@Model final class CarryAccountAssetQueueOwner {
    @Attribute(.unique) var key: String
    var accountID: UUID
    init(accountID: UUID) { key = "account"; self.accountID = accountID }
}
@Model final class CarryAccountAssetBinding {
    @Attribute(.unique) var key: String
    var accountID: UUID
    var entityID: UUID
    var entityKind: String
    var slot: String
    var assetID: UUID
    var sourceReference: String?
    init(accountID: UUID, entityID: UUID, entityKind: String, slot: String, assetID: UUID, sourceReference: String?) {
        key = "\(accountID.uuidString)|\(entityID.uuidString)|\(slot)"; self.accountID = accountID
        self.entityID = entityID; self.entityKind = entityKind; self.slot = slot; self.assetID = assetID; self.sourceReference = sourceReference
    }
}
@Model final class CarryAccountAssetJob {
    @Attribute(.unique) var assetID: UUID
    var accountID: UUID
    var entityID: UUID
    var entityKind: String
    var slot: String
    var fileToken: String
    var sha256: String
    var byteCount: Int
    var contentType: String
    var phase: String
    var frozenRequestIDs: [UUID]
    var createdAt: Date
    init(snapshot: CarryAccountAssetSnapshot, entityID: UUID, entityKind: String, slot: String, contentType: String) {
        assetID = snapshot.token.assetID; accountID = snapshot.token.accountID; self.entityID = entityID
        self.entityKind = entityKind; self.slot = slot; fileToken = snapshot.token.rawValue
        sha256 = snapshot.token.sha256; byteCount = snapshot.byteCount; self.contentType = contentType
        phase = "queued"; frozenRequestIDs = []; createdAt = Date()
    }
}

nonisolated struct CarryAccountAssetWork: Sendable {
    let snapshot: CarryAccountAssetSnapshot
    let descriptor: CarryAssetDescriptor
    let isVerified: Bool
}

/// Pure metadata operations; the caller saves this with native/replica intent
/// and rolls back the whole transaction on failure. No method reads a file or
/// starts an upload. Keep the queue's private container out of CloudKit.
@MainActor final class CarryAccountAssetQueue {
    static let models: [any PersistentModel.Type] = [CarryAccountAssetQueueOwner.self, CarryAccountAssetBinding.self, CarryAccountAssetJob.self]
    let accountID: UUID
    init(accountID: UUID) { self.accountID = accountID }
    private func validate(_ context: ModelContext) throws {
        guard context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }),
              Self.models.allSatisfy({ type in context.container.schema.entities.contains { $0.name == String(describing: type) } }) else {
            throw CarryAccountAssetCacheFailure.wrongContainer
        }
        let owners = try context.fetch(FetchDescriptor<CarryAccountAssetQueueOwner>())
        guard owners.count <= 1, owners.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetCacheFailure.wrongAccount }
        if context.container.schema.entities.contains(where: { $0.name == String(describing: CarryReplicaCheckpoint.self) }) {
            let checkpoints = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
            guard checkpoints.count <= 1, checkpoints.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetCacheFailure.wrongAccount }
        }
        if context.container.schema.entities.contains(where: { $0.name == String(describing: CarryNativeJournalOwner.self) }) {
            let journals = try context.fetch(FetchDescriptor<CarryNativeJournalOwner>())
            guard journals.count <= 1, journals.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetCacheFailure.wrongAccount }
        }
        if owners.isEmpty { context.insert(CarryAccountAssetQueueOwner(accountID: accountID)) }
    }
    private func job(_ id: UUID, in context: ModelContext) throws -> CarryAccountAssetJob? {
        var query = FetchDescriptor<CarryAccountAssetJob>(predicate: #Predicate { $0.assetID == id }); query.fetchLimit = 1
        return try context.fetch(query).first
    }
    private func validDescription(kind: String, slot: String, contentType: String) -> Bool {
        let validSlot: Bool
        switch kind {
        case "photo": validSlot = ["thumbnail", "original"].contains(slot)
        case "attachment": validSlot = ["thumbnail", "file"].contains(slot)
        case "libraryItem": validSlot = slot == "image"
        case "trip":
            let suffix = String(slot.dropFirst("background:".count))
            validSlot = slot.hasPrefix("background:") && (1...255).contains(suffix.utf8.count)
                && suffix != "." && suffix != ".." && !suffix.contains("/") && !suffix.contains("\\")
        default: validSlot = false
        }
        return validSlot && !slot.contains("|") && !slot.contains("\0") && contentType.utf8.count <= 200
            && contentType.range(of: "^[A-Za-z0-9.+_-]+/[A-Za-z0-9.+_-]+$", options: .regularExpression) != nil
    }
    private func work(_ job: CarryAccountAssetJob) throws -> CarryAccountAssetWork {
        let token = try CarryAccountAssetToken(rawValue: job.fileToken)
        guard job.accountID == accountID, token.accountID == accountID, token.assetID == job.assetID,
              token.sha256 == job.sha256, (1...CarryAccountAssetCache.maximumBytes).contains(job.byteCount),
              validDescription(kind: job.entityKind, slot: job.slot, contentType: job.contentType),
              token.assetID == (try CarryAccountAssetIdentity.id(accountID: accountID, entityID: job.entityID, slot: job.slot, sha256: job.sha256)),
              ["queued", "uploading", "verified"].contains(job.phase) else { throw CarryAccountAssetCacheFailure.invalidState }
        return CarryAccountAssetWork(snapshot: .init(token: token, byteCount: job.byteCount),
            descriptor: .init(id: job.assetID, entityID: job.entityID, entityKind: job.entityKind,
                slot: job.slot, sha256: job.sha256, byteCount: job.byteCount, contentType: job.contentType), isVerified: job.phase == "verified")
    }
    @discardableResult
    func bind(_ snapshot: CarryAccountAssetSnapshot, entityID: UUID, entityKind: String, slot: String,
              contentType: String = "application/octet-stream", sourceReference: String? = nil,
              in context: ModelContext) throws -> CarryAccountAssetWork {
        try validate(context)
        guard snapshot.token.accountID == accountID else { throw CarryAccountAssetCacheFailure.wrongAccount }
        guard validDescription(kind: entityKind, slot: slot, contentType: contentType),
              (1...CarryAccountAssetCache.maximumBytes).contains(snapshot.byteCount) else { throw CarryAccountAssetCacheFailure.invalidState }
        guard snapshot.token.assetID == (try CarryAccountAssetIdentity.id(accountID: accountID, entityID: entityID,
            slot: slot, sha256: snapshot.token.sha256)) else { throw CarryAccountAssetCacheFailure.immutableIdentity }
        let record: CarryAccountAssetJob
        if let existing = try job(snapshot.token.assetID, in: context) {
            let old = try work(existing)
            guard old.snapshot.token == snapshot.token, old.snapshot.byteCount == snapshot.byteCount,
                  existing.entityID == entityID, existing.entityKind == entityKind, existing.slot == slot,
                  existing.contentType == contentType else { throw CarryAccountAssetCacheFailure.immutableIdentity }
            record = existing
        } else {
            record = CarryAccountAssetJob(snapshot: snapshot, entityID: entityID, entityKind: entityKind, slot: slot, contentType: contentType)
            context.insert(record)
        }
        let key = "\(accountID.uuidString)|\(entityID.uuidString)|\(slot)"
        var query = FetchDescriptor<CarryAccountAssetBinding>(predicate: #Predicate { $0.key == key }); query.fetchLimit = 1
        if let binding = try context.fetch(query).first {
            guard binding.accountID == accountID, binding.entityKind == entityKind else { throw CarryAccountAssetCacheFailure.invalidState }
            binding.assetID = snapshot.token.assetID; binding.sourceReference = sourceReference
        } else { context.insert(CarryAccountAssetBinding(accountID: accountID, entityID: entityID,
            entityKind: entityKind, slot: slot, assetID: snapshot.token.assetID, sourceReference: sourceReference)) }
        return try work(record)
    }
    func binding(entityID: UUID, slot: String, in context: ModelContext) throws -> CarryAccountAssetWork? {
        try validate(context)
        let key = "\(accountID.uuidString)|\(entityID.uuidString)|\(slot)"
        var query = FetchDescriptor<CarryAccountAssetBinding>(predicate: #Predicate { $0.key == key }); query.fetchLimit = 1
        guard let binding = try context.fetch(query).first else { return nil }
        guard binding.accountID == accountID, let record = try job(binding.assetID, in: context),
              record.entityID == entityID, record.slot == slot, record.entityKind == binding.entityKind else {
            throw CarryAccountAssetCacheFailure.invalidState
        }
        return try work(record)
    }
    func pendingWork(limit: Int = 2, in context: ModelContext) throws -> [CarryAccountAssetWork] {
        try validate(context)
        guard (1...64).contains(limit) else { throw CarryAccountAssetCacheFailure.invalidState }
        var query = FetchDescriptor<CarryAccountAssetJob>(predicate: #Predicate { $0.phase == "queued" || $0.phase == "uploading" },
            sortBy: [SortDescriptor(\.createdAt)])
        query.fetchLimit = limit
        return try context.fetch(query).map { try work($0) }
    }
    func unbind(entityID: UUID, slot: String, in context: ModelContext) throws {
        try validate(context)
        let key = "\(accountID.uuidString)|\(entityID.uuidString)|\(slot)"
        for binding in try context.fetch(FetchDescriptor<CarryAccountAssetBinding>(predicate: #Predicate { $0.key == key })) { context.delete(binding) }
    }
    func freeze(assetIDs: Set<UUID>, requestID: UUID, in context: ModelContext) throws -> [CarryAccountAssetWork] {
        try validate(context)
        var result: [CarryAccountAssetWork] = []
        for id in assetIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let record = try job(id, in: context) else { throw CarryAccountAssetCacheFailure.invalidState }
            result.append(try work(record))
            if !record.frozenRequestIDs.contains(requestID) { record.frozenRequestIDs.append(requestID) }
        }
        return result
    }
    func markUploading(_ assetID: UUID, in context: ModelContext) throws {
        try validate(context)
        guard let record = try job(assetID, in: context) else { throw CarryAccountAssetCacheFailure.invalidState }
        _ = try work(record); record.phase = "uploading"
    }
    /// Invoke only after CarryAssetTransfer.transfer returns server verification.
    func markVerified(_ assetID: UUID, in context: ModelContext) throws {
        try validate(context)
        guard let record = try job(assetID, in: context) else { throw CarryAccountAssetCacheFailure.invalidState }
        _ = try work(record); record.phase = "verified"
    }
    /// Recover an interrupted upload after awaiting uploader.pauseAll/close.
    func requeue(_ assetID: UUID, in context: ModelContext) throws {
        try validate(context)
        guard let record = try job(assetID, in: context) else { throw CarryAccountAssetCacheFailure.invalidState }
        _ = try work(record); if record.phase != "verified" { record.phase = "queued" }
    }
    func release(requestID: UUID, in context: ModelContext) throws {
        try validate(context)
        for record in try context.fetch(FetchDescriptor<CarryAccountAssetJob>()) {
            _ = try work(record); record.frozenRequestIDs.removeAll { $0 == requestID }
        }
    }
    /// Delete metadata only. The coordinator performs physical GC with the
    /// committed retention set and any unconsumed-journal/native references.
    func retireUnboundJobs(in context: ModelContext) throws {
        try validate(context)
        let bindings = try context.fetch(FetchDescriptor<CarryAccountAssetBinding>())
        guard bindings.allSatisfy({ $0.accountID == accountID }) else { throw CarryAccountAssetCacheFailure.wrongAccount }
        let bound = Set(bindings.map(\.assetID))
        for record in try context.fetch(FetchDescriptor<CarryAccountAssetJob>()) {
            _ = try work(record)
            if !bound.contains(record.assetID), record.frozenRequestIDs.isEmpty, record.phase != "uploading" { context.delete(record) }
        }
    }
    func retainedTokens(in context: ModelContext) throws -> Set<CarryAccountAssetToken> {
        try validate(context)
        let jobs = try context.fetch(FetchDescriptor<CarryAccountAssetJob>())
        let ids = Set(jobs.map(\.assetID))
        let bindings = try context.fetch(FetchDescriptor<CarryAccountAssetBinding>())
        guard bindings.allSatisfy({ $0.accountID == accountID && ids.contains($0.assetID) }) else {
            throw CarryAccountAssetCacheFailure.invalidState
        }
        return try Set(jobs.map { try work($0).snapshot.token })
    }
}
