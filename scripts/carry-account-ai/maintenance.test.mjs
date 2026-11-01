import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
const routine = await readFile(new URL('./maintenance.sql', import.meta.url), 'utf8');
const migration = await readFile(new URL('../carry-account-service/supabase/migrations/20261101081026_account_ai_bounded_retention.sql', import.meta.url), 'utf8');

test('hosted retention installs the exact tested routine and keeps client roles denied', async () => {
  assert.ok(migration.startsWith(routine));
  const db = new PGlite();
  try {
    await db.exec("create role anon; create role authenticated; create role service_role;");
    await db.exec(await readFile(new URL('./postgres-schema.sql', import.meta.url), 'utf8'));
    await db.exec(migration);
    await db.exec('grant usage on schema carry_ai to anon,authenticated,service_role;');
    const rights = (await db.query("select has_function_privilege('anon','carry_ai.maintain_records(bigint,integer)','execute') as anon,has_function_privilege('authenticated','carry_ai.maintain_records(bigint,integer)','execute') as authenticated,has_function_privilege('service_role','carry_ai.maintain_records(bigint,integer)','execute') as service")).rows[0];
    assert.deepEqual(rights, {anon:false,authenticated:false,service:true});
    for (const role of ['anon','authenticated']) {
      await db.exec(`set role ${role}`);
      await assert.rejects(db.query('select carry_ai.maintain_records(1000000,1)'), /permission denied/);
      await db.exec('reset role');
    }
  } finally { await db.close(); }
});

test('retention is bounded, preserves receipt identities and live replay evidence, and rejects bad inputs', async () => {
  const db = new PGlite(), now=40*86400000;
  try {
    await db.exec(await readFile(new URL('./postgres-schema.sql', import.meta.url), 'utf8'));
    await db.exec(routine);
    for (const id of ['a','b','c']) await db.query("insert into carry_ai.records(bucket,id,value) values('access',$1,$2)",[id,{expiresAt:now-1}]);
    await db.query("insert into carry_ai.records(bucket,id,value) values('receipt','stable-request',$1),('refresh','live-spent',$2)",[
      {createdAt:0,before:[1],after:[2],mutations:[3],contentHash:'preserved'},
      {expiresAt:now+1,usedAt:now-1}]);
    for (const key of ['a','b','c']) await db.query('insert into carry_ai.rate_limits values($1,null,0,1)',[key]);
    const result=(await db.query('select carry_ai.maintain_records($1,1) as result',[now])).rows[0].result;
    assert.deepEqual(result,{records:1,compactedReceipts:1,rateBuckets:1});
    assert.equal((await db.query("select count(*) from carry_ai.records where bucket='access'")).rows[0].count,2);
    assert.deepEqual((await db.query("select value from carry_ai.records where id='stable-request'")).rows[0].value,{createdAt:0,contentHash:'preserved',undoExpired:true});
    assert.equal((await db.query("select count(*) from carry_ai.records where id='live-spent'")).rows[0].count,1);
    for (const limit of [null,0,1001]) await assert.rejects(db.query('select carry_ai.maintain_records($1,$2)',[now,limit]),/invalid_maintenance_input/);
    await assert.rejects(db.query('select carry_ai.maintain_records(null,1)'),/invalid_maintenance_input/);
    await db.query('select carry_ai.maintain_records($1,1000)',[now]);
    assert.equal((await db.query("select count(*) from carry_ai.records where bucket='access'")).rows[0].count,0);
  } finally { await db.close(); }
});
