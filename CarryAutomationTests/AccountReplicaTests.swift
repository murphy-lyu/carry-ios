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
    private func entity(id: UUID = UUID(), version: Int = 0, name: String = "Tokyo", kind: String = "trip") -> CarryGraphEntity {
        CarryGraphEntity(id: id, kind: kind, parentID: nil, version: version, subtreeVersion: version,
            fields: ["name": .string(name)], fieldVersions: version == 0 ? [:] : ["name": version])
    }
    private func receipt(_ command: CarryGraphCommand, entity: CarryGraphEntity) -> CarryGraphReceipt {
        CarryGraphReceipt(status: "saved_to_account", requestID: command.requestID,
            changes: [CarryGraphChange(sequence: entity.subtreeVersion, entity: entity)], cursor: entity.subtreeVersion)
    }

    func testPagedReceiptSurvivesReopenAndPreservesEditsAfterFirstPage() throws {
        let (_, container) = try database()
        let owner = UUID(), replica = try CarryAccountReplica(container: container, accountID: owner)
        let first = entity(), second = entity()
        try replica.edit([first, second])
        let command = try XCTUnwrap(replica.nextCommand())
        let summary = CarryGraphReceiptSummary(status: "saved_to_account", requestID: command.requestID, cursor: 2, changeCount: 2)
        try replica.accept(CarryGraphReceiptPage(requestID: command.requestID, cursor: 2,
            changes: [CarryGraphChange(sequence: 1, entity: entity(id: first.id, version: 1))],
            nextOffset: 1, hasMore: true, changeCount: 2), summary: summary)
        var edited = try XCTUnwrap(replica.localEntities().first { $0.id == first.id })
        edited.fields["name"] = .string("Edited while receipt was incomplete")
        try replica.edit(edited)
        let reopened = try CarryAccountReplica(container: container, accountID: owner)
        XCTAssertEqual(try reopened.receiptProgress(for: command.requestID)?.nextOffset, 1)
        XCTAssertEqual(try reopened.nextCommand(), command)
        try reopened.accept(CarryGraphReceiptPage(requestID: command.requestID, cursor: 2,
            changes: [CarryGraphChange(sequence: 2, entity: CarryGraphEntity(id: second.id, kind: "trip", parentID: nil, version: 1, subtreeVersion: 2, fields: ["name": .string("Tokyo")], fieldVersions: ["name": 1]))],
            nextOffset: 2, hasMore: false, changeCount: 2), summary: summary)
        XCTAssertNil(try reopened.receiptProgress(for: command.requestID))
        let next = try XCTUnwrap(reopened.nextCommand())
        XCTAssertNotEqual(next.requestID, command.requestID)
        XCTAssertEqual(next.mutations.count, 1)
        XCTAssertEqual(next.mutations.first?.id, first.id)
        XCTAssertEqual(next.mutations.first?.fields?["name"], .string("Edited while receipt was incomplete"))
        XCTAssertEqual(try reopened.cursor, 0)
    }

    func testPagedReceiptProjectionFailureRollsBackProgressAndRejectsMissingAcknowledgement() throws {
        enum Injected: Error { case failed }
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let first = entity(), second = entity()
        try replica.edit([first, second])
        let command = try XCTUnwrap(replica.nextCommand())
        let summary = CarryGraphReceiptSummary(status: "saved_to_account", requestID: command.requestID, cursor: 2, changeCount: 2)
        let page = CarryGraphReceiptPage(requestID: command.requestID, cursor: 2,
            changes: [CarryGraphChange(sequence: 1, entity: entity(id: first.id, version: 1))],
            nextOffset: 1, hasMore: true, changeCount: 2)
        XCTAssertThrowsError(try replica.accept(page, summary: summary) { _, _ in throw Injected.failed })
        XCTAssertNil(try replica.receiptProgress(for: command.requestID))
        try replica.accept(page, summary: summary)
        let duplicate = CarryGraphReceiptPage(requestID: command.requestID, cursor: 2,
            changes: [CarryGraphChange(sequence: 2, entity: CarryGraphEntity(id: first.id, kind: "trip", parentID: nil,
                version: 1, subtreeVersion: 2, fields: [:], fieldVersions: [:]), metadataOnly: true)],
            nextOffset: 2, hasMore: false, changeCount: 2)
        XCTAssertThrowsError(try replica.accept(duplicate, summary: summary))
        XCTAssertEqual(try replica.receiptProgress(for: command.requestID)?.nextOffset, 1)
        XCTAssertEqual(try replica.nextCommand(), command)
    }

    func testMetadataRequiresTrustedBaselineAndNeverUsesUnsentLocalFields() throws {
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let original = entity(version: 1)
        let metadata = CarryGraphChange(sequence: 2, entity: CarryGraphEntity(id: original.id, kind: "trip", parentID: nil,
            version: 1, subtreeVersion: 2, fields: [:], fieldVersions: [:]), metadataOnly: true)
        XCTAssertThrowsError(try replica.receive(CarryGraphPage(changes: [metadata], cursor: 2, hasMore: false)))
        try replica.receive(CarryGraphPage(changes: [CarryGraphChange(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        var edited = original; edited.fields["name"] = .string("Unsent local name")
        try replica.edit(edited)
        try replica.receive(CarryGraphPage(changes: [metadata], cursor: 2, hasMore: false))
        XCTAssertEqual(try replica.localEntities().first?.fields["name"], .string("Unsent local name"))
        XCTAssertEqual(try replica.nextCommand()?.mutations.first?.fieldVersions, ["name": 1])
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

    func testUnsentMoveKeepsOriginalVersionAcrossConcurrentRemoteMoveAndReopen() throws {
        let (_, container) = try database(), owner = UUID()
        let replica = try CarryAccountReplica(container: container, accountID: owner)
        let first = UUID(), mine = UUID(), theirs = UUID()
        var original = entity(version: 1, kind: "stop"); original.parentID = first
        try replica.receive(CarryGraphPage(changes: [.init(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        var local = original; local.parentID = mine; try replica.edit(local)
        var remote = original; remote.parentID = theirs; remote.version = 2; remote.subtreeVersion = 2
        try replica.receive(CarryGraphPage(changes: [.init(sequence: 2, entity: remote)], cursor: 2, hasMore: false))
        let reopened = try CarryAccountReplica(container: container, accountID: owner)
        let move = try XCTUnwrap(reopened.nextCommand()?.mutations.first)
        XCTAssertEqual(move.action, "move")
        XCTAssertEqual(move.parentID, mine)
        XCTAssertEqual(move.baseVersion, 1, "Pulling a concurrent parent must not turn an old move into a force overwrite")
    }

    func testUndoOfAnInFlightMoveIsSentAfterAcknowledgementInsteadOfBeingLost() throws {
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        var original = entity(version: 1, kind: "stop"); original.parentID = UUID()
        try replica.receive(CarryGraphPage(changes: [.init(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        var moved = original; moved.parentID = UUID(); try replica.edit(moved)
        let flight = try XCTUnwrap(replica.nextCommand())
        try replica.edit(original) // Return to the old parent while the move is in flight.
        var accepted = moved; accepted.version = 2; accepted.subtreeVersion = 2
        try replica.accept(receipt(flight, entity: accepted))
        let undo = try XCTUnwrap(replica.nextCommand()?.mutations.first)
        XCTAssertEqual(undo.action, "move")
        XCTAssertEqual(undo.parentID, original.parentID)
        XCTAssertEqual(undo.baseVersion, 2)
    }

    func testLateMoveAcknowledgementKeepsPostFlightMoveBoundToItsOwnReceiptVersion() throws {
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        var original = entity(version: 1, kind: "stop"); original.parentID = UUID()
        try replica.receive(CarryGraphPage(changes: [.init(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        var moved = original; moved.parentID = UUID(); try replica.edit(moved)
        let flight = try XCTUnwrap(replica.nextCommand())
        var accepted = moved; accepted.version = 2; accepted.subtreeVersion = 2
        var local = moved; local.parentID = UUID(); try replica.edit(local)
        var latest = accepted; latest.parentID = UUID(); latest.version = 3; latest.subtreeVersion = 3
        try replica.receive(CarryGraphPage(changes: [.init(sequence: 2, entity: accepted),
            .init(sequence: 3, entity: latest)], cursor: 3, hasMore: false))
        try replica.accept(receipt(flight, entity: accepted))
        let pending = try XCTUnwrap(replica.nextCommand()?.mutations.first)
        XCTAssertEqual(pending.parentID, local.parentID)
        XCTAssertEqual(pending.baseVersion, 2, "A newer pull must not silently approve overwriting the third client's move")
    }

    func testCompoundEditRollsBackEveryQueuedEntityAndNativeProjectionTogether() throws {
        enum Injected: Error { case failed }
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let first = entity(), second = entity()
        XCTAssertThrowsError(try replica.edit([first, second]) { context in
            context.insert(TripBundle(name: "Synthetic compound", destinationCity: "Tokyo", days: 3, dateRange: ""))
            throw Injected.failed
        })
        XCTAssertTrue(try replica.localEntities().isEmpty)
        XCTAssertTrue(try replica.context.fetch(FetchDescriptor<TripBundle>()).isEmpty)
        XCTAssertNil(try replica.nextCommand())
        try replica.edit([first, second])
        XCTAssertEqual(try replica.nextCommand()?.mutations.count, 2)
    }

    func testPatchAcknowledgementCannotAdvanceAnUnseenConcurrentParentMove() throws {
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        var original = entity(version: 1, kind: "stop"); original.parentID = UUID()
        try replica.receive(CarryGraphPage(changes: [.init(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        var local = original; local.fields["name"] = .string("My name")
        try replica.edit(local)
        let patch = try XCTUnwrap(replica.nextCommand())
        local.parentID = UUID(); try replica.edit(local)
        // Another client moved the entity before our name-only patch committed.
        var accepted = local; accepted.parentID = UUID(); accepted.version = 3; accepted.subtreeVersion = 3
        accepted.fieldVersions["name"] = 3
        try replica.accept(receipt(patch, entity: accepted))
        let pending = try XCTUnwrap(replica.nextCommand()?.mutations.first)
        XCTAssertEqual(pending.parentID, local.parentID)
        XCTAssertEqual(pending.baseVersion, 1, "An ACK for a name change cannot approve an unseen parent change")
    }

    func testMoveConflictResolutionBindsRequestLocalParentAndServerVersion() throws {
        struct Failure: Encodable { let error = "move_conflict"; let conflict: CarryGraphEntity }
        for chooseLocal in [true, false] {
            let (_, container) = try database()
            let replica = try CarryAccountReplica(container: container, accountID: UUID())
            var original = entity(version: 1, kind: "stop"); original.parentID = UUID()
            try replica.receive(.init(changes: [.init(sequence: 1, entity: original)], cursor: 1, hasMore: false))
            var local = original; local.parentID = UUID(); try replica.edit(local)
            let command = try XCTUnwrap(replica.nextCommand())
            var remote = original; remote.parentID = UUID(); remote.version = 2; remote.subtreeVersion = 2
            try replica.blockFlight(details: JSONEncoder().encode(Failure(conflict: remote)))
            XCTAssertThrowsError(try replica.resolveParent(requestID: UUID(), serverVersion: 2,
                expectedLocalParentID: local.parentID, choice: .local))
            XCTAssertThrowsError(try replica.resolveParent(requestID: command.requestID, serverVersion: 3,
                expectedLocalParentID: local.parentID, choice: .local))
            XCTAssertThrowsError(try replica.resolveParent(requestID: command.requestID, serverVersion: 2,
                expectedLocalParentID: UUID(), choice: .local))
            try replica.resolveParent(requestID: command.requestID, serverVersion: 2,
                expectedLocalParentID: local.parentID, choice: chooseLocal ? .local : .remote)
            let followup = try replica.nextCommand()
            if chooseLocal {
                XCTAssertNotEqual(followup?.requestID, command.requestID)
                XCTAssertEqual(followup?.mutations.first?.baseVersion, 2)
                XCTAssertEqual(followup?.mutations.first?.parentID, local.parentID)
            } else {
                XCTAssertNil(followup)
                XCTAssertEqual(try replica.localEntities().first?.parentID, remote.parentID)
            }
            XCTAssertNil(try replica.pendingFailure)
        }
    }

    func testFieldResolutionCannotDowngradeAnAlreadyPulledNewerVersion() throws {
        struct Conflict: Encodable { let current: CarryGraphEntity; let fields: [String] }
        struct Failure: Encodable { let error = "field_conflict"; let conflict: Conflict }
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let original = entity(version: 1)
        try replica.receive(.init(changes: [.init(sequence: 1, entity: original)], cursor: 1, hasMore: false))
        var local = original; local.fields["name"] = .string("My local value"); try replica.edit(local)
        let command = try XCTUnwrap(replica.nextCommand())
        let rejected = entity(id: original.id, version: 2, name: "Reviewed remote value")
        try replica.blockFlight(details: JSONEncoder().encode(Failure(conflict: .init(current: rejected, fields: ["name"]))))
        let latest = entity(id: original.id, version: 3, name: "Newer remote value")
        try replica.receive(.init(changes: [.init(sequence: 2, entity: rejected), .init(sequence: 3, entity: latest)],
            cursor: 3, hasMore: false))
        XCTAssertThrowsError(try replica.resolveFields(requestID: command.requestID, serverVersion: 2, choices: ["name": .remote]))
        XCTAssertEqual(try replica.localEntities().first?.fields["name"], .string("My local value"))
        XCTAssertEqual(try replica.localEntities().first?.version, 3)
        XCTAssertNotNil(try replica.pendingFailure)
    }

    func testPullBeforeCreateAcknowledgementRetainsNewerRemoteSnapshotAcrossReopen() throws {
        let (_, container) = try database(), owner = UUID()
        let replica = try CarryAccountReplica(container: container, accountID: owner)
        var created = entity(); try replica.edit(created)
        let command = try XCTUnwrap(replica.nextCommand())
        created.fields["name"] = .string("My post-flight edit"); try replica.edit(created)
        let accepted = entity(id: created.id, version: 1)
        var latest = accepted; latest.version = 2; latest.subtreeVersion = 2
        latest.fields["destinationCity"] = .string("Remote destination")
        latest.fieldVersions["destinationCity"] = 2
        try replica.receive(.init(changes: [.init(sequence: 1, entity: accepted), .init(sequence: 2, entity: latest)],
            cursor: 2, hasMore: false)) { _, _ in XCTFail("Unacknowledged UUIDs must not replace local creations") }
        let reopened = try CarryAccountReplica(container: container, accountID: owner)
        XCTAssertEqual(try reopened.cursor, 2)
        try reopened.accept(receipt(command, entity: accepted))
        let local = try XCTUnwrap(reopened.localEntities().first)
        XCTAssertEqual(local.fields["name"], .string("My post-flight edit"))
        XCTAssertEqual(local.fields["destinationCity"], .string("Remote destination"))
        XCTAssertEqual(local.version, 2)
        XCTAssertEqual(try reopened.nextCommand()?.mutations.first?.fieldVersions, ["name": 1])
    }

    func testLateCreateAcknowledgementWithoutNewLocalEditsCannotDiscardAlreadyPulledRemoteFields() throws {
        let (_, container) = try database()
        let replica = try CarryAccountReplica(container: container, accountID: UUID())
        let created = entity(); try replica.edit(created)
        let command = try XCTUnwrap(replica.nextCommand())
        let accepted = entity(id: created.id, version: 1)
        let latest = entity(id: created.id, version: 2, name: "Remote edit after creation")
        try replica.receive(.init(changes: [.init(sequence: 1, entity: accepted), .init(sequence: 2, entity: latest)],
            cursor: 2, hasMore: false))
        try replica.accept(receipt(command, entity: accepted))
        XCTAssertEqual(try replica.localEntities().first, latest)
        XCTAssertNil(try replica.nextCommand())
    }

}
