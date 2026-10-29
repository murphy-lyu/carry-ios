import Foundation
import CryptoKit

nonisolated struct CarryGraphMigrationAsset: Codable, Sendable {
    let id: UUID
    let entityID: UUID
    let slot: String
    let fileName: String?
    let sha256: String
    let bytes: Data
}

nonisolated struct CarryGraphMigrationPacket: Codable, Sendable {
    let accountID: UUID
    let migrationID: UUID
    let backupVersion: Int
    let createdAt: Date
    let defaultReminderOffsets: [Int]?
    let entities: [CarryGraphEntity]
    let assets: [CarryGraphMigrationAsset]
    /// Preserve optional relation presence in a portable backup round trip.
    let relations: [UUID: [String]]

    /// CarryBackup contains photo-reconstruction thumbnails and device-local
    /// Photos identifiers, not their library originals. Those originals require
    /// permission and collection on the source device before ownership switches.
    /// Passing the backup round-trip alone is not a completed photo migration.
    var photosRequiringOriginalCollection: [UUID] {
        entities.compactMap { entity in
            guard entity.kind == "photo", case .string(let identifier) = entity.fields["assetLocalIdentifier"],
                  !identifier.isEmpty else { return nil }
            return entity.id
        }
    }
}

enum CarryGraphMigrationFailure: Error {
    case invalidGraph, invalidScope, accountMismatch, missingAsset, invalidAsset, duplicateIdentity
}

