import XCTest
import CryptoKit
@testable import Carry

@MainActor
private final class AccountServiceDouble: CarryAccountAuthenticating {
    var isConfigured = true
    var cachedProfile: CarryAccountProfile?
    var restored: CarryAccountProfile?
    var signedIn = CarryAccountProfile(id: UUID(), displayName: "Test Traveler", email: nil)
    var failure: CarryAccountFailure?
    var signInCalls = 0
    var restoreCalls = 0
    var signOutCalls = 0
    var deleteCalls = 0
    var pauseSignIn: (() async -> Void)?
    func restore() async throws -> CarryAccountProfile? {
        restoreCalls += 1
        if let failure { throw failure }
        return restored
    }
    func signIn(_ credential: CarryAppleCredential, nonce: String) async throws -> CarryAccountProfile {
        signInCalls += 1
        if let pauseSignIn { await pauseSignIn() }
        if let failure { throw failure }
        return signedIn
    }
    func signOut() async throws {
        signOutCalls += 1
        if let failure { throw failure }
    }
    func deleteAccount(_ credential: CarryAppleCredential, nonce: String) async throws {
        deleteCalls += 1
        if let failure { throw failure }
    }
}

@MainActor
final class AccountTests: XCTestCase {
    private func credential(_ challenge: CarrySignInChallenge, state: String? = nil) -> CarryAppleCredential {
        CarryAppleCredential(idToken: "synthetic-token", authorizationCode: "synthetic-code",
            appleUserID: "synthetic-subject", fullName: nil, state: state ?? challenge.state)
    }

    func testProfileInitialsHandleWhitespaceChineseAndMissingNames() {
        let id = UUID()
        XCTAssertEqual(CarryAccountProfile(id: id, displayName: "  Jane Doe  ", email: nil).initials, "JD")
        XCTAssertEqual(CarryAccountProfile(id: id, displayName: "小明", email: nil).initials, "小明")
        XCTAssertNil(CarryAccountProfile(id: id, displayName: " \n ", email: nil).initials)
        XCTAssertNil(CarryAccountProfile(id: id, displayName: nil, email: nil).initials)
    }

