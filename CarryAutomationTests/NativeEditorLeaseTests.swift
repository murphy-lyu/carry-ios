import XCTest
import SwiftData
@testable import Carry

@MainActor
final class NativeEditorLeaseTests: XCTestCase {
    private enum Injected: Error { case save }
    @MainActor private final class Reference { weak var store: TripStore? }
    @MainActor private final class Gate {
        var failSave = false
        var holdPreparation = false
        var entered: (() -> Void)?
        var resume: CheckedContinuation<Void, Never>?
    }
    @MainActor private final class Server: CarryGraphTransporting {
        var history: [CarryGraphChange]
        var writes: [CarryGraphCommand] = []
        private let rootID: UUID
        init(_ entity: CarryGraphEntity, day: CarryGraphEntity) {
            rootID = entity.id
            history = [.init(sequence: 1, entity: entity), .init(sequence: 2, entity: day)]
        }
        var current: CarryGraphEntity { history.last(where: { $0.entity.id == rootID })!.entity }
        func remoteName(_ name: String, deleted: Bool = false) {
            var entity = current
            entity.version += 1; entity.subtreeVersion = history.count + 1
            entity.fields["name"] = .string(name); entity.fieldVersions["name"] = entity.version
            entity.deletedAt = deleted ? "2026-11-01T00:00:00Z" : nil
            history.append(.init(sequence: history.count + 1, entity: entity))
        }
        func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
            writes.append(command)
            var entity = current
            for mutation in command.mutations {
                for (key, expected) in mutation.fieldVersions ?? [:] where entity.fieldVersions[key] != expected {
                    throw CarryGraphTransportFailure.conflict(Data("{\"error\":\"field_conflict\"}".utf8))
                }
                entity.version += 1; entity.subtreeVersion = history.count + 1
                for (key, value) in mutation.fields ?? [:] {
                    entity.fields[key] = value; entity.fieldVersions[key] = entity.version
                }
            }
            let change = CarryGraphChange(sequence: history.count + 1, entity: entity)
            history.append(change)
            return .init(status: "saved_to_account", requestID: command.requestID, changes: [change], cursor: change.sequence)
        }
        func pull(cursor: Int) async throws -> CarryGraphPage {
            .init(changes: history.filter { $0.sequence > cursor }, cursor: history.count, hasMore: false)
        }
    }
    @MainActor private final class Fixture {
        let workspace: CarryAccountWorkspace
        let store: TripStore
        let server: Server
        let gate: Gate
        let tripID: UUID
        let groupID = UUID()
        init(accountID: UUID = UUID(), singleDay: Bool = false) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CarryEditor-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try CarryAccountReplica.container(at: root.appendingPathComponent("account.store"))
            let context = ModelContext(database), reference = Reference(), gate = Gate()
            self.gate = gate
            let seed = TripBundle(name: "Name A", destinationCity: "Tokyo", days: 1, dateRange: "", isDateless: true)
            seed.countryCode = "JP"
            seed.departureDate = Calendar.current.startOfDay(for: seed.departureDate)
            if singleDay {
                seed.isDateless = false
                seed.days = 0
                seed.dateRange = TripInfo(departureDate: seed.departureDate, returnDate: seed.departureDate).dateRangeDisplay
            }
            let day = ItineraryDay(sortOrder: 0)
            seed.itineraryDays = [day]; day.bundle = seed
            let metadata = try XCTUnwrap(CarryNativeSourceCodec.capture(seed)).metadata
            let dayMetadata = try XCTUnwrap(CarryNativeSourceCodec.capture(day)).metadata
            tripID = seed.id
            server = Server(.init(id: seed.id, kind: "trip", version: 1, subtreeVersion: 1,
                fields: metadata.fields, fieldVersions: metadata.fields.mapValues { _ in 1 }),
                day: .init(id: day.id, kind: "day", parentID: seed.id, version: 1, subtreeVersion: 2,
                    fields: dayMetadata.fields, fieldVersions: dayMetadata.fields.mapValues { _ in 1 }))
            var hooks = CarryAccountWorkspace.Hooks()
            hooks.didProject = { _ in reference.store?.refresh() }
            hooks.prepareProjection = { _, _ in
                if gate.holdPreparation {
                    gate.entered?()
                    await withCheckedContinuation { gate.resume = $0 }
                }
            }
            workspace = try CarryAccountWorkspace(accountID: accountID, container: database, transport: server,
                businessContext: { reference.store?.businessContext ?? context }, hooks: hooks)
            let writer = workspace.businessSave
            store = TripStore(context: context, persistenceSave: { context in
                if gate.failSave { throw Injected.save }
                try writer(context)
            }, scope: .account(didChange: {}))
            store.nativeEditing = workspace.editing
            reference.store = store
            store.refresh(); workspace.enableSynchronization()
        }
        func sync() async throws -> Bool { try await workspace.synchronize() }
        var trip: TripBundle { get throws { try XCTUnwrap(store.bundle(for: tripID)) } }
        func draft() throws -> TripInfo {
            let value = try trip
            return TripInfo(name: value.name, destinationCity: value.destinationCity,
                departureDate: value.departureDate,
                returnDate: Calendar.current.date(byAdding: .day, value: value.days, to: value.departureDate) ?? value.departureDate,
                isDateless: value.isDateless)
        }
    }

    func testUnsavedTripDraftKeepsObservedFieldVersionAndTriggersConflictAfterPull() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        var draft = try f.draft()
        f.server.remoteName("Name B")
        let result1 = try await f.sync(); XCTAssertFalse(result1)
        XCTAssertEqual(try f.trip.name, "Name A")
        XCTAssertEqual(try f.workspace.replica.localEntities().first(where: { $0.id == f.tripID })?.fields["name"], .string("Name B"))
        draft.name = "Name C"
        XCTAssertTrue(f.store.performEditorSave(groupID: f.groupID) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        lease.close()
        let result2 = try await f.sync(); XCTAssertFalse(result2)
        XCTAssertEqual(f.workspace.state, .conflict)
        XCTAssertEqual(f.server.writes.last?.mutations.first?.fieldVersions?["name"], 1)
        XCTAssertEqual(f.server.current.fields["name"], .string("Name B"))
        XCTAssertEqual(try f.trip.name, "Name C")
    }

    func testOnlyActualDraftFieldsAreSentAndUntouchedRemoteNameConverges() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        var draft = try f.draft()
        f.server.remoteName("Name B"); _ = try await f.sync()
        draft.destinationCity = "Osaka"
        draft.resolvedDestinations = [.init(name: "Osaka", countryCode: "JP")]
        XCTAssertTrue(f.store.performEditorSave(groupID: f.groupID) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        lease.close()
        let result3 = try await f.sync(); XCTAssertTrue(result3)
        XCTAssertEqual(try f.trip.name, "Name B")
        XCTAssertEqual(try f.trip.destinationCity, "Osaka")
        XCTAssertNil(f.server.writes.last?.mutations.first?.fields?["name"])
    }


    func testSameDayTripMetadataEditsKeepSingleDayAndUnchangedGraphFields() async throws {
        let f = try Fixture(singleDay: true); _ = try await f.sync()
        let initial = try XCTUnwrap(CarryNativeSourceCodec.capture(f.trip)).metadata.fields
        let dayID = try XCTUnwrap(f.trip.safeItineraryDays.first).id
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        var draft = try f.draft()
        XCTAssertEqual(draft.durationDays, 0)
        draft.name = "Single day renamed"
        XCTAssertTrue(f.store.performEditorSave(groupID: f.groupID) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        let renamed = try XCTUnwrap(CarryNativeSourceCodec.capture(f.trip)).metadata.fields
        XCTAssertEqual(Set(renamed.keys.filter { renamed[$0] != initial[$0] }), ["name"])
        draft = try f.draft()
        draft.destinationCity = "Osaka"
        draft.resolvedDestinations = [.init(name: "Osaka", countryCode: "JP", latitude: 34.6937, longitude: 135.5023)]
        XCTAssertTrue(f.store.performEditorSave(groupID: f.groupID) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        let edited = try XCTUnwrap(CarryNativeSourceCodec.capture(f.trip)).metadata.fields
        let destinationFields: Set<String> = ["destinationCity", "countryCode", "latitude", "longitude", "additionalDestinationsData"]
        XCTAssertTrue(Set(edited.keys.filter { edited[$0] != renamed[$0] }).isSubset(of: destinationFields))
        XCTAssertEqual(try f.trip.days, 0)
        XCTAssertEqual(try f.trip.safeItineraryDays.map(\.id), [dayID])
        lease.close()
        let complete = try await f.sync(); XCTAssertTrue(complete)
        XCTAssertEqual(f.server.current.fields["days"], .integer(0))
        XCTAssertEqual(f.server.current.fields["name"], .string("Single day renamed"))
        XCTAssertEqual(f.server.current.fields["destinationCity"], .string("Osaka"))
        for write in f.server.writes {
            XCTAssertTrue(write.mutations.allSatisfy { $0.kind == "trip" })
            for mutation in write.mutations {
                XCTAssertNil(mutation.fields?["days"])
                XCTAssertNil(mutation.fields?["departureDate"])
                XCTAssertNil(mutation.fields?["dateRange"])
                XCTAssertNil(mutation.fields?["createdAt"])
            }
        }
    }

    func testCancelAndNestedPresentationReleaseOnlyAfterLastOwner() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let parent = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        let child = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        var releases = 0
        f.workspace.editing.didReleaseLastSession = { releases += 1 }
        f.server.remoteName("Name B"); _ = try await f.sync()
        child.close(); child.close()
        XCTAssertTrue(f.workspace.editing.hasActiveSessions)
        let result4 = try await f.sync(); XCTAssertFalse(result4); XCTAssertEqual(try f.trip.name, "Name A")
        parent.close(); parent.close()
        XCTAssertEqual(releases, 1)
        let result5 = try await f.sync(); XCTAssertTrue(result5); XCTAssertEqual(try f.trip.name, "Name B")
        XCTAssertTrue(f.server.writes.isEmpty)
    }

    func testEditorOpeningDuringAsyncPreparationStillBlocksProjection() async throws {
        let f = try Fixture(); _ = try await f.sync()
        f.server.remoteName("Name B")
        let stream = AsyncStream<Void>.makeStream()
        f.gate.holdPreparation = true
        f.gate.entered = { stream.continuation.yield(()) }
        let run = Task { try await f.sync() }
        for await _ in stream.stream { break }
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        f.gate.holdPreparation = false
        f.gate.resume?.resume(); f.gate.resume = nil
        let result6 = try await run.value; XCTAssertFalse(result6)
        XCTAssertEqual(try f.trip.name, "Name A")
        lease.close()
        let result7 = try await f.sync(); XCTAssertTrue(result7); XCTAssertEqual(try f.trip.name, "Name B")
    }

    func testFailedSaveKeepsEditingGateAndRetryRetainsDraftBaseline() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        var draft = try f.draft(); draft.name = "Name C"
        f.server.remoteName("Name B"); _ = try await f.sync()
        f.gate.failSave = true
        XCTAssertFalse(f.store.performEditorSave(groupID: f.groupID) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        XCTAssertTrue(f.workspace.editing.hasActiveSessions)
        XCTAssertEqual(try f.trip.name, "Name A")
        f.gate.failSave = false
        XCTAssertTrue(f.store.performEditorSave(groupID: f.groupID) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        lease.close(); _ = try await f.sync()
        XCTAssertEqual(f.workspace.state, .conflict)
        XCTAssertEqual(f.server.writes.last?.mutations.first?.fieldVersions?["name"], 1)
    }

    func testAccountRevocationInvalidatesEditorsAndCannotWriteOrReleaseAnotherAccount() throws {
        let f = try Fixture(), lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        let other = CarryNativeEditingCoordinator(), otherLease = try XCTUnwrap(other.acquire(groupID: UUID()))
        f.workspace.revokeWriterLease()
        XCTAssertFalse(f.workspace.editing.hasActiveSessions)
        XCTAssertNil(f.store.beginNativeEditing(groupID: f.groupID))
        var called = false
        XCTAssertFalse(f.store.performEditorSave(groupID: f.groupID) { called = true })
        XCTAssertFalse(called)
        lease.close()
        XCTAssertTrue(other.hasActiveSessions)
        otherLease.close(); XCTAssertFalse(other.hasActiveSessions)
    }

    func testOldDismissalCannotReleaseAReplacementPresentation() throws {
        let f = try Fixture(), owner = CarryNativeEditorPresentations()
        owner.begin(key: "editor", store: f.store)
        let oldDismissal = owner.dismissal(key: "editor")
        owner.end(key: "editor")
        owner.begin(key: "editor", store: f.store)
        oldDismissal()
        XCTAssertTrue(f.workspace.editing.hasActiveSessions)
        owner.closeAll()
        XCTAssertFalse(f.workspace.editing.hasActiveSessions)
    }

    func testPresentationCannotUseAnotherAccountsStoreEvenIfThatAccountHasAnEditor() throws {
        let accountID = UUID()
        let first = try Fixture(accountID: accountID), second = try Fixture(accountID: accountID), owner = CarryNativeEditorPresentations()
        owner.begin(key: "editor", store: first.store)
        let otherLease = try XCTUnwrap(second.store.beginNativeEditing(groupID: second.groupID))
        first.workspace.revokeWriterLease()
        var called = false
        XCTAssertFalse(owner.save(store: second.store) { called = true })
        XCTAssertFalse(called)
        XCTAssertTrue(second.workspace.editing.hasActiveSessions)
        owner.closeAll(); otherLease.close()
    }

    func testTwoWindowGroupsCannotCaptureConcurrentDraftsButReadonlyDetailsCanCoexist() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let a = UUID(), b = UUID()
        let detailA = try XCTUnwrap(f.store.beginNativeEditing(groupID: a, readOnly: true))
        let detailB = try XCTUnwrap(f.store.beginNativeEditing(groupID: b, readOnly: true))
        let editorA = try XCTUnwrap(f.store.beginNativeEditing(groupID: a))
        let nestedA = try XCTUnwrap(f.store.beginNativeEditing(groupID: a))
        XCTAssertNil(f.store.beginNativeEditing(groupID: b))
        var draft = try f.draft(); draft.name = "Window A saved"
        var called = false
        XCTAssertFalse(f.store.performEditorSave(groupID: b) { called = true })
        XCTAssertFalse(called)
        XCTAssertTrue(f.store.performEditorSave(groupID: a) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        editorA.close()
        XCTAssertNil(f.store.beginNativeEditing(groupID: b))
        nestedA.close()
        let editorB = try XCTUnwrap(f.store.beginNativeEditing(groupID: b))
        // Window B only reads its draft after the exclusive acquisition succeeds.
        var next = try f.draft()
        XCTAssertEqual(next.name, "Window A saved")
        next.destinationCity = "Osaka"; next.resolvedDestinations = [.init(name: "Osaka", countryCode: "JP")]
        XCTAssertTrue(f.store.performEditorSave(groupID: b) { f.store.updateTripInfo(tripId: f.tripID, info: next) })
        XCTAssertEqual(try f.trip.name, "Window A saved")
        editorB.close(); detailA.close(); detailB.close()
        let complete = try await f.sync(); XCTAssertTrue(complete)
        XCTAssertEqual(f.server.current.fields["name"], .string("Window A saved"))
        XCTAssertEqual(f.server.current.fields["destinationCity"], .string("Osaka"))
    }

    func testBypassingWriterRollsBackBusyWithoutReplacingContextOrLosingOwningDraft() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let ownerGroup = UUID(), otherGroup = UUID()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: ownerGroup))
        let held = try f.trip, context = f.store.businessContext
        var draft = try f.draft(); draft.name = "Owning draft"
        // A legacy void delegation may mutate before attempting persistence.
        // The backstop must rollback, report failure through the outer result,
        // and leave the owning editor's identity map usable.
        let root = TripStore(context: ModelContext(context.container), scope: .account(didChange: {}))
        root.owningStoreProvider = { id in id == f.tripID ? f.store : nil }
        var otherDraft = try f.draft(); otherDraft.name = "Untrusted overwrite"
        XCTAssertFalse(root.performEditorSave(groupID: otherGroup) {
            root.owningStore(for: f.tripID)?.updateTripInfo(tripId: f.tripID, info: otherDraft)
        })
        XCTAssertTrue(root.lastEditorSaveWasBusy)
        XCTAssertTrue(f.store.businessContext === context)
        XCTAssertEqual(held.id, f.tripID)
        XCTAssertEqual(held.name, "Name A")
        XCTAssertEqual(try f.trip.name, "Name A")
        XCTAssertTrue(try context.fetch(FetchDescriptor<CarryNativeChange>()).isEmpty)
        XCTAssertTrue(root.performEditorSave(groupID: ownerGroup) { root.owningStore(for: f.tripID)?.updateTripInfo(tripId: f.tripID, info: draft) })
        lease.close()
        let complete = try await f.sync(); XCTAssertTrue(complete)
        XCTAssertEqual(f.server.current.fields["name"], .string("Owning draft"))
    }

    func testMaintenanceUsesImmutableIdentityAndDoesNotOverwriteAnEditedCity() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        f.store.applyCountryResolution(tripID: f.tripID, expectedCity: "Tokyo",
            primary: ("JP", 35, 139), extras: [], caller: "synthetic_editor_test")
        XCTAssertEqual(try f.trip.latitude, 0)
        var draft = try f.draft(); draft.destinationCity = "Osaka"
        draft.resolvedDestinations = [.init(name: "Osaka", countryCode: "JP", latitude: 34, longitude: 135)]
        XCTAssertTrue(f.store.performEditorSave(groupID: f.groupID) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        lease.close()
        XCTAssertEqual(try f.trip.destinationCity, "Osaka")
        XCTAssertEqual(try f.trip.latitude, 34)
        XCTAssertEqual(try f.trip.longitude, 135)
    }

    func testDeferredMaintenanceIsDiscardedWhenAccountWriterIsRevoked() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        f.store.applyCountryResolution(tripID: f.tripID, expectedCity: "Tokyo",
            primary: ("JP", 35, 139), extras: [], caller: "synthetic_editor_test")
        f.workspace.revokeWriterLease()
        lease.close()
        XCTAssertEqual(try f.trip.latitude, 0)
    }

    func testPresentationBusyUpgradeAndInheritedEmptyChildCannotChangeOwners() throws {
        let f = try Fixture(), parent = CarryNativeEditorPresentations(), other = CarryNativeEditorPresentations()
        XCTAssertTrue(parent.begin(key: "edit", store: f.store))
        XCTAssertFalse(other.begin(key: "edit", store: f.store))
        XCTAssertTrue(other.saveWasBusy)
        XCTAssertTrue(other.begin(key: "detail", store: f.store, readOnly: true))
        XCTAssertFalse(other.begin(key: "detail", store: f.store))
        let child = CarryNativeEditorPresentations()
        child.bind(owner: f.store.nativeEditorIdentity, group: parent.groupIdentity)
        var called = false
        XCTAssertTrue(child.save(store: f.store) { called = true })
        XCTAssertTrue(called)
        XCTAssertFalse(f.store.performEditorSave { XCTFail("Unbound account group must not run") })
        parent.closeAll()
        XCTAssertTrue(other.begin(key: "detail", store: f.store))
        f.workspace.revokeWriterLease()
        XCTAssertFalse(other.begin(key: "detail", store: f.store))
        other.closeAll()
    }

    func testGuestAndUnboundChildOwnerPoliciesDoNotDependOnHavingSessions() throws {
        let f = try Fixture(), guest = TripStore(context: ModelContext(f.workspace.container), scope: .local)
        let presenter = CarryNativeEditorPresentations()
        presenter.bind(owner: guest.nativeEditorIdentity)
        var called = false
        XCTAssertTrue(presenter.save(store: guest) { called = true })
        XCTAssertTrue(called)
        let staleChild = CarryNativeEditorPresentations()
        staleChild.bind(owner: f.store.nativeEditorIdentity, group: UUID())
        called = false
        XCTAssertFalse(staleChild.save(store: guest) { called = true })
        XCTAssertFalse(called)
    }

    func testCompositeCreationStoreLibraryWritesReceiveGroupAndFailureOutcome() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let owner = UUID(), other = UUID()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: owner))
        let facade = TripStore(context: ModelContext(f.workspace.container), scope: .account(didChange: {}))
        facade.creationStoreProvider = { f.store }
        XCTAssertTrue(facade.performEditorSave(groupID: owner) {
            _ = facade.creationStore.addMyItem(name: "Synthetic library draft", category: "Clothes", defaultQuantity: 1)
        })
        let item = try XCTUnwrap(f.store.myItems.first)
        let context = f.store.businessContext
        XCTAssertFalse(facade.performEditorSave(groupID: other) {
            _ = facade.creationStore.addMyItem(name: "Synthetic library draft", category: "Clothes", defaultQuantity: 9)
        })
        XCTAssertTrue(facade.lastEditorSaveWasBusy)
        XCTAssertTrue(f.store.businessContext === context)
        XCTAssertEqual(item.defaultQuantity, 1)
        XCTAssertTrue(facade.performEditorSave(groupID: owner) {
            _ = facade.creationStore.addMyItem(name: "Synthetic library draft", category: "Clothes", defaultQuantity: 2)
        })
        XCTAssertEqual(item.defaultQuantity, 2)
        lease.close()
    }

    func testRejectedCascadeDeleteKeepsOwningParentAndChildModelsUsable() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let owner = UUID(), foreign = UUID()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: owner))
        let heldTrip = try f.trip
        let heldDay = try XCTUnwrap(heldTrip.safeItineraryDays.first)
        let context = f.store.businessContext
        let facade = TripStore(context: ModelContext(context.container), scope: .account(didChange: {}))
        facade.owningStoreProvider = { id in id == f.tripID ? f.store : nil }
        XCTAssertFalse(facade.performEditorSave(groupID: foreign) {
            facade.owningStore(for: f.tripID)?.removeTrip(withId: f.tripID)
        })
        XCTAssertTrue(f.store.businessContext === context)
        XCTAssertEqual(heldTrip.name, "Name A")
        XCTAssertEqual(heldTrip.safeItineraryDays.count, 1)
        XCTAssertEqual(heldDay.bundle?.id, heldTrip.id)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CarryNativeChange>()).isEmpty)
        var draft = try f.draft(); draft.name = "Owner after rejected delete"
        XCTAssertTrue(facade.performEditorSave(groupID: owner) {
            facade.owningStore(for: f.tripID)?.updateTripInfo(tripId: f.tripID, info: draft)
        })
        lease.close()
        let complete = try await f.sync(); XCTAssertTrue(complete)
        XCTAssertEqual(f.server.current.fields["name"], .string("Owner after rejected delete"))
    }

    func testRemoteDeletionDuringDraftRequiresReviewAndNeverRestoresAutomatically() async throws {
        let f = try Fixture(); _ = try await f.sync()
        let lease = try XCTUnwrap(f.store.beginNativeEditing(groupID: f.groupID))
        var draft = try f.draft(); draft.name = "Keep my unsaved draft"
        f.server.remoteName("Name B", deleted: true); _ = try await f.sync()
        XCTAssertEqual(try f.trip.name, "Name A")
        XCTAssertTrue(f.store.performEditorSave(groupID: f.groupID) { f.store.updateTripInfo(tripId: f.tripID, info: draft) })
        lease.close(); _ = try await f.sync()
        XCTAssertEqual(f.workspace.state, .conflict)
        XCTAssertTrue(f.server.writes.isEmpty)
        XCTAssertNotNil(f.server.current.deletedAt)
        XCTAssertEqual(try f.workspace.replica.deletionConflicts().first?.local.fields["name"], .string("Keep my unsaved draft"))
    }
}
