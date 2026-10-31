import { createHash } from 'node:crypto';
import { GraphRequestError, isUUID } from './graph-http.mjs';

const maximumBytes=50*1024*1024;
function validManifest(manifest,identity,id) {
  return manifest?.status==='verified'&&manifest.accountID===identity.accountID&&manifest.id===id&&
    isUUID(manifest.storageVersion)&&/^[0-9a-f]{64}$/.test(manifest.sha256)&&
    Number.isSafeInteger(manifest.byteCount)&&manifest.byteCount>0&&manifest.byteCount<=maximumBytes;
}

function validPublishedManifest(manifest,identity,id) {
  return validManifest(manifest,identity,id)&&isUUID(manifest.entityID)&&
    ['photo','attachment','trip'].includes(manifest.entityKind)&&typeof manifest.slot==='string'&&
    ((manifest.entityKind==='photo'&&['thumbnail','original'].includes(manifest.slot))||
     (manifest.entityKind==='attachment'&&['thumbnail','file'].includes(manifest.slot))||
     (manifest.entityKind==='trip'&&/^background:[0-9]{1,4}:[0-9]{1,4}$/.test(manifest.slot)));
}

export function createAssetManifestHandler(adapter) {
  return async(request,id)=>{
    const reply=(body,status)=>Response.json(body,{status,headers:{'Cache-Control':'private, no-store, max-age=0','X-Content-Type-Options':'nosniff'}});
    try {
      const url=new URL(request.url);
      if(request.method!=='GET')throw new GraphRequestError(405,'method_not_allowed');
      if(!isUUID(id)||url.search||url.hash||request.headers.has('Range'))throw new GraphRequestError(400,'invalid_manifest_request');
      id=id.toLowerCase();
      const token=request.headers.get('authorization')?.match(/^Bearer ([^\s]+)$/)?.[1];
      if(!token||token.length>16000)throw new GraphRequestError(401,'unauthorized');
      const identity=await adapter.authenticate(token);
      if(!isUUID(identity?.accountID)||!isUUID(identity?.sessionID))throw new GraphRequestError(401,'unauthorized');
      if(!await adapter.rateLimit(identity))throw new GraphRequestError(429,'rate_limited');
      const manifest=await adapter.downloadManifest(identity,id);
      if(!validPublishedManifest(manifest,identity,id))throw new GraphRequestError(409,'asset_not_verified');
      return reply({accountID:manifest.accountID,assetID:manifest.id,entityID:manifest.entityID,kind:manifest.entityKind,
        slot:manifest.slot,sha256:manifest.sha256,byteCount:manifest.byteCount,providerVersion:manifest.storageVersion},200);
    }catch(error) {
      return error instanceof GraphRequestError?reply({error:error.status===404?'asset_not_found':error.code},error.status):reply({error:'service_unavailable'},503);
    }
  };
}

/** Only private-ledger identities reach this function. The version is part of
 * the fixed provider request; an object replacement cannot change its bytes. */
export async function openStoredAsset({projectURL,serviceKey,manifest,fetcher=fetch,signal}) {
  const url=new URL(projectURL);
  if(url.protocol!=='https:'||url.username||url.password||url.search||url.hash||
      !['','/'].includes(url.pathname)||!serviceKey||!validManifest(manifest,{accountID:manifest?.accountID},manifest?.id)||
      !isUUID(manifest.accountID)||!isUUID(manifest.id))throw new GraphRequestError(503,'invalid_asset_manifest');
  if(url.hostname.endsWith('.supabase.co')&&!url.hostname.endsWith('.storage.supabase.co')) {
    url.hostname=url.hostname.slice(0,-'.supabase.co'.length)+'.storage.supabase.co';
  }
  url.pathname=`/storage/v1/object/authenticated/carry-account-assets/${manifest.accountID.toLowerCase()}/${manifest.id.toLowerCase()}/${manifest.sha256}`;
  url.searchParams.set('versionId',manifest.storageVersion);
  return fetcher(url,{method:'GET',redirect:'error',signal,
    headers:{apikey:serviceKey,Authorization:`Bearer ${serviceKey}`,'Accept-Encoding':'identity','Cache-Control':'no-cache'}});
}

