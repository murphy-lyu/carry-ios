import Foundation

/// Accept the original native seconds format and server RFC3339 milliseconds
/// explicitly on iOS 17, without relying on newer Foundation parser leniency.
nonisolated enum CarryBackupDates {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = try? fractional.parse(value) { return date }
            if let date = try? whole.parse(value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid backup date")
        }
        return decoder
    }
}
