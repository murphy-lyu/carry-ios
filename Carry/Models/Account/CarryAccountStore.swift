import Foundation
import Combine
import CryptoKit
import Security

struct CarryAccountProfile: Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String?
    var email: String?

    var initials: String? {
        guard let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let words = name.split(whereSeparator: \.isWhitespace)
        let characters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(characters).uppercased()
    }
}

enum CarryAccountFailure: Error, Equatable {
    case unavailable, cancelled, invalidCredential, sessionExpired, offline, storage, accountMismatch, service

    var messageKey: String {
        switch self {
        case .unavailable: return "account.error.unavailable"
        case .cancelled: return "account.error.cancelled"
        case .invalidCredential: return "account.error.credential"
        case .sessionExpired: return "account.error.expired"
        case .offline: return "account.error.offline"
        case .storage: return "account.error.storage"
        case .accountMismatch: return "account.error.mismatch"
        case .service: return "account.error.service"
        }
    }
}

struct CarryAppleCredential: Sendable {
    let idToken: String
    let authorizationCode: String
    let appleUserID: String
    let fullName: String?
    let state: String?
}

enum CarryAccountDeletionProgress: Equatable { case none, pending, completed }

struct CarrySignInChallenge: Equatable, Sendable {
    let nonce: String
    let state: String
    var hashedNonce: String { SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func generate() throws -> Self {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw CarryAccountFailure.invalidCredential
            }
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return try Self(nonce: random(), state: random())
    }
}

/// A backend adapter returns a profile only after server-side identity validation.
/// No TripStore/CloudKit reference is available here: signing in cannot upload or erase trips.
@MainActor
protocol CarryAccountAuthenticating: AnyObject {
    var isConfigured: Bool { get }
    var cachedProfile: CarryAccountProfile? { get }
    func restore() async throws -> CarryAccountProfile?
    func signIn(_ credential: CarryAppleCredential, nonce: String) async throws -> CarryAccountProfile
    func signOut() async throws
    func deleteAccount(_ credential: CarryAppleCredential, nonce: String) async throws
    var pendingDeletion: Bool { get throws }
    func refreshDeletion() async throws -> CarryAccountDeletionProgress
}

extension CarryAccountAuthenticating {
    var pendingDeletion: Bool { get throws { false } }
    func refreshDeletion() async throws -> CarryAccountDeletionProgress { .none }
}

@MainActor
final class CarryAccountStore: ObservableObject {
    enum State: Equatable {
        case signedOut
        case checking(CarryAccountProfile)
        case signedIn(CarryAccountProfile)
        case offline(CarryAccountProfile)
        case temporarilyUnavailable(CarryAccountProfile)
        case needsReauthentication(CarryAccountProfile)
        case deleting(CarryAccountProfile?)

        var profile: CarryAccountProfile? {
            switch self {
            case .signedOut: return nil
            case .checking(let p), .signedIn(let p), .offline(let p), .temporarilyUnavailable(let p), .needsReauthentication(let p): return p
            case .deleting(let p): return p
            }
        }
    }

    @Published private(set) var state: State
    @Published private(set) var isBusy = false
    @Published private(set) var error: CarryAccountFailure?
    private let service: any CarryAccountAuthenticating
    private var challenge: CarrySignInChallenge?
    private var action: AppleAction?
    private var hasRestored = false

    enum AppleAction { case signIn, deleteAccount }

    var isAvailable: Bool { service.isConfigured }
    var profile: CarryAccountProfile? { state.profile }
    var hasVerifiedSession: Bool {
        if case .signedIn = state { return true }
        return false
    }
    var isDeleting: Bool {
        if case .deleting = state { return true }
        return false
    }

    init(service: any CarryAccountAuthenticating) {
        self.service = service
        state = service.cachedProfile.map(State.checking) ?? .signedOut
        do { if try service.pendingDeletion { state = .deleting(service.cachedProfile) } }
        catch { self.error = .storage }
    }

