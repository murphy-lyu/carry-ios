import Foundation
import CryptoKit

/// Incoming files have fresh names and are never visible in a model until its
/// final save. UI entry points prepare bytes away from the persistence actor.
@MainActor
final class CarryBackupFileStage {
    let backup: CarryBackup
    private let files: [CarryBackupStagedFile]
    private let directory: URL
    private var publishedFiles: [URL] = []
    private let accountURLs: [String: URL]
    private var committed = false

    init(_ source: CarryBackup, allowLocalFileReferences: Bool = false) throws {
        let inputs = try Self.inputs(source)
        let prepared = try CarryBackupFilePreparation.build(source, inputs: inputs, allowLocalFileReferences: allowLocalFileReferences)
        backup = prepared.backup; files = prepared.files; directory = inputs.stageRoot; accountURLs = inputs.accountURLs
    }
    private init(_ prepared: CarryBackupPreparedFiles, inputs: CarryBackupFileInputs) { backup = prepared.backup; files = prepared.files; directory = inputs.stageRoot; accountURLs = inputs.accountURLs }
    func validateLease() throws {
        guard accountURLs.allSatisfy({ CarryAccountFileAccess.shared.url(named: $0.key) == $0.value }) else { throw DataBackupManager.BackupError.missingAsset }
    }
    func publish() throws {
        try validateLease()
        guard publishedFiles.isEmpty else { throw DataBackupManager.BackupError.targetChanged }
        for file in files {
            try Task.checkCancellation()
            guard !FileManager.default.fileExists(atPath: file.destination.path) else { throw DataBackupManager.BackupError.missingAsset }
            try FileManager.default.moveItem(at: file.staged, to: file.destination)
            publishedFiles.append(file.destination)
        }
    }
    func commit() { committed = true; CarryBackupFilePreparation.remove([], directory: directory) }
    func discard() {
        guard !committed else { return }
        CarryBackupFilePreparation.remove(files.map(\.staged) + publishedFiles, directory: directory)
    }
    func discardAsync() async {
        guard !committed else { return }
        await Self.removeAsync(files.map(\.staged) + publishedFiles, directory: directory)
    }
    static func prepareAsync(_ source: CarryBackup, allowLocalFileReferences: Bool = false) async throws -> CarryBackupFileStage {
        let backgroundNames = try await extractBackgroundNamesAsync(source)
        let inputs = try inputs(source, backgroundNames: backgroundNames)
        let prepared = try await buildAsync(source, inputs: inputs, allowLocalFileReferences: allowLocalFileReferences)
        do {
            try Task.checkCancellation()
            // Registry leases are resolved only on their actor. A sign-out or
            // workspace switch during disk work invalidates the result.
            guard inputs.accountURLs.allSatisfy({ CarryAccountFileAccess.shared.url(named: $0.key) == $0.value }) else {
                throw DataBackupManager.BackupError.missingAsset
            }
            return CarryBackupFileStage(prepared, inputs: inputs)
        } catch { await removeAsync(prepared.files.map(\.staged), directory: inputs.stageRoot); throw error }
    }
    nonisolated static func validateManifests(_ source: CarryBackup) throws { try CarryBackupFilePreparation.validateManifests(source) }
    nonisolated static func selectedManifests(_ source: CarryBackup) -> [CarryBackupAssetManifest]? {
        guard let manifests = source.assetManifest else { return nil }
        let ids = CarryBackupFilePreparation.entityIDs(source)
        return manifests.filter { ids.contains($0.entityID) }
    }
    nonisolated static func validateEmbeddedBudget(_ source: CarryBackup) throws -> Int { try CarryBackupFilePreparation.validateBudget(source) }
    private static func inputs(_ source: CarryBackup, backgroundNames: Set<String>? = nil) throws -> CarryBackupFileInputs {
        var names = try backgroundNames ?? CarryBackupFilePreparation.backgroundNames(source)
        for trip in source.trips {
            for day in trip.itineraryDays ?? [] {
                for stop in day.stops { names.formUnion((stop.attachments ?? []).map(\.fileName)); names.formUnion((stop.photos ?? []).map(\.assetLocalIdentifier)) }
                for segment in day.segments ?? [] { names.formUnion((segment.attachments ?? []).map(\.fileName)) }
            }
            for stay in trip.lodgingStays ?? [] { names.formUnion((stay.attachments ?? []).map(\.fileName)) }
        }
        var accountURLs: [String: URL] = [:]
        for name in names where CarryAccountFileAccess.isAccountReference(name) {
            if let url = CarryAccountFileAccess.shared.url(named: name) { accountURLs[name] = url }
        }
        return CarryBackupFileInputs(backgroundRoot: BackgroundImageStore.fileURL(named: ".stage").deletingLastPathComponent(),
            attachmentRoot: AttachmentStore.fileURL(named: ".stage").deletingLastPathComponent(),
            stageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("CarryBackupFileStage-" + UUID().uuidString, isDirectory: true), accountURLs: accountURLs)
    }
    @concurrent nonisolated private static func extractBackgroundNamesAsync(_ source: CarryBackup) async throws -> Set<String> { try CarryBackupFilePreparation.backgroundNames(source) }
    @concurrent nonisolated private static func buildAsync(_ source: CarryBackup, inputs: CarryBackupFileInputs,
                                                          allowLocalFileReferences: Bool) async throws -> CarryBackupPreparedFiles {
        try CarryBackupFilePreparation.build(source, inputs: inputs, allowLocalFileReferences: allowLocalFileReferences)
    }
    @concurrent nonisolated private static func removeAsync(_ files: [URL], directory: URL) async { CarryBackupFilePreparation.remove(files, directory: directory) }
    /// A shared itinerary cannot smuggle references to recipient-local private
    /// attachments. Full backup restore/merge is a separate explicit operation.
    static func itineraryOnly(_ source: BackupTrip) -> BackupTrip {
        var trip = source
        trip.backgroundsData = nil
        trip.itineraryDays = trip.itineraryDays?.map { value in
            var day = value
            day.stops = day.stops.map { value in
                var stop = value
                stop.attachments = nil
                stop.photos = nil
                stop.fromPhotos = false
                return stop
            }
            day.segments = day.segments?.map { value in var segment = value; segment.attachments = nil; return segment }
            return day
        }
        trip.lodgingStays = trip.lodgingStays?.map { value in var stay = value; stay.attachments = nil; return stay }
        return trip
    }
}

