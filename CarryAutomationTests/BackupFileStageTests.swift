import XCTest
import SwiftData
@testable import Carry

@MainActor
final class BackupFileStageTests: XCTestCase {
    private func packet(background name: String, bytes: Data? = nil) throws -> CarryBackup {
        let entries = [TripBackgroundEntry(source: .local, localFileName: name, destinationIndex: 0)]
        let trip = BackupTrip(id: UUID(), name: "Synthetic", destinationCity: "", days: 0, dateRange: "",
            departureDate: Date(), isDateless: true, createdAt: Date(), selectedSceneKeys: [], dismissedSurpriseNames: [],
            sceneCardDismissed: false, remindersEnabled: false, reminderConfigData: Data(), countryCode: "", latitude: 0,
            longitude: 0, additionalDestinationsData: nil, backgroundsData: try JSONEncoder().encode(entries),
            sections: [], itineraryDays: [], lodgingStays: [])
        return CarryBackup(version: DataBackupManager.currentBackupVersion, createdAt: Date(), trips: [trip], myItems: [],
            backgroundImages: bytes.map { [name: $0] })
    }

    private func backgroundName(_ packet: CarryBackup) throws -> String {
        let data = try XCTUnwrap(packet.trips.first?.backgroundsData)
        return try XCTUnwrap(JSONDecoder().decode([TripBackgroundEntry].self, from: data).first?.localFileName)
    }

    func testStagingNeverOverwritesAnExistingFileAndDiscardOnlyRemovesNewBytes() throws {
        let name = UUID().uuidString + ".jpg", original = Data("original".utf8), incoming = Data("incoming".utf8)
        XCTAssertTrue(BackgroundImageStore.write(data: original, named: name))
        defer { BackgroundImageStore.delete(named: name) }
        let stage = try CarryBackupFileStage(packet(background: name, bytes: incoming))
        let allocated = try backgroundName(stage.backup)
        XCTAssertNotEqual(allocated, name)
        XCTAssertEqual(BackgroundImageStore.data(named: allocated), incoming)
        XCTAssertEqual(BackgroundImageStore.data(named: name), original)
        stage.discard()
        XCTAssertNil(BackgroundImageStore.data(named: allocated))
        XCTAssertEqual(BackgroundImageStore.data(named: name), original)
    }

    func testExternalBackupCannotResolveARecipientLocalFileWithoutItsOwnBytes() throws {
        let name = UUID().uuidString + ".jpg", original = Data("private-local".utf8)
        XCTAssertTrue(BackgroundImageStore.write(data: original, named: name))
        defer { BackgroundImageStore.delete(named: name) }
        XCTAssertThrowsError(try CarryBackupFileStage(packet(background: name)))
        let local = try CarryBackupFileStage(packet(background: name), allowLocalFileReferences: true)
        defer { local.discard() }
        XCTAssertEqual(try backgroundName(local.backup), name)
        XCTAssertThrowsError(try CarryBackupFileStage(packet(background: UUID().uuidString), allowLocalFileReferences: true))
    }

    func testInvalidReferencedNamesCannotEscapeTheFileDirectory() throws {
        for name in ["../outside.jpg", "folder/name.jpg", "folder\\name.jpg", "..", "", "null\0name"] {
            XCTAssertThrowsError(try CarryBackupFileStage(packet(background: name, bytes: Data("incoming".utf8))))
        }
    }

    func testFailedPreparationCleansEarlierAllocatedFiles() throws {
        let originalNames = Set(BackgroundImageStore.allStoredFileNames())
        let name = UUID().uuidString + ".jpg"
        var incoming = try packet(background: name, bytes: Data("incoming".utf8))
        incoming.trips += try packet(background: "../invalid.jpg", bytes: Data()).trips
        XCTAssertThrowsError(try CarryBackupFileStage(incoming))
        XCTAssertEqual(Set(BackgroundImageStore.allStoredFileNames()), originalNames)
    }

    func testFileReferencesPublishOnlyAfterTheDatabaseWriterAcceptsTheRestore() throws {
        enum Injected: Error { case rejected }
        let name = UUID().uuidString + ".jpg", original = Data("original".utf8), incoming = Data("incoming".utf8)
        XCTAssertTrue(BackgroundImageStore.write(data: original, named: name))
        defer { BackgroundImageStore.delete(named: name) }
        let packet = try packet(background: name, bytes: incoming)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(packet)
        let schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        var allocated: String?
        let before = Set(BackgroundImageStore.allStoredFileNames())
        XCTAssertThrowsError(try DataBackupManager.shared.restoreFromData(bytes, into: context, save: { transaction in
            allocated = try transaction.fetch(FetchDescriptor<TripBundle>()).first?.primaryBackground?.localFileName
            throw Injected.rejected
        }))
        XCTAssertEqual(BackgroundImageStore.data(named: name), original)
        XCTAssertEqual(Set(BackgroundImageStore.allStoredFileNames()), before)
        XCTAssertNotNil(allocated)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
        let accepted = ModelContext(container)
        _ = try DataBackupManager.shared.restoreFromData(bytes, into: accepted)
        let published = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first?.primaryBackground?.localFileName)
        defer { BackgroundImageStore.delete(named: published) }
        XCTAssertNotEqual(published, name)
        XCTAssertEqual(BackgroundImageStore.data(named: published), incoming)
        XCTAssertEqual(BackgroundImageStore.data(named: name), original)
    }

    func testSharedItineraryCannotImportPrivateAttachmentReferences() throws {
        var incoming = try packet(background: "recipient-private.jpg")
        let attachment = BackupAttachment(id: UUID(), kindRaw: "file", displayName: "Private", fileName: "recipient-private.pdf",
            utiOrExt: "pdf", urlString: "", thumbnailData: Data(), sortOrder: 0, addedAt: Date())
        incoming.trips[0].lodgingStays = [BackupLodgingStay(id: UUID(), name: "Synthetic", address: "", latitude: 0,
            longitude: 0, checkInDayOrder: 0, nights: 1, checkInMinutes: -1, checkOutMinutes: -1, confirmationCode: "",
            note: "", sortOrder: 0, costAmount: nil, costCurrencyCode: nil, costHomeAmount: nil, attachments: [attachment])]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let schema = Schema(SchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        _ = try DataBackupManager.shared.importSharedTrip(from: encoder.encode(incoming), into: ModelContext(container))
        let trip = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TripBundle>()).first)
        XCTAssertTrue(trip.backgroundsData.isEmpty)
        XCTAssertTrue(trip.safeLodgingStays.first?.attachments?.isEmpty ?? true)
    }
}
