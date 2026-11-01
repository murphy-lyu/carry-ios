//
//  DataBackupManager.swift
//  Carry
//

import Foundation
import SwiftData
import os
import Darwin
import CryptoKit

// MARK: - Codable Mirror Types

nonisolated struct BackupPackingItem: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var quantity: Int
    var isPacked: Bool
    var isAlert: Bool
    var sortOrder: Int
}

nonisolated struct BackupPackingSection: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var sortOrder: Int
    var items: [BackupPackingItem]
}

/// 照片回溯生成的停靠点照片（spec: photo-trip-reconstruction.md）。
/// 缩略图字节随备份走（CLAUDE.md 备份约定：沙盒外/不在关系图直存的字节必须显式带上）；
/// 旧备份只有设备 Photos 标识；新账户完整备份通过 photoOriginals 保留原图。
/// 缺少原图的迁移必须停下来采集，不能把只有缩略图称为完整迁移。
nonisolated struct BackupStopPhoto: Codable, Equatable, Sendable {
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
nonisolated struct BackupAttachment: Codable, Equatable, Sendable {
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

nonisolated struct BackupItineraryStop: Codable, Equatable, Sendable {
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

nonisolated struct BackupTransportSegment: Codable, Equatable, Sendable {
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
    var eticketNumber: String? = nil   // 电子客票号（航班）；可选 + 默认 nil：兼容旧备份
    // 地面/水路交通选填（火车/巴士/渡轮）；均可选 + 默认 nil：兼容旧备份。
    var routeName: String? = nil
    var coachNumber: String? = nil
    var seatClass: String? = nil
    var serviceType: String? = nil
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

nonisolated struct BackupLodgingStay: Codable, Equatable, Sendable {
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

nonisolated struct BackupItineraryDay: Codable, Equatable, Sendable {
    var id: UUID
    var sortOrder: Int
    var title: String
    var note: String
    var stops: [BackupItineraryStop]
    /// 交通段（spec: itinerary-transport-lodging.md）。可选以兼容旧备份（无此键 → 还原后该天无交通）。
    var segments: [BackupTransportSegment]?
}

nonisolated struct BackupTrip: Codable, Equatable, Sendable {
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

nonisolated struct BackupMyItem: Codable, Equatable, Sendable {
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

nonisolated struct CarryBackupAssetManifest: Codable, Equatable, Sendable {
    var entityID: UUID
    var assetID: UUID
    var slot: String
    var sha256: String
    var byteCount: Int
}

nonisolated struct CarryBackup: Codable, Equatable, Sendable {
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
    /// Optional full originals keyed by canonical photo UUID, not device Photos IDs.
    var photoOriginals: [String: Data]? = nil
    var assetManifest: [CarryBackupAssetManifest]? = nil
}

// MARK: - DataBackupManager

nonisolated struct CarryBackupInfo: Sendable {
    let date: Date
    let tripCount: Int
}

/// One serial worker owns automatic-backup encoding and disk writes. New work
/// replaces queued snapshots; an older detached write cannot win the race.
nonisolated final class CarryBackupWriter: Sendable {
    private struct Job: Sendable { let snapshot: CarryBackup; let url: URL; let generation: UUID }
    private struct MetadataTrip: Decodable { let id: UUID }
    private struct MetadataHeader: Decodable { let createdAt: Date; let trips: [MetadataTrip] }
    private struct State: Sendable {
        var pending: Job?
        var running = false
        var generation = UUID()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "app.nevestudio.carry.backup", qos: .utility)
    private let encode: @Sendable (CarryBackup) throws -> Data
    private let report: @Sendable (Error) -> Void
    private static let stagingPrefix = ".carry-backup-stage-"

    private func pruneStaging(in directory: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            try FileManager.default.removeItem(at: url)
        }
    }

    init(encode: @escaping @Sendable (CarryBackup) throws -> Data = { snapshot in
        let encoder = CarryBackupDates.encoder()
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(snapshot)
    }, report: @escaping @Sendable (Error) -> Void = { error in
        let message = error.localizedDescription
        Task { @MainActor in
            CarryLogger.shared.log(.backupWriteFailed, context: "reason=write_failed error=\(message)")
        }
    }) { self.encode = encode; self.report = report }

    func submit(_ snapshot: CarryBackup, to url: URL) {
        let start = state.withLock { value in
            value.pending = Job(snapshot: snapshot, url: url, generation: value.generation)
            if value.running { return false }
            value.running = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while let job = state.withLock({ value -> Job? in
            let job = value.pending
            value.pending = nil
            if job == nil { value.running = false }
            return job
        }) {
            let directory = job.url.deletingLastPathComponent()
            let stagingDirectory = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString,
                                                                     isDirectory: true)
            let staging = stagingDirectory.appendingPathComponent("snapshot.json")
            defer {
                do {
                    if FileManager.default.fileExists(atPath: stagingDirectory.path) {
                        try FileManager.default.removeItem(at: stagingDirectory)
                    }
                } catch { report(error) }
            }
            do {
                let active = try state.withLock { value in
                    guard value.generation == job.generation else { return false }
                    try pruneStaging(in: directory)
                    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
                    return true
                }
                if !active { continue }
                // Encoding and large file IO never hold the gate that clear()
                // uses. Only the final, same-directory atomic rename is gated.
                try encode(job.snapshot).write(to: staging, options: .atomic)
                try state.withLock { value in
                    guard value.generation == job.generation else { return }
                    try staging.withUnsafeFileSystemRepresentation { source in
                        try job.url.withUnsafeFileSystemRepresentation { destination in
                            guard let source, let destination else { throw CocoaError(.fileWriteInvalidFileName) }
                            if Darwin.rename(source, destination) != 0 {
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                            }
                        }
                    }
                }
            }
            catch {
                // A cleared generation deliberately removes its staging parent;
                // a late file write then fails without recreating private bytes.
                if state.withLock({ $0.generation == job.generation }) { report(error) }
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    func info(at url: URL) async throws -> CarryBackupInfo? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let decoder = CarryBackupDates.decoder()
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let header = try decoder.decode(MetadataHeader.self, from: data)
                    continuation.resume(returning: CarryBackupInfo(date: header.createdAt, tripCount: header.trips.count))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Invalidate pending/in-flight work before deleting. The short commit gate
    /// prevents late rename after erasure without waiting for encoding or IO.
    func clear(_ url: URL) throws {
        try state.withLock { value in
            value.generation = UUID()
            value.pending = nil
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try pruneStaging(in: url.deletingLastPathComponent())
        }
    }
}

final class DataBackupManager {
    static let shared = DataBackupManager()
    private init() { explicitBackupURL = nil }
    init(backupURL: URL) { explicitBackupURL = backupURL }

    private let explicitBackupURL: URL?
    private let writer = CarryBackupWriter()
    private var pendingBackup: Task<Void, Never>?
    private var pendingSource: (@MainActor () -> (trips: [TripBundle], myItems: [MyItem])?)?
    private var backupDeadline: ContinuousClock.Instant?

    private let fileName = "carry_backup.json"

    private let decoder: JSONDecoder = {
        let d = CarryBackupDates.decoder()
        return d
    }()

    private var backupURL: URL? {
        if let explicitBackupURL { return explicitBackupURL }
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
    /// `includeAttachments`：附件（含缩略图字节）仅供自己用的完整备份/导出携带；「发给同行者」的单行程分享
    /// 必须传 false——附件可能是证件照/确认单截图，分享渲染器不读附件、天然不该外泄（spec: itinerary-attachments.md）。
    private func backupSegments(_ day: ItineraryDay, includeAttachments: Bool = true) -> [BackupTransportSegment] {
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
                aircraftType: s.aircraftType, cabinClass: s.cabinClass, eticketNumber: s.eticketNumber,
                routeName: s.routeName, coachNumber: s.coachNumber, seatClass: s.seatClass, serviceType: s.serviceType,
                distanceMeters: s.distanceMeters, durationMinutes: s.durationMinutes,
                vehicleModel: s.vehicleModel, licensePlate: s.licensePlate,
                fromAddress: s.fromAddress, toAddress: s.toAddress,
                phone: s.phone,
                remindersMuted: s.remindersMuted,
                attachments: includeAttachments ? backupAttachments(s.attachments) : nil
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

    /// 把一个行程的住宿跨度映射为备份镜像。`includeAttachments` 同 `backupSegments`。
    private func backupLodging(_ trip: TripBundle, includeAttachments: Bool = true) -> [BackupLodgingStay] {
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
                attachments: includeAttachments ? backupAttachments(l.attachments) : nil
            )
        }
    }

    /// Value capture only. File collection and encoding belong to the migration
    /// worker so large backups never perform disk I/O on the UI actor.
    func migrationSnapshot(trips: [TripBundle], myItems: [MyItem]) -> CarryBackup {
        makeBackup(trips: trips, myItems: myItems)
    }

    private func makeBackup(trips: [TripBundle], myItems: [MyItem]) -> CarryBackup {
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


        return CarryBackup(
            version: Self.currentBackupVersion,
            createdAt: Date(),
            trips: backupTrips,
            myItems: backupMyItems,
            defaultReminderOffsets: ReminderPreferences.enabledOffsets.sorted()
        )
    }

    /// Local-only optimistic concurrency fingerprint. Includes private metadata so a delete
    /// based on an old public snapshot cannot miss a newly attached document. Only the digest
    /// leaves the device; never expose this mirror as an MCP query projection.
    func automationRevision(for trip: TripBundle) throws -> String {
        guard var mirror = makeBackup(trips: [trip], myItems: []).trips.first else {
            throw AutomationError.notFound
        }
        func attachments(_ values: [BackupAttachment]?) -> [BackupAttachment]? {
            values?.map { value in
                var result = value; result.thumbnailData = Data(); return result
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        mirror.sections = mirror.sections.map { section in
            var result = section
            result.items.sort { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.id.uuidString < $1.id.uuidString }
            return result
        }.sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.id.uuidString < $1.id.uuidString }
        mirror.itineraryDays = mirror.itineraryDays?.map { day in
            var result = day
            result.stops = day.stops.map { stop in
                var item = stop
                item.photos = stop.photos?.map { photo in
                    var value = photo; value.thumbnailData = Data(); return value
                }.sorted { $0.id.uuidString < $1.id.uuidString }
                item.attachments = attachments(stop.attachments)
                return item
            }.sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.id.uuidString < $1.id.uuidString }
            result.segments = day.segments?.map { segment in
                var item = segment; item.attachments = attachments(segment.attachments); return item
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            return result
        }.sorted { $0.sortOrder < $1.sortOrder }
        mirror.lodgingStays = mirror.lodgingStays?.map { stay in
            var item = stay; item.attachments = attachments(stay.attachments); return item
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return try AutomationCodec.privateDigest(mirror)
    }

    /// SwiftData saves stay immediate. Coalesce automatic-backup work for 250 ms
    /// (at most one second during continuous edits), then read the current graph
    /// on its actor. Thumbnail bytes remain in the backup; JSON/base64 and disk
    /// work run on the serial utility worker, never in the tap handler.
    func scheduleBackup(source: @escaping @MainActor () -> (trips: [TripBundle], myItems: [MyItem])?) {
        pendingSource = source
        pendingBackup?.cancel()
        let clock = ContinuousClock()
        let deadline = backupDeadline ?? clock.now.advanced(by: .seconds(1))
        backupDeadline = deadline
        let due = min(deadline, clock.now.advanced(by: .milliseconds(250)))
        pendingBackup = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: due, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.performPendingBackup()
        }
    }

    private func performPendingBackup() {
        let source = pendingSource
        pendingSource = nil
        pendingBackup = nil
        backupDeadline = nil
        guard let models = source?(), let url = backupURL else { return }
        writer.submit(makeBackup(trips: models.trips, myItems: models.myItems), to: url)
    }

    func flushPendingBackup() async {
        pendingBackup?.cancel()
        performPendingBackup()
        await writer.flush()
    }

    /// Export is bounded and complete. Unavailable account files fail explicitly
    /// rather than producing a nominal backup that cannot restore its contents.
    private func exportSnapshot(trips: [TripBundle], myItems: [MyItem]) throws -> CarryBackup {
        var snapshot = makeBackup(trips: trips, myItems: myItems)
        var remaining = CarryMigrationBackupPreparation.maximumEmbeddedBytes
        func read(_ url: URL) throws -> Data {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, let count = info.fileSize,
                  count > 0, count <= CarryAccountAssetCache.maximumBytes, count <= remaining else { throw BackupError.missingAsset }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard bytes.count == count else { throw BackupError.missingAsset }
            remaining -= count
            return bytes
        }
        var backgrounds: [String: Data] = [:], attachments: [String: Data] = [:], originals: [String: Data] = [:]
        for trip in trips {
            for name in trip.backgrounds.compactMap(\.localFileName) where backgrounds[name] == nil {
                backgrounds[name] = try read(BackgroundImageStore.fileURL(named: name))
            }
            var references = trip.safeLodgingStays.flatMap { $0.attachments ?? [] }
            for day in trip.safeItineraryDays {
                references += day.sortedStops.flatMap { $0.attachments ?? [] }
                references += day.sortedSegments.flatMap { $0.attachments ?? [] }
                for photo in day.sortedStops.flatMap(\.sortedPhotos)
                    where photo.assetLocalIdentifier.hasPrefix("carryphoto1_") || CarryAccountFileAccess.isAccountReference(photo.assetLocalIdentifier) {
                    originals[photo.id.uuidString.lowercased()] = try read(AttachmentStore.fileURL(named: photo.assetLocalIdentifier))
                }
            }
            for attachment in references where !attachment.fileName.isEmpty && attachments[attachment.fileName] == nil {
                attachments[attachment.fileName] = try read(AttachmentStore.fileURL(named: attachment.fileName))
            }
        }
        snapshot.backgroundImages = backgrounds.isEmpty ? nil : backgrounds
        snapshot.attachmentFiles = attachments.isEmpty ? nil : attachments
        snapshot.photoOriginals = originals.isEmpty ? nil : originals
        _ = try CarryBackupFileStage.validateEmbeddedBudget(snapshot)
        return snapshot
    }

    /// Builds a complete, bounded self-contained file for explicit sharing.
    func makeExportFile(trips: [TripBundle], myItems: [MyItem]) -> URL? {
        let snapshot: CarryBackup
        do { snapshot = try exportSnapshot(trips: trips, myItems: myItems) }
        catch {
            CarryLogger.shared.log(.backupWriteFailed, context: "reason=missing_or_oversized_asset export=true")
            return nil
        }
        guard let data = Self.encode(snapshot), data.count <= 256 * 1024 * 1024 else {
            CarryLogger.shared.log(.backupWriteFailed, context: "reason=encode_failed export=true")
            return nil
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("carry_backup_\(fmt.string(from: Date())).json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try data.write(to: url, options: .atomic)
            CarryLogger.shared.log(.backupExported, context: "trips=\(trips.count)")
            return url
        } catch {
            CarryLogger.shared.log(.backupWriteFailed,
                context: "reason=write_failed export=true error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func encode(_ backup: CarryBackup) -> Data? {
        let e = CarryBackupDates.encoder()
        e.outputFormatting = .prettyPrinted
        return try? e.encode(backup)
    }

    // MARK: - Query

    /// The file URL of the backup, usable for sharing via UIActivityViewController.
    var backupFileURL: URL? { backupURL }

    /// 删除本地自动备份文件（用于「抹掉所有数据」——否则抹除后 restore 又把数据带回来，
    /// 与「被遗忘」矛盾。spec: erase-all-data.md）。文件不存在视为成功。
    func clearBackup() throws {
        pendingBackup?.cancel()
        pendingBackup = nil
        pendingSource = nil
        backupDeadline = nil
        guard let url = backupURL else { return }
        do { try writer.clear(url) }
        catch {
            CarryLogger.shared.log(.backupWriteFailed, context: "reason=erase_failed")
            throw error
        }
    }

    func latestBackupInfo() async -> CarryBackupInfo? {
        guard let url = backupURL else { return nil }
        do { return try await writer.info(at: url) }
        catch {
            CarryLogger.shared.log(.loadFailed, context: "reason=backup_metadata")
            return nil
        }
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
    nonisolated static let currentBackupVersion = 1

    nonisolated enum BackupError: LocalizedError {
        case fileNotFound
        case decodingFailed
        case missingAsset
        case tooLarge
        case targetChanged
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return NSLocalizedString("settings.data.restore.error.not_found", comment: "")
            case .decodingFailed:
                return NSLocalizedString("settings.data.restore.error.corrupt", comment: "")
            case .tooLarge:
                return NSLocalizedString("settings.data.backup.too_large", comment: "")
            case .targetChanged:
                return NSLocalizedString("settings.data.backup.changed", comment: "")
            case .missingAsset:
                return NSLocalizedString("settings.data.restore.error.asset", comment: "")
            case .unsupportedVersion(let v):
                return String(format: NSLocalizedString("settings.data.restore.error.version", comment: ""), v)
            }
        }
    }

    // MARK: - Restore (device backup)

    /// Restore from the automatic local backup written after every save.
    @discardableResult
    func restore(into context: ModelContext, save: CarryPersistence.Save = { try $0.save() }) throws -> (trips: Int, myItems: Int) {
        guard let url = backupURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.fileNotFound
        }
        let data = try Data(contentsOf: url)
        return try restoreFromData(data, into: context, allowLocalFileReferences: true, save: save)
    }

    // MARK: - Restore (imported file)

    /// Restore from raw JSON data — used when the caller has already read the
    /// file within a security scope (e.g., from the file importer picker).
    @discardableResult
    func restoreFromData(_ data: Data, into context: ModelContext, allowLocalFileReferences: Bool = false, save: CarryPersistence.Save = { try $0.save() }) throws -> (trips: Int, myItems: Int) {
        // 关键顺序：必须先用最小 stub 只读 version，再做完整 decode。
        // 否则新版备份含旧版未识别的非可选字段时，完整 decode 会先抛 decodingFailed
        //（"文件损坏"），用户永远看不到 unsupportedVersion 的"请更新 App"提示。
        struct VersionStub: Decodable { let version: Int }
        if let stub = try? decoder.decode(VersionStub.self, from: data),
           stub.version > Self.currentBackupVersion {
            CarryLogger.shared.log(.backupRestoreFailed, context: "reason=unsupported_version v=\(stub.version)")
            throw BackupError.unsupportedVersion(stub.version)
        }
        guard let backup = try? decoder.decode(CarryBackup.self, from: data) else {
            CarryLogger.shared.log(.backupCorrupted, context: "reason=decode_failed bytes=\(data.count)")
            throw BackupError.decodingFailed
        }
        let result = try performRestore(from: backup, into: context, allowLocalFileReferences: allowLocalFileReferences, save: save)
        CarryLogger.shared.log(.backupRestored, context: "trips=\(result.trips) items=\(result.myItems)")
        return result
    }

    // MARK: - Merge (imported file)

    /// 合并导入：将备份中在本地不存在的行程 / 物品模板插入数据库，
    /// 已存在的（UUID 匹配）跳过，不覆盖本地版本。
    @discardableResult
    func mergeFromData(_ data: Data, into context: ModelContext, save: CarryPersistence.Save = { try $0.save() }) throws -> (trips: Int, myItems: Int) {
        struct VersionStub: Decodable { let version: Int }
        if let stub = try? decoder.decode(VersionStub.self, from: data),
           stub.version > Self.currentBackupVersion {
            CarryLogger.shared.log(.backupRestoreFailed, context: "reason=unsupported_version merge v=\(stub.version)")
            throw BackupError.unsupportedVersion(stub.version)
        }
        guard let backup = try? decoder.decode(CarryBackup.self, from: data) else {
            CarryLogger.shared.log(.backupCorrupted, context: "reason=decode_failed merge bytes=\(data.count)")
            throw BackupError.decodingFailed
        }
        let result = try performMerge(from: backup, into: context, save: save)
        CarryLogger.shared.log(.backupMerged, context: "trips=\(result.trips) items=\(result.myItems)")
        return result
    }

    /// 合并一个已在内存中构建好的 `CarryBackup`（如从 Tripsy 转换而来，spec: tripsy-import.md）。
    /// 与 `mergeFromData` 同一段 `performMerge` 逻辑，但**跳过 JSON 编/解码往返**——避免把
    /// 附件图片字节 base64 编一遍又解一遍的浪费（值已是合法内存对象，无需版本校验）。
    @discardableResult
    func merge(_ backup: CarryBackup, into context: ModelContext, save: CarryPersistence.Save = { try $0.save() }) throws -> (trips: Int, myItems: Int) {
        try performMerge(from: backup, into: context, save: save)
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
                    eticketNumber: bg.eticketNumber ?? "",
                    routeName: bg.routeName ?? "", coachNumber: bg.coachNumber ?? "",
                    seatClass: bg.seatClass ?? "", serviceType: bg.serviceType ?? "",
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

    private func performMerge(from source: CarryBackup, into context: ModelContext, preparedStage: CarryBackupFileStage? = nil, save: CarryPersistence.Save) throws -> (trips: Int, myItems: Int) {
        // 取出现有 UUID 集合，用于去重判断
        let existingTripIDs = Set(try context.fetch(FetchDescriptor<TripBundle>()).map(\.id))
        let existingMyItemIDs = Set(try context.fetch(FetchDescriptor<MyItem>()).map(\.id))
        var selected = source
        selected.trips = source.trips.filter { !existingTripIDs.contains($0.id) }
        selected.assetManifest = CarryBackupFileStage.selectedManifests(selected)
        let fileStage: CarryBackupFileStage
        if let preparedStage { fileStage = preparedStage } else { fileStage = try CarryBackupFileStage(selected) }
        defer { if preparedStage == nil { fileStage.discard() } }
        try fileStage.publish()
        let backup = fileStage.backup

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

        try CarryPersistence.commit(context, using: save)
        fileStage.commit()
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
            let segments = backupSegments(day, includeAttachments: false)
            return BackupItineraryDay(id: day.id, sortOrder: day.sortOrder, title: day.title, note: day.note,
                                      stops: stops, segments: segments.isEmpty ? nil : segments)
        }
        let lodgingStays = backupLodging(trip, includeAttachments: false)
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
    func importSharedTrip(from data: Data, into context: ModelContext, save: CarryPersistence.Save = { try $0.save() }) throws -> UUID {
        struct VersionStub: Decodable { let version: Int }
        if let stub = try? decoder.decode(VersionStub.self, from: data),
           stub.version > Self.currentBackupVersion {
            throw BackupError.unsupportedVersion(stub.version)
        }
        guard let backup = try? decoder.decode(CarryBackup.self, from: data),
              let incoming = backup.trips.first else {
            throw BackupError.decodingFailed
        }
        let bt = CarryBackupFileStage.itineraryOnly(incoming)
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
        try CarryPersistence.commit(context, using: save)
        return bt.id
    }

    // MARK: - Core restore

    private func performRestore(from source: CarryBackup, into context: ModelContext, allowLocalFileReferences: Bool, preparedStage: CarryBackupFileStage? = nil, save: CarryPersistence.Save) throws -> (trips: Int, myItems: Int) {
        let fileStage: CarryBackupFileStage
        if let preparedStage { fileStage = preparedStage } else { fileStage = try CarryBackupFileStage(source, allowLocalFileReferences: allowLocalFileReferences) }
        defer { if preparedStage == nil { fileStage.discard() } }
        try fileStage.publish()
        let backup = fileStage.backup
        // 原子化保护：在执行破坏性 delete 前先把当前 backup.json 复制成
        // .pre-restore-{epoch}.json，任一步失败时用户/作者可手动恢复。
        // ⚠️ 用 epoch 时间戳后缀而非固定名 — 用户连续 restore 失败多次时，
        // 每次保留独立安全副本，避免被下一次覆盖丢失原始数据。
        if preparedStage == nil, let backupURL = backupURL,
           FileManager.default.fileExists(atPath: backupURL.path) {
            let epoch = Int(Date().timeIntervalSince1970)
            let safety = backupURL
                .deletingPathExtension()
                .appendingPathExtension("pre-restore-\(epoch).json")
            try? FileManager.default.copyItem(at: backupURL, to: safety)
            CarryLogger.shared.log(.backupSafetyCopyCreated, context: "path=\(safety.lastPathComponent)")
        }

        // Wipe existing data (cascade deletes PackingSection + PackingItem).
        // 用逐实例 delete（非类型擦除的批量 `context.delete(model:)`）——后者是直接落盘的批量操作，
        // 不参与 context 的待提交事务，一旦本函数后续任何一步（重建行程/最终 save）失败，旧数据已经
        // 永久消失、新数据从未提交，只能靠隐藏的 pre-restore 安全副本手动找回。逐实例 delete 会随下面
        // 新建的对象一起，在最终唯一一次 `context.save()` 里同生共死——失败即整体不落盘，旧数据完好无损。
        for t in try context.fetch(FetchDescriptor<TripBundle>()) { context.delete(t) }
        for m in try context.fetch(FetchDescriptor<MyItem>()) { context.delete(m) }

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

        try CarryPersistence.commit(context, using: save)
        fileStage.commit()
        // Apply global preferences only after the business transaction succeeds.
        if let offsets = backup.defaultReminderOffsets {
            ReminderPreferences.enabledOffsets = Set(offsets)
        }
        // 还原成功：安全副本已完成使命，只留最近几份防线（+ 每次还原都会新建一份，
        // 不清理会无限堆积孤儿文件）。失败路径（本函数抛出）刻意不清——那正是需要它的时候。
        if preparedStage == nil { pruneOldSafetyCopies(keepLatest: 3) }
        return (backup.trips.count, backup.myItems.count)
    }

    /// 清理 `performRestore` 生成的 `carry_backup.pre-restore-{epoch}.json` 安全副本，只保留最近 N 份。
    private func pruneOldSafetyCopies(keepLatest: Int) {
        guard let backupURL, let dir = backupURL.deletingLastPathComponent() as URL? else { return }
        let prefix = backupURL.deletingPathExtension().lastPathComponent + ".pre-restore-"
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let stale = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // epoch 字符串序 == 时间序，新→旧
            .dropFirst(keepLatest)
        for url in stale { try? FileManager.default.removeItem(at: url) }
    }
}


// MARK: - User initiated backup work
extension DataBackupManager {
    /// Only the value snapshot and resolved immutable URLs leave the UI actor.
    /// No SwiftData model, context or file-access registry crosses this boundary.
    func makeExportFileAsync(trips: [TripBundle], myItems: [MyItem]) async throws -> URL {
        let snapshot = makeBackup(trips: trips, myItems: myItems)
        var inputs: [CarryBackupExportFile] = [], accountURLs: [String: URL] = [:]
        func resolve(_ name: String, background: Bool) throws -> URL {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name != ".", name != ".." else { throw BackupError.missingAsset }
            if CarryAccountFileAccess.isAccountReference(name) {
                guard let url = CarryAccountFileAccess.shared.url(named: name) else { throw BackupError.missingAsset }
                accountURLs[name] = url; return url
            }
            return background ? BackgroundImageStore.fileURL(named: name) : AttachmentStore.fileURL(named: name)
        }
        var backgroundNames = Set<String>(), attachmentNames = Set<String>()
        for trip in trips {
            for name in trip.backgrounds.compactMap(\.localFileName) where backgroundNames.insert(name).inserted {
                inputs.append(.init(key: name, sourceName: name, url: try resolve(name, background: true), destination: .background))
            }
            var attachments = trip.safeLodgingStays.flatMap { $0.attachments ?? [] }
            for day in trip.safeItineraryDays {
                attachments += day.sortedStops.flatMap { $0.attachments ?? [] }
                attachments += day.sortedSegments.flatMap { $0.attachments ?? [] }
                for photo in day.sortedStops.flatMap(\.sortedPhotos) where photo.assetLocalIdentifier.hasPrefix("carryphoto1_") || CarryAccountFileAccess.isAccountReference(photo.assetLocalIdentifier) {
                    inputs.append(.init(key: photo.id.uuidString.lowercased(), sourceName: photo.assetLocalIdentifier,
                        url: try resolve(photo.assetLocalIdentifier, background: false), destination: .original))
                }
            }
            for attachment in attachments where !attachment.fileName.isEmpty && attachmentNames.insert(attachment.fileName).inserted {
                inputs.append(.init(key: attachment.fileName, sourceName: attachment.fileName,
                    url: try resolve(attachment.fileName, background: false), destination: .attachment))
            }
        }
        let result = try await Self.writeExportAsync(snapshot, files: inputs)
        do {
            try Task.checkCancellation()
            guard accountURLs.allSatisfy({ CarryAccountFileAccess.shared.url(named: $0.key) == $0.value }) else { throw BackupError.missingAsset }
            return result
        } catch { await Self.discardExportFileAsync(result); throw error }
    }

    func restoreFromBackupAsync(into context: ModelContext, preCommit: () throws -> Void = {}, save: CarryPersistence.Save = { try $0.save() }) async throws -> (trips: Int, myItems: Int) {
        let baseline = try targetSnapshot(in: context)
        guard let url = backupURL else { throw BackupError.fileNotFound }
        let data = try await Self.readImportData(at: url, securityScoped: false)
        return try await restoreFromDataAsync(data, into: context, allowLocalFileReferences: true, expectedTarget: baseline, preCommit: preCommit, save: save)
    }
    func restoreFromDataAsync(_ data: Data, into context: ModelContext, allowLocalFileReferences: Bool = false, expectedTarget: CarryBackup? = nil, preCommit: () throws -> Void = {},
                              save: CarryPersistence.Save = { try $0.save() }) async throws -> (trips: Int, myItems: Int) {
        let baseline = try expectedTarget ?? targetSnapshot(in: context)
        let source = try await Self.decodeImportAsync(data)
        let stage = try await CarryBackupFileStage.prepareAsync(source, allowLocalFileReferences: allowLocalFileReferences)
        var safety: CarryBackupSafetyFile?
        do {
            safety = try await writeFullSafetyBackupAsync(from: context)
            try Task.checkCancellation()
            try stage.validateLease(); try preCommit()
            guard !context.hasChanges, try targetSnapshot(in: context) == baseline else { throw BackupError.targetChanged }
            let result = try performRestore(from: stage.backup, into: context, allowLocalFileReferences: allowLocalFileReferences, preparedStage: stage, save: save)
            if let safety, let completed = await Self.finishSafetyBackupAsync(safety) { await Self.pruneSafetyBackupsAsync(current: completed, prefix: safety.prefix) }
            return result
        } catch {
            await stage.discardAsync()
            if let safety { _ = await Self.finishSafetyBackupAsync(safety) }
            throw error
        }
    }
    func mergeFromDataAsync(_ data: Data, into context: ModelContext, preCommit: () throws -> Void = {},
                            save: CarryPersistence.Save = { try $0.save() }) async throws -> (trips: Int, myItems: Int) {
        let baseline = try targetSnapshot(in: context)
        var source = try await Self.decodeImportAsync(data)
        let existing = Set(try context.fetch(FetchDescriptor<TripBundle>()).map(\.id))
        source.trips.removeAll { existing.contains($0.id) }
        source.assetManifest = CarryBackupFileStage.selectedManifests(source)
        let stage = try await CarryBackupFileStage.prepareAsync(source)
        do {
            try Task.checkCancellation()
            let current = Set(try context.fetch(FetchDescriptor<TripBundle>()).map(\.id))
            guard stage.backup.trips.allSatisfy({ !current.contains($0.id) }) else { throw BackupError.targetChanged }
            try stage.validateLease(); try preCommit()
            guard !context.hasChanges, try targetSnapshot(in: context) == baseline else { throw BackupError.targetChanged }
            return try performMerge(from: stage.backup, into: context, preparedStage: stage, save: save)
        } catch { await stage.discardAsync(); throw error }
    }

    private func targetSnapshot(in context: ModelContext) throws -> CarryBackup {
        guard !context.hasChanges else { throw BackupError.targetChanged }
        let fresh = ModelContext(context.container); fresh.autosaveEnabled = false
        var snapshot = makeBackup(trips: try fresh.fetch(FetchDescriptor<TripBundle>()).sorted { $0.id.uuidString < $1.id.uuidString },
            myItems: try fresh.fetch(FetchDescriptor<MyItem>()).sorted { $0.id.uuidString < $1.id.uuidString })
        snapshot.createdAt = Date(timeIntervalSince1970: 0)
        snapshot.trips = snapshot.trips.map { value in
            var trip = value
            trip.sections = trip.sections.map { value in var section = value; section.items.sort { $0.id.uuidString < $1.id.uuidString }; return section }.sorted { $0.id.uuidString < $1.id.uuidString }
            trip.itineraryDays = trip.itineraryDays?.map { value in
                var day = value
                day.stops = day.stops.map { value in
                    var stop = value; stop.photos?.sort { $0.id.uuidString < $1.id.uuidString }; stop.attachments?.sort { $0.id.uuidString < $1.id.uuidString }; return stop
                }.sorted { $0.id.uuidString < $1.id.uuidString }
                day.segments = day.segments?.map { value in var segment = value; segment.attachments?.sort { $0.id.uuidString < $1.id.uuidString }; return segment }.sorted { $0.id.uuidString < $1.id.uuidString }
                return day
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            trip.lodgingStays = trip.lodgingStays?.map { value in var stay = value; stay.attachments?.sort { $0.id.uuidString < $1.id.uuidString }; return stay }.sorted { $0.id.uuidString < $1.id.uuidString }
            return trip
        }
        return snapshot
    }
    @concurrent nonisolated static func readImportData(at url: URL, securityScoped: Bool = true) async throws -> Data {
        let accessing = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size > 0, size <= 256 * 1024 * 1024 else { throw BackupError.tooLarge }
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        guard data.count == size else { throw BackupError.decodingFailed }
        return data
    }
    @concurrent nonisolated private static func decodeImportAsync(_ data: Data) async throws -> CarryBackup {
        guard data.count <= 256 * 1024 * 1024 else { throw BackupError.tooLarge }
        try Task.checkCancellation()
        struct VersionStub: Decodable { let version: Int }
        let decoder = CarryBackupDates.decoder()
        if let version = try? decoder.decode(VersionStub.self, from: data).version, version > currentBackupVersion { throw BackupError.unsupportedVersion(version) }
        let result: CarryBackup
        do { result = try decoder.decode(CarryBackup.self, from: data) } catch { throw BackupError.decodingFailed }
        try Task.checkCancellation()
        _ = try CarryBackupFileStage.validateEmbeddedBudget(result)
        try CarryBackupFileStage.validateManifests(result)
        return result
    }
    private func writeFullSafetyBackupAsync(from context: ModelContext) async throws -> CarryBackupSafetyFile {
        // Separate namespaces prevent a local restore from pruning another
        // Carry account's recovery files. Pending operations are never pruned.
        let fresh = ModelContext(context.container); fresh.autosaveEnabled = false
        let namespace: String
        if context.container.schema.entities.contains(where: { $0.name == String(describing: CarryReplicaCheckpoint.self) }) {
            let owners = try fresh.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
            guard owners.count == 1, let owner = owners.first else { throw BackupError.targetChanged }
            namespace = owner.accountID.uuidString.lowercased()
        } else { namespace = "local" }
        let exported = try await makeExportFileAsync(trips: fresh.fetch(FetchDescriptor<TripBundle>()), myItems: fresh.fetch(FetchDescriptor<MyItem>()))
        guard let base = backupURL else { await Self.discardExportFileAsync(exported); throw BackupError.fileNotFound }
        let prefix = base.deletingPathExtension().lastPathComponent + ".pre-restore-"
        let folder = base.deletingLastPathComponent().appendingPathComponent("Safety-" + namespace, isDirectory: true)
        let pending = folder.appendingPathComponent(".pending-" + prefix + UUID().uuidString.lowercased() + ".json")
        do {
            try await Self.retainSafetyExportAsync(exported, at: pending)
            return CarryBackupSafetyFile(pending: pending, prefix: prefix)
        } catch { await Self.discardExportFileAsync(exported); throw error }
    }
    @concurrent nonisolated private static func retainSafetyExportAsync(_ exported: URL, at destination: URL) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exported.path)
        try FileManager.default.moveItem(at: exported, to: destination)
    }
    @concurrent nonisolated private static func finishSafetyBackupAsync(_ file: CarryBackupSafetyFile) async -> URL? {
        let name = file.prefix + String(Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString.lowercased() + ".json"
        let completed = file.pending.deletingLastPathComponent().appendingPathComponent(name)
        do { try FileManager.default.moveItem(at: file.pending, to: completed); return completed }
        catch { Task { @MainActor in CarryLogger.shared.log(.persistFailed, context: "safety_backup_finalize") }; return nil }
    }
    @concurrent nonisolated private static func pruneSafetyBackupsAsync(current: URL, prefix: String) async {
        let folder = current.deletingLastPathComponent()
        func timestamp(_ name: String) -> Int? {
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
            let suffix = name.dropFirst(prefix.count).dropLast(5)
            guard let separator = suffix.firstIndex(of: "-"), let stamp = Int(suffix[..<separator]), stamp > 0,
                  UUID(uuidString: String(suffix[suffix.index(after: separator)...])) != nil else { return nil }
            return stamp
        }
        guard let cutoff = timestamp(current.lastPathComponent) else { return }
        do {
            let folderInfo = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard folderInfo.isDirectory == true, folderInfo.isSymbolicLink != true else { return }
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            var old: [(URL, Int)] = []
            for url in urls {
                guard url != current, url.deletingLastPathComponent() == folder,
                      let stamp = timestamp(url.lastPathComponent), stamp < cutoff else { continue }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if info.isRegularFile == true && info.isSymbolicLink != true { old.append((url, stamp)) }
            }
            old.sort { $0.1 == $1.1 ? $0.0.lastPathComponent > $1.0.lastPathComponent : $0.1 > $1.1 }
            for (url, _) in old.dropFirst(2) {
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if info.isRegularFile == true && info.isSymbolicLink != true { try FileManager.default.removeItem(at: url) }
            }
        } catch { Task { @MainActor in CarryLogger.shared.log(.persistFailed, context: "safety_backup_prune") } }
    }
    @concurrent nonisolated static func discardExportFileAsync(_ url: URL) async {
        guard url.isFileURL, url.lastPathComponent.hasPrefix("carry_backup_"),
              url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { Task { @MainActor in CarryLogger.shared.log(.backupWriteFailed, context: "export_cleanup") } }
    }
    @concurrent nonisolated private static func writeExportAsync(_ source: CarryBackup, files: [CarryBackupExportFile]) async throws -> URL {
        var backup = source
        var remaining = CarryMigrationBackupPreparation.maximumEmbeddedBytes - (try CarryBackupFileStage.validateEmbeddedBudget(source))
        var backgrounds: [String: Data] = [:], attachments: [String: Data] = [:], originals: [String: Data] = [:]
        for file in files {
            try Task.checkCancellation()
            let info = try file.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
                  size > 0 else { throw BackupError.missingAsset }
            guard size <= (file.destination == .attachment ? AttachmentStore.maxBytes : CarryAccountAssetCache.maximumBytes), size <= remaining else { throw BackupError.tooLarge }
            let bytes = try Data(contentsOf: file.url)
            guard bytes.count == size else { throw BackupError.missingAsset }
            if CarryAccountFileAccess.isAccountReference(file.sourceName) {
                let token = try CarryAccountAssetToken(rawValue: file.sourceName)
                guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == token.sha256 else { throw BackupError.missingAsset }
            }
            remaining -= size
            switch file.destination { case .background: backgrounds[file.key] = bytes; case .attachment: attachments[file.key] = bytes; case .original: originals[file.key] = bytes }
        }
        backup.backgroundImages = backgrounds.isEmpty ? nil : backgrounds
        backup.attachmentFiles = attachments.isEmpty ? nil : attachments
        backup.photoOriginals = originals.isEmpty ? nil : originals
        try Task.checkCancellation()
        let encoder = CarryBackupDates.encoder(); encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(backup)
        guard data.count <= 256 * 1024 * 1024 else { throw BackupError.tooLarge }
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("carry_backup_" + UUID().uuidString + ".json")
        do { try data.write(to: url, options: .atomic); try Task.checkCancellation(); return url }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}
private nonisolated struct CarryBackupExportFile: Sendable {
    enum Destination: Equatable, Sendable { case background, attachment, original }
    let key: String
    let sourceName: String
    let url: URL
    let destination: Destination
}

private nonisolated struct CarryBackupSafetyFile: Sendable { let pending: URL; let prefix: String }
