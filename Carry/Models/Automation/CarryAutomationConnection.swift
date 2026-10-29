import Foundation
import Combine
import CloudKit
import Security
import UIKit
import CryptoKit

private struct AutomationHTTPError: Error { let status: Int }

extension Notification.Name {
    static let carryAutomationInvalidated = Notification.Name("carryAutomationInvalidated")
}

struct AutomationPendingPair: Codable {
    let code: String
    let shareLibrary: Bool
}

struct AutomationCredentials: Codable {
    let connectionId: UUID
    let deviceToken: String
    let clientName: String
    var tripIds: [UUID]
    let scope: String
    var cloudAccount: String
    var revocationPending = false
    var pendingPair: AutomationPendingPair?
}

struct AutomationOperationSummary: Decodable, Identifiable {
    let requestId: UUID
    let name: String
    let status: String
    let createdAt: Double
    let targetName: String?
    var id: UUID { requestId }
    var statusKey: String {
        switch status {
        case "queued": return "automation.status.queued"
        case "executing": return "automation.status.executing"
        case "applied": return "automation.status.applied"
        case "cancelled": return "automation.status.cancelled"
        case "expired": return "automation.status.expired"
        default: return "automation.status.failed"
        }
    }
}

enum AutomationKeychain {
    private static var cachedRevisionKey: SymmetricKey?
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.nevestudio.carry.automation",
         kSecAttrAccount as String: "device-connection"]
    }
    static func load() throws -> AutomationCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AutomationError.saveFailed }
        return try JSONDecoder().decode(AutomationCredentials.self, from: data)
    }
    static func save(_ credentials: AutomationCredentials) throws {
        let attributes: [String: Any] = [kSecValueData as String: try AutomationCodec.encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw AutomationError.saveFailed }
        } else if status != errSecSuccess { throw AutomationError.saveFailed }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AutomationError.saveFailed }
    }
    static func revisionKey() throws -> SymmetricKey {
        if let cachedRevisionKey { return cachedRevisionKey }
        var keyQuery = query
        keyQuery[kSecAttrAccount as String] = "revision-hmac"
        var read = keyQuery
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        let key: SymmetricKey
        if status == errSecItemNotFound {
            key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            let attributes = keyQuery.merging([kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new }
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw AutomationError.saveFailed }
        } else {
            guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw AutomationError.saveFailed }
            key = SymmetricKey(data: data)
        }
        cachedRevisionKey = key
        return key
    }
}

@MainActor
final class CarryAutomationConnection: ObservableObject {
    @Published private(set) var credentials: AutomationCredentials?
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var lastSynced: Date?
    @Published private(set) var operations: [AutomationOperationSummary] = []
    private var loop: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private weak var store: TripStore?
    private weak var router: NavigationRouter?
    private var identityVerified = false
    private var storeVersion = 0
    private var generation = UUID()
    private let sendData: (URLRequest) async throws -> (Data, URLResponse)

    // Public endpoint, not a credential. No device data is sent before explicit pairing consent.
    static let serviceURL = URL(string: "https://connect.nevestudio.app")

    /// Synchronous durable pause before restore/erase/reset. A notification alone
    /// can be lost if the process exits before its async subscriber runs.
    static func invalidatePersistedConnection() throws {
        guard var credential = try AutomationKeychain.load() else { return }
        credential.revocationPending = true
        try AutomationKeychain.save(credential)
    }

