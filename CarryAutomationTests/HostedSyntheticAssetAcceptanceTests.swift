import XCTest
import CryptoKit
@testable import Carry

/// Explicit device-only acceptance. Never creates an identity, uploads, deletes,
/// exports a bearer, or reads guest trips. Ordinary local/CI suites skip it.
@MainActor
final class HostedSyntheticAssetAcceptanceTests: XCTestCase {
    func testExistingSyntheticFixtureDownloadsWithVerifiedBytesAndRejectsRange() async throws {
        guard ProcessInfo.processInfo.environment["CARRY_HOSTED_SYNTHETIC_ASSET_QA"] == "read-only-carry-dev" else {
            throw XCTSkip("Requires an explicitly selected, signed-in physical acceptance device")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Hosted acceptance must use the existing physical Carry session")
        #else
        let secrets = try XCTUnwrap(Bundle.main.url(forResource: "Secrets", withExtension: "plist"))
        var values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: secrets), format: nil) as? [String: Any])
        values["CarryAccountReleaseReady"] = true
        let configuration = try XCTUnwrap(CarryAccountConfiguration.load(values: values))
        guard configuration.projectURL.host == "lbxsvguuoqqpctkinpwy.supabase.co" else {
            XCTFail("Hosted fixture QA is restricted to carry-dev"); return
        }
        let service = CarryAccountService(configuration: configuration)
        guard let profile = try await service.restore() else {
            XCTFail("The original Carry must already have a verified user session"); return
        }
        let graph = try service.graphTransport(for: profile.id)
        var cursor = 0, entities: [UUID: CarryGraphEntity] = [:], exhausted = false
        for _ in 0..<20 {
            let page = try await graph.pull(cursor: cursor)
            for change in page.changes { entities[change.entity.id] = change.entity }
            cursor = page.cursor
            if !page.hasMore { exhausted = true; break }
        }
        XCTAssertTrue(exhausted)
        let fixture = try XCTUnwrap(entities.values.first {
            $0.kind == "attachment" && $0.fields["displayName"] == .string("Carry-QA-attachment-20261101.txt")
        })
        guard case .string(let rawID) = fixture.fields["fileAssetID"], let assetID = UUID(uuidString: rawID) else {
            XCTFail("The synthetic attachment must have a published immutable asset"); return
        }
        let token: @Sendable () async throws -> String = { try await service.accessToken(for: profile.id) }
        let manifests = try CarryAccountAssetManifestClient(accountID: profile.id, projectURL: configuration.projectURL,
            publishableKey: configuration.publishableKey, accessToken: token)
        let manifest = try await manifests.manifest(assetID)
        await manifests.close()
        let expected = "47491b540f186807cedebe39a39923ab62a87f67f5987f31df298cde79f0f106"
        XCTAssertEqual(manifest.sha256, expected)
        XCTAssertEqual(manifest.byteCount, 131072)
        XCTAssertTrue(manifest.entityID == fixture.id && manifest.kind == "attachment" && manifest.slot == "file")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryHostedSyntheticAsset-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = try CarryAssetDownloader(accountID: profile.id, projectURL: configuration.projectURL,
            directory: directory, publishableKey: configuration.publishableKey, accessToken: token)
        let file: URL
        do {
            file = try await downloader.download(.init(id: assetID, accountID: profile.id, sha256: expected, byteCount: 131072))
        } catch {
            // Report only metadata flags/depth, never a sandbox path or ID.
            var part = directory.resolvingSymlinksInPath().appendingPathComponent("downloads").appendingPathComponent(profile.id.uuidString.lowercased())
            var depth = 0
            while part.path != "/" {
                let flags = try part.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                print("carry_qa_directory_flags depth=\(depth) directory=\(flags.isDirectory == true) symlink=\(flags.isSymbolicLink == true)")
                part.deleteLastPathComponent(); depth += 1
            }
            throw error
        }
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(bytes.count, 131072)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected)
        try await downloader.close()
        var request = URLRequest(url: configuration.projectURL.appendingPathComponent("functions/v1/carry-assets/download/" + assetID.uuidString.lowercased()))
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=0-7", forHTTPHeaderField: "Range")
        let (_, response) = try await CarryGraphTransport.boundedResponse(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        #endif
    }
}
