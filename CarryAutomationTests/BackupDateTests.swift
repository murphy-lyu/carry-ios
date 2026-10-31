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
}
