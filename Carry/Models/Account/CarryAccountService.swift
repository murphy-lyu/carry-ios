import Foundation
import Auth
import Security

struct CarryAccountConfiguration {
    let projectURL: URL
    let publishableKey: String

    /// Release opt-in is deliberate: credentials alone must not publish unfinished cloud features.
    static func load(values: [String: Any]) -> Self? {
        guard values["CarryAccountReleaseReady"] as? Bool == true,
              let rawURL = values["CarryAccountProjectURL"] as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let key = values["CarryAccountPublishableKey"] as? String,
              key.hasPrefix("sb_publishable_"), key.count > 20 else { return nil }
        return Self(projectURL: url, publishableKey: key)
    }

    static var bundled: Self? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return load(values: values)
    }
}

/// Sessions, first-authorization name and cached identity share a per-project Keychain namespace.
/// They are not iCloud-synchronizable and never stored in UserDefaults or event logs.
struct CarryAccountSecureStorage: AuthLocalStorage {
    let namespace: String

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.nevestudio.carry.account.\(namespace)",
         kSecAttrAccount as String: key]
    }

    func store(key: String, value: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(key).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw CarryAccountFailure.storage
            }
        } else if status != errSecSuccess { throw CarryAccountFailure.storage }
    }

    func retrieve(key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CarryAccountFailure.storage }
        return data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CarryAccountFailure.storage }
    }
}

@MainActor
final class CarryAccountService: CarryAccountAuthenticating {
    private struct DeletionReceipt: Codable {
        let accountID: UUID
        let appleUserID: String
        let token: String
        var accepted: Bool
    }
    private let configuration: CarryAccountConfiguration?
    private let client: AuthClient?
    private let storage: CarryAccountSecureStorage
    private let send: AuthClient.FetchHandler

    var isConfigured: Bool { configuration != nil }
    var pendingDeletion: Bool { get throws { try receipt() != nil } }
    var cachedProfile: CarryAccountProfile? {
        guard let data = try? storage.retrieve(key: "profile") else { return nil }
        return try? JSONDecoder().decode(CarryAccountProfile.self, from: data)
    }

    convenience init() { self.init(configuration: .bundled) }

    init(configuration: CarryAccountConfiguration?,
         storage: CarryAccountSecureStorage? = nil,
         send: @escaping AuthClient.FetchHandler = { request in
             var bounded = request
             bounded.timeoutInterval = 20
             return try await CarryGraphTransport.boundedResponse(bounded)
         }) {
        self.configuration = configuration
        self.send = send
        self.storage = storage ?? CarryAccountSecureStorage(namespace: configuration?.projectURL.host ?? "disabled")
        if let configuration {
            client = AuthClient(url: configuration.projectURL.appendingPathComponent("auth/v1"),
                headers: ["apikey": configuration.publishableKey], storageKey: "session",
                localStorage: self.storage, fetch: send, autoRefreshToken: false,
                emitLocalSessionAsInitialSession: true)
        } else { client = nil }
    }

    func restore() async throws -> CarryAccountProfile? {
        guard let client else { throw CarryAccountFailure.unavailable }
        guard client.currentSession != nil else { return nil }
        do {
            let session = try await client.session
            let user = try await client.user(jwt: session.accessToken)
            guard cachedProfile == nil || cachedProfile?.id == user.id else { throw CarryAccountFailure.accountMismatch }
            try await verifyLifecycle(accessToken: session.accessToken)
            try persistSession(session)
            return try saveProfile(user)
        } catch { throw classify(error) }
    }

