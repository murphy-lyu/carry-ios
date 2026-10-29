import Foundation
import os
import CoreTransferable
import UniformTypeIdentifiers

nonisolated enum AttachmentImportFailure: Error { case tooLarge, notARegularFile }

/// A newly written file stays owned by this lease until its metadata is saved
/// or accepted into an edit form's pending list. Cancellation and rejected saves
/// release it; dropping a task/result also has a cleanup backstop.
nonisolated final class PreparedAttachmentImport: Sendable {
    let fileURL: URL
    let thumbnailData: Data
    let displayName: String
    let ext: String
    let isPhoto: Bool
    private let owned = OSAllocatedUnfairLock(initialState: true)

    init(fileURL: URL, thumbnailData: Data, displayName: String, ext: String, isPhoto: Bool) {
        self.fileURL = fileURL; self.thumbnailData = thumbnailData
        self.displayName = displayName; self.ext = ext; self.isPhoto = isPhoto
    }

    func adopt() { owned.withLock { $0 = false } }

    func discard() async throws {
        guard owned.withLock({ value in let result = value; value = false; return result }) else { return }
        let url = fileURL
        do { try await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: url) }.value }
        catch {
            // Keep the fallback armed if explicit cleanup could not complete.
            owned.withLock { $0 = true }
            throw error
        }
    }

    deinit {
        guard owned.withLock({ $0 }) else { return }
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            do { try FileManager.default.removeItem(at: url) }
            catch {
                Task { @MainActor in CarryLogger.shared.log(.attachmentDeleteFailed, context: "import_discard") }
            }
        }
    }
}

nonisolated enum AttachmentImportWorker {
    /// Limit every actual read too: the file can grow after its size metadata
    /// was checked, or a provider may omit its size. Never read the full input
    /// first and apply the limit only afterwards.
    static func readBounded(advertisedLength: Int?, maxBytes: Int = AttachmentStore.maxBytes,
                            read: (Int) throws -> Data) throws -> Data {
        if let advertisedLength, advertisedLength > maxBytes { throw AttachmentImportFailure.tooLarge }
        var result = Data()
        if let advertisedLength, advertisedLength > 0 { result.reserveCapacity(min(advertisedLength, maxBytes)) }
        while true {
            try Task.checkCancellation()
            let bytes = try read(min(64 * 1024, maxBytes - result.count + 1))
            guard !bytes.isEmpty else { return result }
            guard bytes.count <= maxBytes - result.count else { throw AttachmentImportFailure.tooLarge }
            result.append(bytes)
        }
    }

    static func prepare(fileURL: URL, isPhoto: Bool = false, directory: URL? = nil) async throws -> PreparedAttachmentImport {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            let metadata = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard metadata.isRegularFile == true else { throw AttachmentImportFailure.notARegularFile }
            if let length = metadata.fileSize, length > AttachmentStore.maxBytes { throw AttachmentImportFailure.tooLarge }
            let handle = try FileHandle(forReadingFrom: fileURL)
            let data: Data
            do {
                data = try readBounded(advertisedLength: metadata.fileSize) { try handle.read(upToCount: $0) ?? Data() }
                try handle.close()
            } catch {
                do { try handle.close() }
                catch {
                    Task { @MainActor in CarryLogger.shared.log(.attachmentSaveFailed, context: "import_close") }
                }
                throw error
            }
            return try prepareBytes(data, ext: fileURL.pathExtension.isEmpty ? "dat" : fileURL.pathExtension,
                                    displayName: isPhoto ? "" : fileURL.lastPathComponent, isPhoto: isPhoto, directory: directory)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    static func prepare(data: Data, ext: String, directory: URL? = nil) async throws -> PreparedAttachmentImport {
        let work = Task.detached(priority: .utility) {
            try prepareBytes(data, ext: ext, displayName: "", isPhoto: true, directory: directory)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func prepareBytes(_ data: Data, ext: String, displayName: String,
                                     isPhoto: Bool, directory: URL?) throws -> PreparedAttachmentImport {
        try Task.checkCancellation()
        guard data.count <= AttachmentStore.maxBytes else { throw AttachmentImportFailure.tooLarge }
        let thumbnail = AttachmentThumbnail.make(from: data) ?? Data()
        try Task.checkCancellation()
        let url = try AttachmentStore.writeImportedFile(data, ext: ext, directory: directory)
        let result = PreparedAttachmentImport(fileURL: url, thumbnailData: thumbnail,
            displayName: displayName, ext: ext, isPhoto: isPhoto)
        // If cancellation arrives during the atomic write, the unadopted result
        // owns cleanup even though no metadata will reach the UI.
        if Task.isCancelled {
            try FileManager.default.removeItem(at: url)
            result.adopt()
            throw CancellationError()
        }
        return result
    }
}

/// The Photos provider keeps this received file alive during the import
/// closure. Read it through the same bounded worker instead of asking Photos
/// to materialize an arbitrarily large original as one Data value first.
nonisolated struct AttachmentPhotoTransfer: Transferable, Sendable {
    let prepared: PreparedAttachmentImport
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            AttachmentPhotoTransfer(prepared: try await AttachmentImportWorker.prepare(fileURL: received.file, isPhoto: true))
        }
    }
}
