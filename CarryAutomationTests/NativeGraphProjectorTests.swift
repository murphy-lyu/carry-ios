import XCTest
import SwiftData
@testable import Carry

@MainActor
final class NativeGraphProjectorTests: XCTestCase {
    private enum Injected: Error { case failed }
    private func database() throws -> ModelContainer {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("CarryNativeProjection-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let schema = Schema(SchemaV1.models + [CarryReplicaRecord.self, CarryReplicaCheckpoint.self, CarryReplicaReceiptCheckpoint.self]
            + CarryNativeChangeJournal.models + CarryNativeGraphProjector.models)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: path.appendingPathComponent("account.store"), cloudKitDatabase: .none)])
    }
    private func graph() throws -> [CarryNativeProjectionEntity] {
        let trip = TripBundle(name: "Synthetic trip", destinationCity: "Tokyo", days: 2, dateRange: "", isDateless: true)
        let section = PackingSection(title: "Clothes"), item = PackingItem(name: "Shirt")
        trip.sections = [section]; section.bundle = trip; section.items = [item]; item.section = section
        let day = ItineraryDay(title: "Day"), stop = ItineraryStop(name: "Synthetic stop"), transport = TransportSegment()
        trip.itineraryDays = [day]; day.bundle = trip; day.stops = [stop]; stop.day = day; day.segments = [transport]; transport.day = day
        let lodging = LodgingStay(name: "Synthetic hotel"); trip.lodgingStays = [lodging]; lodging.bundle = trip
        let photo = StopPhoto(); stop.photos = [photo]; photo.stop = stop
        let a = ItineraryAttachment(kind: .link, displayName: "Stop link"), b = ItineraryAttachment(kind: .link, displayName: "Transport link"), c = ItineraryAttachment(kind: .link, displayName: "Hotel link")
        stop.attachments = [a]; a.stop = stop; transport.attachments = [b]; b.segment = transport; lodging.attachments = [c]; c.stay = lodging
        let library = MyItem(name: "Synthetic library", category: "Clothes")
        let models: [any PersistentModel] = [trip, section, item, day, stop, transport, lodging, photo, a, b, c, library]
        return try models.enumerated().map { index, model in
            let source = try XCTUnwrap(CarryNativeSourceCodec.capture(model))
            let entity = CarryGraphEntity(id: source.metadata.id, kind: source.metadata.kind, parentID: source.metadata.parentID,
                version: 1, subtreeVersion: index + 1, fields: source.metadata.fields,
                fieldVersions: source.metadata.fields.mapValues { _ in 1 })
            return CarryNativeProjectionEntity(local: entity, observed: entity)
        }
    }
    private func changing(_ snapshot: [CarryNativeProjectionEntity], kind: String, field: String, value: CarryGraphValue,
                          observedMatches: Bool = true) throws -> [CarryNativeProjectionEntity] {
        var result = snapshot
        let index = try XCTUnwrap(result.firstIndex { $0.local.kind == kind })
        var local = result[index].local; local.fields[field] = value; local.version += 1; local.subtreeVersion += 100
        local.fieldVersions[field] = local.version
        result[index] = CarryNativeProjectionEntity(local: local, observed: observedMatches ? local : result[index].observed)
        return result
    }

    /// Full required field shape from carry-account-ai/domain.mjs defaults and
    /// create_trip (dateless trips still create a day at sortOrder zero).
    private func aiTrip(timestamp: String) -> [CarryNativeProjectionEntity] {
        let tripID = UUID()
        let fields: [String: CarryGraphValue] = [
            "name": .string("Synthetic AI trip"), "destinationCity": .string(""),
            "days": .integer(0), "dateRange": .string(""),
            "departureDate": .string(timestamp), "createdAt": .string(timestamp),
            "isDateless": .bool(true), "selectedSceneKeys": .array([]),
            "dismissedSurpriseNames": .array([]), "sceneCardDismissed": .bool(false),
            "remindersEnabled": .bool(false), "reminderConfigData": .string(""),
            "countryCode": .string(""), "latitude": .integer(0), "longitude": .integer(0)
        ]
        let trip = CarryGraphEntity(id: tripID, kind: "trip", version: 1, subtreeVersion: 1,
            fields: fields, fieldVersions: fields.mapValues { _ in 1 })
        let day = CarryGraphEntity(id: UUID(), kind: "day", parentID: tripID, version: 1, subtreeVersion: 2,
            fields: ["title": .string(""), "note": .string(""), "sortOrder": .integer(0)],
            fieldVersions: ["title": 1, "note": 1, "sortOrder": 1])
        return [trip, day].map { .init(local: $0, observed: $0) }
    }

    func testAITripFractionalDatesProjectExactInstantsAndPreserveDefaultsAndObservedBaseline() throws {
        let container = try database(), context = ModelContext(container)
        let snapshot = aiTrip(timestamp: "2026-11-01T10:20:30.123Z")
        let owner = UUID(), projector = CarryNativeGraphProjector(accountID: owner)
        let replica = try CarryAccountReplica(container: container, accountID: owner)
        try replica.receive(CarryGraphPage(changes: snapshot.enumerated().map {
            .init(sequence: $0.offset + 1, entity: $0.element.local)
        }, cursor: snapshot.count, hasMore: false))
        _ = try projector.project(snapshot: replica.projectionSnapshot(), in: context)
        let native = try XCTUnwrap(context.fetch(FetchDescriptor<TripBundle>()).first)
        let expected = 1_793_528_430.123
        XCTAssertEqual(native.departureDate.timeIntervalSince1970, expected, accuracy: 0.000_01)
        XCTAssertEqual(native.createdAt.timeIntervalSince1970, expected, accuracy: 0.000_01)
        let source = try XCTUnwrap(CarryNativeSourceCodec.capture(native))
        for (key, value) in snapshot[0].local.fields {
            XCTAssertEqual(source.metadata.fields[key], value, "Default field: \(key)")
        }
        XCTAssertEqual(native.safeItineraryDays.count, 1)
        XCTAssertEqual(native.safeItineraryDays.first?.sortOrder, 0)
        let materialization = try XCTUnwrap(context.fetch(FetchDescriptor<CarryNativeMaterialization>()).first { $0.id == native.id })
        let observed = try JSONDecoder().decode(CarryGraphEntity.self, from: XCTUnwrap(materialization.observedGraphData))
        XCTAssertEqual(observed, snapshot[0].observed)
        let again = try projector.project(snapshot: snapshot, in: context)
        XCTAssertTrue(again.changedTripIDs.isEmpty)
        XCTAssertEqual(native.createdAt.timeIntervalSince1970, expected, accuracy: 0.000_01)
        let journal = CarryNativeChangeJournal(accountID: owner)
        try journal.captureAndSave(context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CarryNativeChange>()).isEmpty)
        native.name = "Synthetic rename after AI projection"
        try journal.captureAndSave(context)
        let changes = try context.fetch(FetchDescriptor<CarryNativeChange>())
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.changedFields, ["name"])
        let bridge = CarryNativeJournalBridge(replica: replica)
        XCTAssertEqual(try bridge.apply(batch: XCTUnwrap(bridge.nextBatch())), .consumed)
        let command = try XCTUnwrap(replica.nextCommand())
        XCTAssertEqual(command.mutations.count, 1)
        XCTAssertEqual(Set(command.mutations[0].fields?.keys.map { $0 } ?? []), ["name"])
        XCTAssertEqual(try CarryNativeSourceCodec.capture(native)?.metadata.fields["createdAt"], snapshot[0].local.fields["createdAt"])
        XCTAssertEqual(try CarryNativeSourceCodec.capture(native)?.metadata.fields["departureDate"], snapshot[0].local.fields["departureDate"])
    }

    func testLegacyAndOffsetISO8601DatesRemainCompatible() throws {
        let expected = 1_793_528_430.0
        for timestamp in ["2026-11-01T10:20:30Z", "2026-11-01T18:20:30+08:00", "2026-11-01T18:20:30.000+08:00"] {
            let context = ModelContext(try database())
            _ = try CarryNativeGraphProjector(accountID: UUID()).project(snapshot: aiTrip(timestamp: timestamp), in: context)
            let native = try XCTUnwrap(context.fetch(FetchDescriptor<TripBundle>()).first)
            XCTAssertEqual(native.createdAt.timeIntervalSince1970, expected, accuracy: 0.000_01)
            XCTAssertEqual(native.departureDate.timeIntervalSince1970, expected, accuracy: 0.000_01)
            let captured = try XCTUnwrap(CarryNativeSourceCodec.capture(native))
            XCTAssertEqual(captured.metadata.fields["createdAt"], .string("2026-11-01T10:20:30Z"))
            XCTAssertEqual(captured.metadata.fields["departureDate"], .string("2026-11-01T10:20:30Z"))
        }
    }

    func testMalformedAIDateRejectsWholeProjectionWithoutPollutingContextOrStoredGraph() throws {
        let container = try database(), context = ModelContext(container)
        let projector = CarryNativeGraphProjector(accountID: UUID())
        let snapshot = aiTrip(timestamp: "2026-11-01T10:20:30.123Z")
        _ = try projector.project(snapshot: snapshot, in: context)
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<TripBundle>()).first)
        let before = try XCTUnwrap(CarryNativeSourceCodec.capture(original))
        var bad = try changing(snapshot, kind: "trip", field: "createdAt", value: .string("invalid-date"))
        bad = try changing(bad, kind: "trip", field: "name", value: .string("Must not be applied"))
        XCTAssertThrowsError(try projector.project(snapshot: bad, in: context)) { error in
            guard case CarryNativeProjectionFailure.invalidGraph = error else { return XCTFail("Wrong failure type") }
        }
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try CarryNativeSourceCodec.capture(original)?.metadata, before.metadata)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<TripBundle>()).count, 1)
        XCTAssertEqual(try CarryNativeSourceCodec.capture(XCTUnwrap(fresh.fetch(FetchDescriptor<TripBundle>()).first))?.metadata, before.metadata)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CarryNativeProjectionCheckpoint>()).count, 2)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<CarryNativeChange>()).isEmpty)
    }

    func testOriginalPhotoProjectionUsesVerifiedLocalTokenAndKeepsItAcrossScalarEdits() throws {
        let owner = UUID(), container = try database(), context = ModelContext(container)
        var snapshot = try graph()
        let index = try XCTUnwrap(snapshot.firstIndex { $0.local.kind == "photo" })
        let assetID = UUID(), token = try CarryAccountAssetToken(accountID: owner, assetID: assetID, sha256: String(repeating: "a", count: 64))
        var photo = snapshot[index].local
        photo.fields["originalAssetID"] = .string(assetID.uuidString)
        photo.fields["assetLocalIdentifier"] = .string("Other-device-unresolvable-identifier")
        snapshot[index] = .init(local: photo, observed: photo)
        let projector = CarryNativeGraphProjector(accountID: owner, resolveAssets: { entity, _ in
            var assets = CarryNativeProjectionAssets()
            if entity.kind == "photo" { assets.originalFileName = token.rawValue; assets.readyAssetIDs = [assetID] }
            return assets
        })
        _ = try projector.project(snapshot: snapshot, in: context)
        let native = try XCTUnwrap(context.fetch(FetchDescriptor<StopPhoto>()).first)
        XCTAssertEqual(native.assetLocalIdentifier, token.rawValue)
        photo.fields["sortOrder"] = .integer(4); photo.version += 1; photo.subtreeVersion += 100
        snapshot[index] = .init(local: photo, observed: photo)
        _ = try projector.project(snapshot: snapshot, in: context)
        XCTAssertEqual(native.assetLocalIdentifier, token.rawValue)
        XCTAssertEqual(native.sortOrder, 4)
    }

    func testCompleteGraphProjectsAllTenKindsAndEveryAttachmentParentInOneSave() throws {
        let container = try database(), context = ModelContext(container), owner = UUID(), snapshot = try graph()
        let projector = CarryNativeGraphProjector(accountID: owner)
        var saves = 0
        let result = try projector.project(snapshot: Array(snapshot.reversed()), in: context, save: { transaction in
            saves += 1; try transaction.save()
        })
        XCTAssertEqual(saves, 1); XCTAssertTrue(result.libraryChanged)
        let fresh = ModelContext(container), trip = try XCTUnwrap(fresh.fetch(FetchDescriptor<TripBundle>()).first)
        XCTAssertEqual(result.changedTripIDs, [trip.id]); XCTAssertEqual(trip.safeSections.first?.items?.first?.name, "Shirt")
        let day = try XCTUnwrap(trip.safeItineraryDays.first), stop = try XCTUnwrap(day.stops?.first)
        XCTAssertEqual(stop.photos?.count, 1); XCTAssertEqual(stop.attachments?.count, 1)
        XCTAssertEqual(day.segments?.first?.attachments?.count, 1); XCTAssertEqual(trip.safeLodgingStays.first?.attachments?.count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CarryNativeMaterialization>()).count, snapshot.count)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CarryNativeProjectionCheckpoint>()).count, snapshot.count)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<CarryNativeChange>()).isEmpty)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<CarryNativeTransaction>()).isEmpty)
    }

    func testUpdatesKeepNativeIdentityAndUseTheActualObservedServerBaseline() throws {
        let container = try database(), context = ModelContext(container), snapshot = try graph()
        let projector = CarryNativeGraphProjector(accountID: UUID())
        _ = try projector.project(snapshot: snapshot, in: context)
        let held = try XCTUnwrap(context.fetch(FetchDescriptor<PackingItem>()).first)
        let changed = try changing(snapshot, kind: "packingItem", field: "isPacked", value: .bool(true), observedMatches: false)
        let result = try projector.project(snapshot: changed, in: context)
        XCTAssertTrue(held === (try context.fetch(FetchDescriptor<PackingItem>()).first))
        XCTAssertTrue(held.isPacked); XCTAssertFalse(result.libraryChanged); XCTAssertEqual(result.changedTripIDs.count, 1)
        let id = held.id
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<CarryNativeMaterialization>(predicate: #Predicate { $0.id == id })).first)
        let observed = try JSONDecoder().decode(CarryGraphEntity.self, from: XCTUnwrap(row.observedGraphData))
        XCTAssertEqual(observed.fields["isPacked"], .bool(false))
        let source = try JSONDecoder().decode(CarryNativeSourceMetadata.self, from: row.sourceData)
        XCTAssertEqual(source.fields["isPacked"], .bool(true))
        let replay = try projector.project(snapshot: changed, in: context)
        XCTAssertTrue(replay.changedTripIDs.isEmpty); XCTAssertFalse(replay.libraryChanged)
    }

    func testVersionOnlyAdvanceDoesNotResolveAssetsOrReportUserVisibleChanges() throws {
        let container = try database(), context = ModelContext(container)
        var calls = 0
        let projector = CarryNativeGraphProjector(accountID: UUID(), resolveAssets: { _, _ in calls += 1; return CarryNativeProjectionAssets() })
        let snapshot = try graph(); _ = try projector.project(snapshot: snapshot, in: context)
        let before = calls
        let advanced = snapshot.map { entry in
            var local = entry.local; local.version += 1; local.subtreeVersion += 100
            return CarryNativeProjectionEntity(local: local, observed: local)
        }
        let result = try projector.project(snapshot: advanced, in: context)
        XCTAssertEqual(calls, before); XCTAssertTrue(result.changedTripIDs.isEmpty); XCTAssertFalse(result.libraryChanged)
    }

    func testTombstonesDeleteTheGraphAndRollbackPreservesBothModelsAndBaselines() throws {
        let container = try database(), context = ModelContext(container), snapshot = try graph()
        let projector = CarryNativeGraphProjector(accountID: UUID())
        _ = try projector.project(snapshot: snapshot, in: context)
        let deleted = snapshot.map { entry in
            var local = entry.local; local.deletedAt = "2026-10-30T00:00:00Z"; local.deletionBatch = UUID()
            local.version += 1; local.subtreeVersion += 100
            return CarryNativeProjectionEntity(local: local, observed: local)
        }
        XCTAssertThrowsError(try projector.project(snapshot: deleted, in: context, save: { _ in throw Injected.failed }))
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<TripBundle>()).count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ItineraryAttachment>()).count, 3)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<CarryNativeMaterialization>()).allSatisfy { !$0.locallyDeleted })
        let result = try projector.project(snapshot: deleted, in: fresh)
        XCTAssertEqual(result.changedTripIDs.count, 1); XCTAssertTrue(result.libraryChanged)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ItineraryAttachment>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CarryNativeMaterialization>()).allSatisfy { $0.locallyDeleted })
    }

    func testIncompleteParentsWrongKindsAndPendingNativeWorkAreRejectedBeforeProjection() throws {
        for mode in 0..<6 {
            let container = try database(), context = ModelContext(container), owner = UUID()
            var snapshot = try graph()
            switch mode {
            case 0: snapshot.removeAll { $0.local.kind == "trip" }
            case 1:
                let index = try XCTUnwrap(snapshot.firstIndex { $0.local.kind == "packingItem" })
                var local = snapshot[index].local; local.parentID = snapshot.first { $0.local.kind == "stop" }?.local.id
                snapshot[index] = CarryNativeProjectionEntity(local: local, observed: local)
            case 2: context.insert(CarryNativeTransaction(id: UUID(), sequence: 1, changeCount: 1)); try context.save()
            case 3: context.insert(CarryNativeJournalOwner(accountID: UUID())); try context.save()
            case 4:
                let local = CarryGraphEntity(id: UUID(), kind: "unsupported", parentID: nil, version: 1, subtreeVersion: 1, fields: [:], fieldVersions: [:])
                snapshot.append(CarryNativeProjectionEntity(local: local, observed: local))
            default:
                context.insert(CarryNativeChange(transactionID: UUID(), ordinal: 0, entityID: UUID(), kind: "trip", action: "upsert",
                    sourceData: Data(), previousSourceData: nil, observedGraphData: nil, changedFields: [], parentChanged: false, thumbnailChanged: false, thumbnailData: nil))
                try context.save()
            }
            XCTAssertThrowsError(try CarryNativeGraphProjector(accountID: owner).project(snapshot: snapshot, in: context))
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
        }
    }

    func testUnreadyAssetsNeverReplaceUsableLocalFilesAndOrdinaryEditsDoNotReresolveThem() throws {
        let container = try database(), context = ModelContext(container)
        var snapshot = try graph(), fileID = UUID(), ready = true, assetCalls = 0
        let attachmentIndex = try XCTUnwrap(snapshot.firstIndex { $0.local.kind == "attachment" })
        var attachment = snapshot[attachmentIndex].local
        attachment.fields["fileName"] = .string("remote-name.pdf"); attachment.fields["fileAssetID"] = .string(fileID.uuidString)
        snapshot[attachmentIndex] = CarryNativeProjectionEntity(local: attachment, observed: attachment)
        let projector = CarryNativeGraphProjector(accountID: UUID(), resolveAssets: { entity, _ in
            if entity.id == attachment.id {
                assetCalls += 1
                guard ready else { throw CarryNativeProjectionFailure.assetUnavailable }
                return CarryNativeProjectionAssets(localFileName: "verified-local.pdf", readyAssetIDs: [fileID])
            }
            return CarryNativeProjectionAssets()
        })
        _ = try projector.project(snapshot: snapshot, in: context)
        XCTAssertEqual(assetCalls, 1)
        snapshot = try changing(snapshot, kind: "attachment", field: "displayName", value: .string("Renamed"))
        _ = try projector.project(snapshot: snapshot, in: context)
        XCTAssertEqual(assetCalls, 1)
        let id = attachment.id
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItineraryAttachment>(predicate: #Predicate { $0.id == id })).first?.fileName, "verified-local.pdf")
        fileID = UUID(); ready = false
        snapshot = try changing(snapshot, kind: "attachment", field: "fileAssetID", value: .string(fileID.uuidString))
        XCTAssertThrowsError(try projector.project(snapshot: snapshot, in: context))
        let persisted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<ItineraryAttachment>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(persisted.fileName, "verified-local.pdf"); XCTAssertEqual(persisted.displayName, "Renamed")
    }

    func testLocalCreationHasNoInventedServerBaselineAndDirtyBusinessContextIsRejected() throws {
        let container = try database(), context = ModelContext(container), owner = UUID()
        let local = CarryGraphEntity(id: UUID(), kind: "trip", parentID: nil, version: 0, subtreeVersion: 0,
            fields: ["name": .string("Unacknowledged")], fieldVersions: [:])
        let projector = CarryNativeGraphProjector(accountID: owner)
        _ = try projector.project(snapshot: [CarryNativeProjectionEntity(local: local, observed: nil)], in: context)
        XCTAssertNil(try context.fetch(FetchDescriptor<CarryNativeMaterialization>()).first?.observedGraphData)
        let trip = try XCTUnwrap(context.fetch(FetchDescriptor<TripBundle>()).first); trip.name = "Not saved"
        XCTAssertThrowsError(try projector.project(snapshot: [CarryNativeProjectionEntity(local: local, observed: nil)], in: context))
        XCTAssertEqual(trip.name, "Not saved")
    }

    func testCandidateProjectionDoesNotEncodeOrResolveUnrelatedPayloadsAndStillChecksTheWholeGraph() throws {
        let container = try database(), context = ModelContext(container)
        var resolutions = 0
        let projector = CarryNativeGraphProjector(accountID: UUID(), resolveAssets: { _, _ in
            resolutions += 1; return CarryNativeProjectionAssets()
        })
        let original = try graph(); _ = try projector.project(snapshot: original, in: context)
        let before = resolutions
        var edited = try changing(original, kind: "packingItem", field: "isPacked", value: .bool(true))
        let itemID = try XCTUnwrap(edited.first { $0.local.kind == "packingItem" }?.local.id)
        let unrelatedIndex = try XCTUnwrap(edited.firstIndex { $0.local.kind == "transport" })
        var unreadable = edited[unrelatedIndex].local
        // Encoding or parsing an unrelated wire payload must fail deterministically.
        // The caller's dirty-set contract says this entity is unchanged; its
        // malformed synthetic bytes must not be projected or persisted either.
        unreadable.fields["distanceMeters"] = .number(.nan)
        edited[unrelatedIndex] = CarryNativeProjectionEntity(local: unreadable, observed: unreadable)
        let result = try projector.project(snapshot: edited, candidateIDs: [itemID], in: context)
        XCTAssertEqual(resolutions, before)
        XCTAssertTrue(try XCTUnwrap(context.fetch(FetchDescriptor<PackingItem>()).first).isPacked)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TransportSegment>()).first?.distanceMeters, 0)
        XCTAssertEqual(result.changedTripIDs.count, 1)
        var missingParent = edited
        missingParent.removeAll { $0.local.kind == "trip" }
        XCTAssertThrowsError(try projector.project(snapshot: missingParent, candidateIDs: [itemID], in: context))
    }

    func testMissingProjectionCheckpointsAndCandidateTombstonesAreAlwaysApplied() throws {
        let container = try database(), context = ModelContext(container), snapshot = try graph()
        let projector = CarryNativeGraphProjector(accountID: UUID())
        // Empty caller dirty set must not omit bootstrap entities.
        _ = try projector.project(snapshot: snapshot, candidateIDs: [], in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CarryNativeProjectionCheckpoint>()).count, snapshot.count)
        let index = try XCTUnwrap(snapshot.firstIndex { $0.local.kind == "packingItem" })
        var removed = snapshot, tombstone = snapshot[index].local
        tombstone.deletedAt = "2026-10-30T00:00:00Z"; tombstone.version += 1; tombstone.subtreeVersion += 100
        removed[index] = CarryNativeProjectionEntity(local: tombstone, observed: tombstone)
        let result = try projector.project(snapshot: removed, candidateIDs: [tombstone.id], in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PackingItem>()).isEmpty)
        XCTAssertEqual(result.changedTripIDs.count, 1)
        let id = tombstone.id
        XCTAssertTrue(try XCTUnwrap(context.fetch(FetchDescriptor<CarryNativeMaterialization>(predicate: #Predicate { $0.id == id })).first).locallyDeleted)
    }

    func testSurvivingItemMovesOutBeforeItsOldParentIsDeletedInTheSameProjection() throws {
        let container = try database(), context = ModelContext(container)
        let projector = CarryNativeGraphProjector(accountID: UUID())
        var snapshot = try graph()
        _ = try projector.project(snapshot: snapshot, in: context)
        let held = try XCTUnwrap(context.fetch(FetchDescriptor<PackingItem>()).first)
        let oldIndex = try XCTUnwrap(snapshot.firstIndex { $0.local.kind == "section" })
        let itemIndex = try XCTUnwrap(snapshot.firstIndex { $0.local.kind == "packingItem" })
        let parentID = try XCTUnwrap(snapshot[oldIndex].local.parentID), newSectionID = UUID()
        var deletedSection = snapshot[oldIndex].local
        deletedSection.deletedAt = "2026-10-30T00:00:00Z"; deletedSection.version += 1; deletedSection.subtreeVersion += 100
        snapshot[oldIndex] = CarryNativeProjectionEntity(local: deletedSection, observed: deletedSection)
        let newSection = CarryGraphEntity(id: newSectionID, kind: "section", parentID: parentID, version: 1, subtreeVersion: 200,
            fields: ["title": .string("Surviving section"), "sortOrder": .integer(1)], fieldVersions: ["title": 1, "sortOrder": 1])
        snapshot.append(CarryNativeProjectionEntity(local: newSection, observed: newSection))
        var moved = snapshot[itemIndex].local
        moved.parentID = newSectionID; moved.version += 1; moved.subtreeVersion += 100
        snapshot[itemIndex] = CarryNativeProjectionEntity(local: moved, observed: moved)
        let result = try projector.project(snapshot: snapshot, candidateIDs: [deletedSection.id, newSectionID, moved.id], in: context)
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<PackingItem>()).first)
        XCTAssertTrue(item === held); XCTAssertEqual(item.section?.id, newSectionID); XCTAssertEqual(item.name, "Shirt")
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<PackingItem>()).count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<PackingSection>()).map(\.id), [newSectionID])
        XCTAssertEqual(result.changedTripIDs, [parentID])
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<CarryNativeChange>()).isEmpty)
    }

    func testHighPrecisionProjectionKeepsRawObservedDatesAndNoOpJournalWhileOnlyNameChanges() throws {
        for timestamp in ["2026-11-01T10:20:30.123456789Z", "2026-11-01T10:20:30.999999999Z",
                          "2026-11-01T10:20:59.999999999Z", "2026-12-31T23:59:59.999999999Z",
                          "2026-11-01T18:20:30.999999999+08:00", "2026-11-01T10:20:30.000000001Z"] {
            let container = try database(), context = ModelContext(container), owner = UUID()
            let snapshot = aiTrip(timestamp: timestamp), projector = CarryNativeGraphProjector(accountID: owner)
            let replica = try CarryAccountReplica(container: container, accountID: owner)
            try replica.receive(CarryGraphPage(changes: snapshot.enumerated().map {
                .init(sequence: $0.offset + 1, entity: $0.element.local)
            }, cursor: snapshot.count, hasMore: false))
            _ = try projector.project(snapshot: replica.projectionSnapshot(), in: context)
            let native = try XCTUnwrap(context.fetch(FetchDescriptor<TripBundle>()).first)
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<CarryNativeMaterialization>()).first { $0.id == native.id })
            let raw = try JSONDecoder().decode(CarryGraphEntity.self, from: XCTUnwrap(row.observedGraphData))
            XCTAssertEqual(raw.fields["departureDate"], .string(timestamp), "Never rewrite the trusted raw observation")
            let source = try XCTUnwrap(CarryNativeSourceCodec.capture(native))
            let baseline = try JSONDecoder().decode(CarryNativeSourceMetadata.self, from: row.sourceData)
            XCTAssertEqual(baseline, source.metadata)
            let expectedDate = CarryBackupDates.string(from: try XCTUnwrap(CarryBackupDates.parse(timestamp)))
            XCTAssertEqual(source.metadata.fields["departureDate"], .string(expectedDate))
            let journal = CarryNativeChangeJournal(accountID: owner)
            try journal.captureAndSave(context)
            XCTAssertTrue(try context.fetch(FetchDescriptor<CarryNativeChange>()).isEmpty)
            XCTAssertTrue(try projector.project(snapshot: replica.projectionSnapshot(), in: context).changedTripIDs.isEmpty)
            native.name = "Synthetic name-only edit"
            try journal.captureAndSave(context)
            let changes = try context.fetch(FetchDescriptor<CarryNativeChange>())
            XCTAssertEqual(changes.count, 1)
            XCTAssertEqual(changes.first?.changedFields, ["name"])
            let bridge = CarryNativeJournalBridge(replica: replica)
            XCTAssertEqual(try bridge.apply(batch: XCTUnwrap(bridge.nextBatch())), .consumed)
            let command = try XCTUnwrap(replica.nextCommand())
            XCTAssertEqual(Set(command.mutations[0].fields?.keys.map { $0 } ?? []), ["name"])
        }
    }

}