    func signIn(_ credential: CarryAppleCredential, nonce: String) async throws -> CarryAccountProfile {
        guard let client else { throw CarryAccountFailure.unavailable }
        guard try receipt() == nil else { throw CarryAccountFailure.unavailable }
        // Persist the name before the first exchange; Apple may never return it again after a failure.
        let nameKey = "apple-name-\(credential.appleUserID)"
        if let name = credential.fullName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try storage.store(key: nameKey, value: Data(name.utf8))
        }
        do {
            let session = try await client.signInWithIdToken(credentials: .init(provider: .apple,
                idToken: credential.idToken, nonce: nonce))
            guard cachedProfile == nil || cachedProfile?.id == session.user.id else {
                try await signOut()
                throw CarryAccountFailure.accountMismatch
            }
            try persistSession(session)
            // Enrol the code for server-managed Apple revocation. Native token verification alone
            // is insufficient to claim a complete account lifecycle.
            try await lifecycle(action: "enroll", credential: credential, nonce: nonce,
                                accessToken: session.accessToken, expectedStatus: "enrolled")
            let name = try storage.retrieve(key: nameKey).flatMap { String(data: $0, encoding: .utf8) }
            let profile = try saveProfile(session.user, name: name)
            if let name {
                // The local first-name copy remains durable if optional metadata delivery fails.
                _ = try? await client.update(user: UserAttributes(data: ["full_name": .string(name)]))
            }
            return profile
        } catch { throw classify(error) }
    }

    func signOut() async throws {
        guard let client, let configuration else { throw CarryAccountFailure.unavailable }
        // A timed-out deletion request may still commit remotely. Do not lose
        // its owner/receipt through logout or silently switch accounts mid-flight.
        guard try receipt() == nil else { throw CarryAccountFailure.unavailable }
        do {
            if let session = client.currentSession {
                var request = URLRequest(url: configuration.projectURL.appendingPathComponent("auth/v1/logout")
                    .appending(queryItems: [.init(name: "scope", value: "local")]))
                request.httpMethod = "POST"
                request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await send(request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) || [401, 403, 404].contains(http.statusCode) else {
                    throw CarryAccountFailure.service
                }
            }
            // Supabase removes its local session before performing logout. Revoke remotely first
            // so a network failure leaves the app able to retry rather than falsely signing out.
            try? await client.signOut(scope: .local)
            try storage.remove(key: "session")
            try storage.remove(key: "profile")
        } catch { throw classify(error) }
    }

    func deleteAccount(_ credential: CarryAppleCredential, nonce: String) async throws {
        guard let client, let expected = cachedProfile else { throw CarryAccountFailure.sessionExpired }
        do {
            if try await refreshDeletion() != .none { return }
            let session = try await client.signInWithIdToken(credentials: .init(provider: .apple,
                idToken: credential.idToken, nonce: nonce))
            let user = try await client.user(jwt: session.accessToken)
            guard user.id == expected.id else { throw CarryAccountFailure.accountMismatch }
            try persistSession(session)
            var saved: DeletionReceipt
            if let existing = try receipt() {
                guard existing.accountID == expected.id else { throw CarryAccountFailure.accountMismatch }
                saved = existing
            } else {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                    throw CarryAccountFailure.storage
                }
                saved = DeletionReceipt(accountID: expected.id, appleUserID: credential.appleUserID,
                    token: bytes.map { String(format: "%02x", $0) }.joined(), accepted: false)
                // Persist before the HTTP request. A lost response is recovered by
                // the receipt, without replaying Apple's one-use code.
                try storage.store(key: "deletion-receipt", value: JSONEncoder().encode(saved))
            }
            try await lifecycle(action: "delete", credential: credential, nonce: nonce,
                                accessToken: session.accessToken, expectedStatus: "deleting", deletionReceipt: saved.token)
            saved.accepted = true
            try storage.store(key: "deletion-receipt", value: JSONEncoder().encode(saved))
        } catch { throw classify(error) }
    }

    private func receipt() throws -> DeletionReceipt? {
        guard let data = try storage.retrieve(key: "deletion-receipt") else { return nil }
        let value = try JSONDecoder().decode(DeletionReceipt.self, from: data)
        guard value.token.count == 64, value.token.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CarryAccountFailure.storage
        }
        return value
    }

    func refreshDeletion() async throws -> CarryAccountDeletionProgress {
        guard var saved = try receipt() else { return .none }
        guard let configuration else { throw CarryAccountFailure.unavailable }
        if let cachedProfile, cachedProfile.id != saved.accountID { throw CarryAccountFailure.accountMismatch }
        var request = URLRequest(url: configuration.projectURL.appendingPathComponent("functions/v1/carry-account-status"))
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(saved.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw CarryAccountFailure.service }
            // An unaccepted receipt may never have reached the server. Keep it
            // for a fresh Apple retry; do not claim this is a finished deletion.
            if http.statusCode == 401, !saved.accepted { return .none }
            guard http.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = body["status"] as? String else { throw CarryAccountFailure.service }
            if status == "deleting" {
                if !saved.accepted {
                    saved.accepted = true
                    try storage.store(key: "deletion-receipt", value: JSONEncoder().encode(saved))
                }
                return .pending
            }
            guard status == "deleted" else { throw CarryAccountFailure.service }
            if let client { try await client.signOut(scope: .local) }
            try storage.remove(key: "session")
            try storage.remove(key: "profile")
            try storage.remove(key: "apple-name-\(saved.appleUserID)")
            try storage.remove(key: "deletion-receipt") // clear last, after confirmed local cleanup
            return .completed
        } catch { throw classify(error) }
    }

    /// Bind every data request to the cache's owner, including after a token
    /// refresh. Never reuse a transport across an account switch.
    func graphTransport(for accountID: UUID) throws -> CarryGraphTransport {
        guard let configuration else { throw CarryAccountFailure.unavailable }
        return CarryGraphTransport(configuration: configuration, accessToken: { [weak self] in
            guard let self else { throw CarryAccountFailure.unavailable }
            return try await self.accessToken(for: accountID)
        }, send: send)
    }

    /// The storage transport uses the same owner-bound, refreshed Keychain
    /// session as graph requests. It never snapshots a bearer into its cache.
    func assetUploader(for accountID: UUID, directory: URL) throws -> CarryAssetUploader {
        guard let configuration else { throw CarryAccountFailure.unavailable }
        // The broker binds one TUS session to an owned reservation. Granting
        // clients direct INSERT on Storage would allow repeated TUS creations
        // against one reservation to bypass partial-upload resource accounting.
        let endpoint = configuration.projectURL.appendingPathComponent("functions/v1/carry-assets/tus")
        return try CarryAssetUploader(accountID: accountID, endpoint: endpoint,
            directory: directory, publishableKey: configuration.publishableKey, accessToken: { [weak self] in
                guard let self else { throw CarryAccountFailure.unavailable }
                return try await self.accessToken(for: accountID)
            })
    }

    private func accessToken(for accountID: UUID) async throws -> String {
        guard let client else { throw CarryAccountFailure.unavailable }
        guard cachedProfile?.id == accountID else { throw CarryAccountFailure.accountMismatch }
        do {
            let session = try await client.session
            guard session.user.id == accountID, cachedProfile?.id == accountID else {
                throw CarryAccountFailure.accountMismatch
            }
            try persistSession(session)
            return session.accessToken
        } catch { throw classify(error) }
    }

    func assetTransfer(for accountID: UUID, directory: URL) throws -> CarryAssetTransfer {
        guard let configuration else { throw CarryAccountFailure.unavailable }
        return try CarryAssetTransfer(accountID: accountID, projectURL: configuration.projectURL,
            directory: directory, publishableKey: configuration.publishableKey, accessToken: { [weak self] in
                guard let self else { throw CarryAccountFailure.unavailable }
                return try await self.accessToken(for: accountID)
            })
    }

    private func saveProfile(_ user: User, name: String? = nil) throws -> CarryAccountProfile {
        let profile = CarryAccountProfile(id: user.id,
            displayName: name ?? user.userMetadata["full_name"]?.stringValue
                ?? (cachedProfile?.id == user.id ? cachedProfile?.displayName : nil), email: user.email)
        try storage.store(key: "profile", value: JSONEncoder().encode(profile))
        return profile
    }

    private func persistSession(_ session: Session) throws {
        // The SDK logs and swallows storage write errors; our success state requires durability.
        try storage.store(key: "session", value: JSONEncoder().encode(session))
        guard let data = try storage.retrieve(key: "session"),
              let persisted = try? JSONDecoder().decode(Session.self, from: data),
              persisted.user.id == session.user.id, persisted.refreshToken == session.refreshToken else {
            throw CarryAccountFailure.storage
        }
    }

    private func verifyLifecycle(accessToken: String) async throws {
        guard let configuration else { throw CarryAccountFailure.unavailable }
        var request = URLRequest(url: configuration.projectURL.appendingPathComponent("functions/v1/carry-account"))
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw CarryAccountFailure.service }
        if http.statusCode == 401 { throw CarryAccountFailure.sessionExpired }
        guard http.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["status"] as? String == "enrolled" else { throw CarryAccountFailure.service }
    }

    private func lifecycle(action: String, credential: CarryAppleCredential, nonce: String,
                           accessToken: String, expectedStatus: String, deletionReceipt: String? = nil) async throws {
        guard let configuration else { throw CarryAccountFailure.unavailable }
        var request = URLRequest(url: configuration.projectURL.appendingPathComponent("functions/v1/carry-account"))
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = [
            "action": action, "idToken": credential.idToken,
            "authorizationCode": credential.authorizationCode, "nonce": nonce
        ]
        if let deletionReceipt { payload["deletionReceipt"] = deletionReceipt }
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw CarryAccountFailure.service }
        if http.statusCode == 401 { throw CarryAccountFailure.sessionExpired }
        guard http.statusCode == (expectedStatus == "deleting" ? 202 : 200),
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["status"] as? String == expectedStatus else { throw CarryAccountFailure.service }
    }

    private func classify(_ error: Error) -> CarryAccountFailure {
        if let known = error as? CarryAccountFailure { return known }
        if let network = error as? URLError {
            if network.code == .cancelled { return .cancelled }
            return .offline
        }
        if let auth = error as? AuthError,
           [.sessionNotFound, .sessionExpired, .refreshTokenNotFound, .refreshTokenAlreadyUsed,
            .userNotFound, .badJWT].contains(auth.errorCode) { return .sessionExpired }
        return .service
    }
}
