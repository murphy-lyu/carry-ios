import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createAccountAIHandler } from "./worker.mjs";
import { syntheticStore } from "./synthetic-store.mjs";
import { challenge, AIFailure } from "./security.mjs";
import { defaults, compilePlan } from "./domain.mjs";
const origin = "https://connect-qa.invalid",
  accountOrigin = "https://account-qa.invalid",
  resource = origin + "/mcp",
  redirect = "http://127.0.0.1:49321/callback";
const accountID = randomUUID(),
  sessionID = randomUUID(),
  tripID = randomUUID(),
  otherTripID = randomUUID(),
  dayID = randomUUID(),
  now = Date.parse("2026-10-30T12:00:00Z");
const entity = (kind, id, parentID = null, fields = {}) => ({
  id,
  kind,
  parentID,
  fields: { ...defaults(kind, now), ...fields },
  version: 1,
  subtreeVersion: 1,
  fieldVersions: Object.fromEntries(
    Object.keys({ ...defaults(kind, now), ...fields }).map((k) => [k, 1]),
  ),
  deletedAt: null,
  deletionBatch: null,
});
async function fixture(extra = {}) {
  let time = now;
  const store = syntheticStore({
    accountID,
    sessionID,
    entities: [
      entity("trip", tripID, null, { name: "Tokyo", days: 2 }),
      entity("day", dayID, tripID),
      entity("trip", otherTripID, null, { name: "Private other trip" }),
    ],
  });
  const firstParty = {
    authenticate: async (request) => {
      if (
        request.headers.get("Authorization") !== "Bearer synthetic-owner" ||
        !store.db.sessions.has(sessionID)
      )
        throw new AIFailure(401, "unauthorized");
      return { accountID, sessionID };
    },
    verifyCSRF: async (request) => {
      if (request.headers.get("X-CSRF") !== "synthetic-csrf")
        throw new AIFailure(403, "csrf_mismatch");
    },
  };
  const handler = createAccountAIHandler({
    store,
    firstParty,
    origin,
    accountOrigin,
    now: () => time,
    synthetic: true,
    ...extra,
  });
  const req = (
    path,
    { method = "GET", body, token, owner = false, headers = {} } = {},
  ) =>
    new Request(origin + path, {
      method,
      headers: {
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
        ...(token ? { Authorization: "Bearer " + token } : {}),
        ...(owner
          ? {
              Authorization: "Bearer synthetic-owner",
              Origin: accountOrigin,
              "X-CSRF": "synthetic-csrf",
            }
          : {}),
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  const registered = await handler(
    req("/oauth/register", {
      method: "POST",
      body: { client_name: "Synthetic Codex", redirect_uris: [redirect] },
    }),
  );
  assert.equal(registered.status, 201);
  const client = (await registered.json()).client_id;
  const authorize = async ({
    requestedScopes = "trips:read trips:write trips:create",
    redirectURI = redirect,
    resourceURI = resource,
    verifier = "v".repeat(43),
  } = {}) => {
    const params = new URLSearchParams({
      client_id: client,
      redirect_uri: redirectURI,
      response_type: "code",
      code_challenge: await challenge(verifier),
      code_challenge_method: "S256",
      scope: requestedScopes,
      state: "synthetic-state",
      resource: resourceURI,
    });
    const response = await handler(req("/oauth/authorize?" + params));
    return {
      response,
      id:
        response.headers.get("Location") &&
        new URL(response.headers.get("Location")).searchParams.get(
          "authorization_id",
        ),
      verifier,
    };
  };
  const approve = async (
    flow,
    {
      selectedScopes = ["trips:read", "trips:write", "trips:create"],
      tripIDs = [tripID],
      onlyCreated = false,
      headers = {},
    } = {},
  ) => {
    const response = await handler(
      req("/oauth/requests/" + flow.id, {
        method: "POST",
        owner: true,
        headers,
        body: {
          decision: "approve",
          csrf: "body-is-not-authority",
          scopes: selectedScopes,
          tripIDs,
          onlyCreated,
        },
      }),
    );
    return {
      response,
      code:
        response.headers.get("Location") &&
        new URL(response.headers.get("Location")).searchParams.get("code"),
    };
  };
  const token = async (
    code,
    verifier,
    { clientID = client, redirectURI = redirect, resourceURI = resource } = {},
  ) =>
    handler(
      new Request(origin + "/oauth/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          client_id: clientID,
          redirect_uri: redirectURI,
          resource: resourceURI,
          code,
          code_verifier: verifier,
        }),
      }),
    );
  const connect = async (options) => {
    const flow = await authorize(options),
      approved = await approve(flow, options);
    assert.equal(approved.response.status, 303);
    const result = await token(approved.code, flow.verifier);
    assert.equal(result.status, 200);
    return { ...(await result.json()), flow, approved };
  };
  const tool = async (access, name, args = {}) => {
    const response = await handler(
      req("/mcp", {
        method: "POST",
        token: access,
        body: {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name, arguments: args },
        },
      }),
    );
    const data = await response.json();
    return { response, data, result: data.result?.structuredContent };
  };
  const approvePlan = async (result) =>
    handler(
      req("/plans/" + result.previewID + "/approve", {
        method: "POST",
        owner: true,
        body: {
          csrf: "body-is-not-authority",
          contentHash: result.contentHash,
        },
      }),
    );
  return {
    store,
    handler,
    req,
    client,
    authorize,
    approve,
    token,
    connect,
    tool,
    approvePlan,
    setTime: (value) => {
      time = value;
    },
  };
}
test("non-durable store needs an explicit synthetic opt-in", async () => {
  const f = await fixture();
  assert.throws(
    () =>
      createAccountAIHandler({
        store: f.store,
        firstParty: { authenticate() {}, verifyCSRF() {} },
        origin,
        accountOrigin,
      }),
    /durable_store_required/,
  );
});
test("discovery binds exact resource, S256 and an unauthenticated resource challenge", async () => {
  const f = await fixture();
  assert.equal(
    (
      await (
        await f.handler(f.req("/.well-known/oauth-protected-resource/mcp"))
      ).json()
    ).resource,
    resource,
  );
  assert.deepEqual(
    (
      await (
        await f.handler(f.req("/.well-known/oauth-authorization-server"))
      ).json()
    ).code_challenge_methods_supported,
    ["S256"],
  );
  const r = await f.handler(f.req("/mcp", { method: "POST", body: {} }));
  assert.equal(r.status, 401);
  assert.match(r.headers.get("WWW-Authenticate"), /resource_metadata=/);
});
test("redirect and resource mismatch never create an authorization or unsafe redirect", async () => {
  const f = await fixture();
  for (const options of [
    { redirectURI: "http://127.0.0.1:49322/callback" },
    { redirectURI: redirect + "?x=1" },
    { resourceURI: origin + "/other" },
  ]) {
    const flow = await f.authorize(options);
    assert.equal(flow.response.status, 400);
    assert.equal(flow.response.headers.get("Location"), null);
  }
  assert.equal(f.store.db.authorizations.size, 0);
});
test("PKCE code is single-use and bound to client, redirect and resource", async () => {
  const f = await fixture(),
    flow = await f.authorize(),
    a = await f.approve(flow);
  for (const [verifier, options] of [
    ["x".repeat(43), {}],
    [flow.verifier, { clientID: randomUUID() }],
    [flow.verifier, { redirectURI: redirect + "?x=1" }],
    [flow.verifier, { resourceURI: origin + "/other" }],
  ])
    assert.equal((await f.token(a.code, verifier, options)).status, 400);
  assert.equal((await f.token(a.code, flow.verifier)).status, 200);
  assert.equal((await f.token(a.code, flow.verifier)).status, 400);
  assert.equal(f.store.db.access.size, 1);
});
test("only current first-party session plus exact origin and CSRF approve a grant", async () => {
  const f = await fixture(),
    flow = await f.authorize();
  assert.equal(
    (
      await f.handler(
        f.req("/oauth/requests/" + flow.id, {
          method: "POST",
          body: { decision: "approve" },
        }),
      )
    ).status,
    401,
  );
  assert.equal(
    (await f.approve(flow, { headers: { Origin: "https://evil.invalid" } }))
      .response.status,
    403,
  );
  assert.equal(
    (await f.approve(flow, { headers: { "X-CSRF": "wrong" } })).response.status,
    403,
  );
  assert.equal(f.store.db.grants.size, 0);
  f.store.db.sessions.delete(sessionID);
  assert.equal((await f.approve(flow)).response.status, 401);
});
test("scope escalation, unowned trips and invalid only-created selection fail", async () => {
  const f = await fixture(),
    flow = await f.authorize();
  for (const options of [
    { selectedScopes: ["trips:read", "attachments:read"] },
    { tripIDs: [randomUUID()] },
    { onlyCreated: true, tripIDs: [tripID] },
    { selectedScopes: ["trips:write"] },
  ])
    assert.ok(
      [400, 403].includes((await f.approve(flow, options)).response.status),
    );
  assert.equal(f.store.db.grants.size, 0);
});
test("Codex refresh omits resource and repeats the original scope without broadening it", async () => {
  const f = await fixture(), s = await f.connect();
  const refresh = (extra = {}) => f.handler(new Request(origin + "/oauth/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: f.client,
      refresh_token: s.refresh_token, scope: s.scope, ...extra }),
  }));
  assert.equal((await refresh({resource:origin+'/wrong'})).status,400);
  assert.equal((await refresh({scope:'trips:read library:read'})).status,400);
  assert.equal((await refresh({scope:'trips:read'})).status,400);
  const response = await refresh();
  assert.equal(response.status,200);
  const next = await response.json();
  assert.equal(next.scope,s.scope);
  assert.equal((await f.tool(next.access_token,'list_trips')).response.status,200);
});
test("refresh rotates once and reuse revokes old and replacement access tokens", async () => {
  const f = await fixture(),
    s = await f.connect();
  const refresh = () =>
    f.handler(
      new Request(origin + "/oauth/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "refresh_token",
          client_id: f.client,
          resource,
          refresh_token: s.refresh_token,
        }),
      }),
    );
  const r = await refresh();
  assert.equal(r.status, 200);
  const next = await r.json();
  assert.equal(
    (await f.tool(next.access_token, "list_trips")).response.status,
    200,
  );
  assert.equal((await refresh()).status, 400);
  assert.equal(
    (await f.tool(next.access_token, "list_trips")).response.status,
    401,
  );
  assert.equal(
    (await f.tool(s.access_token, "list_trips")).response.status,
    401,
  );
});
test("expiry, account deletion and explicit grant revocation reject subsequent requests", async () => {
  for (const action of ["expiry", "delete", "revoke"]) {
    const f = await fixture(),
      s = await f.connect();
    if (action === "expiry") f.setTime(now + 16 * 60000);
    else if (action === "delete") f.store.db.accountActive = false;
    else {
      const g = [...f.store.db.grants.values()][0];
      assert.equal(
        (
          await f.handler(
            f.req("/connections/" + g.id + "/revoke", {
              method: "POST",
              owner: true,
              body: { csrf: "ignored" },
            }),
          )
        ).status,
        200,
      );
    }
    assert.equal(
      (await f.tool(s.access_token, "list_trips")).response.status,
      401,
    );
  }
});
test("only-created connection binds new complete trip atomically without exposing prior trips", async () => {
  const f = await fixture(),
    s = await f.connect({ onlyCreated: true, tripIDs: [] });
  assert.deepEqual(
    (await f.tool(s.access_token, "list_trips")).result.entities,
    [],
  );
  const result = await f.tool(s.access_token, "apply_changes", {
    requestID: randomUUID(),
    operations: [
      { action: "create_trip", fields: { name: "New trip", days: 1 } },
    ],
  });
  assert.equal(result.result.status, "saved_to_account");
  assert.equal(result.result.deviceState, "not_observed");
  assert.equal(result.result.changes.length, 3);
  assert.equal(
    (await f.tool(s.access_token, "list_trips")).result.entities.length,
    1,
  );
  assert.equal(
    (await f.tool(s.access_token, "get_trip", { tripID })).response.status,
    403,
  );
});
test("Codex MCP transport metadata is bounded and cannot grant access to existing trips", async () => {
  const f = await fixture(), s = await f.connect({ onlyCreated: true, tripIDs: [] });
  const call = async (meta, name = "list_trips", args = {}) => {
    const r = await f.handler(f.req("/mcp", {
      method: "POST", token: s.access_token,
      body: { jsonrpc: "2.0", id: 42, method: "tools/call",
        params: { name, arguments: args, _meta: meta } },
    }));
    return { status: r.status, body: await r.json() };
  };
  const meta = { threadId: "synthetic-codex-thread", progressToken: 0,
    scopes: ["trips:read"], tripIDs: [tripID], onlyCreated: false,
    accountID: "spoofed-account" };
  const list = await call(meta);
  assert.equal(list.status, 200);
  assert.deepEqual(list.body.result.structuredContent.entities, []);
  assert.equal((await call(meta, "get_trip", { tripID })).status, 403);
  for (const invalid of [null, [], "metadata", Object.fromEntries(Array.from({length:65},(_,i)=>[String(i),0])), {x:"x".repeat(16384)}]) {
    assert.equal((await call(invalid)).status, 400);
  }
});
test("ordinary account writes are exactly once without any phone, with changed reuse rejected", async () => {
  const f = await fixture(),
    s = await f.connect(),
    requestID = randomUUID();
  const args = {
    requestID,
    operations: [
      {
        action: "patch",
        kind: "trip",
        id: tripID,
        baseVersion: 1,
        fields: { name: "Changed" },
      },
    ],
  };
  const a = await f.tool(s.access_token, "apply_changes", args),
    b = await f.tool(s.access_token, "apply_changes", args);
  assert.equal(a.result.status, "saved_to_account");
  assert.deepEqual(a.result, b.result);
  assert.equal(f.store.db.graph.get(tripID).version, 2);
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        ...args,
        operations: [{ ...args.operations[0], fields: { name: "Different" } }],
      })
    ).response.status,
    409,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        requestID: randomUUID(),
        operations: [{ ...args.operations[0], id: otherTripID }],
      })
    ).response.status,
    403,
  );
});
test("destructive preview needs exact owner approval, never an AI confirmed flag", async () => {
  const f = await fixture(),
    s = await f.connect(),
    requestID = randomUUID();
  const p = await f.tool(s.access_token, "apply_changes", {
    requestID,
    operations: [
      {
        action: "delete",
        kind: "trip",
        id: tripID,
        baseVersion: 1,
        baseSubtreeVersion: 1,
      },
    ],
  });
  assert.equal(p.result.status, "awaiting_user_approval");
  assert.equal(f.store.db.graph.get(tripID).deletedAt, null);
  assert.equal(
    (
      await f.tool(s.access_token, "commit_plan", {
        requestID,
        previewID: p.result.previewID,
        confirmed: true,
      })
    ).response.status,
    400,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "commit_plan", {
        requestID,
        previewID: p.result.previewID,
      })
    ).response.status,
    403,
  );
  assert.equal((await f.approvePlan(p.result)).status, 200);
  const saved = await f.tool(s.access_token, "commit_plan", {
    requestID,
    previewID: p.result.previewID,
  });
  assert.equal(saved.result.status, "saved_to_account");
  assert.ok(f.store.db.graph.get(tripID).deletedAt);
  assert.deepEqual(
    (
      await f.tool(s.access_token, "commit_plan", {
        requestID,
        previewID: p.result.previewID,
      })
    ).result,
    saved.result,
  );
});
test("late version conflict rolls back whole plan and receipt", async () => {
  const f = await fixture(),
    s = await f.connect(),
    requestID = randomUUID();
  const p = await f.tool(s.access_token, "preview_plan", {
    requestID,
    operations: [
      {
        action: "patch",
        kind: "trip",
        id: tripID,
        baseVersion: 1,
        fields: { name: "Must roll back" },
      },
      {
        action: "patch",
        kind: "day",
        id: dayID,
        baseVersion: 1,
        fields: { title: "New day" },
      },
    ],
  });
  await f.approvePlan(p.result);
  f.store.db.graph.get(dayID).fieldVersions.title = 2;
  f.store.db.graph.get(dayID).version = 2;
  assert.equal(
    (
      await f.tool(s.access_token, "commit_plan", {
        requestID,
        previewID: p.result.previewID,
      })
    ).response.status,
    409,
  );
  assert.equal(f.store.db.graph.get(tripID).fields.name, "Tokyo");
  assert.equal(f.store.db.receipts.size, 0);
});
test("private details and files are neither exposed nor editable without separate scopes", async () => {
  const f = await fixture(),
    s = await f.connect(),
    stopID = randomUUID(),
    attachmentID = randomUUID(),
    assetID = randomUUID(),
    lodgingID = randomUUID();
  f.store.db.graph.set(stopID, entity("stop", stopID, dayID, { name: "Park" }));
  f.store.db.graph.set(
    attachmentID,
    entity("attachment", attachmentID, stopID, {
      displayName: "Secret file",
      fileAssetID: assetID,
    }),
  );
  f.store.db.graph.set(
    lodgingID,
    entity("lodging", lodgingID, tripID, {
      confirmationCode: "private-secret",
    }),
  );
  assert.doesNotMatch(
    JSON.stringify(
      (await f.tool(s.access_token, "get_trip", { tripID })).result,
    ),
    /Secret file|private-secret|fileAssetID/,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        requestID: randomUUID(),
        operations: [
          {
            action: "patch",
            kind: "lodging",
            id: lodgingID,
            baseVersion: 1,
            fields: { confirmationCode: "new-secret" },
          },
        ],
      })
    ).response.status,
    403,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "read_attachment", {
        tripID,
        assetID,
        offset: 0,
        limit: 100,
      })
    ).response.status,
    403,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        requestID: randomUUID(),
        operations: [
          {
            action: "delete",
            kind: "trip",
            id: tripID,
            baseVersion: 1,
            baseSubtreeVersion: 1,
          },
        ],
      })
    ).response.status,
    403,
  );
});
test("undo is a new approved version-bound transaction and never overwrites later edits", async () => {
  for (const later of [false, true]) {
    const f = await fixture(),
      s = await f.connect(),
      operationID = randomUUID();
    await f.tool(s.access_token, "apply_changes", {
      requestID: operationID,
      operations: [
        {
          action: "patch",
          kind: "trip",
          id: tripID,
          baseVersion: 1,
          fields: { name: "AI edit" },
        },
      ],
    });
    if (later) {
      f.store.db.graph.get(tripID).version++;
      f.store.db.graph.get(tripID).fields.name = "Later phone edit";
    }
    const requestID = randomUUID(),
      undo = await f.tool(s.access_token, "undo_operation", {
        requestID,
        operationID,
      });
    if (later) {
      assert.equal(undo.response.status, 409);
      assert.equal(
        f.store.db.graph.get(tripID).fields.name,
        "Later phone edit",
      );
      continue;
    }
    assert.equal(undo.result.status, "awaiting_user_approval");
    await f.approvePlan(undo.result);
    assert.equal(
      (
        await f.tool(s.access_token, "commit_plan", {
          requestID,
          previewID: undo.result.previewID,
        })
      ).result.status,
      "saved_to_account",
    );
    assert.equal(f.store.db.graph.get(tripID).fields.name, "Tokyo");
  }
});
test("unknown fields/account-ID injection and cross-site MCP fail closed", async () => {
  const f = await fixture(),
    s = await f.connect();
  assert.equal(
    (
      await f.tool(s.access_token, "get_trip", {
        tripID,
        accountID: randomUUID(),
      })
    ).response.status,
    400,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        requestID: randomUUID(),
        operations: [
          {
            action: "patch",
            kind: "trip",
            id: tripID,
            baseVersion: 1,
            fields: { healthData: "secret" },
          },
        ],
      })
    ).response.status,
    400,
  );
  assert.equal(
    (
      await f.handler(
        f.req("/mcp", {
          method: "POST",
          token: s.access_token,
          headers: { Origin: "https://evil.invalid" },
          body: { jsonrpc: "2.0", id: 1, method: "initialize" },
        }),
      )
    ).status,
    403,
  );
  assert.equal(
    (await f.tool(s.access_token, "unknown", {})).response.status,
    404,
  );
});
test("domain preserves zero/sentinel costs and deterministic copy IDs and rejects incomplete ordering", async () => {
  const f = await fixture(),
    s = await f.connect(),
    grant = [...f.store.db.grants.values()][0],
    stopID = randomUUID();
  f.store.db.graph.set(
    stopID,
    entity("stop", stopID, dayID, {
      name: "Free park",
      costAmount: 0,
      costHomeAmount: -1,
    }),
  );
  const requestID = randomUUID(),
    operations = [
      {
        action: "duplicate_trip",
        id: tripID,
        baseVersion: 1,
        baseSubtreeVersion: 1,
        fields: { name: "Copy" },
      },
    ];
  const a = await compilePlan({
      requestID,
      operations,
      entities: [...f.store.db.graph.values()],
      grant,
      now,
    }),
    b = await compilePlan({
      requestID,
      operations,
      entities: [...f.store.db.graph.values()],
      grant,
      now,
    });
  assert.deepEqual(a, b);
  assert.equal(a.requiresApproval, true);
  assert.equal(
    a.command.mutations.find((m) => m.kind === "stop").fields.costAmount,
    0,
  );
  assert.equal(
    a.command.mutations.find((m) => m.kind === "stop").fields.costHomeAmount,
    -1,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        requestID: randomUUID(),
        operations: [
          {
            action: "reorder",
            kind: "day",
            id: dayID,
            baseVersion: 1,
            baseSubtreeVersion: 1,
            ids: [],
            data: { childKind: "stop" },
          },
        ],
      })
    ).response.status,
    400,
  );
});

