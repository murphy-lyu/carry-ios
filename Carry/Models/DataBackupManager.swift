//
//  DataBackupManager.swift
//  Carry
//

import Foundation
import SwiftData

// MARK: - Codable Mirror Types

struct BackupPackingItem: Codable {
    var id: UUID
    var name: String
    var quantity: Int
    var isPacked: Bool
    var isAlert: Bool
    var sortOrder: Int
}

struct BackupPackingSection: Codable {
    var id: UUID
    var title: String
    var sortOrder: Int
    var items: [BackupPackingItem]
}

struct BackupTrip: Codable {
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
    var sections: [BackupPackingSection]
}

struct BackupMyItem: Codable {
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

struct CarryBackup: Codable {
    var version: Int
    var createdAt: Date
    var trips: [BackupTrip]
    var myItems: [BackupMyItem]
    /// 用户的默认提醒档位偏好（设置 →「通知」）。可选：旧备份无此字段时还原后保持现状。
    var defaultReminderOffsets: [Int]?
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

    /// Serialize all current data to JSON. Called after every successful save so the backup stays fresh.
    func backup(trips: [TripBundle], myItems: [MyItem]) {
        guard let url = backupURL else { return }

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
                sections: sections
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

        let backup = CarryBackup(
            version: Self.currentBackupVersion,
            createdAt: Date(),
            trips: backupTrips,
            myItems: backupMyItems,
            defaultReminderOffsets: ReminderPreferences.enabledOffsets.sorted()
        )

        // Encode on the calling thread (main actor) so the Codable conformance stays
        // in its correct isolation context. Only the disk write is offloaded.
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        guard let data = try? e.encode(backup) else {
            CarryLogger.shared.log(.backupWriteFailed, context: "reason=encode_failed")
            return
        }
        Task.detached(priority: .utility) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                await CarryLogger.shared.log(.backupWriteFailed,
                    context: "reason=write_failed error=\(error.localizedDescription)")
            }
        }
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
    /// 版本历史：
    /// - v1（首版）：基础字段
    /// - v2：BackupTrip 加 additionalDestinationsData（多目的地）；CarryBackup 加
    ///   defaultReminderOffsets（通知偏好）；二者均为可选，v1 旧备份在 v2 App 还原
    ///   时按 nil 处理（多目的地丢失/偏好保持现状）。
    static let currentBackupVersion = 2

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
