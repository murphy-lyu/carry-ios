import XCTest
@testable import Carry

@MainActor
final class AccountAdapterTests: XCTestCase {
    private var storage: CarryAccountSecureStorage!
    private let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

    override func setUp() async throws {
        storage = CarryAccountSecureStorage(namespace: "qa-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for key in ["profile", "session", "apple-name-synthetic-subject"] { try storage.remove(key: key) }
    }

    private var configuration: CarryAccountConfiguration {
        .init(projectURL: URL(string: "https://account-qa.invalid")!, publishableKey: "sb_publishable_synthetic_qa_key")
    }

    private func userJSON() -> [String: Any] {
        ["id": userID.uuidString, "app_metadata": ["provider": "apple", "providers": ["apple"]],
         "user_metadata": [String: String](), "aud": "authenticated", "role": "authenticated",
         "created_at": "2026-10-26T00:00:00Z", "updated_at": "2026-10-26T00:00:00Z", "is_anonymous": false]
    }

    private func sessionJSON() -> [String: Any] {
        ["access_token": "synthetic-access", "token_type": "bearer", "expires_in": 3600,
         "expires_at": Date().timeIntervalSince1970 + 3600, "refresh_token": "synthetic-refresh", "user": userJSON()]
    }

    private var credential: CarryAppleCredential {
        .init(idToken: "synthetic-id-token", authorizationCode: "synthetic-code", appleUserID: "synthetic-subject",
              fullName: "Test Traveler", state: "synthetic-state")
    }

    func testSDKExchangePersistsProfileOnlyAfterLifecycleEnrollmentAndRestoresThroughServer() async throws {
        let session = try JSONSerialization.data(withJSONObject: sessionJSON())
        let user = try JSONSerialization.data(withJSONObject: userJSON())
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "account-qa.invalid")
            var data: Data
            switch (request.httpMethod ?? "GET", url.path) {
            case ("POST", "/auth/v1/token"):
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(object["provider"] as? String, "apple")
                XCTAssertEqual(object["nonce"] as? String, "raw-synthetic-nonce")
                data = session
            case ("GET", "/auth/v1/user"), ("PUT", "/auth/v1/user"): data = user
            case ("POST", "/functions/v1/carry-account"):
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(object["action"] as? String, "enroll")
                XCTAssertEqual(object["authorizationCode"] as? String, "synthetic-code")
                data = Data("{\"status\":\"enrolled\"}".utf8)
            case ("GET", "/functions/v1/carry-account"): data = Data("{\"status\":\"enrolled\"}".utf8)
            default: XCTFail("Unexpected request route \(url.path)"); throw CarryAccountFailure.service
            }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let profile = try await service.signIn(credential, nonce: "raw-synthetic-nonce")
        XCTAssertEqual(profile.id, userID)
        XCTAssertEqual(profile.displayName, "Test Traveler")
        XCTAssertNotNil(try storage.retrieve(key: "session"))
        XCTAssertEqual(service.cachedProfile, profile)
        let restored = try await service.restore()
        XCTAssertEqual(restored?.id, userID)
        XCTAssertEqual(restored?.displayName, "Test Traveler")
    }

    func testLifecycleFailureNeverPublishesProfileAndRestoreCannotBypassEnrollment() async throws {
        let session = try JSONSerialization.data(withJSONObject: sessionJSON())
        let user = try JSONSerialization.data(withJSONObject: userJSON())
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/auth/v1/token" { return (session, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            if url.path == "/auth/v1/user" { return (user, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            return (Data("{\"status\":\"not_enrolled\"}".utf8), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await service.signIn(credential, nonce: "nonce"); XCTFail("Must reject incomplete enrollment") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .service) }
        XCTAssertNil(service.cachedProfile)
        do { _ = try await service.restore(); XCTFail("Restore must recheck enrollment") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .service) }
        XCTAssertNil(service.cachedProfile)
        XCTAssertEqual(String(data: try XCTUnwrap(storage.retrieve(key: "apple-name-synthetic-subject")), encoding: .utf8), "Test Traveler")
    }

    func testLogoutNetworkFailurePreservesSessionAndCachedIdentity() async throws {
        try storage.store(key: "session", value: JSONSerialization.data(withJSONObject: sessionJSON()))
        let profile = CarryAccountProfile(id: userID, displayName: "Test Traveler", email: nil)
        try storage.store(key: "profile", value: JSONEncoder().encode(profile))
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { _ in throw URLError(.notConnectedToInternet) })
        do { try await service.signOut(); XCTFail("Offline logout must not claim remote revocation") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .offline) }
        XCTAssertNotNil(try storage.retrieve(key: "session"))
        XCTAssertEqual(service.cachedProfile, profile)
    }

    func testMalformedLifecycleSuccessIsRejected() async throws {
        let session = try JSONSerialization.data(withJSONObject: sessionJSON())
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            let data = url.path == "/auth/v1/token" ? session : Data("{\"status\":\"ok\"}".utf8)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await service.signIn(credential, nonce: "nonce"); XCTFail("Generic 200 is not enrollment") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .service) }
        XCTAssertNil(service.cachedProfile)
    }
    func testDataTransportRejectsCacheOwnerMismatchBeforeAnyNetworkRequest() async throws {
        try storage.store(key: "session", value: JSONSerialization.data(withJSONObject: sessionJSON()))
        try storage.store(key: "profile", value: JSONEncoder().encode(CarryAccountProfile(id: userID, displayName: nil, email: nil)))
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { _ in
            XCTFail("A different account's cache must not contact the API")
            throw CarryAccountFailure.service
        })
        let transport = try service.graphTransport(for: UUID())
        do { _ = try await transport.pull(cursor: 0); XCTFail("Must reject wrong owner") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .accountMismatch) }
    }

}
