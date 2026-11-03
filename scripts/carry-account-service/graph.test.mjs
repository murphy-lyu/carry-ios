import { applyPortableMigrations } from './migration-fixture.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { graphSchema } from './graph-schema.mjs';
const account = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const session = '00000000-0000-0000-0000-000000000003';
const otherSession = '00000000-0000-0000-0000-000000000004';
const id = () => randomUUID();
function fields(kind) {
  return Object.fromEntries(Object.entries(graphSchema[kind].fields).filter(([,r]) => !r.optional).map(([k,r]) => [k,
    r.values?.[0] ?? (r.type==='string' ? (r.format==='date-time' ? '2026-11-01T00:00:00Z' : r.format==='uuid' ? id() : '')
      : r.type==='number' ? Math.max(0,r.min) : r.type==='array' ? [] : false)]));
}
const trip = (entityID=id()) => ({id:entityID,kind:'trip',action:'create',baseVersion:0,fields:{...fields('trip'),name:'Tokyo',days:3}});
const child = (kind,parentID,entityID=id()) => ({id:entityID,kind,action:'create',baseVersion:0,parentID,fields:fields(kind)});
async function database() {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create table auth.users(id uuid primary key);
    create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);
    create schema storage;
    create table storage.objects(bucket_id text,name text,version text,archived_at timestamptz,is_delete_marker boolean not null default false,primary key(bucket_id,name,version));
    grant usage on schema storage to service_role;
    grant select,insert,update,delete on storage.objects to service_role;
    insert into auth.users values('${account}'),('${other}');
    insert into auth.sessions values('${session}','${account}',null,null),('${otherSession}','${other}',null,null);`);
  await applyPortableMigrations(db);
  await db.exec('set role service_role');
  for (const key of [account,other]) await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[key,'subject-'+key,'app.nevestudio.carry','test-encrypted']);
  return db;
}
async function apply(db,mutations,{requestID=id(),owner=account,token=session}={}) {
  return (await db.query('select public.carry_graph_apply($1,$2,$3) as result',[owner,token,{requestID,mutations}])).rows[0].result;
}
async function pull(db,cursor=0,limit=100,owner=account,token=session) {
  return (await db.query('select public.carry_graph_pull($1,$2,$3,$4) as result',[owner,token,cursor,limit])).rows[0].result;
}
async function entity(db,entityID,owner=account) {
  return (await db.query('select carry_private.graph_snapshot(e) as entity from carry_private.graph_entities e where account_id=$1 and id=$2',[owner,entityID])).rows[0]?.entity;
}
const patch = (e,changes,base=e.version) => ({id:e.id,kind:e.kind,action:'patch',baseVersion:base,fields:changes});
const remove = e => ({id:e.id,kind:e.kind,action:'delete',baseVersion:e.version,baseSubtreeVersion:e.subtreeVersion});

// Synthetic verified bytes use the same reserve → provider metadata → trusted
// inspection path as the service. No graph test bypasses the reference guard.
async function verifiedAsset(db,entityID,entityKind,slot,{owner=account,token=session,verify=true}={}) {
  await db.query('insert into carry_private.asset_budgets values($1,1073741824,20) on conflict do nothing',[owner]);
  const sha='a'.repeat(64),assetID=(await db.query('select carry_private.asset_identity($1,$2,$3,$4) as id',[owner,entityID,slot,sha])).rows[0].id;
  await db.query('select public.carry_asset_reserve($1,$2,$3)',[owner,token,{id:assetID,entityID,entityKind,slot,sha256:sha,byteCount:7,contentType:'application/octet-stream'}]);
  const version=id(),name=`${owner}/${assetID}/${sha}`;
  await db.query("insert into storage.objects values('carry-account-assets',$1,$2,null,false)",[name,version]);
  if(verify) assert.equal((await db.query('select public.carry_asset_inspection_finish($1,$2,$3,$4,$5,7) as result',[owner,token,assetID,version,sha])).rows[0].result.status,'verified');
  return {id:assetID,version,name};
}

// Independent databases make each scenario a real migration + transaction test.
test('effective migrated PostgreSQL schema matches current wire manifest',async()=>{
  const db=await database();try{
    assert.deepEqual((await db.query('select carry_private.graph_schema() as schema')).rows[0].schema,graphSchema);
  }finally{await db.close();}
});
test('account graph creates and reads a full synthetic plan, with contiguous cursor pages',async()=>{
  const db=await database(); try {
    const t=trip(),s=child('section',t.id),p=child('packingItem',s.id),d=child('day',t.id),stop=child('stop',d.id),transport=child('transport',d.id),hotel=child('lodging',t.id);
    const result=await apply(db,[t,s,p,d,stop,transport,hotel]);
    assert.equal(result.status,'saved_to_account');
    const all=[]; let cursor=0,more=true;
    while(more){const page=await pull(db,cursor,2);all.push(...page.changes);cursor=page.cursor;more=page.hasMore;}
    assert.equal(cursor,result.cursor);
    assert.deepEqual(all.map(c=>c.sequence),Array.from({length:cursor},(_,i)=>i+1));
    assert.equal(new Set(all.map(c=>c.entity.id)).size,7);
    assert.equal((await entity(db,t.id)).subtreeVersion,cursor);
    assert.equal((await pull(db,cursor)).changes.length,0);
  } finally {await db.close();}
});
test('lost response retry is exactly once and canonical JSON key order is irrelevant',async()=>{
  const db=await database();try{
    const t=trip(),requestID=id();const result=await apply(db,[t],{requestID});
    assert.deepEqual(await apply(db,[{fields:t.fields,baseVersion:0,action:'create',kind:'trip',id:t.id}],{requestID}),result);
    await assert.rejects(apply(db,[{...t,fields:{...t.fields,name:'Changed'}}],{requestID}),/request_id_reused/);
    assert.equal((await entity(db,t.id)).version,1);
  }finally{await db.close();}
});
test('independent fields merge; competing fields preserve both versions in structured conflict',async()=>{
  const db=await database();try{
    const t=trip();await apply(db,[t]);const initial=await entity(db,t.id);
    await apply(db,[patch(initial,{name:'Edited by phone'})]);
    await apply(db,[patch(initial,{destinationCity:'Tokyo, Japan'})]);
    const e=await entity(db,t.id);assert.equal(e.fields.name,'Edited by phone');assert.equal(e.fields.destinationCity,'Tokyo, Japan');
    await assert.rejects(apply(db,[patch(initial,{name:'AI proposal'})]),error=>{
      assert.equal(error.message,'field_conflict'); const detail=JSON.parse(error.detail);
      assert.equal(detail.current.fields.name,'Edited by phone');assert.deepEqual(detail.fields,['name']);assert.equal(detail.proposed.name,'AI proposal');return true;
    });
    assert.equal((await entity(db,t.id)).version,3);
  }finally{await db.close();}
});
test('invalid late mutation rolls back entities, receipts and cursor as a single transaction',async()=>{
  const db=await database();try{
    const t=trip(),invalid=child('packingItem',id());
    await assert.rejects(apply(db,[t,invalid]),/invalid_parent|foreign key/);
    assert.equal(await entity(db,t.id),undefined);assert.equal((await pull(db)).cursor,0);
    for(const table of ['graph_accounts','graph_entities','graph_receipts','graph_changes']){
      assert.equal((await db.query(`select count(*)::int as n from carry_private.${table}`)).rows[0].n,0);
    }
  }finally{await db.close();}
});
test('parent delete detects concurrent descendants, cascades atomically and cannot resurrect on retry',async()=>{
  const db=await database();try{
    const t=trip(),s=child('section',t.id),p=child('packingItem',s.id);
    await apply(db,[t,s,p]);const stale=await entity(db,t.id);const item=await entity(db,p.id);
    await apply(db,[patch(item,{isPacked:true})]);
    await assert.rejects(apply(db,[remove(stale)]),/subtree_conflict/);
    await apply(db,[remove(await entity(db,t.id))]);
    for(const key of [t.id,s.id,p.id])assert.ok((await entity(db,key)).deletedAt);
    await assert.rejects(apply(db,[patch(item,{isPacked:false})]),/deleted_entity/);
    await assert.rejects(apply(db,[t]),/entity_exists/);
    const root=await entity(db,t.id);await apply(db,[{...remove(root),action:'restore'}]);
    for(const key of [t.id,s.id,p.id])assert.equal((await entity(db,key)).deletedAt,null);
  }finally{await db.close();}
});
test('restoring a parent leaves independently deleted children in the trash',async()=>{
  const db=await database();try{
    const t=trip(),s=child('section',t.id),p=child('packingItem',s.id);await apply(db,[t,s,p]);
    await apply(db,[remove(await entity(db,p.id))]);await apply(db,[remove(await entity(db,t.id))]);
    const e=await entity(db,t.id);await apply(db,[{...remove(e),action:'restore'}]);
    assert.equal((await entity(db,t.id)).deletedAt,null);assert.ok((await entity(db,p.id)).deletedAt);
    await db.exec('reset role');await db.query("update carry_private.graph_entities set deleted_at=now()-interval '31 days' where id=$1",[p.id]);await db.exec('set role service_role');
    await assert.rejects(apply(db,[{...remove(await entity(db,p.id)),action:'restore'}]),/restore_expired/);
  }finally{await db.close();}
});
test('moves publish both old and new ancestor metadata and reject cycles or parent-kind mismatch',async()=>{
  const db=await database();try{
    const t=trip(),d1=child('day',t.id),d2=child('day',t.id),s=child('stop',d1.id);d2.fields.sortOrder=1;await apply(db,[t,d1,d2,s]);
    const old1=await entity(db,d1.id),old2=await entity(db,d2.id),e=await entity(db,s.id);
    const result=await apply(db,[{...patch(e,{}),action:'move',parentID:d2.id}]);
    assert.equal((await entity(db,s.id)).parentID,d2.id);
    assert.ok((await entity(db,d1.id)).subtreeVersion>old1.subtreeVersion);assert.ok((await entity(db,d2.id)).subtreeVersion>old2.subtreeVersion);
    assert.ok(result.changes.some(c=>c.entity.id===d1.id));assert.ok(result.changes.some(c=>c.entity.id===d2.id));
    // Self parent would produce an infinite ancestor walk; must reject BEFORE recording.
    await assert.rejects(apply(db,[{...patch(await entity(db,d1.id),{}),action:'move',parentID:s.id}]),/invalid_parent/);
  }finally{await db.close();}
});
test('shrinking dates or duplicating days fails atomically; coordinated edits succeed',async()=>{
  const db=await database();try{
    const t=trip(),d=child('day',t.id);d.fields.sortOrder=3;await apply(db,[t,d]);
    const e=await entity(db,t.id);await assert.rejects(apply(db,[patch(e,{days:1})]),/trip_date_impact/);
    await apply(db,[patch(e,{days:1}),patch(await entity(db,d.id),{sortOrder:1})]);
    const duplicate=child('day',t.id);duplicate.fields.sortOrder=1;await assert.rejects(apply(db,[duplicate]),/duplicate_day/);
  }finally{await db.close();}
});
test('schema rejects unauthorized fields, invalid time zones, invalid amounts and malformed patches',async()=>{
  const db=await database();try{
    const t=trip();await apply(db,[t]);const e=await entity(db,t.id);
    for(const invalid of [null,[],{owner:other},{days:1.2},{days:-1},{latitude:91}])await assert.rejects(apply(db,[{...patch(e,{}),fields:invalid}]),/invalid_patch|unknown_field|invalid_field/);
    const d=child('day',t.id),s=child('stop',d.id);s.fields.timeZoneId='Mars/Olympus';await assert.rejects(apply(db,[d,s]),/invalid_field/);
    s.fields.timeZoneId='Asia/Tokyo';s.fields.costAmount=100;await assert.rejects(apply(db,[d,s]),/cost_currency_required/);
    s.fields.costCurrencyCode='JPY';await apply(db,[d,s]);
  }finally{await db.close();}
});
test('server-derived account and active session are mandatory; direct client SQL is denied',async()=>{
  const db=await database();try{
    const t=trip();await apply(db,[t]);
    await assert.rejects(apply(db,[trip()],{owner:other,token:session}),/session_expired/);
    assert.equal((await pull(db,0,100,other,otherSession)).changes.length,0);
    await assert.rejects(apply(db,[patch(await entity(db,t.id),{name:'stolen'})],{owner:other,token:otherSession}),/entity_not_found/);
    for(const role of ['anon','authenticated']){
      await db.exec(`reset role;set role ${role}`);
      await assert.rejects(pull(db),/permission denied/);
      await assert.rejects(db.query('select * from carry_private.graph_entities'),/permission denied/);
    }
    await db.exec('reset role');await db.query('delete from auth.sessions where id=$1',[session]);await db.exec('set role service_role');
    await assert.rejects(pull(db),/session_expired/);
  }finally{await db.close();}
});
test('deletion-pending account immediately stops all graph reads and writes',async()=>{
  const db=await database();try{
    await apply(db,[trip()]);await db.query('select public.carry_account_begin_delete($1,$2,$3,$4)',[account,'subject-'+account,'app.nevestudio.carry','test']);
    await assert.rejects(pull(db),/account_unavailable/);await assert.rejects(apply(db,[trip()]),/account_unavailable/);
  }finally{await db.close();}
});

test('field-specific baselines distinguish causal local edits from unrelated later server changes',async()=>{
  const db=await database();try{
    const t=trip();await apply(db,[t]);const original=await entity(db,t.id);
    await apply(db,[patch(original,{name:'My first edit'})]);
    const afterOwn=await entity(db,t.id);
    await apply(db,[{...patch(original,{destinationCity:'Other field'}),fieldVersions:{destinationCity:1}}]);
    await apply(db,[{...patch(afterOwn,{name:'My next edit'}),fieldVersions:{name:2}}]);
    assert.equal((await entity(db,t.id)).fields.name,'My next edit');
    await assert.rejects(apply(db,[{...patch(original,{name:'Stale'}),fieldVersions:{name:1}}]),/field_conflict/);
    for(const fieldVersions of [{},{name:2,owner:1},{name:-1},{name:1.5},null])await assert.rejects(apply(db,[{...patch(await entity(db,t.id),{name:'Invalid'}),fieldVersions}]),/invalid_field_versions/);
  }finally{await db.close();}
});
test('OAuth client sessions cannot use the full-account device RPC even with a valid user ID',async()=>{
  const db=await database();try{
    await db.exec('reset role');await db.query('update auth.sessions set oauth_client_id=$1 where id=$2',[other,session]);await db.exec('set role service_role');
    await assert.rejects(pull(db),/session_expired/);await assert.rejects(apply(db,[trip()]),/session_expired/);
  }finally{await db.close();}
});

test('native cost semantics preserve free entries and an uncaptured FX snapshot without accepting an orphan positive amount',async()=>{
  const db=await database();try{
    const t=trip(),h=child('lodging',t.id);Object.assign(h.fields,{costAmount:0,costCurrencyCode:'',costHomeAmount:-1});
    await apply(db,[t,h]);assert.equal((await entity(db,h.id)).fields.costHomeAmount,-1);
    let e=await entity(db,h.id);await apply(db,[patch(e,{costCurrencyCode:'JPY'})]);
    e=await entity(db,h.id);assert.equal(e.fields.costAmount,0);assert.equal(e.fields.costCurrencyCode,'JPY');
    await assert.rejects(apply(db,[patch(e,{costAmount:100,costCurrencyCode:''})]),/cost_currency_required/);
  }finally{await db.close();}
});

test('compound move and parent deletion use transaction-start subtree baselines without hiding an outside concurrent edit',async()=>{
  const db=await database();try{
    const t=trip(),first=child('day',t.id),second=child('day',t.id),stop=child('stop',first.id);second.fields.sortOrder=1;
    await apply(db,[t,first,second,stop]);
    const day=await entity(db,first.id),e=await entity(db,stop.id);
    await apply(db,[{...patch(e,{}),action:'move',parentID:second.id},remove(day)]);
    assert.equal((await entity(db,stop.id)).parentID,second.id);assert.ok((await entity(db,first.id)).deletedAt);
    const destination=await entity(db,second.id),moved=await entity(db,stop.id);
    await apply(db,[child('stop',second.id)]);
    await assert.rejects(apply(db,[remove(destination)]),/subtree_conflict/);
    assert.equal((await entity(db,stop.id)).version,moved.version);
  }finally{await db.close();}
});

test('native account lifecycle requires an active non-OAuth session before enrollment',async()=>{
  const db=await database();try{
    await db.query('select public.carry_account_require_session($1,$2)',[account,session]);
    // A new native account can enroll; no existing graph/credential is required.
    await db.query('delete from carry_private.carry_apple_credentials where account_id=$1',[account]);
    await db.query('select public.carry_account_require_session($1,$2)',[account,session]);
    await assert.rejects(db.query('select public.carry_account_require_session($1,$2)',[other,session]),/session_expired/);
    await db.exec('reset role');
    await db.query('update auth.sessions set oauth_client_id=$1 where id=$2',[other,session]);
    await db.exec('set role service_role');
    await assert.rejects(db.query('select public.carry_account_require_session($1,$2)',[account,session]),/session_expired/);
    await db.exec('reset role');
    await db.query("update auth.sessions set oauth_client_id=null,not_after=now()-interval '1 second' where id=$1",[session]);
    await db.exec('set role service_role');
    await assert.rejects(db.query('select public.carry_account_require_session($1,$2)',[account,session]),/session_expired/);
    await db.exec('reset role');
    await db.query('delete from auth.sessions where id=$1',[session]);
    await db.exec('set role service_role');
    await assert.rejects(db.query('select public.carry_account_require_session($1,$2)',[account,session]),/session_expired/);
    for(const role of ['anon','authenticated']){
      await db.exec('reset role;set role '+role);
      await assert.rejects(db.query('select public.carry_account_require_session($1,$2)',[other,otherSession]),/permission denied/);
      await assert.rejects(db.query('select carry_private.account_require_native_session($1,$2)',[other,otherSession]),/permission denied/);
    }
    await db.exec('reset role');
    assert.deepEqual((await db.query("select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='carry_private' and p.prosecdef order by p.proname")).rows.map(row=>row.proname),["account_require_native_session","deletion_identity_exists","recovery_fence_other_sessions"]);
  }finally{await db.close();}
});

test('moving before patching the old parent publishes only metadata until the actual parent edit',async()=>{
  const db=await database();try{
    const t=trip(),first=child('day',t.id),second=child('day',t.id),stop=child('stop',first.id);
    second.fields.sortOrder=1;
    await apply(db,[t,first,second,stop]);
    const previous=await entity(db,first.id),moving=await entity(db,stop.id);
    const result=await apply(db,[{...patch(moving,{}),action:'move',parentID:second.id},patch(previous,{title:'Actual parent edit'})]);
    const events=result.changes.filter(c=>c.entity.id===first.id);
    assert.ok(events.length>=2);
    for(const event of events.slice(0,-1)){
      assert.equal(event.metadataOnly,true,'An unchanged old parent cannot acknowledge its later edit');
      assert.deepEqual(event.entity.fields,{});assert.deepEqual(event.entity.fieldVersions,{});
    }
    assert.equal(events.at(-1).metadataOnly,false);
    assert.equal(events.at(-1).entity.fields.title,'Actual parent edit');
  }finally{await db.close();}
});

test('independent child and parent deletes in one command keep separate restore batches',async()=>{
  const db=await database();try{
    const t=trip(),section=child('section',t.id),item=child('packingItem',section.id);
    await apply(db,[t,section,item]);
    const rootBefore=await entity(db,t.id),itemBefore=await entity(db,item.id),requestID=id();
    const deleted=await apply(db,[remove(itemBefore),remove(rootBefore)],{requestID});
    const root=await entity(db,t.id),leaf=await entity(db,item.id);
    assert.notEqual(root.deletionBatch,leaf.deletionBatch);
    assert.deepEqual(await apply(db,[remove(itemBefore),remove(rootBefore)],{requestID}),deleted);
    await apply(db,[{...remove(root),action:'restore'}]);
    assert.equal((await entity(db,t.id)).deletedAt,null);
    assert.equal((await entity(db,section.id)).deletedAt,null);
    assert.ok((await entity(db,item.id)).deletedAt,'Restoring the parent must preserve an earlier independent delete');
    const remaining=await entity(db,item.id);
    await apply(db,[{...remove(remaining),action:'restore'}]);
    assert.equal((await entity(db,item.id)).deletedAt,null);
  }finally{await db.close();}
});

test('receipts and pulls expose contiguous pre-event versions without historical fields',async()=>{
 const db=await database();try{
  const t=trip(),s=child('section',t.id),p=child('packingItem',s.id);
  await apply(db,[t,s,p]);const before=await entity(db,t.id),item=await entity(db,p.id);
  const receipt=await apply(db,[patch(item,{isPacked:true})]);
  const root=receipt.changes.find(c=>c.entity.id===t.id),leaf=receipt.changes.find(c=>c.entity.id===p.id);
  assert.equal(root.previousVersion,before.version);assert.equal(root.previousSubtreeVersion,before.subtreeVersion);
  assert.equal(root.metadataOnly,true);assert.deepEqual(root.entity.fields,{});
  assert.equal(leaf.previousVersion,item.version);assert.equal(leaf.previousSubtreeVersion,item.subtreeVersion);
  const pulled=await pull(db,receipt.changes[0].sequence-1,500);
  assert.deepEqual(pulled.changes,receipt.changes);
  assert.ok(receipt.changes.every(c=>!Object.hasOwn(c,'previous')),'Never send old private field snapshots');
 }finally{await db.close();}
});

test('restore can atomically apply pending root fields under exact subtree review',async()=>{
 const db=await database();try{
  const t=trip(),s=child('section',t.id);await apply(db,[t,s]);await apply(db,[remove(await entity(db,t.id))]);
  const deleted=await entity(db,t.id);
  await assert.rejects(apply(db,[{...remove(deleted),action:'restore',fields:{unknown:'Invalid'}}]),/invalid|unknown/);
  assert.ok((await entity(db,t.id)).deletedAt);
  await apply(db,[{...remove(deleted),action:'restore',fields:{name:'Restored edited title'}}]);
  const restored=await entity(db,t.id);
  assert.equal(restored.deletedAt,null);assert.equal(restored.fields.name,'Restored edited title');
  assert.equal(restored.fieldVersions.name,restored.version);
  assert.equal((await entity(db,s.id)).deletedAt,null);
 }finally{await db.close();}
});

test('reviewed restore can atomically move the root and retain both ancestor revisions',async()=>{
 const db=await database();try{
  const t=trip(),otherTrip=trip(),day=child('day',t.id),stop=child('stop',day.id);
  await apply(db,[t,otherTrip,day,stop]);await apply(db,[remove(await entity(db,day.id))]);
  const deleted=await entity(db,day.id);
  await assert.rejects(apply(db,[{...remove(deleted),action:'restore',parentID:stop.id}]),/invalid_parent/);
  const receipt=await apply(db,[{...remove(deleted),action:'restore',parentID:otherTrip.id,fields:{title:'Moved restore'}}]);
  assert.equal((await entity(db,day.id)).parentID,otherTrip.id);
  assert.equal((await entity(db,stop.id)).deletedAt,null);
  assert.ok(receipt.changes.some(c=>c.entity.id===t.id&&c.metadataOnly));
  assert.ok(receipt.changes.some(c=>c.entity.id===otherTrip.id&&c.metadataOnly));
 }finally{await db.close();}
});

test('graph assets require verified bytes owned by the exact account entity and slot',async()=>{
  const db=await database();try{
    const t=trip(),d=child('day',t.id),s=child('stop',d.id),photo=child('photo',s.id),attachment=child('attachment',s.id);
    const thumb=await verifiedAsset(db,photo.id,'photo','thumbnail');
    const original=await verifiedAsset(db,photo.id,'photo','original');
    const file=await verifiedAsset(db,attachment.id,'attachment','file');
    photo.fields.thumbnailAssetID=thumb.id;photo.fields.originalAssetID=original.id;
    attachment.fields.fileAssetID=file.id;attachment.fields.fileName='synthetic.pdf';
    await apply(db,[t,d,s,photo,attachment]);
    assert.equal((await entity(db,photo.id)).fields.originalAssetID,original.id);
    await assert.rejects(apply(db,[patch(await entity(db,photo.id),{thumbnailAssetID:original.id})]),/asset_reference_unverified/);
    await assert.rejects(apply(db,[patch(await entity(db,attachment.id),{fileAssetID:thumb.id})]),/asset_reference_unverified/);
    const outsider=await verifiedAsset(db,attachment.id,'attachment','file',{owner:other,token:otherSession});
    await assert.rejects(apply(db,[patch(await entity(db,attachment.id),{fileAssetID:outsider.id})]),/asset_reference_unverified/);
    const version=(await entity(db,attachment.id)).version;
    assert.equal(version,1,'rejected publication does not advance graph versions');
  }finally{await db.close();}
});

test('pending, deleting, missing and superseded provider objects cannot enter the graph',async()=>{
  const db=await database();try{
    const t=trip(),d=child('day',t.id),s=child('stop',d.id),attachment=child('attachment',s.id);
    await apply(db,[t,d,s]);
    const pending=await verifiedAsset(db,attachment.id,'attachment','file',{verify:false});
    attachment.fields.fileAssetID=pending.id;
    for(const state of ['pending','deleting']) {
      await db.query('update carry_private.assets set state=$1 where account_id=$2 and id=$3',[state,account,pending.id]);
      await assert.rejects(apply(db,[attachment]),/asset_reference_unverified/);
      assert.equal(await entity(db,attachment.id),undefined);
    }
    await db.query("update carry_private.assets set state='pending' where account_id=$1 and id=$2",[account,pending.id]);
    await db.query('select public.carry_asset_inspection_finish($1,$2,$3,$4,$5,7)',[account,session,pending.id,pending.version,'a'.repeat(64)]);
    await db.query('update storage.objects set archived_at=now() where name=$1',[pending.name]);
    await assert.rejects(apply(db,[attachment]),/asset_reference_unverified/);
    await db.query('delete from storage.objects where name=$1',[pending.name]);
    await assert.rejects(apply(db,[attachment]),/asset_reference_unverified/);
    attachment.fields.fileAssetID=id();await assert.rejects(apply(db,[attachment]),/asset_reference_unverified/);
  }finally{await db.close();}
});

test('named background references are bounded, validated and restored with their bytes',async()=>{
  const db=await database();try{
    const t=trip(),background=await verifiedAsset(db,t.id,'trip','background:0:0');
    t.fields.backgroundAssetIDs={'background:0:0':background.id};
    t.fields.backgroundsData=Buffer.from(JSON.stringify([{source:'local',localFileName:'synthetic.jpg',destinationIndex:0}])).toString('base64');
    await apply(db,[t]);
    assert.deepEqual((await entity(db,t.id)).fields.backgroundAssetIDs,t.fields.backgroundAssetIDs);
    for(const value of [{'../escape':background.id},{'background:0:0':'not-a-uuid'},Object.fromEntries(Array.from({length:257},(_,i)=>[`background:0:${i}`,background.id]))]) {
      await assert.rejects(apply(db,[patch(await entity(db,t.id),{backgroundAssetIDs:value})]),/invalid_field/);
    }
    await apply(db,[remove(await entity(db,t.id))]);
    const deleted=await entity(db,t.id),cursor=(await pull(db)).cursor;
    await db.query('delete from storage.objects where name=$1',[background.name]);
    await assert.rejects(apply(db,[{...remove(deleted),action:'restore'}]),/asset_reference_unverified/);
    assert.ok((await entity(db,t.id)).deletedAt);assert.equal((await pull(db)).cursor,cursor);
    await db.query("insert into storage.objects values('carry-account-assets',$1,$2,null,false)",[background.name,background.version]);
    await apply(db,[{...remove(deleted),action:'restore'}]);
    assert.equal((await entity(db,t.id)).deletedAt,null);
  }finally{await db.close();}
});

test('parent restore validates restored child assets and rolls back the entire subtree',async()=>{
  const db=await database();try{
    const t=trip(),d=child('day',t.id),s=child('stop',d.id),attachment=child('attachment',s.id);
    const file=await verifiedAsset(db,attachment.id,'attachment','file');attachment.fields.fileAssetID=file.id;
    await apply(db,[t,d,s,attachment]);await apply(db,[remove(await entity(db,t.id))]);
    const root=await entity(db,t.id),cursor=(await pull(db)).cursor;
    await db.query("update carry_private.assets set state='deleting' where account_id=$1 and id=$2",[account,file.id]);
    await assert.rejects(apply(db,[{...remove(root),action:'restore'}]),/asset_reference_unverified/);
    for(const key of [t.id,d.id,s.id,attachment.id])assert.ok((await entity(db,key)).deletedAt);
    assert.equal((await pull(db)).cursor,cursor);
  }finally{await db.close();}
});

test('device-only filenames and malformed background payloads cannot publish unprojectable graphs',async()=>{
  const db=await database();try{
    const t=trip(),d=child('day',t.id),s=child('stop',d.id),attachment=child('attachment',s.id);
    attachment.fields.fileName='device-only.pdf';
    await assert.rejects(apply(db,[t,d,s,attachment]),/asset_reference_required/);
    assert.equal((await pull(db)).cursor,0,'late invalid file rolls back the complete plan');
    const entries=[{source:'local',localFileName:'device-only.jpg',destinationIndex:0}];
    t.fields.backgroundsData=Buffer.from(JSON.stringify(entries)).toString('base64');
    await assert.rejects(apply(db,[t]),/asset_reference_required/);
    for(const raw of ['not-base64',Buffer.from('{}').toString('base64'),Buffer.from(JSON.stringify([{source:'unrecognized'}])).toString('base64'),
      Buffer.from(JSON.stringify([{source:'local',localFileName:'../escape',destinationIndex:0}])).toString('base64')]) {
      t.fields.backgroundsData=raw;await assert.rejects(apply(db,[t]),/invalid_background_data/);
    }
    assert.equal((await pull(db)).cursor,0);
  }finally{await db.close();}
});

test('photos without thumbnails remain valid placeholders and original bytes remain independently verified',async()=>{
  const db=await database();try{
    const t=trip(),d=child('day',t.id),s=child('stop',d.id),photo=child('photo',s.id);
    await apply(db,[t,d,s,photo]);
    assert.equal((await entity(db,photo.id)).fields.thumbnailAssetID,undefined);
    const original=await verifiedAsset(db,photo.id,'photo','original');
    await apply(db,[patch(await entity(db,photo.id),{originalAssetID:original.id,thumbnailAssetID:null})]);
    assert.equal((await entity(db,photo.id)).fields.originalAssetID,original.id);
    assert.equal((await entity(db,photo.id)).fields.thumbnailAssetID,null);
    await assert.rejects(apply(db,[patch(await entity(db,photo.id),{thumbnailAssetID:id()})]),/asset_reference_unverified/);
  }finally{await db.close();}
});