/// Complete backup mirrors form the migration boundary, never MCP's intentionally
/// limited projection. This codec does no network or filesystem work. A migration
/// coordinator must upload/verify every asset before changing a trip's ownership.
nonisolated enum CarryGraphMigrationCodec {
    private static let children: [String: [String: String]] = [
        "trip": ["sections": "section", "itineraryDays": "day", "lodgingStays": "lodging"],
        "section": ["items": "packingItem"], "day": ["stops": "stop", "segments": "transport"],
        "stop": ["photos": "photo", "attachments": "attachment"],
        "transport": ["attachments": "attachment"], "lodging": ["attachments": "attachment"]
    ]

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static func object<T: Encodable>(_ value: T) throws -> [String: CarryGraphValue] {
        guard case .object(let object) = try JSONDecoder().decode(CarryGraphValue.self, from: encoder().encode(value)) else {
            throw CarryGraphMigrationFailure.invalidGraph
        }
        return object
    }

    private static func string(_ value: CarryGraphValue?) -> String? {
        guard case .string(let text) = value else { return nil }
        return text
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func assetID(account: UUID, entity: UUID, slot: String, sha256: String) throws -> UUID {
        let input = "\(account.uuidString.lowercased())/\(entity.uuidString.lowercased())/\(slot)/\(sha256)"
        let hash = Array(digest(Data(input.utf8)).prefix(32))
        let raw = String(hash)
        let positions = [8, 12, 16, 20]
        var result = ""
        for (index, char) in raw.enumerated() {
            if positions.contains(index) { result.append("-") }
            result.append(char)
        }
        guard let id = UUID(uuidString: result) else { throw CarryGraphMigrationFailure.invalidAsset }
        return id
    }

    static func prepare(_ backup: CarryBackup, accountID: UUID, migrationID: UUID,
                        tripIDs: Set<UUID>, includeLibrary: Bool,
                        includeReminderPreferences: Bool = false) throws -> CarryGraphMigrationPacket {
        guard backup.version == DataBackupManager.currentBackupVersion,
              tripIDs.isSubset(of: Set(backup.trips.map(\.id))) else { throw CarryGraphMigrationFailure.invalidScope }
        var entities: [CarryGraphEntity] = []
        var assets: [CarryGraphMigrationAsset] = []
        var assetIDs: Set<UUID> = []
        var ids: Set<UUID> = []
        var relations: [UUID: [String]] = [:]

        func addAsset(entity: UUID, slot: String, name: String? = nil, bytes: Data) throws -> UUID {
            guard bytes.count <= AttachmentStore.maxBytes, name == nil || safeName(name ?? "") else {
                throw CarryGraphMigrationFailure.invalidAsset
            }
            let sha256 = digest(bytes)
            let id = try assetID(account: accountID, entity: entity, slot: slot, sha256: sha256)
            guard assetIDs.insert(id).inserted else { throw CarryGraphMigrationFailure.duplicateIdentity }
            assets.append(CarryGraphMigrationAsset(id: id, entityID: entity, slot: slot, fileName: name, sha256: sha256, bytes: bytes))
            return id
        }

        func flatten(_ object: [String: CarryGraphValue], kind: String, parent: UUID?) throws {
            guard let id = string(object["id"]).flatMap(UUID.init(uuidString:)), ids.insert(id).inserted else {
                throw CarryGraphMigrationFailure.duplicateIdentity
            }
            var fields = object
            fields.removeValue(forKey: "id")
            relations[id] = []
            var nested: [(String, [CarryGraphValue])] = []
            for (key, childKind) in children[kind] ?? [:] {
                if let value = fields.removeValue(forKey: key) {
                    guard case .array(let array) = value else { throw CarryGraphMigrationFailure.invalidGraph }
                    relations[id, default: []].append(key)
                    nested.append((childKind, array))
                }
            }
            if kind == "trip", fields["isDateless"] == nil { fields["isDateless"] = .bool(false) }
            if kind == "photo" || kind == "attachment" {
                guard let raw = string(fields.removeValue(forKey: "thumbnailData")), let bytes = Data(base64Encoded: raw) else {
                    throw CarryGraphMigrationFailure.invalidAsset
                }
                if kind == "photo" || !bytes.isEmpty {
                    fields["thumbnailAssetID"] = .string(try addAsset(entity: id, slot: "thumbnail", bytes: bytes).uuidString)
                }
            }
            if kind == "attachment", let name = string(fields["fileName"]), !name.isEmpty {
                guard let bytes = backup.attachmentFiles?[name] else { throw CarryGraphMigrationFailure.missingAsset }
                fields["fileAssetID"] = .string(try addAsset(entity: id, slot: "file", name: name, bytes: bytes).uuidString)
            }
            if kind == "trip", let raw = string(fields["backgroundsData"]), !raw.isEmpty {
                guard let data = Data(base64Encoded: raw) else { throw CarryGraphMigrationFailure.invalidAsset }
                let backgrounds = try JSONDecoder().decode([TripBackgroundEntry].self, from: data)
                for name in Set(backgrounds.compactMap(\.localFileName)) {
                    guard let bytes = backup.backgroundImages?[name] else { throw CarryGraphMigrationFailure.missingAsset }
                    _ = try addAsset(entity: id, slot: "background:\(name)", name: name, bytes: bytes)
                }
            }
            entities.append(CarryGraphEntity(id: id, kind: kind, parentID: parent, version: 0, subtreeVersion: 0,
                fields: fields, fieldVersions: [:]))
            for (childKind, array) in nested {
                for value in array {
                    guard case .object(let child) = value else { throw CarryGraphMigrationFailure.invalidGraph }
                    try flatten(child, kind: childKind, parent: id)
                }
            }
        }

        for trip in backup.trips where tripIDs.contains(trip.id) { try flatten(object(trip), kind: "trip", parent: nil) }
        if includeLibrary { for item in backup.myItems { try flatten(object(item), kind: "libraryItem", parent: nil) } }
        return CarryGraphMigrationPacket(accountID: accountID, migrationID: migrationID, backupVersion: backup.version,
            createdAt: backup.createdAt, defaultReminderOffsets: includeReminderPreferences ? backup.defaultReminderOffsets : nil,
            entities: entities, assets: assets, relations: relations)
    }

    /// Builds a complete portable backup in memory. Digest/ref/owner failures stop
    /// the operation; missing private bytes never become an apparently good backup.
    static func restore(_ packet: CarryGraphMigrationPacket, accountID: UUID) throws -> CarryBackup {
        guard packet.accountID == accountID else { throw CarryGraphMigrationFailure.accountMismatch }
        guard packet.backupVersion == DataBackupManager.currentBackupVersion else { throw CarryGraphMigrationFailure.invalidGraph }
        var entities: [UUID: CarryGraphEntity] = [:]
        for entity in packet.entities {
            guard entities.updateValue(entity, forKey: entity.id) == nil, entity.deletedAt == nil else {
                throw CarryGraphMigrationFailure.duplicateIdentity
            }
        }
        var assetMap: [UUID: CarryGraphMigrationAsset] = [:]
        var assetsBySlot: [UUID: [String: CarryGraphMigrationAsset]] = [:]
        for asset in packet.assets {
            guard entities[asset.entityID] != nil, digest(asset.bytes) == asset.sha256,
                  asset.bytes.count <= AttachmentStore.maxBytes,
                  try assetID(account: accountID, entity: asset.entityID, slot: asset.slot, sha256: asset.sha256) == asset.id,
                  assetMap.updateValue(asset, forKey: asset.id) == nil else { throw CarryGraphMigrationFailure.invalidAsset }
            guard assetsBySlot[asset.entityID, default: [:]].updateValue(asset, forKey: asset.slot) == nil else {
                throw CarryGraphMigrationFailure.invalidAsset
            }
        }
        var descendants: [UUID: [String: [CarryGraphEntity]]] = [:]
        for entity in packet.entities {
            if let parentID = entity.parentID {
                guard let parent = entities[parentID], (children[parent.kind] ?? [:]).values.contains(entity.kind) else {
                    throw CarryGraphMigrationFailure.invalidGraph
                }
                descendants[parentID, default: [:]][entity.kind, default: []].append(entity)
            } else if !["trip", "libraryItem"].contains(entity.kind) { throw CarryGraphMigrationFailure.invalidGraph }
        }
        var used: Set<UUID> = []
        var visited: Set<UUID> = []
        var backgroundImages: [String: Data] = [:]
        var attachmentFiles: [String: Data] = [:]
        func bytes(entity: UUID, id: UUID, slot: String) throws -> Data {
            guard let asset = assetMap[id], asset.entityID == entity, asset.slot == slot else {
                throw CarryGraphMigrationFailure.missingAsset
            }
            used.insert(id)
            return asset.bytes
        }
        func put(_ data: Data, name: String, into dictionary: inout [String: Data]) throws {
            guard safeName(name), dictionary[name] == nil || dictionary[name] == data else { throw CarryGraphMigrationFailure.invalidAsset }
            dictionary[name] = data
        }
        func rebuild(_ entity: CarryGraphEntity) throws -> CarryGraphValue {
            guard visited.insert(entity.id).inserted else { throw CarryGraphMigrationFailure.invalidGraph }
            var object = entity.fields
            object["id"] = .string(entity.id.uuidString)
            for (key, childKind) in children[entity.kind] ?? [:] {
                let nested = descendants[entity.id]?[childKind] ?? []
                if !(packet.relations[entity.id] ?? []).contains(key) {
                    guard nested.isEmpty else { throw CarryGraphMigrationFailure.invalidGraph }
                } else { object[key] = .array(try nested.map(rebuild)) }
            }
            if entity.kind == "photo" || entity.kind == "attachment" {
                if let raw = string(object.removeValue(forKey: "thumbnailAssetID")), let id = UUID(uuidString: raw) {
                    object["thumbnailData"] = .string(try bytes(entity: entity.id, id: id, slot: "thumbnail").base64EncodedString())
                } else if entity.kind == "photo" { throw CarryGraphMigrationFailure.missingAsset }
                else { object["thumbnailData"] = .string("") }
            }
            if entity.kind == "attachment", let name = string(object["fileName"]), !name.isEmpty {
                guard let raw = string(object.removeValue(forKey: "fileAssetID")), let id = UUID(uuidString: raw) else {
                    throw CarryGraphMigrationFailure.missingAsset
                }
                try put(bytes(entity: entity.id, id: id, slot: "file"), name: name, into: &attachmentFiles)
            }
            if entity.kind == "trip", let raw = string(object["backgroundsData"]), !raw.isEmpty {
                guard let data = Data(base64Encoded: raw) else { throw CarryGraphMigrationFailure.invalidAsset }
                let backgrounds = try JSONDecoder().decode([TripBackgroundEntry].self, from: data)
                for name in Set(backgrounds.compactMap(\.localFileName)) {
                    guard let asset = assetsBySlot[entity.id]?["background:\(name)"] else {
                        throw CarryGraphMigrationFailure.missingAsset
                    }
                    try put(bytes(entity: entity.id, id: asset.id, slot: "background:\(name)"), name: name, into: &backgroundImages)
                }
            }
            return .object(object)
        }
        let trips = try packet.entities.filter { $0.kind == "trip" && $0.parentID == nil }.map(rebuild)
        let library = try packet.entities.filter { $0.kind == "libraryItem" && $0.parentID == nil }.map(rebuild)
        guard visited.count == packet.entities.count, used.count == packet.assets.count else { throw CarryGraphMigrationFailure.invalidGraph }
        var object: [String: CarryGraphValue] = [
            "version": .integer(Int64(packet.backupVersion)), "createdAt": .string(ISO8601DateFormatter().string(from: packet.createdAt)),
            "trips": .array(trips), "myItems": .array(library),
            "backgroundImages": .object(backgroundImages.mapValues { .string($0.base64EncodedString()) }),
            "attachmentFiles": .object(attachmentFiles.mapValues { .string($0.base64EncodedString()) })
        ]
        if let offsets = packet.defaultReminderOffsets { object["defaultReminderOffsets"] = .array(offsets.map { .integer(Int64($0)) }) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(CarryBackup.self, from: encoder().encode(CarryGraphValue.object(object)))
        let checked = try prepare(restored, accountID: accountID, migrationID: packet.migrationID,
            tripIDs: Set(restored.trips.map(\.id)), includeLibrary: true, includeReminderPreferences: true)
        let checkedEntities = Dictionary(uniqueKeysWithValues: checked.entities.map { ($0.id, $0) })
        let checkedAssets = Dictionary(uniqueKeysWithValues: checked.assets.map { ($0.id, $0) })
        guard checkedEntities.count == entities.count, packet.entities.allSatisfy({ entity in
            guard let checked = checkedEntities[entity.id] else { return false }
            return checked.kind == entity.kind && checked.parentID == entity.parentID && checked.fields == entity.fields
        }) else { throw CarryGraphMigrationFailure.invalidGraph }
        guard checkedAssets.count == packet.assets.count, packet.assets.allSatisfy({ asset in
            guard let checked = checkedAssets[asset.id] else { return false }
            return checked.entityID == asset.entityID && checked.slot == asset.slot
                && checked.fileName == asset.fileName && checked.sha256 == asset.sha256
        }) else { throw CarryGraphMigrationFailure.invalidAsset }
        return restored
    }
}
