import { GraphRequestError, isUUID } from './graph-http.mjs';

// Only server environment keys are accepted. No caller-selected URLs or owner IDs.
export function createGraphAdapter({configuration,jose,fetcher=fetch}) {
  const project=new URL(configuration.projectURL),key=configuration.serviceKey;
  if(project.protocol!=='https:'||project.username||project.password||project.search||project.hash||
    !['','/'].includes(project.pathname)||!key)throw new Error('invalid_configuration');
  const issuer=new URL('/auth/v1',project).href;
  async function send(path,options={}) {
    return fetcher(new URL(path,project),{...options,redirect:'error',signal:AbortSignal.timeout(15000),
      headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json',...options.headers}});
  }
  async function rpc(name,body){
    const response=await send(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(body)});
    if(response.ok)return response.json();
    let error;try{error=await response.json();}catch{throw new GraphRequestError(503,'service_unavailable');}
    if(error.code==='28000')throw new GraphRequestError(401,'session_expired');
    if(['field_conflict','subtree_conflict','move_conflict'].includes(error.message)&&error.code==='P0001'){
      let conflict;try{conflict=JSON.parse(error.details);}catch{throw new GraphRequestError(503,'service_unavailable');}
      throw new GraphRequestError(409,error.message,conflict);
    }
    const expected=['invalid_command','invalid_command_size','invalid_request_id','invalid_mutation','entity_exists','entity_not_found',
      'invalid_fields','unknown_field','invalid_field','invalid_parent','invalid_version','invalid_patch','use_move','invalid_field_versions',
      'subtree_version_required','restore_expired','deleted_entity','request_id_reused','duplicate_mutation','invalid_cursor',
      'trip_date_impact','transport_date_impact','duplicate_day','cost_currency_required'];
    if(expected.includes(error.message)&&error.code==='22023')throw new GraphRequestError(422,error.message);
    if(['22P02','22003'].includes(error.code))throw new GraphRequestError(422,'invalid_request');
    throw new GraphRequestError(503,'service_unavailable');
  }
  return {
    authenticate:async token=>{
      // decodeJwt extracts claims only AFTER Auth verified this exact bearer.
      // The database subsequently checks this session's continued existence.
      const response=await send('/auth/v1/user',{headers:{Authorization:`Bearer ${token}`}});
      if([401,403].includes(response.status))throw new GraphRequestError(401,'unauthorized');
      if(!response.ok)throw new GraphRequestError(503,'service_unavailable');
      const user=await response.json();let claims;try{claims=jose.decodeJwt(token);}catch{throw new GraphRequestError(401,'unauthorized');}
      if(claims.client_id!==undefined||!isUUID(user.id)||claims.sub!==user.id||claims.iss!==issuer||!isUUID(claims.session_id)||
        typeof claims.exp!=='number'||claims.exp<=Date.now()/1000||
        !user.identities?.some(identity=>identity.provider==='apple'))throw new GraphRequestError(401,'unauthorized');
      return {accountID:user.id,sessionID:claims.session_id};
    },
    rateLimit:identity=>rpc('carry_account_rate_limit',{p_account_id:identity.accountID}),
    apply:(identity,command)=>rpc('carry_graph_apply',{p_account:identity.accountID,p_session:identity.sessionID,p_command:command}),
    pull:(identity,cursor,limit)=>rpc('carry_graph_pull',{p_account:identity.accountID,p_session:identity.sessionID,p_cursor:cursor,p_limit:limit}),
  };
}