private nonisolated struct CarryBackupFileInputs: Sendable {
    let backgroundRoot: URL
    let attachmentRoot: URL
    let stageRoot: URL
    let accountURLs: [String: URL]
}
private nonisolated struct CarryBackupStagedFile: Sendable { let staged: URL; let destination: URL }
private nonisolated struct CarryBackupPreparedFiles: Sendable { let backup: CarryBackup; let files: [CarryBackupStagedFile] }
private nonisolated struct CarryBackupFilePreparation {
    var backup: CarryBackup
    let inputs: CarryBackupFileInputs
    let allowLocalFileReferences: Bool
    var files: [CarryBackupStagedFile] = []
    static func build(_ source: CarryBackup, inputs: CarryBackupFileInputs, allowLocalFileReferences: Bool) throws -> CarryBackupPreparedFiles {
        _ = try validateBudget(source)
        _ = try backgroundNames(source)
        try validateManifests(source)
        var worker = Self(backup: source, inputs: inputs, allowLocalFileReferences: allowLocalFileReferences)
        do { try worker.prepare(); return CarryBackupPreparedFiles(backup: worker.backup, files: worker.files) }
        catch { remove(worker.files.map(\.staged), directory: inputs.stageRoot); throw error }
    }
    static func backgroundNames(_ source: CarryBackup) throws -> Set<String> {
        var result = Set<String>()
        for trip in source.trips {
            try Task.checkCancellation()
            if let data = trip.backgroundsData, !data.isEmpty {
                guard data.count <= 128 * 1024 else { throw DataBackupManager.BackupError.tooLarge }
                let entries = try JSONDecoder().decode([TripBackgroundEntry].self, from: data)
                guard entries.count <= 1024 else { throw DataBackupManager.BackupError.tooLarge }
                result.formUnion(entries.compactMap(\.localFileName))
            }
        }
        return result
    }
    static func entityIDs(_ source: CarryBackup) -> Set<UUID> {
        var result = Set<UUID>()
        for trip in source.trips {
            result.insert(trip.id)
            for section in trip.sections { result.insert(section.id); for item in section.items { result.insert(item.id) } }
            for day in trip.itineraryDays ?? [] {
                result.insert(day.id)
                for stop in day.stops { result.insert(stop.id); for photo in stop.photos ?? [] { result.insert(photo.id) }; for file in stop.attachments ?? [] { result.insert(file.id) } }
                for segment in day.segments ?? [] { result.insert(segment.id); for file in segment.attachments ?? [] { result.insert(file.id) } }
            }
            for stay in trip.lodgingStays ?? [] { result.insert(stay.id); for file in stay.attachments ?? [] { result.insert(file.id) } }
        }
        return result
    }
    static func validateManifests(_ source: CarryBackup) throws {
        guard let manifests = source.assetManifest else { return }
        var expected: [String: Data] = [:]
        func add(_ id: UUID, slot: String, bytes: Data?) throws {
            guard let bytes, !bytes.isEmpty else { throw DataBackupManager.BackupError.missingAsset }
            let key = id.uuidString.lowercased() + ":" + slot
            guard expected[key] == nil else { throw DataBackupManager.BackupError.decodingFailed }
            expected[key] = bytes
        }
        func attachments(_ values: [BackupAttachment]?) throws {
            for file in values ?? [] {
                if !file.fileName.isEmpty { try add(file.id, slot: "file", bytes: source.attachmentFiles?[file.fileName]) }
                if !file.thumbnailData.isEmpty { try add(file.id, slot: "thumbnail", bytes: file.thumbnailData) }
            }
        }
        for trip in source.trips {
            if let data = trip.backgroundsData, !data.isEmpty {
                let entries = try JSONDecoder().decode([TripBackgroundEntry].self, from: data)
                for (index, entry) in entries.enumerated() { if let name = entry.localFileName { try add(trip.id, slot: "background:\(entry.destinationIndex):\(index)", bytes: source.backgroundImages?[name]) } }
            }
            for day in trip.itineraryDays ?? [] {
                for stop in day.stops {
                    try attachments(stop.attachments)
                    for photo in stop.photos ?? [] {
                        if !photo.thumbnailData.isEmpty { try add(photo.id, slot: "thumbnail", bytes: photo.thumbnailData) }
                        try add(photo.id, slot: "original", bytes: source.photoOriginals?[photo.id.uuidString.lowercased()])
                    }
                }
                for segment in day.segments ?? [] { try attachments(segment.attachments) }
            }
            for stay in trip.lodgingStays ?? [] { try attachments(stay.attachments) }
        }
        guard manifests.count == expected.count else { throw DataBackupManager.BackupError.missingAsset }
        var seen = Set<String>(), assetIDs = Set<UUID>()
        for manifest in manifests {
            try Task.checkCancellation()
            let key = manifest.entityID.uuidString.lowercased() + ":" + manifest.slot
            guard seen.insert(key).inserted, assetIDs.insert(manifest.assetID).inserted,
                  let bytes = expected[key], bytes.count == manifest.byteCount,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw DataBackupManager.BackupError.missingAsset }
        }
    }
    static func validateBudget(_ source: CarryBackup) throws -> Int {
        var identities = Set<UUID>()
        func identity(_ id: UUID) throws {
            guard identities.count < 20000 else { throw DataBackupManager.BackupError.tooLarge }
            guard identities.insert(id).inserted else { throw DataBackupManager.BackupError.decodingFailed }
        }
        for trip in source.trips {
            try identity(trip.id)
            for section in trip.sections { try identity(section.id); for item in section.items { try identity(item.id) } }
            for day in trip.itineraryDays ?? [] {
                try identity(day.id)
                for stop in day.stops { try identity(stop.id); for photo in stop.photos ?? [] { try identity(photo.id) }; for file in stop.attachments ?? [] { try identity(file.id) } }
                for segment in day.segments ?? [] { try identity(segment.id); for file in segment.attachments ?? [] { try identity(file.id) } }
            }
            for stay in trip.lodgingStays ?? [] { try identity(stay.id); for file in stay.attachments ?? [] { try identity(file.id) } }
        }
        for item in source.myItems { try identity(item.id) }
        var total = 0
        func add(_ data: Data, maximum: Int) throws {
            guard data.count <= maximum, data.count <= CarryMigrationBackupPreparation.maximumEmbeddedBytes - total else { throw DataBackupManager.BackupError.tooLarge }
            total += data.count
        }
        for data in source.backgroundImages?.values ?? Dictionary<String, Data>().values { try add(data, maximum: CarryAccountAssetCache.maximumBytes) }
        for data in source.attachmentFiles?.values ?? Dictionary<String, Data>().values { try add(data, maximum: AttachmentStore.maxBytes) }
        for data in source.photoOriginals?.values ?? Dictionary<String, Data>().values { try add(data, maximum: CarryAccountAssetCache.maximumBytes) }
        for trip in source.trips {
            for day in trip.itineraryDays ?? [] {
                for stop in day.stops {
                    for photo in stop.photos ?? [] { try add(photo.thumbnailData, maximum: CarryAccountAssetCache.maximumBytes) }
                    for file in stop.attachments ?? [] { try add(file.thumbnailData, maximum: CarryAccountAssetCache.maximumBytes) }
                }
                for segment in day.segments ?? [] { for file in segment.attachments ?? [] { try add(file.thumbnailData, maximum: CarryAccountAssetCache.maximumBytes) } }
            }
            for stay in trip.lodgingStays ?? [] { for file in stay.attachments ?? [] { try add(file.thumbnailData, maximum: CarryAccountAssetCache.maximumBytes) } }
        }
        return total
    }
    private func existingURL(_ name: String, background: Bool) throws -> URL {
        if CarryAccountFileAccess.isAccountReference(name) {
            guard let url = inputs.accountURLs[name] else { throw DataBackupManager.BackupError.missingAsset }
            return url
        }
        return (background ? inputs.backgroundRoot : inputs.attachmentRoot).appendingPathComponent(name)
    }
    static func remove(_ files: [URL], directory: URL? = nil) {
        for url in files where FileManager.default.fileExists(atPath: url.path) { do { try FileManager.default.removeItem(at: url) } catch { Task { @MainActor in CarryLogger.shared.log(.persistFailed, context: "backup_stage_cleanup") } } }
        if let directory, FileManager.default.fileExists(atPath: directory.path) { do { try FileManager.default.removeItem(at: directory) } catch { Task { @MainActor in CarryLogger.shared.log(.persistFailed, context: "backup_stage_directory_cleanup") } } }
    }
    private mutating func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw DataBackupManager.BackupError.decodingFailed
        }
    }

    private mutating func stage(_ name: String, background: Bool) throws -> String {
        try validate(name)
        try Task.checkCancellation()
        let incoming = background ? backup.backgroundImages?[name] : backup.attachmentFiles?[name]
        // Older automatic backups omit external bytes and refer to the existing
        // local files. Validate these names too; never reinterpret them as paths.
        guard let incoming else {
            let url = try existingURL(name, background: background)
            guard allowLocalFileReferences, FileManager.default.fileExists(atPath: url.path) else {
                throw DataBackupManager.BackupError.missingAsset
            }
            return name
        }
        guard incoming.count <= (background ? CarryAccountAssetCache.maximumBytes : AttachmentStore.maxBytes) else { throw DataBackupManager.BackupError.decodingFailed }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 32 ? "dat" : ext
        let allocated = UUID().uuidString + "." + suffix
        let url = inputs.stageRoot.appendingPathComponent(allocated)
        try incoming.write(to: url, options: .atomic)
        files.append(CarryBackupStagedFile(staged: url, destination: (background ? inputs.backgroundRoot : inputs.attachmentRoot).appendingPathComponent(allocated)))
        return allocated
    }

    private mutating func rewrite(_ values: [BackupAttachment]?) throws -> [BackupAttachment]? {
        try values?.map { value in
            var copy = value
            if !copy.fileName.isEmpty { copy.fileName = try stage(copy.fileName, background: false) }
            return copy
        }
    }

    private mutating func photo(_ value: BackupStopPhoto) throws -> BackupStopPhoto {
        try Task.checkCancellation()
        var copy = value
        let key = value.id.uuidString.lowercased()
        if let data = backup.photoOriginals?[key] {
            guard !data.isEmpty, data.count <= CarryAccountAssetCache.maximumBytes else { throw DataBackupManager.BackupError.decodingFailed }
            let manifests = (backup.assetManifest ?? []).filter { $0.entityID == value.id && $0.slot == "original" }
            guard manifests.count <= 1 else { throw DataBackupManager.BackupError.decodingFailed }
            if let manifest = manifests.first {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard manifest.byteCount == data.count, manifest.sha256 == hash else { throw DataBackupManager.BackupError.missingAsset }
            }
            let name = "carryphoto1_" + UUID().uuidString.lowercased() + ".blob"
            let url = inputs.stageRoot.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            files.append(CarryBackupStagedFile(staged: url, destination: inputs.attachmentRoot.appendingPathComponent(name))); copy.assetLocalIdentifier = name
        } else if value.assetLocalIdentifier.hasPrefix("carryphoto1_") || CarryAccountFileAccess.isAccountReference(value.assetLocalIdentifier) {
            try validate(value.assetLocalIdentifier)
            let url = try existingURL(value.assetLocalIdentifier, background: false)
            guard allowLocalFileReferences,
                  FileManager.default.fileExists(atPath: url.path) else {
                throw DataBackupManager.BackupError.missingAsset
            }
        }
        return copy
    }

    private mutating func prepare() throws {
        try FileManager.default.createDirectory(at: inputs.stageRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: inputs.backgroundRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs.attachmentRoot, withIntermediateDirectories: true)
        for index in backup.trips.indices {
            var trip = backup.trips[index]
            if let data = trip.backgroundsData, !data.isEmpty {
                var entries: [TripBackgroundEntry]
                do { entries = try JSONDecoder().decode([TripBackgroundEntry].self, from: data) }
                catch { throw DataBackupManager.BackupError.decodingFailed }
                for position in entries.indices {
                    if let name = entries[position].localFileName {
                        entries[position].localFileName = try stage(name, background: true)
                    }
                }
                trip.backgroundsData = try JSONEncoder().encode(entries)
            }
            trip.itineraryDays = try trip.itineraryDays?.map { value in
                var day = value
                day.stops = try day.stops.map { value in
                    var stop = value
                    stop.attachments = try rewrite(stop.attachments)
                    stop.photos = try stop.photos?.map { try photo($0) }
                    return stop
                }
                day.segments = try day.segments?.map { value in
                    var segment = value; segment.attachments = try rewrite(segment.attachments); return segment
                }
                return day
            }
            trip.lodgingStays = try trip.lodgingStays?.map { value in
                var stay = value; stay.attachments = try rewrite(stay.attachments); return stay
            }
            backup.trips[index] = trip
        }
    }

}
