import { test } from "node:test";
import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { applyPortableMigrations } from "../carry-account-service/migration-fixture.mjs";
import { postgresStore } from "./postgres-store.mjs";
import { postgresGraphCore } from "./postgres-graph-core.mjs";
import { compilePlan } from "./domain.mjs";
import { hash, canonical, AIFailure } from "./security.mjs";
const accountID = crypto.randomUUID(),
  otherID = crypto.randomUUID(),
  sessionID = crypto.randomUUID(),
  clientID = crypto.randomUUID(),
  resource = "https://connect.invalid/mcp",
  now = Date.parse("2026-10-31T00:00:00Z");
const id = () => crypto.randomUUID();
async function fixture() {
  const db = new PGlite();
  await db.exec(
    "create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);",
  );
  await db.query("insert into auth.users values($1),($2)", [
    accountID,
    otherID,
  ]);
  await db.query("insert into auth.sessions values($1,$2,null,null)", [
    sessionID,
    accountID,
  ]);
  await db.exec(
    "create schema storage;create table storage.objects(bucket_id text,name text);grant usage on schema storage to service_role;grant select on storage.objects to service_role;",
  );
  await applyPortableMigrations(db);
  await db.exec("set role service_role");
  await db.query("select public.carry_account_enroll($1,$2,$3,$4)", [
    accountID,
    "synthetic-ai-core",
    "app.nevestudio.carry",
    "encrypted-test-only",
  ]);
  const core = postgresGraphCore(),
    store = postgresStore({
      driver: { transaction: (fn) => db.transaction(fn) },
      core,
    });
  await store.registerClient({
    id: clientID,
    name: "Synthetic Codex",
    redirectURIs: ["https://client.invalid/callback"],
  });
  async function grant(
    scopes = ["trips:read", "trips:write", "trips:create"],
    tripIDs = [],
    onlyCreated = true,
  ) {
    const authID = id(),
      grantID = id(),
      codeHash = await hash(authID);
    await store.createAuthorization({
      id: authID,
      clientID,
      redirectURI: "https://client.invalid/callback",
      challenge: "challenge",
      resource,
      state: "state",
      scopes,
      expiresAt: now + 100000,
    });
    await store.approveAuthorization({
      id: authID,
      accountID,
      sessionID,
      selectedScopes: scopes,
      tripIDs,
      onlyCreated,
      grantID,
      grantExpiresAt: now + 100000,
      codeHash,
      codeExpiresAt: now + 1000,
      now,
    });
    return store.getGrant({ id: grantID, now });
  }
  async function graph(g) {
    return store.readGraph({ accountID, grantID: g.id, now });
  }
  async function plan(g, operations, requestID = id()) {
    g = await store.getGrant({ id: g.id, now });
    const compiled = await compilePlan({
      requestID,
      operations,
      entities: await graph(g),
      grant: g,
      now,
    });
    return {
      accountID,
      grantID: g.id,
      requestID,
      inputHash: await hash(JSON.stringify(canonical({ operations }))),
      compiled,
      now,
    };
  }
  async function execute(p, { approve = true } = {}) {
    if (p.compiled.requiresApproval) {
      const v = await store.createPreview({ ...p, expiresAt: now + 10000 });
      if (approve)
        await store.approvePreview({
          id: v.id,
          accountID,
          sessionID,
          contentHash: v.contentHash,
          now,
        });
      return store.execute({ ...p, previewID: v.id });
    }
    return store.execute(p);
  }
  return { db, store, core, grant, graph, plan, execute };
}
const rejects = (promise, code) =>
  assert.rejects(promise, (e) => e instanceof AIFailure && e.code === code);
