//
//  DataBackupManager.swift
//  Carry
//

import Foundation
import SwiftData

// MARK: - Codable Mirror Types

struct BackupPackingItem: Codable, Sendable {
    var id: UUID
    var name: String
    var quantity: Int
    var isPacked: Bool
    var isAlert: Bool
    var sortOrder: Int
}

struct BackupPackingSection: Codable, Sendable {
    var id: UUID
    var title: String
    var sortOrder: Int
    var items: [BackupPackingItem]
}

/// 照片回溯生成的停靠点照片（spec: photo-trip-reconstruction.md）。
/// 缩略图字节随备份走（CLAUDE.md 备份约定：沙盒外/不在关系图直存的字节必须显式带上）；
/// assetLocalIdentifier 也带上，换机后原图可能取不到、UI 退化为「仅缩略图」，可接受。
struct BackupStopPhoto: Codable, Sendable {
    var id: UUID
    var assetLocalIdentifier: String
    var thumbnailData: Data
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var sortOrder: Int
}

/// 附件镜像（spec: itinerary-attachments.md）。缩略图字节随记录走（小）；原文件字节存
/// CarryBackup.attachmentFiles（按 fileName 索引，仅 export 内嵌）。分享/导出渲染器不读附件 → 天然不外泄。
struct BackupAttachment: Codable, Sendable {
    var id: UUID
    var kindRaw: String
    var displayName: String
    var fileName: String
    var utiOrExt: String
    var urlString: String
    var thumbnailData: Data
    var sortOrder: Int
    var addedAt: Date
}

struct BackupItineraryStop: Codable, Sendable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var address: String
    var categoryRaw: String
    var plannedStartMinutes: Int
    var stayMinutes: Int
    var note: String
    var sortOrder: Int
    // 费用记录（spec: itinerary-cost-tracking.md）；可选以兼容旧备份（无键 → nil → 还原为「未记录」）。
    var costAmount: Double?
    var costCurrencyCode: String?
    var costHomeAmount: Double?
    // 照片回溯（spec: photo-trip-reconstruction.md）；可选 + 默认 nil：兼容旧备份，且分享/导出路径不带照片。
    var fromPhotos: Bool? = nil
    var photos: [BackupStopPhoto]? = nil
    // 联系电话（地点）；可选 + 默认 nil：兼容旧备份。
    var phone: String? = nil
    // 时区（spec: itinerary-timezone.md）；可选 + 默认 nil：兼容旧备份。
    var timeZoneId: String? = nil
    // 附件（spec: itinerary-attachments.md）；可选 + 默认 nil：兼容旧备份。
    var attachments: [BackupAttachment]? = nil
}

struct BackupTransportSegment: Codable, Sendable {
    var id: UUID
    var modeRaw: String
    var carrier: String
    var number: String
    var fromName: String
    var fromCode: String
    var fromLatitude: Double
    var fromLongitude: Double
    var fromTimeZoneId: String
    var fromTerminal: String
    var toName: String
    var toCode: String
    var toLatitude: Double
    var toLongitude: Double
    var toTimeZoneId: String
    var toTerminal: String
    var departDayOrder: Int
    var departLocalMinutes: Int
    var arriveDayOrder: Int
    var arriveLocalMinutes: Int
    var seat: String
    var confirmationCode: String
    var note: String
    var sortOrder: Int
    var costAmount: Double?
    var costCurrencyCode: String?
    var costHomeAmount: Double?
    // 机型 + 航程(米) + 时长(分)（spec: itinerary-flight-lookup.md）；可选 + 默认 nil：兼容旧备份。
    var aircraftType: String? = nil
    var cabinClass: String? = nil      // 舱位等级（可选 + 默认 nil：兼容旧备份）
    var distanceMeters: Double? = nil
    var durationMinutes: Int? = nil
    // 租车专属：车型 + 车牌（spec: itinerary-car-rental.md）；可选 + 默认 nil：兼容旧备份。
    var vehicleModel: String? = nil
    var licensePlate: String? = nil
    // 端点详细地址（地点搜索回填）；可选 + 默认 nil：兼容旧备份。
    var fromAddress: String? = nil
    var toAddress: String? = nil
    // 联系电话（租车点）；可选 + 默认 nil：兼容旧备份。
    var phone: String? = nil
    // 通知静音（spec: notification-center.md）；可选 + 默认 nil：兼容旧备份。
    var remindersMuted: Bool? = nil
    // 附件（spec: itinerary-attachments.md）；可选 + 默认 nil：兼容旧备份。
    var attachments: [BackupAttachment]? = nil
}

struct BackupLodgingStay: Codable, Sendable {
    var id: UUID
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var checkInDayOrder: Int
    var nights: Int
    var checkInMinutes: Int
    var checkOutMinutes: Int
    var confirmationCode: String
    var note: String
    var sortOrder: Int
    var costAmount: Double?
    var costCurrencyCode: String?
    var costHomeAmount: Double?
    // 联系电话（酒店）；可选 + 默认 nil：兼容旧备份。
    var phone: String? = nil
    // 时区（spec: itinerary-timezone.md）；可选 + 默认 nil：兼容旧备份。
    var timeZoneId: String? = nil
    // 通知静音（spec: notification-center.md）；可选 + 默认 nil：兼容旧备份。
    var remindersMuted: Bool? = nil
    // 附件（spec: itinerary-attachments.md）；可选 + 默认 nil：兼容旧备份。
    var attachments: [BackupAttachment]? = nil
}

