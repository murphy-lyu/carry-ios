import { test } from "node:test";
import assert from "node:assert/strict";
import { CarryRelay, digest, TOOLS } from "../worker.js";
import { webcrypto } from "node:crypto";
if (!globalThis.crypto) globalThis.crypto = webcrypto;

class Storage {
  values = new Map();
  alarmAt = null;
  async get(key) { return structuredClone(this.values.get(key)); }
  async put(key, value) {
    const entries = typeof key === "string" ? [[key, value]] : Object.entries(key);
    const cloned = entries.map(([k, v]) => [k, structuredClone(v)]);
    for (const [k, v] of cloned) this.values.set(k, v);
  }
  async delete(key) { this.values.delete(key); }
  async list({ prefix = "", limit = Infinity, startAfter = "" } = {}) { return new Map([...this.values].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).filter(([k]) => k.startsWith(prefix) && k > startAfter).slice(0, limit).map(([k, v]) => [k, structuredClone(v)])); }
  async getAlarm() { return this.alarmAt; }
  async setAlarm(value) { this.alarmAt = value; }
}
function fixture() {
  const storage = new Storage();
  let lock = Promise.resolve();
  const relay = new CarryRelay({ storage, blockConcurrencyWhile(fn) {
    const result = lock.then(fn); lock = result.catch(() => {}); return result;
  } }, {});
  const send = (path, body, token, method = "POST", headers = {}) => relay.fetch(new Request("https://carry.test" + path, {
    method, headers: { ...(body ? { "Content-Type": "application/json" } : {}), ...(token ? { Authorization: "Bearer " + token } : {}), ...headers },
    ...(body ? { body: typeof body === "string" ? body : JSON.stringify(body) } : {}),
  }));
  const rpc = async (token, name, args = {}) => {
    const response = await send("/mcp", { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, token);
    return (await response.json()).result;
  };
  async function pair(tripIds = [], scope = "trips:read trips:write", shareLibrary = false) {
    const registered = await (await send("/register", { client_name: "Test client", redirect_uris: ["http://127.0.0.1:51234/callback"] })).json();
    const verifier = "v".repeat(64), hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
    const challenge = Buffer.from(hash).toString("base64url");
    const params = new URLSearchParams({ client_id: registered.client_id, redirect_uri: "http://127.0.0.1:51234/callback", response_type: "code", code_challenge_method: "S256", code_challenge: challenge, state: "test-state", scope });
    const html = await (await send("/authorize?" + params, null, null, "GET")).text();
    const code = html.match(/<code>([A-F0-9]{16})<\/code>/)[1];
    const flow = html.match(/'X-Flow':"([a-f0-9]+)"/)[1];
    const preview = await (await send("/device/pair", { code, preview: true })).json();
    assert.equal(preview.clientName, "Test client");
    assert.equal(preview.redirectHost, "127.0.0.1:51234");
    const paired = await (await send("/device/pair", { code, tripIds, shareLibrary })).json();
    const status = await (await send("/authorize/status", null, null, "GET", { "X-Flow": flow })).json();
    const redirect = new URL(status.redirect);
    assert.equal(redirect.searchParams.get("state"), "test-state");
    const grant = { grant_type: "authorization_code", client_id: registered.client_id, code: redirect.searchParams.get("code"), code_verifier: verifier, redirect_uri: "http://127.0.0.1:51234/callback" };
    const tokenResponse = await send("/token", new URLSearchParams(grant).toString(), null, "POST", { "Content-Type": "application/x-www-form-urlencoded" });
    assert.equal(tokenResponse.status, 200);
    return { ...paired, ...await tokenResponse.json(), grant, code };
  }
  return { relay, storage, send, rpc, pair };
}
const id = () => crypto.randomUUID();
const revision = "a".repeat(64);

async function pendingPair(f) {
  const client = await (await f.send("/register", { client_name: "Recovery QA", redirect_uris: ["http://127.0.0.1:51234/callback"] })).json();
  const verifier = "r".repeat(64);
  const challenge = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))).toString("base64url");
  const params = new URLSearchParams({ client_id: client.client_id, redirect_uri: "http://127.0.0.1:51234/callback", response_type: "code", code_challenge_method: "S256", code_challenge: challenge, scope: "trips:read trips:write library:read" });
  const page = await (await f.send("/authorize?" + params, null, null, "GET")).text();
  return { code: page.match(/<code>([A-F0-9]{16})<\/code>/)[1], connectionId: id(), deviceToken: "c".repeat(64), tripIds: [], shareLibrary: false };
}

