import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {createAssetDownloadHandler,createAssetManifestHandler,openStoredAsset} from './asset-download.mjs';
import {GraphRequestError} from './graph-http.mjs';
const accountID=randomUUID(),sessionID=randomUUID(),id=randomUUID(),version=randomUUID();
const raw=new Uint8Array([1,2,3,4]),sha256=createHash('sha256').update(raw).digest('hex');
const manifest={accountID,id,entityID:randomUUID(),entityKind:'attachment',slot:'file',storageVersion:version,sha256,byteCount:raw.length,status:'verified'};
const url='https://project.invalid/functions/v1/carry-assets/download/'+id;
function fixture(overrides={}) {
  const calls=[];
  const adapter={authenticate:async token=>{calls.push('auth');if(token!=='synthetic')throw new GraphRequestError(401,'unauthorized');return {accountID,sessionID};},
    rateLimit:async()=>{calls.push('rate');return true;},downloadManifest:async()=>{calls.push('manifest');return manifest;},
    openDownload:async()=>{calls.push('storage');return new Response(raw);},...overrides};
  return {calls,handler:createAssetDownloadHandler(adapter),request:(options={})=>new Request(url,{headers:{Authorization:'Bearer synthetic'},...options})};
}
test('private download streams verified bytes, repeats authorization and exposes no provider headers',async()=>{
  const f=fixture({openDownload:async()=>new Response(raw,{headers:{Location:'https://private.invalid',ETag:'provider-version',Authorization:'private-key'}})});
  const response=await f.handler(f.request(),id);
  assert.equal(response.status,200);assert.deepEqual(new Uint8Array(await response.arrayBuffer()),raw);
  assert.deepEqual(f.calls,['auth','rate','manifest','manifest']);
  for(const header of ['Location','ETag','Authorization'])assert.equal(response.headers.get(header),null);
  assert.equal(response.headers.get('X-Carry-Asset-SHA256'),sha256);
  assert.equal(response.headers.get('X-Carry-Asset-Version'),version);
  assert.match(response.headers.get('Cache-Control'),/no-store/);
});
test('untrusted paths, methods, range and URLs cannot select storage objects',async()=>{
  const f=fixture();
  for(const request of [new Request(url+'?url=https://evil.invalid'),f.request({method:'POST'}),f.request({headers:{Range:'bytes=0-1'}})]) {
    assert.ok([400,405].includes((await f.handler(request,id)).status));
  }
  assert.equal((await f.handler(f.request(),'../private')).status,400);assert.deepEqual(f.calls,[]);
});
test('missing, cross-account, unverified and malformed manifests never reach storage',async()=>{
  for(const value of [{...manifest,status:'pending'},{...manifest,accountID:randomUUID()},{...manifest,id:randomUUID()},
    {...manifest,storageVersion:'bad'},{...manifest,byteCount:50*1024*1024+1},{...manifest,sha256:'bad'}]) {
    const f=fixture({downloadManifest:async()=>value});
    assert.equal((await f.handler(f.request(),id)).status,409);assert.ok(!f.calls.includes('storage'));
  }
});
test('revocation or version change while fetching provider headers cancels body before publishing',async()=>{
  for(const revoked of [false,true]) {
    let checks=0,cancelled=false;
    const f=fixture({downloadManifest:async()=>{
      if(++checks===1)return manifest;
      if(revoked)throw new GraphRequestError(401,'session_expired');
      return {...manifest,storageVersion:randomUUID()};
    },openDownload:async()=>new Response(new ReadableStream({cancel(){cancelled=true;}}))});
    assert.equal((await f.handler(f.request(),id)).status,revoked?401:409);assert.equal(cancelled,true);
  }
});
test('overflow, truncated and corrupt bytes fail the response stream',async()=>{
  for(const body of [new Uint8Array([1]),new Uint8Array([0,0,0,0]),new Uint8Array(5)]) {
    const f=fixture({openDownload:async()=>new Response(body)}),response=await f.handler(f.request(),id);
    assert.equal(response.status,200);await assert.rejects(response.arrayBuffer());
  }
});
test('redirect/error/encoded/incorrect length provider responses fail before streaming',async()=>{
  for(const response of [new Response(null,{status:302,headers:{Location:'https://evil.invalid'}}),new Response(null,{status:404}),
    new Response(raw,{headers:{'Content-Length':'999'}}),new Response(raw,{headers:{'Content-Encoding':'gzip'}})]) {
    const f=fixture({openDownload:async()=>response});assert.equal((await f.handler(f.request(),id)).status,503);
  }
});
test('cancellation stops the upstream reader without buffering the whole asset',async()=>{
  let cancelled=false,pulls=0;
  const f=fixture({openDownload:async()=>new Response(new ReadableStream({pull(controller){pulls++;controller.enqueue(raw);},cancel(){cancelled=true;}}))});
  const response=await f.handler(f.request(),id);
  await response.body.cancel();assert.equal(cancelled,true);assert.ok(pulls<=1);
});
test('provider request uses only the fixed project path and exact private ledger version',async()=>{
  let calls=0;
  await openStoredAsset({projectURL:'https://demo.supabase.co',serviceKey:'synthetic-private',manifest,
    fetcher:async(raw,options)=>{
      calls++;const url=new URL(raw);assert.equal(url.origin,'https://demo.storage.supabase.co');
      assert.equal(url.pathname,`/storage/v1/object/authenticated/carry-account-assets/${accountID}/${id}/${sha256}`);
      assert.equal(url.searchParams.get('versionId'),version);assert.equal(options.redirect,'error');
      assert.equal(options.headers.Authorization,'Bearer synthetic-private');return new Response(raw);
    }});
  assert.equal(calls,1);
  await assert.rejects(openStoredAsset({projectURL:'https://evil.invalid/path',serviceKey:'synthetic',manifest}));
});