struct BackupItineraryDay: Codable, Sendable {
    var id: UUID
    var sortOrder: Int
    var title: String
    var note: String
    var stops: [BackupItineraryStop]
    /// 交通段（spec: itinerary-transport-lodging.md）。可选以兼容旧备份（无此键 → 还原后该天无交通）。
    var segments: [BackupTransportSegment]?
}

struct BackupTrip: Codable, Sendable {
    var id: UUID
    var name: String
    var destinationCity: String
    var days: Int
    var dateRange: String
    var departureDate: Date
    /// 可选以兼容旧备份（无此键时解码不报错，还原时按 false 处理）。
    var isDateless: Bool?
    var createdAt: Date
    var selectedSceneKeys: [String]
    var dismissedSurpriseNames: [String]

    var sceneCardDismissed: Bool
    var remindersEnabled: Bool
    var reminderConfigData: Data
    var countryCode: String
    var latitude: Double
    var longitude: Double
    /// 多目的地行程的次目的地（2nd city onward）JSON。可选以兼容旧备份。
    var additionalDestinationsData: Data?
    /// 用户背景图条目（含裁剪框 crop）的 JSON。可选以兼容旧备份。
    /// 对应的图片字节存在 CarryBackup.backgroundImages（按文件名索引）。
    var backgroundsData: Data?
    var sections: [BackupPackingSection]
    /// 行程路线规划（spec: itinerary-route-planning.md）。可选以兼容旧备份
    /// （无此键时解码不报错，还原后该行程无规划数据）。
    var itineraryDays: [BackupItineraryDay]?
    /// 住宿跨度（spec: itinerary-transport-lodging.md）。可选以兼容旧备份。
    var lodgingStays: [BackupLodgingStay]?
}

struct BackupMyItem: Codable, Sendable {
    var id: UUID
    var name: String
    var collectionName: String
    var category: String
    var defaultQuantity: Int
    var quantityModeRaw: String
    var quantityIntervalDays: Int
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

struct CarryBackup: Codable, Sendable {
    var version: Int
    var createdAt: Date
    var trips: [BackupTrip]
    var myItems: [BackupMyItem]
    /// 用户的默认提醒档位偏好（设置 →「通知」）。可选：旧备份无此字段时还原后保持现状。
    var defaultReminderOffsets: [Int]?
    /// 用户上传的背景图字节，按 sandbox 文件名索引（JSON 中以 base64 编码）。
    /// 可选：旧备份无此字段；还原时写回沙盒，配合各 trip 的 backgroundsData 复原封面。
    var backgroundImages: [String: Data]?
    /// 行程附件原文件字节，按 sandbox 文件名索引（仅 export 内嵌）。还原时写回沙盒。
    /// 可选：旧备份无此字段。spec: itinerary-attachments.md。
    var attachmentFiles: [String: Data]?
}

// MARK: - DataBackupManager

final class DataBackupManager {
    static let shared = DataBackupManager()
    private init() {}

    private let fileName = "carry_backup.json"

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var backupURL: URL? {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let backupDir = dir.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        return backupDir.appendingPathComponent(fileName)
    }

    // MARK: - Write

    /// Builds the value-type snapshot of all data. MUST run where SwiftData models are safe to
    /// read (the main actor). `embedImages`: when true, reads each referenced background image's
    /// bytes off disk and embeds them — for the portable EXPORT file. The per-save auto-backup
    /// passes false: the bytes already persist as sandbox files, so re-reading + base64-encoding
    /// them on every save (e.g. ticking a packing item) would be pure waste.
    /// 把一天的交通段映射为备份镜像（spec: itinerary-transport-lodging.md）。整份备份与单行程导出共用。
    private func backupSegments(_ day: ItineraryDay) -> [BackupTransportSegment] {
        day.sortedSegments.map { s in
            BackupTransportSegment(
                id: s.id, modeRaw: s.modeRaw, carrier: s.carrier, number: s.number,
                fromName: s.fromName, fromCode: s.fromCode,
                fromLatitude: s.fromLatitude, fromLongitude: s.fromLongitude,
                fromTimeZoneId: s.fromTimeZoneId, fromTerminal: s.fromTerminal,
                toName: s.toName, toCode: s.toCode,
                toLatitude: s.toLatitude, toLongitude: s.toLongitude,
                toTimeZoneId: s.toTimeZoneId, toTerminal: s.toTerminal,
                departDayOrder: s.departDayOrder, departLocalMinutes: s.departLocalMinutes,
                arriveDayOrder: s.arriveDayOrder, arriveLocalMinutes: s.arriveLocalMinutes,
                seat: s.seat, confirmationCode: s.confirmationCode, note: s.note, sortOrder: s.sortOrder,
                costAmount: s.costAmount, costCurrencyCode: s.costCurrencyCode, costHomeAmount: s.costHomeAmount,
                aircraftType: s.aircraftType, cabinClass: s.cabinClass, distanceMeters: s.distanceMeters, durationMinutes: s.durationMinutes,
                vehicleModel: s.vehicleModel, licensePlate: s.licensePlate,
                fromAddress: s.fromAddress, toAddress: s.toAddress,
                phone: s.phone,
                remindersMuted: s.remindersMuted,
                attachments: backupAttachments(s.attachments)
            )
        }
    }

    /// 附件 → 备份镜像（缩略图随记录；原文件字节走 attachmentFiles 顶层字典）。
    private func backupAttachments(_ atts: [ItineraryAttachment]?) -> [BackupAttachment]? {
        let sorted = (atts ?? []).sorted { $0.sortOrder < $1.sortOrder }
        guard !sorted.isEmpty else { return nil }
        return sorted.map { a in
            BackupAttachment(
                id: a.id, kindRaw: a.kindRaw, displayName: a.displayName,
                fileName: a.fileName, utiOrExt: a.utiOrExt, urlString: a.urlString,
                thumbnailData: a.thumbnailData, sortOrder: a.sortOrder, addedAt: a.addedAt
            )
        }
    }

