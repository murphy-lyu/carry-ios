import XCTest
import SwiftData
@testable import Carry

@MainActor
final class NativeSyncBarrierTests: XCTestCase {
    @MainActor
    private class Transport: CarryGraphTransporting {
        var applied: [UUID] = []
        var pulled = 0
        var afterApply: () -> Void = {}
        var afterPull: () -> Void = {}
        var pullChanges: [CarryGraphChange] = []
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
            applied.append(command.requestID)
            let changes = command.mutations.enumerated().map { index, mutation in
                CarryGraphChange(sequence: index + 1, entity: CarryGraphEntity(id: mutation.id,
                    kind: mutation.kind, parentID: mutation.parentID, version: 1, subtreeVersion: index + 1,
                    fields: mutation.fields ?? [:], fieldVersions: ["name": 1]))
            }
            afterApply()
            return CarryGraphReceipt(status: "saved_to_account", requestID: command.requestID,
                changes: changes, cursor: changes.count)
        }
        func pull(cursor: Int) async throws -> CarryGraphPage {
            pulled += 1
            afterPull()
            let changes = pullChanges.filter { $0.sequence > cursor }
            return CarryGraphPage(changes: changes, cursor: changes.last?.sequence ?? cursor, hasMore: false)
        }
    }

    @MainActor
    private final class StreamingTransport: Transport, CarryGraphStreamingTransporting {
        var splitPages = false
        var beforePage: (Int) -> Void = { _ in }
        var resumedOffsets: [Int] = []
        func applyStreaming(_ command: CarryGraphCommand, progress: CarryGraphReceiptProgress?,
                            receive: @MainActor (CarryGraphReceiptSummary, CarryGraphReceiptPage, Int) async throws -> Void) async throws {
            let receipt = try await apply(command)
            let summary = CarryGraphReceiptSummary(status: receipt.status, requestID: receipt.requestID,
                cursor: receipt.cursor, changeCount: receipt.changes.count)
            let offset = progress?.nextOffset ?? 0
            resumedOffsets.append(offset)
            if splitPages {
                for index in offset..<receipt.changes.count {
                    beforePage(index)
                    try await receive(summary, CarryGraphReceiptPage(requestID: receipt.requestID, cursor: receipt.cursor,
                        changes: [receipt.changes[index]], nextOffset: index + 1,
                        hasMore: index + 1 < receipt.changes.count, changeCount: receipt.changes.count), 0)
                }
                return
            }
            try await receive(summary, CarryGraphReceiptPage(requestID: receipt.requestID, cursor: receipt.cursor,
                changes: receipt.changes, nextOffset: receipt.changes.count, hasMore: false,
                changeCount: receipt.changes.count), 0)
        }
    }

    private func replica() throws -> CarryAccountReplica {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryNativeBarrier-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try CarryAccountReplica(container: CarryAccountReplica.container(at: directory.appendingPathComponent("cache.store")),
            accountID: UUID())
    }

    func testBacklogDefersAllNetworkWorkAndCanResume() async throws {
        let replica = try replica(), transport = Transport()
        var ready = false
        let engine = CarryAccountSyncEngine(replica: replica, transport: transport, drainNativeChanges: { ready })
        let deferred = try await engine.synchronize()
        XCTAssertFalse(deferred); XCTAssertEqual(transport.pulled, 0); XCTAssertTrue(transport.applied.isEmpty)
        ready = true
        let complete = try await engine.synchronize()
        XCTAssertTrue(complete); XCTAssertEqual(transport.pulled, 1)
    }

    func testEditArrivingDuringApplyDefersAcknowledgementAndReusesFrozenRequest() async throws {
        let replica = try replica(), transport = Transport()
        try replica.edit(CarryGraphEntity(id: UUID(), kind: "trip", parentID: nil, version: 0, subtreeVersion: 0,
            fields: ["name": .string("Synthetic")], fieldVersions: [:]))
        let frozen = try XCTUnwrap(replica.nextCommand())
        var ready = true
        transport.afterApply = { ready = false }
        let engine = CarryAccountSyncEngine(replica: replica, transport: transport, drainNativeChanges: { ready })
        let deferred = try await engine.synchronize()
        XCTAssertFalse(deferred); XCTAssertEqual(try replica.nextCommand(), frozen)
        XCTAssertNil(try replica.pendingFailure); XCTAssertEqual(transport.pulled, 0)
        ready = true; transport.afterApply = {}
        let complete = try await engine.synchronize()
        XCTAssertTrue(complete); XCTAssertNil(try replica.nextCommand())
        XCTAssertEqual(transport.applied, [frozen.requestID, frozen.requestID])
    }

    func testEditArrivingDuringPullDoesNotAdvanceReplicaOrProject() async throws {
        let replica = try replica(), transport = Transport()
        transport.pullChanges = [CarryGraphChange(sequence: 1, entity: CarryGraphEntity(id: UUID(), kind: "trip",
            parentID: nil, version: 1, subtreeVersion: 1, fields: ["name": .string("Unshown remote")], fieldVersions: ["name": 1]))]
        var ready = true, projections = 0
        transport.afterPull = { ready = false }
        let engine = CarryAccountSyncEngine(replica: replica, transport: transport,
            drainNativeChanges: { ready }, project: { _, _ in projections += 1 })
        let deferred = try await engine.synchronize()
        XCTAssertFalse(deferred); XCTAssertEqual(projections, 0); XCTAssertEqual(try replica.cursor, 0)
        XCTAssertTrue(try replica.localEntities().isEmpty)
        ready = true; transport.afterPull = {}
        let complete = try await engine.synchronize()
        XCTAssertTrue(complete); XCTAssertEqual(projections, 1)
        XCTAssertEqual(try replica.cursor, 1)
        XCTAssertEqual(try replica.localEntities().first?.fields["name"], .string("Unshown remote"))
        XCTAssertEqual(transport.pulled, 2)
    }

    func testStreamingAcknowledgementWaitsForDurableNativeEdits() async throws {
        let replica = try replica(), transport = StreamingTransport()
        try replica.edit(CarryGraphEntity(id: UUID(), kind: "trip", parentID: nil, version: 0, subtreeVersion: 0,
            fields: ["name": .string("Synthetic streaming")], fieldVersions: [:]))
        let frozen = try XCTUnwrap(replica.nextCommand())
        var ready = true
        transport.afterApply = { ready = false }
        let engine = CarryAccountSyncEngine(replica: replica, transport: transport, drainNativeChanges: { ready })
        let deferred = try await engine.synchronize()
        XCTAssertFalse(deferred)
        XCTAssertNil(try replica.receiptProgress(for: frozen.requestID))
        XCTAssertEqual(try replica.nextCommand(), frozen)
        ready = true; transport.afterApply = {}
        let complete = try await engine.synchronize()
        XCTAssertTrue(complete); XCTAssertNil(try replica.nextCommand())
        XCTAssertEqual(transport.applied, [frozen.requestID, frozen.requestID])
    }

    func testPartialStreamingReceiptRetainsItsOffsetAcrossNativeBacklogAndReopen() async throws {
        let replica = try replica(), transport = StreamingTransport()
        let entities = (0..<2).map { index in CarryGraphEntity(id: UUID(), kind: "trip", parentID: nil,
            version: 0, subtreeVersion: 0, fields: ["name": .string("Synthetic \(index)")], fieldVersions: [:]) }
        try replica.edit(entities)
        let frozen = try XCTUnwrap(replica.nextCommand())
        var ready = true
        transport.splitPages = true
        transport.beforePage = { index in if index == 1 { ready = false } }
        let engine = CarryAccountSyncEngine(replica: replica, transport: transport, drainNativeChanges: { ready })
        let deferred = try await engine.synchronize()
        XCTAssertFalse(deferred)
        XCTAssertEqual(try replica.receiptProgress(for: frozen.requestID)?.nextOffset, 1)
        let firstID = try XCTUnwrap(frozen.mutations.first?.id)
        XCTAssertEqual(try replica.localEntities().first { $0.id == firstID }?.fieldVersions["name"], 1)
        let reopened = try CarryAccountReplica(container: replica.context.container, accountID: replica.accountID)
        XCTAssertEqual(try reopened.nextCommand(), frozen)
        ready = true; transport.beforePage = { _ in }
        let resumed = CarryAccountSyncEngine(replica: reopened, transport: transport, drainNativeChanges: { ready })
        let complete = try await resumed.synchronize()
        XCTAssertTrue(complete)
        XCTAssertEqual(transport.resumedOffsets, [0, 1])
        XCTAssertEqual(transport.applied, [frozen.requestID, frozen.requestID])
        XCTAssertNil(try reopened.receiptProgress(for: frozen.requestID))
        XCTAssertNil(try reopened.nextCommand())
    }
}
