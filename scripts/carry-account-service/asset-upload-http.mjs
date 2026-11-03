import { GraphRequestError, isUUID, readBoundedBytes } from './graph-http.mjs';
const root='/functions/v1/carry-assets/tus';
const chunkBytes=6*1024*1024;
const integer=value=>typeof value==='string'&&/^(0|[1-9][0-9]*)$/.test(value)&&Number.isSafeInteger(Number(value))?Number(value):null;
const reply=(status,headers={})=>new Response(null,{status,headers:{'Tus-Resumable':'1.0.0','Cache-Control':'no-store',...headers}});

function metadata(request,identity) {
  const raw=request.headers.get('upload-metadata');
  if(!raw||raw.length>4096)throw new GraphRequestError(400,'invalid_upload_metadata');
  const fields={};
  for(const entry of raw.split(',')) {
    const pair=entry.match(/^([A-Za-z]+) ([A-Za-z0-9+/]*={0,2})$/);
    if(!pair||Object.hasOwn(fields,pair[1]))throw new GraphRequestError(400,'invalid_upload_metadata');
    try { fields[pair[1]]=new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(atob(pair[2]),c=>c.charCodeAt(0))); }
    catch { throw new GraphRequestError(400,'invalid_upload_metadata'); }
  }
  if(Object.keys(fields).sort().join(',')!=='bucketName,cacheControl,contentType,objectName'||
      fields.bucketName!=='carry-account-assets'||fields.cacheControl!=='0')throw new GraphRequestError(400,'invalid_upload_metadata');
  const [owner,id,sha,extra]=fields.objectName.split('/');
  if(owner!==identity.accountID.toLowerCase()||!isUUID(id)||id!==id.toLowerCase()||extra!==undefined||!/^[0-9a-f]{64}$/.test(sha)) {
    throw new GraphRequestError(400,'invalid_upload_metadata');
  }
  const length=integer(request.headers.get('upload-length'));
  if(length===null||length<1||length>50*1024*1024)throw new GraphRequestError(400,'invalid_upload_length');
  return {id,sha,contentType:fields.contentType,length};
}

/** Native-only broker. Adapter ownership comes from verified Auth/session data.
 * Upstream storage URLs and service credentials never leave this boundary. */
export function createAssetUploadHandler(adapter) {
  const publicURL=new URL(adapter.publicURL);
  if(publicURL.protocol!=='https:'||publicURL.username||publicURL.password||publicURL.search||publicURL.hash||!['','/'].includes(publicURL.pathname))throw new Error('invalid_configuration');
  return async request=>{
    let identity,authorized=false;
    try {
      const url=new URL(request.url);
      if(url.search||url.hash)throw new GraphRequestError(400,'invalid_upload_path');
      // Edge gateways may remove /functions/v1 before invoking the function.
      // Public locations always use configuration, never Host/forwarded input.
      const path=url.pathname.startsWith('/carry-assets/')?'/functions/v1'+url.pathname:url.pathname;
      const create=path===root;
      const id=create?null:path.startsWith(root+'/')?path.slice(root.length+1):null;
      if(!create&&!isUUID(id))throw new GraphRequestError(404,'upload_not_found');
      if((create&&request.method!=='POST')||(!create&&!['HEAD','PATCH'].includes(request.method)))throw new GraphRequestError(405,'method_not_allowed');
      if(request.headers.get('tus-resumable')!=='1.0.0')throw new GraphRequestError(412,'invalid_tus_version');
      const token=request.headers.get('authorization')?.match(/^Bearer ([^\s]+)$/)?.[1];
      if(!token||token.length>16000)throw new GraphRequestError(401,'unauthorized');
      identity=await adapter.authenticate(token);
      if(!isUUID(identity?.accountID)||!isUUID(identity?.sessionID))throw new GraphRequestError(401,'unauthorized');
      if(!await adapter.rateLimit(identity))throw new GraphRequestError(429,'rate_limited');
      authorized=true;
      if(create) {
        await readBoundedBytes(request,0);
        const input=metadata(request,identity),asset=await adapter.descriptor(identity,input.id);
        if(asset.sha256!==input.sha||asset.byteCount!==input.length||asset.contentType!==input.contentType)throw new GraphRequestError(409,'asset_identity_mismatch');
        const attempt=await adapter.begin(identity,asset.id);
        if(attempt.status==='verified')throw new GraphRequestError(409,'asset_already_verified');
        if(attempt.status==='creating')throw new GraphRequestError(503,'upload_creation_pending');
        if(!isUUID(attempt.id))throw new GraphRequestError(503,'invalid_upload_response');
        if(attempt.status==='create') {
          let location;
          try { location=await adapter.createStorage(identity,asset,request.signal); }
          catch(error) {
            await adapter.created(identity,attempt,null);
            throw error;
          }
          const result=await adapter.created(identity,attempt,location);
          if(result.status!=='active')throw new GraphRequestError(409,'upload_unavailable');
        } else if(attempt.status!=='active')throw new GraphRequestError(503,'invalid_upload_response');
        // A native/session/deletion recheck after the asynchronous create must
        // precede publishing any client-visible upload location.
        await adapter.descriptor(identity,asset.id);
        return reply(201,{Location:new URL(root+'/'+attempt.id,publicURL).href});
      }
      const patch=request.method==='PATCH';
      if(patch&&request.headers.get('content-type')!=='application/offset+octet-stream')throw new GraphRequestError(415,'invalid_patch_type');
      const offset=patch?integer(request.headers.get('upload-offset')):null;
      if(patch&&offset===null)throw new GraphRequestError(400,'invalid_upload_offset');
      const operation=crypto.randomUUID();
      const claim=await adapter.claim(identity,id,operation,request.method,offset);
      let finished=false,response;
      try {
        const count=patch?Math.min(chunkBytes,claim.byteCount-offset):0;
        if(patch&&(count<=0||!request.body))throw new GraphRequestError(400,'invalid_upload_body');
        const declared=request.headers.get('content-length');
        if(patch&&declared!==null&&integer(declared)!==count)throw new GraphRequestError(400,'invalid_upload_length');
        response=await adapter.transfer(identity,claim,request,count);
        const gone=[404,410].includes(response.status);
        let next=null;
        if((patch&&response.status===204)||(!patch&&[200,204].includes(response.status))) {
          next=integer(response.headers.get('upload-offset'));
          if(response.headers.get('tus-resumable')!=='1.0.0'||next===null||next>claim.byteCount||
             (patch&&next!==offset+count)||(!patch&&integer(response.headers.get('upload-length'))!==claim.byteCount))throw new GraphRequestError(502,'invalid_storage_response');
        }
        // Ignore storage diagnostic bodies; neither private locations nor raw
        // service responses can become client error messages.
        await adapter.finish(identity,id,operation,next,gone);finished=true;
        if(gone)return reply(response.status);
        if(next!==null)return reply(patch?204:200,{'Upload-Offset':String(next),...(!patch?{'Upload-Length':String(claim.byteCount)}:{})});
        if(response.status===409)throw new GraphRequestError(409,'upload_offset_mismatch');
        if(response.status===429)throw new GraphRequestError(429,'storage_rate_limited');
        throw new GraphRequestError(503,'storage_unavailable');
      } finally {
        try { await response?.body?.cancel(); }
        finally { if(!finished)await adapter.finish(identity,id,operation,null,false); }
      }
    } catch(error) {
      if(error instanceof GraphRequestError)return reply(error.status);
      return reply(503);
    } finally {
      if(authorized&&adapter.scheduleCleanup)adapter.scheduleCleanup(identity.accountID);
    }
  };
}