    /// 把一个行程的住宿跨度映射为备份镜像。
    private func backupLodging(_ trip: TripBundle) -> [BackupLodgingStay] {
        trip.safeLodgingStays.map { l in
            BackupLodgingStay(
                id: l.id, name: l.name, address: l.address,
                latitude: l.latitude, longitude: l.longitude,
                checkInDayOrder: l.checkInDayOrder, nights: l.nights,
                checkInMinutes: l.checkInMinutes, checkOutMinutes: l.checkOutMinutes,
                confirmationCode: l.confirmationCode, note: l.note, sortOrder: l.sortOrder,
                costAmount: l.costAmount, costCurrencyCode: l.costCurrencyCode, costHomeAmount: l.costHomeAmount,
                phone: l.phone,
                timeZoneId: l.timeZoneId,
                remindersMuted: l.remindersMuted,
                attachments: backupAttachments(l.attachments)
            )
        }
    }

    private func makeBackup(trips: [TripBundle], myItems: [MyItem], embedImages: Bool) -> CarryBackup {
        let backupTrips: [BackupTrip] = trips.map { trip in
            let sections: [BackupPackingSection] = (trip.sections ?? []).map { section in
                let items: [BackupPackingItem] = (section.items ?? []).map {
                    BackupPackingItem(
                        id: $0.id,
                        name: $0.name,
                        quantity: $0.quantity,
                        isPacked: $0.isPacked,
                        isAlert: $0.isAlert,
                        sortOrder: $0.sortOrder
                    )
                }
                return BackupPackingSection(
                    id: section.id,
                    title: section.title,
                    sortOrder: section.sortOrder,
                    items: items
                )
            }
            let itineraryDays: [BackupItineraryDay] = trip.safeItineraryDays.map { day in
                let stops: [BackupItineraryStop] = day.sortedStops.map {
                    let photos = $0.sortedPhotos.map { p in
                        BackupStopPhoto(
                            id: p.id,
                            assetLocalIdentifier: p.assetLocalIdentifier,
                            thumbnailData: p.thumbnailData,
                            timestamp: p.timestamp,
                            latitude: p.latitude,
                            longitude: p.longitude,
                            sortOrder: p.sortOrder
                        )
                    }
                    return BackupItineraryStop(
                        id: $0.id,
                        name: $0.name,
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        address: $0.address,
                        categoryRaw: $0.categoryRaw,
                        plannedStartMinutes: $0.plannedStartMinutes,
                        stayMinutes: $0.stayMinutes,
                        note: $0.note,
                        sortOrder: $0.sortOrder,
                        costAmount: $0.costAmount,
                        costCurrencyCode: $0.costCurrencyCode,
                        costHomeAmount: $0.costHomeAmount,
                        fromPhotos: $0.fromPhotos,
                        photos: photos.isEmpty ? nil : photos,
                        phone: $0.phone,
                        timeZoneId: $0.timeZoneId,
                        attachments: backupAttachments($0.attachments)
                    )
                }
                let segments = backupSegments(day)
                return BackupItineraryDay(
                    id: day.id,
                    sortOrder: day.sortOrder,
                    title: day.title,
                    note: day.note,
                    stops: stops,
                    segments: segments.isEmpty ? nil : segments
                )
            }
            let lodgingStays = backupLodging(trip)
            return BackupTrip(
                id: trip.id,
                name: trip.name,
                destinationCity: trip.destinationCity,
                days: trip.days,
                dateRange: trip.dateRange,
                departureDate: trip.departureDate,
                isDateless: trip.isDateless,
                createdAt: trip.createdAt,
                selectedSceneKeys: trip.selectedSceneKeys,
                dismissedSurpriseNames: trip.dismissedSurpriseNames,

                sceneCardDismissed: trip.sceneCardDismissed,
                remindersEnabled: trip.remindersEnabled,
                reminderConfigData: trip.reminderConfigData,
                countryCode: trip.countryCode,
                latitude: trip.latitude,
                longitude: trip.longitude,
                additionalDestinationsData: trip.additionalDestinationsData.isEmpty ? nil : trip.additionalDestinationsData,
                backgroundsData: trip.backgroundsData.isEmpty ? nil : trip.backgroundsData,
                sections: sections,
                itineraryDays: itineraryDays.isEmpty ? nil : itineraryDays,
                lodgingStays: lodgingStays.isEmpty ? nil : lodgingStays
            )
        }

        let backupMyItems: [BackupMyItem] = myItems.map {
            BackupMyItem(
                id: $0.id,
                name: $0.name,
                collectionName: $0.collectionName,
                category: $0.category,
                defaultQuantity: $0.defaultQuantity,
                quantityModeRaw: $0.quantityModeRaw,
                quantityIntervalDays: $0.quantityIntervalDays,
                sortOrder: $0.sortOrder,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }

        var backgroundImages: [String: Data]? = nil
        var attachmentFiles: [String: Data]? = nil
        if embedImages {
            var dict: [String: Data] = [:]
            for name in Set(trips.flatMap { $0.backgrounds.compactMap(\.localFileName) }) {
                if let bytes = BackgroundImageStore.data(named: name) { dict[name] = bytes }
            }
            backgroundImages = dict.isEmpty ? nil : dict

            // 附件原文件字节（仅 export 内嵌；auto-backup 不带，沙盒文件仍在）。
            var attDict: [String: Data] = [:]
            let attNames = trips.flatMap { trip -> [String] in
                var names: [String] = []
                for day in trip.safeItineraryDays {
                    for stop in day.sortedStops { names += (stop.attachments ?? []).map(\.fileName) }
                    for seg in day.sortedSegments { names += (seg.attachments ?? []).map(\.fileName) }
                }
                for stay in trip.safeLodgingStays { names += (stay.attachments ?? []).map(\.fileName) }
                return names
            }
            for name in Set(attNames) where !name.isEmpty {
                if let bytes = AttachmentStore.data(named: name) { attDict[name] = bytes }
            }
            attachmentFiles = attDict.isEmpty ? nil : attDict
        }

        return CarryBackup(
            version: Self.currentBackupVersion,
            createdAt: Date(),
            trips: backupTrips,
            myItems: backupMyItems,
            defaultReminderOffsets: ReminderPreferences.enabledOffsets.sorted(),
            backgroundImages: backgroundImages,
            attachmentFiles: attachmentFiles
        )
    }

    /// Auto-backup after every save. Hot path → stays cheap: builds a TEXT-ONLY snapshot (no
    /// embedded image bytes — the images live on as sandbox files and are reconciled separately),
    /// then encodes + writes it off the main thread. The portable, self-contained file with image
    /// bytes is produced on demand by `makeExportFile` only when the user actually exports.
    func backup(trips: [TripBundle], myItems: [MyItem]) {
        guard let url = backupURL else { return }
        // Text-only snapshot → encoding is sub-millisecond, so it stays on the main actor; only
        // the disk write (IO) is offloaded. (Image bytes are no longer embedded here, which is
        // exactly what used to make per-save encoding expensive.)
        let snapshot = makeBackup(trips: trips, myItems: myItems, embedImages: false)
        guard let data = Self.encode(snapshot) else {
            CarryLogger.shared.log(.backupWriteFailed, context: "reason=encode_failed")
            return
        }
        Task.detached(priority: .utility) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let errorDesc = error.localizedDescription
                await MainActor.run {
                    CarryLogger.shared.log(.backupWriteFailed,
                        context: "reason=write_failed error=\(errorDesc)")
                }
            }
        }
    }

