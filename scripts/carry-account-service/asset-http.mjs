import { boundedJSON, GraphRequestError, isUUID } from './graph-http.mjs';
import { createAssetUploadHandler } from './asset-upload-http.mjs';
import { AssetInspectionError } from './asset-storage.mjs';

export function createAssetHandler(adapter) {
  const upload=createAssetUploadHandler(adapter);
  return async request=>{
    const url=new URL(request.url);
    const path=url.pathname.startsWith('/carry-assets/')?'/functions/v1'+url.pathname:url.pathname;
    if(path==='/functions/v1/carry-assets/tus'||path.startsWith('/functions/v1/carry-assets/tus/'))return upload(request);
    const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
    let identity,authorized=false;
    try {
      if(!['/functions/v1/carry-assets/reserve','/functions/v1/carry-assets/verify'].includes(path))throw new GraphRequestError(404,'not_found');
      if(request.method!=='POST')throw new GraphRequestError(405,'method_not_allowed');
      if(url.search||url.hash)throw new GraphRequestError(400,'invalid_request');
      const token=request.headers.get('authorization')?.match(/^Bearer ([^\s]+)$/)?.[1];
      if(!token||token.length>16000)throw new GraphRequestError(401,'unauthorized');
      identity=await adapter.authenticate(token);
      if(!isUUID(identity?.accountID)||!isUUID(identity?.sessionID))throw new GraphRequestError(401,'unauthorized');
      if(!await adapter.rateLimit(identity))throw new GraphRequestError(429,'rate_limited');
      authorized=true;
      const body=await boundedJSON(request,8192);
      if(!body||typeof body!=='object'||Array.isArray(body))throw new GraphRequestError(400,'invalid_request');
      if(path.endsWith('/reserve'))return reply(await adapter.reserve(identity,body));
      if(Object.keys(body).length!==1||!isUUID(body.id))throw new GraphRequestError(400,'invalid_request');
      const manifest=await adapter.inspectionTarget(identity,body.id);
      if(manifest.status==='not_uploaded')throw new GraphRequestError(409,'asset_not_uploaded');
      if(manifest.status==='verified')return reply({id:manifest.id,status:'verified'});
      let measurement;
      try { measurement=await adapter.inspect(manifest,request.signal); }
      catch(error) {
        if(error instanceof AssetInspectionError&&error.code==='asset_integrity_mismatch') {
          // A temporary outage/cancellation never schedules deletion. Only a
          // byte-integrity failure bound to the same provider version does.
          const result=await adapter.inspected(identity,manifest,null);
          if(result.status==='retry')throw new GraphRequestError(409,'asset_changed_during_inspection');
          throw new GraphRequestError(422,'asset_integrity_mismatch');
        }
        if(error instanceof AssetInspectionError&&error.code==='asset_not_uploaded')throw new GraphRequestError(409,'asset_not_uploaded');
        throw error;
      }
      const result=await adapter.inspected(identity,manifest,measurement);
      if(result.status==='retry')throw new GraphRequestError(409,'asset_changed_during_inspection');
      if(result.status!=='verified')throw new GraphRequestError(422,'asset_integrity_mismatch');
      return reply({id:manifest.id,status:'verified'});
    }catch(error) {
      if(error instanceof GraphRequestError)return reply({error:error.code},error.status);
      return reply({error:'service_unavailable'},503);
    } finally {
      if(authorized&&adapter.scheduleCleanup)adapter.scheduleCleanup(identity.accountID);
    }
  };
}
