import XCTest
import SwiftData
@testable import Carry

/// Native persistence and the actual loopback HTTP/PostgreSQL graph protocol.
/// Authentication is explicitly synthetic; no user account or files are used.
@MainActor
final class NativeTreeIntentTests: XCTestCase {
    private struct Fixture: Decodable { let accountID: UUID; let fields: [String: CarryGraphValue]; let bearer: String? }
    private struct State {
        let container: ModelContainer
        let replica: CarryAccountReplica
        let transport: CarryGraphTransport
        let trip: UUID, section: UUID, item: UUID
        let observed: [UUID: CarryGraphEntity]
        var ids: [UUID] { [trip, section, item] }
        func tree(_ id: UUID, deleted: Bool, members: [UUID]? = nil, baseline: CarryGraphEntity? = nil) -> CarryNativeObservedTreeChange {
            CarryNativeObservedTreeChange(id: id, kind: id == trip ? "trip" : id == section ? "section" : "packingItem",
                isDeleted: deleted, observed: baseline ?? observed[id], memberIDs: members ?? ids)
        }
    }
    private func container() throws -> ModelContainer {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CarryTreeIntent-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try CarryAccountReplica.container(at: folder.appendingPathComponent("account.store"))
    }
    private func seed(using existing: State? = nil) async throws -> State {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8891"))
        var request = URLRequest(url: url.appendingPathComponent("__fixture"))
        request.httpMethod = existing == nil ? "POST" : "GET"
        let (bytes, _) = try await URLSession.shared.data(for: request)
        let fixture = try JSONDecoder().decode(Fixture.self, from: bytes)
        let token = fixture.bearer ?? "synthetic-native-qa"
        let transport = existing?.transport ?? CarryGraphTransport(configuration: CarryAccountConfiguration(projectURL: url,
            publishableKey: "sb_publishable_synthetic_only"), accessToken: { token })
        let container = try container(), replica = try CarryAccountReplica(container: container, accountID: existing?.replica.accountID ?? fixture.accountID)
        let trip = UUID(), section = UUID(), item = UUID()
        try replica.edit([
            CarryGraphEntity(id: trip, kind: "trip", parentID: nil, version: 0, subtreeVersion: 0, fields: fixture.fields, fieldVersions: [:]),
            CarryGraphEntity(id: section, kind: "section", parentID: trip, version: 0, subtreeVersion: 0,
                fields: ["title": .string("Synthetic"), "sortOrder": .integer(0)], fieldVersions: [:]),
            CarryGraphEntity(id: item, kind: "packingItem", parentID: section, version: 0, subtreeVersion: 0,
                fields: ["name": .string("Synthetic"), "quantity": .integer(1), "isPacked": .bool(false), "isAlert": .bool(false), "sortOrder": .integer(0)], fieldVersions: [:])])
        try replica.accept(await transport.apply(XCTUnwrap(replica.nextCommand())))
        return State(container: container, replica: replica, transport: transport, trip: trip, section: section, item: item,
            observed: Dictionary(uniqueKeysWithValues: try replica.localEntities().map { ($0.id, $0) }))
    }
    private func send(_ state: State, replica: CarryAccountReplica? = nil) async throws -> CarryGraphCommand {
        let replica = replica ?? state.replica
        let command = try XCTUnwrap(replica.nextCommand())
        let receipt = try await state.transport.apply(command)
        try replica.accept(receipt)
        return command
    }
    private func drain(_ state: State) async throws {
        for _ in 0..<100 {
            let page = try await state.transport.pull(cursor: state.replica.cursor)
            try state.replica.receive(page)
            if !page.hasMore { return }
        }
        XCTFail("Synthetic history did not finish")
    }
    private func value(_ state: State, _ id: UUID) throws -> CarryGraphEntity {
        try XCTUnwrap(state.replica.localEntities().first { $0.id == id })
    }

    private func externalDelete(_ state: State) async throws {
        try await drain(state)
        let root = try value(state, state.trip)
        _ = try await state.transport.apply(CarryGraphCommand(requestID: UUID(), mutations: [
            CarryGraphMutation(id: root.id, kind: root.kind, action: "delete", baseVersion: root.version,
                baseSubtreeVersion: root.subtreeVersion)]))
        try await drain(state)
    }

