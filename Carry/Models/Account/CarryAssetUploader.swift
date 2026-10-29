import Foundation
import CryptoKit

nonisolated enum CarryAssetTransferFailure: Error, Equatable, Sendable {
    case invalidConfiguration, invalidSource, invalidCheckpoint, invalidResponse
    case sessionExpired, unavailable, busy, offsetMismatch
}

nonisolated struct CarryAssetUpload: Sendable {
    let id: UUID
    let accountID: UUID
    let sha256: String
    let byteCount: Int
    var contentType = "application/octet-stream"
}

nonisolated struct CarryAssetUploadProgress: Sendable {
    let assetID: UUID
    let accountID: UUID
    let uploadedBytes: Int
    let totalBytes: Int
}

private nonisolated struct CarryAssetUploadCheckpoint: Codable, Sendable {
    let assetID: UUID
    let accountID: UUID
    let sha256: String
    let byteCount: Int
    var destination: URL?
    var acknowledgedBytes: Int
}

/// Never forward a bearer or a private file body through an HTTP redirect.
/// Small TUS core adapter. Only opaque upload location/offset and immutable file
/// identity are persisted. Authentication is obtained afresh for every request;
/// no SDK custom/applied headers, bearer or refresh token can enter checkpoints.
/// Upload completion is NOT verification or migration completion: the account
/// service must verify the stored bytes before ownership may change.
actor CarryAssetUploader {
    private static let chunkBytes = 6 * 1024 * 1024 // Required by Supabase's TUS endpoint.
    private let accountID: UUID
    private let endpoint: URL
    private let directory: URL
    private let publishableKey: String
    private let accessToken: @Sendable () async throws -> String
    private let session: URLSession
    nonisolated let updates: AsyncStream<CarryAssetUploadProgress>
    private let progress: AsyncStream<CarryAssetUploadProgress>.Continuation
    private let noRedirect = CarryAccountNoRedirect()
    private var acceptsUploads = true
    private var closed = false
    private var pauseWaiters = 0
    private var discarding: Set<UUID> = []
    private var running: [UUID: (generation: UUID, task: Task<Void, Error>)] = [:]

    init(accountID: UUID, endpoint: URL, directory: URL, publishableKey: String,
         accessToken: @escaping @Sendable () async throws -> String) throws {
        var permittedScheme = endpoint.scheme == "https"
        var permittedPath = endpoint.path == "/functions/v1/carry-assets/tus"
        #if DEBUG
        // Synthetic loopback HTTP only; bundled configuration still requires HTTPS.
        permittedScheme = permittedScheme || (endpoint.scheme == "http" && endpoint.host == "127.0.0.1")
        permittedPath = permittedPath || (endpoint.host == "127.0.0.1" && endpoint.path == "/storage/v1/upload/resumable")
        #endif
        guard permittedScheme, endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              permittedPath, directory.isFileURL,
              publishableKey.hasPrefix("sb_publishable_") else { throw CarryAssetTransferFailure.invalidConfiguration }
        self.accountID = accountID; self.endpoint = endpoint
        self.directory = directory.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
        self.publishableKey = publishableKey; self.accessToken = accessToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
        (updates, progress) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    deinit { progress.finish() }

    func upload(_ asset: CarryAssetUpload, from source: URL) async throws {
        guard asset.accountID == accountID else { throw CarryAssetTransferFailure.invalidSource }
        guard acceptsUploads, !closed, !discarding.contains(asset.id),
              running[asset.id] == nil, running.count < 2 else { throw CarryAssetTransferFailure.busy }
        let generation = UUID()
        let task = Task { try await self.perform(asset, source: source) }
        running[asset.id] = (generation, task)
        defer { if running[asset.id]?.generation == generation { running.removeValue(forKey: asset.id) } }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func pause(_ assetID: UUID) { running[assetID]?.task.cancel() }

    /// Wait before account switching or erasing this account's upload cache.
    /// The source was copied into this namespace; original files are untouched.
    func pauseAll() async {
        acceptsUploads = false
        pauseWaiters += 1
        defer { pauseWaiters -= 1 }
        let active = running.values.map(\.task)
        active.forEach { $0.cancel() }
        for task in active { _ = await task.result }
    }

    func resume() throws {
        guard !closed else { throw CarryAssetTransferFailure.invalidConfiguration }
        guard pauseWaiters == 0 else { throw CarryAssetTransferFailure.busy }
        acceptsUploads = true
    }

    func close() async {
        closed = true
        await pauseAll()
        session.invalidateAndCancel()
        progress.finish()
    }

    func discard(_ assetID: UUID) async throws {
        guard !discarding.contains(assetID) else { throw CarryAssetTransferFailure.busy }
        discarding.insert(assetID)
        defer { discarding.remove(assetID) }
        if let task = running[assetID]?.task { task.cancel(); _ = await task.result }
        for url in [checkpointURL(assetID), sourceURL(assetID)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func checkpointURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func sourceURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".upload") }

    private func persist(_ value: CarryAssetUploadCheckpoint) throws {
        try Task.checkCancellation()
        try JSONEncoder().encode(value).write(to: checkpointURL(value.assetID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func prepare(_ asset: CarryAssetUpload, source: URL) throws -> CarryAssetUploadCheckpoint {
        guard asset.byteCount > 0, asset.byteCount <= 50 * 1024 * 1024,
              asset.sha256.count == 64, asset.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              source.isFileURL, asset.contentType.count <= 200,
              !asset.contentType.contains("\r"), !asset.contentType.contains("\n") else {
            throw CarryAssetTransferFailure.invalidSource
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        let storedSource = sourceURL(asset.id)
        if !FileManager.default.fileExists(atPath: storedSource.path) {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == asset.byteCount else { throw CarryAssetTransferFailure.invalidSource }
            // .copyItem is a synchronous local operation on this actor, never
            // the UI actor. Only private cache copies are subsequently removed.
            try FileManager.default.copyItem(at: source, to: storedSource)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: storedSource.path)
        }
        guard let stream = InputStream(url: storedSource) else { throw CarryAssetTransferFailure.invalidSource }
        stream.open(); defer { stream.close() }
        var digest = SHA256(), total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? CarryAssetTransferFailure.invalidSource }
            if count == 0 { break }
            total += count
            guard total <= asset.byteCount else { throw CarryAssetTransferFailure.invalidSource }
            digest.update(data: Data(buffer.prefix(count)))
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == asset.byteCount, actual == asset.sha256 else { throw CarryAssetTransferFailure.invalidSource }
        if FileManager.default.fileExists(atPath: checkpointURL(asset.id).path) {
            let metadata = try checkpointURL(asset.id).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let bytes = metadata.fileSize, bytes <= 8192 else { throw CarryAssetTransferFailure.invalidCheckpoint }
            let checkpoint = try JSONDecoder().decode(CarryAssetUploadCheckpoint.self,
                from: Data(contentsOf: checkpointURL(asset.id)))
            guard checkpoint.assetID == asset.id, checkpoint.accountID == accountID,
                  checkpoint.sha256 == asset.sha256, checkpoint.byteCount == asset.byteCount,
                  (0...asset.byteCount).contains(checkpoint.acknowledgedBytes),
                  checkpoint.destination == nil || permitted(checkpoint.destination) else {
                throw CarryAssetTransferFailure.invalidCheckpoint
            }
            return checkpoint
        }
        let checkpoint = CarryAssetUploadCheckpoint(assetID: asset.id, accountID: accountID,
            sha256: asset.sha256, byteCount: asset.byteCount, destination: nil, acknowledgedBytes: 0)
        try persist(checkpoint)
        return checkpoint
    }

    private func permitted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == endpoint.scheme && url.host == endpoint.host && url.port == endpoint.port
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            && url.path.hasPrefix(endpoint.path + "/")
    }

    private func send(_ request: URLRequest) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request, delegate: noRedirect)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw CarryAssetTransferFailure.invalidResponse }
        // TUS control/error responses have no useful large body. Refuse it
        // during reception rather than buffering an unbounded error document.
        var received = 0
        for try await _ in bytes {
            received += 1
            if received > 16 * 1024 { throw CarryAssetTransferFailure.invalidResponse }
        }
        if (200..<300).contains(http.statusCode),
           http.value(forHTTPHeaderField: "Tus-Resumable") != "1.0.0" {
            throw CarryAssetTransferFailure.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw CarryAssetTransferFailure.sessionExpired }
        if http.statusCode == 429 || http.statusCode >= 500 { throw CarryAssetTransferFailure.unavailable }
        return http
    }

    private func headerOffset(_ response: HTTPURLResponse, size: Int) throws -> Int {
        guard let raw = response.value(forHTTPHeaderField: "Upload-Offset"),
              !raw.isEmpty, raw.allSatisfy(\.isNumber), let offset = Int(raw),
              (0...size).contains(offset) else { throw CarryAssetTransferFailure.invalidResponse }
        return offset
    }

    private func report(_ asset: CarryAssetUpload, uploaded: Int) {
        progress.yield(.init(assetID: asset.id, accountID: accountID,
                             uploadedBytes: uploaded, totalBytes: asset.byteCount))
    }

    private func perform(_ asset: CarryAssetUpload, source: URL) async throws {
        var checkpoint = try prepare(asset, source: source)
        if let destination = checkpoint.destination {
            var head = URLRequest(url: destination); head.httpMethod = "HEAD"
            let response = try await send(head)
            if [404, 410].contains(response.statusCode) {
                checkpoint.destination = nil; checkpoint.acknowledgedBytes = 0
                try persist(checkpoint)
            } else {
                guard [200, 204].contains(response.statusCode),
                      response.value(forHTTPHeaderField: "Upload-Length").flatMap(Int.init) == asset.byteCount else {
                    throw CarryAssetTransferFailure.invalidResponse
                }
                checkpoint.acknowledgedBytes = try headerOffset(response, size: asset.byteCount)
                try persist(checkpoint)
            }
        }
        if checkpoint.destination == nil {
            var create = URLRequest(url: endpoint); create.httpMethod = "POST"
            create.setValue(String(asset.byteCount), forHTTPHeaderField: "Upload-Length")
            let object = "\(accountID.uuidString.lowercased())/\(asset.id.uuidString.lowercased())/\(asset.sha256)"
            let metadata = ["bucketName": "carry-account-assets", "objectName": object,
                            "contentType": asset.contentType, "cacheControl": "0"]
            create.setValue(metadata.keys.sorted().map { "\($0) \(Data((metadata[$0] ?? "").utf8).base64EncodedString())" }
                .joined(separator: ","), forHTTPHeaderField: "Upload-Metadata")
            let response = try await send(create)
            guard response.statusCode == 201, let location = response.value(forHTTPHeaderField: "Location"),
                  let destination = URL(string: location, relativeTo: endpoint)?.absoluteURL,
                  permitted(destination) else { throw CarryAssetTransferFailure.invalidResponse }
            checkpoint.destination = destination
            checkpoint.acknowledgedBytes = 0
            try persist(checkpoint)
        }
        guard let destination = checkpoint.destination else { throw CarryAssetTransferFailure.invalidCheckpoint }
        report(asset, uploaded: checkpoint.acknowledgedBytes)
        guard let stream = InputStream(url: sourceURL(asset.id)) else { throw CarryAssetTransferFailure.invalidSource }
        stream.open(); defer { stream.close() }
        // Seek forward without loading the prefix or retaining the whole file.
        var skip = checkpoint.acknowledgedBytes
        var skipping = [UInt8](repeating: 0, count: 64 * 1024)
        while skip > 0 {
            try Task.checkCancellation()
            let count = stream.read(&skipping, maxLength: min(skip, skipping.count))
            guard count > 0 else { throw stream.streamError ?? CarryAssetTransferFailure.invalidSource }
            skip -= count
        }
        while checkpoint.acknowledgedBytes < asset.byteCount {
            try Task.checkCancellation()
            let count = min(Self.chunkBytes, asset.byteCount - checkpoint.acknowledgedBytes)
            var chunk = [UInt8](repeating: 0, count: count), filled = 0
            while filled < count {
                let read = chunk.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return -1 }
                    return stream.read(base.advanced(by: filled), maxLength: count - filled)
                }
                guard read > 0 else { throw stream.streamError ?? CarryAssetTransferFailure.invalidSource }
                filled += read
            }
            var patch = URLRequest(url: destination); patch.httpMethod = "PATCH"
            patch.setValue(String(checkpoint.acknowledgedBytes), forHTTPHeaderField: "Upload-Offset")
            patch.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            patch.httpBody = Data(chunk)
            let response = try await send(patch)
            if response.statusCode == 409 { throw CarryAssetTransferFailure.offsetMismatch }
            guard response.statusCode == 204,
                  try headerOffset(response, size: asset.byteCount) == checkpoint.acknowledgedBytes + count else {
                throw CarryAssetTransferFailure.invalidResponse
            }
            checkpoint.acknowledgedBytes += count
            try persist(checkpoint)
            report(asset, uploaded: checkpoint.acknowledgedBytes)
        }
        try Task.checkCancellation()
    }
}