test("real shared Graph core creates complete trip with no extra native Auth session and survives receipt retry", async () => {
  const f = await fixture();
  try {
    const g = await f.grant(),
      p = await f.plan(g, [
        {
          action: "create_trip",
          fields: { name: "Synthetic AI trip", days: 2 },
        },
      ]),
      r = await f.execute(p),
      rows = await f.graph(g);
    assert.equal(r.status, "saved_to_account");
    assert.equal(rows.filter((e) => e.kind === "trip").length, 1);
    assert.equal(rows.filter((e) => e.kind === "day").length, 3);
    assert.deepEqual(await f.execute(p), r);
    await f.db.exec("reset role");
    assert.equal(
      (await f.db.query("select count(*) from auth.sessions")).rows[0].count,
      1,
    );
    await f.db.exec("set role service_role");
    const native = (
      await f.db.query(
        "select public.carry_graph_pull($1,$2,0,500) as result",
        [accountID, sessionID],
      )
    ).rows[0].result;
    assert.ok(
      native.changes.some(
        (c) => c.entity.id === rows.find((e) => e.kind === "trip").id,
      ),
    );
  } finally {
    await f.db.close();
  }
});
test("AI delete/restore verifies deletion batch and uses shared native cascade logic", async () => {
  const f = await fixture();
  try {
    const g = await f.grant();
    await f.execute(
      await f.plan(g, [
        {
          action: "create_trip",
          fields: { name: "Synthetic restore", days: 1 },
        },
      ]),
    );
    let trip = (await f.graph(g)).find((e) => e.kind === "trip");
    await f.execute(
      await f.plan(g, [
        {
          action: "delete",
          id: trip.id,
          kind: "trip",
          baseVersion: trip.version,
          baseSubtreeVersion: trip.subtreeVersion,
        },
      ]),
    );
    trip = (await f.graph(g)).find((e) => e.kind === "trip");
    assert.ok(trip.deletedAt);
    const restore = await f.plan(g, [
      {
        action: "restore",
        id: trip.id,
        kind: "trip",
        baseVersion: trip.version,
        baseSubtreeVersion: trip.subtreeVersion,
        deletionBatch: trip.deletionBatch,
      },
    ]);
    await f.execute(restore);
    assert.ok((await f.graph(g)).every((e) => !e.deletedAt));
  } finally {
    await f.db.close();
  }
});
test("shared core late conflict rolls back entire approved plan and AI receipt", async () => {
  const f = await fixture();
  try {
    const g = await f.grant();
    await f.execute(
      await f.plan(g, [
        {
          action: "create_trip",
          fields: { name: "Synthetic conflict", days: 1 },
        },
      ]),
    );
    const trip = (await f.graph(g)).find((e) => e.kind === "trip"),
      day = (await f.graph(g)).find((e) => e.kind === "day");
    const p = await f.plan(g, [
      {
        action: "patch",
        id: day.id,
        kind: "day",
        baseVersion: day.version,
        fields: { note: "Must rollback" },
      },
      {
        action: "patch",
        id: trip.id,
        kind: "trip",
        baseVersion: trip.version,
        fields: { name: "AI change" },
      },
    ]);
    await f.db.query("select public.carry_graph_apply($1,$2,$3)", [
      accountID,
      sessionID,
      {
        requestID: id(),
        mutations: [
          {
            id: trip.id,
            kind: "trip",
            action: "patch",
            baseVersion: trip.version,
            fields: { name: "Native change" },
          },
        ],
      },
    ]);
    await rejects(f.execute(p), "field_conflict");
    assert.equal(
      (await f.graph(g)).find((e) => e.id === day.id).fields.note,
      "",
    );
    assert.equal(await f.store.receipt(p), null);
  } finally {
    await f.db.close();
  }
});
test("undo uses accepted before/after and refuses a later native descendant edit", async () => {
  const f = await fixture();
  try {
    const g = await f.grant(),
      created = await f.execute(
        await f.plan(g, [
          {
            action: "create_trip",
            fields: { name: "Synthetic undo", days: 1 },
          },
        ]),
      );
    const req = {
      accountID,
      grantID: g.id,
      operationID: created.operationID,
      requestID: id(),
      now,
    };
    const inverse = await f.store.prepareUndo(req);
    assert.equal(inverse.operations[0].action, "delete");
    const day = (await f.graph(g)).find((e) => e.kind === "day");
    await f.db.query("select public.carry_graph_apply($1,$2,$3)", [
      accountID,
      sessionID,
      {
        requestID: id(),
        mutations: [
          {
            id: day.id,
            kind: "day",
            action: "patch",
            baseVersion: day.version,
            fields: { note: "Native later" },
          },
        ],
      },
    ]);
    await rejects(
      f.store.prepareUndo({ ...req, requestID: id() }),
      "undo_conflict",
    );
    await rejects(f.plan(g, inverse.operations), "subtree_conflict");
  } finally {
    await f.db.close();
  }
});
test("shared core and AI schema expose no anon/authenticated execute or table privileges", async () => {
  const f = await fixture();
  try {
    const p = (
      await f.db.query(
        "select has_function_privilege('anon','carry_private.graph_apply_core(uuid,jsonb)','execute') a,has_function_privilege('authenticated','carry_private.graph_require_active_account(uuid)','execute') b,has_table_privilege('authenticated','carry_ai.records','select') c",
      )
    ).rows[0];
    assert.deepEqual(p, { a: false, b: false, c: false });
  } finally {
    await f.db.close();
  }
});
test("undo creation is a reviewed atomic shared-core deletion, retaining tombstones for native devices", async () => {
  const f = await fixture();
  try {
    const g = await f.grant(),
      created = await f.execute(
        await f.plan(g, [
          {
            action: "create_trip",
            fields: { name: "Synthetic actual undo", days: 1 },
          },
        ]),
      );
    const inverse = await f.store.prepareUndo({
      accountID,
      grantID: g.id,
      operationID: created.operationID,
      requestID: id(),
      now,
    });
    const undone = await f.execute(await f.plan(g, inverse.operations));
    assert.equal(undone.status, "saved_to_account");
    const rows = await f.graph(g);
    assert.equal(rows.length, 3);
    assert.ok(rows.every((e) => e.deletedAt));
  } finally {
    await f.db.close();
  }
});
test("native wrapper still rejects missing/revoked sessions while separately approved AI grant remains usable", async () => {
  const f = await fixture();
  try {
    const g = await f.grant(),
      nativePlan = await f.plan(g, [
        {
          action: "create_trip",
          fields: { name: "Native must reject", days: 1 },
        },
      ]);
    await f.db.exec("reset role");
    await f.db.query("delete from auth.sessions where id=$1", [sessionID]);
    await f.db.exec("set role service_role");
    await assert.rejects(
      f.db.query("select public.carry_graph_apply($1,$2,$3)", [
        accountID,
        sessionID,
        nativePlan.compiled.command,
      ]),
      (e) => e.message === "session_expired",
    );
    const r = await f.execute(
      await f.plan(g, [
        {
          action: "create_trip",
          fields: { name: "Synthetic authorized without phone", days: 1 },
        },
      ]),
    );
    assert.equal(r.status, "saved_to_account");
    await rejects(f.grant(), "session_expired");
  } finally {
    await f.db.close();
  }
});

