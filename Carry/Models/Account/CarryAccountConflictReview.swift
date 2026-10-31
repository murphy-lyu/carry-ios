import Foundation

nonisolated enum CarryGraphConflictReviewKind: String, Codable, Sendable { case field, move, subtree }

/// A complete immutable review, not a force-write token. Replica resolution
/// recomputes it under the transaction before rebinding any user intention.
nonisolated struct CarryGraphConflictReview: Codable, Equatable, Sendable {
    typealias Kind = CarryGraphConflictReviewKind
    let requestID: UUID
    let kind: CarryGraphConflictReviewKind
    let action: String
    let local: CarryGraphEntity
    let current: CarryGraphEntity
    let fields: [String]
    let impact: [CarryGraphEntity]
}

/// No JSON blobs, device filenames, asset IDs or UUIDs are shown in the review.
/// Complex native configuration is represented by its human label and a concise
/// state; adopting either version still uses the exact full protocol value.
@MainActor
enum CarryAccountConflictPresentation {
    static func title(_ entity: CarryGraphEntity) -> String {
        for key in ["name", "title", "displayName"] {
            if case .string(let text) = entity.fields[key], !text.isEmpty { return text }
        }
        return NSLocalizedString("account.conflict.item", comment: "")
    }

    static func fieldKey(_ field: String) -> String {
        switch field {
        case "name", "title", "displayName": return "account.conflict.field.name"
        case "note": return "account.conflict.field.note"
        case "quantity", "defaultQuantity": return "account.conflict.field.quantity"
        case "isPacked": return "account.conflict.field.packed"
        case "destinationCity", "additionalDestinationsData", "countryCode": return "account.conflict.field.destination"
        case "days", "departureDate", "dateRange", "isDateless", "checkInDayOrder", "nights": return "account.conflict.field.dates"
        case "plannedStartMinutes", "stayMinutes", "departDayOrder", "departLocalMinutes", "arriveDayOrder", "arriveLocalMinutes", "checkInMinutes", "checkOutMinutes": return "account.conflict.field.time"
        case "sortOrder": return "account.conflict.field.order"
        case "costAmount", "costCurrencyCode", "costHomeAmount": return "account.conflict.field.cost"
        case "address", "fromAddress", "toAddress", "latitude", "longitude", "fromLatitude", "fromLongitude", "toLatitude", "toLongitude", "timeZoneId", "fromTimeZoneId", "toTimeZoneId": return "account.conflict.field.location"
        case "thumbnailAssetID", "fileAssetID", "originalAssetID", "fileName", "backgroundAssetIDs", "backgroundsData", "assetLocalIdentifier": return "account.conflict.field.files"
        case "remindersEnabled", "reminderConfigData", "remindersMuted": return "account.conflict.field.reminders"
        case "phone", "urlString": return "account.conflict.field.contact"
        case "confirmationCode", "eticketNumber", "seat", "coachNumber", "cabinClass", "seatClass": return "account.conflict.field.booking"
        default: return "account.conflict.field.details"
        }
    }

    static func value(_ value: CarryGraphValue?, field: String) -> String {
        let empty = NSLocalizedString("account.conflict.empty", comment: "")
        guard let value, value != .null else { return empty }
        let opaque: Set<String> = ["thumbnailAssetID", "fileAssetID", "originalAssetID", "fileName", "backgroundAssetIDs", "backgroundsData", "assetLocalIdentifier", "reminderConfigData", "additionalDestinationsData"]
        if opaque.contains(field) {
            switch value {
            case .string(let text): return text.isEmpty ? empty : NSLocalizedString("account.conflict.content_present", comment: "")
            case .object(let values): return values.isEmpty ? empty : NSLocalizedString("account.conflict.content_present", comment: "")
            default: return NSLocalizedString("account.conflict.content_present", comment: "")
            }
        }
        switch value {
        case .null: return empty
        case .bool(let flag): return NSLocalizedString(flag ? "account.conflict.yes" : "account.conflict.no", comment: "")
        case .integer(let integer):
            let minuteFields: Set<String> = ["plannedStartMinutes", "departLocalMinutes", "arriveLocalMinutes", "checkInMinutes", "checkOutMinutes"]
            if minuteFields.contains(field) { return integer < 0 ? empty : String(format: "%02lld:%02lld", integer / 60, integer % 60) }
            return integer.formatted()
        case .number(let number): return number.formatted()
        case .string(let text):
            if text.isEmpty { return empty }
            if field == "departureDate" || field == "timestamp", let date = ISO8601DateFormatter().date(from: text) {
                return date.formatted(date: .abbreviated, time: .omitted)
            }
            // A UUID string in a generic field is an opaque identifier, too.
            if UUID(uuidString: text) != nil { return NSLocalizedString("account.conflict.content_present", comment: "") }
            if field == "modeRaw" { return NSLocalizedString("itinerary.transport.mode." + text, comment: "") }
            if field == "categoryRaw" { return NSLocalizedString("itinerary.category." + text, comment: "") }
            return text
        case .array(let values):
            let strings = values.compactMap { if case .string(let text) = $0, UUID(uuidString: text) == nil { return text }; return nil }
            return strings.isEmpty ? empty : strings.joined(separator: ", ")
        case .object: return NSLocalizedString("account.conflict.content_present", comment: "")
        }
    }
}
