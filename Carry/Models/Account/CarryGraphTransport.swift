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

/// One account's HTTP adapter. A refreshed bearer comes from AccountService,
/// while account ownership is derived and verified again on the server.
@MainActor
final class CarryGraphTransport: CarryGraphTransporting {
    private struct Body: Encodable {
        let action: String
        var command: CarryGraphCommand?
        var cursor: Int?
        var limit: Int?
    }
    private struct Failure: Decodable { let error: String }
    private let endpoint: URL
    private let publishableKey: String
    private let accessToken: () async throws -> String
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(configuration: CarryAccountConfiguration,
         accessToken: @escaping () async throws -> String,
         send: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        endpoint = configuration.projectURL.appendingPathComponent("functions/v1/carry-data")
        publishableKey = configuration.publishableKey
        self.accessToken = accessToken
        self.send = send
    }

    func apply(_ command: CarryGraphCommand) async throws -> CarryGraphReceipt {
        try await request(Body(action: "apply", command: command))
    }

    func pull(cursor: Int) async throws -> CarryGraphPage {
        try await request(Body(action: "pull", cursor: cursor, limit: 100))
    }

    private func request<Result: Decodable>(_ body: Body) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, data.count <= 16 * 1024 * 1024 else {
            throw CarryGraphTransportFailure.invalidResponse
        }
        if http.statusCode == 401 { throw CarryGraphTransportFailure.sessionExpired }
        if http.statusCode == 409 { throw CarryGraphTransportFailure.conflict(data) }
        if http.statusCode == 422 {
            let failure = try JSONDecoder().decode(Failure.self, from: data)
            throw CarryGraphTransportFailure.rejected(failure.error)
        }
        guard http.statusCode == 200 else { throw CarryGraphTransportFailure.unavailable }
        do { return try JSONDecoder().decode(Result.self, from: data) }
        catch { throw CarryGraphTransportFailure.invalidResponse }
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
                let receipt = try await transport.apply(command)
                try replica.accept(receipt, project: project)
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
}
