import Foundation

/// Incoming backup bytes never overwrite files referenced by the current store.
/// The prepared value points at private, newly allocated names; only its final
/// database save publishes them. Discard removes only this stage's own files.
@MainActor
final class CarryBackupFileStage {
    private(set) var backup: CarryBackup
    private var backgrounds: [String] = []
    private var attachments: [String] = []
    private var committed = false
    private let allowLocalFileReferences: Bool

    init(_ source: CarryBackup, allowLocalFileReferences: Bool = false) throws {
        backup = source
        self.allowLocalFileReferences = allowLocalFileReferences
        do { try prepare() }
        catch { discard(); throw error }
    }

    func commit() { committed = true }

    func discard() {
        guard !committed else { return }
        for name in backgrounds { BackgroundImageStore.delete(named: name) }
        for name in attachments { AttachmentStore.delete(named: name) }
        backgrounds = []; attachments = []
    }

    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw DataBackupManager.BackupError.decodingFailed
        }
    }

    private func stage(_ name: String, background: Bool) throws -> String {
        try validate(name)
        let incoming = background ? backup.backgroundImages?[name] : backup.attachmentFiles?[name]
        // Older automatic backups omit external bytes and refer to the existing
        // local files. Validate these names too; never reinterpret them as paths.
        guard let incoming else {
            let url = background ? BackgroundImageStore.fileURL(named: name) : AttachmentStore.fileURL(named: name)
            guard allowLocalFileReferences, FileManager.default.fileExists(atPath: url.path) else {
                throw DataBackupManager.BackupError.missingAsset
            }
            return name
        }
        guard incoming.count <= AttachmentStore.maxBytes else { throw DataBackupManager.BackupError.decodingFailed }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 32 ? "dat" : ext
        let allocated = UUID().uuidString + "." + suffix
        let written = background ? BackgroundImageStore.write(data: incoming, named: allocated)
                                 : AttachmentStore.write(data: incoming, named: allocated)
        guard written else { throw CocoaError(.fileWriteUnknown) }
        if background { backgrounds.append(allocated) } else { attachments.append(allocated) }
        return allocated
    }

    private func rewrite(_ values: [BackupAttachment]?) throws -> [BackupAttachment]? {
        try values?.map { value in
            var copy = value
            if !copy.fileName.isEmpty { copy.fileName = try stage(copy.fileName, background: false) }
            return copy
        }
    }

    private func prepare() throws {
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
                    var stop = value; stop.attachments = try rewrite(stop.attachments); return stop
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

    /// A shared itinerary cannot smuggle references to recipient-local private
    /// attachments. Full backup restore/merge is a separate explicit operation.
    static func itineraryOnly(_ source: BackupTrip) -> BackupTrip {
        var trip = source
        trip.backgroundsData = nil
        trip.itineraryDays = trip.itineraryDays?.map { value in
            var day = value
            day.stops = day.stops.map { value in var stop = value; stop.attachments = nil; return stop }
            day.segments = day.segments?.map { value in var segment = value; segment.attachments = nil; return segment }
            return day
        }
        trip.lodgingStays = trip.lodgingStays?.map { value in var stay = value; stay.attachments = nil; return stay }
        return trip
    }
}
