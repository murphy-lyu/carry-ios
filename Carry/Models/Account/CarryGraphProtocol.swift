import Foundation

/// Lossless JSON scalar/container values for the versioned account protocol.
/// Dates, IDs and asset references remain explicit wire strings; no Any/NSNumber
/// conversion that silently turns booleans into numbers.
nonisolated enum CarryGraphValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([CarryGraphValue]), object([String: CarryGraphValue])

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.integer(let a), .number(let b)), (.number(let b), .integer(let a)):
            return Double(exactly: a) == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        default: return false
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([CarryGraphValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: CarryGraphValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let decoded): try value.encode(decoded)
        case .integer(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .string(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        }
    }
}

nonisolated struct CarryGraphEntity: Codable, Equatable, Sendable {
    let id: UUID
    let kind: String
    var parentID: UUID?
    var version: Int
    var subtreeVersion: Int
    var fields: [String: CarryGraphValue]
    var fieldVersions: [String: Int]
    var deletedAt: String?
    var deletionBatch: UUID?
}

nonisolated struct CarryGraphMutation: Codable, Equatable, Sendable {
    let id: UUID
    let kind: String
    var action: String
    let baseVersion: Int
    var baseSubtreeVersion: Int?
    var parentID: UUID?
    var fields: [String: CarryGraphValue]?
    var fieldVersions: [String: Int]?
}

nonisolated struct CarryGraphCommand: Codable, Equatable, Sendable {
    let requestID: UUID
    let mutations: [CarryGraphMutation]
}

nonisolated struct CarryGraphChange: Codable, Equatable, Sendable {
    let sequence: Int
    let entity: CarryGraphEntity
}

nonisolated struct CarryGraphPage: Codable, Sendable {
    let changes: [CarryGraphChange]
    let cursor: Int
    let hasMore: Bool
}

nonisolated struct CarryGraphReceipt: Codable, Sendable {
    let status: String
    let requestID: UUID
    let changes: [CarryGraphChange]
    let cursor: Int
}

enum CarryReplicaFailure: Error {
    case accountMismatch, invalidState, invalidReceipt, invalidCursor, blocked, tooManyChanges
}

nonisolated enum CarryGraphConflictChoice: Sendable {
    case local, remote, edited(CarryGraphValue)
}
