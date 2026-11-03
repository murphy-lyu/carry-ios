import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AccountExportBackupTests: XCTestCase {
    private func fixture() throws -> CarryBackup {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "account-export-synthetic", withExtension: "json"))
        let decoder = CarryBackupDates.decoder()
        return try decoder.decode(CarryBackup.self, from: Data(contentsOf: url))
    }
    func testActualServerExportRestoresAndReexportsOriginalPhotoAndAllBusinessValues() throws {
        let backup = try fixture(), schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let result = try DataBackupManager.shared.merge(backup, into: context)
        XCTAssertEqual(result.trips, 1)
        let trips = try context.fetch(FetchDescriptor<TripBundle>()), photos = try context.fetch(FetchDescriptor<StopPhoto>())
        let photo = try XCTUnwrap(photos.first)
        XCTAssertTrue(photo.assetLocalIdentifier.hasPrefix("carryphoto1_"))
        let original = try XCTUnwrap(backup.photoOriginals?[photo.id.uuidString.lowercased()])
        XCTAssertEqual(AttachmentStore.data(named: photo.assetLocalIdentifier), original)
        let exported = try XCTUnwrap(DataBackupManager.shared.makeExportFile(trips: trips, myItems: []))
        let attachments = try context.fetch(FetchDescriptor<ItineraryAttachment>())
        defer {
            do { try FileManager.default.removeItem(at: exported) } catch { XCTFail("Synthetic export cleanup") }
            AttachmentStore.delete(named: photo.assetLocalIdentifier)
            for attachment in attachments { AttachmentStore.delete(named: attachment.fileName) }
            for trip in trips { for name in trip.backgrounds.compactMap(\.localFileName) { BackgroundImageStore.delete(named: name) } }
        }
        let decoder = CarryBackupDates.decoder()
        let roundtrip = try decoder.decode(CarryBackup.self, from: Data(contentsOf: exported))
        XCTAssertEqual(roundtrip.photoOriginals?[photo.id.uuidString.lowercased()], original)
        let item = try XCTUnwrap(trips.first?.safeSections.first?.sortedItems.first)
        XCTAssertTrue(item.isPacked)
        let stop = try XCTUnwrap(trips.first?.safeItineraryDays.first?.sortedStops.first)
        XCTAssertEqual(stop.costCurrencyCode, "JPY")
        XCTAssertEqual(stop.timeZoneId, "Asia/Tokyo")
        XCTAssertFalse(try XCTUnwrap(trips.first).backgrounds.isEmpty)
    }
    func testAlteredOriginalCannotPassManifestValidationOrCreateFiles() throws {
        var backup = try fixture()
        let key = try XCTUnwrap(backup.photoOriginals?.keys.first)
        backup.photoOriginals?[key] = Data("Tampered original bytes".utf8)
        XCTAssertThrowsError(try CarryBackupFileStage(backup))
    }
    func testSharedItineraryDiscardsRecipientLocalPrivatePhotoPointers() throws {
        var backup = try fixture()
        backup.trips[0].itineraryDays?[0].stops[0].photos?[0].assetLocalIdentifier = "carryphoto1_recipient-private.blob"
        backup.trips[0].itineraryDays?[0].stops[0].fromPhotos = true
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        _ = try DataBackupManager.shared.importSharedTrip(from: encoder.encode(backup), into: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StopPhoto>()).isEmpty)
        XCTAssertFalse(try XCTUnwrap(context.fetch(FetchDescriptor<ItineraryStop>()).first).fromPhotos)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ItineraryAttachment>()).isEmpty)
    }
    func testExportDoesNotSilentlyOmitAnUnavailableOriginal() throws {
        let trip = TripBundle(name: "Synthetic", destinationCity: "", days: 1, sections: [])
        let day = ItineraryDay(title: "Day"), stop = ItineraryStop(name: "Place")
        let photo = StopPhoto(assetLocalIdentifier: "carryphoto1_" + UUID().uuidString + ".blob")
        photo.stop = stop; stop.photos = [photo]; stop.day = day; day.stops = [stop]; day.bundle = trip; trip.itineraryDays = [day]
        XCTAssertNil(DataBackupManager.shared.makeExportFile(trips: [trip], myItems: []))
    }
    func testBackgroundAboveAttachmentLimitStillRoundTripsUnderItsOwnLimit() throws {
        let trip = TripBundle(name: "Synthetic cover", destinationCity: "", days: 1, sections: [])
        let name = UUID().uuidString + ".jpg"
        trip.backgroundsData = try JSONEncoder().encode([TripBackgroundEntry(source: .local, localFileName: name, destinationIndex: 0)])
        var backup = DataBackupManager.shared.migrationSnapshot(trips: [trip], myItems: [])
        let cover = Data(repeating: 19, count: AttachmentStore.maxBytes + 1)
        backup.backgroundImages = [name: cover]
        let owner = UUID()
        let packet = try CarryGraphMigrationCodec.prepare(backup, accountID: owner, migrationID: UUID(), tripIDs: [trip.id], includeLibrary: false)
        let restored = try CarryGraphMigrationCodec.restore(packet, accountID: owner)
        XCTAssertEqual(restored.backgroundImages?[name], cover)
    }
}