test("complete plan references resolve deterministic days and children without prior phone or account writes", async () => {
  const f = await fixture(),
    s = await f.connect({ onlyCreated: true, tripIDs: [] }),
    requestID = randomUUID();
  const operations = [
    {
      action: "create_trip",
      ref: "japan",
      fields: { name: "Japan trip", days: 2 },
    },
    {
      action: "create",
      kind: "stop",
      ref: "museum",
      parentID: "@japan/day/1",
      fields: {
        name: "Museum",
        timeZoneId: "Asia/Tokyo",
        plannedStartMinutes: 600,
      },
    },
    {
      action: "create",
      kind: "section",
      ref: "essentials",
      parentID: "@japan",
      fields: { title: "Essentials" },
    },
    {
      action: "create",
      kind: "packingItem",
      parentID: "@essentials",
      fields: { name: "Passport", quantity: 1 },
    },
  ];
  const p = await f.tool(s.access_token, "preview_plan", {
    requestID,
    operations,
  });
  assert.equal(p.result.status, "awaiting_user_approval");
  assert.equal(f.store.db.receipts.size, 0);
  assert.equal(
    p.result.summary.actions.find((a) => a.kind === "stop").after.name,
    "Museum",
  );
  await f.approvePlan(p.result);
  assert.equal(
    (
      await f.tool(s.access_token, "commit_plan", {
        requestID,
        previewID: p.result.previewID,
      })
    ).result.status,
    "saved_to_account",
  );
  const trip = [...f.store.db.graph.values()].find(
      (e) => e.fields.name === "Japan trip",
    ),
    stop = [...f.store.db.graph.values()].find(
      (e) => e.fields.name === "Museum",
    );
  assert.equal(f.store.db.graph.get(stop.parentID).fields.sortOrder, 1);
  assert.equal(f.store.db.graph.get(stop.parentID).parentID, trip.id);
  assert.equal(
    [...f.store.db.graph.values()].filter(
      (e) => e.kind === "day" && e.parentID === trip.id,
    ).length,
    3,
  );
});
test("canonical request retries tolerate object key order without a second write", async () => {
  const f = await fixture(),
    s = await f.connect(),
    requestID = randomUUID();
  const a = await f.tool(s.access_token, "apply_changes", {
    requestID,
    operations: [
      {
        action: "patch",
        kind: "trip",
        id: tripID,
        baseVersion: 1,
        fields: { name: "Same", destinationCity: "Tokyo" },
      },
    ],
  });
  const b = await f.tool(s.access_token, "apply_changes", {
    requestID,
    operations: [
      {
        fields: { destinationCity: "Tokyo", name: "Same" },
        baseVersion: 1,
        id: tripID,
        kind: "trip",
        action: "patch",
      },
    ],
  });
  assert.deepEqual(a.result, b.result);
  assert.equal(f.store.db.graph.get(tripID).version, 2);
});
test("preview shows exact permitted before/after values and stored client destination for user review", async () => {
  const f = await fixture(),
    s = await f.connect(),
    requestID = randomUUID();
  const p = await f.tool(s.access_token, "preview_plan", {
    requestID,
    operations: [
      {
        action: "patch",
        kind: "trip",
        id: tripID,
        baseVersion: 1,
        fields: { name: "Osaka" },
      },
    ],
  });
  assert.equal(p.result.summary.actions[0].before.name, "Tokyo");
  assert.equal(p.result.summary.actions[0].after.name, "Osaka");
  const request = await f.handler(
    f.req("/oauth/requests/" + s.flow.id, { owner: true }),
  );
  const details = await request.json();
  assert.equal(details.client.redirectURI, redirect);
  assert.equal(details.client.id, f.client);
});
test("read-only grants cannot alter trips, unauthorized receipts or empty cross-account selection", async () => {
  const f = await fixture(),
    s = await f.connect({
      requestedScopes: "trips:read",
      selectedScopes: ["trips:read"],
    });
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        requestID: randomUUID(),
        operations: [
          {
            action: "patch",
            kind: "trip",
            id: tripID,
            baseVersion: 1,
            fields: { name: "No" },
          },
        ],
      })
    ).response.status,
    403,
  );
  assert.equal(
    (await f.tool(s.access_token, "get_operation", { requestID: randomUUID() }))
      .response.status,
    404,
  );
});
test("one preview cannot be committed through a different connection even for the same account", async () => {
  const f = await fixture(),
    a = await f.connect(),
    b = await f.connect(),
    requestID = randomUUID();
  const p = await f.tool(a.access_token, "preview_plan", {
    requestID,
    operations: [
      {
        action: "patch",
        kind: "trip",
        id: tripID,
        baseVersion: 1,
        fields: { name: "Bound" },
      },
    ],
  });
  await f.approvePlan(p.result);
  assert.equal(
    (
      await f.tool(b.access_token, "commit_plan", {
        requestID,
        previewID: p.result.previewID,
      })
    ).response.status,
    403,
  );
  assert.equal(f.store.db.graph.get(tripID).fields.name, "Tokyo");
});
test("registration rejects unsafe redirects and token forms reject duplicate fields", async () => {
  const f = await fixture();
  for (const redirectURI of [
    "https://evil.invalid/#fragment",
    "javascript:alert(1)",
    "https://user:pass@evil.invalid/cb",
  ]) {
    assert.equal(
      (
        await f.handler(
          f.req("/oauth/register", {
            method: "POST",
            body: { client_name: "Bad", redirect_uris: [redirectURI] },
          }),
        )
      ).status,
      400,
    );
  }
  const response = await f.handler(
    new Request(origin + "/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: "grant_type=authorization_code&client_id=a&client_id=b&resource=x",
    }),
  );
  assert.equal(response.status, 400);
});
test("captured Codex native registration metadata is accepted without issuing a grant", async () => {
  const f = await fixture();
  const result = await f.handler(f.req("/oauth/register", { method: "POST", body: {
    client_name: "Codex", redirect_uris: ["http://127.0.0.1:49321/callback/synthetic"],
    grant_types: ["authorization_code", "refresh_token"],
    token_endpoint_auth_method: "none", response_types: ["code"], application_type: "native",
  } }));
  assert.equal(result.status, 201);
  const metadata = await result.json();
  assert.equal(metadata.application_type, "native");
  assert.equal(metadata.token_endpoint_auth_method, "none");
  assert.equal(f.store.db.clients.get(metadata.client_id).applicationType, "native");
  assert.equal(f.store.db.grants.size, 0);
});
test("unknown registration metadata is discarded and cannot select identity or grant access", async () => {
  const f = await fixture(), suppliedID = randomUUID();
  const result = await f.handler(f.req("/oauth/register", { method: "POST", body: {
    client_name: "Unverified client", redirect_uris: [redirect], application_type: "web",
    client_id: suppliedID, owner: accountID, confirmed: true, scopes: ["private:read"],
    client_uri: "http://127.0.0.1/private", arbitrary_extension: { unsafe: true },
  } }));
  assert.equal(result.status, 201);
  const metadata = await result.json(), stored = f.store.db.clients.get(metadata.client_id);
  assert.notEqual(metadata.client_id, suppliedID);
  for (const key of ["owner", "confirmed", "scopes", "client_uri", "arbitrary_extension"])
    assert.equal(Object.hasOwn(stored, key), false);
  assert.equal(f.store.db.grants.size, 0);
});
test("supported registration metadata still rejects invalid application and authentication values", async () => {
  const f = await fixture();
  for (const extra of [{application_type:"other"},{application_type:{}},
    ...["client_secret_basic", null, false, 0, ""].map(value => ({token_endpoint_auth_method:value}))]) {
    const result = await f.handler(f.req("/oauth/register", {method:"POST",body:{client_name:"Invalid",redirect_uris:[redirect],...extra}}));
    assert.equal(result.status,400);
  }
});
test("revoking a token for the wrong client does not revoke the original connection", async () => {
  const f = await fixture(),
    s = await f.connect();
  const revoke = (client) =>
    f.handler(
      new Request(origin + "/oauth/revoke", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ client_id: client, token: s.access_token }),
      }),
    );
  assert.equal((await revoke(randomUUID())).status, 200);
  assert.equal(
    (await f.tool(s.access_token, "list_trips")).response.status,
    200,
  );
  assert.equal((await revoke(f.client)).status, 200);
  assert.equal(
    (await f.tool(s.access_token, "list_trips")).response.status,
    401,
  );
});

