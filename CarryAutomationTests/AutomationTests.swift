import XCTest
import SwiftData
import Combine
@testable import Carry

/// The previous shipped version used VersionedSchema 1.0.0 too. Verify that
/// exact version marker, not only an unversioned store with matching tables.
private enum PreAutomationSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { SchemaV1.models.filter { $0 != AutomationExecutionRecord.self } }
}

@MainActor
final class AutomationTests: XCTestCase {
    private var container: ModelContainer!
    private var store: TripStore!
    private var context: ModelContext!
    private let connectionId = UUID()
    private var allowed: Set<UUID> = []
    private var failAutomationSave = false

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        context.autosaveEnabled = false
        failAutomationSave = false
        store = TripStore(context: context, automationSave: { [weak self] transaction in
            if self?.failAutomationSave == true { throw AutomationError.saveFailed }
            try transaction.save()
        })
        let ready = expectation(description: "Initial data loaded")
        let subscription = store.$automationReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        subscription.cancel()
        allowed = []
    }

    private func operation(_ name: String, tripId: UUID? = nil, entityId: UUID? = nil, fields: [String: AutomationValue] = [:], requestId: UUID = UUID(), revision: String? = nil, expiresAt: Double? = nil) throws -> AutomationOperation {
        let expected = try revision ?? tripId.flatMap { tripId in
            try store.automationSnapshots(allowedTripIds: allowed).first { $0.id == tripId }?.revision
        }
        return AutomationOperation(protocolVersion: 1, connectionId: connectionId, requestId: requestId, name: name,
            arguments: AutomationArguments(requestId: requestId, tripId: tripId, entityId: entityId, expectedRevision: expected, data: fields),
            payloadHash: String(repeating: "a", count: 64), entityId: UUID(), expiresAt: expiresAt ?? Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    }
    @discardableResult private func execute(_ operation: AutomationOperation) throws -> AutomationReceipt {
        try store.executeAutomation(operation, connectionId: connectionId, allowedTripIds: allowed)
    }
    private func trip() throws -> UUID {
        let result = try execute(operation("create_trip", fields: ["name": .string("Tokyo QA"), "isDateless": .bool(false), "departureDate": .string("2030-11-15"), "returnDate": .string("2030-11-20")]))
        let id = try XCTUnwrap(result.entityId)
        allowed.insert(id)
        return id
    }

    func testCreateReadUpdateDeleteRoundTrip() throws {
        let id = try trip()
        let snapshot = try XCTUnwrap(store.automationSnapshots(allowedTripIds: allowed).first)
        XCTAssertEqual(snapshot.days.count, 6)
        XCTAssertEqual(snapshot.departureDate, "2030-11-15")
        try execute(operation("update_trip", tripId: id, fields: ["name": .string("Renamed")]))
        XCTAssertEqual(store.bundle(for: id)?.name, "Renamed")
        try execute(operation("delete_trip", tripId: id))
        XCTAssertNil(store.bundle(for: id))
        let disk = ModelContext(container)
        XCTAssertEqual(try disk.fetchCount(FetchDescriptor<TripBundle>()), 0)
    }

    func testPublishingCommittedGraphChangesInstanceIdentityWithoutChangingTripID() throws {
        let id = try trip()
        let before = try XCTUnwrap(store.bundle(for: id))
        try execute(operation("update_trip", tripId: id, fields: ["name": .string("Updated through Codex")]))
        let after = try XCTUnwrap(store.bundle(for: id))
        XCTAssertEqual(before.id, after.id)
        XCTAssertNotEqual(ObjectIdentifier(before), ObjectIdentifier(after))
        XCTAssertEqual(after.name, "Updated through Codex")
    }

    func testAdditiveSchemaMigrationPreservesExistingTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("legacy.store")
        let originalId = UUID()
        try autoreleasepool {
            let legacySchema = Schema(versionedSchema: PreAutomationSchema.self)
            let old = try ModelContainer(for: legacySchema, configurations: [ModelConfiguration(schema: legacySchema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(old)
            context.insert(TripBundle(id: originalId, name: "Existing trip", destinationCity: "Tokyo", days: 2, dateRange: ""))
            try context.save()
        }
        let schema = Schema(versionedSchema: SchemaV1.self)
        let migrated = try ModelContainer(for: schema, migrationPlan: CarryMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let reader = ModelContext(migrated)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<TripBundle>()).first?.id, originalId)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<AutomationExecutionRecord>()), 0)
    }

    func testInMemoryFallbackCannotExecuteOrPublishSnapshots() async throws {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let memory = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let memoryStore = TripStore(context: ModelContext(memory))
        let ready = expectation(description: "Memory fallback loaded")
        let subscription = memoryStore.$automationReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10); subscription.cancel()
        XCTAssertThrowsError(try memoryStore.automationSnapshots(allowedTripIds: [])) { XCTAssertEqual($0 as? AutomationError, .persistenceUnavailable) }
        let command = try operation("create_trip", fields: ["name": .string("Not durable"), "isDateless": .bool(true)])
        XCTAssertThrowsError(try memoryStore.executeAutomation(command, connectionId: connectionId, allowedTripIds: [])) { XCTAssertEqual($0 as? AutomationError, .persistenceUnavailable) }
        XCTAssertEqual(try ModelContext(memory).fetchCount(FetchDescriptor<TripBundle>()), 0)
    }

    func testMoveReorderAndRemoveStopsPersistTheirRelationships() throws {
        let id = try trip()
        let a = try XCTUnwrap(execute(operation("add_stop", tripId: id, fields: ["name": .string("A"), "dayOrder": .number(0)])).entityId)
        let b = try XCTUnwrap(execute(operation("add_stop", tripId: id, fields: ["name": .string("B"), "dayOrder": .number(0)])).entityId)
        try execute(operation("reorder_stops", tripId: id, fields: ["dayOrder": .number(0), "ids": .array([.string(b.uuidString), .string(a.uuidString)])]))
        XCTAssertEqual(store.bundle(for: id)?.safeItineraryDays.first?.sortedStops.map(\.id), [b, a])
        try execute(operation("move_stop", tripId: id, entityId: a, fields: ["dayOrder": .number(1)]))
        XCTAssertEqual(store.bundle(for: id)?.safeItineraryDays[1].sortedStops.first?.id, a)
        try execute(operation("update_stop", tripId: id, entityId: b, fields: ["name": .string("Renamed"), "note": .string("")]))
        try execute(operation("remove_stop", tripId: id, entityId: a))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ItineraryStop>()), 1)
        XCTAssertEqual(store.bundle(for: id)?.safeItineraryDays.first?.sortedStops.first?.name, "Renamed")
    }

    func testPackingReorderRenameAndCascadingRemoval() throws {
        let id = try trip()
        let a = try XCTUnwrap(execute(operation("add_packing_section", tripId: id, fields: ["name": .string("A")])).entityId)
        let b = try XCTUnwrap(execute(operation("add_packing_section", tripId: id, fields: ["name": .string("B")])).entityId)
        let x = try XCTUnwrap(execute(operation("add_packing_item", tripId: id, fields: ["name": .string("X"), "sectionId": .string(a.uuidString)])).entityId)
        let y = try XCTUnwrap(execute(operation("add_packing_item", tripId: id, fields: ["name": .string("Y"), "sectionId": .string(a.uuidString)])).entityId)
        try execute(operation("reorder_packing_items", tripId: id, fields: ["sectionId": .string(a.uuidString), "ids": .array([.string(y.uuidString), .string(x.uuidString)])]))
        try execute(operation("reorder_packing_sections", tripId: id, fields: ["ids": .array([.string(b.uuidString), .string(a.uuidString)])]))
        try execute(operation("rename_packing_section", tripId: id, entityId: b, fields: ["name": .string("Renamed")]))
        XCTAssertEqual(store.bundle(for: id)?.safeSections.first?.title, "Renamed")
        XCTAssertEqual(store.bundle(for: id)?.safeSections.last?.sortedItems.map(\.id), [y, x])
        try execute(operation("remove_packing_item", tripId: id, entityId: x))
        try execute(operation("remove_packing_section", tripId: id, entityId: a))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PackingItem>()), 0)
        XCTAssertEqual(store.bundle(for: id)?.safeSections.count, 1)
    }

    func testDuplicateDeliveryUsesPersistedReceiptAcrossContextReload() throws {
        let command = try operation("create_trip", fields: ["name": .string("One"), "isDateless": .bool(true)])
        let first = try execute(command)
        let second = try execute(command)
        XCTAssertEqual(first.entityId, second.entityId)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TripBundle>()), 1)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<AutomationExecutionRecord>()).first)
        XCTAssertEqual(try JSONDecoder().decode(AutomationReceipt.self, from: record.receiptData).entityId, first.entityId)
    }

    func testConflictAndOutOfScopeHaveNoWrites() throws {
        let id = try trip()
        let stale = try operation("update_trip", tripId: id, fields: ["name": .string("Wrong")], revision: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try execute(stale)) { XCTAssertEqual($0 as? AutomationError, .conflict) }
        let outside = try operation("delete_trip", tripId: UUID(), revision: "unused")
        XCTAssertThrowsError(try execute(outside)) { XCTAssertEqual($0 as? AutomationError, .unauthorized) }
        XCTAssertEqual(store.bundle(for: id)?.name, "Tokyo QA")
    }

    func testInvalidStopRollsBackAlreadyChangedFields() throws {
        let id = try trip(), day = try XCTUnwrap(store.bundle(for: id)?.safeItineraryDays.first)
        let before = try store.automationSnapshots(allowedTripIds: allowed).first?.revision
        let bad = try operation("add_stop", tripId: id, fields: ["name": .string("Invalid"), "dayOrder": .number(0), "timeZoneId": .string("Not/AZone")])
        XCTAssertThrowsError(try execute(bad))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItineraryStop>()), 0)
        XCTAssertEqual(day.sortedStops.count, 0)
        XCTAssertEqual(try store.automationSnapshots(allowedTripIds: allowed).first?.revision, before)
    }

    func testPackingCategorySurvivesUntilItemIsAddedAndPackedStateIsIdempotent() throws {
        let id = try trip()
        let section = try XCTUnwrap(execute(operation("add_packing_section", tripId: id, fields: ["name": .string("Essentials")])).entityId)
        XCTAssertEqual(store.bundle(for: id)?.safeSections.count, 1)
        let item = try XCTUnwrap(execute(operation("add_packing_item", tripId: id, fields: ["sectionId": .string(section.uuidString), "name": .string("Passport"), "quantity": .number(1)])).entityId)
        let packed = try operation("update_packing_item", tripId: id, entityId: item, fields: ["isPacked": .bool(true)])
        try execute(packed); try execute(packed)
        XCTAssertEqual(store.bundle(for: id)?.packedCount, 1)
        XCTAssertEqual(store.bundle(for: id)?.totalCount, 1)
    }

    func testSingleDayTripDoesNotCreateAnExtraDay() throws {
        let created = try execute(operation("create_trip", fields: ["name": .string("Day trip"), "departureDate": .string("2030-11-15"), "returnDate": .string("2030-11-15")]))
        XCTAssertEqual(store.bundle(for: try XCTUnwrap(created.entityId))?.safeItineraryDays.count, 1)
    }

    func testDatedToDatelessRetainsStopsAndClearsPublishedDates() throws {
        let id = try trip()
        try execute(operation("add_stop", tripId: id, fields: ["name": .string("Museum"), "dayOrder": .number(4)]))
        try execute(operation("update_trip", tripId: id, fields: ["isDateless": .bool(true)]))
        let snapshot = try XCTUnwrap(store.automationSnapshots(allowedTripIds: allowed).first)
        XCTAssertTrue(snapshot.isDateless)
        XCTAssertNil(snapshot.departureDate)
        XCTAssertEqual(snapshot.days.count, 1)
        XCTAssertEqual(snapshot.days.first?.stops.count, 1)
    }

    func testTransportLodgingAndCostUseExistingModels() throws {
        let id = try trip()
        let segment = try execute(operation("add_transport", tripId: id, fields: ["mode": .string("flight"), "carrier": .string("ANA"), "number": .string("NH920"), "fromName": .string("Shanghai"), "toName": .string("Tokyo"), "fromTimeZoneId": .string("Asia/Shanghai"), "toTimeZoneId": .string("Asia/Tokyo"), "departDayOrder": .number(0), "arriveDayOrder": .number(0), "departLocalMinutes": .number(600), "arriveLocalMinutes": .number(840)]))
        XCTAssertNotNil(segment.entityId)
        let stay = try XCTUnwrap(execute(operation("add_lodging", tripId: id, fields: ["name": .string("QA hotel"), "checkInDayOrder": .number(0), "checkOutDayOrder": .number(5)])).entityId)
        try execute(operation("set_cost", tripId: id, entityId: stay, fields: ["entityType": .string("lodging"), "amount": .number(50000), "currencyCode": .string("JPY")]))
        XCTAssertEqual(store.bundle(for: id)?.safeLodgingStays.first?.costAmount, 50000)
        XCTAssertEqual(store.bundle(for: id)?.safeLodgingStays.first?.costCurrencyCode, "JPY")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TransportSegment>()), 1)
    }

    func testExpiredRequestAndPendingLocalEditsAreNotApplied() throws {
        let id = try trip()
        XCTAssertThrowsError(try execute(operation("delete_trip", tripId: id, expiresAt: 1))) { XCTAssertEqual($0 as? AutomationError, .expired) }
        let pending = try operation("delete_trip", tripId: id)
        store.bundle(for: id)?.name = "Unsaved edit"
        XCTAssertThrowsError(try execute(pending)) { XCTAssertEqual($0 as? AutomationError, .busy) }
        XCTAssertEqual(store.bundle(for: id)?.name, "Unsaved edit")
    }

    func testPrivateAttachmentsNeverAppearInProjection() throws {
        _ = try trip()
        let writer = ModelContext(container)
        let trip = try XCTUnwrap(writer.fetch(FetchDescriptor<TripBundle>()).first), day = try XCTUnwrap(trip.safeItineraryDays.first)
        let stop = ItineraryStop(name: "Hotel")
        writer.insert(stop); stop.day = day; day.stops = [stop]
        try writer.save()
        let previous = try store.automationSnapshots(allowedTripIds: allowed).first?.revision
        let attachment = ItineraryAttachment(kind: .link, displayName: "Secret", urlString: "https://example.com/private")
        writer.insert(attachment); attachment.stop = stop; stop.attachments = [attachment]
        try writer.save()
        XCTAssertNotEqual(try store.automationSnapshots(allowedTripIds: allowed).first?.revision, previous)
        let projection = try AutomationCodec.encode(store.automationSnapshots(allowedTripIds: allowed))
        let text = try XCTUnwrap(String(data: projection, encoding: .utf8))
        XCTAssertFalse(text.contains("Secret")); XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("attachment"))
    }

    func testPrivateRevisionUsesAStableDeviceKeyInsteadOfAnUnkeyedGuessableHash() throws {
        let data = ["bookingCode": "123456"]
        let first = try AutomationCodec.privateDigest(data)
        XCTAssertEqual(first, try AutomationCodec.privateDigest(data))
        XCTAssertNotEqual(first, try AutomationCodec.digest(data))
        XCTAssertEqual(first.count, 64)
    }

    func testProtocolRejectsMalformedValuesAndReusedRequestContents() throws {
        XCTAssertThrowsError(try AutomationCodec.date("2030-02-30"))
        XCTAssertThrowsError(try AutomationFields(values: ["quantity": .number(1.5)]).integer("quantity", range: 1...999))
        XCTAssertThrowsError(try AutomationFields(values: ["isPacked": .number(1)]).bool("isPacked"))
        let first = try operation("create_trip", fields: ["name": .string("One"), "isDateless": .bool(true)])
        try execute(first)
        let changed = AutomationOperation(protocolVersion: 1, connectionId: connectionId, requestId: first.requestId, name: first.name,
            arguments: AutomationArguments(requestId: first.requestId, tripId: nil, entityId: nil, expectedRevision: nil, data: ["name": .string("Other"), "isDateless": .bool(true)]),
            payloadHash: first.payloadHash, entityId: first.entityId, expiresAt: first.expiresAt)
        XCTAssertThrowsError(try execute(changed)) { XCTAssertEqual($0 as? AutomationError, .requestReused) }
    }

    func testSaveFailureLeavesObservedModelsAndStoredReceiptUntouched() throws {
        let id = try trip()
        let original = try XCTUnwrap(store.bundle(for: id))
        let before = try context.fetchCount(FetchDescriptor<AutomationExecutionRecord>())
        let command = try operation("update_trip", tripId: id, fields: ["name": .string("Should not survive")])
        failAutomationSave = true
        XCTAssertThrowsError(try execute(command)) { XCTAssertEqual($0 as? AutomationError, .saveFailed) }
        XCTAssertEqual(original.name, "Tokyo QA")
        let reader = ModelContext(container)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<TripBundle>()).first?.name, "Tokyo QA")
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<AutomationExecutionRecord>()), before)
    }

    func testNamedEmptyCategorySurvivesAStoreRestart() async throws {
        let id = try trip()
        try execute(operation("add_packing_section", tripId: id, fields: ["name": .string("Later")]))
        let reopened = TripStore(context: ModelContext(container))
        let ready = expectation(description: "Reopened store loaded")
        let subscription = reopened.$automationReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        subscription.cancel()
        XCTAssertEqual(reopened.bundle(for: id)?.safeSections.first?.title, "Later")
    }

    func testDuplicateTripUsesIndependentGraphAndResetsPacking() throws {
        let id = try trip()
        let section = try XCTUnwrap(execute(operation("add_packing_section", tripId: id, fields: ["name": .string("Essentials")])).entityId)
        try execute(operation("add_packing_item", tripId: id, fields: ["sectionId": .string(section.uuidString), "name": .string("Passport"), "isPacked": .bool(true)]))
        let copyId = try XCTUnwrap(execute(operation("duplicate_trip", tripId: id, fields: ["name": .string("Copy")])).entityId)
        let copy = try XCTUnwrap(store.bundle(for: copyId)), original = try XCTUnwrap(store.bundle(for: id))
        XCTAssertEqual(copy.name, "Copy")
        XCTAssertEqual(copy.packedCount, 0)
        XCTAssertEqual(original.packedCount, 1)
        XCTAssertNotEqual(copy.safeSections.first?.id, original.safeSections.first?.id)
        XCTAssertNotEqual(copy.safeItineraryDays.first?.id, original.safeItineraryDays.first?.id)
    }

    func testAirportQueryIsReadOnlyAndReceiptSurvivesRetry() async throws {
        let command = try operation("search_airports", fields: ["query": .string("NRT")])
        let first = try await store.executeAutomationQuery(command, connectionId: connectionId, allowedTripIds: [])
        let second = try await store.executeAutomationQuery(command, connectionId: connectionId, allowedTripIds: [])
        XCTAssertEqual(first.data, second.data)
        guard case .array(let results) = first.data?["results"] else { return XCTFail("Missing query results") }
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TripBundle>()), 0)
    }

    func testRoutePreviewDoesNotWriteAndRequiresTripGrant() async throws {
        let id = try trip()
        for (name, lat, lon) in [("A", 35.0, 139.0), ("B", 35.5, 139.6), ("C", 35.1, 139.1), ("D", 35.6, 139.7)] {
            try execute(operation("add_stop", tripId: id, fields: ["name": .string(name), "dayOrder": .number(0), "latitude": .number(lat), "longitude": .number(lon)]))
        }
        let before = try store.automationSnapshots(allowedTripIds: allowed).first
        let command = try operation("preview_route", tripId: id, fields: ["dayOrder": .number(0)])
        do { _ = try await store.executeAutomationQuery(command, connectionId: connectionId, allowedTripIds: []) ; XCTFail("Unauthorized query accepted") }
        catch { XCTAssertEqual(error as? AutomationError, .unauthorized) }
        let receipt = try await store.executeAutomationQuery(command, connectionId: connectionId, allowedTripIds: allowed)
        XCTAssertEqual(receipt.data?["distanceBasis"], .string("straight_line_not_road_distance"))
        XCTAssertEqual(try store.automationSnapshots(allowedTripIds: allowed).first?.revision, before?.revision)
        guard case .array(let ids) = receipt.data?["ids"] else { return XCTFail("Missing route") }
        XCTAssertEqual(ids.first, .string(try XCTUnwrap(before?.days.first?.stops.first?.id).uuidString))
        XCTAssertEqual(ids.last, .string(try XCTUnwrap(before?.days.first?.stops.last?.id).uuidString))
    }

    func testLibraryRequiresSeparateGrantAndKeepsTripListsIndependent() throws {
        let revision = try store.automationLibrarySnapshot().revision
        let command = try operation("add_my_item", fields: ["name": .string("Camera"), "defaultQuantity": .number(1)], revision: revision)
        XCTAssertThrowsError(try execute(command)) { XCTAssertEqual($0 as? AutomationError, .unauthorized) }
        let receipt = try store.executeAutomation(command, connectionId: connectionId, allowedTripIds: [], allowLibrary: true)
        let itemId = try XCTUnwrap(receipt.entityId)
        XCTAssertEqual(try store.automationLibrarySnapshot().items.first?.name, "Camera")
        let update = try operation("update_my_item", entityId: itemId, fields: ["defaultQuantity": .number(2)], revision: store.automationLibrarySnapshot().revision)
        _ = try store.executeAutomation(update, connectionId: connectionId, allowedTripIds: [], allowLibrary: true)
        XCTAssertEqual(try store.automationLibrarySnapshot().items.first?.defaultQuantity, 2)
        let remove = try operation("remove_my_item", entityId: itemId, revision: store.automationLibrarySnapshot().revision)
        _ = try store.executeAutomation(remove, connectionId: connectionId, allowedTripIds: [], allowLibrary: true)
        XCTAssertTrue(try store.automationLibrarySnapshot().items.isEmpty)
    }

    func testOldBackupRestoresAndInvalidatesAutomationGrant() throws {
        let id = try trip()
        let file = try XCTUnwrap(DataBackupManager.shared.makeExportFile(trips: store.trips, myItems: []))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var trips = try XCTUnwrap(json["trips"] as? [[String: Any]])
        for key in ["isDateless", "itineraryDays", "lodgingStays", "additionalDestinationsData", "backgroundsData"] { trips[0].removeValue(forKey: key) }
        json["trips"] = trips
        XCTAssertNil(json["credentials"])
        XCTAssertNil(json["automationRecords"])
        let version = store.automationInvalidationVersion
        let restored = try store.restoreFromData(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.trips, 1)
        XCTAssertEqual(store.bundle(for: id)?.name, "Tokyo QA")
        XCTAssertGreaterThan(store.automationInvalidationVersion, version)
    }

    func testInvalidationSurvivesConnectionManagerRecreation() throws {
        guard try AutomationKeychain.load() == nil else { throw XCTSkip("An existing device connection must not be overwritten by QA") }
        let credential = AutomationCredentials(connectionId: UUID(), deviceToken: "synthetic-local-test-credential", clientName: "QA", tripIds: [], scope: "trips:read", cloudAccount: "local-only")
        try AutomationKeychain.save(credential)
        defer { try? AutomationKeychain.clear() }
        try CarryAutomationConnection.invalidatePersistedConnection()
        XCTAssertEqual(try AutomationKeychain.load()?.revocationPending, true)
        let recreated = CarryAutomationConnection()
        XCTAssertEqual(recreated.credentials?.revocationPending, true)
    }

    func testPendingRevocationRetriesWithoutCancellingItsOwnNetworkRequest() async throws {
        guard try AutomationKeychain.load() == nil else { throw XCTSkip("An existing device connection must not be overwritten by QA") }
        var credential = AutomationCredentials(connectionId: UUID(), deviceToken: "synthetic-local-test-credential", clientName: "QA", tripIds: [], scope: "trips:read", cloudAccount: "local-only")
        credential.revocationPending = true
        try AutomationKeychain.save(credential)
        defer { try? AutomationKeychain.clear() }
        let revoked = expectation(description: "Revocation completes from the foreground loop")
        var attempts = 0
        let manager = CarryAutomationConnection(sendData: { request in
            XCTAssertEqual(request.url?.path, "/device/revoke")
            XCTAssertFalse(Task.isCancelled)
            try Task.checkCancellation()
            attempts += 1
            if attempts == 1 { throw AutomationError.network }
            return (Data("{}".utf8), try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let subscription = manager.$credentials.dropFirst().filter { $0 == nil }.prefix(1).sink { _ in revoked.fulfill() }
        manager.start(store: store)
        await fulfillment(of: [revoked], timeout: 12)
        manager.stop(); subscription.cancel()
        XCTAssertNil(try AutomationKeychain.load())
        XCTAssertEqual(attempts, 2)
    }

    func testDeviceIndependentlyRejectsWritesOutsideItsGrantedScope() throws {
        XCTAssertNoThrow(try AutomationAuthorization.validate(operation: "search_airports", scope: "trips:read"))
        XCTAssertThrowsError(try AutomationAuthorization.validate(operation: "create_trip", scope: "trips:read"))
        XCTAssertThrowsError(try AutomationAuthorization.validate(operation: "open_trip", scope: "trips:read"))
        XCTAssertThrowsError(try AutomationAuthorization.validate(operation: "add_my_item", scope: "trips:read trips:write"))
        XCTAssertNoThrow(try AutomationAuthorization.validate(operation: "add_my_item", scope: "library:write"))
    }

    func testServerCannotSilentlyExpandTheLocallyApprovedTripScope() {
        let approved = UUID(), unapproved = UUID(), created = UUID()
        XCTAssertEqual(Set(AutomationAuthorization.approvedTripIds(serverIds: [approved, unapproved], approved: [approved])), [approved])
        XCTAssertEqual(Set(AutomationAuthorization.approvedTripIds(serverIds: [approved, unapproved], approved: [approved], locallyCreated: created)), [approved, created])
    }

    func testCreationCannotReuseAnExistingUnsharedTripUUID() throws {
        let existing = try trip()
        let command = try operation("create_trip", fields: ["name": .string("Collision"), "isDateless": .bool(true)])
        let collision = AutomationOperation(protocolVersion: command.protocolVersion, connectionId: command.connectionId, requestId: command.requestId,
            name: command.name, arguments: command.arguments, payloadHash: command.payloadHash, entityId: existing, expiresAt: command.expiresAt)
        XCTAssertThrowsError(try store.executeAutomation(collision, connectionId: connectionId, allowedTripIds: [])) { XCTAssertEqual($0 as? AutomationError, .invalidInput) }
        XCTAssertEqual(store.bundle(for: existing)?.name, "Tokyo QA")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TripBundle>()), 1)
    }

    func testResolvedDestinationsAndTripReminderPreferenceRoundTrip() throws {
        let id = try trip()
        let destinations: AutomationValue = .array([
            .object(["name": .string("東京"), "countryCode": .string("JP"), "latitude": .number(35.68), "longitude": .number(139.76)]),
            .object(["name": .string("大阪"), "countryCode": .string("JP"), "latitude": .number(34.69), "longitude": .number(135.5)])
        ])
        try execute(operation("update_trip", tripId: id, fields: ["destinations": destinations, "remindersEnabled": .bool(false)]))
        let read = try XCTUnwrap(store.automationSnapshots(allowedTripIds: allowed).first)
        XCTAssertEqual(read.destinationCity, "東京 & 大阪")
        XCTAssertEqual(read.destinations.count, 2)
        XCTAssertEqual(read.destinations[0]["name"], .string("東京"))
        XCTAssertEqual(read.destinations[1]["name"], .string("大阪"))
        XCTAssertFalse(read.remindersEnabled)
        XCTAssertEqual(store.bundle(for: id)?.countryCode, "JP")
    }

    func testRecommendationPreviewAndSelectedMergePreservePackedItems() async throws {
        let id = try trip()
        let preview = try await store.executeAutomationQuery(operation("get_packing_recommendations", tripId: id), connectionId: connectionId, allowedTripIds: allowed)
        guard case .array(let sections) = preview.data?["sections"], case .object(let first) = sections.first,
              case .array(let items) = first["items"], case .object(let item) = items.first, case .string(let name) = item["name"] else { return XCTFail("Missing recommendations") }
        XCTAssertEqual(store.bundle(for: id)?.totalCount, 0)
        try execute(operation("apply_packing_recommendations", tripId: id, fields: ["selectedNames": .array([.string(name)])]))
        let packedId = try XCTUnwrap(store.bundle(for: id)?.safeSections.flatMap(\.sortedItems).first?.id)
        try execute(operation("update_packing_item", tripId: id, entityId: packedId, fields: ["isPacked": .bool(true)]))
        try execute(operation("apply_packing_recommendations", tripId: id, fields: ["selectedNames": .array([.string(name)])]))
        XCTAssertEqual(store.bundle(for: id)?.totalCount, 1)
        XCTAssertEqual(store.bundle(for: id)?.packedCount, 1)
    }

    func testOpenTripOnlyAllowsAuthorizedExistingTripAndKnownFace() async throws {
        let id = try trip()
        let receipt = try await store.executeAutomationQuery(operation("open_trip", tripId: id, fields: ["face": .string("packing")]), connectionId: connectionId, allowedTripIds: allowed)
        XCTAssertEqual(receipt.data?["face"], .string("packing"))
        do {
            _ = try await store.executeAutomationQuery(operation("open_trip", tripId: id, fields: ["face": .string("arbitrary")]), connectionId: connectionId, allowedTripIds: allowed)
            XCTFail("Unknown face accepted")
        } catch { XCTAssertEqual(error as? AutomationError, .invalidInput) }
    }

    func testDuplicateCannotSilentlyDropAnUnreadableAttachment() throws {
        let id = try trip()
        let stopId = try XCTUnwrap(execute(operation("add_stop", tripId: id, fields: ["name": .string("With file"), "dayOrder": .number(0)])).entityId)
        let writer = ModelContext(container)
        let stop = try XCTUnwrap(writer.fetch(FetchDescriptor<ItineraryStop>()).first { $0.id == stopId })
        let attachment = ItineraryAttachment(kind: .file, displayName: "Missing QA file", fileName: "missing-qa-file.pdf")
        writer.insert(attachment); stop.attachments = [attachment]; try writer.save()
        let command = try operation("duplicate_trip", tripId: id)
        XCTAssertThrowsError(try execute(command)) { XCTAssertEqual($0 as? AutomationError, .saveFailed) }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TripBundle>()), 1)
    }
}
