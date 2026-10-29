import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
import {applyPortableMigrations} from './migration-fixture.mjs';
import {graphSchema} from './graph-schema.mjs';
const account=randomUUID(),session=randomUUID();
const fields=kind=>Object.fromEntries(Object.entries(graphSchema[kind].fields).filter(([,rule])=>!rule.optional).map(([key,rule])=>[key,
 rule.type==='string'?(rule.format==='date-time'?'2026-11-01T00:00:00Z':''):rule.type==='number'?Math.max(0,rule.min):rule.type==='array'?[]:false]));
const create=(kind,parentID)=>({id:randomUUID(),kind,action:'create',baseVersion:0,...(parentID?{parentID}:{}),fields:fields(kind)});
async function fixture(){
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid,not_after timestamptz,oauth_client_id uuid);`);
 await db.query('insert into auth.users values($1)',[account]);await db.query('insert into auth.sessions(id,user_id) values($1,$2)',[session,account]);
 await applyPortableMigrations(db);await db.exec('set role service_role');
 await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[account,'synthetic-staging','app.nevestudio.carry','encrypted']);
 const rpc=async(name,args)=>(await db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) as result`,args)).rows[0].result;
 const stage=(request,index,total,count,mutations)=>rpc('carry_graph_stage',[account,session,request,index,total,count,mutations]);
 const commit=request=>rpc('carry_graph_commit_stage',[account,session,request]);
 return{db,rpc,stage,commit};
}

test('large staged graph publishes atomically and keeps immutable, bounded, resumable receipt pages',async()=>{
 const f=await fixture();try{
 const trip=create('trip');trip.fields.name='Synthetic staged trip';trip.fields.selectedSceneKeys=Array.from({length:1000},(_,i)=>'synthetic-scene-'+i+'x'.repeat(30));
 const section=create('section',trip.id),mutations=[trip,section,...Array.from({length:501},()=>create('packingItem',section.id))],request=randomUUID();
 await f.stage(request,0,2,mutations.length,mutations.slice(0,500));
 assert.equal((await f.db.query('select count(*)::int n from carry_private.graph_entities')).rows[0].n,0);
 await assert.rejects(f.commit(request),/stage_incomplete/);
 await f.stage(request,0,2,mutations.length,mutations.slice(0,500));
 await f.stage(request,1,2,mutations.length,mutations.slice(500));
 const summary=await f.commit(request);assert.equal(summary.status,'saved_to_account');assert.equal(summary.requestID,request);
 assert.equal((await f.db.query('select count(*)::int n from carry_private.graph_entities')).rows[0].n,mutations.length);
 assert.equal((await f.db.query('select count(*)::int n from carry_private.graph_command_stages')).rows[0].n,0);
 const meta=(await f.db.query('select max(octet_length(snapshot::text))::int bytes from carry_private.graph_changes where metadata_only')).rows[0];
 assert.ok(meta.bytes<1000,'Parent fields must not be copied once per packed item');
 let offset=0,last=0,count=0;
 while(offset<summary.changeCount){
 const page=await f.rpc('carry_graph_receipt_page',[account,session,request,offset,137]);
 assert.equal(page.requestID,request);assert.equal(page.cursor,summary.cursor);assert.ok(page.changes.length<=137);
 assert.ok(Buffer.byteLength(JSON.stringify(page))<5*1024*1024);
 for(const change of page.changes){assert.equal(change.sequence,last+1);last=change.sequence;if(change.metadataOnly)assert.deepEqual(change.entity.fields,{});}
 count+=page.changes.length;offset=page.nextOffset;
 }
 assert.equal(count,summary.changeCount);assert.equal(last,summary.cursor);
 const first=await f.rpc('carry_graph_receipt_page',[account,session,request,0,1]);
 await f.rpc('carry_graph_apply',[account,session,{requestID:randomUUID(),mutations:[{id:trip.id,kind:'trip',action:'patch',baseVersion:1,fields:{name:'Later edit'}}]}]);
 assert.deepEqual(await f.rpc('carry_graph_receipt_page',[account,session,request,0,1]),first,'A later pull is not an immutable receipt');
 await f.stage(request,0,2,mutations.length,mutations.slice(0,500));await f.stage(request,1,2,mutations.length,mutations.slice(500));
 assert.deepEqual(await f.commit(request),summary,'Lost commit replies must not apply twice');
 }finally{await f.db.close();}
});