test("complete ten-kind plan compiles scopes and relationships in one immutable command", async () => {
  const f = await fixture(),
    scope = [
      "trips:read",
      "trips:write",
      "trips:create",
      "library:read",
      "library:write",
      "attachments:read",
      "attachments:write",
      "preferences:read",
      "preferences:write",
      "private:read",
      "private:write",
      "exports:read",
    ];
  const s = await f.connect({
      requestedScopes: scope.join(" "),
      selectedScopes: scope,
    }),
    grant = [...f.store.db.grants.values()][0];
  const compiled = await compilePlan({
    requestID: randomUUID(),
    grant,
    now,
    entities: [...f.store.db.graph.values()],
    operations: [
      {
        action: "create_trip",
        ref: "trip",
        fields: { name: "Complete", days: 1 },
      },
      {
        action: "create",
        kind: "section",
        ref: "packing",
        parentID: "@trip",
        fields: { title: "Packing" },
      },
      {
        action: "create",
        kind: "packingItem",
        parentID: "@packing",
        fields: { name: "Passport" },
      },
      {
        action: "create",
        kind: "stop",
        ref: "place",
        parentID: "@trip/day/0",
        fields: { name: "Museum", timeZoneId: "Asia/Tokyo" },
      },
      {
        action: "create",
        kind: "transport",
        parentID: "@trip/day/0",
        fields: {
          modeRaw: "flight",
          fromTimeZoneId: "Asia/Shanghai",
          toTimeZoneId: "Asia/Tokyo",
        },
      },
      {
        action: "create",
        kind: "lodging",
        ref: "hotel",
        parentID: "@trip",
        fields: { name: "Hotel", confirmationCode: "Synthetic-booking" },
      },
      {
        action: "create",
        kind: "photo",
        parentID: "@place",
        fields: { thumbnailAssetID: randomUUID() },
      },
      {
        action: "create",
        kind: "attachment",
        parentID: "@hotel",
        fields: { fileAssetID: randomUUID(), displayName: "Synthetic file" },
      },
      { action: "create", kind: "libraryItem", fields: { name: "Charger" } },
    ],
  });
  assert.deepEqual(
    [...new Set(compiled.command.mutations.map((m) => m.kind))].sort(),
    [
      "trip",
      "day",
      "section",
      "packingItem",
      "stop",
      "transport",
      "lodging",
      "photo",
      "attachment",
      "libraryItem",
    ].sort(),
  );
  assert.equal(
    (await f.tool(s.access_token, "list_capabilities")).result
      .executionRequiresPhone,
    false,
  );
});
test("final commit rechecks narrowed attachment scope instead of trusting a previously approved preview", async () => {
  const f = await fixture(),
    scope = [
      "trips:read",
      "trips:write",
      "trips:create",
      "attachments:read",
      "attachments:write",
    ];
  const s = await f.connect({
      requestedScopes: scope.join(" "),
      selectedScopes: scope,
    }),
    stopID = randomUUID();
  f.store.db.graph.set(stopID, entity("stop", stopID, dayID));
  const requestID = randomUUID(),
    p = await f.tool(s.access_token, "preview_plan", {
      requestID,
      operations: [
        {
          action: "create",
          kind: "attachment",
          parentID: stopID,
          fields: { displayName: "Must not create", fileAssetID: randomUUID() },
        },
      ],
    });
  await f.approvePlan(p.result);
  [...f.store.db.grants.values()][0].scopes = scope.filter(
    (s) => s !== "attachments:write",
  );
  assert.equal(
    (
      await f.tool(s.access_token, "commit_plan", {
        requestID,
        previewID: p.result.previewID,
      })
    ).response.status,
    403,
  );
  assert.equal(f.store.db.receipts.size, 0);
});
test("pagination is bounded and a changed trip subtree cannot silently continue an old page", async () => {
  const f = await fixture(),
    s = await f.connect();
  const first = await f.tool(s.access_token, "get_trip", {
    tripID,
    offset: 0,
    limit: 1,
  });
  assert.equal(first.result.entities.length, 1);
  assert.equal(first.result.hasMore, true);
  const second = await f.tool(s.access_token, "get_trip", {
    tripID,
    offset: first.result.nextOffset,
    limit: 1,
    expectedSubtreeVersion: first.result.subtreeVersion,
  });
  assert.equal(second.result.entities.length, 1);
  assert.notEqual(second.result.entities[0].id, first.result.entities[0].id);
  f.store.db.graph.get(tripID).subtreeVersion++;
  assert.equal(
    (
      await f.tool(s.access_token, "get_trip", {
        tripID,
        offset: 1,
        limit: 1,
        expectedSubtreeVersion: first.result.subtreeVersion,
      })
    ).response.status,
    409,
  );
});
test("concurrent exchanges consume one authorization code exactly once", async () => {
  const f = await fixture(),
    flow = await f.authorize(),
    approval = await f.approve(flow);
  const responses = await Promise.all([
    f.token(approval.code, flow.verifier),
    f.token(approval.code, flow.verifier),
  ]);
  assert.deepEqual(responses.map((r) => r.status).sort(), [200, 400]);
  assert.equal(f.store.db.access.size, 1);
});
test("expired authorization/code/preview never create a grant or publish a plan", async () => {
  const f = await fixture(),
    flow = await f.authorize();
  f.setTime(now + 11 * 60000);
  assert.equal((await f.approve(flow)).response.status, 410);
  f.setTime(now);
  const valid = await f.authorize(),
    a = await f.approve(valid);
  f.setTime(now + 61000);
  assert.equal((await f.token(a.code, valid.verifier)).status, 400);
});
test("explicit attachment read exposes only bounded authorized bytes and rechecks the grant each chunk", async () => {
  const f = await fixture(),
    scope = ["trips:read", "attachments:read"],
    s = await f.connect({
      requestedScopes: scope.join(" "),
      selectedScopes: scope,
    }),
    stopID = randomUUID(),
    assetID = randomUUID(),
    attachmentID = randomUUID();
  f.store.db.graph.set(stopID, entity("stop", stopID, dayID));
  f.store.db.graph.set(
    attachmentID,
    entity("attachment", attachmentID, stopID, { fileAssetID: assetID }),
  );
  f.store.readAsset = async () => ({
    bytes: new Uint8Array([1, 2, 3]),
    hasMore: false,
  });
  const read = await f.tool(s.access_token, "read_attachment", {
    tripID,
    assetID,
    offset: 0,
    limit: 3,
  });
  assert.equal(read.result.bytes, "AQID");
  assert.equal(read.result.byteCount, 3);
  assert.equal(
    (
      await f.tool(s.access_token, "read_attachment", {
        tripID,
        assetID: randomUUID(),
        offset: 0,
        limit: 3,
      })
    ).response.status,
    403,
  );
  [...f.store.db.grants.values()][0].revokedAt = now;
  assert.equal(
    (
      await f.tool(s.access_token, "read_attachment", {
        tripID,
        assetID,
        offset: 0,
        limit: 3,
      })
    ).response.status,
    401,
  );
});

