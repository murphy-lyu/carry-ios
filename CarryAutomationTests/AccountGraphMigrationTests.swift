import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AccountGraphMigrationTests: XCTestCase {
    private func backup() throws -> CarryBackup {
        let blob = Data("Synthetic private attachment bytes".utf8)
        let fileName = try XCTUnwrap(AttachmentStore.save(blob, ext: "pdf"))
        let coverName = UUID().uuidString + ".jpg"
        try blob.write(to: BackgroundImageStore.fileURL(named: coverName))
        defer { AttachmentStore.delete(named: fileName); BackgroundImageStore.delete(named: coverName) }
        let item = PackingItem(name: "Camera", quantity: 2, isPacked: true, isAlert: true)
        let trip = TripBundle(name: "Synthetic Tokyo", destinationCity: "Tokyo", days: 3,
            sections: [PackingSection(title: "Equipment", items: [item])])
        trip.countryCode = "JP"; trip.latitude = 35.68; trip.longitude = 139.76
        trip.backgrounds = [TripBackgroundEntry(source: .local, localFileName: coverName, destinationIndex: 0,
            crop: BackgroundCrop(x: 0.1, y: 0.2, width: 0.7, height: 0.6))]
        let stop = ItineraryStop(name: "Museum", latitude: 35.71, longitude: 139.77, plannedStartMinutes: 600,
            stayMinutes: 90, note: "A private note", timeZoneId: "Asia/Tokyo", costAmount: 0, costCurrencyCode: "JPY", fromPhotos: true)
        stop.photos = [StopPhoto(assetLocalIdentifier: "synthetic-photo-id", thumbnailData: Data([1,2,3]), latitude: 35.71, longitude: 139.77)]
        stop.attachments = [ItineraryAttachment(kind: .file, displayName: "Synthetic ticket", fileName: fileName, utiOrExt: "pdf")]
        let segment = TransportSegment(mode: .flight, carrier: "ANA", number: "NH920", fromName: "Shanghai",
            fromTimeZoneId: "Asia/Shanghai", toName: "Tokyo", toTimeZoneId: "Asia/Tokyo",
            departDayOrder: 0, departLocalMinutes: 600, arriveDayOrder: 0, arriveLocalMinutes: 840,
            confirmationCode: "SYNTHETIC", eticketNumber: "SYNTHETIC-ETICKET", costAmount: 1200, costCurrencyCode: "CNY", costHomeAmount: 1200)
        let day = ItineraryDay(sortOrder: 0, title: "Arrival", note: "Day note", stops: [stop]); day.segments = [segment]
        trip.itineraryDays = [day]
        trip.lodgingStays = [LodgingStay(name: "Synthetic Hotel", checkInDayOrder: 0, nights: 2, timeZoneId: "Asia/Tokyo")]
        let custom = MyItem(name: "Lens", collectionName: "Camera", category: "Electronics", quantityMode: .everyNDays, quantityIntervalDays: 2)
        let url = try XCTUnwrap(DataBackupManager.shared.makeExportFile(trips: [trip], myItems: [custom]))
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = CarryBackupDates.decoder()
        return try decoder.decode(CarryBackup.self, from: Data(contentsOf: url))
    }

    private func json(_ backup: CarryBackup) throws -> CarryGraphValue {
        let encoder = CarryBackupDates.encoder()
        return try JSONDecoder().decode(CarryGraphValue.self, from: encoder.encode(backup))
    }

    func testMigrationGraphRoundTripPreservesPacketAndNativeMilliseconds() throws {
        var source = try backup()
        source.createdAt = Date(timeIntervalSince1970: 1_793_528_430.123)
        source.trips[0].createdAt = Date(timeIntervalSince1970: 1_793_528_430.456)
        source.trips[0].departureDate = Date(timeIntervalSince1970: 1_793_528_430.789)
        let owner = UUID(), packet = try CarryGraphMigrationCodec.prepare(source, accountID: owner,
            migrationID: UUID(), tripIDs: Set(source.trips.map(\.id)), includeLibrary: true, includeReminderPreferences: true)
        let restored = try CarryGraphMigrationCodec.restore(packet, accountID: owner)
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, source.createdAt.timeIntervalSince1970, accuracy: 0.000_01)
        XCTAssertEqual(restored.trips[0].createdAt.timeIntervalSince1970, source.trips[0].createdAt.timeIntervalSince1970, accuracy: 0.000_01)
        XCTAssertEqual(restored.trips[0].departureDate.timeIntervalSince1970, source.trips[0].departureDate.timeIntervalSince1970, accuracy: 0.000_01)
        XCTAssertEqual(try json(restored), try json(source))
    }

    func testPreparedMigrationSourcePreservesMillisecondsAndLegacyWholeSecondBytes() async throws {
        for seconds in [1_793_528_430.0, 1_793_528_430.123] {
            let date = Date(timeIntervalSince1970: seconds)
            let trip = TripBundle(name: "Synthetic date migration", destinationCity: "", days: 0, dateRange: "", isDateless: true)
            trip.createdAt = date; trip.departureDate = date
            var source = DataBackupManager.shared.migrationSnapshot(trips: [trip], myItems: [])
            source.createdAt = date
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CarryMigrationPreparation-" + UUID().uuidString)
            let prepared = try await CarryMigrationBackupPreparation.prepare(source, attachments: [:], backgrounds: [:], originalPhotos: [:], directory: root)
            let bytes = try Data(contentsOf: prepared.url)
            let restored = try CarryBackupDates.decoder().decode(CarryBackup.self, from: bytes)
            XCTAssertEqual(restored.createdAt.timeIntervalSince1970, seconds, accuracy: 0.000_01)
            XCTAssertEqual(restored.trips[0].createdAt.timeIntervalSince1970, seconds, accuracy: 0.000_01)
            XCTAssertEqual(restored.trips[0].departureDate.timeIntervalSince1970, seconds, accuracy: 0.000_01)
            if seconds.rounded() == seconds {
                let legacy = JSONEncoder(); legacy.outputFormatting = .sortedKeys; legacy.dateEncodingStrategy = .iso8601
                // Existing whole-second source bytes and therefore SHA256 remain identical.
                XCTAssertEqual(bytes, try legacy.encode(prepared.backup))
            }
            try await CarryMigrationBackupPreparation.discard(root)
        }
    }

    func testIncrementalNativeSourcesCoverEveryBusinessKindAndMatchTheFullBackupContract() throws {
        let fixture = try backup()
        let schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        _ = try DataBackupManager.shared.merge(fixture, into: context)
        var models: [any PersistentModel] = []
        func collect<T: PersistentModel>(_ type: T.Type) throws {
            models += try context.fetch(FetchDescriptor<T>()).map { $0 as any PersistentModel }
        }
        try collect(TripBundle.self); try collect(PackingSection.self); try collect(PackingItem.self)
        try collect(ItineraryDay.self); try collect(ItineraryStop.self); try collect(TransportSegment.self)
        try collect(LodgingStay.self); try collect(StopPhoto.self); try collect(ItineraryAttachment.self); try collect(MyItem.self)
        let sources = try models.map { try XCTUnwrap(CarryNativeSourceCodec.capture($0)) }
        defer {
            for source in sources {
                for (slot, name) in source.metadata.fileReferences {
                    if slot.hasPrefix("background:") { BackgroundImageStore.delete(named: name) }
                    else { AttachmentStore.delete(named: name) }
                }
            }
        }
        let trips = try context.fetch(FetchDescriptor<TripBundle>()), items = try context.fetch(FetchDescriptor<MyItem>())
        let url = try XCTUnwrap(DataBackupManager.shared.makeExportFile(trips: trips, myItems: items))
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail("Cannot remove synthetic export") } }
        let decoder = CarryBackupDates.decoder()
        let full = try decoder.decode(CarryBackup.self, from: Data(contentsOf: url))
        let packet = try CarryGraphMigrationCodec.prepare(full, accountID: UUID(), migrationID: UUID(),
            tripIDs: Set(full.trips.map(\.id)), includeLibrary: true)
        XCTAssertEqual(sources.count, packet.entities.count)
        XCTAssertEqual(Set(sources.map { $0.metadata.kind }), Set(packet.entities.map(\.kind)))
        for source in sources {
            let expected = try XCTUnwrap(packet.entities.first { $0.id == source.metadata.id })
            XCTAssertEqual(source.metadata.parentID, expected.parentID)
            var fields = expected.fields
            fields.removeValue(forKey: "thumbnailAssetID"); fields.removeValue(forKey: "fileAssetID"); fields.removeValue(forKey: "backgroundAssetIDs")
            for key in ["additionalDestinationsData", "backgroundsData"] where expected.kind == "trip" && fields[key] == nil {
                fields[key] = .null
            }
            XCTAssertEqual(source.metadata.fields, fields, "Complete scalar contract for \(expected.kind)")
            let thumbnail = packet.assets.first { $0.entityID == expected.id && $0.slot == "thumbnail" }
            XCTAssertEqual(source.thumbnailData, thumbnail?.bytes)
        }
    }

    func testCompleteNativeGraphAndPrivateBytesRoundTripOffMainActorWithStableAssetIDs() async throws {
        let source = try backup(), account = UUID(), migration = UUID()
        let packet = try await Task.detached {
            try CarryGraphMigrationCodec.prepare(source, accountID: account, migrationID: migration,
                tripIDs: Set(source.trips.map(\.id)), includeLibrary: true, includeReminderPreferences: true)
        }.value
        XCTAssertEqual(Set(packet.entities.map(\.kind)), Set(["trip","section","packingItem","day","stop","transport","lodging","photo","attachment","libraryItem"]))
        XCTAssertEqual(packet.assets.count, 3, "Cover, photo thumbnail and attachment are independent private assets")
        XCTAssertEqual(packet.photosRequiringOriginalCollection.count, 1, "A thumbnail must never be mistaken for a migrated Photos original")
        let restored = try await Task.detached { try CarryGraphMigrationCodec.restore(packet, accountID: account) }.value
        XCTAssertEqual(try json(restored), try json(source), "Dates, FX sentinel, free cost, crop, bytes and relationships must all survive")
        let retried = try CarryGraphMigrationCodec.prepare(source, accountID: account, migrationID: migration,
            tripIDs: Set(source.trips.map(\.id)), includeLibrary: true)
        XCTAssertEqual(Set(retried.assets.map(\.id)), Set(packet.assets.map(\.id)))
        XCTAssertThrowsError(try CarryGraphMigrationCodec.restore(packet, accountID: UUID()))
    }

    func testMissingOrCorruptedFileCannotProduceACompletedMigration() throws {
        let source = try backup(), account = UUID()
        var missing = source; missing.attachmentFiles = nil
        XCTAssertThrowsError(try CarryGraphMigrationCodec.prepare(missing, accountID: account, migrationID: UUID(),
            tripIDs: Set(source.trips.map(\.id)), includeLibrary: false))
        let packet = try CarryGraphMigrationCodec.prepare(source, accountID: account, migrationID: UUID(),
            tripIDs: Set(source.trips.map(\.id)), includeLibrary: false)
        let first = try XCTUnwrap(packet.assets.first)
        var assets = packet.assets
        assets[0] = CarryGraphMigrationAsset(id: first.id, entityID: first.entityID, slot: first.slot,
            fileName: first.fileName, sha256: first.sha256, bytes: Data("Corrupted".utf8))
        let damaged = CarryGraphMigrationPacket(accountID: account, migrationID: packet.migrationID,
            backupVersion: packet.backupVersion, createdAt: packet.createdAt, defaultReminderOffsets: nil,
            entities: packet.entities, assets: assets, relations: packet.relations)
        XCTAssertThrowsError(try CarryGraphMigrationCodec.restore(damaged, accountID: account))
        let file = try XCTUnwrap(packet.assets.first(where: { $0.slot == "file" }))
        let mismatched = packet.assets.map { asset in
            asset.id == file.id ? CarryGraphMigrationAsset(id: asset.id, entityID: asset.entityID, slot: asset.slot,
                fileName: "mismatched.pdf", sha256: asset.sha256, bytes: asset.bytes) : asset
        }
        let badMetadata = CarryGraphMigrationPacket(accountID: account, migrationID: packet.migrationID,
            backupVersion: packet.backupVersion, createdAt: packet.createdAt, defaultReminderOffsets: nil,
            entities: packet.entities, assets: mismatched, relations: packet.relations)
        XCTAssertThrowsError(try CarryGraphMigrationCodec.restore(badMetadata, accountID: account))
    }

    func testScopeExcludesUnselectedTripsLibraryAndGlobalReminderPreferences() throws {
        var source = try backup()
        var other = source.trips[0]; other.id = UUID(); other.name = "Must remain local"
        source.trips.append(other)
        let packet = try CarryGraphMigrationCodec.prepare(source, accountID: UUID(), migrationID: UUID(),
            tripIDs: [source.trips[0].id], includeLibrary: false)
        XCTAssertFalse(packet.entities.contains { $0.id == other.id || $0.kind == "libraryItem" })
        XCTAssertNil(packet.defaultReminderOffsets)
        XCTAssertThrowsError(try CarryGraphMigrationCodec.prepare(source, accountID: UUID(), migrationID: UUID(),
            tripIDs: [UUID()], includeLibrary: false))
        XCTAssertThrowsError(try CarryGraphMigrationCodec.prepare(source, accountID: UUID(), migrationID: UUID(),
            tripIDs: Set(source.trips.map(\.id)), includeLibrary: false), "Duplicate child identities must be reviewed, never silently combined")
    }

    func testNativeFreeAndUnrecordedCostSentinelsAreAcceptedByActualHTTPDatabase() async throws {
        let source = try backup(), owner = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let packet = try CarryGraphMigrationCodec.prepare(source, accountID: owner, migrationID: UUID(),
            tripIDs: Set(source.trips.map(\.id)), includeLibrary: true)
        let configuration = CarryAccountConfiguration(projectURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8891")), publishableKey: "sb_publishable_synthetic_only")
        let transport = CarryGraphTransport(configuration: configuration, accessToken: { "synthetic-native-qa" })
        // This test isolates cost semantics. Unverified file references are
        // rejected by the actual graph guard and cannot be sent as placeholders.
        let mutations = packet.entities.filter { !["photo", "attachment"].contains($0.kind) }.map { entity in
            var fields = entity.fields
            if entity.kind == "trip" { fields["backgroundsData"] = .null; fields["backgroundAssetIDs"] = .object([:]) }
            return CarryGraphMutation(id: entity.id, kind: entity.kind, action: "create", baseVersion: 0,
                parentID: entity.parentID, fields: fields)
        }
        let receipt = try await transport.apply(CarryGraphCommand(requestID: UUID(), mutations: mutations))
        XCTAssertEqual(receipt.status, "saved_to_account")
        XCTAssertTrue(receipt.changes.contains { $0.entity.kind == "stop" && $0.entity.fields["costAmount"] == .integer(0) && $0.entity.fields["costCurrencyCode"] == .string("JPY") })
        XCTAssertTrue(receipt.changes.contains { $0.entity.kind == "lodging" && $0.entity.fields["costCurrencyCode"] == .string("") && $0.entity.fields["costHomeAmount"] == .integer(-1) })
        // Files are verified locally above. This test does not upload them to
        // Supabase Storage or count as completed production asset migration.
    }

    func testHighPrecisionPacketDatesRestoreSemanticallyWithoutChangingRawFieldsOrAssetDigests() throws {
        let source = try backup(), owner = UUID()
        let original = try CarryGraphMigrationCodec.prepare(source, accountID: owner, migrationID: UUID(),
            tripIDs: Set(source.trips.map { $0.id }), includeLibrary: true)
        let dateFields: [String: [String]] = ["trip": ["createdAt", "departureDate"], "photo": ["timestamp"],
            "attachment": ["addedAt"], "libraryItem": ["createdAt", "updatedAt"]]
        for raw in ["2026-11-01T10:20:30.123456789Z", "2026-11-01T18:20:59.999999999+08:00", "2026-12-31T23:59:59.999999999Z"] {
            var entities = original.entities
            for index in entities.indices {
                for key in dateFields[entities[index].kind] ?? [] where entities[index].fields[key] != nil {
                    entities[index].fields[key] = .string(raw)
                }
                if entities[index].kind == "trip" { entities[index].fields["name"] = .string(raw) }
            }
            func packet(_ values: [CarryGraphEntity]) -> CarryGraphMigrationPacket {
                .init(accountID: owner, migrationID: original.migrationID, backupVersion: original.backupVersion,
                    createdAt: original.createdAt, defaultReminderOffsets: original.defaultReminderOffsets,
                    entities: values, assets: original.assets, relations: original.relations)
            }
            let input = packet(entities), encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let originalBytes = try encoder.encode(input), digests = input.assets.map { $0.sha256 }
            let restored = try CarryGraphMigrationCodec.restore(input, accountID: owner)
            XCTAssertEqual(restored.trips[0].name, raw, "Date-looking ordinary text stays byte-exact")
            let checked = try CarryGraphMigrationCodec.prepare(restored, accountID: owner, migrationID: input.migrationID,
                tripIDs: Set(restored.trips.map { $0.id }), includeLibrary: true)
            let canonical = CarryBackupDates.string(from: try XCTUnwrap(CarryBackupDates.parse(raw)))
            for entity in checked.entities {
                for key in dateFields[entity.kind] ?? [] where entity.fields[key] != nil {
                    XCTAssertEqual(entity.fields[key], .string(canonical))
                }
            }
            XCTAssertEqual(try encoder.encode(input), originalBytes)
            XCTAssertEqual(input.assets.map { $0.sha256 }, digests)
            var unknown = entities
            unknown[0].fields["unexpectedDate"] = .string(raw)
            XCTAssertThrowsError(try CarryGraphMigrationCodec.restore(packet(unknown), accountID: owner), "Unknown fields must never bypass round-trip validation")
            var invalid = entities
            let trip = try XCTUnwrap(invalid.firstIndex { $0.kind == "trip" })
            invalid[trip].fields["createdAt"] = .string("2026-02-30T10:20:30.999999999Z")
            XCTAssertThrowsError(try CarryGraphMigrationCodec.restore(packet(invalid), accountID: owner))
        }
    }

}
