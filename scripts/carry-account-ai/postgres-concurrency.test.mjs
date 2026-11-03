import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import pg from "pg";
import { spawn } from "node:child_process";
import { postgresDriver } from "./postgres-driver.mjs";
import { postgresStore } from "./postgres-store.mjs";
import { postgresGraphCore } from "./postgres-graph-core.mjs";
const endpoint = process.env.CARRY_QA_POSTGRES_URL;
const now = 200 * 86400000,
  resource = "https://concurrency.invalid/mcp";
const token = (label) => ({
  accessHash: "access-" + label,
  refreshHash: "refresh-" + label,
  accessExpiresAt: now + 10000,
  refreshExpiresAt: now + 20000,
});
async function fixture() {
  const url = new URL(endpoint);
  if (url.hostname !== "127.0.0.1" || url.pathname !== "/postgres")
    throw Error("local_synthetic_postgres_only");
  const admin = new pg.Pool({ connectionString: url.href, max: 1 }),
    name = "carry_qa_ops_" + crypto.randomUUID().replaceAll("-", "");
  await admin.query("create database " + name);
  url.pathname = "/" + name;
  const pool = new pg.Pool({ connectionString: url.href, max: 8 });
  pool.on("error", error => console.error("QA_IDLE_ERROR", error.code));
  try {
    await pool.query(
      await readFile(new URL("./postgres-schema.sql", import.meta.url), "utf8"),
    );
    await pool.query(
      await readFile(new URL("./operations.sql", import.meta.url), "utf8"),
    );
    await pool.query(
      await readFile(new URL("./maintenance.sql", import.meta.url), "utf8"),
    );
    await pool.query(
      "create schema carry_private;create table carry_private.carry_apple_credentials(account_id uuid,status text)",
    );
    const shared = await readFile(
      new URL(
        "../carry-account-service/supabase/migrations/20261101041529_account_ai_shared_graph_core.sql",
        import.meta.url,
      ),
      "utf8",
    );
    await pool.query(
      shared.slice(
        shared.indexOf("create function"),
        shared.indexOf(
          "create or replace function carry_private.graph_apply_core",
        ),
      ),
    );
    const accountID = crypto.randomUUID(),
      grantID = crypto.randomUUID(),
      clientID = crypto.randomUUID();
    await pool.query(
      "insert into carry_private.carry_apple_credentials values($1,'active')",
      [accountID],
    );
    const driver = postgresDriver(pool),
      core = postgresGraphCore(),
      store = postgresStore({ driver, core });
    await store.registerClient({
      id: clientID,
      createdAt: now,
      name: "Synthetic",
      redirectURIs: ["https://client.invalid/callback"],
    });
    const g = {
      id: grantID,
      accountID,
      clientID,
      resource,
      scopes: ["trips:read"],
      expiresAt: now + 30000,
      revokedAt: null,
      createdAt: now,
    };
    await pool.query(
      "insert into carry_ai.records(bucket,id,account_id,grant_id,value) values('grant',$1::text,$2,$1::uuid,$3)",
      [grantID, accountID, g],
    );
    await pool.query(
      "insert into carry_ai.records(bucket,id,account_id,grant_id,value) values('refresh','original',$1,$2,$3)",
      [
        accountID,
        grantID,
        { accountID, grantID, expiresAt: now + 20000, spent: false },
      ],
    );
    return {
      url: url.href,
      pool,
      driver,
      core,
      store,
      g,
      clientID,
      accountID,
      grantID,
      async close() {
        await pool.end();
        await admin.query("drop database " + name);
        await admin.end();
      },
    };
  } catch (e) {
    await pool.end();
    await admin.query("drop database " + name);
    await admin.end();
    throw e;
  }
}

test(
  "real PostgreSQL independent connections serialize duplicate refresh and persist family revocation",
  { skip: !endpoint },
  async () => {
    const f = await fixture();
    try {
      const stores = [
        f.store,
        postgresStore({ driver: postgresDriver(f.pool), core: f.core }),
      ];
      const results = await Promise.allSettled(
        stores.map((s, i) =>
          s.rotateRefresh({
            refreshHash: "original",
            clientID: f.clientID,
            resource,
            now,
            tokens: token(i),
          }),
        ),
      );
      assert.equal(results.filter((x) => x.status === "fulfilled").length, 1);
      assert.equal(
        results.find((x) => x.status === "rejected").reason.code,
        "invalid_grant",
      );
      const g = (
        await f.pool.query(
          "select value from carry_ai.records where bucket='grant' and id=$1",
          [f.grantID],
        )
      ).rows[0].value;
      assert.equal(g.revokedAt, now);
      for (let i = 0; i < 2; i++)
        await assert.rejects(
          f.store.resolveAccess({
            tokenHash: token(i).accessHash,
            resource,
            now,
          }),
          (e) => e.code === "invalid_token",
        );
    } finally {
      await f.close();
    }
  },
);

