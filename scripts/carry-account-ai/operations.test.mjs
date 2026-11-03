import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { postgresStore } from "./postgres-store.mjs";
import { createOperationsRecorder, oauthResponseEvent } from "./operations.mjs";
const sql = async (name) => readFile(new URL(name, import.meta.url), "utf8");
async function fixture() {
  const db = new PGlite();
  await db.exec(await sql("./postgres-schema.sql"));
  await db.exec(await sql("./operations.sql"));
  await db.exec(await sql("./maintenance.sql"));
  return db;
}
const day = 86400000,
  now = 200 * day;
const client = (db, id, value = {}) =>
  db.query(
    "insert into carry_ai.records(bucket,id,value) values('client',$1,$2)",
    [id, { registryVersion: 1, createdAt: 0, usedAt: 1, ...value }],
  );
const grant = async (db, clientID, value = {}) => {
  const id = crypto.randomUUID();
  await db.query(
    "insert into carry_ai.records(bucket,id,grant_id,value) values('grant',$1::text,$1::uuid,$2)",
    [id, { clientID, createdAt: 0, expiresAt: day, revokedAt: null, ...value }],
  );
  return id;
};

test("retirement preserves active grants, unexpired spent refreshes, unknown deadlines and legacy clients", async () => {
  const db = await fixture();
  try {
    for (const id of [
      "old",
      "live",
      "recent",
      "spent",
      "unknown",
      "legacy",
      "no-date",
    ])
      await client(
        db,
        id,
        id === "legacy"
          ? { registryVersion: 0 }
          : id === "no-date"
            ? { createdAt: null }
            : {},
      );
    const old = await grant(db, "old");
    await grant(db, "live", { expiresAt: now + day });
    await grant(db, "recent", { revokedAt: now - day });
    const spent = await grant(db, "spent", { revokedAt: day });
    const unknown = await grant(db, "unknown", { expiresAt: null });
    await db.query(
      "insert into carry_ai.records(bucket,id,grant_id,value) values('refresh','spent-proof',$1,$2)",
      [spent, { grantID: spent, spent: true, expiresAt: now + day }],
    );
    let r = (
      await db.query("select carry_ai.retire_clients($1,100) result", [now])
    ).rows[0].result;
    assert.deepEqual(r, { unusedClients: 0, retiredClients: 1 });
    assert.equal(
      (
        await db.query(
          "select count(*) from carry_ai.records where bucket='grant' and id=$1",
          [old],
        )
      ).rows[0].count,
      1,
    );
    assert.equal(
      (
        await db.query(
          "select count(*) from carry_ai.records where bucket='client'",
        )
      ).rows[0].count,
      6,
    );
    await db.query(
      "update carry_ai.records set value=value||$1 where bucket='refresh'",
      [{ expiresAt: now - 1 }],
    );
    r = (await db.query("select carry_ai.retire_clients($1,1) result", [now]))
      .rows[0].result;
    assert.equal(r.retiredClients, 1);
    assert.equal(
      (
        await db.query(
          "select count(*) from carry_ai.records where id='spent' and bucket='client'",
        )
      ).rows[0].count,
      0,
    );
  } finally {
    await db.close();
  }
});

test("registration under capacity pressure reclaims safely and commits bounded progress even when still full", async () => {
  const db = await fixture();
  try {
    for (let i = 0; i < 40; i++) await client(db, "old-" + i, { usedAt: null });
    await client(db, "retained", { registryVersion: 0 });
    const core = Object.fromEntries(
      [
        "assertOwner",
        "assertAccount",
        "ownsTrips",
        "readGraph",
        "execute",
        "prepareUndo",
      ].map((k) => [k, async () => {}]),
    );
    const store = postgresStore({
      driver: { transaction: (f) => db.transaction(f) },
      core,
      clientRegistryLimits: { maximumClients: 1 },
    });
    await assert.rejects(
      store.registerClient({ id: "new", createdAt: now }),
      (e) => e.code === "client_registration_capacity_exhausted",
    );
    assert.equal(
      (
        await db.query(
          "select count(*) from carry_ai.records where bucket='client'",
        )
      ).rows[0].count,
      9,
    );
    await assert.rejects(
      store.registerClient({ id: "new", createdAt: now }),
      (e) => e.code === "client_registration_capacity_exhausted",
    );
    assert.equal(
      (
        await db.query(
          "select count(*) from carry_ai.records where bucket='client'",
        )
      ).rows[0].count,
      1,
    );
    const bigger = postgresStore({
      driver: { transaction: (f) => db.transaction(f) },
      core,
      clientRegistryLimits: { maximumClients: 2 },
    });
    await bigger.registerClient({ id: "new", createdAt: now });
    assert.ok(await bigger.getClient({ id: "new" }));
  } finally {
    await db.close();
  }
});

