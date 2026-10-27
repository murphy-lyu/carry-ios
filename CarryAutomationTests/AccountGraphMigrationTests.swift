import XCTest
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
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CarryBackup.self, from: Data(contentsOf: url))
    }

    private func json(_ backup: CarryBackup) throws -> CarryGraphValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(CarryGraphValue.self, from: encoder.encode(backup))
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
        let mutations = packet.entities.map { CarryGraphMutation(id: $0.id, kind: $0.kind, action: "create", baseVersion: 0,
            parentID: $0.parentID, fields: $0.fields) }
        let receipt = try await transport.apply(CarryGraphCommand(requestID: UUID(), mutations: mutations))
        XCTAssertEqual(receipt.status, "saved_to_account")
        XCTAssertTrue(receipt.changes.contains { $0.entity.kind == "stop" && $0.entity.fields["costAmount"] == .integer(0) && $0.entity.fields["costCurrencyCode"] == .string("JPY") })
        XCTAssertTrue(receipt.changes.contains { $0.entity.kind == "lodging" && $0.entity.fields["costCurrencyCode"] == .string("") && $0.entity.fields["costHomeAmount"] == .integer(-1) })
        // Files are verified locally above. This test does not upload them to
        // Supabase Storage or count as completed production asset migration.
    }
}