test("lost pairing responses recover the same connection without storing secrets or widening consent", async () => {
  const f = fixture(), attempt = await pendingPair(f);
  const first = await (await f.send("/device/pair", attempt)).json();
  assert.equal((await f.storage.get("pair:" + attempt.code)).consumed, true);
  const recovered = await (await f.send("/device/pair", attempt)).json();
  assert.deepEqual(recovered, first);
  assert.equal(first.deviceToken, attempt.deviceToken);
  assert.equal(first.scope, "trips:read trips:write");
  assert.equal(JSON.stringify([...f.storage.values]).includes(attempt.deviceToken), false);
  assert.equal((await f.send("/device/pair", { ...attempt, tripIds: [id()] })).status, 403);
  assert.equal((await f.send("/device/pair", { ...attempt, deviceToken: "d".repeat(64) })).status, 403);
  assert.equal((await f.send("/device/pair", { ...attempt, shareLibrary: true })).status, 403);
  await f.send("/device/revoke", {}, attempt.deviceToken);
  assert.equal((await f.send("/device/pair", attempt)).status, 403);
});

test("cancelling pending pairing blocks late approval and revokes an already created grant", async () => {
  const f = fixture(), attempt = await pendingPair(f);
  assert.equal((await f.send("/device/cancel-pair", attempt)).status, 200);
  assert.equal((await f.send("/device/pair", attempt)).status, 404);
  assert.equal(await f.storage.get("connection:" + attempt.connectionId), undefined);
  const g = fixture(), created = await pendingPair(g);
  assert.equal((await g.send("/device/pair", created)).status, 200);
  assert.equal((await g.send("/device/cancel-pair", { ...created, deviceToken: "d".repeat(64) })).status, 403);
  assert.equal((await g.send("/device/next", {}, created.deviceToken)).status, 200);
  assert.equal((await g.send("/device/cancel-pair", created)).status, 200);
  assert.equal((await g.send("/device/cancel-pair", created)).status, 200);
  assert.equal((await g.send("/device/next", {}, created.deviceToken)).status, 401);
  assert.equal((await g.send("/device/pair", created)).status, 403);
});

test("pairing storage failure cannot consume the code or publish a partial grant", async () => {
  const f = fixture(), attempt = await pendingPair(f), put = f.storage.put.bind(f.storage);
  f.storage.put = async (key, value) => {
    if (typeof key === "object" && Object.keys(key).some(k => k.startsWith("connection:"))) {
      assert.equal(Object.keys(key).length, 5);
      throw new Error("Injected atomic batch failure");
    }
    return put(key, value);
  };
  assert.equal((await f.send("/device/pair", attempt)).status, 500);
  assert.equal((await f.storage.get("pair:" + attempt.code)).consumed, undefined);
  assert.equal(await f.storage.get("connection:" + attempt.connectionId), undefined);
  assert.equal(await f.storage.get("device:" + await digest(attempt.deviceToken)), undefined);
  f.storage.put = put;
  assert.equal((await f.send("/device/pair", attempt)).status, 200);
  assert.equal((await f.send("/device/pair", attempt)).status, 200);
});

test("OAuth revocation is client-bound, idempotent and clears both client and device access", async () => {
  const f = fixture(), conn = await f.pair();
  const revoke = client_id => f.send("/revoke", new URLSearchParams({ token: conn.access_token, client_id }).toString(), null, "POST", { "Content-Type": "application/x-www-form-urlencoded" });
  assert.equal((await revoke(id())).status, 200);
  assert.equal((await f.send("/device/next", {}, conn.deviceToken)).status, 200);
  assert.equal((await revoke(conn.grant.client_id)).status, 200);
  assert.equal((await f.send("/device/next", {}, conn.deviceToken)).status, 401);
  assert.equal((await f.send("/mcp", { jsonrpc: "2.0", id: 1, method: "tools/list" }, conn.access_token)).status, 401);
  assert.equal((await revoke(conn.grant.client_id)).status, 200);
});

test("library-only OAuth does not retain trip snapshots even if a device sends them", async () => {
  const f = fixture(), tripId = id(), conn = await f.pair([tripId], "library:read library:write", true);
  assert.equal((await f.send("/device/snapshot", { trips: [{ id: tripId, name: "Not granted", revision }], library: { items: [], revision } }, conn.deviceToken)).status, 200);
  assert.equal((await f.storage.get("data:" + conn.connectionId + ":snapshot")).trips.length, 0);
  assert.equal(await f.storage.get("data:" + conn.connectionId + ":trip:" + tripId), undefined);
});

