import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {recoverHeldDeletion} from './deletion-recovery.mjs';
import {createAccountHandler} from './lifecycle.mjs';
import {fixture,account,session,other,ticket,subject,audience} from './deletion-recovery-fixture.mjs';

test('recovery requires explicit provider-completion evidence, not elapsed drain or a still-present file',async()=>{
 const f=await fixture({files:true,evidence:false});try{
  await assert.rejects(f.prepare(),/recovery_not_ready/);
  assert.equal((await f.db.query("select status from carry_private.carry_apple_credentials")).rows[0].status,'deleting');
  await f.db.query("update carry_private.account_deletions set recovery_provider_cleared_at=now()-interval '1 minute',recovery_provider_evidence_digest=$1",['e'.repeat(64)]);
  const p=await f.prepare();assert.equal(p.assets.length,1);
 }finally{await f.db.close();}
});

test('verified held recovery keeps graph IDs, fences cleanup, retires old grants and returns a cancelled receipt',async()=>{
 const f=await fixture({files:true});try{
  const stale=randomUUID();
  assert.equal(await f.rpc('carry_account_deletion_claim',[account,stale]),null);
  assert.equal(await f.rpc('carry_asset_cleanup_claim',[account,stale]),null);
  await f.rpc('carry_asset_cleanup_empty',[account]);
  await assert.rejects(f.rpc('carry_asset_cleanup_finish',[account,randomUUID(),stale]),/cleanup_operation_superseded/);
  const grant=randomUUID();await f.db.query("insert into carry_ai.records(bucket,id,account_id,value) values('grant',$1,$2,$3)",[grant,account,{revokedAt:null}]);
  const p=await f.prepare();const result=await f.commit(p);assert.deepEqual(result,{status:'cancelled'});
  assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'cancelled'});
  assert.deepEqual(await f.commit(p),{status:'cancelled'});
  assert.equal((await f.db.query('select count(*)::int n from carry_private.graph_entities where id=$1',[f.trip])).rows[0].n,1);
  assert.equal((await f.db.query("select state from carry_private.assets")).rows[0].state,'verified');
  assert.equal((await f.db.query("select state from carry_private.asset_upload_attempts")).rows[0].state,'complete');
  const credential=(await f.db.query('select status,revoked_at,encrypted_token from carry_private.carry_apple_credentials')).rows[0];
  assert.deepEqual(credential,{status:'active',revoked_at:null,encrypted_token:'fresh-encrypted-apple-token'});
  assert.ok((await f.db.query("select value from carry_ai.records where id=$1",[grant])).rows[0].value.revokedAt);
  assert.equal(await f.rpc('carry_account_deletion_claim',[account,stale]),null);
  await f.rpc('carry_account_request_deletion',[account,session,subject,audience,'second-fresh-token','b'.repeat(64)]);
  assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'cancelled'});
  assert.deepEqual(await f.rpc('carry_account_deletion_status',['b'.repeat(64)]),{status:'deleting'});
 }finally{await f.db.close();}
});

test('wrong identity, unsafe stage, outstanding lease and expired recovery fail closed',async()=>{
 const f=await fixture();try{
  for(const o of [{account:other},{session:randomUUID()},{ticket:'b'.repeat(64)},{subject:'other'},{audience:'other'}])await assert.rejects(f.prepare(randomUUID(),o));
  for(const stage of ['revoking','deleting_auth','deleted']){
   await f.db.query('update carry_private.account_deletions set stage=$1',[stage]);await assert.rejects(f.prepare(),/recovery_not_ready/);
  }
  await f.db.query("update carry_private.account_deletions set stage='purging',recovery_hold_at=now()");await assert.rejects(f.prepare(),/recovery_not_ready/);
  await f.db.query("update carry_private.account_deletions set recovery_hold_at=now()-interval '5 minutes'");
  const p=await f.prepare();await assert.rejects(f.prepare(),/recovery_not_ready/);
  await f.db.query("update carry_private.account_deletions set recovery_lease_until=now()-interval '1 second'");await assert.rejects(f.commit(p),/recovery_operation_superseded/);
 }finally{await f.db.close();}
});

test('graph, asset, provider version or proof changes never activate the account',async()=>{
 for(const mutation of ['graph','asset','version','proof']){
  const f=await fixture({files:true});try{
   const p=await f.prepare();
   if(mutation==='graph')await f.db.query("update carry_private.graph_entities set fields=fields||'{\"name\":\"Changed\"}' where id=$1",[f.trip]);
   if(mutation==='asset')await f.db.query("update carry_private.assets set byte_count=15");
   if(mutation==='version'){await f.db.exec('reset role');await f.db.query('update storage.objects set version=$1',[randomUUID()]);await f.db.exec('set role service_role');}
   if(mutation==='proof')p.assets=[];
   await assert.rejects(f.commit(p),/recovery_snapshot_changed|recovery_files_missing|recovery_proof_mismatch/);
   assert.equal((await f.db.query('select status from carry_private.carry_apple_credentials')).rows[0].status,'deleting');
  }finally{await f.db.close();}
 }
});

