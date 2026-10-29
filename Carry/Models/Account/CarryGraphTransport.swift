import Foundation
import SwiftData

enum CarryGraphTransportFailure: Error {
    case sessionExpired, conflict(Data), rejected(String), unavailable, invalidResponse
}

@MainActor
protocol CarryGraphTransporting {
    func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt
    func pull(cursor: Int) async throws -> CarryGraphPage
}

@MainActor
protocol CarryGraphStreamingTransporting: CarryGraphTransporting {
    func applyStreaming(_ command: CarryGraphCommand, progress: CarryGraphReceiptProgress?,
                        receive: @MainActor (CarryGraphReceiptSummary, CarryGraphReceiptPage, Int) async throws -> Void) async throws
}

/// One account's HTTP adapter. A refreshed bearer comes from AccountService,
/// while account ownership is derived and verified again on the server.
@MainActor
final class CarryGraphTransport: CarryGraphStreamingTransporting {
    private nonisolated static let responseLimit = 16 * 1024 * 1024
    private nonisolated static let httpSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()
    private nonisolated struct Body: Encodable, Sendable {
        let action: String
        var command: CarryGraphCommand?
        var cursor: Int?
        var limit: Int?
        var receiptMode: String?
        var requestID: UUID?
        var chunkIndex: Int?
        var totalChunks: Int?
        var mutationCount: Int?
        var mutations: [CarryGraphMutation]?
        var offset: Int?
    }
    private nonisolated struct Failure: Decodable, Sendable { let error: String }
    private nonisolated struct Staged: Decodable, Sendable {
        let status: String
        let requestID: UUID
        let chunkIndex: Int
    }
    private let endpoint: URL
    private let publishableKey: String
    private let accessToken: () async throws -> String
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(configuration: CarryAccountConfiguration,
         accessToken: @escaping () async throws -> String,
         send: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await CarryGraphTransport.boundedResponse($0)
         }) {
        endpoint = configuration.projectURL.appendingPathComponent("functions/v1/carry-data")
        publishableKey = configuration.publishableKey
        self.accessToken = accessToken
        self.send = send
    }

    // Reject while receiving, not after data(for:) has already buffered an
    // unbounded response. Byte processing stays off the UI actor.
    @concurrent nonisolated static func boundedResponse(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await httpSession.bytes(for: request, delegate: CarryAccountNoRedirect())
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= responseLimit else {
            throw CarryGraphTransportFailure.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), responseLimit))
        var buffer: [UInt8] = []
        buffer.reserveCapacity(16 * 1024)
        var received = 0
        for try await byte in bytes {
            guard received < responseLimit else { throw CarryGraphTransportFailure.invalidResponse }
            received += 1
            buffer.append(byte)
            if buffer.count == 16 * 1024 {
                try Task.checkCancellation()
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: buffer)
        return (data, response)
    }

    func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
        // Direct callers have a bounded compatibility result. The app's sync
        // engine uses applyStreaming and commits each receipt page durably.
        var changes: [CarryGraphChange] = []
        var totalBytes = 0
        var completed: CarryGraphReceiptSummary?
        try await applyStreaming(command, progress: nil) { summary, page, byteCount in
            guard byteCount <= 64 * 1024 * 1024 - totalBytes else { throw CarryGraphTransportFailure.invalidResponse }
            totalBytes += byteCount
            changes.append(contentsOf: page.changes)
            completed = summary
        }
        guard let completed else { throw CarryGraphTransportFailure.invalidResponse }
        return CarryGraphReceipt(status: completed.status, requestID: completed.requestID,
            changes: changes, cursor: completed.cursor)
    }

    func applyStreaming(_ command: CarryGraphCommand, progress: CarryGraphReceiptProgress?,
                        receive: @MainActor (CarryGraphReceiptSummary, CarryGraphReceiptPage, Int) async throws -> Void) async throws {
        guard (1...20000).contains(command.mutations.count) else { throw CarryGraphTransportFailure.rejected("invalid_command_size") }
        let direct = Body(action: "apply", command: command, receiptMode: "paged")
        let encoded = try await Self.encode(direct)
        let summary: CarryGraphReceiptSummary
        if command.mutations.count <= 500, encoded.count <= 1_800_000 {
            summary = try await request(direct, encoded: encoded)
        } else {
            let chunks = try await Self.stageChunks(command)
            for (index, chunk) in chunks.enumerated() {
                let staged: Staged = try await request(Body(action: "stage", requestID: command.requestID,
                    chunkIndex: index, totalChunks: chunks.count, mutationCount: command.mutations.count, mutations: chunk))
                guard staged.status == "staged", staged.requestID == command.requestID, staged.chunkIndex == index else {
                    throw CarryGraphTransportFailure.invalidResponse
                }
            }
            summary = try await request(Body(action: "commitStage", requestID: command.requestID))
        }
        guard summary.status == "saved_to_account", summary.requestID == command.requestID,
              summary.changeCount > 0, summary.changeCount <= 1_000_000, summary.cursor >= summary.changeCount else {
            throw CarryGraphTransportFailure.invalidResponse
        }
        var offset = 0
        if let progress {
            guard progress.requestID == summary.requestID, progress.cursor == summary.cursor,
                  progress.changeCount == summary.changeCount, progress.nextOffset >= 0,
                  progress.nextOffset < summary.changeCount else { throw CarryGraphTransportFailure.invalidResponse }
            offset = progress.nextOffset
        }
        while offset < summary.changeCount {
            let bytes = try await sendRequest(Body(action: "receiptPage", limit: 500, requestID: command.requestID, offset: offset))
            let page = try await Self.decode(CarryGraphReceiptPage.self, from: bytes)
            guard page.requestID == command.requestID, page.cursor == summary.cursor,
                  page.changeCount == summary.changeCount, !page.changes.isEmpty, page.changes.count <= 500,
                  page.nextOffset == offset + page.changes.count, page.nextOffset <= summary.changeCount,
                  page.hasMore == (page.nextOffset < summary.changeCount) else { throw CarryGraphTransportFailure.invalidResponse }
            try await receive(summary, page, bytes.count)
            offset = page.nextOffset
        }
    }

    @concurrent nonisolated private static func stageChunks(_ command: CarryGraphCommand) async throws -> [[CarryGraphMutation]] {
        var chunks: [[CarryGraphMutation]] = []
        var current: [CarryGraphMutation] = []
        var size = 2, total = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for mutation in command.mutations {
            try Task.checkCancellation()
            let count = try encoder.encode(mutation).count + 1
            guard count <= 1_800_000 else { throw CarryGraphTransportFailure.rejected("invalid_command_size") }
            if !current.isEmpty, current.count == 500 || size + count > 1_400_000 {
                chunks.append(current); current = []; size = 2
            }
            current.append(mutation); size += count; total += count
            guard total <= 12 * 1024 * 1024 else { throw CarryGraphTransportFailure.rejected("invalid_command_size") }
        }
        if !current.isEmpty { chunks.append(current) }
        guard chunks.count <= 40 else { throw CarryGraphTransportFailure.rejected("invalid_command_size") }
        return chunks
    }

    @concurrent nonisolated private static func encode<Value: Encodable & Sendable>(_ value: Value) async throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    @concurrent nonisolated private static func decode<Value: Decodable & Sendable>(_ type: Value.Type, from bytes: Data) async throws -> Value {
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw CarryGraphTransportFailure.invalidResponse }
    }

    func pull(cursor: Int) async throws -> CarryGraphPage {
        try await request(Body(action: "pull", cursor: cursor, limit: 100))
    }

    private func request<Result: Decodable & Sendable>(_ body: Body, encoded: Data? = nil) async throws -> Result {
        let bytes = try await sendRequest(body, encoded: encoded)
        return try await Self.decode(Result.self, from: bytes)
    }

    private func sendRequest(_ body: Body, encoded: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = body.action == "commitStage" ? 60 : 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        if let encoded { request.httpBody = encoded }
        else { request.httpBody = try await Self.encode(body) }
        let (data, response) = try await send(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= Self.responseLimit else {
            throw CarryGraphTransportFailure.invalidResponse
        }
        if http.statusCode == 401 { throw CarryGraphTransportFailure.sessionExpired }
        if http.statusCode == 409 { throw CarryGraphTransportFailure.conflict(data) }
        if http.statusCode == 422 {
            let failure = try await Self.decode(Failure.self, from: data)
            if ["stage_unavailable", "stage_incomplete", "receipt_not_found", "invalid_receipt_page"].contains(failure.error) {
                throw CarryGraphTransportFailure.unavailable
            }
            throw CarryGraphTransportFailure.rejected(failure.error)
        }
        guard http.statusCode == 200 else { throw CarryGraphTransportFailure.unavailable }
        return data
    }
}