test('native manifest returns only exact bound identity and immutable version metadata',async()=>{
  const handler=createAssetManifestHandler({authenticate:async()=>({accountID,sessionID}),rateLimit:async()=>true,
    downloadManifest:async()=>({...manifest,location:'https://private.invalid',serviceKey:'never-return'})});
  const response=await handler(new Request(url.replace('/download/','/manifest/'),{headers:{Authorization:'Bearer synthetic'}}),id);
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{accountID,assetID:id,entityID:manifest.entityID,kind:'attachment',slot:'file',sha256,byteCount:raw.length,providerVersion:version});
  assert.match(response.headers.get('Cache-Control'),/no-store/);
});

test('native manifest rejects methods selectors malformed ledger and unauthorized identities',async()=>{
  const endpoint=url.replace('/download/','/manifest/');
  const request=options=>new Request(endpoint,{headers:{Authorization:'Bearer synthetic'},...options});
  let storageCalls=0;
  const base={authenticate:async()=>({accountID,sessionID}),rateLimit:async()=>true,downloadManifest:async()=>manifest,
    openDownload:async()=>{storageCalls++;throw new Error('Manifest must not fetch bytes');}};
  const handler=createAssetManifestHandler(base);
  for(const req of [request({method:'POST'}),new Request(endpoint+'?url=https://evil.invalid'),request({headers:{Range:'bytes=1-2'}})])assert.ok([400,405].includes((await handler(req,id)).status));
  for(const value of [{...manifest,entityID:'bad'},{...manifest,entityKind:'trip',slot:'file'},{...manifest,slot:'../x'},{...manifest,accountID:randomUUID()},{...manifest,status:'pending'}]) {
    assert.equal((await createAssetManifestHandler({...base,downloadManifest:async()=>value})(request(),id)).status,409);
  }
  assert.equal((await createAssetManifestHandler({...base,authenticate:async()=>null})(request(),id)).status,401);
  assert.equal((await createAssetManifestHandler({...base,rateLimit:async()=>false})(request(),id)).status,429);
  assert.equal(storageCalls,0);
});
