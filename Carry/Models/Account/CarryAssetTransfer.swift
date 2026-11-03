import Foundation

nonisolated struct CarryAssetDescriptor: Codable, Sendable {
    let id: UUID
    let entityID: UUID
    let entityKind: String
    let slot: String
    let sha256: String
    let byteCount: Int
    var contentType = "application/octet-stream"
}

/// Native reserve → resumable upload → server byte verification. A successful
/// return confirms the file only; it never changes a trip's storage ownership.
actor CarryAssetTransfer {
    private let accountID: UUID
    private let uploader: CarryAssetUploader
    private let control: CarryAssetControl
    private var active: Set<UUID> = []
    private var closed = false
    nonisolated let updates: AsyncStream<CarryAssetUploadProgress>

    init(accountID: UUID, projectURL: URL, directory: URL, publishableKey: String,
         accessToken: @escaping @Sendable () async throws -> String) throws {
        self.accountID = accountID
        uploader = try CarryAssetUploader(accountID: accountID,
            endpoint: projectURL.appendingPathComponent("functions/v1/carry-assets/tus"),
            directory: directory, publishableKey: publishableKey, accessToken: accessToken)
        control = try CarryAssetControl(projectURL: projectURL, publishableKey: publishableKey, accessToken: accessToken)
        updates = uploader.updates
    }

    func transfer(_ descriptor: CarryAssetDescriptor, from source: URL) async throws {
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        guard !active.contains(descriptor.id), active.count < 2 else { throw CarryAssetTransferFailure.busy }
        active.insert(descriptor.id)
        defer { active.remove(descriptor.id) }
        let uploaded = try await control.reserve(descriptor)
        try Task.checkCancellation()
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        if !uploaded {
            try await uploader.upload(.init(id: descriptor.id, accountID: accountID,
                sha256: descriptor.sha256, byteCount: descriptor.byteCount, contentType: descriptor.contentType), from: source)
        }
        try Task.checkCancellation()
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        // Even a previously verified reservation is checked against the current
        // storage version. A lost source or changed object cannot be skipped.
        try await control.verify(descriptor.id)
        try Task.checkCancellation()
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
    }

    func close() async {
        closed = true
        await control.close()
        await uploader.close()
    }

    func discard(_ id: UUID) async throws {
        guard !active.contains(id) else { throw CarryAssetTransferFailure.busy }
        try await uploader.discard(id)
    }
}

private actor CarryAssetControl {
    private nonisolated struct Receipt: Decodable, Sendable { let id: UUID; let status: String }
    private nonisolated struct VerifyBody: Encodable, Sendable { let id: UUID }
    private let endpoint: URL
    private let publishableKey: String
    private let accessToken: @Sendable () async throws -> String
    private let session: URLSession
    private let noRedirect = CarryAccountNoRedirect()
    private var closed = false

    init(projectURL: URL, publishableKey: String, accessToken: @escaping @Sendable () async throws -> String) throws {
        var secure = projectURL.scheme == "https"
        #if DEBUG
        secure = secure || (projectURL.scheme == "http" && projectURL.host == "127.0.0.1")
        #endif
        guard secure, projectURL.host != nil, projectURL.user == nil, projectURL.password == nil,
              projectURL.query == nil, projectURL.fragment == nil, ["", "/"].contains(projectURL.path),
              publishableKey.hasPrefix("sb_publishable_") else { throw CarryAssetTransferFailure.invalidConfiguration }
        endpoint = projectURL.appendingPathComponent("functions/v1/carry-assets")
        self.publishableKey = publishableKey; self.accessToken = accessToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    func close() { closed = true; session.invalidateAndCancel() }

    func reserve(_ asset: CarryAssetDescriptor) async throws -> Bool {
        let receipt = try await request("reserve", body: JSONEncoder().encode(asset))
        guard receipt.id == asset.id, ["pending", "verified"].contains(receipt.status) else {
            throw CarryAssetTransferFailure.invalidResponse
        }
        return receipt.status == "verified"
    }

    func verify(_ id: UUID) async throws {
        let receipt = try await request("verify", body: JSONEncoder().encode(VerifyBody(id: id)))
        guard receipt.id == id, receipt.status == "verified" else { throw CarryAssetTransferFailure.invalidResponse }
    }

    private func request(_ action: String, body: Data) async throws -> Receipt {
        try Task.checkCancellation()
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        guard body.count <= 8192 else { throw CarryAssetTransferFailure.invalidSource }
        var request = URLRequest(url: endpoint.appendingPathComponent(action))
        request.httpMethod = "POST"; request.httpBody = body
        request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        let (bytes, response) = try await session.bytes(for: request, delegate: noRedirect)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= 16 * 1024 else {
            throw CarryAssetTransferFailure.invalidResponse
        }
        var data = Data(); data.reserveCapacity(1024)
        for try await byte in bytes {
            guard data.count < 16 * 1024 else { throw CarryAssetTransferFailure.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        if [401, 403].contains(http.statusCode) { throw CarryAssetTransferFailure.sessionExpired }
        if http.statusCode == 429 || http.statusCode >= 500 { throw CarryAssetTransferFailure.unavailable }
        guard http.statusCode == 200 else { throw CarryAssetTransferFailure.invalidResponse }
        do { return try JSONDecoder().decode(Receipt.self, from: data) }
        catch { throw CarryAssetTransferFailure.invalidResponse }
    }
}
