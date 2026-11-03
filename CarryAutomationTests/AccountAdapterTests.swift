import XCTest
@testable import Carry

@MainActor
final class AccountAdapterTests: XCTestCase {
    func testAccountAIEntryRequiresBothReleaseGatesAndUsesFixedCredentialFreeURLs() throws {
        let accountValues: [String: Any] = ["CarryAccountReleaseReady": true,
            "CarryAccountProjectURL": "https://project-qa.invalid",
            "CarryAccountPublishableKey": "sb_publishable_synthetic_only"]
        XCTAssertNil(CarryAccountAIConfiguration.load(values: accountValues))
        var values = accountValues
        values["CarryAccountAIReleaseReady"] = "true"
        XCTAssertNil(CarryAccountAIConfiguration.load(values: values))
        values["CarryAccountAIReleaseReady"] = true
        let configuration = try XCTUnwrap(CarryAccountAIConfiguration.load(values: values))
        XCTAssertEqual(configuration.connectionsURL.absoluteString, "https://account.nevestudio.app/connections")
        XCTAssertEqual(configuration.mcpURL.absoluteString, "https://connect.nevestudio.app/mcp")
        values["CarryAccountReleaseReady"] = false
        XCTAssertNil(CarryAccountAIConfiguration.load(values: values))
        values["CarryAccountReleaseReady"] = true
        values["CarryAccountPublishableKey"] = nil
        XCTAssertNil(CarryAccountAIConfiguration.load(values: values))
    }
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

    private func emailService(canonical: String, identities: [[String: Any]], metadata: [String: Any] = [:]) throws -> CarryAccountService {
        var user = userJSON()
        user["email"] = canonical
        user["identities"] = identities
        user["user_metadata"] = metadata
        var session = sessionJSON()
        session["user"] = user
        let userData = try JSONSerialization.data(withJSONObject: user)
        let sessionData = try JSONSerialization.data(withJSONObject: session)
        return CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            let data: Data
            switch url.path {
            case "/auth/v1/token": data = sessionData
            case "/auth/v1/user": data = userData
            case "/functions/v1/carry-account": data = Data("{\"status\":\"enrolled\"}".utf8)
            default: XCTFail("Unexpected email profile request"); throw CarryAccountFailure.service
            }
            return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
    }

    private func appleIdentity(email: String, verified: Any = true, provider: String = "apple", owner: UUID? = nil) -> [String: Any] {
        ["id": "synthetic-subject", "identity_id": UUID().uuidString,
         "user_id": (owner ?? userID).uuidString, "provider": provider,
         "identity_data": ["sub": "synthetic-subject", "email": email, "email_verified": verified]]
    }

    func testSharedAppleEmailReplacesStaleRelayDisplayOnSignInAndRestore() async throws {
        let service = try emailService(canonical: "old@privaterelay.appleid.com",
            identities: [appleIdentity(email: "shared@example.invalid")],
            metadata: ["email": "untrusted@example.invalid", "email_verified": true])
        let profile = try await service.signIn(credential, nonce: "synthetic-nonce")
        XCTAssertEqual(profile.id, userID)
        XCTAssertEqual(profile.email, "shared@example.invalid")
        XCTAssertEqual(service.cachedProfile?.email, profile.email)
        let restored = try await service.restore()
        XCTAssertEqual(restored?.email, profile.email)
    }

    func testChoosingHiddenAppleEmailRemainsPrivateEvenWhenAccountEmailWasShared() async throws {
        let service = try emailService(canonical: "previously-shared@example.invalid",
            identities: [appleIdentity(email: "current@privaterelay.appleid.com", verified: "true")])
        let profile = try await service.signIn(credential, nonce: "synthetic-nonce")
        XCTAssertEqual(profile.email, "current@privaterelay.appleid.com")
    }

