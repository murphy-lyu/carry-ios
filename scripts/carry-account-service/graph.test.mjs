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
    assert.equal((await db.query("select count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='carry_private' and p.prosecdef")).rows[0].n,1);
  }finally{await db.close();}
});
