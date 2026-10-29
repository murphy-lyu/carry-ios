import { AccountRequestError } from './lifecycle.mjs';
import { readBoundedBytes } from './graph-http.mjs';

export function createDeletionStatusAdapter({configuration,fetcher=fetch}) {
  const project=new URL(configuration.projectURL),key=configuration.serviceKey;
  if(project.protocol!=='https:'||project.username||project.password||project.search||project.hash||
    !['','/'].includes(project.pathname)||!key)throw new Error('invalid_configuration');
  return {deletionStatus:async ticket=>{
    const signal=AbortSignal.timeout(15000);
    const response=await fetcher(new URL('/rest/v1/rpc/carry_account_deletion_status',project),{
      method:'POST',redirect:'error',signal,headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json'},
      body:JSON.stringify({p_ticket:ticket}),
    });
    let value;try{value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(await readBoundedBytes(response,4096,signal)));}
    catch{throw new Error('deletion_status_unavailable');}
    if(!response.ok) {
      if(value?.code==='28000')throw new AccountRequestError(401,'unauthorized');
      throw new Error('deletion_status_unavailable');
    }
    return value;
  }};
}
