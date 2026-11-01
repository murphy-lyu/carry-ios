import XCTest
@testable import Carry

final class BackupDateTests: XCTestCase {
    func testExplicitBackupDateStrategiesAcceptNativeSecondsAndServerMilliseconds() throws {
        let decoder = CarryBackupDates.decoder()
        let seconds = try decoder.decode(Date.self, from: Data("\"2026-10-31T10:20:30Z\"".utf8))
        let milliseconds = try decoder.decode(Date.self, from: Data("\"2026-10-31T10:20:30.125Z\"".utf8))
        let offset = try decoder.decode(Date.self, from: Data("\"2026-10-31T19:20:30+09:00\"".utf8))
        XCTAssertEqual(milliseconds.timeIntervalSince(seconds), 0.125, accuracy: 0.0001)
        XCTAssertEqual(offset, seconds)
        XCTAssertThrowsError(try decoder.decode(Date.self, from: Data("\"not-a-date\"".utf8)))
    }

    func testHighPrecisionFractionsTruncateTextToMillisecondsWithoutCalendarCarry() throws {
        let values = [
            ("2026-11-01T10:20:30.1Z", "2026-11-01T10:20:30.100Z"),
            ("2026-11-01T10:20:30.12Z", "2026-11-01T10:20:30.120Z"),
            ("2026-11-01T10:20:30.123456789Z", "2026-11-01T10:20:30.123Z"),
            ("2026-11-01T10:20:30.9995Z", "2026-11-01T10:20:30.999Z"),
            ("2026-11-01T10:20:59.999999999Z", "2026-11-01T10:20:59.999Z"),
            ("2026-12-31T23:59:59.999999999Z", "2026-12-31T23:59:59.999Z"),
            ("2026-11-01T18:20:30.999999999+08:00", "2026-11-01T10:20:30.999Z"),
            ("2026-11-01T10:20:30.000000001Z", "2026-11-01T10:20:30Z"),
            ("1969-12-31T23:59:59.999999999Z", "1969-12-31T23:59:59.999Z")
        ]
        for (input, expected) in values {
            let date = try XCTUnwrap(CarryBackupDates.parse(input), input)
            XCTAssertEqual(CarryBackupDates.string(from: date), expected, input)
            XCTAssertEqual(try CarryBackupDates.decoder().decode(Date.self, from: JSONEncoder().encode(input)), date)
            let encoded = try CarryBackupDates.encoder().encode(date)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: encoded), expected)
            XCTAssertEqual(try XCTUnwrap(CarryBackupDates.parse(expected)), date)
        }
    }

    func testFractionTruncationNeverMakesInvalidCalendarsOrTrailingValuesValid() {
        for input in ["2026-02-30T10:20:30.999999999Z", "2026-02-29T10:20:30.123Z",
                      "2026-11-01T24:00:00.999999999Z", "2026-11-01T10:20:60.999999999Z",
                      "2026-11-01T10:60:30.123Z", "2026-11-01T10:20:30.123Zgarbage",
                      "2026-11-01T10:20:30.123Z\n", "2026-11-01T10:20:30.123+08:60"] {
            XCTAssertNil(CarryBackupDates.parse(input), input)
        }
    }


    func testUTCYearRangeRemainsClosedAcrossOffsetsAndFractionTruncation() throws {
        for invalid in ["0001-01-01T00:00:00+15:59", "9999-12-31T23:59:59.999-15:59"] {
            XCTAssertNil(CarryBackupDates.parse(invalid), invalid)
            XCTAssertThrowsError(try CarryBackupDates.decoder().decode(Date.self, from: JSONEncoder().encode(invalid)))
        }
        for (input, canonical) in [
            ("0001-01-01T00:00:00Z", "0001-01-01T00:00:00Z"),
            ("9999-12-31T23:59:59.999999999Z", "9999-12-31T23:59:59.999Z")
        ] {
            let date = try XCTUnwrap(CarryBackupDates.parse(input), input)
            XCTAssertEqual(CarryBackupDates.string(from: date), canonical)
            XCTAssertEqual(CarryBackupDates.parse(canonical), date)
            XCTAssertEqual(try CarryBackupDates.decoder().decode(Date.self, from: CarryBackupDates.encoder().encode(date)), date)
        }
    }

}
