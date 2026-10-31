import XCTest
import SwiftData
@testable import Carry

@MainActor
final class ConflictReviewTests: XCTestCase {
    private func replica() throws -> CarryAccountReplica {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConflictReview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try CarryAccountReplica.container(at: directory.appendingPathComponent("account.store"))
        return try CarryAccountReplica(container: container, accountID: UUID())
    }
    private func entity(id: UUID = UUID(), kind: String = "trip", version: Int = 1, name: String = "Original", parent: UUID? = nil) -> CarryGraphEntity {
        .init(id: id, kind: kind, parentID: parent, version: version, subtreeVersion: version,
            fields: ["name": .string(name)], fieldVersions: ["name": version])
    }
    private func receive(_ values: [CarryGraphEntity], in replica: CarryAccountReplica, starting: Int) throws {
        try replica.receive(.init(changes: values.enumerated().map { offset, value in
            var entity = value; entity.subtreeVersion = starting + offset
            return .init(sequence: starting + offset, entity: entity)
        },
            cursor: starting + values.count - 1, hasMore: false))
    }
    private func blockField(_ remote: CarryGraphEntity, in replica: CarryAccountReplica) throws {
        struct Conflict: Encodable { let current: CarryGraphEntity; let fields = ["name"] }
        struct Failure: Encodable { let error = "field_conflict"; let conflict: Conflict }
        try replica.blockFlight(details: JSONEncoder().encode(Failure(conflict: .init(current: remote))))
    }

    func testReviewRefreshesBothLocalDraftAndRemoteInsteadOfPermanentlyUsingOldFailure() throws {
        let replica = try replica(), original = entity()
        try receive([original], in: replica, starting: 1)
        var local = original; local.fields["name"] = .string("My first draft"); try replica.edit(local)
        let command = try XCTUnwrap(replica.nextCommand())
        let rejected = entity(id: original.id, version: 2, name: "Remote first")
        try blockField(rejected, in: replica)
        let first = try XCTUnwrap(replica.conflictReview())
        XCTAssertEqual(first.requestID, command.requestID)
        let newer = entity(id: original.id, version: 3, name: "Remote latest")
        try receive([rejected, newer], in: replica, starting: 2)
        var draft = try XCTUnwrap(replica.localEntities().first); draft.fields["name"] = .string("My latest draft"); try replica.edit(draft)
        XCTAssertThrowsError(try replica.resolveReviewedConflict(first, fields: ["name": .local]))
        XCTAssertTrue(try replica.abandonedPublicationRequests().isEmpty)
        let latest = try XCTUnwrap(replica.conflictReview())
        XCTAssertEqual(latest.current.fields["name"], .string("Remote latest"))
        XCTAssertEqual(latest.local.fields["name"], .string("My latest draft"))
        try replica.resolveReviewedConflict(latest, fields: ["name": .local])
        let retry = try XCTUnwrap(replica.nextCommand())
        XCTAssertNotEqual(retry.requestID, command.requestID)
        XCTAssertEqual(retry.mutations.first?.fields?["name"], .string("My latest draft"))
        XCTAssertEqual(retry.mutations.first?.fieldVersions?["name"], 3)
    }

    func testChoosingReviewedRemoteDoesNotDiscardUnrelatedLocalFields() throws {
        let replica = try replica(), original = entity()
        try receive([original], in: replica, starting: 1)
        var local = original; local.fields["name"] = .string("My name"); local.fields["note"] = .string("Keep my note")
        try replica.edit(local); _ = try replica.nextCommand()
        let remote = entity(id: original.id, version: 2, name: "Other name")
        try blockField(remote, in: replica)
        let review = try XCTUnwrap(replica.conflictReview())
        try replica.resolveReviewedConflict(review, fields: ["name": .remote])
        let command = try XCTUnwrap(replica.nextCommand())
        XCTAssertNil(command.mutations.first?.fields?["name"])
        XCTAssertEqual(command.mutations.first?.fields?["note"], .string("Keep my note"))
        XCTAssertEqual(try replica.localEntities().first?.fields["name"], .string("Other name"))
    }

    func testMoveReviewBindsTheCurrentParentAndRejectsAnOutdatedChoice() throws {
        struct Failure: Encodable { let error = "move_conflict"; let conflict: CarryGraphEntity }
        let replica = try replica(), original = entity(kind: "stop", parent: UUID())
        try receive([original], in: replica, starting: 1)
        var local = original; local.parentID = UUID(); try replica.edit(local); _ = try replica.nextCommand()
        var remote = original; remote.parentID = UUID(); remote.version = 2; remote.subtreeVersion = 2
        try replica.blockFlight(details: JSONEncoder().encode(Failure(conflict: remote)))
        let first = try XCTUnwrap(replica.conflictReview())
        local.parentID = UUID(); try replica.edit(local)
        XCTAssertThrowsError(try replica.resolveReviewedConflict(first, parent: .remote))
        let current = try XCTUnwrap(replica.conflictReview())
        try replica.resolveReviewedConflict(current, parent: .remote)
        XCTAssertNil(try replica.nextCommand())
        XCTAssertEqual(try replica.localEntities().first?.parentID, remote.parentID)
    }

