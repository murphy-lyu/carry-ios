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
        for key in ["profile", "session", "apple-name-synthetic-subject", "deletion-receipt"] { try storage.remove(key: key) }
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

    func testDeletionReceiptIsDurableAndCanConfirmCompletionWithoutAnyUserSession() async throws {
        let token = String(repeating: "a", count: 64)
        try storage.store(key: "deletion-receipt", value: JSONSerialization.data(withJSONObject: [
            "accountID": userID.uuidString, "appleUserID": "synthetic-subject", "token": token, "accepted": true
        ]))
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/functions/v1/carry-account-status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertNil(request.httpBody)
            return (Data("{\"status\":\"deleted\"}".utf8),
                    try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        XCTAssertTrue(try service.pendingDeletion)
        let result = try await service.refreshDeletion()
        XCTAssertEqual(result, .completed)
        XCTAssertFalse(try service.pendingDeletion)
        XCTAssertNil(try storage.retrieve(key: "deletion-receipt"))
    }

    func testUnacceptedUnknownReceiptNeverCountsAsCompletedDeletion() async throws {
        try storage.store(key: "deletion-receipt", value: JSONSerialization.data(withJSONObject: [
            "accountID": userID.uuidString, "appleUserID": "synthetic-subject", "token": String(repeating: "a", count: 64), "accepted": false
        ]))
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            return (Data("{\"error\":\"unauthorized\"}".utf8),
                    try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)))
        })
        let result = try await service.refreshDeletion()
        XCTAssertEqual(result, .none)
        XCTAssertNotNil(try storage.retrieve(key: "deletion-receipt"))
    }

    func testDeletionAcceptanceUsesFreshAppleAndPersistsReceiptBeforePosting() async throws {
        try storage.store(key: "session", value: JSONSerialization.data(withJSONObject: sessionJSON()))
        try storage.store(key: "profile", value: JSONEncoder().encode(CarryAccountProfile(id: userID, displayName: nil, email: nil)))
        let session = try JSONSerialization.data(withJSONObject: sessionJSON())
        let user = try JSONSerialization.data(withJSONObject: userJSON())
        let secure = try XCTUnwrap(storage)
        let service = CarryAccountService(configuration: configuration, storage: secure, send: { request in
            let url = try XCTUnwrap(request.url)
            let data: Data
            let code: Int
            switch url.path {
            case "/auth/v1/token": data = session; code = 200
            case "/auth/v1/user": data = user; code = 200
            case "/functions/v1/carry-account":
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(secure.retrieve(key: "deletion-receipt"))) as? [String: Any])
                XCTAssertEqual(body["deletionReceipt"] as? String, persisted["token"] as? String)
                XCTAssertEqual((body["deletionReceipt"] as? String)?.count, 64)
                XCTAssertEqual(persisted["accepted"] as? Bool, false)
                data = Data("{\"status\":\"deleting\"}".utf8); code = 202
            default: XCTFail("Unexpected deletion request"); throw CarryAccountFailure.service
            }
            return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)))
        })
        try await service.deleteAccount(credential, nonce: "synthetic-nonce")
        XCTAssertTrue(try service.pendingDeletion)
        XCTAssertNotNil(service.cachedProfile)
        do { try await service.signOut(); XCTFail("Must retain a pending request's owner and receipt") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .unavailable) }
    }

    func testLostDeletionResponseRecoversThroughReceiptWithoutReplayingTheAppleCode() async throws {
        try storage.store(key: "session", value: JSONSerialization.data(withJSONObject: sessionJSON()))
        try storage.store(key: "profile", value: JSONEncoder().encode(CarryAccountProfile(id: userID, displayName: nil, email: nil)))
        let session = try JSONSerialization.data(withJSONObject: sessionJSON())
        let user = try JSONSerialization.data(withJSONObject: userJSON())
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/functions/v1/carry-account" { throw URLError(.networkConnectionLost) }
            let data = url.path == "/auth/v1/token" ? session : user
            return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        do { try await service.deleteAccount(credential, nonce: "synthetic-nonce"); XCTFail("Lost response is not completion") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .offline) }
        let restored = CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/functions/v1/carry-account-status", "Recovery must not exchange another one-use Apple code")
            return (Data("{\"status\":\"deleting\"}".utf8),
                    try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let progress = try await restored.refreshDeletion()
        XCTAssertEqual(progress, .pending)
        XCTAssertTrue(try restored.pendingDeletion)
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