test("retrying an immutable preview after time advances returns the original reviewed values and digest", async () => {
  const f = await fixture(),
    s = await f.connect(),
    requestID = randomUUID(),
    args = {
      requestID,
      operations: [
        { action: "create_trip", fields: { name: "Stable preview", days: 1 } },
      ],
    };
  const first = await f.tool(s.access_token, "preview_plan", args);
  f.setTime(now + 5000);
  const second = await f.tool(s.access_token, "preview_plan", args);
  assert.deepEqual(second.result, first.result);
  assert.equal((await f.approvePlan(second.result)).status, 200);
  assert.equal(
    (
      await f.tool(s.access_token, "commit_plan", {
        requestID,
        previewID: second.result.previewID,
      })
    ).result.status,
    "saved_to_account",
  );
});

test("a request bound to an explicit preview cannot bypass review through ordinary apply_changes", async () => {
  const f = await fixture(),
    s = await f.connect(),
    requestID = randomUUID(),
    args = {
      requestID,
      operations: [
        {
          action: "patch",
          kind: "trip",
          id: tripID,
          baseVersion: 1,
          fields: { name: "Awaiting approval" },
        },
      ],
    };
  const p = await f.tool(s.access_token, "preview_plan", args);
  assert.equal(p.result.status, "awaiting_user_approval");
  assert.equal(
    (await f.tool(s.access_token, "apply_changes", args)).response.status,
    403,
  );
  assert.equal(f.store.db.graph.get(tripID).fields.name, "Tokyo");
});

