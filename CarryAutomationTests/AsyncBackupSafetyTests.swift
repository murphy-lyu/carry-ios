import XCTest
import SwiftData
@testable import Carry

@MainActor
final class AsyncBackupSafetyTests: XCTestCase {
    private enum Injected: Error { case save }
    private func fixture() throws -> CarryBackup {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "account-export-synthetic", withExtension: "json"))
        return try CarryBackupDates.decoder().decode(CarryBackup.self, from: Data(contentsOf: url))
    }
    private func container() throws -> ModelContainer {
        let schema = Schema(SchemaV1.models)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    private func testDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CarryAsyncBackupTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func removeDirectory(_ folder: URL) {
        do { try FileManager.default.removeItem(at: folder) } catch { XCTFail("Owned backup directory cleanup") }
    }
    private func encoded(_ backup: CarryBackup) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(backup)
    }
    private func cleanup(_ context: ModelContext) throws {
        for photo in try context.fetch(FetchDescriptor<StopPhoto>()) where photo.assetLocalIdentifier.hasPrefix("carryphoto1_") { AttachmentStore.delete(named: photo.assetLocalIdentifier) }
        for file in try context.fetch(FetchDescriptor<ItineraryAttachment>()) where !file.fileName.isEmpty { AttachmentStore.delete(named: file.fileName) }
        for trip in try context.fetch(FetchDescriptor<TripBundle>()) { for name in trip.backgrounds.compactMap(\.localFileName) { BackgroundImageStore.delete(named: name) } }
    }
    func testLegacyOriginalPointerRejectsPathTraversalBeforeResolvingAnyLocalFile() throws {
        var source = try fixture(); source.photoOriginals = nil; source.assetManifest = nil
        source.trips[0].itineraryDays?[0].stops[0].photos?[0].assetLocalIdentifier = "carryphoto1_folder/../../private.blob"
        XCTAssertThrowsError(try CarryBackupFileStage(source, allowLocalFileReferences: true))
    }
    func testManifestRejectsAlteredAttachmentCoverAndThumbnailBeforePublication() throws {
        for kind in ["attachment", "background", "thumbnail", "duplicate", "missing", "unknown"] {
            var source = try fixture()
            switch kind {
            case "attachment": let key = try XCTUnwrap(source.attachmentFiles?.keys.first); source.attachmentFiles?[key] = Data("altered attachment".utf8)
            case "background": let key = try XCTUnwrap(source.backgroundImages?.keys.first); source.backgroundImages?[key] = Data("altered cover".utf8)
            case "thumbnail": source.trips[0].itineraryDays?[0].stops[0].photos?[0].thumbnailData = Data("altered thumbnail".utf8)
            case "duplicate": let first = try XCTUnwrap(source.assetManifest?.first); source.assetManifest?.append(first)
            case "missing": source.assetManifest?.removeLast()
            default: source.assetManifest?[0].entityID = UUID()
            }
            XCTAssertThrowsError(try CarryBackupFileStage(source), kind)
        }
    }
    func testAsyncMergeAndRepeatedFreshSnapshotKeepUnchangedRelationshipsValid() async throws {
        let directory = try testDirectory(); defer { removeDirectory(directory) }
        let container = try container(), context = ModelContext(container), data = try encoded(fixture())
        let manager = DataBackupManager(backupURL: directory.appendingPathComponent("backup.json"))
        let first = try await manager.mergeFromDataAsync(data, into: context)
        XCTAssertEqual(first.trips, 1)
        defer { do { try cleanup(context) } catch { XCTFail("Synthetic cleanup") } }
        let second = try await manager.mergeFromDataAsync(data, into: context)
        let third = try await manager.mergeFromDataAsync(data, into: context)
        XCTAssertEqual(second.trips, 0); XCTAssertEqual(third.trips, 0)
        let trips = try context.fetch(FetchDescriptor<TripBundle>())
        let url = try await manager.makeExportFileAsync(trips: trips, myItems: [])
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail("Synthetic export cleanup") } }
        let exported = try CarryBackupDates.decoder().decode(CarryBackup.self, from: Data(contentsOf: url))
        XCTAssertEqual(exported.photoOriginals, try fixture().photoOriginals)
    }
    func testSavedTargetEditDuringPreparationRejectsRestoreAndRetainsCurrentData() async throws {
        let directory = try testDirectory(); defer { removeDirectory(directory) }
        let container = try container(), context = ModelContext(container)
        let original = TripBundle(name: "Before", destinationCity: "", days: 1, sections: [])
        context.insert(original); try context.save()
        let manager = DataBackupManager(backupURL: directory.appendingPathComponent("backup.json"))
        do {
            _ = try await manager.restoreFromDataAsync(encoded(fixture()), into: context, preCommit: {
                let writer = ModelContext(container)
                let current = try XCTUnwrap(writer.fetch(FetchDescriptor<TripBundle>()).first)
                current.name = "Saved while preparing"; try writer.save()
            })
            XCTFail("Concurrent edit must be preserved")
        } catch DataBackupManager.BackupError.targetChanged { }
        let fresh = ModelContext(container), values = try fresh.fetch(FetchDescriptor<TripBundle>())
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values.first?.id, original.id); XCTAssertEqual(values.first?.name, "Saved while preparing")
    }
    func testDirtyTargetAndCancelledPreparationCannotPublishIncomingData() async throws {
        let directory = try testDirectory(); defer { removeDirectory(directory) }
        let container = try container(), context = ModelContext(container)
        context.insert(TripBundle(name: "Unsaved", destinationCity: "", days: 1, sections: []))
        let data = try encoded(fixture()), manager = DataBackupManager(backupURL: directory.appendingPathComponent("backup.json"))
        do { _ = try await manager.restoreFromDataAsync(data, into: context); XCTFail("Dirty target") }
        catch DataBackupManager.BackupError.targetChanged { }
        context.rollback()
        let work = Task { try await manager.mergeFromDataAsync(data, into: context) }; work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled") } catch is CancellationError { }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
    }
    func testPreparedFilesSurviveOrdinaryOrphanGCBeforeAtomicPublication() async throws {
        let attachments = AttachmentStore.fileURL(named: ".test").deletingLastPathComponent()
        let backgrounds = BackgroundImageStore.fileURL(named: ".test").deletingLastPathComponent()
        let existingAttachments = Set(try FileManager.default.contentsOfDirectory(atPath: attachments.path))
        let existingBackgrounds = Set(try FileManager.default.contentsOfDirectory(atPath: backgrounds.path))
        let stage = try await CarryBackupFileStage.prepareAsync(fixture())
        defer { stage.discard() }
        // This operates on the two ordinary file stores, which must never see
        // files belonging to a still-unpublished background stage.
        AttachmentStore.deleteOrphans(keeping: existingAttachments)
        BackgroundImageStore.deleteOrphans(keeping: existingBackgrounds)
        try stage.publish()
        let name = try XCTUnwrap(stage.backup.trips[0].itineraryDays?[0].stops[0].photos?[0].assetLocalIdentifier)
        XCTAssertNotNil(AttachmentStore.data(named: name))
    }
    func testNativeEmbeddedBudgetRejectsAggregateOverflowWithoutStagingFiles() throws {
        var source = try fixture()
        let shared = Data(repeating: 0, count: 45 * 1024 * 1024)
        source.backgroundImages = ["synthetic-a": shared, "synthetic-b": shared, "synthetic-c": shared]
        XCTAssertThrowsError(try CarryBackupFileStage.validateEmbeddedBudget(source)) { error in
            guard case DataBackupManager.BackupError.tooLarge = error else { return XCTFail("Explicit size error") }
        }
    }
    func testPreRestoreSafetyFilePreservesOriginalsAfterOrdinaryFilesAreRemoved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CarryAsyncSafety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: folder) } catch { XCTFail("Safety directory cleanup") } }
        let container = try container(), context = ModelContext(container), backup = try fixture()
        let manager = DataBackupManager(backupURL: folder.appendingPathComponent("backup.json"))
        _ = try await manager.mergeFromDataAsync(encoded(backup), into: context)
        let oldPhotos = try context.fetch(FetchDescriptor<StopPhoto>()).map(\.assetLocalIdentifier)
        let oldAttachments = try context.fetch(FetchDescriptor<ItineraryAttachment>()).map(\.fileName)
        let oldBackgrounds = try context.fetch(FetchDescriptor<TripBundle>()).flatMap { $0.backgrounds.compactMap(\.localFileName) }
        var empty = backup; empty.trips = []; empty.myItems = []; empty.backgroundImages = nil; empty.attachmentFiles = nil; empty.photoOriginals = nil; empty.assetManifest = nil
        _ = try await manager.restoreFromDataAsync(encoded(empty), into: context)
        let safety = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Safety-local"), includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("pre-restore-") })
        let snapshot = try CarryBackupDates.decoder().decode(CarryBackup.self, from: Data(contentsOf: safety))
        XCTAssertEqual(snapshot.photoOriginals, backup.photoOriginals)
        XCTAssertEqual(Set(snapshot.attachmentFiles?.values ?? Dictionary<String, Data>().values), Set(backup.attachmentFiles?.values ?? Dictionary<String, Data>().values))
        XCTAssertEqual(Set(snapshot.backgroundImages?.values ?? Dictionary<String, Data>().values), Set(backup.backgroundImages?.values ?? Dictionary<String, Data>().values))
        // Simulate the same removal performed by post-restore orphan GC, without
        // touching unrelated files belonging to the application/test container.
        for name in oldPhotos + oldAttachments { AttachmentStore.delete(named: name) }
        for name in oldBackgrounds { BackgroundImageStore.delete(named: name) }
        _ = try await manager.restoreFromDataAsync(Data(contentsOf: safety), into: context)
        defer { do { try cleanup(context) } catch { XCTFail("Restored synthetic files cleanup") } }
        let photo = try XCTUnwrap(context.fetch(FetchDescriptor<StopPhoto>()).first)
        XCTAssertEqual(AttachmentStore.data(named: photo.assetLocalIdentifier), backup.photoOriginals?[photo.id.uuidString.lowercased()])
    }
    func testMetadataOnlyEntityBudgetAndDuplicateIdentityFailBeforeFileWork() throws {
        var source = try fixture()
        let template = try XCTUnwrap(source.trips[0].sections.first?.items.first)
        source.trips[0].sections[0].items = (0..<20001).map { _ in var item = template; item.id = UUID(); return item }
        XCTAssertThrowsError(try CarryBackupFileStage.validateEmbeddedBudget(source)) { error in
            guard case DataBackupManager.BackupError.tooLarge = error else { return XCTFail("Explicit entity limit") }
        }
        source.trips[0].sections[0].items = [template, template]
        XCTAssertThrowsError(try CarryBackupFileStage.validateEmbeddedBudget(source))
    }
    func testSuccessfulSafetyPruneRetainsPendingUnknownAndOtherAccountFiles() async throws {
        let directory = try testDirectory(); defer { removeDirectory(directory) }
        let local = directory.appendingPathComponent("Safety-local"), other = directory.appendingPathComponent("Safety-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        for stamp in 1...5 { try Data("Owned historical fixture".utf8).write(to: local.appendingPathComponent("backup.pre-restore-\(stamp)-\(UUID().uuidString).json")) }
        let pending = local.appendingPathComponent(".pending-backup.pre-restore-" + UUID().uuidString + ".json")
        let unknown = local.appendingPathComponent("unknown.json"), otherFile = other.appendingPathComponent("backup.pre-restore-1-" + UUID().uuidString + ".json")
        for url in [pending, unknown, otherFile] { try Data("Must remain".utf8).write(to: url) }
        let link = local.appendingPathComponent("backup.pre-restore-1-" + UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: otherFile)
        var empty = try fixture(); empty.trips = []; empty.myItems = []; empty.backgroundImages = nil; empty.attachmentFiles = nil; empty.photoOriginals = nil; empty.assetManifest = nil
        let container = try container(), context = ModelContext(container), manager = DataBackupManager(backupURL: directory.appendingPathComponent("backup.json"))
        _ = try await manager.restoreFromDataAsync(encoded(empty), into: context)
        for url in [pending, unknown, otherFile, link] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        let regular = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter { url in
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return url.lastPathComponent.hasPrefix("backup.pre-restore-") && info.isRegularFile == true && info.isSymbolicLink != true
        }
        XCTAssertEqual(regular.count, 3)
    }
    func testAsyncSaveFailureRollsBackModelsAndDiscardsNewPrivateFiles() async throws {
        let directory = try testDirectory(); defer { removeDirectory(directory) }
        let container = try container(), context = ModelContext(container)
        let manager = DataBackupManager(backupURL: directory.appendingPathComponent("backup.json"))
        do { _ = try await manager.mergeFromDataAsync(encoded(fixture()), into: context, save: { _ in throw Injected.save }); XCTFail("Injected failure") }
        catch Injected.save { }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TripBundle>()).isEmpty)
    }
}
