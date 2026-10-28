import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
const account = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const session = '00000000-0000-0000-0000-000000000003';
const otherSession = '00000000-0000-0000-0000-000000000004';
const maximum = 50 * 1024 * 1024;
async function database() {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create table auth.users(id uuid primary key);
    create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);
    insert into auth.users values('${account}'),('${other}');
    insert into auth.sessions values('${session}','${account}',null,null),('${otherSession}','${other}',null,null);`);
  const directory = new URL('./supabase/migrations/', import.meta.url);
  for (const name of (await readdir(directory)).filter(n => n.endsWith('.sql')).sort()) await db.exec(await readFile(new URL(name,directory),'utf8'));
  await db.exec('set role service_role');
  for (const key of [account,other]) await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[key,'subject-'+key,'app.nevestudio.carry','test-encrypted']);
  return db;
}
function asset({ owner = account, kind = 'attachment', slot = 'file', bytes = 7, mime = 'application/octet-stream' } = {}) {
  const entityID = randomUUID(), sha256 = createHash('sha256').update('synthetic bytes').digest('hex');
  const hex = createHash('sha256').update(`${owner}/${entityID}/${slot}/${sha256}`).digest('hex').slice(0,32);
  const id = [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
  return { id, entityID, entityKind: kind, slot, sha256, byteCount: bytes, contentType: mime };
}
const reserve = async (db, item, owner = account, token = session) =>
  (await db.query('select public.carry_asset_reserve($1,$2,$3) as result',[owner,token,item])).rows[0].result;
const confirm = async (db, item, sha = item.sha256, bytes = item.byteCount, owner = account, token = session) =>
  (await db.query('select public.carry_asset_confirm($1,$2,$3,$4,$5) as result',[owner,token,item.id,sha,bytes])).rows[0].result;

test('asset reservations bind identities and worst-case physical quota until verified or cleaned', async () => {
  const db = await database();
  try {
    const first = asset(), second = asset(), third = asset();
    await assert.rejects(reserve(db,first), /asset_budget_not_configured/);
    await db.query('insert into carry_private.asset_budgets values($1,$2,2)',[account,maximum*2+first.byteCount]);
    assert.deepEqual(await reserve(db,first),{id:first.id,status:'pending'});
    assert.deepEqual(await reserve(db,first),{id:first.id,status:'pending'});
    await assert.rejects(reserve(db,{...first,byteCount:8}), /asset_identity_mismatch/);
    assert.deepEqual(await reserve(db,second),{id:second.id,status:'pending'});
    await assert.rejects(reserve(db,third), /asset_budget_exceeded/);
    // Merely passing a deadline must not free a potentially existing object.
    await db.query("update carry_private.assets set expires_at=statement_timestamp()-interval '1 second' where id=$1",[second.id]);
    await assert.rejects(reserve(db,third), /asset_budget_exceeded/);
    assert.deepEqual(await confirm(db,first),{id:first.id,status:'verified'});
    assert.deepEqual(await confirm(db,first),{id:first.id,status:'verified'});
    await assert.rejects(confirm(db,first,'0'.repeat(64)), /asset_verification_mismatch/);
    assert.equal((await db.query('select state from carry_private.assets where id=$1',[first.id])).rows[0].state,'verified');
    assert.deepEqual(await reserve(db,third),{id:third.id,status:'pending'});
    assert.deepEqual(await confirm(db,second),{id:second.id,status:'rejected'});
    await assert.rejects(reserve(db,second), /asset_cleanup_pending/);
    await assert.rejects(reserve(db,asset()), /asset_budget_exceeded/);
    // Confirmation of physical removal is a separate trusted cleanup action;
    // no automatic expiry path in this ledger deletes/reuses ownership.
    assert.equal((await db.query('select count(*)::int as count from carry_private.assets')).rows[0].count,3);
  } finally { await db.close(); }
});

test('asset service refuses malformed scope, cross-account, OAuth, revoked and deleting identities', async () => {
  const db = await database();
  try {
    await db.query('insert into carry_private.asset_budgets values($1,$2,2)',[account,maximum*2]);
    const valid = asset();
    for (const invalid of [null,[],{}, {...valid,extra:'field'}, {...valid,id:randomUUID()},
      asset({kind:'trip',slot:'file'}),asset({kind:'trip',slot:'background:../x'}),asset({kind:'trip',slot:'background:a\\b'}),
      asset({bytes:0}),asset({bytes:maximum+1}),asset({mime:'text/plain\r\nInjected: yes'}),
      {...valid,byteCount:1.5},{...valid,sha256:null}]) await assert.rejects(reserve(db,invalid));
    await assert.rejects(reserve(db,valid,other,session), /session_expired/);
    await assert.rejects(reserve(db,valid,account,otherSession), /session_expired/);
    await assert.rejects(reserve(db,asset({owner:other})), /invalid_asset/);
    await db.exec('reset role');
    await db.query('update auth.sessions set oauth_client_id=$1 where id=$2',[randomUUID(),session]);
    await db.exec('set role service_role');
    await assert.rejects(reserve(db,valid), /session_expired/);
    await db.exec('reset role');
    await db.query('update auth.sessions set oauth_client_id=null where id=$1',[session]);
    await db.exec('set role service_role');
    await reserve(db,valid);
    assert.deepEqual(await confirm(db,valid,'0'.repeat(64)),{id:valid.id,status:'rejected'});
    await assert.rejects(confirm(db,valid), /asset_cleanup_pending/);
    await assert.rejects(confirm(db,valid,valid.sha256,valid.byteCount,other,otherSession), /asset_not_found/);
    await db.query('select public.carry_account_begin_delete($1,$2,$3,$4)',[account,'subject-'+account,'app.nevestudio.carry','encrypted']);
    await assert.rejects(reserve(db,asset()), /account_unavailable/);
    await db.exec('reset role; set role authenticated');
    await assert.rejects(db.query('select * from carry_private.assets'), /permission denied/);
    await assert.rejects(reserve(db,valid), /permission denied/);
    await assert.rejects(confirm(db,valid), /permission denied/);
    await db.exec('reset role; set role anon');
    await assert.rejects(reserve(db,valid), /permission denied/);
  } finally { await db.close(); }
});

test('asset slots preserve thumbnail, original, library and named background identities', async () => {
  const db = await database();
  try {
    await db.query('insert into carry_private.asset_budgets values($1,$2,10)',[account,maximum*10]);
    for (const item of [asset({kind:'photo',slot:'thumbnail'}),asset({kind:'photo',slot:'original'}),
      asset({kind:'libraryItem',slot:'image'}),asset({kind:'trip',slot:'background:東京.heic'})]) {
      assert.deepEqual(await reserve(db,item),{id:item.id,status:'pending'});
    }
    await db.exec('reset role');
    await db.query("update auth.sessions set not_after=statement_timestamp()-interval '1 second' where id=$1",[session]);
    await db.exec('set role service_role');
    await assert.rejects(reserve(db,asset()), /session_expired/);
    await db.exec('reset role'); await db.query('delete from auth.sessions where id=$1',[session]); await db.exec('set role service_role');
    await assert.rejects(reserve(db,asset()), /session_expired/);
  } finally { await db.close(); }
});
