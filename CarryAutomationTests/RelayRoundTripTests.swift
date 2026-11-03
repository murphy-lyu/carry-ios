import XCTest
import SwiftData
import Combine
import CryptoKit
@testable import Carry

/// Defaults to the local relay; production testing requires an explicit test-only URL.
/// Only synthetic data is used; no connection credentials are printed or persisted to Keychain.
@MainActor
final class RelayRoundTripTests: XCTestCase {
    func testDevicePersistsRelayRequestAndPublishesConfirmedSnapshot() async throws {
        let configuredBase = ProcessInfo.processInfo.environment["CARRY_RELAY_TEST_BASE_URL"] ?? ""
        let base = configuredBase.isEmpty ? "http://127.0.0.1:8789" : configuredBase
        guard ["http://127.0.0.1:8789", "https://connect.nevestudio.app"].contains(base) else {
            XCTFail("Relay test URL must be the documented local or production endpoint")
            return
        }
        print("Relay test endpoint: \(base)")
        func send(_ path: String, _ body: Any? = nil, token: String? = nil, method: String = "POST", headers: [String: String] = [:]) async throws -> (Data, Int) {
            var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
            request.httpMethod = method; request.timeoutInterval = 20
            if let string = body as? String { request.httpBody = Data(string.utf8); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
            else if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            // Log the route only: authorize URLs contain temporary flow parameters.
            let route = String(path.split(separator: "?", maxSplits: 1)[0])
            print("Relay request: \(method) \(route)")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            print("Relay response: \(method) \(route) \(status)")
            return (data, status)
        }
        func object(_ result: (Data, Int), status: Int = 200) throws -> [String: Any] {
            XCTAssertEqual(result.1, status)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result.0) as? [String: Any])
        }
        func match(_ pattern: String, _ source: String) throws -> String {
            let regex = try NSRegularExpression(pattern: pattern)
            let result = try XCTUnwrap(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
            return String(source[try XCTUnwrap(Range(result.range(at: 1), in: source))])
        }
        let registration = try object(await send("/register", ["client_name": "Native QA", "redirect_uris": ["http://127.0.0.1:51235/callback"]]), status: 201)
        let client = try XCTUnwrap(registration["client_id"] as? String), verifier = String(repeating: "v", count: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.queryItems = ["client_id": client, "redirect_uri": "http://127.0.0.1:51235/callback", "response_type": "code", "code_challenge_method": "S256", "code_challenge": challenge, "scope": "trips:read trips:write", "state": "native-qa"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let htmlData = try await send("/authorize?" + (components.percentEncodedQuery ?? ""), method: "GET")
        let html = try XCTUnwrap(String(data: htmlData.0, encoding: .utf8))
        let code = try match("<code>([A-F0-9]{16})</code>", html), flow = try match("'X-Flow':\"([a-f0-9]+)\"", html)
        let paired = try object(await send("/device/pair", ["code": code, "tripIds": []]))
        let deviceToken = try XCTUnwrap(paired["deviceToken"] as? String), connectionId = try XCTUnwrap(UUID(uuidString: paired["connectionId"] as? String ?? ""))
        do {
            let authorized = try object(await send("/authorize/status", method: "GET", headers: ["X-Flow": flow]))
            let callback = try XCTUnwrap(URLComponents(string: authorized["redirect"] as? String ?? ""))
            let authCode = try XCTUnwrap(callback.queryItems?.first { $0.name == "code" }?.value)
            components.queryItems = ["grant_type": "authorization_code", "client_id": client, "redirect_uri": "http://127.0.0.1:51235/callback", "code": authCode, "code_verifier": verifier].map { URLQueryItem(name: $0.key, value: $0.value) }
            let tokens = try object(await send("/token", components.percentEncodedQuery ?? "")), access = try XCTUnwrap(tokens["access_token"] as? String)
            let requestId = UUID()
            let rpc: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "create_trip", "arguments": ["requestId": requestId.uuidString, "data": ["name": "Relay QA", "isDateless": true]]]]
            _ = try object(await send("/mcp", rpc, token: access))
            let next = try object(await send("/device/next", [:], token: deviceToken)), commandData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(next["operation"]))
            let command = try JSONDecoder().decode(AutomationOperation.self, from: commandData)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = Schema(versionedSchema: SchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: directory.appendingPathComponent("relay.store"), cloudKitDatabase: .none)])
            let store = TripStore(context: ModelContext(container))
            let ready = expectation(description: "Persistent store loaded")
            let subscription = store.$automationReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
            await fulfillment(of: [ready], timeout: 10); subscription.cancel()
            let receipt = try store.executeAutomation(command, connectionId: connectionId, allowedTripIds: [])
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TripBundle>()), 1)
            let receiptJSON = try JSONSerialization.jsonObject(with: AutomationCodec.encode(receipt))
            _ = try object(await send("/device/receipt", receiptJSON, token: deviceToken))
            _ = try object(await send("/device/receipt", receiptJSON, token: deviceToken))
            let tripId = try XCTUnwrap(receipt.entityId)
            let snapshots = try store.automationSnapshots(allowedTripIds: [tripId])
            let snapshotJSON = try JSONSerialization.jsonObject(with: AutomationCodec.encode(snapshots))
            _ = try object(await send("/device/snapshot", ["trips": snapshotJSON], token: deviceToken))
            let query: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_trip", "arguments": ["tripId": tripId.uuidString]]]
            let read = try object(await send("/mcp", query, token: access))
            let result = try XCTUnwrap(read["result"] as? [String: Any]), content = try XCTUnwrap(result["structuredContent"] as? [String: Any]), trip = try XCTUnwrap(content["trip"] as? [String: Any])
            XCTAssertEqual(trip["name"] as? String, "Relay QA")
            XCTAssertEqual(trip["revision"] as? String, receipt.revision)
            _ = try object(await send("/device/revoke", [:], token: deviceToken))
            let revoked = try await send("/mcp", query, token: access)
            XCTAssertEqual(revoked.1, 401)
        } catch {
            _ = try? await send("/device/revoke", [:], token: deviceToken)
            throw error
        }
    }
}