    init(sendData: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.sendData = sendData
        do { credentials = try AutomationKeychain.load() }
        catch { errorKey = "automation.error.storage" }
        NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor in self?.accountChanged() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .carryAutomationInvalidated).receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor in await self?.disconnect() }
        }.store(in: &subscriptions)
    }

    func start(store: TripStore, router: NavigationRouter? = nil) {
        self.store = store
        if let router { self.router = router }
        guard loop == nil, credentials != nil, store.automationReady, CarryApp.hasPersistentStore,
              UIApplication.shared.applicationState == .active else { return }
        let currentGeneration = UUID()
        generation = currentGeneration
        storeVersion = store.automationInvalidationVersion
        loop = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == currentGeneration { self.loop = nil } }
            do {
                while !Task.isCancelled {
                    do {
                        if self.credentials?.revocationPending == true {
                            // Do not call disconnect() from the loop: it cancels this task
                            // before URLSession can send the pending revocation.
                            await self.finishRevocation()
                            if self.credentials == nil { return }
                        } else {
                            if !self.identityVerified {
                                guard let credential = self.credentials, try await self.currentCloudAccount() == credential.cloudAccount else {
                                    self.accountChanged(); return
                                }
                                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                                self.identityVerified = true
                            }
                            await self.synchronize()
                        }
                    } catch { self.errorKey = "automation.error.network" }
                    try await Task.sleep(for: .seconds(5))
                }
            } catch is CancellationError {
                // Normal lifecycle cancellation: the foreground loop does not run in the background.
            } catch { self.errorKey = "automation.error.network" }
        }
    }

    func stop() {
        generation = UUID()
        loop?.cancel()
        loop = nil
        identityVerified = false
    }

    private func accountChanged() {
        stop()
        // Persist the pause; re-entering the old iCloud account does not silently restore access.
        guard credentials != nil else { return }
        credentials?.revocationPending = true
        if let credentials {
            do { try AutomationKeychain.save(credentials) }
            catch { errorKey = "automation.error.storage" }
        }
        Task { await disconnect() }
        errorKey = "automation.error.account"
    }

    struct PairPreview: Decodable { let clientName: String; let scope: String; let redirectHost: String? }
    func preview(code: String) async throws -> PairPreview {
        try await request("/device/pair", body: ["code": .string(code), "preview": .bool(true)], token: nil)
    }

    func connect(code: String, tripIds: Set<UUID>, shareLibrary: Bool = false, expectedScope: String, clientName: String = "Codex", store: TripStore) async {
        guard !isBusy, credentials == nil, store.automationReady, CarryApp.hasPersistentStore else { return }
        isBusy = true; errorKey = nil
        defer { isBusy = false }
        let expectedGeneration = generation
        let expectedStoreVersion = store.automationInvalidationVersion
        do {
            let account = try await currentCloudAccount()
            guard generation == expectedGeneration, !Task.isCancelled, credentials == nil,
                  UIApplication.shared.applicationState == .active, store.automationReady,
                  store.automationInvalidationVersion == expectedStoreVersion else { throw CancellationError() }
            let approvedScopes = AutomationAuthorization.scopeSet(expectedScope).intersection(AutomationAuthorization.scopes).filter { shareLibrary || !$0.hasPrefix("library:") }
            let deviceToken = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
            let credential = AutomationCredentials(connectionId: UUID(), deviceToken: deviceToken, clientName: clientName,
                tripIds: Array(tripIds), scope: approvedScopes.sorted().joined(separator: " "), cloudAccount: account,
                pendingPair: AutomationPendingPair(code: code, shareLibrary: shareLibrary))
            // The recoverable secret must exist durably before the server can consume the code.
            try AutomationKeychain.save(credential)
            credentials = credential
            try await finishPairing()
        } catch { errorKey = "automation.error.connection" }
        start(store: store)
    }

    func finishPairing() async throws {
        guard let credential = credentials, let pending = credential.pendingPair, !credential.revocationPending else { return }
        let expectedGeneration = generation
        struct Paired: Decodable {
            let connectionId: UUID; let deviceToken: String; let clientName: String; let tripIds: [UUID]; let scope: String
        }
        let body: [String: AutomationValue] = ["code": .string(pending.code), "connectionId": .string(credential.connectionId.uuidString),
            "deviceToken": .string(credential.deviceToken), "tripIds": .array(credential.tripIds.map { .string($0.uuidString) }), "shareLibrary": .bool(pending.shareLibrary)]
        let paired: Paired
        do { paired = try await request("/device/pair", body: body, token: nil) }
        catch let error as AutomationHTTPError where error.status == 403 || error.status == 404 {
            if credentials?.connectionId == credential.connectionId {
                credentials?.revocationPending = true
                if let credentials { try AutomationKeychain.save(credentials) }
            }
            throw error
        }
        guard generation == expectedGeneration, !Task.isCancelled, credentials?.connectionId == credential.connectionId,
              credentials?.revocationPending == false else { throw CancellationError() }
        guard paired.connectionId == credential.connectionId, paired.deviceToken == credential.deviceToken,
              Set(paired.tripIds) == Set(credential.tripIds), AutomationAuthorization.scopeSet(paired.scope).isSubset(of: AutomationAuthorization.scopeSet(credential.scope)) else {
            credentials?.revocationPending = true
            if let credentials { try AutomationKeychain.save(credentials) }
            throw AutomationError.unauthorized
        }
        let completed = AutomationCredentials(connectionId: paired.connectionId, deviceToken: paired.deviceToken, clientName: paired.clientName,
            tripIds: paired.tripIds, scope: paired.scope, cloudAccount: credential.cloudAccount)
        try AutomationKeychain.save(completed)
        credentials = completed
        errorKey = nil
    }

    func disconnect() async {
        stop()
        guard var credential = credentials else { return }
        credential.revocationPending = true
        credentials = credential
        do {
            try AutomationKeychain.save(credential)
        } catch { errorKey = "automation.error.storage"; return }
        await finishRevocation()
        if credentials?.revocationPending == true, let store { start(store: store) }
    }

    private func finishRevocation() async {
        guard let credential = credentials, credential.revocationPending else { return }
        do {
            if let pending = credential.pendingPair {
                let _: EmptyResponse = try await request("/device/cancel-pair", body: ["code": .string(pending.code),
                    "connectionId": .string(credential.connectionId.uuidString), "deviceToken": .string(credential.deviceToken)], token: nil)
            } else {
                let _: EmptyResponse = try await request("/device/revoke", body: [:], token: credential.deviceToken)
            }
            guard credentials?.connectionId == credential.connectionId, credentials?.revocationPending == true else { return }
            try AutomationKeychain.clear()
            credentials = nil; lastSynced = nil; errorKey = nil; operations = []
        } catch let error as AutomationHTTPError where error.status == 401 {
            // The relay rejects both client and device credentials once a connection is revoked/expired.
            guard credentials?.connectionId == credential.connectionId, credentials?.revocationPending == true else { return }
            do { try AutomationKeychain.clear(); credentials = nil; lastSynced = nil; errorKey = nil; operations = [] }
            catch { errorKey = "automation.error.storage" }
        } catch {
            // Keep a revocation-only credential so going offline cannot silently re-enable access.
            if credentials?.connectionId == credential.connectionId { errorKey = "automation.error.revoke" }
        }
    }

    func synchronize() async {
        guard !isBusy, identityVerified, UIApplication.shared.applicationState == .active,
              let credential = credentials, !credential.revocationPending,
              let store, store.automationReady else { return }
        guard storeVersion == store.automationInvalidationVersion else { Task { await disconnect() }; return }
        isBusy = true
        defer { isBusy = false }
        do {
            if credential.pendingPair != nil { try await finishPairing(); return }
            try Task.checkCancellation()
            // The server may have accepted a previous receipt before the response was lost.
            // Treat its scope as an upper bound; only local approval/creation can add IDs.
            struct Next: Decodable { let operation: AutomationOperation?; let tripIds: [UUID]? }
            let next: Next = try await request("/device/next", body: [:], token: credential.deviceToken)
            try Task.checkCancellation()
            guard credentials?.connectionId == credential.connectionId, credentials?.revocationPending == false,
                  storeVersion == store.automationInvalidationVersion, identityVerified else { return }
            if let tripIds = next.tripIds { try updateScope(tripIds) }
            if let operation = next.operation {
                let receipt: AutomationReceipt
                do {
                    try AutomationAuthorization.validate(operation: operation.name, scope: credential.scope)
                    if CarryAutomationQueries.names.contains(operation.name) {
                        receipt = try await store.executeAutomationQuery(operation, connectionId: credential.connectionId, allowedTripIds: Set(credentials?.tripIds ?? []))
                    } else {
                        receipt = try store.executeAutomation(operation, connectionId: credential.connectionId,
                            allowedTripIds: Set(credentials?.tripIds ?? []), allowLibrary: credential.scope.contains("library:write"))
                    }
                } catch is CancellationError {
                    return
                } catch AutomationError.busy {
                    return // Retry the same executing request after local autosave completes.
                } catch {
                    let code = (error as? AutomationError) ?? .saveFailed
                    let failure = AutomationReceipt(requestId: operation.requestId, payloadHash: operation.payloadHash,
                        status: code == .conflict ? "conflict" : code == .expired ? "expired" : "failed", error: code.rawValue)
                    receipt = try store.recordAutomationReceipt(operation, receipt: failure)
                }
                try Task.checkCancellation()
                guard credentials?.connectionId == credential.connectionId, credentials?.revocationPending == false, identityVerified else { return }
                if receipt.status == "applied", ["create_trip", "duplicate_trip"].contains(operation.name), let created = receipt.entityId {
                    // Only a locally persisted creation receipt can expand the user's trip grant.
                    try updateScope(credentials?.tripIds ?? [], locallyCreated: created)
                }
                struct Acknowledged: Decodable { let tripIds: [UUID] }
                let result: Acknowledged = try await request("/device/receipt", data: AutomationCodec.encode(receipt), token: credential.deviceToken)
                try updateScope(result.tripIds)
                if operation.name == "open_trip", receipt.status == "applied", !Task.isCancelled,
                   identityVerified, credentials?.revocationPending == false, let tripId = operation.arguments.tripId {
                    let packing = operation.arguments.data?["face"] == .string("packing")
                    router?.pendingTrip = TripDeepLink(tripId: tripId, face: packing ? .packing : .itinerary)
                }
            }
            try Task.checkCancellation()
            guard credentials?.connectionId == credential.connectionId, credentials?.revocationPending == false,
                  storeVersion == store.automationInvalidationVersion, identityVerified else { return }
            struct Snapshot: Encodable { let trips: [AutomationTripSnapshot]; let library: AutomationLibrarySnapshot? }
            let snapshot = Snapshot(trips: credential.scope.contains("trips:read") ? try store.automationSnapshots(allowedTripIds: Set(credentials?.tripIds ?? [])) : [],
                library: credential.scope.contains("library:read") ? try store.automationLibrarySnapshot() : nil)
            let _: EmptyResponse = try await request("/device/snapshot", data: AutomationCodec.encode(snapshot), token: credential.deviceToken)
            struct Summaries: Decodable { let operations: [AutomationOperationSummary] }
            let summaries: Summaries = try await request("/device/operations", body: [:], token: credential.deviceToken)
            guard credentials?.connectionId == credential.connectionId, credentials?.revocationPending == false else { return }
            operations = summaries.operations
            lastSynced = Date(); errorKey = nil
        } catch is CancellationError {
            // Data already saved remains saved; its journal drives receipt recovery next time.
        } catch let error as AutomationHTTPError where error.status == 401 {
            stop()
            do { try AutomationKeychain.clear(); credentials = nil; operations = []; lastSynced = nil; errorKey = "automation.error.connection" }
            catch { credentials?.revocationPending = true; errorKey = "automation.error.storage" }
        } catch { errorKey = "automation.error.network" }
    }

    func cancelOperation(_ id: UUID) async {
        guard let credential = credentials, !credential.revocationPending else { return }
        do {
            let _: EmptyResponse = try await request("/device/cancel", body: ["requestId": .string(id.uuidString)], token: credential.deviceToken)
            operations.removeAll { $0.requestId == id }
        } catch { errorKey = "automation.error.cancel" }
    }

    private func updateScope(_ ids: [UUID], locallyCreated: UUID? = nil) throws {
        guard var credential = credentials, !credential.revocationPending else { return }
        let approved = AutomationAuthorization.approvedTripIds(serverIds: ids, approved: credential.tripIds, locallyCreated: locallyCreated)
        if Set(credential.tripIds) != Set(approved) {
            credential.tripIds = approved
            try AutomationKeychain.save(credential)
            credentials = credential
        }
    }

    private func currentCloudAccount() async throws -> String {
        let container = CKContainer(identifier: "iCloud.app.nevestudio.carry")
        let status = try await container.accountStatus()
        if status == .noAccount { return "local-only" }
        guard status == .available else { throw AutomationError.cloudAccountChanged }
        let record = try await container.userRecordID()
        return try AutomationCodec.digest(record.recordName)
    }

    private struct EmptyResponse: Decodable {}
    private func request<T: Decodable>(_ path: String, body: [String: AutomationValue], token: String?) async throws -> T {
        try await request(path, data: AutomationCodec.encode(body), token: token)
    }
    private func request<T: Decodable>(_ path: String, data: Data, token: String?) async throws -> T {
        guard data.count <= 2 * 1024 * 1024 else { throw AutomationError.invalidInput }
        guard let base = Self.serviceURL else { throw AutomationError.invalidInput }
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = data
        let (responseData, response) = try await sendData(request)
        guard let http = response as? HTTPURLResponse else { throw AutomationError.network }
        guard (200..<300).contains(http.statusCode) else { throw AutomationHTTPError(status: http.statusCode) }
        return try JSONDecoder().decode(T.self, from: responseData)
    }
}
