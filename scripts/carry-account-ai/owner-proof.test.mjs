import { test } from "node:test";
import assert from "node:assert/strict";
import { ownerProofHeaders, verifyOwnerProof } from "./owner-proof.mjs";
import { createAccountWebAIBridge } from "./account-web-bridge.mjs";
import { opaque, AIFailure } from "./security.mjs";
const now = Date.now(),
  secret = opaque(),
  origin = "https://connect.invalid",
  accountOrigin = "https://account.invalid",
  id = crypto.randomUUID();
const request = (
  path = "/plans/" + id + "/approve",
  body = '{"contentHash":"approved","csrf":"checked"}',
) =>
  new Request(origin + path, {
    method: "POST",
    headers: {
      Authorization: "Bearer verified.native.jwt",
      Origin: accountOrigin,
      "Content-Type": "application/json",
    },
    body,
  });
const rejects = (p, code) =>
  assert.rejects(p, (e) => e instanceof AIFailure && e.code === code);
test("owner bridge proof binds exact URL, method, body and verified native bearer", async () => {
  const r = request(),
    headers = await ownerProofHeaders(r, secret, now);
  for (const [k, v] of Object.entries(headers)) r.headers.set(k, v);
  await verifyOwnerProof(r, secret, now);
  for (const changed of [
    request("/connections/" + id + "/revoke"),
    request(undefined, '{"contentHash":"changed"}'),
    new Request(r, {
      headers: {
        ...Object.fromEntries(r.headers),
        Authorization: "Bearer other.native.jwt",
      },
    }),
  ]) {
    for (const [k, v] of Object.entries(headers)) changed.headers.set(k, v);
    await rejects(
      verifyOwnerProof(changed, secret, now),
      "invalid_owner_proof",
    );
  }
  await rejects(
    verifyOwnerProof(r, secret, now + 30001),
    "invalid_owner_proof",
  );
});
test("unsigned caller owner headers and another bridge secret cannot approve", async () => {
  const r = request();
  r.headers.set("X-Carry-Account-ID", id);
  await rejects(verifyOwnerProof(r, secret, now), "invalid_owner_proof");
  for (const [k, v] of Object.entries(await ownerProofHeaders(r, secret, now)))
    r.headers.set(k, v);
  await rejects(verifyOwnerProof(r, opaque(), now), "invalid_owner_proof");
});
test("account web bridge signs server-selected native session and never proxies MCP or caller URLs", async () => {
  const seen = [],
    bridge = createAccountWebAIBridge({
      origin,
      accountOrigin,
      secret,
      now: () => now,
      fetcher: async (r) => {
        await verifyOwnerProof(r, secret, now);
        seen.push(r);
        return Response.json({ status: "approved" });
      },
    }),
    session = { access_token: "verified.native.jwt", user: { id } };
  assert.equal(
    (
      await bridge({
        session,
        path: "/plans/" + id + "/approve",
        method: "POST",
        body: { csrf: "checked", contentHash: "approved" },
      })
    ).data.status,
    "approved",
  );
  assert.equal(seen[0].headers.get("Origin"), accountOrigin);
  assert.equal(
    seen[0].headers.get("Authorization"),
    "Bearer verified.native.jwt",
  );
  for (const path of [
    "/mcp",
    "/oauth/token",
    "https://attacker.invalid/",
    "/plans/%2e%2e/oauth/token",
  ])
    await rejects(bridge({ session, path }), "invalid_owner_route");
  assert.equal(seen.length, 1);
});