test('public client roles cannot prepare/commit recovery or bypass private worker fences',async()=>{
 const f=await fixture();try{
  await f.db.exec('reset role');
  for(const role of ['anon','authenticated']){
   await f.db.exec('set role '+role);
   await assert.rejects(f.prepare(),/permission denied/);
   await assert.rejects(f.rpc('carry_asset_cleanup_claim',[account,randomUUID()]),/permission denied/);
   await f.db.exec('reset role');
  }
 }finally{await f.db.close();}
});

test('external verification or session revocation failure cannot commit; no recovery without a validated prepare',async()=>{
 for(const failure of ['prepare','inspect','sessions','corrupt']){
  const calls=[],owner={id:account},asset={accountID:account,id:randomUUID(),sha256:'a'.repeat(64),byteCount:1,storageVersion:randomUUID()};
  const adapter={prepareRecovery:async(a,i,t,op)=>{calls.push('prepare');if(failure==='prepare')throw Error('held');return{status:'verify',operationID:op,fingerprints:{graph:'b'.repeat(64),assets:'c'.repeat(64)},assets:[asset]};},
   inspectRecoveryAsset:async()=>{calls.push('inspect');if(failure==='inspect')throw Error('offline');return{sha256:asset.sha256,byteCount:failure==='corrupt'?2:1};},
   revokeOtherSessions:async()=>{calls.push('sessions');if(failure==='sessions')throw Error('auth unavailable');},
   commitRecovery:async()=>{calls.push('commit');return{status:'cancelled'};}};
  await assert.rejects(recoverHeldDeletion(adapter,{account:owner,identity:{},token:'new',ticket}));assert.ok(!calls.includes('commit'));
 }
});

test('recover HTTP action binds fresh proof and code to current account, exposing no token or data',async()=>{
 let calls=0;const identity={subject,audience};
 const handler=createAccountHandler({authenticate:async()=>({id:account,appleSubjects:[subject]}),rateLimit:async()=>true,
  verifyApple:async()=>identity,exchangeCode:async()=>({idToken:'fresh-exchanged-token',refreshToken:'fresh-private-refresh'}),
  recoverDeletion:async(a,i,t,r)=>{calls++;assert.equal(a.id,account);assert.equal(i.subject,subject);assert.equal(t,'fresh-private-refresh');assert.equal(r,ticket);return{status:'cancelled'};}});
 const request=body=>new Request('https://synthetic.invalid',{method:'POST',headers:{Authorization:'Bearer synthetic','content-type':'application/json'},body:JSON.stringify(body)});
 const body={action:'recover',idToken:'fresh-native-identity',authorizationCode:'fresh-code',nonce:'a'.repeat(43),deletionReceipt:ticket};
 const response=await handler(request(body));assert.deepEqual(await response.json(),{status:'cancelled'});assert.equal(calls,1);
 for(const invalid of [{...body,deletionReceipt:undefined},{...body,accountID:other},{...body,nonce:'short'}])assert.equal((await handler(request(invalid))).status,400);
 assert.equal(calls,1);
});


test('old native JWT session IDs stay rejected after recovery even if Auth retains their rows',async()=>{
 const f=await fixture();try{
  const old=randomUUID(),fresh=randomUUID();
  await f.db.exec('reset role');await f.db.query('insert into auth.sessions(id,user_id) values($1,$2)',[old,account]);await f.db.exec('set role service_role');
  const p=await f.prepare();await f.commit(p);
  await assert.rejects(f.rpc('carry_account_require_session',[account,old]),/session_expired/);
  await assert.rejects(f.rpc('carry_graph_pull',[account,old,0,10]),/session_expired/);
  await f.rpc('carry_account_require_session',[account,session]);
  await f.db.exec('reset role');await f.db.query('insert into auth.sessions(id,user_id) values($1,$2)',[fresh,account]);await f.db.exec('set role service_role');
  await f.rpc('carry_account_require_session',[account,fresh]);
  await f.rpc('carry_account_request_deletion',[account,session,subject,audience,'later-fresh-token','b'.repeat(64)]);
  await assert.rejects(f.rpc('carry_account_require_session',[account,old]),/session_expired/);
 }finally{await f.db.close();}
});

test('recovery availability is coarse, operator-gated, and withdrawn while inspection holds a lease',async()=>{
 const f=await fixture({files:true,evidence:false});try{
  assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'deleting'});
  await f.db.query("update carry_private.account_deletions set recovery_provider_cleared_at=now(),recovery_provider_evidence_digest=$1 where account_id=$2",['e'.repeat(64),account]);
  assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'recovery_available'});
  const p=await f.prepare();
  assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'deleting'});
  await f.commit(p);
  assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'cancelled'});
 }finally{await f.db.close();}
});
