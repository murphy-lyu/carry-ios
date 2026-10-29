import { applyPortableMigrations } from './migration-fixture.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
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
  await applyPortableMigrations(db);
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
const beginUpload = async (db,item,owner=account,token=session) =>
  (await db.query('select public.carry_asset_upload_begin($1,$2,$3) as result',[owner,token,item.id])).rows[0].result;
const createdUpload = async (db,attempt,location) => {
  if(location===undefined) {
    const item=(await db.query('select asset.id,asset.sha256 from carry_private.asset_upload_attempts attempt join carry_private.assets asset on asset.id=attempt.asset_id and asset.account_id=attempt.account_id where attempt.id=$1',[attempt.id])).rows[0];
    location='https://storage-qa.invalid/storage/v1/upload/resumable/'+Buffer.from(`carry-account-assets/${account}/${item.id}/${item.sha256}/${attempt.creationID??randomUUID()}`).toString('base64url');
  }
  return (await db.query('select public.carry_asset_upload_created($1,$2,$3,$4) as result',[account,attempt.id,attempt.creationID,location])).rows[0].result;
};
const claimUpload = async (db,attempt,operation=randomUUID(),method='HEAD',offset=null) =>
  (await db.query('select public.carry_asset_upload_claim($1,$2,$3,$4,$5,$6) as result',[account,session,attempt.id,operation,method,offset])).rows[0].result;
const finishUpload = async (db,attempt,operation,offset,gone=false) =>
  db.query('select public.carry_asset_upload_finish($1,$2,$3,$4,$5)',[account,attempt.id,operation,offset,gone]);

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

test('upload creation is durable and reused before any second upstream creation', async () => {
  const db=await database();
  try {
    await db.query('insert into carry_private.asset_budgets values($1,$2,3)',[account,maximum*3]);
    const item=asset(); await reserve(db,item);
    const attempt=await beginUpload(db,item);
    assert.equal(attempt.status,'create'); assert.ok(attempt.creationID);
    assert.deepEqual(await beginUpload(db,item),{status:'creating',id:attempt.id});
    await assert.rejects(createdUpload(db,{...attempt,creationID:null}), /upload_attempt_not_found/);
    await assert.rejects(createdUpload(db,attempt,'https://invalid.example/arbitrary'), /invalid_upload_location/);
    assert.deepEqual(await createdUpload(db,attempt),{status:'active',id:attempt.id});
    assert.deepEqual(await createdUpload(db,attempt),{status:'active',id:attempt.id});
    assert.deepEqual(await beginUpload(db,item),{status:'active',id:attempt.id});
    assert.equal((await db.query('select count(*)::int as n from carry_private.asset_upload_attempts')).rows[0].n,1);
    await assert.rejects(beginUpload(db,item,other,otherSession), /asset_not_found/);
  } finally { await db.close(); }
});

test('lost creation responses consume durable quota and late responses never replace a newer attempt', async () => {
  const db=await database();
  try {
    await db.query('insert into carry_private.asset_budgets values($1,$2,3)',[account,maximum*3]);
    const item=asset(); await reserve(db,item);
    const attempts=[];
    for(let i=0;i<3;i++) {
      const attempt=await beginUpload(db,item); assert.equal(attempt.status,'create'); attempts.push(attempt);
      await db.query("update carry_private.asset_upload_attempts set lease_until=statement_timestamp()-interval '1 second' where id=$1",[attempt.id]);
    }
    await assert.rejects(beginUpload(db,item), /asset_budget_exceeded/);
    await assert.rejects(reserve(db,asset()), /asset_budget_exceeded/);
    const late=await createdUpload(db,attempts[0]);
    assert.equal(late.status,'deleting');
    assert.deepEqual(await createdUpload(db,attempts[2]),{id:attempts[2].id,status:'active'});
    assert.deepEqual(await beginUpload(db,item),{id:attempts[2].id,status:'active'});
    assert.ok((await db.query('select location from carry_private.asset_upload_attempts where id=$1',[attempts[0].id])).rows[0].location.startsWith('https://storage-qa.invalid/storage/v1/upload/resumable/'));
  } finally { await db.close(); }
});

test('upload operation fencing rejects concurrent and late requests without regressing offsets', async () => {
  const db=await database();
  try {
    await db.query('insert into carry_private.asset_budgets values($1,$2,3)',[account,maximum*3]);
    const item=asset(); await reserve(db,item);
    const attempt=await beginUpload(db,item); await createdUpload(db,attempt);
    const oldOperation=randomUUID(),currentOperation=randomUUID();
    await claimUpload(db,attempt,oldOperation,'PATCH',0);
    await assert.rejects(claimUpload(db,attempt,currentOperation), /upload_busy/);
    await db.query("update carry_private.asset_upload_attempts set lease_until=statement_timestamp()-interval '1 second' where id=$1",[attempt.id]);
    await claimUpload(db,attempt,currentOperation);
    await assert.rejects(finishUpload(db,attempt,oldOperation,2), /upload_operation_superseded/);
    await finishUpload(db,attempt,currentOperation,3);
    await assert.rejects(claimUpload(db,attempt,randomUUID(),'PATCH',0), /upload_offset_mismatch/);
    const next=randomUUID(); assert.equal((await claimUpload(db,attempt,next,'PATCH',3)).offset,3);
    await assert.rejects(finishUpload(db,attempt,next,1), /invalid_upload_offset/);
    await finishUpload(db,attempt,next,item.byteCount);
    assert.equal((await db.query('select state from carry_private.assets where id=$1',[item.id])).rows[0].state,'pending','TUS completion alone must not publish verified data');
    const head=randomUUID(); await claimUpload(db,attempt,head); await finishUpload(db,attempt,head,null,true);
    await assert.rejects(claimUpload(db,attempt), /upload_attempt_not_found/);
  } finally { await db.close(); }
});

test('account deletion keeps late upload locations for cleanup and rejects further client activity', async () => {
  const db=await database();
  try {
    await db.query('insert into carry_private.asset_budgets values($1,$2,3)',[account,maximum*3]);
    const item=asset(); await reserve(db,item);
    const attempt=await beginUpload(db,item);
    await db.query('select public.carry_account_begin_delete($1,$2,$3,$4)',[account,'subject-'+account,'app.nevestudio.carry','encrypted']);
    assert.deepEqual(await createdUpload(db,attempt),{id:attempt.id,status:'deleting'});
    await assert.rejects(beginUpload(db,item), /account_unavailable/);
    await assert.rejects(claimUpload(db,attempt), /account_unavailable/);
    await db.exec('reset role; set role authenticated');
    await assert.rejects(beginUpload(db,item), /permission denied/);
    await assert.rejects(createdUpload(db,attempt), /permission denied/);
    await assert.rejects(claimUpload(db,attempt), /permission denied/);
    await assert.rejects(finishUpload(db,attempt,randomUUID(),null), /permission denied/);
    await assert.rejects(db.query('select * from carry_private.asset_upload_attempts'), /permission denied/);
  } finally { await db.close(); }
});
