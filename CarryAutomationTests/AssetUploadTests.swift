import XCTest
import CryptoKit
import Auth
@testable import Carry

private actor AssetTokenGate {
    nonisolated let blocked: AsyncStream<Bool>
    private let signal: AsyncStream<Bool>.Continuation
    nonisolated let cancelled: AsyncStream<Bool>
    private let cancellation: AsyncStream<Bool>.Continuation
    private var release: CheckedContinuation<Void, Never>?
    private var requests = 0
    init() {
        (blocked, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (cancelled, cancellation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func token() async -> String {
        requests += 1
        if requests == 3 {
            let cancellation = cancellation
            await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    release = continuation; signal.yield(true)
                }
            }, onCancel: { cancellation.yield(true) })
        }
        return requests == 1 ? "synthetic-asset-token-a" : "synthetic-asset-token-b"
    }
    func resume() { release?.resume(); release = nil; signal.finish(); cancellation.finish() }
}

@MainActor
final class AssetUploadTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:8892/storage/v1/upload/resumable")

    private struct Fixture {
        let folder: URL
        let source: URL
        let asset: CarryAssetUpload
    }

    private func fixture(mode: String = "normal") async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CarryAssetQA-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.bin")
        let bytes = Data(repeating: 0x57, count: 7 * 1024 * 1024)
        try bytes.write(to: source)
        let asset = CarryAssetUpload(id: UUID(), accountID: UUID(),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), byteCount: bytes.count)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8892/__fixture")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": asset.id.uuidString, "mode": mode])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        return Fixture(folder: folder, source: source, asset: asset)
    }

    private func uploader(_ fixture: Fixture, owner: UUID? = nil) throws -> CarryAssetUploader {
        try CarryAssetUploader(accountID: owner ?? fixture.asset.accountID, endpoint: XCTUnwrap(endpoint),
            directory: fixture.folder.appendingPathComponent("uploads"), publishableKey: "sb_publishable_synthetic_asset_qa",
            accessToken: { "synthetic-asset-token-a" })
    }

    private func stats(_ fixture: Fixture) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8892/__stats/\(fixture.asset.id.uuidString)"))
        let (data, _) = try await URLSession.shared.data(from: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testChunksHashAndCheckpointNeverPersistCredentialsOrEraseOriginal() async throws {
        let fixture = try await fixture(), upload = try uploader(fixture)
        try await upload.upload(fixture.asset, from: fixture.source)
        await upload.close()
        let result = try await stats(fixture)
        XCTAssertEqual(result["chunks"] as? [Int], [6 * 1024 * 1024, 1024 * 1024])
        XCTAssertEqual(result["sha256"] as? String, fixture.asset.sha256)
        let checkpoint = fixture.folder.appendingPathComponent("uploads/\(fixture.asset.accountID.uuidString.lowercased())/\(fixture.asset.id.uuidString).json")
        let json = try String(contentsOf: checkpoint, encoding: .utf8)
        XCTAssertFalse(json.contains("synthetic-asset-token")); XCTAssertFalse(json.contains("Authorization"))
        try await upload.discard(fixture.asset.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    func testLostAcknowledgementReopensAndAsksServerForOffset() async throws {
        try await interrupted(mode: "drop_once", expectedCreations: 1)
    }

    func testExpiredUploadStartsFreshWithoutTrustingOldOffset() async throws {
        try await interrupted(mode: "expired_once", expectedCreations: 2)
    }

    func testInvalidAcknowledgementRecoversUsingHead() async throws {
        try await interrupted(mode: "bad_offset_once", expectedCreations: 1)
    }

    private func interrupted(mode: String, expectedCreations: Int) async throws {
        let fixture = try await fixture(mode: mode), first = try uploader(fixture)
        do { try await first.upload(fixture.asset, from: fixture.source); XCTFail("Fixture must interrupt") }
        catch { /* Deliberate server-side loss or invalid acknowledgement. */ }
        await first.close()
        let resumed = try uploader(fixture)
        try await resumed.upload(fixture.asset, from: fixture.source)
        await resumed.close()
        let result = try await stats(fixture)
        XCTAssertEqual(result["creations"] as? Int, expectedCreations)
        XCTAssertEqual(result["offset"] as? Int, fixture.asset.byteCount)
        XCTAssertEqual(result["sha256"] as? String, fixture.asset.sha256)
        XCTAssertGreaterThanOrEqual(result["heads"] as? Int ?? 0, 1)
    }

    func testCrossOriginLocationAndRedirectAreRefused() async throws {
        for mode in ["bad_location", "redirect"] {
            let fixture = try await fixture(mode: mode), upload = try uploader(fixture)
            do { try await upload.upload(fixture.asset, from: fixture.source); XCTFail("Must reject redirect/location") }
            catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .invalidResponse) }
            await upload.close()
            let result = try await stats(fixture)
            XCTAssertEqual(result["trap"] as? Int, 0)
            XCTAssertEqual(result["offset"] as? Int, 0)
        }
    }

    func testAnotherAccountCannotUploadAndClosedAccountCannotRestart() async throws {
        let fixture = try await fixture(), wrong = try uploader(fixture, owner: UUID())
        do { try await wrong.upload(fixture.asset, from: fixture.source); XCTFail("Wrong account") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .invalidSource) }
        await wrong.close()
        let own = try uploader(fixture); await own.close()
        do { try await own.upload(fixture.asset, from: fixture.source); XCTFail("Closed account") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .busy) }
        let result = try await stats(fixture)
        XCTAssertEqual(result["creations"] as? Int, 0)
    }

    func testPauseBeforeNextChunkKeepsDurableOffsetAndOriginal() async throws {
        let fixture = try await fixture(), gate = AssetTokenGate()
        let upload = try CarryAssetUploader(accountID: fixture.asset.accountID, endpoint: XCTUnwrap(endpoint),
            directory: fixture.folder.appendingPathComponent("uploads"), publishableKey: "sb_publishable_synthetic_asset_qa",
            accessToken: { await gate.token() })
        let pending = Task { try await upload.upload(fixture.asset, from: fixture.source) }
        var signals = gate.blocked.makeAsyncIterator()
        let blocked = await signals.next()
        XCTAssertEqual(blocked, true)
        await upload.pause(fixture.asset.id)
        await gate.resume()
        do { try await pending.value; XCTFail("Paused upload must cancel") }
        catch is CancellationError { }
        await upload.close()
        let paused = try await stats(fixture)
        XCTAssertEqual(paused["offset"] as? Int, 6 * 1024 * 1024)
        XCTAssertEqual(paused["tokenARequests"] as? Int, 1)
        XCTAssertEqual(paused["tokenBRequests"] as? Int, 1, "Second request must obtain refreshed credentials")
        let resumed = try uploader(fixture)
        try await resumed.upload(fixture.asset, from: fixture.source)
        await resumed.close()
        let complete = try await stats(fixture)
        XCTAssertEqual(complete["chunks"] as? [Int], [6 * 1024 * 1024, 1024 * 1024])
        XCTAssertEqual(complete["sha256"] as? String, fixture.asset.sha256)
    }

    func testInvalidFileSizeAndDigestFailBeforeNetwork() async throws {
        for wrongSize in [false, true] {
            let fixture = try await fixture(), upload = try uploader(fixture)
            let bad = CarryAssetUpload(id: fixture.asset.id, accountID: fixture.asset.accountID,
                sha256: wrongSize ? fixture.asset.sha256 : String(repeating: "0", count: 64),
                byteCount: fixture.asset.byteCount + (wrongSize ? 1 : 0))
            do { try await upload.upload(bad, from: fixture.source); XCTFail("Invalid source") }
            catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .invalidSource) }
            await upload.close()
            let result = try await stats(fixture)
            XCTAssertEqual(result["creations"] as? Int, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        }
    }

    func testResumeCannotReopenUploadsWhilePauseAllIsStillWaiting() async throws {
        let fixture = try await fixture(), gate = AssetTokenGate()
        let upload = try CarryAssetUploader(accountID: fixture.asset.accountID, endpoint: XCTUnwrap(endpoint),
            directory: fixture.folder.appendingPathComponent("uploads"), publishableKey: "sb_publishable_synthetic_asset_qa",
            accessToken: { await gate.token() })
        let pending = Task { try await upload.upload(fixture.asset, from: fixture.source) }
        var blocked = gate.blocked.makeAsyncIterator()
        let blockedValue = await blocked.next()
        XCTAssertEqual(blockedValue, true)
        let pausing = Task { await upload.pauseAll() }
        var cancelled = gate.cancelled.makeAsyncIterator()
        let cancelledValue = await cancelled.next()
        XCTAssertEqual(cancelledValue, true, "pauseAll has cancelled the still-blocked child")
        do { try await upload.resume(); XCTFail("Cannot resume before the old request exits") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .busy) }
        await gate.resume()
        do { try await pending.value; XCTFail("Paused upload must cancel") }
        catch is CancellationError { }
        await pausing.value
        try await upload.resume()
        try await upload.upload(fixture.asset, from: fixture.source)
        await upload.close()
        let result = try await stats(fixture)
        XCTAssertEqual(result["chunks"] as? [Int], [6 * 1024 * 1024, 1024 * 1024])
    }

    func testTamperedCheckpointCannotSendBearerToAnotherOrigin() async throws {
        let fixture = try await fixture(), first = try uploader(fixture)
        try await first.upload(fixture.asset, from: fixture.source)
        await first.close()
        let checkpoint = fixture.folder.appendingPathComponent("uploads/\(fixture.asset.accountID.uuidString.lowercased())/\(fixture.asset.id.uuidString).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as? [String: Any])
        json["destination"] = "https://invalid.example/storage/v1/upload/resumable/trap"
        try JSONSerialization.data(withJSONObject: json).write(to: checkpoint)
        let resumed = try uploader(fixture)
        do { try await resumed.upload(fixture.asset, from: fixture.source); XCTFail("Tampered checkpoint") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .invalidCheckpoint) }
        await resumed.close()
        let result = try await stats(fixture)
        XCTAssertEqual(result["heads"] as? Int, 0)
    }

    func testRealAccountServiceFactoryRechecksOwnerForEveryStorageRequest() async throws {
        let fixture = try await fixture()
        let storage = CarryAccountSecureStorage(namespace: "asset-factory-\(UUID())")
        addTeardownBlock { try storage.remove(key: "session"); try storage.remove(key: "profile") }
        let owner = fixture.asset.accountID
        try storage.store(key: "profile", value: JSONEncoder().encode(CarryAccountProfile(id: owner, displayName: nil, email: nil)))
        let session = Session(accessToken: "synthetic-asset-token-a", tokenType: "bearer", expiresIn: 3600,
            expiresAt: Date().timeIntervalSince1970 + 3600, refreshToken: "synthetic-asset-refresh",
            user: User(id: owner, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date()))
        try storage.store(key: "session", value: JSONEncoder().encode(session))
        let configuration = CarryAccountConfiguration(projectURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8892")),
            publishableKey: "sb_publishable_synthetic_asset_qa")
        let service = CarryAccountService(configuration: configuration, storage: storage)
        let upload = try service.assetUploader(for: owner, directory: fixture.folder.appendingPathComponent("uploads"))
        try await upload.upload(fixture.asset, from: fixture.source)
        // An old transport must fail before its next HEAD after a switch/logout,
        // even if the former SDK session still exists in memory.
        try storage.store(key: "profile", value: JSONEncoder().encode(CarryAccountProfile(id: UUID(), displayName: nil, email: nil)))
        do { try await upload.upload(fixture.asset, from: fixture.source); XCTFail("Old owner transport") }
        catch let error as CarryAccountFailure { XCTAssertEqual(error, .accountMismatch) }
        await upload.close()
        let result = try await stats(fixture)
        XCTAssertEqual(result["heads"] as? Int, 0)
        XCTAssertEqual(result["creations"] as? Int, 1)
    }

    private func transfer(_ fixture: Fixture) throws -> CarryAssetTransfer {
        try CarryAssetTransfer(accountID: fixture.asset.accountID,
            projectURL: XCTUnwrap(URL(string: "http://127.0.0.1:8892")),
            directory: fixture.folder.appendingPathComponent("uploads"),
            publishableKey: "sb_publishable_synthetic_asset_qa", accessToken: { "synthetic-asset-token-a" })
    }

    private func descriptor(_ fixture: Fixture) -> CarryAssetDescriptor {
        .init(id: fixture.asset.id, entityID: UUID(), entityKind: "attachment", slot: "file",
              sha256: fixture.asset.sha256, byteCount: fixture.asset.byteCount)
    }

    func testTransferRequiresServerVerificationAndReusesAnAlreadyVerifiedFile() async throws {
        let fixture = try await fixture(), transfer = try transfer(fixture), descriptor = descriptor(fixture)
        try await transfer.transfer(descriptor, from: fixture.source)
        try await transfer.transfer(descriptor, from: fixture.source)
        await transfer.close()
        let result = try await stats(fixture)
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(result["reserves"] as? Int, 2)
        XCTAssertEqual(result["verifications"] as? Int, 2)
        XCTAssertEqual(result["creations"] as? Int, 1)
        XCTAssertEqual(result["chunks"] as? [Int], [6 * 1024 * 1024, 1024 * 1024])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testVerificationOutageNeverReportsSuccessAndRetryDoesNotReuploadBytes() async throws {
        let fixture = try await fixture(mode: "verify_outage"), transfer = try transfer(fixture), descriptor = descriptor(fixture)
        do { try await transfer.transfer(descriptor, from: fixture.source); XCTFail("Upload alone is not verified") }
        catch let error as CarryAssetTransferFailure { XCTAssertEqual(error, .unavailable) }
        let incomplete = try await stats(fixture)
        XCTAssertNotEqual(incomplete["verified"] as? Bool, true)
        var recover = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8892/__recover/\(fixture.asset.id.uuidString)")))
        recover.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: recover)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        try await transfer.transfer(descriptor, from: fixture.source)
        await transfer.close()
        let complete = try await stats(fixture)
        XCTAssertEqual(complete["verified"] as? Bool, true)
        XCTAssertEqual(complete["creations"] as? Int, 1)
        XCTAssertEqual(complete["chunks"] as? [Int], [6 * 1024 * 1024, 1024 * 1024])
    }
}
