import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {applyPortableMigrations} from './migration-fixture.mjs';
import {graphSchema} from './graph-schema.mjs';
const valid=['0001-01-01T00:00:00Z','9999-12-31T23:59:59.999999999Z','2026-11-01T12:34:56Z','2026-11-01T12:34:56.123Z','2026-11-01T12:34:56.123456789+08:00','2024-02-29T12:34:56-05:30','2000-02-29T00:00:00Z','2026-11-01T12:34:56+15:59'];
const invalid=['0001-01-01T00:00:00+15:59','9999-12-31T23:59:59.999-15:59','2026-02-30T12:34:56Z','2026-02-29T12:34:56Z','1900-02-29T00:00:00Z','2026-11-01T24:00:00Z','2026-11-01T12:34:60Z','2026-11-01T12:60:00Z','2026-11-01T12:34Z','2026-11-01T12:34:56','2026-11-01T12:34:56Zgarbage','2026-11-01T12:34:56Z\n','2026-11-01T12:34:56+0800','2026-11-01T12:34:56+23:59','2026-11-01T12:34:56+16:00','2026-11-01T12:34:56+08:60','0000-01-01T00:00:00Z'];
const rule={type:'string',format:'date-time',max:64};
const routine=await readFile(new URL('./graph-date-validation.sql',import.meta.url),'utf8');
const migration=await readFile(new URL('./supabase/migrations/20261101122423_graph_utc_year_closure.sql',import.meta.url),'utf8');
test('base SQL and replacement migration reject unsupported dates without SQL timezone errors',async()=>{
 assert.ok(migration.startsWith(routine));
 const db=new PGlite();
 try{
  await db.exec('create schema carry_private;create role anon;create role authenticated;create role service_role;');
  const base=await readFile(new URL('./graph-transactions.sql',import.meta.url),'utf8');
  await db.exec(base.match(/create function carry_private\.graph_validate_value[\s\S]*?\$\$;/)[0]);
  for(const sql of [null,migration]){
   if(sql)await db.exec(sql);
   for(const value of valid)assert.equal((await db.query('select carry_private.graph_validate_value($1,$2) valid',[JSON.stringify(value),rule])).rows[0].valid,true,value);
   for(const value of invalid)assert.equal((await db.query('select carry_private.graph_validate_value($1,$2) valid',[JSON.stringify(value),rule])).rows[0].valid,false,value);
  }
  const rights=(await db.query("select has_function_privilege('anon','carry_private.graph_validate_value(jsonb,jsonb)','execute') anon,has_function_privilege('authenticated','carry_private.graph_validate_value(jsonb,jsonb)','execute') authenticated,has_function_privilege('service_role','carry_private.graph_validate_value(jsonb,jsonb)','execute') service")).rows[0];
  assert.deepEqual(rights,{anon:false,authenticated:false,service:true});
 }finally{await db.close();}
});
test('all migrations enforce dates on real Graph writes and rejected values leave no graph rows',async()=>{
 const db=new PGlite(),account=crypto.randomUUID(),session=crypto.randomUUID();
 try{
  await db.exec('create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);create schema storage;create table storage.objects(bucket_id text,name text);grant usage on schema storage to service_role;grant select on storage.objects to service_role;');
  await db.query('insert into auth.users values($1)',[account]);await db.query('insert into auth.sessions values($1,$2,null,null)',[session,account]);
  await applyPortableMigrations(db);await db.exec('set role service_role');
  await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[account,'synthetic-date-subject','app.nevestudio.carry','synthetic-encrypted']);
  const fields=Object.fromEntries(Object.entries(graphSchema.trip.fields).filter(([,r])=>!r.optional).map(([k,r])=>[k,r.type==='string'?(r.format==='date-time'?valid[0]:''):r.type==='number'?Math.max(0,r.min):r.type==='array'?[]:false]));
  const apply=value=>db.query('select public.carry_graph_apply($1,$2,$3)',[account,session,{requestID:crypto.randomUUID(),mutations:[{id:crypto.randomUUID(),kind:'trip',action:'create',baseVersion:0,fields:{...fields,name:'Synthetic date',departureDate:value}}]}]);
  for(const value of invalid)await assert.rejects(apply(value),/invalid_field/,value);
  assert.equal((await db.query('select count(*) from carry_private.graph_entities')).rows[0].count,0);
  for(const value of valid)await apply(value);
  assert.equal((await db.query('select count(*) from carry_private.graph_entities')).rows[0].count,valid.length);
 }finally{await db.close();}
});