test("operation summaries and queue selection work beyond a storage page without returning receipts", async () => {
  const f = fixture(), conn = await f.pair(), now = Date.now();
  let last;
  for (let i = 0; i < 250; i++) {
    last = id();
    await f.storage.put("data:" + conn.connectionId + ":op:" + last, { requestId: last, name: "create_trip", status: i === 249 ? "queued" : "applied", createdAt: now + i, expiresAt: now + 10000, arguments: { data: { name: "QA " + i } }, result: { data: "not part of summary" } });
  }
  const summaries = await (await f.send("/device/operations", {}, conn.deviceToken)).json();
  assert.equal(summaries.operations.length, 20);
  assert.equal(summaries.operations[0].requestId, last);
  assert.equal(summaries.operations[0].result, undefined);
  const next = await (await f.send("/device/next", {}, conn.deviceToken)).json();
  assert.equal(next.operation.requestId, last);
});

test("oversize operations are rejected before exceeding a Durable Object value limit", async () => {
  const f = fixture(), tripId = id(), conn = await f.pair([tripId]);
  const result = await f.rpc(conn.access_token, "apply_packing_recommendations", { requestId: id(), tripId, expectedRevision: revision, data: { selectedNames: Array(500).fill("x".repeat(500)) } });
  assert.equal(result.isError, true);
  assert.equal(result.content[0].text, "operation_too_large");
});

test("large unicode snapshots are chunked, paginated and completely removed on revoke", async () => {
  const f = fixture(), tripId = id(), conn = await f.pair([tripId]);
  const days = Array.from({ length: 40 }, (_, dayOrder) => ({ id: id(), dayOrder, title: "日本", note: "旅程🌸".repeat(1000), stops: [], transport: [] }));
  assert.equal((await f.send("/device/snapshot", { trips: [{ id: tripId, name: "Tokyo", revision, days }] }, conn.deviceToken)).status, 200);
  assert.ok([...f.storage.values.keys()].some(key => key.includes(":chunks:")));
  const read = await f.rpc(conn.access_token, "get_trip", { tripId, dayOffset: 20, dayLimit: 10 });
  assert.equal(read.structuredContent.trip.days.length, 10);
  assert.equal(read.structuredContent.trip.days[0].note, days[20].note);
  assert.equal(read.structuredContent.dayPage.nextOffset, 30);
  await f.send("/device/revoke", {}, conn.deviceToken);
  assert.equal([...f.storage.values.keys()].filter(key => key.startsWith("data:" + conn.connectionId)).length, 0);
});

test("retention scans beyond one storage page and malformed snapshots fail with a client error", async () => {
  const f = fixture(), tripId = id(), conn = await f.pair([tripId]);
  for (let i = 0; i < 250; i++) await f.storage.put("old:" + String(i).padStart(3, "0"), { expires: Date.now() - 1 });
  await f.relay.alarm();
  assert.equal([...f.storage.values.keys()].filter(key => key.startsWith("old:")).length, 0);
  assert.equal((await f.send("/device/snapshot", { trips: [{ id: tripId, revision, days: {} }] }, conn.deviceToken)).status, 400);
});

test("read-only device queries carry results without enabling writes", async () => {
  const f = fixture(), conn = await f.pair([], "trips:read"), requestId = id();
  const queued = await f.rpc(conn.access_token, "search_airports", { requestId, data: { query: "NRT" } });
  assert.equal(queued.structuredContent.status, "queued");
  await f.send("/device/next", {}, conn.deviceToken);
  const data = { results: [{ iata: "NRT", name: "Narita" }] };
  assert.equal((await f.send("/device/receipt", { requestId, payloadHash: queued.structuredContent.payloadHash, status: "applied", data }, conn.deviceToken)).status, 200);
  const result = await f.rpc(conn.access_token, "get_operation", { requestId });
  assert.deepEqual(result.structuredContent.result.data, data);
  assert.equal((await f.rpc(conn.access_token, "create_trip", { requestId: id(), data: { name: "Forbidden", isDateless: true } })).isError, true);
});

