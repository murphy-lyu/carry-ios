import Foundation
import CryptoKit

nonisolated struct CarryAssetDownload: Sendable {
    let id: UUID
    let accountID: UUID
    let sha256: String
    let byteCount: Int
}

/// Private, verified local copies. Callers retain graph ownership separately;
/// possessing a cache URL never grants an AI connection access to its bytes.
actor CarryAssetDownloader {
    private let accountID: UUID
    private let endpoint: URL
    private let directory: URL
    private let sandboxRoot: URL
    private let publishableKey: String
    private let accessToken: @Sendable () async throws -> String
    private let session: URLSession
    private let noRedirect = CarryAccountNoRedirect()
    private var closed = false
    private var running: [UUID: (generation: UUID, task: Task<URL, Error>)] = [:]

    init(accountID: UUID, projectURL: URL, directory: URL, publishableKey: String,
         accessToken: @escaping @Sendable () async throws -> String) throws {
        var secure = projectURL.scheme == "https"
        #if DEBUG
        secure = secure || (projectURL.scheme == "http" && projectURL.host == "127.0.0.1")
        #endif
        let sandboxRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard secure, projectURL.host != nil, projectURL.user == nil, projectURL.password == nil,
              projectURL.query == nil, projectURL.fragment == nil, ["", "/"].contains(projectURL.path),
              directory.isFileURL, resolvedDirectory.path.hasPrefix(sandboxRoot.path + "/"),
              publishableKey.hasPrefix("sb_publishable_") else {
            throw CarryAssetTransferFailure.invalidConfiguration
        }
        self.accountID = accountID
        endpoint = projectURL.appendingPathComponent("functions/v1/carry-assets/download")
        self.sandboxRoot = sandboxRoot
        self.directory = resolvedDirectory.appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
        self.publishableKey = publishableKey
        self.accessToken = accessToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)
    }

    func download(_ asset: CarryAssetDownload) async throws -> URL {
        try validate(asset)
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        guard running[asset.id] == nil, running.count < 2 else { throw CarryAssetTransferFailure.busy }
        let generation = UUID()
        let task = Task { try await self.perform(asset) }
        running[asset.id] = (generation, task)
        defer { if running[asset.id]?.generation == generation { running.removeValue(forKey: asset.id) } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func cancel(_ id: UUID) { running[id]?.task.cancel() }

    /// Closing prevents late network completions from publishing files. Wait for
    /// every writer before removing this account's cache; never touch another ID.
    func close(discardCache: Bool = false) async throws {
        closed = true
        session.invalidateAndCancel()
        let tasks = running.values.map(\.task)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.result }
        if discardCache, FileManager.default.fileExists(atPath: directory.path) {
            try requireDirectory(directory)
            try FileManager.default.removeItem(at: directory)
        }
    }

    func cached(_ asset: CarryAssetDownload) throws -> URL? {
        try validate(asset)
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        let url = destination(asset)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try requireDirectory(directory)
        try verify(url, asset: asset)
        return url
    }

    private func validate(_ asset: CarryAssetDownload) throws {
        guard asset.accountID == accountID, asset.byteCount > 0, asset.byteCount <= 50 * 1024 * 1024,
              asset.sha256.count == 64,
              asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CarryAssetTransferFailure.invalidSource
        }
    }

    private func destination(_ asset: CarryAssetDownload) -> URL {
        directory.appendingPathComponent(asset.id.uuidString.lowercased() + "-" + asset.sha256 + ".asset")
    }

    private func requireDirectory(_ url: URL) throws {
        // The OS owns ancestors above our sandbox (including iOS's /var
        // alias). Inspect every ancestor INSIDE the trusted app container,
        // without treating a system-owned alias as an account-cache escape.
        var part = url.standardizedFileURL
        guard part.path.hasPrefix(sandboxRoot.path + "/") else { throw CarryAssetTransferFailure.invalidSource }
        while true {
            let values = try part.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CarryAssetTransferFailure.invalidSource
            }
            if part.path == sandboxRoot.path { return }
            part.deleteLastPathComponent()
        }
    }

    private func verify(_ url: URL, asset: CarryAssetDownload) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == asset.byteCount,
              let stream = InputStream(url: url) else { throw CarryAssetTransferFailure.invalidResponse }
        stream.open(); defer { stream.close() }
        var digest = SHA256(), total = 0, buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? CarryAssetTransferFailure.invalidResponse }
            if count == 0 { break }
            total += count
            guard total <= asset.byteCount else { throw CarryAssetTransferFailure.invalidResponse }
            digest.update(data: Data(buffer.prefix(count)))
        }
        guard total == asset.byteCount,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
            throw CarryAssetTransferFailure.invalidResponse
        }
    }

    private func perform(_ asset: CarryAssetDownload) async throws -> URL {
        try Task.checkCancellation()
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        // Fetches always reauthorize. Offline readers use cached() explicitly.
        var request = URLRequest(url: endpoint.appendingPathComponent(asset.id.uuidString.lowercased()))
        request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
        let (bytes, response) = try await session.bytes(for: request, delegate: noRedirect)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw CarryAssetTransferFailure.invalidResponse }
        if [401, 403].contains(http.statusCode) { throw CarryAssetTransferFailure.sessionExpired }
        if http.statusCode == 429 || http.statusCode >= 500 { throw CarryAssetTransferFailure.unavailable }
        guard http.statusCode == 200, response.url == request.url,
              UUID(uuidString: http.value(forHTTPHeaderField: "X-Carry-Asset-ID") ?? "") == asset.id,
              UUID(uuidString: http.value(forHTTPHeaderField: "X-Carry-Asset-Version") ?? "") != nil,
              http.value(forHTTPHeaderField: "X-Carry-Asset-SHA256") == asset.sha256,
              http.value(forHTTPHeaderField: "Content-Length") == String(asset.byteCount),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true else {
            throw CarryAssetTransferFailure.invalidResponse
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try requireDirectory(directory)
        var folder = directory, resources = URLResourceValues()
        resources.isExcludedFromBackup = true; try folder.setResourceValues(resources)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw CarryAssetTransferFailure.invalidSource
        }
        do {
            let output = try FileHandle(forWritingTo: temporary)
            do {
                var digest = SHA256(), received = 0, chunk = Data(); chunk.reserveCapacity(64 * 1024)
                for try await byte in bytes {
                    if received % 4096 == 0 { try Task.checkCancellation() }
                    guard !closed, received < asset.byteCount else { throw CarryAssetTransferFailure.invalidResponse }
                    received += 1; chunk.append(byte)
                    if chunk.count == 64 * 1024 {
                        digest.update(data: chunk); try output.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                    }
                }
                digest.update(data: chunk); try output.write(contentsOf: chunk)
                guard received == asset.byteCount,
                      digest.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
                    throw CarryAssetTransferFailure.invalidResponse
                }
                try output.synchronize(); try output.close()
            } catch { try output.close(); throw error }
            try Task.checkCancellation()
            guard !closed else { throw CarryAssetTransferFailure.sessionExpired }
            let target = destination(asset)
            if FileManager.default.fileExists(atPath: target.path) {
                let info = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw CarryAssetTransferFailure.invalidSource }
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
            return target
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
            throw error
        }
    }
}