/// Serial pump; app foreground/reconnect may request another pass, but cannot
/// start two concurrent uploads of mutable outbox state. Network timeouts retain
/// immutable flights; rejected input/conflicts require explicit resolution.
@MainActor
final class CarryAccountSyncEngine {
    private let replica: CarryAccountReplica
    private let transport: any CarryGraphTransporting
    private let project: ([CarryGraphEntity], ModelContext) throws -> Void
    private var running = false

    /// The projection applies a delta of changed local snapshots in one save.
    init(replica: CarryAccountReplica, transport: any CarryGraphTransporting,
         project: @escaping ([CarryGraphEntity], ModelContext) throws -> Void = { _, _ in }) {
        self.replica = replica
        self.transport = transport
        self.project = project
    }

    /// Work is bounded per foreground pass. `false` requests a later continuation;
    /// it must never be shown as "fully synced". Retry scheduling belongs to the
    /// app lifecycle and is not a tight timer inside this engine.
    func synchronize() async throws -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        do {
            for _ in 0..<10 {
                guard let command = try replica.nextCommand() else { break }
                if let streaming = transport as? any CarryGraphStreamingTransporting {
                    let progress = try replica.receiptProgress(for: command.requestID)
                    try await streaming.applyStreaming(command, progress: progress) { summary, page, _ in
                        do { try self.replica.accept(page, summary: summary, project: self.project) }
                        catch CarryReplicaFailure.missingBaseline {
                            try await self.fillBaselines()
                            try self.replica.accept(page, summary: summary, project: self.project)
                        }
                    }
                } else {
                    let receipt = try await transport.apply(command)
                    do { try replica.accept(receipt, project: project) }
                    catch CarryReplicaFailure.missingBaseline {
                        try await fillBaselines()
                        try replica.accept(receipt, project: project)
                    }
                }
            }
            var more = false
            for _ in 0..<10 {
                let page = try await transport.pull(cursor: replica.cursor)
                try replica.receive(page, project: project)
                more = page.hasMore
                if !more { break }
            }
            let pending = try replica.nextCommand()
            return !more && pending == nil
        } catch let error as CarryGraphTransportFailure {
            switch error {
            case .conflict(let details): try replica.blockFlight(details: details)
            case .rejected(let code): try replica.blockFlight(details: JSONEncoder().encode(["error": code]))
            case .sessionExpired, .unavailable, .invalidResponse: break
            }
            throw error
        }
    }

    private func fillBaselines() async throws {
        for _ in 0..<10 {
            let page = try await transport.pull(cursor: replica.cursor)
            try replica.receive(page, project: project)
            if !page.hasMore { break }
        }
    }
}