    func testExternalDeletionRetainsOfflineDraftAndBlocksProjectionAfterReopen() async throws {
        let state = try await seed()
        var item = try value(state, state.item); item.fields["quantity"] = .integer(7)
        try state.replica.edit(item)
        try await externalDelete(state)
        let reopened = try CarryAccountReplica(container: state.container, accountID: state.replica.accountID)
        XCTAssertEqual(try reopened.deletionConflicts().count, 1)
        XCTAssertNotNil(try reopened.pendingFailure)
        XCTAssertThrowsError(try reopened.nextCommand())
        XCTAssertThrowsError(try reopened.projectionSnapshot())
        let review = try XCTUnwrap(reopened.deletionConflicts().first)
        XCTAssertEqual(review.local.fields["quantity"], .integer(7))
        try reopened.resolveDeletion(review, restore: false)
        XCTAssertTrue(try reopened.deletionConflicts().isEmpty)
        XCTAssertNil(try reopened.nextCommand())
        XCTAssertNoThrow(try reopened.projectionSnapshot())
    }

    func testReviewedRestoreResendsDraftAgainstExactReviewedDeletion() async throws {
        let state = try await seed()
        var item = try value(state, state.item); item.fields["quantity"] = .integer(7)
        try state.replica.edit(item)
        try await externalDelete(state)
        let review = try XCTUnwrap(state.replica.deletionConflicts().first)
        try state.replica.resolveDeletion(review, restore: true)
        _ = try await send(state)
        XCTAssertNil(try value(state, state.item).deletedAt)
        XCTAssertEqual(try value(state, state.item).fields["quantity"], .integer(7))
        XCTAssertNil(try state.replica.nextCommand())
    }

    func testUnpublishedChildDetectsDeletedDestinationAncestor() async throws {
        let state = try await seed(), id = UUID()
        try state.replica.edit(CarryGraphEntity(id: id, kind: "packingItem", parentID: state.section,
            version: 0, subtreeVersion: 0, fields: ["name": .string("Offline new item"), "quantity": .integer(1),
                "isPacked": .bool(false), "isAlert": .bool(false), "sortOrder": .integer(2)], fieldVersions: [:]))
        try await externalDelete(state)
        let review = try XCTUnwrap(state.replica.deletionConflicts().first)
        XCTAssertEqual(review.local.id, id)
        try state.replica.resolveDeletion(review, restore: true)
        _ = try await send(state)
        XCTAssertNil(try value(state, id).deletedAt)
    }

    func testEditingHeldDeletedDraftInvalidatesReviewWithoutRestoringIt() async throws {
        let state = try await seed()
        var item = try value(state, state.item); item.fields["quantity"] = .integer(7)
        try state.replica.edit(item); try await externalDelete(state)
        let review = try XCTUnwrap(state.replica.deletionConflicts().first)
        var later = review.local; later.fields["quantity"] = .integer(8)
        try state.replica.edit(later)
        XCTAssertNotNil(try value(state, state.item).deletedAt)
        XCTAssertThrowsError(try state.replica.resolveDeletion(review, restore: false))
        let fresh = try XCTUnwrap(state.replica.deletionConflicts().first)
        XCTAssertEqual(fresh.local.fields["quantity"], .integer(8))
        try state.replica.resolveDeletion(fresh, restore: true)
        _ = try await send(state)
        XCTAssertEqual(try value(state, state.item).fields["quantity"], .integer(8))
    }

    func testDeletionReviewRejectsNewerLocalDraft() async throws {
        let state = try await seed(), id = UUID()
        var item = CarryGraphEntity(id: id, kind: "packingItem", parentID: state.section,
            version: 0, subtreeVersion: 0, fields: ["name": .string("First draft")], fieldVersions: [:])
        try state.replica.edit(item)
        try await externalDelete(state)
        let review = try XCTUnwrap(state.replica.deletionConflicts().first)
        item.fields["name"] = .string("Newer draft"); try state.replica.edit(item)
        XCTAssertThrowsError(try state.replica.resolveDeletion(review, restore: false))
        XCTAssertEqual(try value(state, id).fields["name"], .string("Newer draft"))
        XCTAssertEqual(try state.replica.deletionConflicts().count, 1)
    }

    func testMoveIntoExternallyDeletedDestinationRetainsOriginalMoveBaseline() async throws {
        let state = try await seed()
        let other = try await seed(using: state)
        try await drain(state)
        let original = try value(state, other.item)
        var moved = original; moved.parentID = state.section
        try state.replica.edit(moved)
        try await externalDelete(state)
        let review = try XCTUnwrap(state.replica.deletionConflicts().first)
        XCTAssertEqual(review.local.id, other.item)
        XCTAssertEqual(review.parentBaseline, original.version)
        try state.replica.resolveDeletion(review, restore: true)
        _ = try await send(state)
        XCTAssertEqual(try value(state, other.item).parentID, state.section)
        XCTAssertNil(try state.replica.nextCommand())
    }