    func testUnverifiedForeignAmbiguousOrMissingIdentityCannotOverrideAccountEmail() async throws {
        let wrongOwner = UUID()
        let cases: [[[String: Any]]] = [
            [appleIdentity(email: "unverified@example.invalid", verified: false)],
            [appleIdentity(email: "other-provider@example.invalid", provider: "google")],
            [appleIdentity(email: "other-owner@example.invalid", owner: wrongOwner)],
            [appleIdentity(email: "one@example.invalid"), appleIdentity(email: "two@example.invalid")], []
        ]
        for identities in cases {
            let service = try emailService(canonical: "original@privaterelay.appleid.com", identities: identities,
                metadata: ["email": "spoofed@example.invalid", "email_verified": true])
            let profile = try await service.signIn(credential, nonce: "synthetic-nonce")
            XCTAssertEqual(profile.email, "original@privaterelay.appleid.com")
        }
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

    func testHeldDeletionRecoveryUsesFreshAppleAndClearsReceiptOnlyAfterConfirmedRecovery() async throws {
        let secure = try XCTUnwrap(storage)
        try secure.store(key: "profile", value: JSONEncoder().encode(CarryAccountProfile(id: userID, displayName: "Retained", email: nil)))
        let receipt: [String: Any] = ["accountID": userID.uuidString, "appleUserID": "synthetic-subject", "token": String(repeating: "a", count: 64), "accepted": true]
        try secure.store(key: "deletion-receipt", value: JSONSerialization.data(withJSONObject: receipt))
        let session = try JSONSerialization.data(withJSONObject: sessionJSON())
        let service = CarryAccountService(configuration: configuration, storage: secure, send: { request in
            let url = try XCTUnwrap(request.url)
            let data: Data
            if url.path == "/auth/v1/token" { data = session }
            else {
                XCTAssertEqual(url.path, "/functions/v1/carry-account")
                XCTAssertNotNil(try secure.retrieve(key: "deletion-receipt"))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(body["action"] as? String, "recover")
                XCTAssertEqual(body["deletionReceipt"] as? String, String(repeating: "a", count: 64))
                data = Data("{\"status\":\"cancelled\"}".utf8)
            }
            return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let profile = try await service.recoverDeletion(credential, nonce: "synthetic-nonce")
        XCTAssertEqual(profile.id, userID)
        XCTAssertFalse(try service.pendingDeletion)
        XCTAssertNotNil(try secure.retrieve(key: "profile"))
        XCTAssertNotNil(try secure.retrieve(key: "session"))
    }

    func testFailedRecoveryKeepsPendingReceiptAndOriginalProfile() async throws {
        let secure = try XCTUnwrap(storage)
        try secure.store(key: "profile", value: JSONEncoder().encode(CarryAccountProfile(id: userID, displayName: "Retained", email: nil)))
        try secure.store(key: "deletion-receipt", value: JSONSerialization.data(withJSONObject: ["accountID": userID.uuidString,
            "appleUserID": "synthetic-subject", "token": String(repeating: "a", count: 64), "accepted": true]))
        let session = try JSONSerialization.data(withJSONObject: sessionJSON())
        let service = CarryAccountService(configuration: configuration, storage: secure, send: { request in
            let url = try XCTUnwrap(request.url)
            return (url.path == "/auth/v1/token" ? session : Data("{}".utf8),
                    try XCTUnwrap(HTTPURLResponse(url: url, statusCode: url.path == "/auth/v1/token" ? 200 : 503, httpVersion: nil, headerFields: nil)))
        })
        do { _ = try await service.recoverDeletion(credential, nonce: "synthetic-nonce"); XCTFail("Unverified recovery must fail") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .service) }
        XCTAssertTrue(try service.pendingDeletion)
        XCTAssertEqual(service.cachedProfile?.id, userID)
        do { _ = try await service.signIn(credential, nonce: "synthetic-nonce"); XCTFail("Ordinary sign-in cannot bypass deletion") }
        catch { XCTAssertEqual(error as? CarryAccountFailure, .unavailable) }
    }

    func testCancelledReceiptNeverClearsProfileOrPretendsDeletionCompleted() async throws {
        let profile = CarryAccountProfile(id: userID, displayName: "Retained", email: nil)
        try storage.store(key: "profile", value: JSONEncoder().encode(profile))
        try storage.store(key: "session", value: Data("retained-session".utf8))
        try storage.store(key: "deletion-receipt", value: JSONSerialization.data(withJSONObject: ["accountID": userID.uuidString,
            "appleUserID": "synthetic-subject", "token": String(repeating: "a", count: 64), "accepted": true]))
        let service = CarryAccountService(configuration: configuration, storage: storage, send: { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/functions/v1/carry-account-status")
            return (Data("{\"status\":\"cancelled\"}".utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let result = try await service.refreshDeletion()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(service.cachedProfile, profile)
        XCTAssertNotNil(try storage.retrieve(key: "session"))
        XCTAssertFalse(try service.pendingDeletion)
    }

}
