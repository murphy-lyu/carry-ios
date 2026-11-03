import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { Readable } from "node:stream";
import { randomUUID } from "node:crypto";
import { createAccountAIHandler } from "./worker.mjs";
import { syntheticStore } from "./synthetic-store.mjs";
import { challenge, AIFailure } from "./security.mjs";

test("actual loopback HTTP executes authorization, PKCE, MCP plan and revocation without phone or upstream IO", async () => {
  const origin = "https://synthetic-ai.invalid",
    accountOrigin = "https://synthetic-account.invalid",
    accountID = randomUUID(),
    sessionID = randomUUID();
  const store = syntheticStore({ accountID, sessionID });
  const handler = createAccountAIHandler({
    store,
    origin,
    accountOrigin,
    synthetic: true,
    firstParty: {
      authenticate: async (request) => {
        if (request.headers.get("Authorization") !== "Bearer synthetic-owner")
          throw new AIFailure(401, "unauthorized");
        return { accountID, sessionID };
      },
      verifyCSRF: async (request) => {
        if (request.headers.get("X-CSRF") !== "synthetic-proof")
          throw new AIFailure(403, "csrf_mismatch");
      },
    },
  });
  let requests = 0;
  const server = createServer(async (incoming, outgoing) => {
    requests++;
    try {
      const options = { method: incoming.method, headers: incoming.headers };
      if (!["GET", "HEAD"].includes(incoming.method)) {
        options.body = Readable.toWeb(incoming);
        options.duplex = "half";
      }
      const response = await handler(
        new Request(origin + incoming.url, options),
      );
      outgoing.writeHead(response.status, Object.fromEntries(response.headers));
      if (response.body) {
        for await (const chunk of response.body) outgoing.write(chunk);
      }
      outgoing.end();
    } catch {
      outgoing.writeHead(500).end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = "http://127.0.0.1:" + server.address().port;
  const call = (path, options) =>
    fetch(base + path, { redirect: "manual", ...options });
  const post = (body, headers = {}) => ({
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  try {
    const registration = await call(
      "/oauth/register",
      post({
        client_name: "Synthetic HTTP Codex",
        redirect_uris: ["http://127.0.0.1:39999/callback"],
      }),
    );
    assert.equal(registration.status, 201);
    const client = (await registration.json()).client_id,
      verifier = "a".repeat(43);
    const authorization = await call(
      "/oauth/authorize?" +
        new URLSearchParams({
          client_id: client,
          redirect_uri: "http://127.0.0.1:39999/callback",
          response_type: "code",
          code_challenge: await challenge(verifier),
          code_challenge_method: "S256",
          scope: "trips:read trips:write trips:create",
          state: "synthetic-state",
          resource: origin + "/mcp",
        }),
    );
    assert.equal(authorization.status, 303);
    const authID = new URL(
      authorization.headers.get("Location"),
    ).searchParams.get("authorization_id");
    const approval = await call(
      "/oauth/requests/" + authID,
      post(
        {
          decision: "approve",
          scopes: ["trips:read", "trips:write", "trips:create"],
          tripIDs: [],
          onlyCreated: true,
          csrf: "proof",
        },
        {
          Authorization: "Bearer synthetic-owner",
          Origin: accountOrigin,
          "X-CSRF": "synthetic-proof",
        },
      ),
    );
    assert.equal(approval.status, 303);
    const code = new URL(approval.headers.get("Location")).searchParams.get(
      "code",
    );
    const token = await call("/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: client,
        resource: origin + "/mcp",
        redirect_uri: "http://127.0.0.1:39999/callback",
        code,
        code_verifier: verifier,
      }),
    });
    assert.equal(token.status, 200);
    const access = (await token.json()).access_token;
    const requestID = randomUUID(),
      rpc = (name, args) =>
        call(
          "/mcp",
          post(
            {
              jsonrpc: "2.0",
              id: 1,
              method: "tools/call",
              params: { name, arguments: args },
            },
            { Authorization: "Bearer " + access },
          ),
        );
    const written = await rpc("apply_changes", {
      requestID,
      operations: [
        {
          action: "create_trip",
          fields: { name: "HTTP synthetic trip", days: 1 },
        },
      ],
    });
    assert.equal(written.status, 200);
    const receipt = (await written.json()).result.structuredContent;
    assert.equal(receipt.status, "saved_to_account");
    assert.equal(receipt.deviceState, "not_observed");
    const read = await rpc("list_trips", {});
    assert.equal(
      (await read.json()).result.structuredContent.entities[0].fields.name,
      "HTTP synthetic trip",
    );
    const revoked = await call("/oauth/revoke", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: client, token: access }),
    });
    assert.equal(revoked.status, 200);
    assert.equal((await rpc("list_trips", {})).status, 401);
    assert.equal(store.db.graph.size, 3);
    assert.equal(store.db.receipts.size, 1);
    assert.equal(requests, 8);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});
