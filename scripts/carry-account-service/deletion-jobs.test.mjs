import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID,createHash } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { applyPortableMigrations } from './migration-fixture.mjs';
import { runDeletionStep } from './deletion-jobs.mjs';
const account=randomUUID(),session=randomUUID(),ticket='a'.repeat(64);
async function fixture() {
  const db=new PGlite();
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
    create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id) on delete cascade,not_after timestamptz,oauth_client_id uuid);
    create schema storage;create table storage.objects(bucket_id text,name text,version text);
    grant usage on schema storage to service_role;grant select on storage.objects to service_role;`);
  await db.query('insert into auth.users values($1)',[account]);await db.query('insert into auth.sessions(id,user_id) values($1,$2)',[session,account]);
  await applyPortableMigrations(db);await db.exec('set role service_role');
  await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[account,'synthetic-subject','app.nevestudio.carry','encrypted']);
  const rpc=async(name,args)=>(await db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as result`,args)).rows[0].result;
  const calls=[],fault={};
  const adapter={
    claimDeletion:(a,op)=>rpc('carry_account_deletion_claim',[a,op]),
    deletionCredential:(a,op)=>rpc('carry_account_deletion_credential',[a,op]),
    revokeCredential:async()=>{calls.push('revoke');if(fault.revoke)throw new Error('apple_unavailable');},
    recordRevocation:(a,op,row,hash)=>rpc('carry_account_deletion_revoked',[a,op,row.apple_subject,row.audience,hash]),
    advanceDeletion:(a,op,stage)=>rpc('carry_account_deletion_advance',[a,op,stage]),
    releaseDeletion:(a,op,failed)=>rpc('carry_account_deletion_release',[a,op,failed]),
    cleanupFiles:async()=>{calls.push('files');if(fault.files)throw new Error('storage_unavailable');},
    deleteAuthIdentity:async a=>{calls.push('auth');if(fault.auth)throw new Error('auth_unavailable');await db.exec('reset role');await db.query('delete from auth.users where id=$1',[a]);await db.exec('set role service_role');},
  };
  const request=()=>rpc('carry_account_request_deletion',[account,session,'synthetic-subject','app.nevestudio.carry','encrypted-fresh',ticket]);
  return {db,rpc,adapter,calls,fault,request};
}

test('deletion request persists a private receipt, blocks writes, and is idempotent without reviving credentials',async()=>{
  const f=await fixture();try {
    assert.deepEqual(await f.request(),{status:'deleting'});assert.deepEqual(await f.request(),{status:'deleting'});
    assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'deleting'});
    await assert.rejects(f.rpc('carry_account_deletion_status',['b'.repeat(64)]),/invalid_deletion_receipt/);
    await assert.rejects(f.rpc('carry_account_enroll',[account,'synthetic-subject','app.nevestudio.carry','new-token']),/account_deletion_pending/);
    await assert.rejects(f.rpc('carry_graph_pull',[account,session,0,1]),/account_unavailable/);
    const row=(await f.db.query('select ticket_hash from carry_private.account_deletions')).rows[0];
    assert.equal(row.ticket_hash,createHash('sha256').update(ticket).digest('hex'));assert.notEqual(row.ticket_hash,ticket);
  }finally{await f.db.close();}
});

test('real deletion SQL gates revocation, physical files, graph purge and Auth removal in order',async()=>{
  const f=await fixture();try {
    await f.db.query('insert into carry_private.graph_accounts(account_id) values($1)',[account]);
    await f.request();
    const op=randomUUID();await f.adapter.claimDeletion(account,op);
    await assert.rejects(f.adapter.advanceDeletion(account,op,'purging'),/deletion_revocation_incomplete/);
    await f.adapter.releaseDeletion(account,op,false);
    await runDeletionStep(f.adapter,account); // one credential
    await runDeletionStep(f.adapter,account); // all revoked -> purging
    await runDeletionStep(f.adapter,account); // actual graph purge
    assert.equal((await f.db.query('select count(*)::int as n from carry_private.graph_accounts')).rows[0].n,0);
    assert.deepEqual(f.calls,['revoke','files']);
    await runDeletionStep(f.adapter,account); // Auth removal and independently checked completion
    assert.deepEqual(f.calls,['revoke','files','auth']);
    assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'deleted'});
    assert.equal(await runDeletionStep(f.adapter,account),false);
  }finally{await f.db.close();}
});

