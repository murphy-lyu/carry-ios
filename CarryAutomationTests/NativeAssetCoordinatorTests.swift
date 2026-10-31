import XCTest
import SwiftData
@testable import Carry

private actor NativeAssetCalls {
    var sourceCount = 0
    var uploaded: [UUID] = []
    var failNext = false
    func source(_ url: URL) -> URL { sourceCount += 1; return url }
    func upload(_ descriptor: CarryAssetDescriptor) throws {
        uploaded.append(descriptor.id)
        if failNext { failNext = false; throw URLError(.networkConnectionLost) }
    }
    func setFailure() { failNext = true }
}

@MainActor
final class NativeAssetCoordinatorTests: XCTestCase {
    private struct State {
        let directory: URL
        let container: ModelContainer
        let context: ModelContext
        let cache: CarryAccountAssetCache
        let coordinator: CarryNativeAssetCoordinator
        let queue: CarryAccountAssetQueue
        let calls: NativeAssetCalls
        let accountID: UUID
        let file: URL
    }
    private func state() throws -> State {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAssetCoordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(CarryAccountAssetQueue.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("queue.store"), cloudKitDatabase: .none)])
        let accountID = UUID(), calls = NativeAssetCalls(), file = directory.appendingPathComponent("source")
        try Data("immutable original".utf8).write(to: file)
        let cache = try CarryAccountAssetCache(root: directory.appendingPathComponent("assets"), accountID: accountID)
        let coordinator = try CarryNativeAssetCoordinator(accountID: accountID, cache: cache,
            resolveSource: { _ in await calls.source(file) }, upload: { descriptor, _ in try await calls.upload(descriptor) })
        let context = ModelContext(container); context.autosaveEnabled = false
        return State(directory: directory, container: container, context: context, cache: cache,
            coordinator: coordinator, queue: .init(accountID: accountID), calls: calls, accountID: accountID, file: file)
    }
    private func change(id: UUID = UUID(), source: String?, previous: String? = nil,
                        observed: CarryGraphEntity? = nil) -> CarryNativeJournalChangeSnapshot {
        let current = CarryNativeSourceMetadata(id: id, kind: "attachment", parentID: UUID(),
            fields: ["fileName": .string(source ?? "")], fileReferences: source.map { ["file": $0] } ?? [:])
        let old = previous.map { CarryNativeSourceMetadata(id: id, kind: "attachment", parentID: current.parentID,
            fields: ["fileName": .string($0)], fileReferences: ["file": $0]) }
        return .init(id: UUID(), ordinal: 0, entityID: id, kind: "attachment", action: "upsert", source: current,
            previousSource: old, observed: observed, changedFields: ["fileName"], parentChanged: false,
            thumbnailChanged: false, thumbnailData: nil)
    }
    private func batch(_ change: CarryNativeJournalChangeSnapshot, state: State) -> CarryNativeJournalBatch {
        .init(accountID: state.accountID, id: UUID(), sequence: 1, createdAt: Date(), changes: [change])
    }

    func testPreparedReplacementRetainsPriorBindingAndImmutableBytes() async throws {
        let state = try state(), id = UUID()
        let initial = change(id: id, source: "old.pdf"), firstBatch = batch(initial, state: state)
        try await state.coordinator.prepareJournal(firstBatch)
        XCTAssertEqual(try state.context.fetchCount(FetchDescriptor<CarryAccountAssetJob>()), 0)
        let first = try state.coordinator.resolveFields(initial, in: state.context)
        try state.context.save(); try state.coordinator.didConsumeJournal(firstBatch)
        let old = try XCTUnwrap(state.queue.binding(entityID: id, slot: "file", in: state.context))
        let oldURL = try await state.cache.verify(old.snapshot)
        try Data("replacement".utf8).write(to: state.file)
        let replacement = change(id: id, source: "new.pdf", previous: "old.pdf")
        try await state.coordinator.prepareJournal(batch(replacement, state: state))
        let resolved = try state.coordinator.resolveFields(replacement, in: state.context)
        XCTAssertEqual(resolved.previousFields["fileAssetID"], first.fields["fileAssetID"])
        XCTAssertNotEqual(resolved.fields["fileAssetID"], first.fields["fileAssetID"])
        XCTAssertEqual(try Data(contentsOf: oldURL), Data("immutable original".utf8))
        XCTAssertEqual(try state.context.fetchCount(FetchDescriptor<CarryAccountAssetJob>()), 2)
    }

    func testUnpreparedAndChangedSnapshotCannotConsumeBindings() async throws {
        let state = try state(), initial = change(source: "file.pdf")
        XCTAssertThrowsError(try state.coordinator.resolveFields(initial, in: state.context))
        try await state.coordinator.prepareJournal(batch(initial, state: state))
        let altered = change(id: initial.entityID, source: "other.pdf")
        XCTAssertThrowsError(try state.coordinator.resolveFields(altered, in: state.context))
        XCTAssertEqual(try state.context.fetchCount(FetchDescriptor<CarryAccountAssetJob>()), 0)
    }

    func testRemovingFileClearsBindingAndUsesPriorObservedReference() async throws {
        let state = try state(), id = UUID(), assetID = UUID()
        let observed = CarryGraphEntity(id: id, kind: "attachment", version: 4, subtreeVersion: 4,
            fields: ["fileAssetID": .string(assetID.uuidString)], fieldVersions: ["fileAssetID": 3])
        let removal = change(id: id, source: nil, previous: "old.pdf", observed: observed)
        try await state.coordinator.prepareJournal(batch(removal, state: state))
        let result = try state.coordinator.resolveFields(removal, in: state.context)
        XCTAssertEqual(result.fields["fileAssetID"], .null)
        XCTAssertEqual(result.previousFields["fileAssetID"], .string(assetID.uuidString))
        XCTAssertNil(try state.queue.binding(entityID: id, slot: "file", in: state.context))
        let count = await state.calls.sourceCount
        XCTAssertEqual(count, 0)
    }

    func testScalarBatchDoesNoAssetIOOrQueueWrites() async throws {
        let state = try state()
        let source = CarryNativeSourceMetadata(id: UUID(), kind: "packingItem", parentID: UUID(),
            fields: ["isPacked": .bool(true)], fileReferences: [:])
        let scalar = CarryNativeJournalChangeSnapshot(id: UUID(), ordinal: 0, entityID: source.id,
            kind: source.kind, action: "upsert", source: source, previousSource: source, observed: nil,
            changedFields: ["isPacked"], parentChanged: false, thumbnailChanged: false, thumbnailData: nil)
        try await state.coordinator.prepareJournal(batch(scalar, state: state))
        let count = await state.calls.sourceCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try state.context.fetchCount(FetchDescriptor<CarryAccountAssetJob>()), 0)
        XCTAssertTrue(state.coordinator.preparedTokens.isEmpty)
    }

    func testInterruptedUploadRequeuesStableAssetAndPublicationWaitsForVerification() async throws {
        let state = try state(), initial = change(source: "file.pdf")
        try await state.coordinator.prepareJournal(batch(initial, state: state))
        let fields = try state.coordinator.resolveFields(initial, in: state.context).fields
        try state.context.save()
        let command = CarryGraphCommand(requestID: UUID(), mutations: [.init(id: initial.entityID, kind: "attachment",
            action: "patch", baseVersion: 1, fields: fields)])
        await state.calls.setFailure()
        do { try await state.coordinator.preparePublication(command, in: state.context); XCTFail("Upload failure cannot publish") }
        catch is URLError {}
        let pending = try XCTUnwrap(state.queue.pendingWork(in: state.context).first)
        XCTAssertFalse(pending.isVerified)
        let reopened = ModelContext(state.container)
        let job = try XCTUnwrap(reopened.fetch(FetchDescriptor<CarryAccountAssetJob>()).first)
        XCTAssertEqual(job.phase, "queued")
        XCTAssertEqual(job.frozenRequestIDs, [command.requestID])
        try await state.coordinator.preparePublication(command, in: state.context)
        XCTAssertTrue(try state.queue.pendingWork(in: state.context).isEmpty)
        let uploads = await state.calls.uploaded
        XCTAssertEqual(uploads, [pending.descriptor.id, pending.descriptor.id])
        try state.coordinator.releasePublication(requestID: command.requestID, in: state.context)
        XCTAssertTrue(try XCTUnwrap(state.context.fetch(FetchDescriptor<CarryAccountAssetJob>()).first).frozenRequestIDs.isEmpty)
    }

    func testUnknownPublicationReferenceFailsClosedAndWrongAccountNeverPrepares() async throws {
        let state = try state(), id = UUID()
        let command = CarryGraphCommand(requestID: UUID(), mutations: [.init(id: UUID(), kind: "attachment",
            action: "patch", baseVersion: 1, fields: ["fileAssetID": .string(id.uuidString)])])
        do { try await state.coordinator.preparePublication(command, in: state.context); XCTFail("No verified ledger proof") }
        catch CarryNativeAssetCoordinatorFailure.publicationNotReady {}
        let foreign = CarryNativeJournalBatch(accountID: UUID(), id: UUID(), sequence: 1, createdAt: Date(), changes: [])
        do { try await state.coordinator.prepareJournal(foreign); XCTFail("Wrong identity") }
        catch CarryNativeAssetCoordinatorFailure.wrongAccount {}
        state.coordinator.close()
        do { try await state.coordinator.preparePublication(command, in: state.context); XCTFail("Closed workspace") }
        catch CarryNativeAssetCoordinatorFailure.closed {}
    }

    func testPriorThumbnailRemovalDoesNotAdoptOlderObservedAsset() async throws {
        let state = try state(), id = UUID(), olderID = UUID()
        let current = CarryNativeSourceMetadata(id: id, kind: "attachment", parentID: UUID(), fields: [:],
            fileReferences: [:], thumbnailPresent: true)
        let previous = CarryNativeSourceMetadata(id: id, kind: "attachment", parentID: current.parentID, fields: [:],
            fileReferences: [:], thumbnailPresent: false)
        let observed = CarryGraphEntity(id: id, kind: "attachment", version: 1, subtreeVersion: 1,
            fields: ["thumbnailAssetID": .string(olderID.uuidString)], fieldVersions: ["thumbnailAssetID": 1])
        let change = CarryNativeJournalChangeSnapshot(id: UUID(), ordinal: 0, entityID: id, kind: "attachment",
            action: "upsert", source: current, previousSource: previous, observed: observed, changedFields: [],
            parentChanged: false, thumbnailChanged: true, thumbnailData: Data("new thumbnail".utf8))
        try await state.coordinator.prepareJournal(batch(change, state: state))
        let resolved = try state.coordinator.resolveFields(change, in: state.context)
        XCTAssertEqual(resolved.previousFields["thumbnailAssetID"], .null)
        XCTAssertNotEqual(resolved.fields["thumbnailAssetID"], .string(olderID.uuidString))
    }

    func testAssetPublicationCannotSaveOrRollbackUnjournaledBusinessChanges() async throws {
        let state = try state()
        let container = try CarryAccountReplica.container(at: state.directory.appendingPathComponent("business.store"))
        let context = ModelContext(container); context.autosaveEnabled = false
        let trip = TripBundle(name: "Unsaved draft", destinationCity: "Tokyo", days: 0, dateRange: "", isDateless: true)
        context.insert(trip)
        let command = CarryGraphCommand(requestID: UUID(), mutations: [.init(id: UUID(), kind: "attachment",
            action: "patch", baseVersion: 1, fields: ["fileAssetID": .string(UUID().uuidString)])])
        do { try await state.coordinator.preparePublication(command, in: context, verifiedRemote: { _ in true }); XCTFail("Wrong write context") }
        catch CarryNativeAssetCoordinatorFailure.invalidState {}
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(trip.name, "Unsaved draft")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TripBundle>()), 0)
    }
}