    /// Builds a self-contained export file (WITH embedded image bytes) to a temp URL for sharing.
    /// User-initiated and infrequent, so the one-time image read + encode runs inline. Returns the
    /// temp file URL, or nil on failure.
    func makeExportFile(trips: [TripBundle], myItems: [MyItem]) -> URL? {
        let snapshot = makeBackup(trips: trips, myItems: myItems, embedImages: true)
        guard let data = Self.encode(snapshot) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("carry_backup_\(fmt.string(from: Date())).json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func encode(_ backup: CarryBackup) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return try? e.encode(backup)
    }

    // MARK: - Query

    /// The file URL of the backup, usable for sharing via UIActivityViewController.
    var backupFileURL: URL? { backupURL }

    func hasBackup() -> Bool {
        guard let url = backupURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func latestBackupDate() -> Date? {
        guard let url = backupURL,
              let data = try? Data(contentsOf: url),
              let backup = try? decoder.decode(CarryBackup.self, from: data) else { return nil }
        return backup.createdAt
    }

    func latestBackupTripCount() -> Int? {
        guard let url = backupURL,
              let data = try? Data(contentsOf: url),
              let backup = try? decoder.decode(CarryBackup.self, from: data) else { return nil }
        return backup.trips.count
    }

    // MARK: - Restore

    /// 当前 App 能读取的最高备份版本。备份格式升级时同步递增。
    /// 用来防止"用新版备份在旧版 App 还原"——若 backup.version > currentBackupVersion
    /// 则提示用户先更新 App，而不是崩溃或静默还原出错误数据。
    ///
    /// 产品尚未发布、不存在在野旧备份，因此发布前所有字段新增都归入 v1（launch 基线），
    /// 不递增版本号。版本号的唯一作用是发布后拦截"用更新格式的备份在旧 App 还原";
    /// 发布后再因破坏性格式变更才升到 v2、v3…。当前 v1 字段即 BackupTrip/CarryBackup
    /// 的全部字段（含可选的 additionalDestinations / 通知偏好 / 背景图条目+裁剪 / 图片字节）。
    static let currentBackupVersion = 1

    enum BackupError: LocalizedError {
        case fileNotFound
        case decodingFailed
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return NSLocalizedString("settings.data.restore.error.not_found", comment: "")
            case .decodingFailed:
                return NSLocalizedString("settings.data.restore.error.corrupt", comment: "")
            case .unsupportedVersion(let v):
                return String(format: NSLocalizedString("settings.data.restore.error.version", comment: ""), v)
            }
        }
    }

    // MARK: - Restore (device backup)

