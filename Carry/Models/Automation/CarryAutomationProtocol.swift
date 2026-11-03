import Foundation
import CryptoKit

enum AutomationValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([AutomationValue]), object([String: AutomationValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AutomationValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AutomationValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum AutomationError: String, Error {
    case invalidInput = "invalid_input"
    case unsupportedOperation = "unsupported_operation"
    case unauthorized = "trip_not_authorized"
    case notFound = "entity_not_found"
    case conflict = "revision_conflict"
    case expired = "expired"
    case requestReused = "request_id_reused"
    case busy = "pending_local_changes"
    case persistenceUnavailable = "persistence_unavailable"
    case cloudAccountChanged = "icloud_account_changed"
    case network = "network_error"
    case saveFailed = "save_failed"
}

enum AutomationAuthorization {
    static let scopes: Set<String> = ["trips:read", "trips:write", "library:read", "library:write"]
    static func scopeSet(_ scope: String) -> Set<String> { Set(scope.split(separator: " ").map(String.init)) }
    static func validate(operation: String, scope: String) throws {
        let required = ["add_my_item", "update_my_item", "remove_my_item"].contains(operation)
            ? "library:write" : CarryAutomationQueries.names.contains(operation) && operation != "open_trip" ? "trips:read" : "trips:write"
        guard scopeSet(scope).contains(required) else { throw AutomationError.unauthorized }
    }
    static func approvedTripIds(serverIds: [UUID], approved: [UUID], locallyCreated: UUID? = nil) -> [UUID] {
        var result = Set(serverIds).intersection(Set(approved))
        if let locallyCreated { result.insert(locallyCreated) }
        return result.sorted { $0.uuidString < $1.uuidString }
    }
}

struct AutomationArguments: Codable, Sendable {
    let requestId: UUID
    let tripId: UUID?
    let entityId: UUID?
    let expectedRevision: String?
    let data: [String: AutomationValue]?
}

struct AutomationOperation: Codable, Sendable {
    let protocolVersion: Int
    let connectionId: UUID
    let requestId: UUID
    let name: String
    let arguments: AutomationArguments
    let payloadHash: String
    let entityId: UUID
    let expiresAt: Double

    func fingerprint() throws -> String {
        // Compute locally; never trust a remote digest to deduplicate device writes.
        struct Input: Encodable {
            let name: String
            let arguments: AutomationArguments
            let entityId: UUID
        }
        return try AutomationCodec.digest(Input(name: name, arguments: arguments, entityId: entityId))
    }
}

struct AutomationReceipt: Codable, Sendable {
    let requestId: UUID
    let payloadHash: String
    let status: String
    var entityId: UUID?
    var revision: String?
    var error: String?
    var data: [String: AutomationValue]?
}

struct AutomationTripSnapshot: Codable, Sendable {
    let id: UUID
    let name: String
    let destinationCity: String
    let isDateless: Bool
    let departureDate: String?
    let returnDate: String?
    let days: [AutomationDaySnapshot]
    let packing: [AutomationSectionSnapshot]
    let lodging: [[String: AutomationValue]]
    var destinations: [[String: AutomationValue]] = []
    var remindersEnabled = true
    var revision: String
}

struct AutomationDaySnapshot: Codable, Sendable {
    let id: UUID
    let dayOrder: Int
    let title: String
    let note: String
    let stops: [AutomationStopSnapshot]
    let transport: [[String: AutomationValue]]
}

struct AutomationStopSnapshot: Codable, Sendable {
    let id: UUID
    let name: String
    let address: String
    let category: String
    let latitude: Double
    let longitude: Double
    let timeZoneId: String
    let plannedStartMinutes: Int
    let stayMinutes: Int
    let note: String
    let sortOrder: Int
    let costAmount: Double
    let costCurrencyCode: String
}

struct AutomationSectionSnapshot: Codable, Sendable {
    let id: UUID
    let name: String
    let items: [AutomationItemSnapshot]
}

struct AutomationItemSnapshot: Codable, Sendable {
    let id: UUID
    let name: String
    let quantity: Int
    let isPacked: Bool
}

struct AutomationLibrarySnapshot: Codable, Sendable {
    let items: [AutomationLibraryItem]
    let revision: String
}
struct AutomationLibraryItem: Codable, Sendable {
    let id: UUID
    let name: String
    let collectionName: String
    let category: String
    let defaultQuantity: Int
    let quantityMode: String
    let quantityIntervalDays: Int
    let sortOrder: Int
}

enum AutomationCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func privateDigest<T: Encodable>(_ value: T) throws -> String {
        // A plain hash of low-entropy private booking codes can be guessed offline.
        // The version key never leaves this device or enters a backup/CloudKit record.
        HMAC<SHA256>.authenticationCode(for: try encode(value), using: try AutomationKeychain.revisionKey())
            .map { String(format: "%02x", $0) }.joined()
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw AutomationError.invalidInput
        }
        return date
    }
}

struct AutomationFields {
    let values: [String: AutomationValue]
    func strings(_ key: String, maxCount: Int = 1000) throws -> [String] {
        guard case .array(let array) = values[key], array.count <= maxCount else { throw AutomationError.invalidInput }
        return try array.map {
            guard case .string(let value) = $0, !value.isEmpty, value.count <= 500 else { throw AutomationError.invalidInput }
            return value
        }
    }
    func validate(allowed: Set<String>) throws {
        guard Set(values.keys).isSubset(of: allowed) else { throw AutomationError.invalidInput }
    }
    func string(_ key: String, required: Bool = false, max: Int = 2000) throws -> String? {
        guard let value = values[key] else {
            if required { throw AutomationError.invalidInput }
            return nil
        }
        guard case .string(let string) = value, string.count <= max, !required || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.invalidInput
        }
        return string
    }
    func number(_ key: String, range: ClosedRange<Double>) throws -> Double? {
        guard let value = values[key] else { return nil }
        guard case .number(let number) = value, number.isFinite, range.contains(number) else { throw AutomationError.invalidInput }
        return number
    }
    func integer(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let number = try number(key, range: Double(range.lowerBound)...Double(range.upperBound)) else { return nil }
        guard number.rounded() == number else { throw AutomationError.invalidInput }
        return Int(number)
    }
    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard case .bool(let flag) = value else { throw AutomationError.invalidInput }
        return flag
    }
    func uuid(_ key: String) throws -> UUID {
        guard let raw = try string(key, required: true), let id = UUID(uuidString: raw) else { throw AutomationError.invalidInput }
        return id
    }
    func uuids(_ key: String) throws -> [UUID] {
        guard case .array(let array) = values[key], array.count <= 1000 else { throw AutomationError.invalidInput }
        let ids = try array.map { value -> UUID in
            guard case .string(let raw) = value, let id = UUID(uuidString: raw) else { throw AutomationError.invalidInput }
            return id
        }
        guard Set(ids).count == ids.count else { throw AutomationError.invalidInput }
        return ids
    }
}
