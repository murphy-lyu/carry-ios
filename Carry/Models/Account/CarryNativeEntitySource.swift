import Foundation
import SwiftData

nonisolated struct CarryNativeSourceMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let kind: String
    let parentID: UUID?
    var fields: [String: CarryGraphValue]
    var fileReferences: [String: String]
}

/// Small scalar snapshot plus an optional binary thumbnail. Reading an edited
/// packing item never enumerates a trip or reads/hashes any external file.
nonisolated struct CarryNativeEntitySource: Sendable {
    let metadata: CarryNativeSourceMetadata
    let thumbnailData: Data?
}

enum CarryNativeSourceFailure: Error { case missingParent, invalidFileReference, unsupportedModel }

@MainActor
enum CarryNativeSourceCodec {
    private static let dateFormatter = ISO8601DateFormatter()
    private static func date(_ value: Date) -> CarryGraphValue { .string(dateFormatter.string(from: value)) }
    private static func integer(_ value: Int) -> CarryGraphValue { .integer(Int64(value)) }
    private static func data(_ value: Data, optional: Bool = false) -> CarryGraphValue {
        optional && value.isEmpty ? .null : .string(value.base64EncodedString())
    }
    private static func cost(_ value: any CostBearing) -> [String: CarryGraphValue] {
        ["costAmount": .number(value.costAmount), "costCurrencyCode": .string(value.costCurrencyCode),
         "costHomeAmount": .number(value.costHomeAmount)]
    }
    private static func file(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw CarryNativeSourceFailure.invalidFileReference
        }
        return name
    }

    static func identity(of model: any PersistentModel) throws -> (id: UUID, kind: String)? {
        switch model {
        case let value as TripBundle: return (value.id, "trip")
        case let value as PackingSection: return (value.id, "section")
        case let value as PackingItem: return (value.id, "packingItem")
        case let value as ItineraryDay: return (value.id, "day")
        case let value as ItineraryStop: return (value.id, "stop")
        case let value as TransportSegment: return (value.id, "transport")
        case let value as LodgingStay: return (value.id, "lodging")
        case let value as StopPhoto: return (value.id, "photo")
        case let value as ItineraryAttachment: return (value.id, "attachment")
        case let value as MyItem: return (value.id, "libraryItem")
        case is AutomationExecutionRecord: return nil
        default:
            if SchemaV1.models.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(type(of: model)) }) {
                throw CarryNativeSourceFailure.unsupportedModel
            }
            return nil // Private replica/journal models are not business writes.
        }
    }

    static func capture(_ model: any PersistentModel) throws -> CarryNativeEntitySource? {
        guard let identity = try identity(of: model) else { return nil }
        var fields: [String: CarryGraphValue]
        var parent: UUID?
        var files: [String: String] = [:]
        var thumbnail: Data?
        switch model {
        case let value as TripBundle:
            fields = ["name": .string(value.name), "destinationCity": .string(value.destinationCity),
                "days": integer(value.days), "dateRange": .string(value.dateRange), "departureDate": date(value.departureDate),
                "isDateless": .bool(value.isDateless), "createdAt": date(value.createdAt),
                "selectedSceneKeys": .array(value.selectedSceneKeys.map(CarryGraphValue.string)),
                "dismissedSurpriseNames": .array(value.dismissedSurpriseNames.map(CarryGraphValue.string)),
                "sceneCardDismissed": .bool(value.sceneCardDismissed), "remindersEnabled": .bool(value.remindersEnabled),
                "reminderConfigData": data(value.reminderConfigData), "additionalDestinationsData": data(value.additionalDestinationsData, optional: true),
                "backgroundsData": data(value.backgroundsData, optional: true), "countryCode": .string(value.countryCode),
                "latitude": .number(value.latitude), "longitude": .number(value.longitude)]
            if !value.backgroundsData.isEmpty {
                let entries = try JSONDecoder().decode([TripBackgroundEntry].self, from: value.backgroundsData)
                for (index, entry) in entries.enumerated() {
                    if let name = entry.localFileName { files["background:\(entry.destinationIndex):\(index)"] = try file(name) }
                }
            }
        case let value as PackingSection:
            parent = value.bundle?.id
            fields = ["title": .string(value.title), "sortOrder": integer(value.sortOrder)]
        case let value as PackingItem:
            parent = value.section?.id
            fields = ["name": .string(value.name), "quantity": integer(value.quantity), "isPacked": .bool(value.isPacked),
                "isAlert": .bool(value.isAlert), "sortOrder": integer(value.sortOrder)]
        case let value as ItineraryDay:
            parent = value.bundle?.id
            fields = ["title": .string(value.title), "note": .string(value.note), "sortOrder": integer(value.sortOrder)]
        case let value as ItineraryStop:
            parent = value.day?.id
            fields = ["name": .string(value.name), "latitude": .number(value.latitude), "longitude": .number(value.longitude),
                "address": .string(value.address), "categoryRaw": .string(value.categoryRaw),
                "plannedStartMinutes": integer(value.plannedStartMinutes), "stayMinutes": integer(value.stayMinutes),
                "note": .string(value.note), "sortOrder": integer(value.sortOrder), "fromPhotos": .bool(value.fromPhotos),
                "phone": .string(value.phone), "timeZoneId": .string(value.timeZoneId)]
            fields.merge(cost(value)) { _, new in new }
        case let value as TransportSegment:
            parent = value.day?.id
            fields = ["modeRaw": .string(value.modeRaw), "carrier": .string(value.carrier), "number": .string(value.number),
                "fromName": .string(value.fromName), "fromCode": .string(value.fromCode), "fromTerminal": .string(value.fromTerminal),
                "fromLatitude": .number(value.fromLatitude), "fromLongitude": .number(value.fromLongitude), "fromTimeZoneId": .string(value.fromTimeZoneId),
                "toName": .string(value.toName), "toCode": .string(value.toCode), "toTerminal": .string(value.toTerminal),
                "toLatitude": .number(value.toLatitude), "toLongitude": .number(value.toLongitude), "toTimeZoneId": .string(value.toTimeZoneId),
                "departDayOrder": integer(value.departDayOrder), "departLocalMinutes": integer(value.departLocalMinutes),
                "arriveDayOrder": integer(value.arriveDayOrder), "arriveLocalMinutes": integer(value.arriveLocalMinutes),
                "seat": .string(value.seat), "confirmationCode": .string(value.confirmationCode), "note": .string(value.note),
                "sortOrder": integer(value.sortOrder), "aircraftType": .string(value.aircraftType), "cabinClass": .string(value.cabinClass),
                "eticketNumber": .string(value.eticketNumber), "routeName": .string(value.routeName), "coachNumber": .string(value.coachNumber),
                "seatClass": .string(value.seatClass), "serviceType": .string(value.serviceType), "vehicleModel": .string(value.vehicleModel),
                "licensePlate": .string(value.licensePlate), "fromAddress": .string(value.fromAddress), "toAddress": .string(value.toAddress),
                "phone": .string(value.phone), "distanceMeters": .number(value.distanceMeters), "durationMinutes": integer(value.durationMinutes),
                "remindersMuted": .bool(value.remindersMuted)]
            fields.merge(cost(value)) { _, new in new }
        case let value as LodgingStay:
            parent = value.bundle?.id
            fields = ["name": .string(value.name), "address": .string(value.address), "latitude": .number(value.latitude),
                "longitude": .number(value.longitude), "checkInDayOrder": integer(value.checkInDayOrder), "nights": integer(value.nights),
                "checkInMinutes": integer(value.checkInMinutes), "checkOutMinutes": integer(value.checkOutMinutes),
                "confirmationCode": .string(value.confirmationCode), "note": .string(value.note), "sortOrder": integer(value.sortOrder),
                "phone": .string(value.phone), "timeZoneId": .string(value.timeZoneId), "remindersMuted": .bool(value.remindersMuted)]
            fields.merge(cost(value)) { _, new in new }
        case let value as StopPhoto:
            parent = value.stop?.id
            fields = ["assetLocalIdentifier": .string(value.assetLocalIdentifier), "timestamp": date(value.timestamp),
                "latitude": .number(value.latitude), "longitude": .number(value.longitude), "sortOrder": integer(value.sortOrder)]
            thumbnail = value.thumbnailData
        case let value as ItineraryAttachment:
            let parents = [value.stop?.id, value.segment?.id, value.stay?.id].compactMap { $0 }
            guard parents.count == 1 else { throw CarryNativeSourceFailure.missingParent }
            parent = parents.first
            fields = ["kindRaw": .string(value.kindRaw), "displayName": .string(value.displayName), "fileName": .string(value.fileName),
                "utiOrExt": .string(value.utiOrExt), "urlString": .string(value.urlString), "addedAt": date(value.addedAt), "sortOrder": integer(value.sortOrder)]
            if !value.thumbnailData.isEmpty { thumbnail = value.thumbnailData }
            if !value.fileName.isEmpty { files["file"] = try file(value.fileName) }
        case let value as MyItem:
            fields = ["name": .string(value.name), "collectionName": .string(value.collectionName), "category": .string(value.category),
                "defaultQuantity": integer(value.defaultQuantity), "quantityModeRaw": .string(value.quantityModeRaw),
                "quantityIntervalDays": integer(value.quantityIntervalDays), "sortOrder": integer(value.sortOrder),
                "createdAt": date(value.createdAt), "updatedAt": date(value.updatedAt)]
        default: throw CarryNativeSourceFailure.unsupportedModel
        }
        guard identity.kind == "trip" || identity.kind == "libraryItem" || parent != nil else { throw CarryNativeSourceFailure.missingParent }
        return CarryNativeEntitySource(metadata: CarryNativeSourceMetadata(id: identity.id, kind: identity.kind,
            parentID: parent, fields: fields, fileReferences: files), thumbnailData: thumbnail)
    }
}