    func testSubtreeReviewDetectsNewDescendantAndRebasesOnlyAfterFreshReview() throws {
        struct Failure: Encodable { let error = "subtree_conflict"; let conflict: CarryGraphEntity }
        let replica = try replica(), root = entity(), child = entity(kind: "section", parent: nil)
        var section = child; section.parentID = root.id; section.subtreeVersion = 2
        try receive([root, section], in: replica, starting: 1)
        try replica.editTrees([.init(id: root.id, kind: root.kind, isDeleted: true, observed: root, memberIDs: [root.id, section.id])])
        _ = try replica.nextCommand()
        var changed = root; changed.subtreeVersion = 3
        try replica.blockFlight(details: JSONEncoder().encode(Failure(conflict: changed)))
        let first = try XCTUnwrap(replica.conflictReview())
        let extra = entity(kind: "section", parent: root.id)
        var latest = root; latest.subtreeVersion = 4
        try receive([extra, latest], in: replica, starting: 3)
        XCTAssertThrowsError(try replica.resolveReviewedConflict(first, tree: true))
        let reviewed = try XCTUnwrap(replica.conflictReview())
        XCTAssertTrue(reviewed.impact.contains { $0.id == extra.id })
        try replica.resolveReviewedConflict(reviewed, tree: true)
        let retry = try XCTUnwrap(replica.nextCommand())
        XCTAssertEqual(retry.mutations.first?.baseSubtreeVersion, 4)
    }

    func testPresentationHidesOpaqueConfigurationIdentifiersAndFormatsActualClockMinutes() {
        let id = UUID().uuidString
        XCTAssertFalse(CarryAccountConflictPresentation.value(.string(id), field: "fileAssetID").contains(id))
        XCTAssertFalse(CarryAccountConflictPresentation.value(.string("base64-secret-config"), field: "backgroundsData").contains("base64"))
        XCTAssertEqual(CarryAccountConflictPresentation.value(.integer(545), field: "plannedStartMinutes"), "09:05")
        XCTAssertEqual(CarryAccountConflictPresentation.fieldKey("quantity"), "account.conflict.field.quantity")
    }

    func testCancellingReviewedParentDeletionKeepsIndependentChildDeletion() throws {
        struct Failure: Encodable { let error = "subtree_conflict"; let conflict: CarryGraphEntity }
        let replica = try replica(), root = entity(), child = entity(kind: "section", parent: nil)
        var section = child; section.parentID = root.id; section.subtreeVersion = 2
        try receive([root, section], in: replica, starting: 1)
        try replica.editTrees([.init(id: section.id, kind: section.kind, isDeleted: true, observed: section, memberIDs: [section.id]),
            .init(id: root.id, kind: root.kind, isDeleted: true, observed: root, memberIDs: [root.id, section.id])])
        _ = try replica.nextCommand()
        var changed = root; changed.subtreeVersion = 3
        try replica.blockFlight(details: JSONEncoder().encode(Failure(conflict: changed)))
        let review = try XCTUnwrap(replica.conflictReview())
        try replica.resolveReviewedConflict(review, tree: false)
        let retry = try XCTUnwrap(replica.nextCommand())
        XCTAssertEqual(retry.mutations.map(\.id), [section.id])
        let local = try replica.localEntities()
        XCTAssertNil(local.first { $0.id == root.id }?.deletedAt)
        XCTAssertNotNil(local.first { $0.id == section.id }?.deletedAt)
    }

    func testResolvedFlightQueuesDurablePinReleaseUntilWorkspaceAcknowledgesIt() throws {
        let replica = try replica(), original = entity()
        try receive([original], in: replica, starting: 1)
        var local = original; local.fields["name"] = .string("Mine"); try replica.edit(local)
        let command = try XCTUnwrap(replica.nextCommand())
        try blockField(entity(id: original.id, version: 2, name: "Other"), in: replica)
        try replica.resolveReviewedConflict(XCTUnwrap(replica.conflictReview()), fields: ["name": .remote])
        XCTAssertEqual(try replica.abandonedPublicationRequests(), [command.requestID])
        let reopened = try CarryAccountReplica(container: replica.context.container, accountID: replica.accountID)
        XCTAssertEqual(try reopened.abandonedPublicationRequests(), [command.requestID])
        try reopened.didReleaseAbandonedPublication(command.requestID)
        XCTAssertTrue(try reopened.abandonedPublicationRequests().isEmpty)
    }
}
