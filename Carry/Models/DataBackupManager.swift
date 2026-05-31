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
            version: 1,
            createdAt: Date(),
            trips: backupTrips,
            myItems: backupMyItems
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

    enum BackupError: LocalizedError {
        case fileNotFound
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .fileNotFound:  return NSLocalizedString("settings.data.restore.error.not_found", comment: "")
            case .decodingFailed: return NSLocalizedString("settings.data.restore.error.corrupt", comment: "")
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
        guard let backup = try? decoder.decode(CarryBackup.self, from: data) else {
            throw BackupError.decodingFailed
        }
        return try performRestore(from: backup, into: context)
    }

    // MARK: - Core restore

    private func performRestore(from backup: CarryBackup, into context: ModelContext) throws -> (trips: Int, myItems: Int) {
        // Wipe existing data (cascade deletes PackingSection + PackingItem)
        try context.delete(model: TripBundle.self)
        try context.delete(model: MyItem.self)

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