test("accepted commit remains idempotent after preview expiry and an accepted undo retry reads receipt", async () => {
  const f = await fixture(),
    s = await f.connect(),
    operationID = randomUUID();
  const p = await f.tool(s.access_token, "preview_plan", {
    requestID: operationID,
    operations: [
      {
        action: "patch",
        id: tripID,
        kind: "trip",
        baseVersion: 1,
        fields: { name: "Reviewed change" },
      },
    ],
  });
  await f.approvePlan(p.result);
  const accepted = await f.tool(s.access_token, "commit_plan", {
    requestID: operationID,
    previewID: p.result.previewID,
  });
  assert.equal(accepted.result.status, "saved_to_account");
  f.store.db.previews.get(p.result.previewID).expiresAt = now - 1;
  assert.deepEqual(
    (
      await f.tool(s.access_token, "commit_plan", {
        requestID: operationID,
        previewID: p.result.previewID,
      })
    ).result,
    accepted.result,
  );
  const requestID = randomUUID(),
    undo = await f.tool(s.access_token, "undo_operation", {
      requestID,
      operationID,
    });
  await f.approvePlan(undo.result);
  const undone = await f.tool(s.access_token, "commit_plan", {
    requestID,
    previewID: undo.result.previewID,
  });
  assert.equal(undone.result.status, "saved_to_account");
  assert.deepEqual(
    (await f.tool(s.access_token, "undo_operation", { requestID, operationID }))
      .result,
    undone.result,
  );
  assert.equal(f.store.db.graph.get(tripID).fields.name, "Tokyo");
});
test("untrusted CF address cannot manufacture separate anonymous rate-limit buckets", async () => {
  const f = await fixture(),
    seen = [];
  f.store.rateLimit = async (p) => {
    seen.push(p.address);
    return true;
  };
  await f.handler(
    f.req("/.well-known/oauth-authorization-server", {
      headers: { "CF-Connecting-IP": "forged-address" },
    }),
  );
  assert.deepEqual(seen, [null]);
});
test("background object maps and original photos retain independent file scope across reads, deletion and duplication", async () => {
  const f = await fixture(),
    s = await f.connect(),
    assetID = randomUUID();
  f.store.db.graph.get(tripID).fields.backgroundAssetIDs = {
    "background:0:0": assetID,
  };
  const read = await f.tool(s.access_token, "get_trip", { tripID });
  assert.equal(
    read.result.entities.find((e) => e.id === tripID).fields.backgroundAssetIDs,
    undefined,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        requestID: randomUUID(),
        operations: [
          {
            action: "delete",
            kind: "trip",
            id: tripID,
            baseVersion: 1,
            baseSubtreeVersion: 1,
          },
        ],
      })
    ).response.status,
    403,
  );
  assert.equal(
    (
      await f.tool(s.access_token, "apply_changes", {
        requestID: randomUUID(),
        operations: [
          {
            action: "patch",
            kind: "trip",
            id: tripID,
            baseVersion: 1,
            fields: { backgroundAssetIDs: { "background:0:0": assetID } },
          },
        ],
      })
    ).response.status,
    403,
  );
  const full = await f.connect({
    requestedScopes:
      "trips:read trips:write trips:create attachments:read attachments:write",
    selectedScopes: [
      "trips:read",
      "trips:write",
      "trips:create",
      "attachments:read",
      "attachments:write",
    ],
  });
  const duplicate = await f.tool(full.access_token, "preview_plan", {
    requestID: randomUUID(),
    operations: [
      {
        action: "duplicate_trip",
        id: tripID,
        baseVersion: 1,
        baseSubtreeVersion: 1,
      },
    ],
  });
  assert.equal(duplicate.result.status, "awaiting_user_approval");
  const compiled = f.store.db.previews.get(duplicate.result.previewID).compiled;
  assert.equal(
    compiled.command.mutations.find((m) => m.kind === "trip").fields
      .backgroundAssetIDs,
    undefined,
  );
  const invalid = await f.tool(full.access_token, "apply_changes", {
    requestID: randomUUID(),
    operations: [
      {
        action: "patch",
        kind: "trip",
        id: tripID,
        baseVersion: 1,
        fields: { backgroundAssetIDs: { "arbitrary-invalid-slot": assetID } },
      },
    ],
  });
  assert.equal(invalid.response.status, 400);
});