    func restoreIfNeeded() async {
        guard !hasRestored else { return }
        await refresh()
    }

    func refresh() async {
        guard isAvailable, !isBusy else { return }
        isBusy = true
        defer { isBusy = false; hasRestored = true }
        do {
            switch try await service.refreshDeletion() {
            case .pending: state = .deleting(profile); error = nil; return
            case .completed: state = .signedOut; error = nil; return
            case .none: break
            }
            if let restored = try await service.restore() {
                guard profile == nil || profile?.id == restored.id else {
                    throw CarryAccountFailure.accountMismatch
                }
                state = .signedIn(restored)
            } else if let profile {
                state = .needsReauthentication(profile)
            } else {
                state = .signedOut
            }
            error = nil
        } catch {
            applyFailure(error)
        }
    }

    /// Holds the operation lock across Apple's native prompt and the token exchange.
    func beginAppleAction(_ action: AppleAction = .signIn) throws -> CarrySignInChallenge {
        guard isAvailable, !isBusy, !isDeleting else { throw CarryAccountFailure.unavailable }
        if action == .deleteAccount, profile == nil { throw CarryAccountFailure.sessionExpired }
        let generated = try CarrySignInChallenge.generate()
        challenge = generated
        self.action = action
        isBusy = true
        error = nil
        if action == .signIn { CarryLogger.shared.log(.accountSignInStarted) }
        return generated
    }

    func cancelAppleAction() {
        // Only cancel an outstanding system prompt; do not unlock an in-flight exchange.
        guard challenge != nil else { return }
        challenge = nil
        action = nil
        isBusy = false
        error = nil
    }

    func completeAppleAction(_ credential: CarryAppleCredential) async {
        guard let challenge, let action else { return } // duplicate/late completion is inert
        self.challenge = nil
        self.action = nil
        defer { isBusy = false }
        guard credential.state == challenge.state, !credential.idToken.isEmpty,
              !credential.authorizationCode.isEmpty, !credential.appleUserID.isEmpty else {
            error = .invalidCredential
            CarryLogger.shared.log(.accountOperationFailed, context: "reason=invalid_credential")
            return
        }
        do {
            switch action {
            case .signIn:
                let previous = profile
                let signedIn = try await service.signIn(credential, nonce: challenge.nonce)
                guard previous == nil || previous?.id == signedIn.id else {
                    // No data switch is allowed just because another Apple identity was selected.
                    try await service.signOut()
                    throw CarryAccountFailure.accountMismatch
                }
                state = .signedIn(signedIn)
                CarryLogger.shared.log(.accountSignInSucceeded)
            case .deleteAccount:
                try await service.deleteAccount(credential, nonce: challenge.nonce)
                if try service.pendingDeletion {
                    state = .deleting(profile)
                } else {
                    state = .signedOut
                    CarryLogger.shared.log(.accountDeleted)
                }
            }
            error = nil
        } catch {
            applyFailure(error)
        }
    }

    func failAppleAction(cancelled: Bool) {
        guard challenge != nil else { return }
        cancelAppleAction()
        if !cancelled {
            error = .invalidCredential
            CarryLogger.shared.log(.accountOperationFailed, context: "reason=apple_authorization_failed")
        }
    }

    func signOut() async {
        guard !isBusy, !isDeleting else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.signOut()
            state = .signedOut
            CarryLogger.shared.log(.accountSignedOut)
            error = nil
        } catch { applyFailure(error) }
    }

    private func applyFailure(_ cause: Error) {
        let failure = cause as? CarryAccountFailure ?? .service
        if error != failure { CarryLogger.shared.log(.accountOperationFailed, context: "reason=\(failure.messageKey)") }
        error = failure
        if isDeleting { return }
        guard let profile else { return }
        switch failure {
        case .offline: state = .offline(profile)
        case .sessionExpired, .accountMismatch: state = .needsReauthentication(profile)
        default: state = .temporarilyUnavailable(profile)
        }
    }
}