test("aggregate diagnostics contain no identities and remain bounded; unknown events are rejected", async () => {
  const db = await fixture();
  try {
    await client(db, "sensitive-client-name", { usedAt: 60000 });
    await db.query("select carry_ai.record_auth_event('refresh_ok',$1)", [now]);
    await db.query("select carry_ai.record_auth_event('refresh_ok',$1)", [now]);
    await db.query("select carry_ai.record_auth_event('refresh_missing',$1)", [
      now - 14 * day,
    ]);
    await assert.rejects(
      db.query("select carry_ai.record_auth_event('arbitrary-user-input',$1)", [
        now,
      ]),
    );
    const before = JSON.stringify(
      (await db.query("select carry_ai.operations_snapshot($1) result", [now]))
        .rows[0].result,
    );
    assert.ok(!before.includes("sensitive-client-name"));
    assert.ok(before.includes("authorizedWithinMinute"));
    await db.query("select carry_ai.maintain_records($1,10)", [now]);
    assert.deepEqual(
      (await db.query("select event,count from carry_ai.auth_event_counts"))
        .rows,
      [{ event: "refresh_ok", count: 2 }],
    );
  } finally {
    await db.close();
  }
});

test("diagnostic sink outage never changes the OAuth decision and only fixed categories are submitted", async () => {
  const calls = [];
  const recorder = createOperationsRecorder({
    transaction: async (f) =>
      f({
        query: async (...args) => {
          calls.push(args);
          throw Error("private provider detail");
        },
      }),
  });
  await recorder({ name: "refresh_ok", now });
  assert.equal(calls.length, 1);
  assert.equal(oauthResponseEvent("/oauth/token", 200), "token_ok");
  assert.equal(oauthResponseEvent("/oauth/register", 503), "oauth_unavailable");
  assert.equal(oauthResponseEvent("/private-path", 200), null);
});


test('expired diagnostic cleanup obeys the same per-run bound',async()=>{
 const db=await fixture();try{
  for(let n=15;n<20;n++)await db.query("select carry_ai.record_auth_event('refresh_ok',$1)",[now-n*day]);
  const result=(await db.query('select carry_ai.maintain_records($1,2) result',[now])).rows[0].result;
  assert.equal(result.eventBuckets,2);assert.equal((await db.query('select count(*) from carry_ai.auth_event_counts')).rows[0].count,3);
 }finally{await db.close();}
});

test('health evaluation flags capacity, stale cleanup, replay and elevated token failures without taking action',async()=>{
 const {evaluateOperationsHealth}=await import('./operations-health.mjs');
 const snapshot={clients:0,clientBytes:0,events:[]},cron={active:true,lastSuccess:new Date(now-60000).toISOString(),failuresLastDay:0};
 assert.equal(evaluateOperationsHealth(snapshot,cron,{now}).status,'ok');
 assert.ok(evaluateOperationsHealth({...snapshot,clients:800},cron,{now}).warnings.includes('registry_capacity'));
 assert.ok(evaluateOperationsHealth({...snapshot,clients:1000},cron,{now}).critical.includes('registry_capacity'));
 assert.ok(evaluateOperationsHealth(snapshot,{...cron,lastSuccess:new Date(now-46*60000).toISOString()},{now}).critical.includes('retention_stale'));
 const events=[{day:200,event:'refresh_replay',count:1},{day:200,event:'token_rejected',count:5},{day:200,event:'token_ok',count:15}];
 const result=evaluateOperationsHealth({...snapshot,events},cron,{now});assert.deepEqual(result.warnings,['refresh_replay_observed','token_rejection_rate']);
 assert.throws(()=>evaluateOperationsHealth({clients:-1,clientBytes:0,events:[]},cron,{now}));
});