test("PKCE pairing is explicit, one-time, and does not expose device credentials to MCP", async () => {
  const f = fixture(), conn = await f.pair();
  assert.equal((await f.send("/device/pair", { code: conn.code, tripIds: [] })).status, 404);
  assert.equal((await f.send("/token", new URLSearchParams(conn.grant).toString())).status, 400);
  assert.equal((await f.send("/device/next", {}, conn.access_token)).status, 401);
  const unauthenticated = await f.send("/mcp", { jsonrpc: "2.0", id: 1, method: "initialize" });
  assert.equal(unauthenticated.status, 401);
  assert.match(unauthenticated.headers.get("WWW-Authenticate"), /resource_metadata/);
  assert.equal((await f.send("/device/next", {}, conn.deviceToken)).status, 200);
});

test("redirect registration rejects insecure or credential-bearing destinations", async () => {
  const f = fixture();
  for (const uri of ["http://example.com/cb", "https://a:b@example.com/cb", "https://example.com/#secret", "javascript:alert(1)"]) {
    assert.equal((await f.send("/register", { redirect_uris: [uri] })).status, 400);
  }
});

test("pair and operation scopes isolate two users even with a known trip UUID", async () => {
  const f = fixture(), tripId = id(), one = await f.pair([tripId]), two = await f.pair();
  await f.send("/device/snapshot", { trips: [{ id: tripId.toUpperCase(), name: "Tokyo", destinationCity: "Tokyo", revision }] }, one.deviceToken);
  const allowed = await f.rpc(one.access_token, "get_trip", { tripId });
  assert.equal(allowed.structuredContent.trip.name, "Tokyo");
  assert.equal((await f.rpc(two.access_token, "get_trip", { tripId })).isError, true);
  assert.equal((await f.rpc(two.access_token, "delete_trip", { requestId: id(), tripId, expectedRevision: revision })).isError, true);
});

test("a queued operation is not applied; duplicate requests reuse the original generated entity UUID", async () => {
  const f = fixture(), conn = await f.pair(), requestId = id();
  const first = await f.rpc(conn.access_token, "create_trip", { requestId, data: { name: "Tokyo", isDateless: true } });
  assert.equal(first.structuredContent.status, "queued");
  const duplicate = await f.rpc(conn.access_token, "create_trip", { data: { isDateless: true, name: "Tokyo" }, requestId: requestId.toUpperCase() });
  assert.equal(duplicate.structuredContent.entityId, first.structuredContent.entityId);
  assert.equal((await f.rpc(conn.access_token, "create_trip", { requestId, data: { name: "Osaka" } })).isError, true);
  const next = await (await f.send("/device/next", {}, conn.deviceToken)).json();
  assert.equal(next.operation.status, "executing");
  const receipt = { requestId, payloadHash: next.operation.payloadHash, status: "applied", entityId: next.operation.entityId, revision };
  assert.equal((await f.send("/device/receipt", receipt, conn.deviceToken)).status, 200);
  assert.equal((await f.send("/device/receipt", receipt, conn.deviceToken)).status, 200);
  assert.equal((await f.rpc(conn.access_token, "get_operation", { requestId })).structuredContent.status, "applied");
  const after = await (await f.send("/device/next", {}, conn.deviceToken)).json();
  assert.equal(after.operation, null);
  assert.ok(after.tripIds.includes(next.operation.entityId));
});

test("queued cancellation and expiry prevent execution, executing requests cannot be reassigned or cancelled", async () => {
  const f = fixture(), conn = await f.pair(), first = id(), second = id();
  await f.rpc(conn.access_token, "create_trip", { requestId: first, data: { name: "A" } });
  await f.rpc(conn.access_token, "cancel_operation", { requestId: first });
  assert.equal((await (await f.send("/device/next", {}, conn.deviceToken)).json()).operation, null);
  await f.rpc(conn.access_token, "create_trip", { requestId: second, data: { name: "B" } });
  const next = await (await f.send("/device/next", {}, conn.deviceToken)).json();
  assert.equal((await f.rpc(conn.access_token, "cancel_operation", { requestId: second })).isError, true);
  assert.equal((await (await f.send("/device/next", {}, conn.deviceToken)).json()).operation.entityId, next.operation.entityId);
  const third = id();
  await f.rpc(conn.access_token, "create_trip", { requestId: third, data: { name: "C" } });
  const key = `data:${conn.connectionId}:op:${third}`, op = await f.storage.get(key);
  op.expiresAt = 1; await f.storage.put(key, op);
  await f.relay.alarm();
  assert.equal((await f.rpc(conn.access_token, "get_operation", { requestId: third })).structuredContent.status, "expired");
});

