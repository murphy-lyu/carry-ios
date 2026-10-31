import Foundation
import UIKit
import UniformTypeIdentifiers

/// Explicit per-store import dependency. It never chooses an account from a
/// process-global setting and never writes account bytes into guest folders.
@MainActor
final class CarryAccountImportService {
    let accountID: UUID
    private let cache: CarryAccountAssetCache
    private let access: CarryAccountFileAccess
    private let lease: CarryAccountFileAccess.Lease
    private var pins: [UUID: CarryAccountAssetToken] = [:]
    private var closed = false
    init(accountID: UUID, cache: CarryAccountAssetCache, access: CarryAccountFileAccess,
         lease: CarryAccountFileAccess.Lease) throws {
        guard cache.accountID == accountID, lease.accountID == accountID else { throw CarryAccountAssetCacheFailure.wrongAccount }
        self.accountID = accountID; self.cache = cache; self.access = access; self.lease = lease
    }
    var preparedTokens: Set<CarryAccountAssetToken> { Set(pins.values) }
    func close() { closed = true }

    private func prepare(snapshot: CarryAccountAssetSnapshot, entityID: UUID, thumbnail: Data,
                         name: String, ext: String, isPhoto: Bool) async throws -> PreparedAttachmentImport {
        let url = try await cache.verify(snapshot)
        try Task.checkCancellation()
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        try access.publish([snapshot.token.rawValue: url], lease: lease)
        let pin = UUID(); pins[pin] = snapshot.token
        let service = self
        return PreparedAttachmentImport(fileURL: url, thumbnailData: thumbnail, displayName: name, ext: ext,
            isPhoto: isPhoto, entityID: entityID, ownsPhysicalFile: false,
            release: { Task { @MainActor in service.pins.removeValue(forKey: pin) } })
    }

    func attachment(from temporary: PreparedAttachmentImport, entityID: UUID = UUID()) async throws -> PreparedAttachmentImport {
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        let snapshot = try await cache.snapshot(fileURL: temporary.fileURL, entityID: entityID, slot: "file")
        let result = try await prepare(snapshot: snapshot, entityID: entityID, thumbnail: temporary.thumbnailData,
            name: temporary.displayName, ext: temporary.ext, isPhoto: temporary.isPhoto)
        try await temporary.discard()
        try Task.checkCancellation()
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        return result
    }

    func originalPhoto(data: Data, entityID: UUID) async throws -> PreparedAttachmentImport {
        guard !closed else { throw CarryNativeAssetCoordinatorFailure.closed }
        let snapshot = try await cache.snapshot(data: data, entityID: entityID, slot: "original")
        return try await prepare(snapshot: snapshot, entityID: entityID, thumbnail: Data(), name: "", ext: "image", isPhoto: true)
    }

    func background(image: UIImage, tripID: UUID) async throws -> PreparedAttachmentImport {
        let encoding = Task.detached(priority: .utility) { try Self.backgroundBytes(image) }
        let bytes = try await withTaskCancellationHandler(operation: { try await encoding.value }, onCancel: { encoding.cancel() })
        let snapshot = try await cache.snapshot(data: bytes, entityID: tripID, slot: "background:0:0")
        return try await prepare(snapshot: snapshot, entityID: tripID, thumbnail: Data(), name: "", ext: "jpg", isPhoto: true)
    }

    private nonisolated static func backgroundBytes(_ image: UIImage) throws -> Data {
        try Task.checkCancellation()
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest.isFinite, longest > 0 else { throw AttachmentImportFailure.notARegularFile }
        let ratio = min(1, 1400 / longest)
        let size = CGSize(width: image.size.width * image.scale * ratio, height: image.size.height * image.scale * ratio)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let bytes = resized.jpegData(compressionQuality: 0.72) else { throw AttachmentImportFailure.notARegularFile }
        try Task.checkCancellation(); return bytes
    }
}

nonisolated enum CarryAccountAttachmentPreview {
    /// Quick Look receives an extension-bearing private alias, while graph and
    /// cache identity retain the immutable .blob token. The alias lease removes
    /// only its own link/copy; it never deletes the original cache snapshot.
    static func prepare(url: URL, ext: String) async throws -> PreparedAttachmentImport {
        let work = Task.detached(priority: .utility) {
            let token = try CarryAccountAssetToken(rawValue: url.lastPathComponent)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, let count = info.fileSize,
                  count > 0, count <= CarryAccountAssetCache.maximumBytes else { throw CarryAccountAssetCacheFailure.invalidSource }
            let type = UTType(ext)?.preferredFilenameExtension ?? ext
            let safe = type.lowercased()
            guard safe.count <= 20, !safe.isEmpty, safe.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw CarryAccountAssetCacheFailure.invalidSource
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CarryAccountPreviews", isDirectory: true)
                .appendingPathComponent(token.accountID.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let alias = folder.appendingPathComponent(UUID().uuidString + "." + safe)
            do { try FileManager.default.linkItem(at: url, to: alias) }
            catch { try FileManager.default.copyItem(at: url, to: alias) }
            let result = PreparedAttachmentImport(fileURL: alias, thumbnailData: Data(), displayName: "", ext: safe, isPhoto: false)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}
