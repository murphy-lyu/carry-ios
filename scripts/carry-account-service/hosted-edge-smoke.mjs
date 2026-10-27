// Read-only negative checks on the isolated development endpoint. No real user
// identity is created, selected or impersonated. Never supply a service key.
const base=new URL(process.env.CARRY_ACCOUNT_DEV_URL??'');
const publicKey=process.env.CARRY_ACCOUNT_PUBLISHABLE_KEY??'';
if(base.href!=='https://lbxsvguuoqqpctkinpwy.supabase.co/'||!publicKey.startsWith('sb_publishable_'))throw new Error('explicit_carry_dev_configuration_required');
const anonymous=process.env.CARRY_ACCOUNT_ANON_JWT;
if(anonymous){
  const claims=JSON.parse(Buffer.from(anonymous.split('.')[1],'base64url').toString());
  if(claims.role!=='anon'||claims.ref!==base.hostname.split('.')[0])throw new Error('only_public_anonymous_key_allowed');
}
const probes=[['no_user_bearer',undefined,false],['malformed_bearer','not-a-jwt',false],
  ...(anonymous?[['anonymous_identity',anonymous,true]]:[])];
for(const [check,bearer,handler] of probes){
  const response=await fetch(new URL('/functions/v1/carry-data',base),{
    method:'POST',headers:{apikey:publicKey,'Content-Type':'application/json',...(bearer?{Authorization:`Bearer ${bearer}`}:{})},
    body:JSON.stringify({action:'pull',cursor:0}),redirect:'error',signal:AbortSignal.timeout(20000),
  });
  const result=await response.json();const denied=response.status===401&&(!handler||result.error==='unauthorized');
  console.log(JSON.stringify({check,status:response.status,denied,handlerVerified:handler&&denied}));
  if(!denied)throw new Error('edge_authentication_probe_failed');
}
