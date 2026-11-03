import Foundation
import Photos

nonisolated enum CarryMigrationBackupFailure: Error { case missingFile, invalidFile, batchTooLarge, photoPermission, photoUnavailable }

nonisolated struct CarryMigrationPreparedBackup: Sendable {
    let backup: CarryBackup
    let url: URL
    let originalPhotos: [UUID: URL]
    let directory: URL
}

/// Full source backup preparation has no network writes. Ordinary attachment
/// bytes have a bounded batch budget; originals stay in separate files so a
/// library of full-resolution images is never held in one JSON/Data value.
nonisolated enum CarryMigrationBackupPreparation {
    static let maximumEmbeddedBytes = 128 * 1024 * 1024
    @concurrent static func prepare(_ source: CarryBackup, attachments: [String: URL], backgrounds: [String: URL],
                                    originalPhotos: [UUID: URL], directory: URL) async throws -> CarryMigrationPreparedBackup {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backup = source, total = 0
        var files: [String: Data] = [:], images: [String: Data] = [:]
        for (name, url) in attachments {
            let bytes = try read(url, maximum: AttachmentStore.maxBytes)
            guard bytes.count <= maximumEmbeddedBytes - total else { throw CarryMigrationBackupFailure.batchTooLarge }
            total += bytes.count; files[name] = bytes
        }
        for (name, url) in backgrounds {
            let bytes = try read(url, maximum: CarryAccountAssetCache.maximumBytes)
            guard bytes.count <= maximumEmbeddedBytes - total else { throw CarryMigrationBackupFailure.batchTooLarge }
            total += bytes.count; images[name] = bytes
        }
        backup.attachmentFiles = files; backup.backgroundImages = images
        // The engine archives these originals alongside source.json and checks
        // each file's exact digest before any graph ownership can be activated.
        let encoder = CarryBackupDates.encoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(backup)
        try Task.checkCancellation()
        let url = directory.appendingPathComponent("source.json")
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return CarryMigrationPreparedBackup(backup: backup, url: url, originalPhotos: originalPhotos, directory: directory)
    }
    @concurrent static func discard(_ directory: URL) async throws {
        guard directory.isFileURL, directory.lastPathComponent.hasPrefix("CarryMigrationPreparation-") else {
            throw CarryMigrationBackupFailure.invalidFile
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let count = info.fileSize, count > 0, count <= maximum else {
            throw CarryMigrationBackupFailure.invalidFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { do { try handle.close() } catch { Task { @MainActor in CarryLogger.shared.log(.loadFailed, context: "migration_source_close") } } }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let next = try handle.read(upToCount: min(64 * 1024, maximum - data.count + 1)) ?? Data()
            if next.isEmpty { break }
            guard next.count <= maximum - data.count else { throw CarryMigrationBackupFailure.batchTooLarge }
            data.append(next)
        }
        guard data.count == count else { throw CarryMigrationBackupFailure.invalidFile }
        return data
    }
    @concurrent static func validateOriginal(_ url: URL) async throws {
        try Task.checkCancellation()
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let count = info.fileSize,
              count > 0, count <= CarryAccountAssetCache.maximumBytes else { throw CarryMigrationBackupFailure.batchTooLarge }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    @concurrent static func saveOriginal(_ data: Data, photoID: UUID, directory: URL) async throws -> URL {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= CarryAccountAssetCache.maximumBytes else { throw CarryMigrationBackupFailure.batchTooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(photoID.uuidString.lowercased() + ".original")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

/// Only Photos identifiers already referenced by the explicitly selected trips
/// are collected. Limited Photos access is respected; unavailable originals
/// stop migration without replacing them with thumbnails.
@MainActor
final class CarryMigrationPhotoCollector {
    func collect(_ photos: [BackupStopPhoto], directory: URL) async throws -> [UUID: URL] {
        let selected = photos.filter { !$0.assetLocalIdentifier.isEmpty }
        guard !selected.isEmpty else { return [:] }
        let needsPhotos = selected.contains { !CarryAccountFileAccess.isAccountReference($0.assetLocalIdentifier) && !$0.assetLocalIdentifier.hasPrefix("carryphoto1_") }
        if needsPhotos {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let authorized = status == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : status
            guard authorized == .authorized || authorized == .limited else { throw CarryMigrationBackupFailure.photoPermission }
        }
        var result: [UUID: URL] = [:]
        for photo in selected {
            try Task.checkCancellation()
            if photo.assetLocalIdentifier.hasPrefix("carryphoto1_") {
                guard !photo.assetLocalIdentifier.contains("/"), !photo.assetLocalIdentifier.contains("\\"), photo.assetLocalIdentifier.utf8.count <= 255 else {
                    throw CarryMigrationBackupFailure.invalidFile
                }
                result[photo.id] = AttachmentStore.fileURL(named: photo.assetLocalIdentifier)
                continue
            }
            if CarryAccountFileAccess.isAccountReference(photo.assetLocalIdentifier) {
                guard let url = CarryAccountFileAccess.shared.url(named: photo.assetLocalIdentifier) else { throw CarryMigrationBackupFailure.photoUnavailable }
                result[photo.id] = url
                continue
            }
            let found = PHAsset.fetchAssets(withLocalIdentifiers: [photo.assetLocalIdentifier], options: nil)
            guard let asset = found.firstObject else { throw CarryMigrationBackupFailure.photoUnavailable }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }) else {
                throw CarryMigrationBackupFailure.photoUnavailable
            }
            let url = directory.appendingPathComponent(photo.id.uuidString.lowercased() + ".original")
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if error != nil { continuation.resume(throwing: CarryMigrationBackupFailure.photoUnavailable) }
                    else { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            try await CarryMigrationBackupPreparation.validateOriginal(url)
            result[photo.id] = url
        }
        return result
    }
}
