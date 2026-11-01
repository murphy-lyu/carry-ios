import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PGlite } from "@electric-sql/pglite";
import { postgresStore } from "./postgres-store.mjs";
import { AIFailure, hash, canonical } from "./security.mjs";
import { defaults, planContentHash } from "./domain.mjs";
const accountID = crypto.randomUUID(),
  sessionID = crypto.randomUUID(),
  clientID = crypto.randomUUID(),
  tripID = crypto.randomUUID(),
  resource = "https://connect.invalid/mcp",
  now = 1000000;
const tokens = async (label) => ({
  accessHash: await hash("access" + label),
  refreshHash: await hash("refresh" + label),
  accessExpiresAt: now + 10000,
  refreshExpiresAt: now + 50000,
});
async function fixture(path) {
  const db = new PGlite(path);
  await db.exec(
    await readFile(new URL("./postgres-schema.sql", import.meta.url), "utf8"),
  );
  await db.exec(await readFile(new URL("./maintenance.sql", import.meta.url), "utf8"));
  await db.exec(
    "create table qa_graph(id uuid primary key, value jsonb); create table qa_account(id uuid primary key, active boolean);",
  );
  await db.query("insert into qa_account values($1,true)", [accountID]);
  const trip = {
    id: tripID,
    kind: "trip",
    parentID: null,
    version: 1,
    subtreeVersion: 1,
    fieldVersions: { name: 1 },
    fields: { ...defaults("trip", now), name: "Before" },
  };
  await db.query("insert into qa_graph values($1,$2)", [tripID, trip]);
  const core = {
    assertAccount: async (tx, p) => {
      const row = (
        await tx.query("select active from qa_account where id=$1 for update", [
          p.accountID,
        ])
      ).rows[0];
      if (!row?.active) throw new AIFailure(401, "invalid_token");
    },
    assertOwner: async (tx, p) => {
      if (p.accountID !== accountID || p.sessionID !== sessionID)
        throw new AIFailure(401, "unauthorized");
    },
    ownsTrips: async (tx, p) => p.tripIDs.every((x) => x === tripID),
    readGraph: async (tx) =>
      (await tx.query("select value from qa_graph")).rows.map((r) => r.value),
    execute: async (tx, p) => {
      const m = p.compiled.command.mutations[0],
        r = (await tx.query("select value from qa_graph where id=$1", [m.id]))
          .rows[0].value;
      r.version++;
      Object.assign(r.fields, m.fields);
      await tx.query("update qa_graph set value=$2 where id=$1", [r.id, r]);
      if (p.compiled.failAfterWrite)
        throw Error("SQL provider detail must not leak");
      return {
        status: "saved_to_account",
        requestID: p.requestID,
        operationID: p.requestID,
        changes: [{ id: r.id, kind: r.kind, version: r.version }],
      };
    },
    prepareUndo: async () => ({ operations: [] }),
  };
  const driver = { transaction: (fn) => db.transaction(fn) },
    store = postgresStore({ driver, core });
  await store.registerClient({
    id: clientID,
    name: "QA",
    redirectURIs: ["https://client.invalid/callback"],
  });
  async function grant() {
    const id = crypto.randomUUID(),
      grantID = crypto.randomUUID(),
      codeHash = await hash(id);
    await store.createAuthorization({
      id,
      clientID,
      redirectURI: "https://client.invalid/callback",
      challenge: "challenge",
      resource,
      state: "state",
      scopes: ["trips:read", "trips:write"],
      expiresAt: now + 10000,
    });
    await store.approveAuthorization({
      id,
      grantID,
      accountID,
      sessionID,
      selectedScopes: ["trips:read", "trips:write"],
      tripIDs: [tripID],
      onlyCreated: false,
      grantExpiresAt: now + 60000,
      codeHash,
      codeExpiresAt: now + 1000,
      now,
    });
    const t = await tokens(id);
    const input = {
      codeHash,
      clientID,
      redirectURI: "https://client.invalid/callback",
      challenge: "challenge",
      resource,
      tokens: t,
      now,
    };
    const g = await store.exchangeCode(input);
    return { g, t, input };
  }
  return { db, store, grant, core, driver };
}
const rejects = (promise, code) =>
  assert.rejects(promise, (e) => e instanceof AIFailure && e.code === code);
