import { GraphRequestError, isUUID, readBoundedBytes } from './graph-http.mjs';

// The internal capability cannot choose accounts, disclose data or issue sessions.
export function createAssetCleanupHandler(adapter) {
  return async request => {
    const reply=(body,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});
    try {
      if(request.method!=='POST')return reply({error:'method_not_allowed'},405);
      const token=request.headers.get('x-carry-cleanup');
      if(!token||!/^[0-9a-f]{64}$/.test(token))return reply({error:'unauthorized'},401);
      const body=await readBoundedBytes(request,2);
      if(body.length&&new TextDecoder().decode(body)!=='{}')return reply({error:'invalid_request'},400);
      const accounts=await adapter.cleanupAccounts(token);
      if(!Array.isArray(accounts)||accounts.length>2||accounts.some(id=>!isUUID(id))||new Set(accounts).size!==accounts.length)
        throw new Error('invalid_cleanup_accounts');
      const outcomes=await Promise.allSettled(accounts.map(id=>adapter.cleanupOne(id)));
      return reply({processed:outcomes.filter(r=>r.status==='fulfilled'&&r.value===true).length,
        deferred:outcomes.filter(r=>r.status==='rejected').length});
    }catch(error) {
      if(error instanceof GraphRequestError)return reply({error:error.status===401?'unauthorized':error.code},error.status);
      return reply({error:'service_unavailable'},503);
    }
  };
}