test("read-only scope cannot enqueue writes; unknown fields and invalid numeric values are rejected", async () => {
  const f = fixture(), tripId = id(), readOnly = await f.pair([tripId], "trips:read"), writer = await f.pair([tripId]);
  assert.equal((await f.rpc(readOnly.access_token, "create_trip", { requestId: id(), data: { name: "Trip" } })).isError, true);
  assert.equal((await f.rpc(writer.access_token, "add_stop", { requestId: id(), tripId, expectedRevision: revision, data: { name: "Park", latitude: 91 } })).isError, true);
  assert.equal((await f.rpc(writer.access_token, "update_trip", { requestId: id(), tripId, expectedRevision: revision, data: { arbitrarySQL: "select *" } })).isError, true);
});

test("revocation deletes snapshots and queued operations and rejects both credential types", async () => {
  const f = fixture(), tripId = id(), conn = await f.pair([tripId]);
  await f.send("/device/snapshot", { trips: [{ id: tripId, name: "Tokyo", revision }] }, conn.deviceToken);
  await f.rpc(conn.access_token, "create_trip", { requestId: id(), data: { name: "Trip" } });
  assert.equal((await f.send("/device/revoke", {}, conn.deviceToken)).status, 200);
  assert.equal((await f.storage.list({ prefix: `data:${conn.connectionId}:` })).size, 0);
  assert.equal((await f.send("/device/next", {}, conn.deviceToken)).status, 401);
  assert.equal((await f.send("/mcp", { jsonrpc: "2.0", id: 1, method: "tools/list" }, conn.access_token)).status, 401);
});

test("retention removes stale data and request digests never contain raw tokens", async () => {
  const f = fixture(), conn = await f.pair();
  await f.storage.put(`data:${conn.connectionId}:trip:old`, { expires: 1 });
  await f.storage.put(`data:${conn.connectionId}:op:old`, { status: "applied", completedAt: 1 });
  await f.relay.alarm();
  assert.equal(await f.storage.get(`data:${conn.connectionId}:trip:old`), undefined);
  assert.equal(await f.storage.get(`data:${conn.connectionId}:op:old`), undefined);
  const keys = [...f.storage.values.keys()].join("\n");
  assert.ok(!keys.includes(conn.access_token) && !keys.includes(conn.deviceToken));
  assert.ok(keys.includes(await digest(conn.access_token)));
  assert.ok(TOOLS.every(t => t.inputSchema.additionalProperties === false));
});

test("custom library requires separate device consent, even when OAuth asks for it", async () => {
  const f = fixture(), requested = "trips:read trips:write library:read library:write";
  const denied = await f.pair([], requested), allowed = await f.pair([], requested, true);
  const library = { revision, items: [{ id: id(), name: "Camera", collectionName: "Default", category: "", defaultQuantity: 1, quantityMode: "fixed", quantityIntervalDays: 2, sortOrder: 0 }] };
  await f.send("/device/snapshot", { trips: [], library }, allowed.deviceToken);
  assert.equal((await f.rpc(denied.access_token, "get_item_library")).isError, true);
  assert.equal((await f.rpc(allowed.access_token, "get_item_library")).structuredContent.items[0].name, "Camera");
  const added = await f.rpc(allowed.access_token, "add_my_item", { requestId: id(), expectedRevision: revision, data: { name: "Coat" } });
  assert.equal(added.structuredContent.status, "queued");
});

test("public snapshots strip private fields on the server and refresh tokens rotate", async () => {
  const f = fixture(), tripId = id(), conn = await f.pair([tripId]);
  await f.send("/device/snapshot", { trips: [{ id: tripId, name: "Trip", revision, attachments: ["secret"], health: { secret: true }, lodging: [{ id: id(), name: "Hotel", confirmationCode: "private-number" }] }] }, conn.deviceToken);
  const snapshot = JSON.stringify(await f.rpc(conn.access_token, "get_trip", { tripId }));
  assert.ok(!snapshot.includes("secret") && !snapshot.includes("private-number"));
  const params = new URLSearchParams({ grant_type: "refresh_token", client_id: conn.grant.client_id, refresh_token: conn.refresh_token }).toString();
  assert.equal((await f.send("/token", params)).status, 200);
  assert.equal((await f.send("/token", params)).status, 400);
});