test("PostgreSQL single-use code and exact PKCE/resource bindings", async () => {
  const f = await fixture();
  try {
    const { input } = await f.grant();
    await rejects(f.store.exchangeCode(input), "invalid_grant");
  } finally {
    await f.db.close();
  }
});
test("refresh replay commits revocation and survives new store instance", async () => {
  const f = await fixture();
  try {
    const { g, t } = await f.grant(),
      t2 = await tokens("rotated");
    await f.store.rotateRefresh({
      refreshHash: t.refreshHash,
      clientID,
      resource,
      tokens: t2,
      now,
    });
    await rejects(
      f.store.rotateRefresh({
        refreshHash: t.refreshHash,
        clientID,
        resource,
        tokens: await tokens("replay"),
        now,
      }),
      "invalid_grant",
    );
    const reopened = postgresStore({ driver: f.driver, core: f.core });
    await rejects(
      reopened.resolveAccess({ tokenHash: t2.accessHash, resource, now }),
      "invalid_token",
    );
    assert.ok(
      (
        await f.db.query(
          "select value from carry_ai.records where bucket='grant' and id=$1",
          [g.id],
        )
      ).rows[0].value.revokedAt,
    );
  } finally {
    await f.db.close();
  }
});
test("another client cannot revoke tokens and account deletion blocks issued token", async () => {
  const f = await fixture();
  try {
    const { t } = await f.grant();
    await f.store.revokeToken({
      tokenHash: t.accessHash,
      clientID: crypto.randomUUID(),
      now,
    });
    assert.equal(
      (await f.store.resolveAccess({ tokenHash: t.accessHash, resource, now }))
        .accountID,
      accountID,
    );
    await f.db.query("update qa_account set active=false");
    await rejects(
      f.store.resolveAccess({ tokenHash: t.accessHash, resource, now }),
      "invalid_token",
    );
  } finally {
    await f.db.close();
  }
});
async function command(g, { failAfterWrite = false } = {}) {
  const mutations = [
    {
      id: tripID,
      kind: "trip",
      action: "patch",
      baseVersion: 1,
      fields: { name: "After" },
    },
  ];
  return {
    accountID,
    grantID: g.id,
    requestID: crypto.randomUUID(),
    inputHash: await hash("input"),
    now,
    compiled: {
      command: { mutations },
      createdTripIDs: [],
      requiresApproval: false,
      contentHash: await planContentHash(mutations),
      failAfterWrite,
    },
  };
}
test("graph mutation and receipt rollback together after injected SQL failure", async () => {
  const f = await fixture();
  try {
    const { g } = await f.grant(),
      p = await command(g, { failAfterWrite: true });
    await rejects(f.store.execute(p), "store_unavailable");
    assert.equal(
      (await f.db.query("select value from qa_graph")).rows[0].value.fields
        .name,
      "Before",
    );
    assert.equal(await f.store.receipt(p), null);
  } finally {
    await f.db.close();
  }
});
test("persistent execute replay returns original receipt and rejects changed input", async () => {
  const f = await fixture();
  try {
    const { g } = await f.grant(),
      p = await command(g),
      a = await f.store.execute(p),
      reopened = postgresStore({ driver: f.driver, core: f.core });
    assert.deepEqual(await reopened.execute(p), a);
    assert.equal(
      (await f.db.query("select value from qa_graph")).rows[0].value.version,
      2,
    );
    await rejects(
      reopened.execute({ ...p, inputHash: await hash("different") }),
      "request_id_reused",
    );
  } finally {
    await f.db.close();
  }
});
test("explicit preview cannot be bypassed and grant revocation invalidates approval", async () => {
  const f = await fixture();
  try {
    const { g } = await f.grant(),
      p = await command(g),
      v = await f.store.createPreview({ ...p, expiresAt: now + 1000 });
    await rejects(f.store.execute(p), "preview_required");
    await f.store.approvePreview({
      id: v.id,
      accountID,
      sessionID,
      contentHash: v.contentHash,
      now,
    });
    await f.store.revokeGrant({ id: g.id, accountID, sessionID, now });
    await rejects(f.store.execute({ ...p, previewID: v.id }), "invalid_token");
  } finally {
    await f.db.close();
  }
});
test("preview payload hash is checked and durable tokens only contain digests", async () => {
  const f = await fixture();
  try {
    const { g, t } = await f.grant(),
      p = await command(g);
    p.compiled.command.mutations[0].fields.name = "Forged";
    await rejects(f.store.execute(p), "preview_changed");
    const rows = (
      await f.db.query(
        "select id,value from carry_ai.records where bucket in ('code','access','refresh')",
      )
    ).rows;
    assert.ok(rows.every((r) => /^[0-9a-f]{64}$/.test(r.id)));
    assert.ok(
      rows.every((r) => !("access" in r.value) && !("refresh" in r.value)),
    );
    assert.equal(
      (await f.store.resolveAccess({ tokenHash: t.accessHash, resource, now }))
        .accountID,
      accountID,
    );
  } finally {
    await f.db.close();
  }
});
test("SQL rate limit is durable and fixed window resets without growing keys", async () => {
  const f = await fixture();
  try {
    for (let n = 0; n < 20; n++)
      assert.equal(
        await f.store.rateLimit({ path: "/oauth/register", now }),
        true,
      );
    assert.equal(
      await f.store.rateLimit({ path: "/oauth/register", now }),
      false,
    );
    assert.equal(
      await f.store.rateLimit({ path: "/oauth/register", now: now + 60000 }),
      true,
    );
    assert.equal(
      (await f.db.query("select count(*) from carry_ai.rate_limits")).rows[0]
        .count,
      1,
    );
  } finally {
    await f.db.close();
  }
});