test('provider failure keeps durable deletion retryable and never calls later destructive steps',async()=>{
  const f=await fixture();try {
    await f.request();f.fault.revoke=true;
    await assert.rejects(runDeletionStep(f.adapter,account),/apple_unavailable/);
    assert.deepEqual(f.calls,['revoke']);assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'deleting'});
    assert.equal(await runDeletionStep(f.adapter,account),false,'Backoff must survive process restart');
    await f.db.query("update carry_private.account_deletions set retry_at=statement_timestamp()-interval '1 second'");
    f.fault.revoke=false;await runDeletionStep(f.adapter,account);await runDeletionStep(f.adapter,account);
    f.fault.files=true;await assert.rejects(runDeletionStep(f.adapter,account),/storage_unavailable/);
    assert.equal(f.calls.includes('auth'),false);
  }finally{await f.db.close();}
});

test('late callbacks and unregistered future stores cannot bypass deletion fencing',async()=>{
  const f=await fixture();try {
    await f.request();const first=randomUUID(),second=randomUUID();
    await f.adapter.claimDeletion(account,first);
    await f.db.query("update carry_private.account_deletions set lease_until=statement_timestamp()-interval '1 second'");
    await f.adapter.claimDeletion(account,second);
    await assert.rejects(f.adapter.advanceDeletion(account,first,'purging'),/deletion_operation_superseded/);
    await f.adapter.releaseDeletion(account,second,false);
    await runDeletionStep(f.adapter,account);await runDeletionStep(f.adapter,account);
    await f.db.exec('reset role;create table carry_private.future_owned_store(account_id uuid);set role service_role');
    await assert.rejects(runDeletionStep(f.adapter,account),/unregistered_account_store/);
    assert.equal(f.calls.includes('auth'),false);
    await f.db.exec('reset role;set role authenticated');
    await assert.rejects(f.db.query('select public.carry_account_deletion_status($1)',[ticket]),/permission denied/);
  }finally{await f.db.close();}
});

test('deletion status uses a private receipt after Auth deletion and never exposes profile or internal stage',async()=>{
  const {createDeletionStatusHandler}=await import('./deletion-status-http.mjs');
  let calls=0;
  const handler=createDeletionStatusHandler({deletionStatus:async value=>{calls++;assert.equal(value,ticket);return {status:'deleting',accountID:account,stage:'purging'};}});
  const request=token=>new Request('https://account-qa.invalid/functions/v1/carry-account-status',{method:'POST',headers:{Authorization:'Bearer '+token}});
  assert.equal((await handler(request('user-access-jwt'))).status,401);assert.equal(calls,0);
  const response=await handler(request(ticket));assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{status:'deleting'});assert.equal(response.headers.get('cache-control'),'no-store');
});

test('deletion cannot complete while actual owned files or the Auth identity remain',async()=>{
  const f=await fixture();try {
    await f.request();await runDeletionStep(f.adapter,account);await runDeletionStep(f.adapter,account);
    await f.db.exec('reset role');await f.db.query('insert into storage.objects values($1,$2,$3)',['carry-account-assets',account+'/synthetic-file',randomUUID()]);await f.db.exec('set role service_role');
    await assert.rejects(runDeletionStep(f.adapter,account),/deletion_files_pending/);
    assert.equal(f.calls.includes('auth'),false);
    await f.db.exec('reset role');await f.db.query('delete from storage.objects');await f.db.query("update carry_private.account_deletions set retry_at=statement_timestamp()-interval '1 second'");await f.db.exec('set role service_role');
    await runDeletionStep(f.adapter,account);
    const dishonest={...f.adapter,deleteAuthIdentity:async()=>{}};
    await assert.rejects(runDeletionStep(dishonest,account),/deletion_auth_pending/);
    assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'deleting'});
  }finally{await f.db.close();}
});
