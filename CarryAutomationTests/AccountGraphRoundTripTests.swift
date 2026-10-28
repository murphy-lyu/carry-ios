import XCTest
import SwiftData
import Auth
@testable import Carry

/// Requires scripts/carry-account-service/graph-qa-server.mjs on localhost.
/// PostgreSQL + SwiftData + URLSession are real; authentication is explicitly a
/// synthetic fixture. This does not claim Apple/Supabase production acceptance.
@MainActor
final class AccountGraphRoundTripTests: XCTestCase {
    func testOversizedDeclaredAndChunkedResponsesCancelBeforeDownloadingTheCompleteBody() async throws {
        struct Probe: Decodable { let sent: Int; let total: Int }
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:8891"))
        for mode in ["declared", "chunked"] {
            let id = UUID().uuidString.lowercased()
            let configuration = CarryAccountConfiguration(
                projectURL: base.appendingPathComponent("__response_limit/\(mode)/\(id)"),
                publishableKey: "sb_publishable_synthetic_only")
            // Exercise the real AccountService factory, whose injected HTTP
            // sender must preserve the streaming cap in the shipped path.
            let owner = UUID()
            let storage = CarryAccountSecureStorage(namespace: "bounded-http-\(id)")
            addTeardownBlock {
                try storage.remove(key: "session")
                try storage.remove(key: "profile")
            }
            try storage.store(key: "profile", value: JSONEncoder().encode(
                CarryAccountProfile(id: owner, displayName: nil, email: nil)))
            let session = Session(accessToken: "synthetic-native-qa", tokenType: "bearer",
                expiresIn: 3600, expiresAt: Date().timeIntervalSince1970 + 3600,
                refreshToken: "synthetic-refresh", user: User(id: owner, appMetadata: [:],
                    userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date()))
            try storage.store(key: "session", value: JSONEncoder().encode(session))
            let service = CarryAccountService(configuration: configuration, storage: storage)
            let transport = try service.graphTransport(for: owner)
            do { _ = try await transport.pull(cursor: 0); XCTFail("Oversized responses must fail") }
            catch CarryGraphTransportFailure.invalidResponse { }
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("__response_limit_stats/\(id)"))
            let probe = try JSONDecoder().decode(Probe.self, from: data)
            XCTAssertEqual(probe.total, 64 * 1024 * 1024)
            XCTAssertLessThan(probe.sent, 32 * 1024 * 1024,
                "A post-download size check would consume the complete 64 MiB fixture")
        }
    }

    private struct Fixture: Decodable {
        let accountID: UUID
        let fields: [String: CarryGraphValue]
    }

    func testOfflineReplicasConvergeConflictsRemainAndLostResponseIsExactlyOnce() async throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:8891"))
        let (fixtureBytes, _) = try await URLSession.shared.data(from: base.appendingPathComponent("__fixture"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: fixtureBytes)
        let configuration = CarryAccountConfiguration(projectURL: base, publishableKey: "sb_publishable_synthetic_only")
        let transport = CarryGraphTransport(configuration: configuration, accessToken: { "synthetic-native-qa" })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarryGraphHTTP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        func replica(_ name: String) throws -> CarryAccountReplica {
            try CarryAccountReplica(container: CarryAccountReplica.container(at: directory.appendingPathComponent(name + ".store")), accountID: fixture.accountID)
        }
        let one = try replica("one"), two = try replica("two")
        let entityID = UUID()
        let create = CarryGraphCommand(requestID: UUID(), mutations: [CarryGraphMutation(id: entityID, kind: "trip", action: "create",
            baseVersion: 0, parentID: nil, fields: fixture.fields)])
        // No local replica is pumping: the server alone accepts the plan.
        let serverSaved = try await transport.apply(create)
        XCTAssertEqual(serverSaved.status, "saved_to_account")
        let syncOne = CarryAccountSyncEngine(replica: one, transport: transport)
        let syncTwo = CarryAccountSyncEngine(replica: two, transport: transport)
        func drain(_ engine: CarryAccountSyncEngine) async throws {
            for _ in 0..<100 { if try await engine.synchronize() { return } }
            XCTFail("Bounded synchronization continuations must finish the synthetic history")
        }
        // The QA server intentionally retains earlier synthetic runs. Cold start
        // must consume all cursor pages, not assume our trip is in page one.
        try await drain(syncOne); try await drain(syncTwo)
        func find(_ store: CarryAccountReplica) throws -> CarryGraphEntity {
            try XCTUnwrap(store.localEntities().first { $0.id == entityID })
        }
        var phone = try find(one), other = try find(two)
        phone.fields["name"] = .string("Offline phone name")
        other.fields["destinationCity"] = .string("Tokyo, Japan")
        try one.edit(phone); try two.edit(other)
        let first = try await syncOne.synchronize(), second = try await syncTwo.synchronize()
        let converged = try await syncOne.synchronize()
        XCTAssertTrue(first && second && converged)
        XCTAssertEqual(try find(one).fields, try find(two).fields)
        XCTAssertEqual(try find(two).fields["name"], .string("Offline phone name"))
        XCTAssertEqual(try find(one).fields["destinationCity"], .string("Tokyo, Japan"))
        // Both edit the SAME field from one baseline. The loser retains its edit.
        phone = try find(one); other = try find(two)
        phone.fields["name"] = .string("Accepted phone edit")
        other.fields["name"] = .string("Conflicting offline edit")
        try one.edit(phone); try two.edit(other)
        let conflictingCommand = try XCTUnwrap(two.nextCommand())
        _ = try await syncOne.synchronize()
        do { _ = try await syncTwo.synchronize(); XCTFail("Concurrent same-field edits must conflict") }
        catch CarryGraphTransportFailure.conflict { }
        XCTAssertEqual(try find(two).fields["name"], .string("Conflicting offline edit"))
        XCTAssertThrowsError(try two.nextCommand(), "A permanent conflict must not enter an endless retry loop")
        XCTAssertNotNil(try two.pendingFailure)
        let authoritative = try find(one)
        XCTAssertThrowsError(try two.resolveFields(requestID: UUID(), serverVersion: authoritative.version, choices: ["name": .local]))
        try two.resolveFields(requestID: conflictingCommand.requestID, serverVersion: authoritative.version, choices: ["name": .local])
        let resolved = try await syncTwo.synchronize()
        XCTAssertTrue(resolved)
        _ = try await syncOne.synchronize()
        XCTAssertEqual(try find(one).fields["name"], .string("Conflicting offline edit"))
        XCTAssertNil(try two.pendingFailure)
        // Simulate server commit followed by the loss of its HTTP response.
        let third = try replica("lost-response")
        let lostID = UUID()
        try third.edit(CarryGraphEntity(id: lostID, kind: "trip", parentID: nil, version: 0, subtreeVersion: 0,
            fields: fixture.fields, fieldVersions: [:]))
        let frozen = try XCTUnwrap(third.nextCommand())
        var dropResponse = true
        let lossy = CarryGraphTransport(configuration: configuration, accessToken: { "synthetic-native-qa" }, send: { request in
            let response = try await URLSession.shared.data(for: request)
            if dropResponse { dropResponse = false; throw URLError(.timedOut) }
            return response
        })
        do { _ = try await CarryAccountSyncEngine(replica: third, transport: lossy).synchronize(); XCTFail("Injected lost response") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let reopened = try replica("lost-response")
        XCTAssertEqual(try reopened.nextCommand(), frozen)
        let recovered = try await CarryAccountSyncEngine(replica: reopened, transport: transport).synchronize()
        XCTAssertTrue(recovered)
        XCTAssertEqual(try reopened.localEntities().filter { $0.id == lostID }.count, 1)
        XCTAssertEqual(try reopened.localEntities().first { $0.id == lostID }?.version, 1)
    }
}
