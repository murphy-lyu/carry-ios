import { AccountRequestError } from './lifecycle.mjs';
import { GraphRequestError, readBoundedBytes } from './graph-http.mjs';

// This dedicated endpoint authenticates the high-entropy deletion receipt, not
// an Auth JWT: it must keep working after the user's Auth identity is removed.
// The receipt grants only a coarse status and is never placed in a URL.
export function createDeletionStatusHandler(adapter) {
  return async request=>{
    const reply=(body,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});
    try {
      if(request.method!=='POST')return reply({error:'method_not_allowed'},405);
      const receipt=request.headers.get('authorization')?.match(/^Bearer ([0-9a-f]{64})$/)?.[1];
      if(!receipt)return reply({error:'unauthorized'},401);
      await readBoundedBytes(request,0);
      const result=await adapter.deletionStatus(receipt);
      if(!result||!['deleting','deleted'].includes(result.status))throw new Error('invalid_deletion_status');
      return reply({status:result.status});
    }catch(error) {
      if(error instanceof AccountRequestError&&error.status===401)return reply({error:'unauthorized'},401);
      if(error instanceof GraphRequestError)return reply({error:error.code},error.status);
      return reply({error:'service_unavailable'},503);
    }
  };
}
