import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../worker.js";
import { usesAccountGateway, forwardAccountRequest } from "../account-gateway.mjs";
import { ownerProofHeaders, verifyOwnerProof } from "../../carry-account-ai/owner-proof.mjs";
import { routeEdgeRequest } from "../../carry-account-ai/edge-router.mjs";

const origin = "https://connect.nevestudio.app";
const enabled = { ACCOUNT_AI_GATEWAY_ENABLED: "true" };
const request = (path, init) => new Request(origin + path, init);

test("account routing requires explicit string enablement", () => {
  for (const env of [{}, { ACCOUNT_AI_GATEWAY_ENABLED: false }, { ACCOUNT_AI_GATEWAY_ENABLED: true }, { ACCOUNT_AI_GATEWAY_ENABLED: "false" }])
    assert.equal(usesAccountGateway(request("/mcp"), env), false);
});

test("only account route boundaries and discovery use new backend", () => {
  for (const path of ["/oauth/register", "/oauth/requests/id", "/owner/trips?offset=0&limit=20",
    "/connections", "/connections/id/revoke", "/plans/id/approve", "/exports/id/download",
    "/.well-known/oauth-authorization-server", "/.well-known/oauth-protected-resource/mcp"])
    assert.equal(usesAccountGateway(request(path), enabled), true, path);
  for (const path of ["/oauth-other", "/ownerish/trips", "/connections-extra", "/register",
    "/token", "/authorize", "/authorize/status", "/revoke", "/device/sync", "/health"])
    assert.equal(usesAccountGateway(request(path), enabled), false, path);
});

test("existing exact legacy bearer stays in old relay without fallback guesses", () => {
  assert.equal(usesAccountGateway(request("/mcp", { headers: { Authorization: "Bearer " + "a1".repeat(32) } }), enabled), false);
  for (const token of [null, "Bearer " + "a".repeat(43), "Bearer malformed", "Bearer " + "g".repeat(64)]) {
    const headers = token ? { Authorization: token } : {};
    assert.equal(usesAccountGateway(request("/mcp", { headers }), enabled), true);
  }
});

test("disabled worker still dispatches to the original durable object", async () => {
  let name;
  const response = await worker.fetch(request("/health"), {
    RELAY: { idFromName(value) { name = value; return "id"; },
      get(id) { assert.equal(id, "id"); return { fetch: async () => new Response("legacy") }; } },
  });
  assert.equal(name, "carry-relay-v1");
  assert.equal(await response.text(), "legacy");
});

test("gateway forwards exact body, proof, query, method and cancellation to fixed backend", async () => {
  const controller = new AbortController();
  const body = '{"redirect_uri":"https://client.test/callback","value":"日本"}';
  const input = request("/oauth/register?upstream=https%3A%2F%2Fevil.test", {
    method: "POST", body, signal: controller.signal,
    headers: { Authorization: "Bearer synthetic", Origin: "https://account.nevestudio.app",
      "X-Carry-Owner-Proof": "synthetic-proof", Cookie: "private=session", "X-Forwarded-Host": "evil.test" },
  });
  const response = await forwardAccountRequest(input, async outgoing => {
    assert.equal(outgoing.url, "https://lbxsvguuoqqpctkinpwy.supabase.co/functions/v1/carry-ai/oauth/register?upstream=https%3A%2F%2Fevil.test");
    assert.equal(outgoing.method, "POST");
    assert.equal(outgoing.redirect, "manual");
    assert.equal(outgoing.headers.get("Authorization"), "Bearer synthetic");
    assert.equal(outgoing.headers.get("Origin"), "https://account.nevestudio.app");
    assert.equal(outgoing.headers.get("X-Carry-Owner-Proof"), "synthetic-proof");
    assert.equal(outgoing.headers.get("Cookie"), null);
    assert.equal(outgoing.headers.get("X-Forwarded-Host"), null);
    assert.equal(await outgoing.text(), body);
    controller.abort();
    assert.equal(outgoing.signal.aborted, true);
    return new Response("created", { status: 201 });
  });
  assert.equal(response.status, 201);
});

test("gateway does not follow OAuth redirects or expose upstream cookies", async () => {
  const result = await forwardAccountRequest(request("/oauth/authorize"), async outgoing => {
    assert.equal(outgoing.redirect, "manual");
    return new Response(null, { status: 303, headers: { Location: "https://account.nevestudio.app/oauth/consent",
      "Set-Cookie": "unexpected=secret", "Cache-Control": "public" } });
  });
  assert.equal(result.status, 303);
  assert.equal(result.headers.get("Location"), "https://account.nevestudio.app/oauth/consent");
  assert.equal(result.headers.get("Set-Cookie"), null);
  assert.equal(result.headers.get("Cache-Control"), "no-store");
});

test("private download response streams without eager body reads", async () => {
  let consumed = false;
  const body = new ReadableStream({ pull(controller) {
    consumed = true; controller.enqueue(new TextEncoder().encode("private")); controller.close();
  } }, { highWaterMark: 0 });
  const result = await forwardAccountRequest(request("/exports/id/download"), async () => new Response(body, {
    headers: { "Content-Type": "application/json", "Content-Disposition": 'attachment; filename="Carry-test.json"' },
  }));
  assert.equal(consumed, false);
  assert.equal(await result.text(), "private");
});

test("failure is sanitized and never retried against the legacy relay", async () => {
  let calls = 0;
  const result = await forwardAccountRequest(request("/mcp"), async () => { calls++; throw new Error("secret upstream details"); });
  assert.equal(calls, 1);
  assert.equal(result.status, 502);
  assert.deepEqual(await result.json(), { error: "account_service_unavailable" });
});

test("unrecognized public host cannot forward credentials", async () => {
  let called = false;
  const result = await forwardAccountRequest(new Request("https://evil.test/oauth/register"), async () => { called = true; });
  assert.equal(result.status, 400);
  assert.equal(called, false);
});

test("owner proof survives public gateway and real edge path normalization", async () => {
  const secret = Buffer.alloc(32, 7).toString("base64url");
  const now = 1793520000000;
  const input = request("/oauth/requests/11111111-1111-4111-8111-111111111111", {
    method: "POST", body: '{"decision":"approve"}',
    headers: { Authorization: "Bearer synthetic", Origin: "https://account.nevestudio.app", "Content-Type": "application/json" },
  });
  for (const [key, value] of Object.entries(await ownerProofHeaders(input, secret, now))) input.headers.set(key, value);
  const result = await forwardAccountRequest(input, incoming => routeEdgeRequest(incoming, {
    origin, handler: async canonical => {
      await verifyOwnerProof(canonical, secret, now);
      return new Response(null, { status: 204 });
    },
  }));
  assert.equal(result.status, 204);
});