    func testChallengeUsesIndependentNonceAndStateWithSHA256() throws {
        let one = try CarrySignInChallenge.generate(), two = try CarrySignInChallenge.generate()
        XCTAssertNotEqual(one.nonce, two.nonce)
        XCTAssertNotEqual(one.nonce, one.state)
        XCTAssertEqual(one.hashedNonce.count, 64)
        XCTAssertEqual(one.hashedNonce, SHA256.hash(data: Data(one.nonce.utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(one.nonce.contains("="))
    }

    func testConfigurationFailsClosedWithoutReleaseGateOrWithUnsafeURLOrKey() throws {
        let valid: [String: Any] = ["CarryAccountReleaseReady": true,
            "CarryAccountProjectURL": "https://account-qa.invalid", "CarryAccountPublishableKey": "sb_publishable_synthetic_qa_key"]
        XCTAssertNotNil(CarryAccountConfiguration.load(values: valid))
        for (key, value) in [
            ("CarryAccountReleaseReady", false as Any),
            ("CarryAccountProjectURL", "http://account-qa.invalid" as Any),
            ("CarryAccountProjectURL", "https://name:password@account-qa.invalid" as Any),
            ("CarryAccountProjectURL", "https://account-qa.invalid?token=secret" as Any),
            ("CarryAccountProjectURL", "https://account-qa.invalid/other" as Any),
            ("CarryAccountPublishableKey", "sb_secret_must_never_be_bundled" as Any)
        ] {
            var invalid = valid
            invalid[key] = value
            XCTAssertNil(CarryAccountConfiguration.load(values: invalid), key)
        }
        XCTAssertNil(CarryAccountConfiguration.load(values: [:]))
    }

    func testUnconfiguredServiceCannotStartOrRestore() async {
        let service = AccountServiceDouble(); service.isConfigured = false
        let store = CarryAccountStore(service: service)
        await store.restoreIfNeeded()
        XCTAssertThrowsError(try store.beginAppleAction())
        XCTAssertEqual(service.restoreCalls, 0)
        XCTAssertEqual(store.state, .signedOut)
    }

    func testCachedIdentityIsCheckingUntilServerConfirms() async {
        let service = AccountServiceDouble(); service.cachedProfile = service.signedIn; service.restored = service.signedIn
        let store = CarryAccountStore(service: service)
        XCTAssertEqual(store.state, .checking(service.signedIn))
        XCTAssertFalse(store.hasVerifiedSession)
        await store.restoreIfNeeded()
        XCTAssertEqual(store.state, .signedIn(service.signedIn))
        await store.restoreIfNeeded()
        XCTAssertEqual(service.restoreCalls, 1)
    }

    func testOfflinePreservesIdentityWithoutVerifiedSession() async {
        let service = AccountServiceDouble(); service.cachedProfile = service.signedIn; service.failure = .offline
        let store = CarryAccountStore(service: service)
        await store.refresh()
        XCTAssertEqual(store.state, .offline(service.signedIn))
        XCTAssertFalse(store.hasVerifiedSession)
    }

    func testExpiredAndAbsentSessionsKeepRecoveryIdentity() async {
        for failure in [nil, CarryAccountFailure.sessionExpired] {
            let service = AccountServiceDouble(); service.cachedProfile = service.signedIn; service.failure = failure
            let store = CarryAccountStore(service: service)
            await store.refresh()
            XCTAssertEqual(store.state, .needsReauthentication(service.signedIn))
        }
    }

    func testRestoredDifferentAccountIsRejected() async {
        let service = AccountServiceDouble(); service.cachedProfile = service.signedIn
        service.restored = CarryAccountProfile(id: UUID(), displayName: "Other", email: nil)
        let store = CarryAccountStore(service: service)
        await store.refresh()
        XCTAssertEqual(store.profile?.id, service.signedIn.id)
        XCTAssertEqual(store.error, .accountMismatch)
        XCTAssertFalse(store.hasVerifiedSession)
    }

    func testNativeCredentialIsNotASuccessUntilBackendReturns() async throws {
        let service = AccountServiceDouble()
        let store = CarryAccountStore(service: service)
        let challenge = try store.beginAppleAction()
        XCTAssertTrue(store.isBusy)
        XCTAssertFalse(store.hasVerifiedSession)
        store.cancelAppleAction()
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.error)
        await store.completeAppleAction(credential(challenge))
        XCTAssertEqual(service.signInCalls, 0)
        XCTAssertEqual(store.state, .signedOut)
    }

    func testStateMismatchConsumesChallengeWithoutContactingBackend() async throws {
        let service = AccountServiceDouble(), store: CarryAccountStore
        store = CarryAccountStore(service: service)
        let challenge = try store.beginAppleAction()
        await store.completeAppleAction(credential(challenge, state: "wrong-state"))
        XCTAssertEqual(store.error, .invalidCredential)
        await store.completeAppleAction(credential(challenge))
        XCTAssertEqual(service.signInCalls, 0)
        XCTAssertFalse(store.isBusy)
    }

    func testMissingAuthorizationCodeIsRejected() async throws {
        let service = AccountServiceDouble(), store: CarryAccountStore
        store = CarryAccountStore(service: service)
        let challenge = try store.beginAppleAction()
        await store.completeAppleAction(.init(idToken: "token", authorizationCode: "", appleUserID: "subject", fullName: nil, state: challenge.state))
        XCTAssertEqual(service.signInCalls, 0)
        XCTAssertEqual(store.error, .invalidCredential)
    }

    func testSuccessfulSignInAndDuplicateCallbackAreIdempotent() async throws {
        let service = AccountServiceDouble(), store: CarryAccountStore
        store = CarryAccountStore(service: service)
        let challenge = try store.beginAppleAction()
        await store.completeAppleAction(credential(challenge))
        await store.completeAppleAction(credential(challenge))
        XCTAssertEqual(service.signInCalls, 1)
        XCTAssertEqual(store.state, .signedIn(service.signedIn))
    }

    func testBackendFailureCannotCreateSignedInState() async throws {
        let service = AccountServiceDouble(); service.failure = .service
        let store = CarryAccountStore(service: service)
        let challenge = try store.beginAppleAction()
        await store.completeAppleAction(credential(challenge))
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(store.error, .service)
    }

    func testSigningIntoAnotherIdentityDoesNotSwitchCachedAccount() async throws {
        let service = AccountServiceDouble()
        service.cachedProfile = CarryAccountProfile(id: UUID(), displayName: "Original", email: nil)
        let store = CarryAccountStore(service: service)
        let challenge = try store.beginAppleAction()
        await store.completeAppleAction(credential(challenge))
        XCTAssertEqual(store.profile, service.cachedProfile)
        XCTAssertEqual(service.signOutCalls, 1)
        XCTAssertEqual(store.error, .accountMismatch)
    }

    func testLogoutFailureKeepsIdentityAndCanRetry() async {
        let service = AccountServiceDouble(); service.cachedProfile = service.signedIn; service.failure = .offline
        let store = CarryAccountStore(service: service)
        await store.signOut()
        XCTAssertEqual(store.profile, service.cachedProfile)
        service.failure = nil
        await store.signOut()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(service.signOutCalls, 2)
    }

    func testDeletionRequiresIdentityAndBackendConfirmation() async throws {
        let service = AccountServiceDouble(), store: CarryAccountStore
        store = CarryAccountStore(service: service)
        XCTAssertThrowsError(try store.beginAppleAction(.deleteAccount))
        service.cachedProfile = service.signedIn
        let signedInStore = CarryAccountStore(service: service)
        service.failure = .service
        var challenge = try signedInStore.beginAppleAction(.deleteAccount)
        await signedInStore.completeAppleAction(credential(challenge))
        XCTAssertEqual(signedInStore.profile, service.cachedProfile)
        service.failure = nil
        challenge = try signedInStore.beginAppleAction(.deleteAccount)
        await signedInStore.completeAppleAction(credential(challenge))
        XCTAssertEqual(signedInStore.state, .signedOut)
        XCTAssertEqual(service.deleteCalls, 2)
    }

    func testCancellationIsQuietButAuthorizationFailureIsVisible() throws {
        let store = CarryAccountStore(service: AccountServiceDouble())
        _ = try store.beginAppleAction(); store.failAppleAction(cancelled: true)
        XCTAssertNil(store.error)
        _ = try store.beginAppleAction(); store.failAppleAction(cancelled: false)
        XCTAssertEqual(store.error, .invalidCredential)
        XCTAssertFalse(store.isBusy)
    }

    func testConcurrentRefreshAndSignOutCannotOverrideInFlightExchange() async throws {
        let service = AccountServiceDouble(), entered = expectation(description: "Exchange entered")
        var resume: CheckedContinuation<Void, Never>?
        service.pauseSignIn = {
            await withCheckedContinuation { continuation in resume = continuation; entered.fulfill() }
        }
        let store = CarryAccountStore(service: service)
        let challenge = try store.beginAppleAction()
        let task = Task { await store.completeAppleAction(credential(challenge)) }
        await fulfillment(of: [entered], timeout: 2)
        store.cancelAppleAction()
        await store.refresh(); await store.signOut()
        XCTAssertTrue(store.isBusy)
        XCTAssertEqual(service.restoreCalls, 0)
        XCTAssertEqual(service.signOutCalls, 0)
        resume?.resume()
        await task.value
        XCTAssertTrue(store.hasVerifiedSession)
        XCTAssertFalse(store.isBusy)
    }
}