    func testDeletionReviewAndRestoreDoNotDecodeUnrelatedPayloads() async throws {
        let state = try await seed()
        var item = try value(state, state.item); item.fields["quantity"] = .integer(9)
        try state.replica.edit(item); try await externalDelete(state)
        let unrelated = CarryReplicaRecord(id: UUID(), payload: Data([0xff]), hasPendingChanges: false)
        unrelated.needsProjection = false
        state.replica.context.insert(unrelated); try state.replica.context.save()
        let review = try XCTUnwrap(state.replica.deletionConflicts().first)
        XCTAssertEqual(Set(review.restoreImpact.map(\.id)), Set(state.ids))
        try state.replica.resolveDeletion(review, restore: true)
        _ = try await send(state)
        XCTAssertNil(try state.replica.nextCommand())
        XCTAssertEqual(unrelated.payload, Data([0xff]))
    }

    func testScalarCommandDoesNotDecodeLiveAncestorPayloads() async throws {
        let state = try await seed()
        var item = try value(state, state.item); item.fields["isPacked"] = .bool(true)
        try state.replica.edit(item)
        let tripID = state.trip
        let parent = try XCTUnwrap(state.replica.context.fetch(FetchDescriptor<CarryReplicaRecord>(
            predicate: #Predicate { $0.id == tripID })).first)
        let original = parent.payload
        parent.payload = Data([0xff]); try state.replica.context.save()
        XCTAssertTrue(try state.replica.deletionConflicts().isEmpty)
        let command = try XCTUnwrap(state.replica.nextCommand())
        XCTAssertEqual(command.mutations.map(\.id), [state.item])
        // Restore the deliberate test corruption; never send corrupted data.
        parent.payload = original; try state.replica.context.save()
    }

    func testExternalDeletionWithoutDraftDoesNotCreateConflict() async throws {
        let state = try await seed(); try await externalDelete(state)
        XCTAssertTrue(try state.replica.deletionConflicts().isEmpty)
        XCTAssertNil(try state.replica.nextCommand())
        XCTAssertNoThrow(try state.replica.projectionSnapshot())
    }

    func testNeverPublishedDeleteAndUndoSurviveReopenWithoutSendingATombstone() throws {
        let container = try container(), owner = UUID()
        let replica = try CarryAccountReplica(container: container, accountID: owner), trip = UUID(), section = UUID()
        try replica.edit([CarryGraphEntity(id: trip, kind: "trip", parentID: nil, version: 0, subtreeVersion: 0,
            fields: ["name": .string("Synthetic")], fieldVersions: [:]),
            CarryGraphEntity(id: section, kind: "section", parentID: trip, version: 0, subtreeVersion: 0,
                fields: ["title": .string("Synthetic")], fieldVersions: [:])])
        try replica.editTrees([CarryNativeObservedTreeChange(id: trip, kind: "trip", isDeleted: true,
            observed: nil, memberIDs: [trip, section])])
        XCTAssertNil(try replica.nextCommand())
        let reopened = try CarryAccountReplica(container: container, accountID: owner)
        XCTAssertTrue(try reopened.localEntities().allSatisfy { $0.deletedAt != nil })
        try reopened.editTrees([CarryNativeObservedTreeChange(id: trip, kind: "trip", isDeleted: false,
            observed: nil, memberIDs: [trip, section])])
        let command = try XCTUnwrap(reopened.nextCommand())
        XCTAssertEqual(command.mutations.count, 2); XCTAssertTrue(command.mutations.allSatisfy { $0.action == "create" })
    }

    func testUndoWhileDeleteIsInFlightRestoresOnlyAfterItsExactReceipt() async throws {
        let state = try await seed()
        try state.replica.editTrees([state.tree(state.trip, deleted: true)])
        let command = try XCTUnwrap(state.replica.nextCommand()), receipt = try await state.transport.apply(command)
        try state.replica.editTrees([state.tree(state.trip, deleted: false)])
        XCTAssertEqual(try state.replica.nextCommand(), command)
        try state.replica.accept(receipt)
        XCTAssertTrue(try state.replica.localEntities().allSatisfy { $0.deletedAt == nil })
        let restore = try await send(state)
        XCTAssertEqual(restore.mutations.map(\.action), ["restore"])
        XCTAssertNotEqual(restore.requestID, command.requestID)
        XCTAssertNil(try state.replica.nextCommand())
    }

    func testIndependentChildDeleteIsNotRevivedByParentRestore() async throws {
        let state = try await seed()
        try state.replica.editTrees([state.tree(state.item, deleted: true, members: [state.item])])
        try state.replica.editTrees([state.tree(state.trip, deleted: true, members: [state.trip, state.section])])
        let deletion = try await send(state)
        XCTAssertEqual(deletion.mutations.map(\.id), [state.item, state.trip])
        let root = try value(state, state.trip), leaf = try value(state, state.item)
        XCTAssertNotEqual(root.deletionBatch, leaf.deletionBatch)
        try state.replica.editTrees([state.tree(state.trip, deleted: false, members: [state.trip, state.section], baseline: root)])
        _ = try await send(state)
        XCTAssertNil(try value(state, state.trip).deletedAt)
        XCTAssertNotNil(try value(state, state.item).deletedAt)
    }

    func testCoveredChildRestoreRemainsFrozenWhenItIsDeletedAgainDuringParentFlight() async throws {
        let state = try await seed()
        try state.replica.editTrees([state.tree(state.trip, deleted: true)])
        _ = try await send(state)
        let root = try value(state, state.trip), leaf = try value(state, state.item)
        try state.replica.editTrees([state.tree(state.trip, deleted: false, baseline: root),
            state.tree(state.item, deleted: false, members: [state.item], baseline: leaf)])
        let restore = try XCTUnwrap(state.replica.nextCommand())
        XCTAssertEqual(restore.mutations.map(\.id), [state.trip])
        let receipt = try await state.transport.apply(restore)
        try state.replica.editTrees([state.tree(state.item, deleted: true, members: [state.item], baseline: leaf)])
        try state.replica.accept(receipt)
        let repeatedDelete = try await send(state)
        XCTAssertEqual(repeatedDelete.mutations.map(\.id), [state.item])
        XCTAssertNil(try value(state, state.trip).deletedAt); XCTAssertNotNil(try value(state, state.item).deletedAt)
    }

    func testCancelDeleteUnhidesRemoteChildrenWhichArrivedAfterThePreview() async throws {
        let state = try await seed(); try await drain(state)
        let preview = try value(state, state.trip)
        try state.replica.editTrees([state.tree(state.trip, deleted: true, baseline: preview)])
        let extra = UUID()
        _ = try await state.transport.apply(CarryGraphCommand(requestID: UUID(), mutations: [CarryGraphMutation(id: extra,
            kind: "packingItem", action: "create", baseVersion: 0, parentID: state.section,
            fields: ["name": .string("External synthetic"), "quantity": .integer(1), "isPacked": .bool(false), "isAlert": .bool(false), "sortOrder": .integer(1)])]))
        try await drain(state)
        XCTAssertNotNil(try value(state, extra).deletedAt)
        try state.replica.editTrees([state.tree(state.trip, deleted: false, baseline: preview)])
        XCTAssertNil(try value(state, extra).deletedAt)
        XCTAssertNil(try state.replica.nextCommand())
    }

    func testOwnPackingAcknowledgementAdvancesTheDeletePreviewButAnUnseenExternalEditDoesNot() async throws {
        for external in [false, true] {
            let state = try await seed()
            var item = try value(state, state.item); item.fields["quantity"] = .integer(2); try state.replica.edit(item)
            let packing = try XCTUnwrap(state.replica.nextCommand())
            try state.replica.editTrees([state.tree(state.trip, deleted: true)])
            if external {
                _ = try await state.transport.apply(CarryGraphCommand(requestID: UUID(), mutations: [CarryGraphMutation(id: state.item,
                    kind: "packingItem", action: "patch", baseVersion: 1, fields: ["isPacked": .bool(true)], fieldVersions: ["isPacked": 1])]))
            }
            try state.replica.accept(await state.transport.apply(packing))
            let deleting = try XCTUnwrap(state.replica.nextCommand())
            if external {
                do { _ = try await state.transport.apply(deleting); XCTFail("Unseen external subtree edit must conflict") }
                catch CarryGraphTransportFailure.conflict { }
            } else {
                try state.replica.accept(await state.transport.apply(deleting))
                XCTAssertNil(try state.replica.nextCommand())
            }
        }
    }

    func testPendingChildFieldsSurviveDeleteAndJoinTheAtomicRestoreCommand() async throws {
        let state = try await seed()
        var item = try value(state, state.item); item.fields["isPacked"] = .bool(true); try state.replica.edit(item)
        try state.replica.editTrees([state.tree(state.trip, deleted: true)])
        let deleting = try await send(state)
        XCTAssertEqual(deleting.mutations.map(\.action), ["delete"])
        let root = try value(state, state.trip)
        try state.replica.editTrees([state.tree(state.trip, deleted: false, baseline: root)])
        let restoring = try await send(state)
        XCTAssertEqual(Set(restoring.mutations.map(\.action)), ["restore", "patch"])
        XCTAssertEqual(try value(state, state.item).fields["isPacked"], .bool(true))
        XCTAssertNil(try state.replica.nextCommand())
    }
}