/** No signed URL or provider header is returned. Authorize each new request,
 * then repeat the current session/ledger check after awaiting provider headers.
 * An already authorized stream may finish; revoked sessions cannot start one. */
export function createAssetDownloadHandler(adapter) {
  return async(request,id)=>{
    let upstream;
    const reply=(code,status)=>Response.json({error:code},{status,headers:{'Cache-Control':'no-store'}});
    try {
      const url=new URL(request.url);
      if(request.method!=='GET')throw new GraphRequestError(405,'method_not_allowed');
      if(!isUUID(id)||url.search||url.hash||request.headers.has('Range'))throw new GraphRequestError(400,'invalid_download_request');
      id=id.toLowerCase();
      const token=request.headers.get('authorization')?.match(/^Bearer ([^\s]+)$/)?.[1];
      if(!token||token.length>16000)throw new GraphRequestError(401,'unauthorized');
      const identity=await adapter.authenticate(token);
      if(!isUUID(identity?.accountID)||!isUUID(identity?.sessionID))throw new GraphRequestError(401,'unauthorized');
      if(!await adapter.rateLimit(identity))throw new GraphRequestError(429,'rate_limited');
      const manifest=await adapter.downloadManifest(identity,id);
      if(!validPublishedManifest(manifest,identity,id))throw new GraphRequestError(409,'asset_not_verified');
      const signal=AbortSignal.any([request.signal,AbortSignal.timeout(60000)]);
      upstream=await adapter.openDownload(manifest,signal);
      const length=upstream.headers.get('Content-Length'),encoding=upstream.headers.get('Content-Encoding');
      if(upstream.status!==200||!upstream.body||
        (length!==null&&(!/^[0-9]+$/.test(length)||Number(length)!==manifest.byteCount))||
        (encoding!==null&&encoding!=='identity'))throw new GraphRequestError(503,'asset_storage_unavailable');
      const current=await adapter.downloadManifest(identity,id);
      if(!validPublishedManifest(current,identity,id)||current.storageVersion!==manifest.storageVersion||
        current.sha256!==manifest.sha256||current.byteCount!==manifest.byteCount)throw new GraphRequestError(409,'asset_changed_during_download');
      signal.throwIfAborted();
      const reader=upstream.body.getReader(),hash=createHash('sha256');let received=0,ended=false;
      const stop=async()=>{if(!ended){ended=true;await reader.cancel().catch(()=>{});reader.releaseLock();}};
      const abort=()=>{void stop();};signal.addEventListener('abort',abort,{once:true});
      const body=new ReadableStream({
        async pull(controller) {
          try {
            signal.throwIfAborted();
            const {done,value}=await reader.read();signal.throwIfAborted();
            if(done) {
              if(received!==manifest.byteCount||hash.digest('hex')!==manifest.sha256)throw new Error('asset_integrity_mismatch');
              ended=true;reader.releaseLock();signal.removeEventListener('abort',abort);controller.close();return;
            }
            received+=value.byteLength;
            if(received>manifest.byteCount)throw new Error('asset_integrity_mismatch');
            hash.update(value);controller.enqueue(value);
          }catch {signal.removeEventListener('abort',abort);await stop();controller.error(new Error('asset_download_failed'));}
        },
        async cancel(){signal.removeEventListener('abort',abort);await stop();},
      },{highWaterMark:0});
      upstream=null;
      return new Response(body,{status:200,headers:{
        'Content-Type':'application/octet-stream','Content-Length':String(manifest.byteCount),
        'Content-Disposition':`attachment; filename="${id}.asset"`,'Cache-Control':'private, no-store, max-age=0',
        'X-Content-Type-Options':'nosniff','X-Carry-Asset-ID':id,'X-Carry-Asset-SHA256':manifest.sha256,
        'X-Carry-Asset-Version':manifest.storageVersion,
      }});
    }catch(error) {
      await upstream?.body?.cancel().catch(()=>{});
      return error instanceof GraphRequestError?reply(error.status===404?'asset_not_found':error.code,error.status):reply('service_unavailable',503);
    }
  };
}
