import Foundation

/// Accept the original native seconds format and server RFC3339 milliseconds
/// explicitly on iOS 17, without relying on newer Foundation parser leniency.
nonisolated enum CarryBackupDates {
    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func parse(_ text: String) -> Date? {
        // Validate the original whole-second calendar before adding fractional
        // time. Foundation can round .999999999 into the next second, which
        // must not make an otherwise valid date appear to have invalid fields.
        let shape = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})\z"#
        guard text.range(of: shape, options: .regularExpression) != nil else { return nil }
        let zoneStart: String.Index
        if text.hasSuffix("Z") { zoneStart = text.index(before: text.endIndex) }
        else {
            guard let sign = text.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
            zoneStart = sign
        }
        let zone = text[zoneStart...]
        guard let date = try? whole.parse(String(text.prefix(19)) + zone) else { return nil }
        let requested = text.prefix(19).split { !$0.isNumber }.compactMap { Int($0) }
        var offset = 0
        if zone != "Z" {
            let digits = zone.dropFirst().filter { $0 != ":" }
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)), hours <= 23, minutes <= 59 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date.addingTimeInterval(TimeInterval(offset)))
        guard requested == [actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second].compactMap({ $0 }) else { return nil }
        let fractionStart = text.index(text.startIndex, offsetBy: 19)
        var result = date
        if fractionStart < zoneStart {
            // JavaScript's wire precision is milliseconds: truncate fractional
            // text, not a floating-point Date. Padding also handles .1 and .12.
            let digits = text[text.index(after: fractionStart)..<zoneStart].prefix(3)
            guard let milliseconds = Int(String(digits).padding(toLength: 3, withPad: "0", startingAt: 0)) else { return nil }
            result = date.addingTimeInterval(TimeInterval(milliseconds) / 1000)
        }
        // UTC encoding must remain within the same four-digit AD year range
        // accepted on input, even when an offset crosses a year boundary.
        let utc = calendar.dateComponents([.era, .year], from: result)
        guard utc.era == 1, let year = utc.year, (1...9999).contains(year) else { return nil }
        return result
    }

    /// Canonical UTC wire time: preserve legacy whole seconds, otherwise round
    /// to milliseconds (the JavaScript service precision). Construct the suffix
    /// explicitly: FormatStyle's fractional formatter can truncate binary
    /// 0.123 seconds to .122 on supported Foundation versions.
    static func string(from date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let remainder = Int(milliseconds - seconds * 1000)
        let base = whole.format(Date(timeIntervalSince1970: seconds))
        return remainder == 0 ? base : String(base.dropLast()) + String(format: ".%03dZ", remainder)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parse(value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid backup date")
        }
        return decoder
    }
}