test(
  "real PostgreSQL registry race stays within the cap and retention cannot retire a live rotating client",
  { skip: !endpoint },
  async () => {
    const f = await fixture();
    try {
      const stores = Array.from({ length: 12 }, () =>
        postgresStore({
          driver: postgresDriver(f.pool),
          core: f.core,
          clientRegistryLimits: { maximumClients: 3 },
        }),
      );
      const result = await Promise.allSettled(
        stores.map((s) =>
          s.registerClient({ id: crypto.randomUUID(), createdAt: now }),
        ),
      );
      assert.equal(result.filter((r) => r.status === "fulfilled").length, 2);
      assert.equal(
        Number(
          (
            await f.pool.query(
              "select count(*) from carry_ai.records where bucket='client'",
            )
          ).rows[0].count,
        ),
        3,
      );
      await f.pool.query(
        "update carry_ai.records set value=value||$1 where bucket='client' and id=$2",
        [{ createdAt: 0, usedAt: 1 }, f.clientID],
      );
      await Promise.all([
        f.store.rotateRefresh({
          refreshHash: "original",
          clientID: f.clientID,
          resource,
          now,
          tokens: token("safe"),
        }),
        f.driver.transaction((tx) =>
          tx.query("select carry_ai.maintain_records($1,100)", [now]),
        ),
      ]);
      assert.ok(await f.store.getClient({ id: f.clientID }));
      assert.equal(
        (
          await f.store.resolveAccess({
            tokenHash: token("safe").accessHash,
            resource,
            now,
          })
        ).id,
        f.grantID,
      );
    } catch (error) {
      console.error("QA_RACE_ORIGINAL", error.code, error.message);
      throw error;
    } finally {
      await f.close();
    }
  },
);

test(
  "real PostgreSQL commit-response loss retains rotation; retrying spent token safely requires reauthorization",
  { skip: !endpoint },
  async () => {
    const f = await fixture();
    try {
      let lose = true;
      const faultyPool = {
        connect: async () => {
          const c = await f.pool.connect();
          return {
            query: async (sql, args) => {
              const result = await c.query(sql, args);
              if (sql === "commit" && lose) {
                lose = false;
                throw Error("synthetic response lost after commit");
              }
              return result;
            },
            release: (broken) => c.release(broken),
          };
        },
      };
      const store = postgresStore({
        driver: postgresDriver(faultyPool),
        core: f.core,
      });
      await assert.rejects(
        store.rotateRefresh({
          refreshHash: "original",
          clientID: f.clientID,
          resource,
          now,
          tokens: token("lost"),
        }),
        (e) => e.code === "store_unavailable",
      );
      assert.equal(
        (
          await f.store.resolveAccess({
            tokenHash: token("lost").accessHash,
            resource,
            now,
          })
        ).id,
        f.grantID,
      );
      await assert.rejects(
        f.store.rotateRefresh({
          refreshHash: "original",
          clientID: f.clientID,
          resource,
          now,
          tokens: token("retry"),
        }),
        (e) => e.code === "invalid_grant",
      );
      await assert.rejects(
        f.store.resolveAccess({
          tokenHash: token("lost").accessHash,
          resource,
          now,
        }),
        (e) => e.code === "invalid_token",
      );
    } finally {
      await f.close();
    }
  },
);

test(
  "separate OS processes cannot both refresh the same public-client credential",
  { skip: !endpoint },
  async () => {
    const f = await fixture();
    try {
      const source = `import pg from ${JSON.stringify(new URL("./node_modules/pg/esm/index.mjs", import.meta.url).href)};
  import {postgresDriver} from ${JSON.stringify(new URL("./postgres-driver.mjs", import.meta.url).href)};
  import {postgresStore} from ${JSON.stringify(new URL("./postgres-store.mjs", import.meta.url).href)};
  import {postgresGraphCore} from ${JSON.stringify(new URL("./postgres-graph-core.mjs", import.meta.url).href)};
  const pool=new pg.Pool({connectionString:process.env.CARRY_SYNTHETIC_DB,max:1});
  const store=postgresStore({driver:postgresDriver(pool),core:postgresGraphCore()});
  try{await store.rotateRefresh(JSON.parse(process.env.CARRY_SYNTHETIC_INPUT));console.log(JSON.stringify({ok:true}));}
  catch(e){console.log(JSON.stringify({ok:false,code:e.code}));}finally{await pool.end();}`;
      const run = (i) =>
        new Promise((resolve, reject) => {
          const input = {
            refreshHash: "original",
            clientID: f.clientID,
            resource,
            now,
            tokens: token("process-" + i),
          };
          const child = spawn(
            process.execPath,
            ["--input-type=module", "--eval", source],
            {
              env: {
                ...process.env,
                CARRY_SYNTHETIC_DB: f.url,
                CARRY_SYNTHETIC_INPUT: JSON.stringify(input),
              },
              stdio: ["ignore", "pipe", "pipe"],
            },
          );
          let output = "",
            err = "";
          child.stdout.on("data", (b) => (output += b));
          child.stderr.on("data", (b) => (err += b));
          child.on("error", reject);
          child.on("exit", (code) => {
            if (code !== 0) reject(Error("synthetic child failed: " + err));
            else {
              try {
                resolve(JSON.parse(output));
              } catch (e) {
                reject(e);
              }
            }
          });
        });
      const results = await Promise.all([run(1), run(2)]);
      assert.equal(results.filter((r) => r.ok).length, 1);
      assert.equal(results.find((r) => !r.ok).code, "invalid_grant");
      assert.equal(
        (
          await f.pool.query(
            "select value from carry_ai.records where bucket='grant' and id=$1",
            [f.grantID],
          )
        ).rows[0].value.revokedAt,
        now,
      );
    } finally {
      await f.close();
    }
  },
);
