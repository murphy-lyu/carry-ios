import { test } from "node:test";
import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { applyPortableMigrations } from "../carry-account-service/migration-fixture.mjs";
import { createWebHandler } from "../carry-account-web/worker.mjs";
import { createAccountAIRuntime } from "./runtime.mjs";
import { opaque, challenge } from "./security.mjs";
import { aiWebStrings } from "./web-strings.mjs";
import { TOOLS } from "./manifest.mjs";
const accountOrigin = "https://account-qa.invalid",
  origin = "https://connect-qa.invalid",
  project = "https://project-qa.invalid",
  accountID = crypto.randomUUID(),
  sessionID = crypto.randomUUID(),
  now = Date.now();
const token =
  Buffer.from(JSON.stringify({ alg: "HS256" })).toString("base64url") +
  "." +
  Buffer.from(
    JSON.stringify({
      sub: accountID,
      session_id: sessionID,
      iss: project + "/auth/v1",
      exp: Math.floor(now / 1000) + 3600,
    }),
  ).toString("base64url") +
  ".synthetic-verified-by-auth";
async function fixture() {
  const db = new PGlite();
  await db.exec(
    "create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);",
  );
  await db.query("insert into auth.users values($1)", [accountID]);
  await db.query("insert into auth.sessions values($1,$2,null,null)", [
    sessionID,
    accountID,
  ]);
  await applyPortableMigrations(db);
  await db.query("select public.carry_account_enroll($1,$2,$3,$4)", [
    accountID,
    "synthetic-browser-ai",
    "app.nevestudio.carry",
    "encrypted-synthetic",
  ]);
  const user = {
      id: accountID,
      email: "synthetic@example.invalid",
      identities: [{ provider: "apple" }],
      user_metadata: {},
    },
    session = { access_token: token, user },
    secret = opaque();
  const authFetch = async (url, options) => {
    assert.equal(String(url), project + "/auth/v1/user");
    assert.equal(options.headers.Authorization, "Bearer " + token);
    return Response.json(user);
  };
  const handler = createAccountAIRuntime({
    pool: {
      connect: async () => ({
        query: (...args) => db.query(...args),
        release: () => {},
      }),
    },
    jose: { decodeJwt: (value) => JSON.parse(atob(value.split(".")[1])) },
    configuration: {
      origin,
      accountOrigin,
      projectURL: project,
      serviceKey: "synthetic-service-secret",
      ownerBridgeSecret: secret,
    },
    fetcher: authFetch,
    now: () => now,
  });
  let current = user;
  const makeClient = () => ({
    auth: {
      getUser: async () => ({ data: { user: current }, error: null }),
      getSession: async () => ({
        data: { session: current ? { ...session, user: current } : null },
        error: null,
      }),
    },
  });
  const fetcher = async (url, options) =>
    url instanceof Request
      ? handler(url)
      : Response.json({ status: "enrolled" });
  const env = {
    ACCOUNT_ORIGIN: accountOrigin,
    SUPABASE_URL: project,
    SUPABASE_PUBLISHABLE_KEY: "sb_publishable_synthetic",
    APPLE_WEB_CLIENT_ID: "app.nevestudio.carry.web",
    WEB_FLOW_ENCRYPTION_KEY: opaque(),
    ACCOUNT_WEB_ENABLED: "true",
    ACCOUNT_AI_ENABLED: "true",
    CARRY_AI_ORIGIN: origin,
    CARRY_OWNER_BRIDGE_SECRET: secret,
  };
  const web = createWebHandler({ makeClient, fetcher, now: () => now });
  const page = (
    path,
    { body, cookie = "", originHeader = accountOrigin, settings = env } = {},
  ) =>
    web(
      new Request(accountOrigin + path, {
        method: body ? "POST" : "GET",
        headers: {
          Accept: "text/html",
          "Accept-Language": "zh-CN",
          Cookie: cookie,
          ...(body
            ? {
                "Content-Type": "application/x-www-form-urlencoded",
                Origin: originHeader,
              }
            : {}),
        },
        body: body ? new URLSearchParams(body) : undefined,
      }),
      settings,
    );
  const csrf = (response) => response.headers.get("Set-Cookie").split(";")[0];
  const formToken = (html) => /name="csrf" value="([^"]+)"/.exec(html)[1];
  async function flow() {
    const registered = await handler(
      new Request(origin + "/oauth/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          client_name: "<img src=x onerror=alert(1)>",
          redirect_uris: ["https://codex.invalid/callback"],
        }),
      }),
    );
    const clientID = (await registered.json()).client_id,
      verifier = "v".repeat(43),
      params = new URLSearchParams({
        client_id: clientID,
        redirect_uri: "https://codex.invalid/callback",
        response_type: "code",
        code_challenge: await challenge(verifier),
        code_challenge_method: "S256",
        scope: "trips:read trips:write trips:create",
        state: "synthetic-state",
        resource: origin + "/mcp",
      });
    const authorized = await handler(
      new Request(origin + "/oauth/authorize?" + params),
    );
    return {
      clientID,
      verifier,
      path:
        new URL(authorized.headers.get("Location")).pathname +
        new URL(authorized.headers.get("Location")).search,
    };
  }
  async function approve(flow) {
    const get = await page(flow.path),
      cookie = csrf(get),
      html = await get.text();
    const post = await page(flow.path, {
      cookie,
      body: [
        ["csrf", formToken(html)],
        ["decision", "approve"],
        ["scopes", "trips:read"],
        ["scopes", "trips:write"],
        ["scopes", "trips:create"],
        ["onlyCreated", "true"],
      ],
    });
    const code = new URL(post.headers.get("Location")).searchParams.get("code");
    const response = await handler(
      new Request(origin + "/oauth/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          client_id: flow.clientID,
          redirect_uri: "https://codex.invalid/callback",
          code_verifier: flow.verifier,
          code,
          resource: origin + "/mcp",
        }),
      }),
    );
    assert.equal(response.status, 200);
    return (await response.json()).access_token;
  }
  async function tool(access, name, args) {
    const r = await handler(
      new Request(origin + "/mcp", {
        method: "POST",
        headers: {
          Authorization: "Bearer " + access,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name, arguments: args },
        }),
      }),
    );
    return { response: r, data: await r.json() };
  }
  return {
    db,
    page,
    flow,
    approve,
    csrf,
    formToken,
    tool,
    handler,
    setUser: (value) => {
      current = value;
    },
    env,
  };
}
test("real web→signed owner bridge→Auth validation→PostgreSQL consent and plan approval persists without phone", async () => {
  const f = await fixture();
  try {
    const flow = await f.flow(),
      get = await f.page(flow.path);
    assert.equal(get.status, 200);
    const cookie = f.csrf(get),
      html = await get.text();
    assert.ok(html.includes("&lt;img src=x onerror=alert(1)&gt;"));
    assert.ok(!html.includes("<img src=x"));
    assert.ok(!html.includes(token));
    assert.ok(html.includes("仅限此连接新建的行程"));
    const getGrants = await f.db.query(
      "select count(*) from carry_ai.records where bucket='grant'",
    );
    assert.equal(getGrants.rows[0].count, 0);
    const denied = await f.page(flow.path, {
      cookie,
      originHeader: "https://attacker.invalid",
      body: { csrf: f.formToken(html), decision: "approve" },
    });
    assert.equal(denied.status, 403);
    const access = await f.approve(flow),
      requestID = crypto.randomUUID(),
      preview = await f.tool(access, "preview_plan", {
        requestID,
        operations: [
          {
            action: "create_trip",
            fields: { name: "<script>not executable</script>", days: 1 },
          },
        ],
      });
    const plan = preview.data.result.structuredContent;
    assert.equal(plan.status, "awaiting_user_approval");
    const planPath = new URL(plan.approvalURL).pathname,
      p = await f.page(planPath),
      pCookie = f.csrf(p),
      pHtml = await p.text();
    assert.ok(!pHtml.includes("<script>not executable"));
    assert.ok(pHtml.includes("&lt;script&gt;not executable&lt;/script&gt;"));
    const hash = /name="contentHash" value="([^"]+)"/.exec(pHtml)[1];
    assert.equal(
      (
        await f.page(planPath, {
          cookie: pCookie,
          body: { csrf: f.formToken(pHtml), contentHash: hash },
        })
      ).status,
      200,
    );
    const committed = await f.tool(access, "commit_plan", {
      requestID,
      previewID: plan.previewID,
    });
    assert.equal(
      committed.data.result.structuredContent.status,
      "saved_to_account",
    );
    assert.equal(
      (await f.db.query("select count(*) from carry_private.graph_entities"))
        .rows[0].count,
      3,
    );
    assert.equal(
      (await f.db.query("select count(*) from auth.sessions")).rows[0].count,
      1,
    );
  } finally {
    await f.db.close();
  }
});
test("web gate, account-bound CSRF, missing proof and signed-out continuation fail closed", async () => {
  const f = await fixture();
  try {
    const flow = await f.flow();
    assert.equal(
      (
        await f.page(flow.path, {
          settings: { ...f.env, ACCOUNT_AI_ENABLED: "false" },
        })
      ).status,
      503,
    );
    const get = await f.page(flow.path),
      cookie = f.csrf(get),
      html = await get.text();
    f.setUser({ id: crypto.randomUUID(), email: "other@example.invalid" });
    const r = await f.page(flow.path, {
      cookie,
      body: [
        ["csrf", f.formToken(html)],
        ["decision", "approve"],
        ["scopes", "trips:read"],
        ["onlyCreated", "true"],
      ],
    });
    assert.equal(r.status, 403);
    const unsigned = await f.handler(
      new Request(origin + "/connections", {
        headers: {
          Authorization: "Bearer " + token,
          Origin: accountOrigin,
          "X-Carry-Account-ID": accountID,
        },
      }),
    );
    assert.equal(unsigned.status, 403);
    f.setUser(null);
    const back = await f.page("/ai/plans/" + crypto.randomUUID());
    assert.equal(back.status, 303);
    assert.ok(back.headers.get("Location").startsWith("/login?continue="));
  } finally {
    await f.db.close();
  }
});
test("all nine AI page translations and object-map tool schema retain matching complete keys", () => {
  const keys = Object.keys(aiWebStrings.en).sort();
  assert.equal(Object.keys(aiWebStrings).length, 9);
  for (const row of Object.values(aiWebStrings)) {
    assert.deepEqual(Object.keys(row).sort(), keys);
    assert.ok(
      Object.values(row).every((v) => typeof v === "string" && v.trim()),
    );
  }
  const tool = TOOLS.find((t) => t.name === "apply_changes"),
    r =
      tool.inputSchema.properties.operations.items.properties.fields.properties
        .backgroundAssetIDs.anyOf[0];
  assert.equal(r.type, "object");
  assert.equal(r.maxProperties, 256);
  assert.ok(r.propertyNames.pattern);
  assert.equal(r.additionalProperties.format, "uuid");
});
