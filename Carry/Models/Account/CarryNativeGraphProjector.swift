import Foundation
import SwiftData

@Model
final class CarryNativeProjectionCheckpoint {
    @Attribute(.unique) var id: UUID
    var desiredData: Data
    init(id: UUID, desiredData: Data) { self.id = id; self.desiredData = desiredData }
}
nonisolated struct CarryNativeProjectionEntity: Sendable {
    let local: CarryGraphEntity
    /// Authenticated server state, never the local overlay. Nil only before a create ACK.
    let observed: CarryGraphEntity?
}
nonisolated struct CarryNativeProjectionAssets: Sendable {
    var localFileName: String? = nil
    var originalFileName: String? = nil
    var thumbnailData: Data? = nil
    var backgroundsData: Data? = nil
    /// Resolver certifies these references already have verified private bytes.
    var readyAssetIDs: Set<UUID> = []
}
nonisolated struct CarryNativeProjectionResult: Sendable {
    let changedTripIDs: Set<UUID>
    let libraryChanged: Bool
}
enum CarryNativeProjectionFailure: Error {
    case invalidGraph, pendingNativeChanges, dirtyContext, accountMismatch, assetUnavailable
}

/// Accepts a complete graph round only. Individual network pages belong to the
/// replica. Existing SwiftData objects keep their identity across projections.
@MainActor
final class CarryNativeGraphProjector {
    static let models: [any PersistentModel.Type] = [CarryNativeProjectionCheckpoint.self]
    typealias ResolveAssets = (CarryGraphEntity, CarryNativeEntitySource?) throws -> CarryNativeProjectionAssets
    private struct Desired: Codable, Equatable {
        let id: UUID
        let kind: String
        let parentID: UUID?
        let fields: [String: CarryGraphValue]
        let deleted: Bool
        init(_ entity: CarryGraphEntity) {
            id = entity.id; kind = entity.kind; parentID = entity.parentID; fields = entity.fields; deleted = entity.deletedAt != nil
        }
    }
    private let accountID: UUID
    private let resolveAssets: ResolveAssets
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = .sortedKeys; return value }()
    private let decoder = JSONDecoder()
    private static let parents: [String: Set<String>] = ["trip": [], "libraryItem": [], "section": ["trip"], "packingItem": ["section"],
        "day": ["trip"], "stop": ["day"], "transport": ["day"], "lodging": ["trip"], "photo": ["stop"], "attachment": ["stop", "transport", "lodging"]]
    private static let rank = ["trip": 0, "libraryItem": 0, "section": 1, "day": 1, "lodging": 1, "packingItem": 2, "stop": 2, "transport": 2, "photo": 3, "attachment": 3]
    private static let assetKeys: Set<String> = ["fileName", "fileAssetID", "thumbnailAssetID", "backgroundsData", "backgroundAssetIDs", "originalAssetID", "assetLocalIdentifier"]

    init(accountID: UUID, resolveAssets: ResolveAssets? = nil) {
        self.accountID = accountID
        // Default arguments are evaluated outside this actor. Construct the
        // synchronous cache resolver here, inside the projector's actor instead.
        self.resolveAssets = resolveAssets ?? { entity, _ in
            if try CarryNativeGraphProjector.needsAssets(entity) { throw CarryNativeProjectionFailure.assetUnavailable }
            return CarryNativeProjectionAssets()
        }
    }

    /// candidateIDs comes from the replica's durable dirty set, including
    /// tombstones. Nil is an explicit full comparison (bootstrap/recovery).
    func project(snapshot: [CarryNativeProjectionEntity], candidateIDs: Set<UUID>? = nil, in context: ModelContext,
                 save: CarryPersistence.Save = { try $0.save() }) throws -> CarryNativeProjectionResult {
        guard !context.hasChanges else { throw CarryNativeProjectionFailure.dirtyContext }
        guard context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else { throw CarryNativeProjectionFailure.invalidGraph }
        let owners = try context.fetch(FetchDescriptor<CarryNativeJournalOwner>()), replicas = try context.fetch(FetchDescriptor<CarryReplicaCheckpoint>())
        guard owners.count <= 1, replicas.count <= 1, owners.allSatisfy({ $0.accountID == accountID }), replicas.allSatisfy({ $0.accountID == accountID }) else {
            throw CarryNativeProjectionFailure.accountMismatch
        }
        var pending = FetchDescriptor<CarryNativeChange>(); pending.fetchLimit = 1
        var transactions = FetchDescriptor<CarryNativeTransaction>(); transactions.fetchLimit = 1
        guard try context.fetch(pending).isEmpty, try context.fetch(transactions).isEmpty else { throw CarryNativeProjectionFailure.pendingNativeChanges }
        var graph: [UUID: CarryNativeProjectionEntity] = [:]
        for entry in snapshot {
            let local = entry.local
            guard Self.parents[local.kind] != nil, graph.updateValue(entry, forKey: local.id) == nil else { throw CarryNativeProjectionFailure.invalidGraph }
            if let observed = entry.observed {
                guard observed.id == local.id, observed.kind == local.kind, observed.version > 0, observed.subtreeVersion > 0 else { throw CarryNativeProjectionFailure.invalidGraph }
            } else if local.version != 0 { throw CarryNativeProjectionFailure.invalidGraph }
        }
        for entry in snapshot where entry.local.deletedAt == nil {
            let local = entry.local
            if let parentID = local.parentID {
                guard let parent = graph[parentID]?.local, parent.deletedAt == nil, Self.parents[local.kind]?.contains(parent.kind) == true else { throw CarryNativeProjectionFailure.invalidGraph }
            } else if Self.parents[local.kind]?.isEmpty != true { throw CarryNativeProjectionFailure.invalidGraph }
        }
        var native = try nativeModels(context)
        for (id, model) in native {
            guard let entry = graph[id], try CarryNativeSourceCodec.identity(of: model)?.kind == entry.local.kind else { throw CarryNativeProjectionFailure.invalidGraph }
        }
        let baselines = try indexed(context.fetch(FetchDescriptor<CarryNativeMaterialization>()), id: { $0.id })
        let checkpoints = try indexed(context.fetch(FetchDescriptor<CarryNativeProjectionCheckpoint>()), id: { $0.id })
        var candidates = candidateIDs ?? Set(graph.keys)
        guard candidates.isSubset(of: Set(graph.keys)) else { throw CarryNativeProjectionFailure.invalidGraph }
        for entry in snapshot where checkpoints[entry.local.id] == nil || baselines[entry.local.id] == nil
            || (entry.local.deletedAt == nil && native[entry.local.id] == nil) {
            candidates.insert(entry.local.id)
        }
        var desiredBytes: [UUID: Data] = [:], changed: Set<UUID> = [], assets: [UUID: CarryNativeProjectionAssets] = [:]
        // Validate changed values and resolve immutable assets before modifying UI models.
        for entry in snapshot where candidates.contains(entry.local.id) {
            let local = entry.local, bytes = try encoder.encode(Desired(local))
            desiredBytes[local.id] = bytes
            guard checkpoints[local.id]?.desiredData != bytes || baselines[local.id] == nil
                || (local.deletedAt == nil && native[local.id] == nil) else { continue }
            changed.insert(local.id)
            guard local.deletedAt == nil else { continue }
            try applyFields(local.fields, to: make(local))
            let old = try checkpoints[local.id].map { try decoder.decode(Desired.self, from: $0.desiredData) }
            if Self.assetKeys.contains(where: { old?.fields[$0] != local.fields[$0] }) || native[local.id] == nil {
                let existing = try baselines[local.id].map { row in
                    CarryNativeEntitySource(metadata: try decoder.decode(CarryNativeSourceMetadata.self, from: row.sourceData), thumbnailData: row.thumbnailData)
                }
                let resolved = try resolveAssets(local, existing)
                try Self.validateAssets(resolved, for: local)
                assets[local.id] = resolved
            }
        }
        var affectedTrips: Set<UUID> = [], actuallyChanged: Set<UUID> = []
        var previousSources: [UUID: CarryNativeEntitySource] = [:], previousRoots: [UUID: UUID] = [:]
        for id in changed {
            if let model = native[id], let source = try CarryNativeSourceCodec.capture(model) { previousSources[id] = source }
            if let root = try tripID(id, using: native) { previousRoots[id] = root }
        }
        var projectedSources: [UUID: CarryNativeEntitySource] = [:]
        let ordered = snapshot.filter { candidates.contains($0.local.id) }.sorted {
            let a = Self.rank[$0.local.kind] ?? 99, b = Self.rank[$1.local.kind] ?? 99
            return a == b ? $0.local.id.uuidString < $1.local.id.uuidString : a < b
        }
        try CarryPersistence.commit(context, using: { transaction in
            if owners.isEmpty { transaction.insert(CarryNativeJournalOwner(accountID: accountID)) }
            for entry in ordered where entry.local.deletedAt == nil && native[entry.local.id] == nil {
                let model = try make(entry.local); transaction.insert(model); native[entry.local.id] = model
            }
            for entry in ordered where entry.local.deletedAt == nil && changed.contains(entry.local.id) {
                guard let model = native[entry.local.id] else { throw CarryNativeProjectionFailure.invalidGraph }
                var fields = entry.local.fields
                if let resolved = assets[entry.local.id] {
                    if let name = resolved.localFileName { fields["fileName"] = .string(name) }
                    if entry.local.kind == "photo" { fields["assetLocalIdentifier"] = .string(resolved.originalFileName ?? "") }
                    if let data = resolved.backgroundsData { fields["backgroundsData"] = .string(data.base64EncodedString()) }
                }
                if assets[entry.local.id] == nil {
                    if let attachment = model as? ItineraryAttachment { fields["fileName"] = .string(attachment.fileName) }
                    if let trip = model as? TripBundle { fields["backgroundsData"] = .string(trip.backgroundsData.base64EncodedString()) }
                    if let photo = model as? StopPhoto { fields["assetLocalIdentifier"] = .string(photo.assetLocalIdentifier) }
                }
                try applyFields(fields, to: model)
                try assignParent(entry.local, to: model, using: native)
                if let resolved = assets[entry.local.id] {
                    let data = resolved.thumbnailData ?? Data()
                    if let photo = model as? StopPhoto, photo.thumbnailData != data { photo.thumbnailData = data }
                    if let attachment = model as? ItineraryAttachment, attachment.thumbnailData != data { attachment.thumbnailData = data }
                }
                guard let source = try CarryNativeSourceCodec.capture(model) else { throw CarryNativeProjectionFailure.invalidGraph }
                projectedSources[entry.local.id] = source
                if previousSources[entry.local.id]?.metadata != source.metadata || previousSources[entry.local.id]?.thumbnailData != source.thumbnailData {
                    actuallyChanged.insert(entry.local.id)
                    if let root = previousRoots[entry.local.id] { affectedTrips.insert(root) }
                    if let root = try tripID(entry.local.id, using: native) { affectedTrips.insert(root) }
                }
            }
            // Relationships of surviving children are fixed before parent cascades.
            for entry in ordered.reversed() where entry.local.deletedAt != nil {
                if let model = native[entry.local.id] {
                    actuallyChanged.insert(entry.local.id)
                    if let root = previousRoots[entry.local.id] { affectedTrips.insert(root) }
                    transaction.delete(model)
                }
            }
            for entry in ordered where candidates.contains(entry.local.id) {
                let local = entry.local, row: CarryNativeMaterialization
                let observed = try entry.observed.map(encoder.encode)
                if let existing = baselines[local.id] { row = existing }
                else {
                    let metadata = CarryNativeSourceMetadata(id: local.id, kind: local.kind, parentID: local.parentID, fields: [:], fileReferences: [:])
                    row = CarryNativeMaterialization(source: CarryNativeEntitySource(metadata: metadata, thumbnailData: nil), sourceData: try encoder.encode(metadata))
                    transaction.insert(row)
                }
                if local.deletedAt == nil, changed.contains(local.id) {
                    guard let source = projectedSources[local.id] else { throw CarryNativeProjectionFailure.invalidGraph }
                    let bytes = try encoder.encode(source.metadata)
                    if row.sourceData != bytes { row.sourceData = bytes }
                    if row.thumbnailData != source.thumbnailData { row.thumbnailData = source.thumbnailData }
                }
                if row.observedGraphData != observed { row.observedGraphData = observed }
                if row.locallyDeleted != (local.deletedAt != nil) { row.locallyDeleted = local.deletedAt != nil }
                guard let bytes = desiredBytes[local.id] else { throw CarryNativeProjectionFailure.invalidGraph }
                if let checkpoint = checkpoints[local.id] {
                    if checkpoint.desiredData != bytes { checkpoint.desiredData = bytes }
                } else { transaction.insert(CarryNativeProjectionCheckpoint(id: local.id, desiredData: bytes)) }
            }
            try save(transaction)
        })
        return CarryNativeProjectionResult(changedTripIDs: affectedTrips, libraryChanged: snapshot.contains { actuallyChanged.contains($0.local.id) && $0.local.kind == "libraryItem" })
    }
    private func tripID(_ id: UUID, using models: [UUID: any PersistentModel]) throws -> UUID? {
        guard var model = models[id] else { return nil }
        var seen: Set<UUID> = []
        while let identity = try CarryNativeSourceCodec.identity(of: model) {
            guard seen.insert(identity.id).inserted else { throw CarryNativeProjectionFailure.invalidGraph }
            if identity.kind == "trip" { return identity.id }
            if identity.kind == "libraryItem" { return nil }
            let parentID: UUID?
            switch model {
            case let value as PackingSection: parentID = value.bundle?.id
            case let value as PackingItem: parentID = value.section?.id
            case let value as ItineraryDay: parentID = value.bundle?.id
            case let value as ItineraryStop: parentID = value.day?.id
            case let value as TransportSegment: parentID = value.day?.id
            case let value as LodgingStay: parentID = value.bundle?.id
            case let value as StopPhoto: parentID = value.stop?.id
            case let value as ItineraryAttachment: parentID = value.stop?.id ?? value.segment?.id ?? value.stay?.id
            default: throw CarryNativeProjectionFailure.invalidGraph
            }
            guard let parentID, let parent = models[parentID] else { throw CarryNativeProjectionFailure.invalidGraph }; model = parent
        }
        throw CarryNativeProjectionFailure.invalidGraph
    }
    private func indexed<T>(_ values: [T], id: (T) -> UUID) throws -> [UUID: T] {
        var result: [UUID: T] = [:]
        for value in values { guard result.updateValue(value, forKey: id(value)) == nil else { throw CarryNativeProjectionFailure.invalidGraph } }
        return result
    }
    private func nativeModels(_ context: ModelContext) throws -> [UUID: any PersistentModel] {
        var result: [UUID: any PersistentModel] = [:]
        func add<T: PersistentModel>(_ type: T.Type) throws {
            for model in try context.fetch(FetchDescriptor<T>()) {
                guard let identity = try CarryNativeSourceCodec.identity(of: model), result.updateValue(model, forKey: identity.id) == nil else { throw CarryNativeProjectionFailure.invalidGraph }
            }
        }
        try add(TripBundle.self); try add(PackingSection.self); try add(PackingItem.self); try add(ItineraryDay.self)
        try add(ItineraryStop.self); try add(TransportSegment.self); try add(LodgingStay.self); try add(StopPhoto.self); try add(ItineraryAttachment.self); try add(MyItem.self)
        return result
    }
    private func make(_ entity: CarryGraphEntity) throws -> any PersistentModel {
        switch entity.kind {
        case "trip": return TripBundle(id: entity.id, name: "", destinationCity: "", days: 0, dateRange: "")
        case "section": let value = PackingSection(); value.id = entity.id; return value
        case "packingItem": let value = PackingItem(); value.id = entity.id; return value
        case "day": let value = ItineraryDay(); value.id = entity.id; return value
        case "stop": let value = ItineraryStop(); value.id = entity.id; return value
        case "transport": let value = TransportSegment(); value.id = entity.id; return value
        case "lodging": let value = LodgingStay(); value.id = entity.id; return value
        case "photo": let value = StopPhoto(); value.id = entity.id; return value
        case "attachment": let value = ItineraryAttachment(); value.id = entity.id; return value
        case "libraryItem": return MyItem(id: entity.id, name: "", category: "")
        default: throw CarryNativeProjectionFailure.invalidGraph
        }
    }
    private func assignParent(_ entity: CarryGraphEntity, to model: any PersistentModel, using models: [UUID: any PersistentModel]) throws {
        let parent = entity.parentID.flatMap { models[$0] }
        switch model {
        case let value as PackingSection: if value.bundle?.id != entity.parentID { value.bundle = parent as? TripBundle }
        case let value as PackingItem: if value.section?.id != entity.parentID { value.section = parent as? PackingSection }
        case let value as ItineraryDay: if value.bundle?.id != entity.parentID { value.bundle = parent as? TripBundle }
        case let value as ItineraryStop: if value.day?.id != entity.parentID { value.day = parent as? ItineraryDay }
        case let value as TransportSegment: if value.day?.id != entity.parentID { value.day = parent as? ItineraryDay }
        case let value as LodgingStay: if value.bundle?.id != entity.parentID { value.bundle = parent as? TripBundle }
        case let value as StopPhoto: if value.stop?.id != entity.parentID { value.stop = parent as? ItineraryStop }
        case let value as ItineraryAttachment:
            if value.stop?.id != (parent as? ItineraryStop)?.id { value.stop = parent as? ItineraryStop }
            if value.segment?.id != (parent as? TransportSegment)?.id { value.segment = parent as? TransportSegment }
            if value.stay?.id != (parent as? LodgingStay)?.id { value.stay = parent as? LodgingStay }
        case is TripBundle, is MyItem: break
        default: throw CarryNativeProjectionFailure.invalidGraph
        }
    }
    private static func needsAssets(_ entity: CarryGraphEntity) throws -> Bool {
        for key in ["fileAssetID", "thumbnailAssetID", "originalAssetID", "backgroundAssetIDs"] {
            if let value = entity.fields[key], value != .null, value != .string(""), value != .object([:]) { return true }
        }
        if case .string(let name) = entity.fields["fileName"], !name.isEmpty { return true }
        if let raw = entity.fields["backgroundsData"] {
            let bytes = try data(raw)
            if !bytes.isEmpty, try JSONDecoder().decode([TripBackgroundEntry].self, from: bytes).contains(where: { $0.localFileName != nil }) { return true }
        }
        return false
    }
    private static func validateAssets(_ assets: CarryNativeProjectionAssets, for entity: CarryGraphEntity) throws {
        func references(_ value: CarryGraphValue) throws -> Set<UUID> {
            switch value {
            case .null: return []
            case .string(let raw):
                if raw.isEmpty { return [] }
                guard let id = UUID(uuidString: raw) else { throw CarryNativeProjectionFailure.invalidGraph }; return [id]
            case .array(let values): return try values.reduce(into: Set<UUID>()) { $0.formUnion(try references($1)) }
            case .object(let values): return try values.values.reduce(into: Set<UUID>()) { $0.formUnion(try references($1)) }
            default: throw CarryNativeProjectionFailure.invalidGraph
            }
        }
        for key in ["fileAssetID", "thumbnailAssetID", "originalAssetID", "backgroundAssetIDs"] {
            if let value = entity.fields[key], !(try references(value)).isSubset(of: assets.readyAssetIDs) { throw CarryNativeProjectionFailure.assetUnavailable }
        }
        func safeName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 && !name.contains("/") && !name.contains("\\") && !name.contains("\0") }
        if let name = assets.localFileName, !safeName(name) { throw CarryNativeProjectionFailure.invalidGraph }
        if let name = assets.originalFileName, !safeName(name) { throw CarryNativeProjectionFailure.invalidGraph }
        if let reference = entity.fields["originalAssetID"], reference != .null, reference != .string(""), assets.originalFileName == nil {
            throw CarryNativeProjectionFailure.assetUnavailable
        }
        if let bytes = assets.backgroundsData, !bytes.isEmpty {
            for background in try JSONDecoder().decode([TripBackgroundEntry].self, from: bytes) {
                if let name = background.localFileName, !safeName(name) { throw CarryNativeProjectionFailure.invalidGraph }
            }
        }
        if let value = entity.fields["thumbnailAssetID"], value != .null, value != .string(""), assets.thumbnailData == nil { throw CarryNativeProjectionFailure.assetUnavailable }
        if case .string(let name) = entity.fields["fileName"], !name.isEmpty, assets.localFileName == nil { throw CarryNativeProjectionFailure.assetUnavailable }
        if let reference = entity.fields["fileAssetID"], reference != .null, reference != .string(""), assets.localFileName == nil { throw CarryNativeProjectionFailure.assetUnavailable }
        if let raw = entity.fields["backgroundsData"] {
            let bytes = try data(raw)
            if !bytes.isEmpty, try JSONDecoder().decode([TripBackgroundEntry].self, from: bytes).contains(where: { $0.localFileName != nil }), assets.backgroundsData == nil { throw CarryNativeProjectionFailure.assetUnavailable }
        }
    }
    private func set<T: AnyObject, V: Equatable>(_ fields: [String: CarryGraphValue], _ key: String, on model: T,
        at path: ReferenceWritableKeyPath<T, V>, decode: (CarryGraphValue) throws -> V) throws {
        if let raw = fields[key] { let value = try decode(raw); if model[keyPath: path] != value { model[keyPath: path] = value } }
    }
    private static func string(_ value: CarryGraphValue) throws -> String {
        guard case .string(let text) = value else { throw CarryNativeProjectionFailure.invalidGraph }; return text
    }
    private static func integer(_ value: CarryGraphValue) throws -> Int {
        guard case .integer(let raw) = value, let result = Int(exactly: raw) else { throw CarryNativeProjectionFailure.invalidGraph }; return result
    }
    private static func number(_ value: CarryGraphValue) throws -> Double {
        let result: Double
        switch value { case .number(let raw): result = raw; case .integer(let raw): result = Double(raw); default: throw CarryNativeProjectionFailure.invalidGraph }
        guard result.isFinite else { throw CarryNativeProjectionFailure.invalidGraph }; return result
    }
    private static func boolean(_ value: CarryGraphValue) throws -> Bool {
        guard case .bool(let flag) = value else { throw CarryNativeProjectionFailure.invalidGraph }; return flag
    }
    private static func data(_ value: CarryGraphValue) throws -> Data {
        if value == .null { return Data() }
        guard let bytes = Data(base64Encoded: try string(value)) else { throw CarryNativeProjectionFailure.invalidGraph }; return bytes
    }
    private static func date(_ value: CarryGraphValue) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: try string(value)) else { throw CarryNativeProjectionFailure.invalidGraph }; return date
    }
    private static func strings(_ value: CarryGraphValue) throws -> [String] {
        guard case .array(let array) = value else { throw CarryNativeProjectionFailure.invalidGraph }; return try array.map(string)
    }
    private func applyFields(_ fields: [String: CarryGraphValue], to model: any PersistentModel) throws {
        switch model {
        case let model as TripBundle:
            try set(fields, "name", on: model, at: \.name, decode: Self.string)
            try set(fields, "destinationCity", on: model, at: \.destinationCity, decode: Self.string)
            try set(fields, "days", on: model, at: \.days, decode: Self.integer)
            try set(fields, "dateRange", on: model, at: \.dateRange, decode: Self.string)
            try set(fields, "departureDate", on: model, at: \.departureDate, decode: Self.date)
            try set(fields, "isDateless", on: model, at: \.isDateless, decode: Self.boolean)
            try set(fields, "createdAt", on: model, at: \.createdAt, decode: Self.date)
            try set(fields, "selectedSceneKeys", on: model, at: \.selectedSceneKeys, decode: Self.strings)
            try set(fields, "dismissedSurpriseNames", on: model, at: \.dismissedSurpriseNames, decode: Self.strings)
            try set(fields, "sceneCardDismissed", on: model, at: \.sceneCardDismissed, decode: Self.boolean)
            try set(fields, "remindersEnabled", on: model, at: \.remindersEnabled, decode: Self.boolean)
            try set(fields, "reminderConfigData", on: model, at: \.reminderConfigData, decode: Self.data)
            try set(fields, "additionalDestinationsData", on: model, at: \.additionalDestinationsData, decode: Self.data)
            try set(fields, "backgroundsData", on: model, at: \.backgroundsData, decode: Self.data)
            try set(fields, "countryCode", on: model, at: \.countryCode, decode: Self.string)
            try set(fields, "latitude", on: model, at: \.latitude, decode: Self.number)
            try set(fields, "longitude", on: model, at: \.longitude, decode: Self.number)
        case let model as PackingSection:
            try set(fields, "title", on: model, at: \.title, decode: Self.string)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
        case let model as PackingItem:
            try set(fields, "name", on: model, at: \.name, decode: Self.string)
            try set(fields, "quantity", on: model, at: \.quantity, decode: Self.integer)
            try set(fields, "isPacked", on: model, at: \.isPacked, decode: Self.boolean)
            try set(fields, "isAlert", on: model, at: \.isAlert, decode: Self.boolean)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
        case let model as ItineraryDay:
            try set(fields, "title", on: model, at: \.title, decode: Self.string)
            try set(fields, "note", on: model, at: \.note, decode: Self.string)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
        case let model as ItineraryStop:
            try set(fields, "name", on: model, at: \.name, decode: Self.string)
            try set(fields, "latitude", on: model, at: \.latitude, decode: Self.number)
            try set(fields, "longitude", on: model, at: \.longitude, decode: Self.number)
            try set(fields, "address", on: model, at: \.address, decode: Self.string)
            try set(fields, "categoryRaw", on: model, at: \.categoryRaw, decode: Self.string)
            try set(fields, "plannedStartMinutes", on: model, at: \.plannedStartMinutes, decode: Self.integer)
            try set(fields, "stayMinutes", on: model, at: \.stayMinutes, decode: Self.integer)
            try set(fields, "note", on: model, at: \.note, decode: Self.string)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
            try set(fields, "fromPhotos", on: model, at: \.fromPhotos, decode: Self.boolean)
            try set(fields, "phone", on: model, at: \.phone, decode: Self.string)
            try set(fields, "timeZoneId", on: model, at: \.timeZoneId, decode: Self.string)
            try set(fields, "costAmount", on: model, at: \.costAmount, decode: Self.number)
            try set(fields, "costCurrencyCode", on: model, at: \.costCurrencyCode, decode: Self.string)
            try set(fields, "costHomeAmount", on: model, at: \.costHomeAmount, decode: Self.number)
        case let model as TransportSegment:
            try set(fields, "modeRaw", on: model, at: \.modeRaw, decode: Self.string)
            try set(fields, "carrier", on: model, at: \.carrier, decode: Self.string)
            try set(fields, "number", on: model, at: \.number, decode: Self.string)
            try set(fields, "fromName", on: model, at: \.fromName, decode: Self.string)
            try set(fields, "fromCode", on: model, at: \.fromCode, decode: Self.string)
            try set(fields, "fromTerminal", on: model, at: \.fromTerminal, decode: Self.string)
            try set(fields, "fromLatitude", on: model, at: \.fromLatitude, decode: Self.number)
            try set(fields, "fromLongitude", on: model, at: \.fromLongitude, decode: Self.number)
            try set(fields, "fromTimeZoneId", on: model, at: \.fromTimeZoneId, decode: Self.string)
            try set(fields, "toName", on: model, at: \.toName, decode: Self.string)
            try set(fields, "toCode", on: model, at: \.toCode, decode: Self.string)
            try set(fields, "toTerminal", on: model, at: \.toTerminal, decode: Self.string)
            try set(fields, "toLatitude", on: model, at: \.toLatitude, decode: Self.number)
            try set(fields, "toLongitude", on: model, at: \.toLongitude, decode: Self.number)
            try set(fields, "toTimeZoneId", on: model, at: \.toTimeZoneId, decode: Self.string)
            try set(fields, "departDayOrder", on: model, at: \.departDayOrder, decode: Self.integer)
            try set(fields, "departLocalMinutes", on: model, at: \.departLocalMinutes, decode: Self.integer)
            try set(fields, "arriveDayOrder", on: model, at: \.arriveDayOrder, decode: Self.integer)
            try set(fields, "arriveLocalMinutes", on: model, at: \.arriveLocalMinutes, decode: Self.integer)
            try set(fields, "seat", on: model, at: \.seat, decode: Self.string)
            try set(fields, "confirmationCode", on: model, at: \.confirmationCode, decode: Self.string)
            try set(fields, "note", on: model, at: \.note, decode: Self.string)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
            try set(fields, "aircraftType", on: model, at: \.aircraftType, decode: Self.string)
            try set(fields, "cabinClass", on: model, at: \.cabinClass, decode: Self.string)
            try set(fields, "eticketNumber", on: model, at: \.eticketNumber, decode: Self.string)
            try set(fields, "routeName", on: model, at: \.routeName, decode: Self.string)
            try set(fields, "coachNumber", on: model, at: \.coachNumber, decode: Self.string)
            try set(fields, "seatClass", on: model, at: \.seatClass, decode: Self.string)
            try set(fields, "serviceType", on: model, at: \.serviceType, decode: Self.string)
            try set(fields, "vehicleModel", on: model, at: \.vehicleModel, decode: Self.string)
            try set(fields, "licensePlate", on: model, at: \.licensePlate, decode: Self.string)
            try set(fields, "fromAddress", on: model, at: \.fromAddress, decode: Self.string)
            try set(fields, "toAddress", on: model, at: \.toAddress, decode: Self.string)
            try set(fields, "phone", on: model, at: \.phone, decode: Self.string)
            try set(fields, "distanceMeters", on: model, at: \.distanceMeters, decode: Self.number)
            try set(fields, "durationMinutes", on: model, at: \.durationMinutes, decode: Self.integer)
            try set(fields, "remindersMuted", on: model, at: \.remindersMuted, decode: Self.boolean)
            try set(fields, "costAmount", on: model, at: \.costAmount, decode: Self.number)
            try set(fields, "costCurrencyCode", on: model, at: \.costCurrencyCode, decode: Self.string)
            try set(fields, "costHomeAmount", on: model, at: \.costHomeAmount, decode: Self.number)
        case let model as LodgingStay:
            try set(fields, "name", on: model, at: \.name, decode: Self.string)
            try set(fields, "address", on: model, at: \.address, decode: Self.string)
            try set(fields, "latitude", on: model, at: \.latitude, decode: Self.number)
            try set(fields, "longitude", on: model, at: \.longitude, decode: Self.number)
            try set(fields, "checkInDayOrder", on: model, at: \.checkInDayOrder, decode: Self.integer)
            try set(fields, "nights", on: model, at: \.nights, decode: Self.integer)
            try set(fields, "checkInMinutes", on: model, at: \.checkInMinutes, decode: Self.integer)
            try set(fields, "checkOutMinutes", on: model, at: \.checkOutMinutes, decode: Self.integer)
            try set(fields, "confirmationCode", on: model, at: \.confirmationCode, decode: Self.string)
            try set(fields, "note", on: model, at: \.note, decode: Self.string)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
            try set(fields, "phone", on: model, at: \.phone, decode: Self.string)
            try set(fields, "timeZoneId", on: model, at: \.timeZoneId, decode: Self.string)
            try set(fields, "remindersMuted", on: model, at: \.remindersMuted, decode: Self.boolean)
            try set(fields, "costAmount", on: model, at: \.costAmount, decode: Self.number)
            try set(fields, "costCurrencyCode", on: model, at: \.costCurrencyCode, decode: Self.string)
            try set(fields, "costHomeAmount", on: model, at: \.costHomeAmount, decode: Self.number)
        case let model as StopPhoto:
            try set(fields, "assetLocalIdentifier", on: model, at: \.assetLocalIdentifier, decode: Self.string)
            try set(fields, "timestamp", on: model, at: \.timestamp, decode: Self.date)
            try set(fields, "latitude", on: model, at: \.latitude, decode: Self.number)
            try set(fields, "longitude", on: model, at: \.longitude, decode: Self.number)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
        case let model as ItineraryAttachment:
            try set(fields, "kindRaw", on: model, at: \.kindRaw, decode: Self.string)
            try set(fields, "displayName", on: model, at: \.displayName, decode: Self.string)
            try set(fields, "fileName", on: model, at: \.fileName, decode: Self.string)
            try set(fields, "utiOrExt", on: model, at: \.utiOrExt, decode: Self.string)
            try set(fields, "urlString", on: model, at: \.urlString, decode: Self.string)
            try set(fields, "addedAt", on: model, at: \.addedAt, decode: Self.date)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
        case let model as MyItem:
            try set(fields, "name", on: model, at: \.name, decode: Self.string)
            try set(fields, "collectionName", on: model, at: \.collectionName, decode: Self.string)
            try set(fields, "category", on: model, at: \.category, decode: Self.string)
            try set(fields, "defaultQuantity", on: model, at: \.defaultQuantity, decode: Self.integer)
            try set(fields, "quantityModeRaw", on: model, at: \.quantityModeRaw, decode: Self.string)
            try set(fields, "quantityIntervalDays", on: model, at: \.quantityIntervalDays, decode: Self.integer)
            try set(fields, "sortOrder", on: model, at: \.sortOrder, decode: Self.integer)
            try set(fields, "createdAt", on: model, at: \.createdAt, decode: Self.date)
            try set(fields, "updatedAt", on: model, at: \.updatedAt, decode: Self.date)
        default: throw CarryNativeProjectionFailure.invalidGraph
        }
    }
}