test("random unknown paths share a durable limit rather than unbounded unique buckets", async () => {
  const f = await fixture();
  try {
    for (let n = 0; n < 120; n++)
      assert.equal(
        await f.store.rateLimit({
          path: "/unknown/" + crypto.randomUUID(),
          now,
        }),
        true,
      );
    assert.equal(
      await f.store.rateLimit({ path: "/unknown/" + crypto.randomUUID(), now }),
      false,
    );
    assert.equal(
      (await f.db.query("select count(*) from carry_ai.rate_limits")).rows[0]
        .count,
      1,
    );
  } finally {
    await f.db.close();
  }
});

test("filesystem-backed SQL preserves grants and hashed access across database close/reopen", async () => {
  const path = await mkdtemp(join(tmpdir(), "carry-ai-durable-"));
  let db;
  try {
    const f = await fixture(path);
    const { t } = await f.grant();
    await f.db.close();
    db = new PGlite(path);
    const reopened = postgresStore({
      driver: { transaction: (fn) => db.transaction(fn) },
      core: f.core,
    });
    assert.equal(
      (await reopened.resolveAccess({ tokenHash: t.accessHash, resource, now }))
        .accountID,
      accountID,
    );
  } finally {
    if (db) await db.close();
    await rm(path, { recursive: true, force: true });
  }
});
test("bounded maintenance expires content without erasing still-valid refresh replay evidence", async () => {
  const { maintainAIRecords } = await import("./maintenance.mjs"),
    f = await fixture();
  try {
    const { t } = await f.grant();
    await f.store.rotateRefresh({
      refreshHash: t.refreshHash,
      clientID,
      resource,
      tokens: await tokens("maintenance-rotate"),
      now,
    });
    await f.db.query(
      "insert into carry_ai.records(bucket,id,value) values('receipt','expired-receipt',$1),('preview','expired-preview',$2)",
      [{ createdAt: now - 31 * 86400000 }, { expiresAt: now - 2 * 86400000 }],
    );
    const removed = await maintainAIRecords(f.driver, { now, limit: 1 });
    assert.equal(removed.records, 1);
    assert.equal(
      (
        await f.db.query(
          "select count(*) from carry_ai.records where bucket='refresh' and id=$1",
          [t.refreshHash],
        )
      ).rows[0].count,
      1,
    );
    await maintainAIRecords(f.driver, { now, limit: 500 });
    assert.equal(
      (
        await f.db.query(
          "select count(*) from carry_ai.records where id='expired-preview'",
        )
      ).rows[0].count,
      0,
    );
    await rejects(
      f.store.rotateRefresh({
        refreshHash: t.refreshHash,
        clientID,
        resource,
        tokens: await tokens("maintenance-replay"),
        now,
      }),
      "invalid_grant",
    );
  } finally {
    await f.db.close();
  }
});

