import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AccountReplicaTests: XCTestCase {
    private func database() throws -> (URL, ModelContainer) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarryReplica-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // XCTest runs teardown after test-local replicas and containers leave
        // scope. Unlinking a live SQLite store in defer triggers API violations.
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
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
        let (_, container) = try database()
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
        let (_, container) = try database()
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
        let (_, container) = try database()
        let owner = UUID(), replica = try CarryAccountReplica(container: container, accountID: owner)
        XCTAssertFalse(replica.context.autosaveEnabled)
        XCTAssertThrowsError(try CarryAccountReplica(container: container, accountID: UUID()))
        XCTAssertNil(try replica.nextCommand())
    }

    func testRemotePullPreservesUnsentLocalFieldAndItsConflictBaseline() throws {
        let (_, container) = try database()
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
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let page = CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: entity(version: 1))], cursor: 1, hasMore: false)
        XCTAssertThrowsError(try replica.receive(page) { _, _ in throw Injected.failed })
        XCTAssertEqual(try replica.cursor, 0); XCTAssertTrue(try replica.localEntities().isEmpty)
        XCTAssertThrowsError(try replica.receive(CarryGraphPage(changes: page.changes, cursor: 2, hasMore: false)))
        try replica.receive(page)
        XCTAssertEqual(try replica.cursor, 1)
    }

    func testWrongReceiptCannotClearFlightAndPermanentRejectionBlocksAutomaticRetries() throws {
        let (_, container) = try database()
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
        let (_, container) = try database()
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

    func testEditingAndQueueSelectionDoNotDecodeUnrelatedCleanPayloads() throws {
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        // An intentionally unreadable unrelated payload makes any accidental
        // full-cache decoding fail deterministically, without timing thresholds.
        let unrelated = CarryReplicaRecord(id: UUID(), payload: Data([0xff]), hasPendingChanges: false)
        replica.context.insert(unrelated)
        try replica.context.save()
        var local = entity()
        try replica.edit(local)
        local.fields["name"] = .string("Only this trip changed")
        try replica.edit(local)
        let command = try XCTUnwrap(replica.nextCommand())
        XCTAssertEqual(command.mutations.count, 1)
        XCTAssertEqual(command.mutations.first?.id, local.id)
        XCTAssertEqual(command.mutations.first?.fields?["name"], .string("Only this trip changed"))
        let accepted = entity(id: local.id, version: 1, name: "Only this trip changed")
        var projected: [CarryGraphEntity] = []
        try replica.accept(receipt(command, entity: accepted)) { values, _ in projected = values }
        XCTAssertEqual(projected, [accepted], "ACK projection is a delta, not a full-cache read")
        let pulled = entity(id: local.id, version: 2, name: "Remote change")
        try replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: accepted),
            CarryGraphChange(sequence: 2, entity: pulled)], cursor: 2, hasMore: false)) { values, _ in projected = values }
        XCTAssertEqual(projected, [pulled])
        try replica.receive(CarryGraphPage(changes: [], cursor: 2, hasMore: false)) { _, _ in
            XCTFail("An empty pull must not re-project the complete business graph")
        }
        XCTAssertEqual(unrelated.payload, Data([0xff]))
        XCTAssertFalse(unrelated.hasPendingChanges)
        XCTAssertThrowsError(try replica.localEntities(), "Explicit full reads still surface corrupt data")
    }

    func testPendingQueueFlagRepairsOldCacheAndTracksUndoWithoutAnUpload() throws {
        let (_, container) = try database()
        let owner = UUID(), replica = try CarryAccountReplica(container: container, accountID: owner)
        let original = entity(version: 1)
        try replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        let row = try XCTUnwrap(replica.context.fetch(FetchDescriptor<CarryReplicaRecord>()).first)
        XCTAssertFalse(row.hasPendingChanges)
        // Older caches get the model's true default during lightweight migration.
        row.hasPendingChanges = true
        try replica.context.save()
        XCTAssertNil(try replica.nextCommand())
        XCTAssertFalse(row.hasPendingChanges)
        var edited = original; edited.fields["name"] = .string("Unsent change")
        try replica.edit(edited)
        XCTAssertTrue(row.hasPendingChanges)
        try replica.edit(original)
        XCTAssertNil(try replica.nextCommand())
        XCTAssertFalse(row.hasPendingChanges)
        let reopened = try CarryAccountReplica(container: container, accountID: owner)
        XCTAssertNil(try reopened.nextCommand())
    }

}
