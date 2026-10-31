import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {Buffer} from 'node:buffer';
import {writeFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {applyPortableMigrations} from '../carry-account-service/migration-fixture.mjs';
import {postgresStore} from './postgres-store.mjs';
import {postgresGraphCore} from './postgres-graph-core.mjs';
import {createAccountAssets} from './assets.mjs';
import {defaults} from './domain.mjs';
import {prepareBackup,backupSerializedByteCount} from './exports.mjs';
import {hash,AIFailure} from './security.mjs';
const id=()=>randomUUID(),scopes=['trips:read','trips:write','exports:read','attachments:read','preferences:read','private:read'];
async function fixture(){
 const db=new PGlite(),accountID=id(),sessionID=id(),clientID=id(),now=Date.now(),bytes=Buffer.from('SYNTHETIC-PRIVATE-FILE'),data=new Map(),fault={};
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);
 create schema storage;create table storage.objects(bucket_id text,name text,version text,archived_at timestamptz,is_delete_marker boolean not null default false);
 grant usage on schema storage to service_role;grant select,insert,update,delete on storage.objects to service_role;`);
 await db.query('insert into auth.users values($1)',[accountID]);await db.query('insert into auth.sessions values($1,$2,null,null)',[sessionID,accountID]);
 await applyPortableMigrations(db);await db.exec('set role service_role');
 await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[accountID,'synthetic-export-'+accountID,'app.nevestudio.carry','encrypted']);
 async function asset(entityID,entityKind,slot){
  const sha256=createHash('sha256').update(bytes).digest('hex'),assetID=(await db.query('select carry_private.asset_identity($1,$2,$3,$4) as id',[accountID,entityID,slot,sha256])).rows[0].id,version=id();
  await db.query(`insert into carry_private.assets(account_id,id,entity_id,entity_kind,slot,sha256,byte_count,content_type,state,expires_at,verified_at,verified_version)
   values($1,$2,$3,$4,$5,$6,$7,'application/octet-stream','verified',now()+interval '1 day',now(),$8)`,[accountID,assetID,entityID,entityKind,slot,sha256,bytes.length,version]);
  await db.query('insert into storage.objects(bucket_id,name,version) values($1,$2,$3)',['carry-account-assets',accountID+'/'+assetID+'/'+sha256,version]);
  data.set(assetID,{bytes,version});return assetID;
 }
 const trip=id(),section=id(),packing=id(),day=id(),stop=id(),photo=id(),attachment=id(),lodging=id(),transport=id();
 const file=await asset(attachment,'attachment','file'),thumbnail=await asset(photo,'photo','thumbnail'),original=await asset(photo,'photo','original'),background=await asset(trip,'trip','background:0:0');
 const backgroundsData=Buffer.from(JSON.stringify([{source:'local',destinationIndex:0,localFileName:'old-private-filename.jpg',crop:{x:0.2,y:0.3,width:0.7,height:0.6}}])).toString('base64');
 const create=(entityID,kind,parentID,fields={})=>({id:entityID,kind,parentID,action:'create',baseVersion:0,fields:{...defaults(kind,now),...fields}});
 await db.query('select public.carry_graph_apply($1,$2,$3)',[accountID,sessionID,{requestID:id(),mutations:[
  create(trip,'trip',null,{name:'Synthetic Japan',days:3,departureDate:'2026-11-01T00:00:00Z',backgroundsData,backgroundAssetIDs:{'background:0:0':background}}),
  create(section,'section',trip,{title:'Clothes'}),create(packing,'packingItem',section,{name:'Shirt',quantity:2,isPacked:true}),
  create(day,'day',trip,{title:'Day 1'}),create(stop,'stop',day,{name:'Tokyo',timeZoneId:'Asia/Tokyo',costAmount:1250,costCurrencyCode:'JPY',costHomeAmount:-1}),
  create(photo,'photo',stop,{assetLocalIdentifier:'device-only-secret',thumbnailAssetID:thumbnail,originalAssetID:original}),
  create(attachment,'attachment',stop,{kindRaw:'file',fileName:'private-passport.pdf',fileAssetID:file,displayName:'Synthetic PDF',utiOrExt:'public.pdf'}),
  create(lodging,'lodging',trip,{name:'Hotel',nights:2,confirmationCode:'PRIVATE-CONFIRMATION'}),
  create(transport,'transport',day,{confirmationCode:'PRIVATE-FLIGHT',fromTimeZoneId:'Asia/Shanghai',toTimeZoneId:'Asia/Tokyo'})]}]);
 const assets=createAccountAssets({projectURL:'https://fixture.supabase.co',serviceKey:'synthetic-service-key',fetcher:async(url,options)=>{
  const u=new URL(url);assert.equal(u.origin,'https://fixture.storage.supabase.co');assert.equal(options.redirect,'error');assert.equal(options.headers.Authorization,'Bearer synthetic-service-key');
  const value=data.get(u.pathname.split('/').at(-2));assert.ok(value);assert.equal(u.searchParams.get('versionId'),value.version);
  if(fault.beforeRead)await fault.beforeRead();
  const range=options.headers.Range;
  if(range){const [,a,b]=/^bytes=(\d+)-(\d+)$/.exec(range);const output=value.bytes.subarray(Number(a),Number(b)+1);
   return new Response(output,{status:fault.ignoreRange?200:206,headers:{'Content-Length':String(output.length),'Content-Range':`bytes ${a}-${b}/${value.bytes.length}`}});}
  return new Response(fault.corrupt?Buffer.alloc(value.bytes.length,0):value.bytes,{headers:{'Content-Length':String(value.bytes.length)}});
 }});
 const core=postgresGraphCore(),store=postgresStore({driver:{transaction:fn=>db.transaction(fn)},core,assets});
 await store.registerClient({id:clientID,name:'Synthetic Export Client',redirectURIs:['https://client.invalid/cb']});
 async function grant(selected=scopes){const authorization=id(),grantID=id();await store.createAuthorization({id:authorization,clientID,redirectURI:'https://client.invalid/cb',resource:'https://connect.invalid/mcp',challenge:'challenge',scopes:selected,expiresAt:now+100000});
  await store.approveAuthorization({id:authorization,accountID,sessionID,selectedScopes:selected,tripIDs:[trip],onlyCreated:false,grantID,grantExpiresAt:now+1000000,codeHash:await hash(authorization),codeExpiresAt:now+10000,now});return store.getGrant({id:grantID,now});}
 const g=await grant(),p={accountID,sessionID,grantID:g.id,tripID:trip,now};
 return{db,store,assets,p,g,grant,fault,data,ids:{trip,day,stop,section,packing,photo,attachment,lodging,transport,file,original,thumbnail,background},bytes,
  prepare(mode='export_backup',requestID=id()){return store.prepareExport({...p,mode,requestID});},
  async approved(mode='export_backup'){const result=await this.prepare(mode),preview=await store.getExport({...p,id:result.id});await store.approveExport({...p,id:result.id,contentHash:preview.contentHash});return{...preview,id:result.id};}};
}
const rejects=(work,code)=>assert.rejects(work,e=>e instanceof AIFailure&&e.code===code);

test('AI file chunks require current grant live exact slot and immutable provider version',async()=>{const f=await fixture();try{
 const part=await f.store.readAsset({...f.p,assetID:f.ids.file,entityID:f.ids.attachment,offset:2,limit:5});assert.deepEqual(Buffer.from(part.bytes),f.bytes.subarray(2,7));assert.equal(part.hasMore,true);
 await rejects(f.store.readAsset({...f.p,assetID:f.ids.file,entityID:f.ids.photo,offset:0,limit:3}),'asset_not_authorized');
 await rejects(f.store.readAsset({...f.p,accountID:id(),assetID:f.ids.file,offset:0,limit:3}),'invalid_token');
 f.fault.ignoreRange=true;await rejects(f.store.readAsset({...f.p,assetID:f.ids.file,offset:0,limit:3}),'asset_storage_unavailable');
 }finally{await f.db.close();}});

test('file response obtained before revocation cannot be returned after its grant is revoked',async()=>{const f=await fixture();try{
 f.fault.beforeRead=async()=>{f.fault.beforeRead=null;await f.store.revokeGrant({...f.p,id:f.g.id});};
 await rejects(f.store.readAsset({...f.p,assetID:f.ids.file,offset:0,limit:3}),'invalid_token');
 }finally{await f.db.close();}});

test('complete approved backup restores relationships amounts time zones files covers and original photos',async()=>{const f=await fixture();try{
 const result=await f.prepare(),preview=await f.store.getExport({...f.p,id:result.id});
 assert.equal(preview.summary.contents.includes('Tokyo'),true);assert.equal(preview.summary.files.some(file=>file.name==='Synthetic PDF'),true);
 assert.equal(preview.summary.fileCount,4);assert.equal(preview.summary.containsOriginalPhotos,true);assert.equal(JSON.stringify(preview).includes(f.bytes.toString('base64')),false);
 await rejects(f.store.downloadExport({...f.p,id:result.id}),'export_not_approved');
 await rejects(f.store.approveExport({...f.p,id:result.id,contentHash:'wrong'}),'export_changed');
 await f.store.approveExport({...f.p,id:result.id,contentHash:preview.contentHash});
 const sourceGraph=await f.store.readGraph(f.p),sourceStop=sourceGraph.find(entity=>entity.id===f.ids.stop);
 const download=await f.store.downloadExport({...f.p,id:result.id}),backup=await new Response(download.body).json();
 if(process.env.CARRY_EXPORT_QA_OUTPUT){await writeFile(process.env.CARRY_EXPORT_QA_OUTPUT,JSON.stringify(backup));await writeFile(process.env.CARRY_EXPORT_QA_OUTPUT+'.source.json',JSON.stringify(sourceGraph));}
 const prepared=prepareBackup(sourceGraph,{tripID:f.ids.trip,mode:'export_backup',now:f.p.now});
 const exportedManifests=backup.assetManifest.map(file=>({...file,id:file.assetID})),encodedLength=Buffer.byteLength(JSON.stringify(backup));
 assert.equal(backupSerializedByteCount(prepared,exportedManifests),encodedLength);
 assert.throws(()=>backupSerializedByteCount(prepared,exportedManifests,{maximumBytes:encodedLength-1}),error=>error.code==='export_too_large');
 assert.equal(backup.version,1);const trip=backup.trips[0],stop=trip.itineraryDays[0].stops[0];
 assert.equal(trip.departureDate,'2026-11-01T00:00:00Z');assert.equal(trip.sections[0].items[0].quantity,2);assert.equal(trip.sections[0].items[0].isPacked,true);
 for(const key of ['timeZoneId','costAmount','costCurrencyCode','costHomeAmount'])assert.deepEqual(stop[key],sourceStop.fields[key]);
 assert.equal(stop.timeZoneId,'Asia/Tokyo');assert.equal(stop.costCurrencyCode,'JPY');assert.equal(stop.costAmount,1250);assert.equal(stop.costHomeAmount,-1);
 assert.equal(trip.itineraryDays[0].segments[0].toTimeZoneId,'Asia/Tokyo');assert.equal(trip.lodgingStays[0].confirmationCode,'PRIVATE-CONFIRMATION');
 assert.equal(stop.photos[0].thumbnailData,f.bytes.toString('base64'));assert.equal(stop.photos[0].assetLocalIdentifier,'');
 assert.equal(backup.photoOriginals[f.ids.photo],f.bytes.toString('base64'));assert.equal(backup.attachmentFiles[stop.attachments[0].fileName],f.bytes.toString('base64'));
 const cover=JSON.parse(Buffer.from(trip.backgroundsData,'base64').toString())[0];assert.equal(cover.crop.x,0.2);assert.equal(backup.backgroundImages[cover.localFileName],f.bytes.toString('base64'));
 assert.equal(backup.assetManifest.length,4);assert.equal(backup.myItems.length,0);assert.equal(JSON.stringify(backup).includes('device-only-secret'),false);
 }finally{await f.db.close();}});

test('share export carries itinerary without packing photos files private bookings or reminders',async()=>{const f=await fixture();try{
 const limited=await f.grant(['trips:read','exports:read']);const p={...f.p,grantID:limited.id};
 const result=await f.store.prepareExport({...p,mode:'share_trip',requestID:id()}),preview=await f.store.getExport({...p,id:result.id});
 await f.store.approveExport({...p,id:result.id,contentHash:preview.contentHash});const download=await f.store.downloadExport({...p,id:result.id}),backup=await new Response(download.body).json();
 assert.ok(download.fileName.endsWith('.carrytrip'));assert.equal(preview.summary.fileCount,0);assert.deepEqual(backup.trips[0].sections,[]);
 assert.equal(backup.trips[0].backgroundsData,null);assert.equal(backup.trips[0].remindersEnabled,false);assert.equal(backup.trips[0].itineraryDays[0].stops[0].photos,null);
 assert.equal(backup.trips[0].lodgingStays[0].confirmationCode,'');assert.equal(backup.trips[0].itineraryDays[0].segments[0].confirmationCode,'');
 await rejects(f.store.prepareExport({...p,mode:'export_backup',requestID:id()}),'insufficient_scope');
 }finally{await f.db.close();}});

test('preview retry is immutable and graph edit invalidates approval and later download',async()=>{const f=await fixture();try{
 const requestID=id(),first=await f.prepare('export_backup',requestID);assert.deepEqual(await f.prepare('export_backup',requestID),first);
 await rejects(f.prepare('share_trip',requestID),'request_id_reused');const preview=await f.store.getExport({...f.p,id:first.id});
 await f.db.query("update carry_private.graph_entities set fields=fields||'{\"name\":\"Changed\"}'::jsonb,version=version+1 where account_id=$1 and id=$2",[f.p.accountID,f.ids.trip]);
 await rejects(f.store.approveExport({...f.p,id:first.id,contentHash:preview.contentHash}),'export_changed');
 await rejects(f.store.getExport({...f.p,id:first.id,accountID:id()}),'account_unavailable');
 }finally{await f.db.close();}});

test('revocation or corruption during download truncates JSON and never completes a partial backup',async()=>{for(const mode of ['revoke','corrupt']){const f=await fixture();try{
 const preview=await f.approved(),download=await f.store.downloadExport({...f.p,id:preview.id});
 if(mode==='revoke')await f.store.revokeGrant({...f.p,id:f.g.id});else f.fault.corrupt=true;
 await assert.rejects(new Response(download.body).json());
 }finally{await f.db.close();}}});

test('export expires and never changes native Auth sessions or grants public SQL access',async()=>{const f=await fixture();try{
 const preview=await f.approved();await rejects(f.store.downloadExport({...f.p,id:preview.id,now:f.p.now+600001}),'export_not_found');
 await f.db.exec('reset role');
 assert.equal(Number((await f.db.query('select count(*) from auth.sessions')).rows[0].count),1);
 const privileges=(await f.db.query("select has_table_privilege('anon','carry_ai.records','select') as a,has_table_privilege('authenticated','carry_ai.records','select') as b")).rows[0];assert.deepEqual(privileges,{a:false,b:false});
 }finally{await f.db.close();}});

test('owner website reviews approves and streams a private download through the signed bridge',async()=>{
 const f=await fixture();try{
  const {createAccountAIHandler}=await import('./worker.mjs'),{createAccountWebAIBridge}=await import('./account-web-bridge.mjs'),
    {verifyOwnerProof}=await import('./owner-proof.mjs'),{accountAIPage}=await import('./web-pages.mjs'),{opaque}=await import('./security.mjs');
  const origin='https://connect.invalid',accountOrigin='https://account.invalid',secret=opaque(),session={access_token:'synthetic.native.jwt',user:{id:f.p.accountID}};
  const firstParty={authenticate:async request=>{await verifyOwnerProof(request,secret,f.p.now);assert.equal(request.headers.get('Authorization'),'Bearer '+session.access_token);return f.p;},verifyCSRF:request=>verifyOwnerProof(request,secret,f.p.now)};
  const handler=createAccountAIHandler({store:f.store,firstParty,origin,accountOrigin,now:()=>f.p.now});
  const bridge=createAccountWebAIBridge({origin,accountOrigin,secret,now:()=>f.p.now,fetcher:request=>handler(request)});
  const result=await f.prepare(),preview=await f.store.getExport({...f.p,id:result.id});let formChecks=0;
  const page=request=>accountAIPage({request,checkedSession:async()=>({user:session.user,session}),formToken:async()=> 'synthetic-csrf',
    checkForm:async form=>{assert.equal(form.get('csrf'),'synthetic-csrf');formChecks++;},bridge,headers:new Headers(),text:{lang:'zh-Hans'},
    htmlPage:(_,title,content,headers)=>new Response(title+content,{headers}),finish:response=>response});
  const before=await page(new Request(accountOrigin+'/ai/exports/'+result.id)),html=await before.text();
  assert.ok(html.includes('核对导出'));assert.ok(html.includes('不会发送给其他人或应用'));assert.ok(!html.includes('device-only-secret'));
  const approved=await page(new Request(accountOrigin+'/ai/exports/'+result.id,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({csrf:'synthetic-csrf',contentHash:preview.contentHash})}));
  assert.equal(formChecks,1);assert.ok((await approved.text()).includes('/download'));
  const download=await page(new Request(accountOrigin+'/ai/exports/'+result.id+'/download'));
  assert.ok(download.headers.get('Content-Disposition').endsWith('.json"'));assert.equal(download.headers.get('Content-Type'),'application/json; charset=utf-8');
  const backup=await download.json();assert.equal(backup.photoOriginals[f.ids.photo],f.bytes.toString('base64'));
  const denied=await handler(new Request(origin+'/exports/'+result.id+'/approve',{method:'POST',headers:{'Content-Type':'application/json','Origin':accountOrigin,'Authorization':'Bearer '+session.access_token},body:JSON.stringify({csrf:'forged',contentHash:preview.contentHash})}));
  assert.ok([400,401,403].includes(denied.status));
 }finally{await f.db.close();}
});

test('streaming reader rejects chunked overflow cancels bodies and bounds file range requests',async()=>{
 const accountID=id(),assetID=id(),raw=Buffer.from('synthetic'),manifest={id:assetID,accountID,status:'verified',storageVersion:id(),sha256:createHash('sha256').update(raw).digest('hex'),byteCount:raw.length};
 let cancelled=false;
 const assets=createAccountAssets({projectURL:'https://fixture.supabase.co',serviceKey:'synthetic-service-key',fetcher:async()=>new Response(new ReadableStream({start(controller){controller.enqueue(new Uint8Array(2));},cancel(){cancelled=true;}}),{status:206,headers:{'Content-Range':`bytes 0-0/${raw.length}`}})});
 await rejects(assets.read(manifest,{offset:0,limit:1}),'asset_storage_unavailable');assert.equal(cancelled,true);
 await rejects(assets.read(manifest,{offset:0,limit:65537}),'invalid_range');
});

test('full export refuses a legacy photo without its recoverable original',async()=>{const f=await fixture();try{
 await f.db.query("update carry_private.graph_entities set fields=fields-'originalAssetID',version=version+1 where account_id=$1 and id=$2",[f.p.accountID,f.ids.photo]);
 await rejects(f.prepare(),'photo_original_required');
 const shared=await f.prepare('share_trip');assert.ok(shared.id);
 }finally{await f.db.close();}});

test('stream authorization is rechecked after a delayed body read and rejected bytes are cancelled',async()=>{
 let allowed=true,cancelled=false;
 const bytes=Buffer.from('synthetic'),manifest={id:id(),accountID:id(),sha256:createHash('sha256').update(bytes).digest('hex'),byteCount:bytes.length,storageVersion:id(),status:'verified'};
 const assets=createAccountAssets({projectURL:'https://fixture.supabase.co',serviceKey:'synthetic-service-key',fetcher:async()=>new Response(new ReadableStream({pull(controller){allowed=false;controller.enqueue(bytes);},cancel(){cancelled=true;}},{highWaterMark:0}))});
 const stream=await assets.stream(manifest,{authorize:async()=>{if(!allowed)throw Error('revoked');}});
 await assert.rejects(stream.getReader().read(),/asset_download_failed/);assert.equal(cancelled,true);
});


test('revocation after Response preparation prevents even the first metadata chunk from being delivered',async()=>{const f=await fixture();try{
 for(const mode of ['share_trip','export_backup']){
  const connection=await f.grant(),p={...f.p,grantID:connection.id},result=await f.store.prepareExport({...p,mode,requestID:id()}),preview=await f.store.getExport({...p,id:result.id});
  await f.store.approveExport({...p,id:result.id,contentHash:preview.contentHash});
  const download=await f.store.downloadExport({...p,id:result.id});
  await f.store.revokeGrant({...p,id:connection.id});
  await assert.rejects(download.body.getReader().read(),/export_download_failed/);
 }
 }finally{await f.db.close();}});


test('cancelling an export immediately cancels its pending private provider read',async()=>{
 const {streamBackup}=await import('./exports.mjs');let started,cancelled=false;const opened=new Promise(resolve=>started=resolve);
 const body=streamBackup({backup:{version:1,trips:[]},files:[{id:id(),destination:'attachmentFiles',key:'synthetic'}]},{authorize:async()=>{},open:async()=>{started();return new ReadableStream({pull(){return new Promise(()=>{});},cancel(){cancelled=true;}},{highWaterMark:0});}});
 const reader=body.getReader(),pending=reader.read();await opened;
 const outcome=await Promise.race([reader.cancel().then(()=>true),new Promise(resolve=>setTimeout(()=>resolve(false),1000))]);
 assert.equal(outcome,true);assert.equal(cancelled,true);await pending;
});


test('removing an export trip from the current grant blocks summary and prepared metadata stream',async()=>{const f=await fixture();try{
 const preview=await f.approved('share_trip'),download=await f.store.downloadExport({...f.p,id:preview.id});
 await f.db.query("update carry_ai.records set value=jsonb_set(value,'{tripIDs}','[]'::jsonb) where bucket='grant' and id=$1",[f.g.id]);
 await rejects(f.store.getExport({...f.p,id:preview.id}),'trip_not_authorized');
 await assert.rejects(download.body.getReader().read(),/export_download_failed/);
 }finally{await f.db.close();}});


test('full export rejects native-incompatible per-file and aggregate byte budgets without truncation',async()=>{const f=await fixture();try{
 await f.db.query("update carry_private.assets set byte_count=$1 where account_id=$2 and entity_kind='attachment'",[26*1024*1024,f.p.accountID]);
 await rejects(f.prepare(),'export_file_too_large');
 await f.db.query("update carry_private.assets set byte_count=$1 where account_id=$2 and entity_kind='attachment'",[f.bytes.length,f.p.accountID]);
 await f.db.query("update carry_private.assets set byte_count=$1 where account_id=$2 and entity_kind<>'attachment'",[45*1024*1024,f.p.accountID]);
 await rejects(f.prepare(),'export_too_large');
 assert.ok((await f.prepare('share_trip')).id);
 }finally{await f.db.close();}});