test("client registry enforces count/byte capacity while existing grants and refresh keep working", async () => {
  const f = await fixture();
  try {
    const limited = postgresStore({ driver:f.driver,core:f.core,clientRegistryLimits:{maximumClients:1} });
    await rejects(limited.registerClient({id:crypto.randomUUID(),name:'New',createdAt:now}), 'client_registration_capacity_exhausted');
    await rejects(limited.registerClient({id:clientID}), 'request_id_reused');
    const byteLimited = postgresStore({driver:f.driver,core:f.core,clientRegistryLimits:{maximumBytes:1}});
    await rejects(byteLimited.registerClient({id:crypto.randomUUID(),name:'New'}), 'client_registration_capacity_exhausted');
    const {g,t} = await f.grant();
    const rotated = await tokens('registry-full');
    assert.equal((await limited.rotateRefresh({refreshHash:t.refreshHash,clientID,resource,tokens:rotated,now})).id,g.id);
    assert.equal((await f.store.getClient({id:clientID})).usedAt,now);
    assert.equal((await f.db.query("select count(*) from carry_ai.records where bucket='client'")).rows[0].count,1);
    for (const maximumClients of [0,NaN,Infinity,1025]) assert.throws(() => postgresStore({driver:f.driver,core:f.core,clientRegistryLimits:{maximumClients}}), /invalid_client_registry_capacity/);
  } finally { await f.db.close(); }
});

test('refresh scope must equal the owner grant and invalid scope does not consume the token or suppress reuse revocation', async () => {
  const f=await fixture();
  try {
    const {g,t}=await f.grant();
    const base={refreshHash:t.refreshHash,clientID,resource,now,tokens:await tokens('scope-rotation')};
    for(const requestedScopes of [[],['trips:read'],['trips:read','trips:write','attachments:read'],['unknown'],null,'trips:read trips:write']) {
      await rejects(f.store.rotateRefresh({...base,requestedScopes}), 'invalid_scope');
      assert.equal((await f.db.query("select value from carry_ai.records where bucket='refresh' and id=$1",[t.refreshHash])).rows[0].value.spent,false);
    }
    const result=await f.store.rotateRefresh({...base,requestedScopes:[...g.scopes].reverse()});
    assert.deepEqual(result.scopes,g.scopes);
    await rejects(f.store.rotateRefresh({...base,requestedScopes:['invalid']}),'invalid_grant');
    const reopened=postgresStore({driver:f.driver,core:f.core});
    await rejects(reopened.resolveAccess({tokenHash:base.tokens.accessHash,resource,now}),'invalid_token');
    assert.ok((await f.db.query("select value from carry_ai.records where bucket='grant' and id=$1",[g.id])).rows[0].value.revokedAt);
  } finally { await f.db.close(); }
});