test('invalid staged commit rolls back all business writes and releases private staging quota',async()=>{
 const f=await fixture();try{
 const trip=create('trip'),bad=create('packingItem',randomUUID()),request=randomUUID();
 await f.stage(request,0,2,2,[trip]);await f.stage(request,1,2,2,[bad]);
 const response=await f.commit(request);assert.equal(response.failure.code,'22023');assert.equal(response.failure.message,'invalid_parent');
 assert.equal((await f.db.query('select count(*)::int n from carry_private.graph_entities')).rows[0].n,0);
 assert.equal((await f.db.query('select count(*)::int n from carry_private.graph_command_stages')).rows[0].n,0);
 }finally{await f.db.close();}
});

test('staging enforces account/session identity, immutable chunks, expiry and separate read/write budgets',async()=>{
 const f=await fixture();try{
 const trip=create('trip'),request=randomUUID();
 await f.stage(request,0,1,1,[trip]);
 await assert.rejects(f.stage(request,0,1,1,[{...trip,fields:{...trip.fields,name:'different'}}]),/request_id_reused/);
 await f.stage(randomUUID(),0,1,1,[create('trip')]);await assert.rejects(f.stage(randomUUID(),0,1,1,[create('trip')]),/stage_budget_exceeded/);
 await f.db.exec('reset role');await f.db.query("update carry_private.graph_command_stages set expires_at=statement_timestamp()-interval '1 second'");await f.db.exec('set role service_role');
 await f.stage(randomUUID(),0,1,1,[create('trip')]);
 for(let i=1;i<=121;i++)assert.equal(await f.rpc('carry_graph_rate_limit',[account,session,'writes']),i<=120);
 assert.equal(await f.rpc('carry_graph_rate_limit',[account,session,'requests']),true);
 await f.db.exec('reset role');await f.db.query('delete from auth.sessions where id=$1',[session]);await f.db.exec('set role service_role');
 await assert.rejects(f.stage(randomUUID(),0,1,1,[create('trip')]),/session_expired/);
 for(const role of ['anon','authenticated']){
 await f.db.exec('reset role;set role '+role);await assert.rejects(f.rpc('carry_graph_commit_stage',[account,session,request]),/permission denied/);
 }
 }finally{await f.db.close();}
});

test('pull bounds aggregate bytes while preserving every contiguous sequence',async()=>{
 const f=await fixture();try{
 const snapshot={id:randomUUID(),kind:'trip',parentID:null,version:1,subtreeVersion:1,
   fields:{...fields('trip'),selectedSceneKeys:Array.from({length:400},()=> 'x'.repeat(500))},fieldVersions:{}};
 await f.db.query('insert into carry_private.graph_accounts(account_id,sequence) values($1,24)',[account]);
 for(let i=1;i<=24;i++)await f.db.query('insert into carry_private.graph_changes(account_id,sequence,entity_id,snapshot,request_id) values($1,$2,$3,$4,$5)',
   [account,i,snapshot.id,{...snapshot,subtreeVersion:i},randomUUID()]);
 let cursor=0,seen=0;
 do{
   const page=await f.rpc('carry_graph_pull',[account,session,cursor,100]);
   assert.ok(Buffer.byteLength(JSON.stringify(page))<4300000);assert.ok(page.changes.length>0);
   for(const change of page.changes){assert.equal(change.sequence,++seen);}
   cursor=page.cursor;assert.equal(page.hasMore,cursor<24);
 }while(cursor<24);
 assert.equal(seen,24);
 }finally{await f.db.close();}
});