    /// Restore from the automatic local backup written after every save.
    @discardableResult
    func restore(into context: ModelContext) throws -> (trips: Int, myItems: Int) {
        guard let url = backupURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.fileNotFound
        }
        let data = try Data(contentsOf: url)
        return try restoreFromData(data, into: context)
    }

    // MARK: - Restore (imported file)

    /// Restore from raw JSON data — used when the caller has already read the
    /// file within a security scope (e.g., from the file importer picker).
    @discardableResult
    func restoreFromData(_ data: Data, into context: ModelContext) throws -> (trips: Int, myItems: Int) {
        // 关键顺序：必须先用最小 stub 只读 version，再做完整 decode。
        // 否则新版备份含旧版未识别的非可选字段时，完整 decode 会先抛 decodingFailed
        //（"文件损坏"），用户永远看不到 unsupportedVersion 的"请更新 App"提示。
        struct VersionStub: Decodable { let version: Int }
        if let stub = try? decoder.decode(VersionStub.self, from: data),
           stub.version > Self.currentBackupVersion {
            throw BackupError.unsupportedVersion(stub.version)
        }
        guard let backup = try? decoder.decode(CarryBackup.self, from: data) else {
            throw BackupError.decodingFailed
        }
        return try performRestore(from: backup, into: context)
    }

    // MARK: - Merge (imported file)

    /// 合并导入：将备份中在本地不存在的行程 / 物品模板插入数据库，
    /// 已存在的（UUID 匹配）跳过，不覆盖本地版本。
    @discardableResult
    func mergeFromData(_ data: Data, into context: ModelContext) throws -> (trips: Int, myItems: Int) {
        struct VersionStub: Decodable { let version: Int }
        if let stub = try? decoder.decode(VersionStub.self, from: data),
           stub.version > Self.currentBackupVersion {
            throw BackupError.unsupportedVersion(stub.version)
        }
        guard let backup = try? decoder.decode(CarryBackup.self, from: data) else {
            throw BackupError.decodingFailed
        }
        return try performMerge(from: backup, into: context)
    }

    /// Rewrite the backed-up background image bytes to the sandbox (filenames are UUIDs, so
    /// overwriting is safe/idempotent). Trip `backgroundsData` then references them.
    private func restoreBackgroundImages(from backup: CarryBackup) {
        for (name, data) in backup.backgroundImages ?? [:] {
            BackgroundImageStore.write(data: data, named: name)
        }
    }

    /// 写回附件原文件字节（仅 export 备份带；auto-backup 无 attachmentFiles，沙盒文件仍在）。
    private func restoreAttachmentFiles(from backup: CarryBackup) {
        for (name, data) in backup.attachmentFiles ?? [:] {
            AttachmentStore.write(data: data, named: name)
        }
    }

    /// 重建附件 model（owner 关系由调用方按实体设置）。
    private func makeAttachments(_ atts: [BackupAttachment]?, into context: ModelContext) -> [ItineraryAttachment] {
        (atts ?? []).sorted { $0.sortOrder < $1.sortOrder }.map { ba in
            let a = ItineraryAttachment(
                kind: AttachmentKind(rawValue: ba.kindRaw) ?? .file,
                displayName: ba.displayName, fileName: ba.fileName, utiOrExt: ba.utiOrExt,
                urlString: ba.urlString, thumbnailData: ba.thumbnailData,
                sortOrder: ba.sortOrder, addedAt: ba.addedAt)
            a.id = ba.id
            context.insert(a)
            return a
        }
    }

    /// 重建行程规划的天/停靠点并挂到 trip（restore 与 merge 共用）。
    /// 旧备份无 itineraryDays（nil）→ 不建任何规划数据；id 沿用备份值保真。
    private func restoreItineraryDays(_ days: [BackupItineraryDay]?, for trip: TripBundle, into context: ModelContext) {
        guard let days else { return }
        for bd in days.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let day = ItineraryDay(sortOrder: bd.sortOrder, title: bd.title, note: bd.note)
            day.id = bd.id
            day.bundle = trip
            context.insert(day)
            for bs in bd.stops.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let stop = ItineraryStop(
                    name: bs.name,
                    latitude: bs.latitude,
                    longitude: bs.longitude,
                    address: bs.address,
                    category: StopCategory(rawValueOrOther: bs.categoryRaw),
                    plannedStartMinutes: bs.plannedStartMinutes,
                    stayMinutes: bs.stayMinutes,
                    note: bs.note,
                    sortOrder: bs.sortOrder,
                    costAmount: bs.costAmount ?? 0,
                    costCurrencyCode: bs.costCurrencyCode ?? "",
                    costHomeAmount: bs.costHomeAmount ?? -1,
                    fromPhotos: bs.fromPhotos ?? false
                )
                stop.phone = bs.phone ?? ""
                stop.timeZoneId = TimeZoneCanonicalizer.canonical(bs.timeZoneId ?? "")   // 大陆境内别名归北京时间
                stop.id = bs.id
                stop.day = day
                context.insert(stop)
                // 照片回溯（spec: photo-trip-reconstruction.md）；旧备份无 photos（nil）→ 不建。
                for bp in (bs.photos ?? []).sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    let photo = StopPhoto(
                        assetLocalIdentifier: bp.assetLocalIdentifier,
                        thumbnailData: bp.thumbnailData,
                        timestamp: bp.timestamp,
                        latitude: bp.latitude,
                        longitude: bp.longitude,
                        sortOrder: bp.sortOrder
                    )
                    photo.id = bp.id
                    photo.stop = stop
                    context.insert(photo)
                }
                for a in makeAttachments(bs.attachments, into: context) { a.stop = stop }
            }
            // 交通段（spec: itinerary-transport-lodging.md）；旧备份无 segments（nil）→ 不建。
            for bg in (bd.segments ?? []).sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let seg = TransportSegment(
                    mode: TransportMode(rawValueOrOther: bg.modeRaw),
                    carrier: bg.carrier, number: bg.number,
                    fromName: bg.fromName, fromCode: bg.fromCode,
                    fromLatitude: bg.fromLatitude, fromLongitude: bg.fromLongitude,
                    fromTimeZoneId: TimeZoneCanonicalizer.canonical(bg.fromTimeZoneId), fromTerminal: bg.fromTerminal,
                    fromAddress: bg.fromAddress ?? "",
                    toName: bg.toName, toCode: bg.toCode,
                    toLatitude: bg.toLatitude, toLongitude: bg.toLongitude,
                    toTimeZoneId: TimeZoneCanonicalizer.canonical(bg.toTimeZoneId), toTerminal: bg.toTerminal,
                    toAddress: bg.toAddress ?? "",
                    departDayOrder: bg.departDayOrder, departLocalMinutes: bg.departLocalMinutes,
                    arriveDayOrder: bg.arriveDayOrder, arriveLocalMinutes: bg.arriveLocalMinutes,
                    seat: bg.seat, confirmationCode: bg.confirmationCode,
                    note: bg.note, aircraftType: bg.aircraftType ?? "", cabinClass: bg.cabinClass ?? "",
                    distanceMeters: bg.distanceMeters ?? 0, durationMinutes: bg.durationMinutes ?? 0,
                    vehicleModel: bg.vehicleModel ?? "", licensePlate: bg.licensePlate ?? "",
                    phone: bg.phone ?? "",
                    sortOrder: bg.sortOrder,
                    costAmount: bg.costAmount ?? 0,
                    costCurrencyCode: bg.costCurrencyCode ?? "",
                    costHomeAmount: bg.costHomeAmount ?? -1
                )
                seg.id = bg.id
                seg.remindersMuted = bg.remindersMuted ?? false
                seg.day = day
                context.insert(seg)
                for a in makeAttachments(bg.attachments, into: context) { a.segment = seg }
            }
        }
    }

    /// 还原住宿跨度（spec: itinerary-transport-lodging.md）。旧备份无 lodgingStays（nil）→ 不建；id 沿用保真。
    private func restoreLodgingStays(_ stays: [BackupLodgingStay]?, for trip: TripBundle, into context: ModelContext) {
        guard let stays else { return }
        for bl in stays.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let stay = LodgingStay(
                name: bl.name, address: bl.address,
                latitude: bl.latitude, longitude: bl.longitude,
                checkInDayOrder: bl.checkInDayOrder, nights: bl.nights,
                checkInMinutes: bl.checkInMinutes, checkOutMinutes: bl.checkOutMinutes,
                confirmationCode: bl.confirmationCode, note: bl.note,
                phone: bl.phone ?? "",
                sortOrder: bl.sortOrder,
                costAmount: bl.costAmount ?? 0,
                costCurrencyCode: bl.costCurrencyCode ?? "",
                costHomeAmount: bl.costHomeAmount ?? -1
            )
            stay.id = bl.id
            stay.remindersMuted = bl.remindersMuted ?? false
            stay.timeZoneId = TimeZoneCanonicalizer.canonical(bl.timeZoneId ?? "")   // 大陆境内别名归北京时间
            stay.bundle = trip
            context.insert(stay)
            for a in makeAttachments(bl.attachments, into: context) { a.stay = stay }
        }
    }

    private func performMerge(from backup: CarryBackup, into context: ModelContext) throws -> (trips: Int, myItems: Int) {
        restoreBackgroundImages(from: backup)
        restoreAttachmentFiles(from: backup)

        // 取出现有 UUID 集合，用于去重判断
        let existingTripIDs = Set(try context.fetch(FetchDescriptor<TripBundle>()).map(\.id))
        let existingMyItemIDs = Set(try context.fetch(FetchDescriptor<MyItem>()).map(\.id))

        var newTripCount = 0

        for bt in backup.trips where !existingTripIDs.contains(bt.id) {
            let trip = TripBundle(
                id: bt.id,
                name: bt.name,
                destinationCity: bt.destinationCity,
                days: bt.days,
                dateRange: bt.dateRange,
                departureDate: bt.departureDate,
                isDateless: bt.isDateless ?? false,
                createdAt: bt.createdAt,
                selectedSceneKeys: bt.selectedSceneKeys
            )
            trip.dismissedSurpriseNames = bt.dismissedSurpriseNames
            trip.sceneCardDismissed = bt.sceneCardDismissed
            trip.remindersEnabled = bt.remindersEnabled
            trip.reminderConfigData = bt.reminderConfigData
            trip.countryCode = bt.countryCode
            trip.latitude = bt.latitude
            trip.longitude = bt.longitude
            if let extra = bt.additionalDestinationsData {
                trip.additionalDestinationsData = extra
            }
            if let bg = bt.backgroundsData {
                trip.backgroundsData = bg
            }
            context.insert(trip)

            for bs in bt.sections.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let section = PackingSection(title: bs.title, sortOrder: bs.sortOrder)
                section.id = bs.id
                section.bundle = trip
                context.insert(section)

                for bi in bs.items.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    let item = PackingItem(
                        name: bi.name,
                        quantity: bi.quantity,
                        isPacked: bi.isPacked,
                        isAlert: bi.isAlert,
                        sortOrder: bi.sortOrder
                    )
                    item.id = bi.id
                    item.section = section
                    context.insert(item)
                }
            }
            restoreItineraryDays(bt.itineraryDays, for: trip, into: context)
            restoreLodgingStays(bt.lodgingStays, for: trip, into: context)
            newTripCount += 1
        }

        for bm in backup.myItems where !existingMyItemIDs.contains(bm.id) {
            let item = MyItem(
                id: bm.id,
                name: bm.name,
                collectionName: bm.collectionName,
                category: bm.category,
                defaultQuantity: bm.defaultQuantity,
                quantityMode: MyItemQuantityMode(rawValue: bm.quantityModeRaw) ?? .fixed,
                quantityIntervalDays: bm.quantityIntervalDays,
                sortOrder: bm.sortOrder,
                createdAt: bm.createdAt,
                updatedAt: bm.updatedAt
            )
            context.insert(item)
        }

        try context.save()
        return (newTripCount, backup.myItems.filter { !existingMyItemIDs.contains($0.id) }.count)
    }

    // MARK: - 单行程「发送给同行者」（仅行程规划，可导入）

    /// 导入前的行程摘要（解码自 `.carrytrip` 文件，不写库）。供确认弹窗展示。
    struct SharedTripSummary: Identifiable {
        var id: UUID { tripId }
        let data: Data
        let tripId: UUID
        let name: String
        let destinationCity: String
        let isDateless: Bool
        let departureDate: Date
        let totalDays: Int
        let placeCount: Int
    }

    /// 导出单个行程的「行程规划」为可分享文件（`.carrytrip`，本质是仅含一个行程、
    /// 且**不带打包清单 / 背景图 / 个人库**的 CarryBackup）。仅天 + 地点 → 更轻、更私密。
    func makeItineraryShareFile(trip: TripBundle, baseName: String) -> URL? {
        let days: [BackupItineraryDay] = trip.safeItineraryDays.map { day in
            let stops: [BackupItineraryStop] = day.sortedStops.map {
                BackupItineraryStop(
                    id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                    address: $0.address, categoryRaw: $0.categoryRaw,
                    plannedStartMinutes: $0.plannedStartMinutes, stayMinutes: $0.stayMinutes,
                    note: $0.note, sortOrder: $0.sortOrder,
                    costAmount: $0.costAmount, costCurrencyCode: $0.costCurrencyCode, costHomeAmount: $0.costHomeAmount,
                    timeZoneId: $0.timeZoneId
                )
            }
            let segments = backupSegments(day)
            return BackupItineraryDay(id: day.id, sortOrder: day.sortOrder, title: day.title, note: day.note,
                                      stops: stops, segments: segments.isEmpty ? nil : segments)
        }
        let lodgingStays = backupLodging(trip)
        let bt = BackupTrip(
            id: trip.id, name: trip.name, destinationCity: trip.destinationCity,
            days: trip.days, dateRange: trip.dateRange, departureDate: trip.departureDate,
            isDateless: trip.isDateless, createdAt: trip.createdAt,
            selectedSceneKeys: trip.selectedSceneKeys, dismissedSurpriseNames: trip.dismissedSurpriseNames,
            sceneCardDismissed: trip.sceneCardDismissed, remindersEnabled: false,
            reminderConfigData: Data(), countryCode: trip.countryCode,
            latitude: trip.latitude, longitude: trip.longitude,
            additionalDestinationsData: trip.additionalDestinationsData.isEmpty ? nil : trip.additionalDestinationsData,
            backgroundsData: nil,          // 不带背景图（私密 + 文件轻）
            sections: [],                  // 不带打包清单（隐私）
            itineraryDays: days.isEmpty ? nil : days,
            lodgingStays: lodgingStays.isEmpty ? nil : lodgingStays
        )
        let backup = CarryBackup(
            version: Self.currentBackupVersion, createdAt: Date(),
            trips: [bt], myItems: [], defaultReminderOffsets: nil, backgroundImages: nil
        )
        guard let data = Self.encode(backup) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(baseName).appendingPathExtension("carrytrip")
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    /// 读取 `.carrytrip` 文件的单行程摘要（不写库）。版本过新或解析失败返回 nil。
    func readSharedTripSummary(from data: Data) -> SharedTripSummary? {
        struct VersionStub: Decodable { let version: Int }
        if let stub = try? decoder.decode(VersionStub.self, from: data),
           stub.version > Self.currentBackupVersion { return nil }
        guard let backup = try? decoder.decode(CarryBackup.self, from: data),
              let bt = backup.trips.first else { return nil }
        let days = bt.itineraryDays ?? []
        return SharedTripSummary(
            data: data, tripId: bt.id, name: bt.name, destinationCity: bt.destinationCity,
            isDateless: bt.isDateless ?? false, departureDate: bt.departureDate,
            totalDays: max(bt.days, 1),
            placeCount: days.reduce(0) { $0 + $1.stops.count }
        )
    }

    /// 该行程是否已存在本地（用于「新建 vs 更新」判断）。
    func tripExists(id: UUID, in context: ModelContext) -> Bool {
        ((try? context.fetch(FetchDescriptor<TripBundle>())) ?? []).contains { $0.id == id }
    }

    /// 导入共享行程：不存在 → 新建；已存在（同 UUID）→ **替换其行程规划**（天/地点 + 行程元信息），
    /// **不动收件方该行程已有的打包清单 / 背景图**。返回行程 id（供导入后跳转）。
    @discardableResult
    func importSharedTrip(from data: Data, into context: ModelContext) throws -> UUID {
        struct VersionStub: Decodable { let version: Int }
        if let stub = try? decoder.decode(VersionStub.self, from: data),
           stub.version > Self.currentBackupVersion {
            throw BackupError.unsupportedVersion(stub.version)
        }
        guard let backup = try? decoder.decode(CarryBackup.self, from: data),
              let bt = backup.trips.first else {
            throw BackupError.decodingFailed
        }
        let allTrips = try context.fetch(FetchDescriptor<TripBundle>())

        if let existing = allTrips.first(where: { $0.id == bt.id }) {
            // 更新：清掉旧行程规划（天 + 地点 + 交通段 + 住宿），重建为最新；打包清单/背景图保留不动
            for day in existing.safeItineraryDays {
                for stop in day.sortedStops { context.delete(stop) }
                for seg in day.sortedSegments { context.delete(seg) }
                context.delete(day)
            }
            existing.itineraryDays = []
            for stay in existing.safeLodgingStays { context.delete(stay) }
            existing.lodgingStays = []
            existing.name = bt.name
            existing.destinationCity = bt.destinationCity
            existing.days = bt.days
            existing.dateRange = bt.dateRange
            existing.departureDate = bt.departureDate
            existing.isDateless = bt.isDateless ?? false
            existing.countryCode = bt.countryCode
            existing.latitude = bt.latitude
            existing.longitude = bt.longitude
            if let extra = bt.additionalDestinationsData { existing.additionalDestinationsData = extra }
            restoreItineraryDays(bt.itineraryDays, for: existing, into: context)
            restoreLodgingStays(bt.lodgingStays, for: existing, into: context)
        } else {
            // 新建（沿用发送方 UUID，便于日后再次导入识别为「更新」）
            let trip = TripBundle(
                id: bt.id, name: bt.name, destinationCity: bt.destinationCity,
                days: bt.days, dateRange: bt.dateRange, departureDate: bt.departureDate,
                isDateless: bt.isDateless ?? false, createdAt: bt.createdAt,
                selectedSceneKeys: bt.selectedSceneKeys
            )
            trip.dismissedSurpriseNames = bt.dismissedSurpriseNames
            trip.sceneCardDismissed = bt.sceneCardDismissed
            trip.countryCode = bt.countryCode
            trip.latitude = bt.latitude
            trip.longitude = bt.longitude
            if let extra = bt.additionalDestinationsData { trip.additionalDestinationsData = extra }
            context.insert(trip)
            restoreItineraryDays(bt.itineraryDays, for: trip, into: context)
            restoreLodgingStays(bt.lodgingStays, for: trip, into: context)
        }
        try context.save()
        return bt.id
    }

    // MARK: - Core restore

    private func performRestore(from backup: CarryBackup, into context: ModelContext) throws -> (trips: Int, myItems: Int) {
        // 原子化保护：在执行破坏性 delete 前先把当前 backup.json 复制成
        // .pre-restore-{epoch}.json，任一步失败时用户/作者可手动恢复。
        // ⚠️ 用 epoch 时间戳后缀而非固定名 — 用户连续 restore 失败多次时，
        // 每次保留独立安全副本，避免被下一次覆盖丢失原始数据。
        if let backupURL = backupURL,
           FileManager.default.fileExists(atPath: backupURL.path) {
            let epoch = Int(Date().timeIntervalSince1970)
            let safety = backupURL
                .deletingPathExtension()
                .appendingPathExtension("pre-restore-\(epoch).json")
            try? FileManager.default.copyItem(at: backupURL, to: safety)
            CarryLogger.shared.log(.backupSafetyCopyCreated, context: "path=\(safety.lastPathComponent)")
        }

        // Wipe existing data (cascade deletes PackingSection + PackingItem)
        try context.delete(model: TripBundle.self)
        try context.delete(model: MyItem.self)

        // Rewrite background image files to the sandbox before relinking trips.
        restoreBackgroundImages(from: backup)
        restoreAttachmentFiles(from: backup)

        // 还原默认提醒偏好（旧备份无此字段则保持现状）
        if let offsets = backup.defaultReminderOffsets {
            ReminderPreferences.enabledOffsets = Set(offsets)
        }

        // Restore trips
        for bt in backup.trips {
            let trip = TripBundle(
                id: bt.id,
                name: bt.name,
                destinationCity: bt.destinationCity,
                days: bt.days,
                dateRange: bt.dateRange,
                departureDate: bt.departureDate,
                isDateless: bt.isDateless ?? false,
                createdAt: bt.createdAt,
                selectedSceneKeys: bt.selectedSceneKeys
            )
            trip.dismissedSurpriseNames = bt.dismissedSurpriseNames

            trip.sceneCardDismissed = bt.sceneCardDismissed
            trip.remindersEnabled = bt.remindersEnabled
            trip.reminderConfigData = bt.reminderConfigData
            trip.countryCode = bt.countryCode
            trip.latitude = bt.latitude
            trip.longitude = bt.longitude
            // 还原多目的地数据（旧备份无此字段时保持默认空 Data）
            if let extra = bt.additionalDestinationsData {
                trip.additionalDestinationsData = extra
            }
            // 还原背景图条目（含裁剪框）；图片字节已在上面写回沙盒
            if let bg = bt.backgroundsData {
                trip.backgroundsData = bg
            }
            context.insert(trip)

            for bs in bt.sections.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let section = PackingSection(title: bs.title, sortOrder: bs.sortOrder)
                section.id = bs.id
                section.bundle = trip
                context.insert(section)

                for bi in bs.items.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    let item = PackingItem(
                        name: bi.name,
                        quantity: bi.quantity,
                        isPacked: bi.isPacked,
                        isAlert: bi.isAlert,
                        sortOrder: bi.sortOrder
                    )
                    item.id = bi.id
                    item.section = section
                    context.insert(item)
                }
            }
            restoreItineraryDays(bt.itineraryDays, for: trip, into: context)
            restoreLodgingStays(bt.lodgingStays, for: trip, into: context)
        }

        // Restore MyItems
        for bm in backup.myItems {
            let item = MyItem(
                id: bm.id,
                name: bm.name,
                collectionName: bm.collectionName,
                category: bm.category,
                defaultQuantity: bm.defaultQuantity,
                quantityMode: MyItemQuantityMode(rawValue: bm.quantityModeRaw) ?? .fixed,
                quantityIntervalDays: bm.quantityIntervalDays,
                sortOrder: bm.sortOrder,
                createdAt: bm.createdAt,
                updatedAt: bm.updatedAt
            )
            context.insert(item)
        }

        try context.save()
        return (backup.trips.count, backup.myItems.count)
    }
}