test("guarded account purge removes AI grants/previews/receipts with graph data before Auth deletion", async () => {
  const f = await fixture();
  try {
    const g = await f.grant();
    await f.execute(
      await f.plan(g, [
        {
          action: "create_trip",
          fields: { name: "Synthetic delete account", days: 1 },
        },
      ]),
    );
    await assert.rejects(
      f.db.query("select public.carry_account_purge_owned_data($1)", [
        accountID,
      ]),
      (e) => e.message === "account_deletion_not_authorized",
    );
    await f.store.rateLimit({ path: "/mcp", accountID, grantID: g.id, now });
    await f.db.query(
      "insert into carry_private.account_deletions(account_id,ticket_hash,stage,operation_id,lease_until) values($1,$2,'purging',$3,statement_timestamp()+interval '120 seconds')",
      [accountID, await hash("synthetic-ticket"), id()],
    );
    await f.db.query(
      "update carry_private.carry_apple_credentials set status='deleting',revoked_at=statement_timestamp() where account_id=$1",
      [accountID],
    );
    await f.db.query("select public.carry_account_purge_owned_data($1)", [
      accountID,
    ]);
    assert.equal(
      (
        await f.db.query(
          "select count(*) from carry_ai.records where account_id=$1",
          [accountID],
        )
      ).rows[0].count,
      0,
    );
    assert.equal(
      (
        await f.db.query(
          "select count(*) from carry_private.graph_entities where account_id=$1",
          [accountID],
        )
      ).rows[0].count,
      0,
    );
    assert.equal(
      (
        await f.db.query(
          "select count(*) from carry_ai.rate_limits where account_id=$1",
          [accountID],
        )
      ).rows[0].count,
      0,
    );
    await rejects(f.store.getGrant({ id: g.id, now }), "invalid_token");
  } finally {
    await f.db.close();
  }
});
test("reorder preview binds parent subtree so a later native child cannot silently escape the complete order", async () => {
  const f = await fixture();
  try {
    const g = await f.grant();
    await f.execute(
      await f.plan(g, [
        {
          action: "create_trip",
          fields: { name: "Synthetic reorder", days: 1 },
        },
      ]),
    );
    const graph = await f.graph(g),
      trip = graph.find((e) => e.kind === "trip"),
      days = graph.filter((e) => e.kind === "day"),
      p = await f.plan(g, [
        {
          action: "reorder",
          id: trip.id,
          kind: "trip",
          baseVersion: trip.version,
          baseSubtreeVersion: trip.subtreeVersion,
          data: { childKind: "day" },
          ids: days.map((e) => e.id).reverse(),
        },
      ]);
    await f.db.query("select public.carry_graph_apply($1,$2,$3)", [
      accountID,
      sessionID,
      {
        requestID: id(),
        mutations: [
          {
            id: id(),
            kind: "section",
            parentID: trip.id,
            action: "create",
            baseVersion: 0,
            fields: { title: "Added later", sortOrder: 0 },
          },
        ],
      },
    ]);
    await rejects(f.execute(p), "subtree_conflict");
    assert.equal(await f.store.receipt(p), null);
  } finally {
    await f.db.close();
  }
});
test("a different AI connection cannot reuse an existing native Graph request receipt", async () => {
  const f = await fixture();
  try {
    const g = await f.grant(),
      p = await f.plan(g, [
        {
          action: "create_trip",
          fields: { name: "Synthetic global request", days: 1 },
        },
      ]);
    await f.db.query("select public.carry_graph_apply($1,$2,$3)", [
      accountID,
      sessionID,
      p.compiled.command,
    ]);
    await rejects(f.execute(p), "request_id_reused");
    assert.equal(await f.store.receipt(p), null);
  } finally {
    await f.db.close();
  }
});
