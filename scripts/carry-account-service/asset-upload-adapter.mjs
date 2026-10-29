import { Buffer } from 'node:buffer';
import { createGraphAdapter } from './graph-adapter.mjs';
import { GraphRequestError, isUUID, readBoundedBytes } from './graph-http.mjs';
import { inspectStoredAsset } from './asset-storage.mjs';
const limit=6*1024*1024;

export function createAssetUploadAdapter({configuration,jose,fetcher=fetch}) {
  const auth=createGraphAdapter({configuration,jose,fetcher});
  const project=new URL(configuration.projectURL),storage=new URL(project),key=configuration.serviceKey;
  if(storage.hostname.endsWith('.supabase.co')&&!storage.hostname.endsWith('.storage.supabase.co')) {
    storage.hostname=storage.hostname.slice(0,-'.supabase.co'.length)+'.storage.supabase.co';
  }
  const headers={apikey:key,Authorization:`Bearer ${key}`};
  async function rpc(name,body,signal) {
    const deadline=signal?AbortSignal.any([signal,AbortSignal.timeout(15000)]):AbortSignal.timeout(15000);
    const response=await fetcher(new URL('/rest/v1/rpc/'+name,project),{method:'POST',redirect:'error',signal:deadline,
      headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify(body)});
    if(response.status===204)return null;
    let value;try{value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(await readBoundedBytes(response,65536,deadline)));}
    catch{throw new GraphRequestError(503,'service_unavailable');}
    if(response.ok)return value;
    const error=value;
    if(!error||typeof error!=='object')throw new GraphRequestError(503,'service_unavailable');
    if(error.code==='28000')throw new GraphRequestError(401,'session_expired');
    if(['22P02','22003'].includes(error.code))throw new GraphRequestError(400,'invalid_upload_request');
    if(error.code==='P0001') {
      if(error.message==='invalid_asset')throw new GraphRequestError(400,'invalid_asset');
      if(['asset_not_found','upload_attempt_not_found'].includes(error.message))throw new GraphRequestError(404,'upload_not_found');
      if(['upload_busy','upload_offset_mismatch','upload_operation_superseded','asset_unavailable','asset_cleanup_pending','upload_attempt_state','asset_identity_mismatch','asset_verification_mismatch'].includes(error.message))throw new GraphRequestError(409,error.message);
      if(error.message==='asset_budget_exceeded')throw new GraphRequestError(429,'asset_budget_exceeded');
    }
    throw new GraphRequestError(503,'service_unavailable');
  }
  function location(raw,identity,asset) {
    const url=new URL(raw),prefix='/storage/v1/upload/resumable/';
    if(![project.origin,storage.origin].includes(url.origin)||url.username||url.password||url.search||url.hash||!url.pathname.startsWith(prefix))throw new GraphRequestError(502,'invalid_storage_location');
    const encoded=url.pathname.slice(prefix.length);
    const bytes=Buffer.from(encoded,'base64url');
    if(!encoded||encoded.length>3000||bytes.toString('base64url')!==encoded)throw new GraphRequestError(502,'invalid_storage_location');
    const decoded=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
    const expected=`carry-account-assets/${identity.accountID.toLowerCase()}/${asset.id.toLowerCase()}/${asset.sha256}/`;
    if(!decoded.startsWith(expected)||!isUUID(decoded.slice(expected.length)))throw new GraphRequestError(502,'invalid_storage_location');
    return url;
  }
  return {
    publicURL:project.origin,
    cleanupAccounts:token=>rpc('carry_asset_cleanup_accounts',{p_token:token}),
    authenticate:auth.authenticate,
    rateLimit:identity=>rpc('carry_asset_rate_limit',{p_account:identity.accountID,p_session:identity.sessionID}),
    reserve:(identity,asset)=>rpc('carry_asset_reserve',{p_account:identity.accountID,p_session:identity.sessionID,p_asset:asset}),
    descriptor:(identity,id)=>rpc('carry_asset_descriptor',{p_account:identity.accountID,p_session:identity.sessionID,p_id:id}),
    begin:(identity,id)=>rpc('carry_asset_upload_begin',{p_account:identity.accountID,p_session:identity.sessionID,p_asset:id}),
    created:(identity,attempt,url)=>rpc('carry_asset_upload_created',{p_account:identity.accountID,p_id:attempt.id,p_creation:attempt.creationID,p_location:url}),
    claim:(identity,id,operation,method,offset)=>rpc('carry_asset_upload_claim',{p_account:identity.accountID,p_session:identity.sessionID,p_id:id,p_operation:operation,p_method:method,p_offset:offset}),
    finish:(identity,id,operation,offset,gone)=>rpc('carry_asset_upload_finish',{p_account:identity.accountID,p_id:id,p_operation:operation,p_offset:offset,p_gone:gone}),
    inspectionTarget:(identity,id)=>rpc('carry_asset_inspection_target',{p_account:identity.accountID,p_session:identity.sessionID,p_id:id}),
    inspect:(manifest,signal)=>inspectStoredAsset({projectURL:project.href,serviceKey:key,manifest,fetcher,signal:AbortSignal.any([signal,AbortSignal.timeout(15000)])}),
    inspected:(identity,manifest,measurement)=>rpc('carry_asset_inspection_finish',{p_account:identity.accountID,p_session:identity.sessionID,p_id:manifest.id,
      p_version:manifest.storageVersion,p_sha256:measurement?.sha256??null,p_bytes:measurement?.byteCount??null}),
    createStorage:async(identity,asset,signal)=>{
      const object=`${identity.accountID.toLowerCase()}/${asset.id.toLowerCase()}/${asset.sha256}`;
      const metadata={bucketName:'carry-account-assets',objectName:object,contentType:asset.contentType,cacheControl:'0'};
      const response=await fetcher(new URL('/storage/v1/upload/resumable',storage),{method:'POST',redirect:'error',signal:AbortSignal.any([signal,AbortSignal.timeout(60000)]),
        headers:{...headers,'Tus-Resumable':'1.0.0','Upload-Length':String(asset.byteCount),
          'Upload-Metadata':Object.entries(metadata).map(([k,v])=>`${k} ${Buffer.from(v).toString('base64')}`).join(',')}});
      try {
        if(response.status!==201||response.headers.get('tus-resumable')!=='1.0.0')throw new GraphRequestError(503,'storage_unavailable');
        return location(response.headers.get('location'),identity,asset).href;
      } finally { await response.body?.cancel(); }
    },
    transfer:async(identity,claim,request,count)=>{
      const url=location(claim.location,identity,{id:claim.assetID,sha256:claim.sha256});
      const options={method:request.method,redirect:'error',signal:AbortSignal.any([request.signal,AbortSignal.timeout(60000)]),headers:{...headers,'Tus-Resumable':'1.0.0'}};
      if(request.method==='PATCH') {
        if(!Number.isSafeInteger(count)||count<=0||count>limit)throw new GraphRequestError(400,'invalid_upload_length');
        let received=0;
        const bound=new TransformStream({transform(chunk,controller){
          received+=chunk.byteLength;
          if(received>count)throw new GraphRequestError(413,'upload_body_too_large');
          controller.enqueue(chunk);
        },flush(){if(received!==count)throw new GraphRequestError(400,'upload_body_truncated');}});
        options.body=request.body.pipeThrough(bound,{signal:options.signal});options.duplex='half';
        options.headers['Content-Type']='application/offset+octet-stream';
        options.headers['Upload-Offset']=request.headers.get('upload-offset');
        options.headers['Content-Length']=String(count);
      }
      return fetcher(url,options);
    },
    cleanupOne:async accountID=>{
      if(!isUUID(accountID))throw new Error('invalid_cleanup_account');
      const operation=crypto.randomUUID(),signal=AbortSignal.timeout(110000);
      await rpc('carry_asset_cleanup_empty',{p_account:accountID},signal);
      const job=await rpc('carry_asset_cleanup_claim',{p_account:accountID,p_operation:operation},signal);
      if(!job)return false;
      if(job.accountID!==accountID||!isUUID(job.id)||!isUUID(job.assetID)||!/^[0-9a-f]{64}$/.test(job.sha256))throw new Error('invalid_cleanup_job');
      if(job.location) {
        const url=location(job.location,{accountID},{id:job.assetID,sha256:job.sha256});
        const version=Buffer.from(url.pathname.split('/').pop(),'base64url').toString('utf8').split('/').pop();
        if(!isUUID(job.storageVersion)||version!==job.storageVersion)throw new Error('invalid_cleanup_version');
        const termination=await fetcher(url,{method:'DELETE',redirect:'error',signal,headers:{...headers,'Tus-Resumable':'1.0.0'}});
        const status=termination.status;await termination.body?.cancel();
        if(![204,404,410].includes(status)) {
          if(![403,409].includes(status))throw new Error('cleanup_termination_unconfirmed');
          // Finished TUS uploads cannot be terminated. Prove that state before
          // proceeding to the provider's exact-version removal endpoint.
          const head=await fetcher(url,{method:'HEAD',redirect:'error',signal,headers:{...headers,'Tus-Resumable':'1.0.0'}});
          try {
            if(head.status!==200||head.headers.get('tus-resumable')!=='1.0.0'||
              head.headers.get('upload-offset')!==String(job.byteCount)||head.headers.get('upload-length')!==String(job.byteCount))throw new Error('cleanup_termination_unconfirmed');
          }finally{await head.body?.cancel();}
        }
        const object=`${accountID.toLowerCase()}/${job.assetID.toLowerCase()}/${job.sha256}`;
        const removal=await fetcher(new URL('/storage/v1/object/carry-account-assets',storage),{method:'DELETE',redirect:'error',signal,
          headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({prefixes:[{path:object,versionId:version}]})});
        try { if(!removal.ok)throw new Error('cleanup_removal_unconfirmed'); }
        finally{await removal.body?.cancel();}
      } else if(job.mayHaveBytes!==false) {
        throw new Error('cleanup_location_missing');
      }
      // Unknown creations have no body and are never PATCH-able through the
      // broker. Their provider-side empty metadata expires under provider TTL;
      // no user file bytes can be silently forgotten here. Known versions must
      // additionally be absent from Storage metadata before the ledger clears.
      await rpc('carry_asset_cleanup_finish',{p_account:accountID,p_id:job.id,p_operation:operation},signal);
      return true;
    },
  };
}
