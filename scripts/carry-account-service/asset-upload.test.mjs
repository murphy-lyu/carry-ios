import { applyPortableMigrations } from './migration-fixture.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { createAssetUploadAdapter } from './asset-upload-adapter.mjs';
import { createAssetUploadHandler } from './asset-upload-http.mjs';
import { createAssetHandler } from './asset-http.mjs';
import { createAssetCleanupHandler } from './asset-cleanup-http.mjs';
const project='https://asset-qa.supabase.co',storage='https://asset-qa.storage.supabase.co';
const account=randomUUID(),session=randomUUID();
const raw=new Uint8Array([1,2,3,4,5,6,7]);
const hash=createHash('sha256').update(raw).digest('hex');

async function fixture() {
  const db=new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create table auth.users(id uuid primary key);
    create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);
    create schema storage;create table storage.objects(bucket_id text,name text,version text,archived_at timestamptz,is_delete_marker boolean not null default false,primary key(bucket_id,name,version));
    create unique index current_object on storage.objects(bucket_id,name) where archived_at is null;
    grant usage on schema storage to service_role;grant select,insert,update,delete on storage.objects to service_role;
    insert into auth.users values('${account}'); insert into auth.sessions values('${session}','${account}',null,null);`);
  await applyPortableMigrations(db);
  await db.exec('set role service_role');
  await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[account,'synthetic-subject','app.nevestudio.carry','encrypted']);
  await db.query('insert into carry_private.asset_budgets values($1,$2,20)',[account,1000*1024*1024]);
  const uploads=new Map(),calls={creates:0,transfers:0},fault={};
  const allowedRPC=new Set(['carry_asset_cleanup_empty','carry_asset_cleanup_accounts','carry_asset_cleanup_claim','carry_asset_cleanup_finish','carry_asset_reserve','carry_asset_inspection_target','carry_asset_inspection_finish','carry_asset_rate_limit','carry_asset_descriptor','carry_asset_upload_begin','carry_asset_upload_created','carry_asset_upload_claim','carry_asset_upload_finish']);
  const fetcher=async(input,options={})=>{
    const url=new URL(input);
    if(url.origin===project&&url.pathname==='/auth/v1/user') {
      if(!['Bearer synthetic-native','Bearer synthetic-ai'].includes(options.headers.Authorization))return Response.json({}, {status:401});
      return Response.json({id:account,identities:[{provider:'apple'}]});
    }
    if(url.origin===project&&url.pathname.startsWith('/rest/v1/rpc/')) {
      assert.equal(options.headers.Authorization,'Bearer synthetic-service-key');
      const name=url.pathname.split('/').pop(); assert.ok(allowedRPC.has(name));
      const body=JSON.parse(options.body),keys=Object.keys(body);
      try {
        const result=await db.query(`select public.${name}(${keys.map((key,i)=>`${key}=>$${i+1}`).join(',')}) as result`,Object.values(body));
        return Response.json(result.rows[0].result);
      } catch(error) { return Response.json({code:error.code,message:error.message},{status:400}); }
    }
    assert.equal(url.origin,storage,'Never forward a key or file to a caller-selected host');
    assert.equal(options.headers.Authorization,'Bearer synthetic-service-key');
    assert.equal(options.redirect,'error');
    if(url.pathname==='/storage/v1/object/carry-account-assets'&&options.method==='DELETE') {
      if(fault.removeOutage)return new Response(null,{status:503});
      const {prefixes}=JSON.parse(options.body);assert.equal(prefixes.length,1);
      const {path,versionId}=prefixes[0];assert.equal(typeof path,'string');assert.ok(versionId);
      await db.query('delete from storage.objects where bucket_id=$1 and name=$2 and version=$3',['carry-account-assets',path,versionId]);
      for(const [key,value] of uploads)if(value.name===path&&value.version===versionId)uploads.delete(key);
      return Response.json([]);
    }
    if(url.pathname.startsWith('/storage/v1/object/authenticated/carry-account-assets/')&&options.method==='GET') {
      const object=url.pathname.slice('/storage/v1/object/authenticated/carry-account-assets/'.length);
      const row=(await db.query('select version from storage.objects where bucket_id=$1 and name=$2 and archived_at is null and not is_delete_marker',['carry-account-assets',object])).rows[0];
      const upload=[...uploads.values()].find(x=>x.version===row?.version);
      if(!upload)return new Response(null,{status:404});
      if(fault.verifyOutage)return new Response(null,{status:503});
      if(fault.swapVersion)await db.query('update storage.objects set version=$1 where name=$2',[randomUUID(),object]);
      if(fault.deleteDuringInspection)await db.query('select public.carry_account_begin_delete($1,$2,$3,$4)',[account,'synthetic-subject','app.nevestudio.carry','encrypted']);
      return new Response(fault.corruptBytes?new Uint8Array(upload.bytes.length):upload.bytes);
    }
    if(url.pathname==='/storage/v1/upload/resumable'&&options.method==='POST') {
      calls.creates++;
      const metadata=Object.fromEntries(options.headers['Upload-Metadata'].split(',').map(pair=>{
        const [key,value]=pair.split(' ');return [key,Buffer.from(value,'base64').toString()];
      }));
      const version=randomUUID(),id=Buffer.from(`${metadata.bucketName}/${metadata.objectName}/${version}`).toString('base64url');
      const location=storage+'/storage/v1/upload/resumable/'+id;
      uploads.set(location,{offset:0,size:Number(options.headers['Upload-Length']),bytes:new Uint8Array(),version,name:metadata.objectName});
      if(fault.deleteDuringCreate)await db.query('select public.carry_account_begin_delete($1,$2,$3,$4)',[account,'synthetic-subject','app.nevestudio.carry','encrypted']);
      if(fault.loseCreate) {fault.loseCreate=false;throw new TypeError('Synthetic response loss');}
      if(fault.badCreateLocation)return new Response(null,{status:201,headers:{'Tus-Resumable':'1.0.0',Location:'https://invalid.example/trap'}});
      return new Response(null,{status:201,headers:{'Tus-Resumable':'1.0.0',Location:location}});
    }
    calls.transfers++;
    const upload=uploads.get(url.href);
    if(!upload)return new Response(null,{status:404});
    if(options.method==='DELETE') {
      if(fault.cleanupOutage)return new Response(null,{status:503});
      if(upload.offset===upload.size)return new Response(null,{status:403});
      uploads.delete(url.href);return new Response(null,{status:204});
    }
    if(options.method==='HEAD')return new Response(null,{status:200,headers:{'Tus-Resumable':'1.0.0','Upload-Offset':String(upload.offset),'Upload-Length':String(fault.badHead?upload.size+1:upload.size)}});
    assert.equal(options.method,'PATCH');
    if(Number(options.headers['Upload-Offset'])!==upload.offset)return new Response(null,{status:409});
    const chunks=[];
    for await(const chunk of options.body)chunks.push(chunk);
    const bytes=Buffer.concat(chunks);
    upload.bytes=Buffer.concat([upload.bytes,bytes]);upload.offset+=bytes.length;
    if(upload.offset===upload.size)await db.query('insert into storage.objects(bucket_id,name,version) values($1,$2,$3) on conflict do nothing',['carry-account-assets',upload.name,upload.version]);
    return new Response(null,{status:204,headers:{'Tus-Resumable':'1.0.0','Upload-Offset':String(fault.badAck?upload.size+1:upload.offset)}});
  };
  const jose={decodeJwt:token=>({sub:account,session_id:session,iss:project+'/auth/v1',exp:Date.now()/1000+3600,...(token==='synthetic-ai'?{client_id:randomUUID()}:{})})};
  const adapter=createAssetUploadAdapter({configuration:{projectURL:project,serviceKey:'synthetic-service-key'},jose,fetcher});
  const handler=createAssetUploadHandler(adapter),control=createAssetHandler(adapter);
  async function asset() {
    const entityID=randomUUID();
    const digest=createHash('sha256').update(`${account}/${entityID}/file/${hash}`).digest('hex').slice(0,32);
    const id=[digest.slice(0,8),digest.slice(8,12),digest.slice(12,16),digest.slice(16,20),digest.slice(20)].join('-');
    const value={id,entityID,entityKind:'attachment',slot:'file',sha256:hash,byteCount:raw.length,contentType:'application/octet-stream'};
    await db.query('select public.carry_asset_reserve($1,$2,$3)',[account,session,value]);return value;
  }
  function request(asset,{method='POST',url=project+'/functions/v1/carry-assets/tus',token='synthetic-native',body,offset=0,extraHeaders={}}={}) {
    const headers={'Tus-Resumable':'1.0.0',Authorization:'Bearer '+token,...extraHeaders};
    if(method==='POST') {
      headers['Upload-Length']=String(asset.byteCount);
      headers['Upload-Metadata']=Object.entries({bucketName:'carry-account-assets',objectName:`${account}/${asset.id}/${hash}`,contentType:asset.contentType,cacheControl:'0'})
        .map(([k,v])=>`${k} ${Buffer.from(v).toString('base64')}`).join(',');
    }
    if(method==='PATCH')Object.assign(headers,{'Upload-Offset':String(offset),'Content-Type':'application/offset+octet-stream','Content-Length':String(asset.byteCount-offset)});
    const options={method,headers};if(body!==undefined){options.body=body;options.duplex='half';}
    return new Request(url,options);
  }
  const controlRequest=(asset,action='verify',body={id:asset.id})=>new Request(project+'/functions/v1/carry-assets/'+action,
    {method:'POST',headers:{Authorization:'Bearer synthetic-native','Content-Type':'application/json'},body:JSON.stringify(body)});
  const complete=async asset=>{
    const location=(await handler(request(asset))).headers.get('location');
    assert.equal((await handler(request(asset,{method:'PATCH',url:location,body:raw}))).status,204);
    return location;
  };
  return {account,session,db,uploads,calls,fault,adapter,handler,control,controlRequest,complete,asset,request};
}

test('real PostgreSQL broker creates once, streams bytes, and exposes only its own opaque location',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();
    const created=await f.handler(f.request(asset,{url:'https://forged-host.invalid/carry-assets/tus',body:new Uint8Array()}));
    assert.equal(created.status,201);
    const location=created.headers.get('location');
    assert.ok(location.startsWith(project+'/functions/v1/carry-assets/tus/'));
    assert.equal(location.includes(asset.id),false); assert.equal(location.includes(hash),false);
    const repeated=await f.handler(f.request(asset));assert.equal(repeated.headers.get('location'),location);assert.equal(f.calls.creates,1);
    const head=await f.handler(f.request(asset,{method:'HEAD',url:location}));assert.equal(head.status,200);assert.equal(head.headers.get('upload-offset'),'0');
    const patch=await f.handler(f.request(asset,{method:'PATCH',url:location,body:raw}));assert.equal(patch.status,204);assert.equal(patch.headers.get('upload-offset'),'7');
    assert.deepEqual([...f.uploads.values()][0].bytes,Buffer.from(raw));
    const rows=await f.db.query('select state,acknowledged_bytes,operation_id from carry_private.asset_upload_attempts');
    assert.deepEqual(rows.rows,[{state:'active',acknowledged_bytes:7,operation_id:null}]);
    assert.equal((await f.db.query('select state from carry_private.assets')).rows[0].state,'pending');
  }finally{await f.db.close();}
});

test('broker records lost and malformed creation responses without leaking upstream data',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();f.fault.loseCreate=true;
    assert.equal((await f.handler(f.request(asset))).status,503);
    assert.equal((await f.db.query('select state from carry_private.asset_upload_attempts')).rows[0].state,'uncertain');
    assert.equal((await f.handler(f.request(asset))).status,201);assert.equal(f.calls.creates,2);
    const bad=await f.asset();f.fault.badCreateLocation=true;
    const response=await f.handler(f.request(bad));assert.equal(response.status,502);assert.equal(response.headers.get('location'),null);
    assert.equal((await f.db.query('select state from carry_private.asset_upload_attempts where asset_id=$1',[bad.id])).rows[0].state,'uncertain');
  }finally{await f.db.close();}
});

test('broker rejects unauthorized and OAuth identities before contacting Storage',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();
    for(const token of ['unknown','synthetic-ai'])assert.equal((await f.handler(f.request(asset,{token}))).status,401);
    await f.db.exec('reset role');await f.db.query('delete from auth.sessions where id=$1',[session]);await f.db.exec('set role service_role');
    assert.equal((await f.handler(f.request(asset))).status,401);assert.equal(f.calls.creates,0);
  }finally{await f.db.close();}
});

test('broker preserves late creation location after deletion but never authorizes its use',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();f.fault.deleteDuringCreate=true;
    const response=await f.handler(f.request(asset));assert.equal(response.status,409);assert.equal(response.headers.get('location'),null);
    const row=(await f.db.query('select state,location from carry_private.asset_upload_attempts')).rows[0];
    assert.equal(row.state,'deleting');assert.ok(row.location.startsWith(storage));
    assert.equal((await f.handler(f.request(asset))).status,401);
  }finally{await f.db.close();}
});

test('invalid streamed bytes and invalid upstream acknowledgements release the operation fence',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();const location=(await f.handler(f.request(asset))).headers.get('location');
    for(const [body,status] of [[raw.slice(0,3),400],[new Uint8Array(8),413]]) {
      assert.equal((await f.handler(f.request(asset,{method:'PATCH',url:location,body}))).status,status);
      assert.equal((await f.db.query('select operation_id from carry_private.asset_upload_attempts')).rows[0].operation_id,null);
    }
    f.fault.badAck=true;
    assert.equal((await f.handler(f.request(asset,{method:'PATCH',url:location,body:raw}))).status,502);
    assert.equal((await f.db.query('select acknowledged_bytes from carry_private.asset_upload_attempts')).rows[0].acknowledged_bytes,0);
    f.fault.badAck=false;
    const head=await f.handler(f.request(asset,{method:'HEAD',url:location}));assert.equal(head.headers.get('upload-offset'),'7');
  }finally{await f.db.close();}
});

test('asset control verifies real streamed bytes and binds completion to the stored version',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();
    assert.equal((await f.control(f.controlRequest(asset,'reserve',asset))).status,200);
    assert.equal((await f.control(f.controlRequest(asset))).status,409);
    await f.complete(asset);
    const verified=await f.control(f.controlRequest(asset));
    assert.equal(verified.status,200);assert.deepEqual(await verified.json(),{id:asset.id,status:'verified'});
    assert.equal((await f.db.query('select state from carry_private.assets')).rows[0].state,'verified');
    assert.equal((await f.db.query('select state from carry_private.asset_upload_attempts')).rows[0].state,'complete');
    assert.equal((await f.control(f.controlRequest(asset))).status,200);
    assert.equal((await f.control(f.controlRequest(asset,'verify',{id:asset.id,sha256:'caller-supplied'}))).status,400);
  }finally{await f.db.close();}
});

test('temporary inspection outage retains the file for retry; confirmed corruption schedules cleanup',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();await f.complete(asset);
    f.fault.verifyOutage=true;
    assert.equal((await f.control(f.controlRequest(asset))).status,503);
    assert.equal((await f.db.query('select state from carry_private.assets')).rows[0].state,'pending');
    f.fault.verifyOutage=false;f.fault.corruptBytes=true;
    assert.equal((await f.control(f.controlRequest(asset))).status,422);
    assert.equal((await f.db.query('select state from carry_private.assets')).rows[0].state,'deleting');
    assert.equal((await f.db.query('select state from carry_private.asset_upload_attempts')).rows[0].state,'deleting');
  }finally{await f.db.close();}
});

test('inspection cannot publish an object whose version changed during its network read',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();await f.complete(asset);f.fault.swapVersion=true;
    const response=await f.control(f.controlRequest(asset));
    assert.equal(response.status,409);assert.deepEqual(await response.json(),{error:'asset_changed_during_inspection'});
    assert.equal((await f.db.query('select state from carry_private.assets')).rows[0].state,'pending');
  }finally{await f.db.close();}
});

test('inspection repeats the native-session and deletion check after the asynchronous byte read',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();await f.complete(asset);f.fault.deleteDuringInspection=true;
    assert.equal((await f.control(f.controlRequest(asset))).status,401);
    assert.equal((await f.db.query('select state from carry_private.assets')).rows[0].state,'pending');
  }finally{await f.db.close();}
});

test('a superseded or uncertain attempt is not declared complete merely because another version verified',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();f.fault.loseCreate=true;
    assert.equal((await f.handler(f.request(asset))).status,503);
    await f.complete(asset);
    assert.equal((await f.control(f.controlRequest(asset))).status,200);
    const states=(await f.db.query('select state,count(*)::int as n from carry_private.asset_upload_attempts group by state order by state')).rows;
    assert.deepEqual(states,[{state:'complete',n:1},{state:'deleting',n:1}]);
    const usage=(await f.db.query('select * from carry_private.asset_usage($1)',[account])).rows[0];
    assert.equal(usage.charged_bytes,raw.length,'Unknown creation received no file body; it consumes an attempt slot rather than inventing uploaded bytes');
    assert.equal(usage.pending_units,1);
  }finally{await f.db.close();}
});

test('archived objects and delete markers cannot masquerade as the current inspectable file',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();await f.complete(asset);
    const uploaded=[...f.uploads.values()][0];
    await f.db.query('insert into storage.objects(bucket_id,name,version,archived_at) values($1,$2,$3,statement_timestamp())',['carry-account-assets',uploaded.name,randomUUID()]);
    const target=(await f.db.query('select public.carry_asset_inspection_target($1,$2,$3) as result',[account,session,asset.id])).rows[0].result;
    assert.equal(target.storageVersion,uploaded.version);
    await f.db.query('update storage.objects set is_delete_marker=true where archived_at is null');
    assert.equal((await f.control(f.controlRequest(asset))).status,409);
    assert.equal((await f.db.query('select state from carry_private.assets')).rows[0].state,'pending');
  }finally{await f.db.close();}
});

test('cleanup releases an empty unknown attempt without touching a verified object',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();f.fault.loseCreate=true;assert.equal((await f.handler(f.request(asset))).status,503);
    await f.complete(asset);assert.equal((await f.control(f.controlRequest(asset))).status,200);
    assert.equal(await f.adapter.cleanupOne(account),true);
    assert.deepEqual((await f.db.query('select state from carry_private.asset_upload_attempts')).rows,[{state:'complete'}]);
    assert.equal((await f.db.query('select count(*)::int as n from storage.objects')).rows[0].n,1);
    assert.equal((await f.control(f.controlRequest(asset))).status,200);
    assert.equal([...f.uploads.values()].filter(x=>x.offset===0).length,1,'Only unreachable zero-byte provider metadata remains under provider TTL');
  }finally{await f.db.close();}
});

test('account deletion cleanup removes the exact completed version before clearing its file ledger',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();await f.complete(asset);assert.equal((await f.control(f.controlRequest(asset))).status,200);
    await f.db.query('select public.carry_account_begin_delete($1,$2,$3,$4)',[account,'synthetic-subject','app.nevestudio.carry','encrypted']);
    assert.equal(await f.adapter.cleanupOne(account),true);
    for(const table of ['storage.objects','carry_private.asset_upload_attempts','carry_private.assets'])assert.equal((await f.db.query(`select count(*)::int as n from ${table}`)).rows[0].n,0);
    assert.equal(f.uploads.size,0);
  }finally{await f.db.close();}
});

test('cleanup outage retains the durable ledger and retry finishes after the lease expires',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();await f.complete(asset);f.fault.corruptBytes=true;
    assert.equal((await f.control(f.controlRequest(asset))).status,422);
    f.fault.removeOutage=true;
    await assert.rejects(f.adapter.cleanupOne(account), /cleanup_removal_unconfirmed/);
    assert.equal((await f.db.query('select count(*)::int as n from carry_private.asset_upload_attempts')).rows[0].n,1);
    assert.equal(await f.adapter.cleanupOne(account),false,'An in-flight lease prevents duplicate cleanup');
    await f.db.query("update carry_private.asset_upload_attempts set lease_until=statement_timestamp()-interval '1 second'");
    f.fault.removeOutage=false;
    assert.equal(await f.adapter.cleanupOne(account),true);
    assert.equal((await f.db.query('select count(*)::int as n from carry_private.assets')).rows[0].n,0);
  }finally{await f.db.close();}
});

test('cleanup cannot remove the active verified version even if an attempt is mistakenly marked deleting',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();await f.complete(asset);assert.equal((await f.control(f.controlRequest(asset))).status,200);
    await f.db.query("update carry_private.asset_upload_attempts set state='deleting'");
    assert.equal(await f.adapter.cleanupOne(account),false);
    assert.equal((await f.db.query('select count(*)::int as n from storage.objects')).rows[0].n,1);
    assert.equal((await f.control(f.controlRequest(asset))).status,200);
  }finally{await f.db.close();}
});

test('old-version cleanup preserves the current verified object at the same path',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset();await f.complete(asset);assert.equal((await f.control(f.controlRequest(asset))).status,200);
    const current=[...f.uploads.values()][0],oldVersion=randomUUID();
    const oldLocation=storage+'/storage/v1/upload/resumable/'+Buffer.from(`carry-account-assets/${current.name}/${oldVersion}`).toString('base64url');
    f.uploads.set(oldLocation,{...current,version:oldVersion});
    await f.db.query('insert into storage.objects(bucket_id,name,version,archived_at) values($1,$2,$3,statement_timestamp())',['carry-account-assets',current.name,oldVersion]);
    await f.db.query("insert into carry_private.asset_upload_attempts(account_id,id,asset_id,creation_id,state,location,storage_version,may_have_bytes,acknowledged_bytes) values($1,$2,$3,$4,'deleting',$5,$6,true,7)",[account,randomUUID(),asset.id,randomUUID(),oldLocation,oldVersion]);
    assert.equal(await f.adapter.cleanupOne(account),true);
    const rows=(await f.db.query('select version from storage.objects')).rows;
    assert.deepEqual(rows,[{version:current.version}]);
    assert.equal((await f.control(f.controlRequest(asset))).status,200);
  }finally{await f.db.close();}
});

test('background cleanup is scheduled only after native session and request budget checks pass',async()=>{
  const f=await fixture();
  try {
    const asset=await f.asset(),scheduled=[];
    const handler=createAssetHandler({...f.adapter,scheduleCleanup:id=>scheduled.push(id)});
    assert.equal((await handler(f.request(asset,{token:'synthetic-ai'}))).status,401);assert.deepEqual(scheduled,[]);
    assert.equal((await handler(f.controlRequest(asset))).status,409);assert.deepEqual(scheduled,[account]);
    const limited=createAssetHandler({...f.adapter,rateLimit:async()=>false,scheduleCleanup:id=>scheduled.push(id)});
    assert.equal((await limited(f.controlRequest(asset))).status,429);assert.deepEqual(scheduled,[account]);
    await f.db.exec('reset role');await f.db.query('delete from auth.sessions where id=$1',[session]);await f.db.exec('set role service_role');
    assert.equal((await handler(f.controlRequest(asset))).status,401);assert.deepEqual(scheduled,[account]);
  }finally{await f.db.close();}
});

test('scheduled cleanup capability isolates callers, leases dispatch, and drains empty reservations',async()=>{
  const f=await fixture(),token='a'.repeat(64);
  try {
    await f.db.exec('reset role');
    await f.db.query('insert into carry_private.asset_cleanup_dispatch(token_hash) values($1)',[createHash('sha256').update(token).digest('hex')]);
    await f.db.exec('set role service_role');
    const asset=await f.asset();
    await f.db.query("update carry_private.assets set expires_at=statement_timestamp()-interval '1 second' where account_id=$1",[account]);
    const handler=createAssetCleanupHandler(f.adapter);
    const request=(key=token,body)=>new Request(project+'/functions/v1/carry-cleanup',{method:'POST',headers:{'x-carry-cleanup':key},...(body?{body}:{})});
    assert.equal((await handler(request('b'.repeat(64)))).status,401);
    assert.equal((await handler(request(token,'{"account":"forged"}'))).status,413);
    assert.equal((await handler(request(token,'[]'))).status,400);
    const response=await handler(request());
    assert.equal(response.status,200);assert.deepEqual(await response.json(),{processed:0,deferred:0});
    assert.equal((await f.db.query('select count(*)::int as count from carry_private.assets')).rows[0].count,0);
    assert.deepEqual(await f.adapter.cleanupAccounts(token),[]);
    await f.db.exec('reset role');
    const visible=(await f.db.query("select has_function_privilege('anon','public.carry_asset_cleanup_accounts(text)','execute') as anon,has_function_privilege('authenticated','public.carry_asset_cleanup_empty(uuid)','execute') as native")).rows[0];
    assert.deepEqual(visible,{anon:false,native:false});
  }finally{await f.db.close();}
});

test('scheduled cleanup retains failed jobs and exposes no account or provider details',async()=>{
  const accounts=[randomUUID(),randomUUID()],seen=[];
  const handler=createAssetCleanupHandler({cleanupAccounts:async()=>accounts,cleanupOne:async id=>{
    seen.push(id);if(id===accounts[0])throw new Error('private-provider-detail');return true;
  }});
  const response=await handler(new Request(project+'/functions/v1/carry-cleanup',{method:'POST',headers:{'x-carry-cleanup':'a'.repeat(64)}}));
  assert.equal(response.status,200);assert.deepEqual(await response.json(),{processed:1,deferred:1});assert.deepEqual(seen,accounts);
});
