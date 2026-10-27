import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AccountReplicaTests: XCTestCase {
    private func database() throws -> (URL, ModelContainer) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarryReplica-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, try CarryAccountReplica.container(at: url.appendingPathComponent("account.store")))
    }
    private func entity(id: UUID = UUID(), version: Int = 0, name: String = "Tokyo") -> CarryGraphEntity {
        CarryGraphEntity(id: id, kind: "trip", parentID: nil, version: version, subtreeVersion: version,
            fields: ["name": .string(name)], fieldVersions: version == 0 ? [:] : ["name": version])
    }
    private func receipt(_ command: CarryGraphCommand, entity: CarryGraphEntity) -> CarryGraphReceipt {
        CarryGraphReceipt(status: "saved_to_account", requestID: command.requestID,
            changes: [CarryGraphChange(sequence: entity.subtreeVersion, entity: entity)], cursor: entity.subtreeVersion)
    }

    func testProtocolPreservesBoolIntegersNullAndNestedValues() throws {
        let value: CarryGraphValue = .object(["flag": .bool(true), "quantity": .integer(2), "optional": .null,
            "items": .array([.string("東京"), .number(2.25)])])
        XCTAssertEqual(try JSONDecoder().decode(CarryGraphValue.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(CarryGraphValue.integer(2), .number(2.0))
        XCTAssertNotEqual(CarryGraphValue.integer(9_007_199_254_740_993), .number(9_007_199_254_740_992))
    }

    func testBusinessGraphAndOutboxRollbackTogetherOnSaveFailure() throws {
        enum Injected: Error { case failed }
        let (url, container) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        var reject = false
        let replica = try CarryAccountReplica(container: container, accountID: UUID(), save: {
            if reject { throw Injected.failed }; try $0.save()
        })
        reject = true
        XCTAssertThrowsError(try replica.edit(entity()) { context in
            context.insert(TripBundle(name: "Synthetic only", destinationCity: "Tokyo", days: 3, dateRange: ""))
        })
        XCTAssertTrue(try replica.localEntities().isEmpty)
        XCTAssertTrue(try replica.context.fetch(FetchDescriptor<TripBundle>()).isEmpty)
        reject = false
        XCTAssertNil(try replica.nextCommand())
    }

    func testRetryAfterReopenKeepsFrozenRequestIDAndLatestUnsentEdit() throws {
        let (url, container) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = UUID(), replica = try CarryAccountReplica(container: container, accountID: owner)
        var local = entity(); try replica.edit(local)
        let command = try XCTUnwrap(replica.nextCommand())
        local.fields["name"] = .string("Edited offline after send")
        try replica.edit(local)
        let reopened = try CarryAccountReplica(container: container, accountID: owner)
        XCTAssertEqual(try reopened.nextCommand(), command)
        let remote = entity(id: local.id, version: 1)
        try reopened.accept(receipt(command, entity: remote))
        XCTAssertEqual(try reopened.localEntities().first?.fields["name"], .string("Edited offline after send"))
        let followup = try XCTUnwrap(reopened.nextCommand())
        XCTAssertNotEqual(followup.requestID, command.requestID)
        XCTAssertEqual(followup.mutations.first?.action, "patch")
        XCTAssertEqual(followup.mutations.first?.fieldVersions, ["name": 1])
        XCTAssertEqual(try reopened.cursor, 0, "Upload acknowledgement cannot skip unseen remote changes")
    }

    func testAccountCacheRejectsAnotherOwnerAndDisablesAutosave() throws {
        let (url, container) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = UUID(), replica = try CarryAccountReplica(container: container, accountID: owner)
        XCTAssertFalse(replica.context.autosaveEnabled)
        XCTAssertThrowsError(try CarryAccountReplica(container: container, accountID: UUID()))
        XCTAssertNil(try replica.nextCommand())
    }

    func testRemotePullPreservesUnsentLocalFieldAndItsConflictBaseline() throws {
        let (url, container) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let initial = entity(version: 1)
        try replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: initial)], cursor: 1, hasMore: false))
        var edited = initial; edited.fields["name"] = .string("My offline edit")
        try replica.edit(edited)
        let other = entity(id: initial.id, version: 2, name: "Other client")
        try replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 2, entity: other)], cursor: 2, hasMore: false))
        XCTAssertEqual(try replica.localEntities().first?.fields["name"], .string("My offline edit"))
        XCTAssertEqual(try replica.nextCommand()?.mutations.first?.fieldVersions, ["name": 1])
    }

    func testPullProjectionFailureRollsBackBothGraphAndCursorAndRejectsGaps() throws {
        enum Injected: Error { case failed }
        let (url, container) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let page = CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: entity(version: 1))], cursor: 1, hasMore: false)
        XCTAssertThrowsError(try replica.receive(page) { _, _ in throw Injected.failed })
        XCTAssertEqual(try replica.cursor, 0); XCTAssertTrue(try replica.localEntities().isEmpty)
        XCTAssertThrowsError(try replica.receive(CarryGraphPage(changes: page.changes, cursor: 2, hasMore: false)))
        try replica.receive(page)
        XCTAssertEqual(try replica.cursor, 1)
    }

    func testWrongReceiptCannotClearFlightAndPermanentRejectionBlocksAutomaticRetries() throws {
        let (url, container) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let e = entity(); try replica.edit(e)
        let command = try XCTUnwrap(replica.nextCommand())
        let wrong = CarryGraphCommand(requestID: UUID(), mutations: command.mutations)
        XCTAssertThrowsError(try replica.accept(receipt(wrong, entity: entity(id: e.id, version: 1))))
        XCTAssertEqual(try replica.nextCommand(), command)
        try replica.blockFlight()
        XCTAssertThrowsError(try replica.nextCommand())
    }
    func testLateReceiptDoesNotOverwriteNewerPullOrAdvancePendingFieldBaseline() throws {
        let (url, container) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let original = entity(version: 1)
        try replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        var local = original; local.fields["name"] = .string("First local edit"); try replica.edit(local)
        let command = try XCTUnwrap(replica.nextCommand())
        local.fields["name"] = .string("Next local edit"); try replica.edit(local)
        let latest = entity(id: original.id, version: 3, name: "Someone edited after my first save")
        try replica.receive(CarryGraphPage(changes: [
            CarryGraphChange(sequence: 2, entity: entity(id: original.id, version: 2, name: "First local edit")),
            CarryGraphChange(sequence: 3, entity: latest)], cursor: 3, hasMore: false))
        try replica.accept(receipt(command, entity: entity(id: original.id, version: 2, name: "First local edit")))
        XCTAssertEqual(try replica.localEntities().first?.fields["name"], .string("Next local edit"))
        XCTAssertEqual(try replica.nextCommand()?.mutations.first?.fieldVersions, ["name": 2])
        XCTAssertEqual(try replica.cursor, 3)
    }

}
