// Transport boundary for the server-owned account graph. This is NOT an AI
// bearer endpoint: scoped AI grants must resolve through their own policy layer.
export class GraphRequestError extends Error {
  constructor(status, code, conflict) { super(code); this.status=status; this.code=code; this.conflict=conflict; }
}
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUUID = value => typeof value==='string' && UUID.test(value);
export async function boundedJSON(request, maximum=2097152) {
  if (request.headers.get('content-type')?.split(';')[0].trim()!=='application/json') throw new GraphRequestError(415,'json_required');
  if (Number(request.headers.get('content-length'))>maximum) throw new GraphRequestError(413,'body_too_large');
  const reader=request.body?.getReader(); if (!reader) throw new GraphRequestError(400,'invalid_request');
  const chunks=[];let size=0;
  while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;
    if(size>maximum){await reader.cancel();throw new GraphRequestError(413,'body_too_large');}chunks.push(value);}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{throw new GraphRequestError(400,'invalid_request');}
}

export function createGraphHandler({authenticate,apply,pull,rateLimit}) {
  return async request => {
    const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
    try{
      if(request.method!=='POST')throw new GraphRequestError(405,'method_not_allowed');
      const token=request.headers.get('authorization')?.match(/^Bearer ([^\s]+)$/)?.[1];
      if(!token || token.length>16000)throw new GraphRequestError(401,'unauthorized');
      const identity=await authenticate(token);
      if(!isUUID(identity?.accountID)||!isUUID(identity?.sessionID))throw new GraphRequestError(401,'unauthorized');
      if(!await rateLimit(identity))throw new GraphRequestError(429,'rate_limited');
      const body=await boundedJSON(request);
      if(!body||Array.isArray(body)||typeof body!=='object')throw new GraphRequestError(400,'invalid_request');
      if(body.action==='apply'){
        if(Object.keys(body).some(k=>!['action','command'].includes(k))||!body.command||typeof body.command!=='object'||Array.isArray(body.command)||
          !isUUID(body.command.requestID)||!Array.isArray(body.command.mutations)||body.command.mutations.length<1||body.command.mutations.length>500)
          throw new GraphRequestError(400,'invalid_request');
        return reply(await apply(identity,body.command));
      }
      if(body.action==='pull'){
        if(Object.keys(body).some(k=>!['action','cursor','limit'].includes(k))||!Number.isSafeInteger(body.cursor)||body.cursor<0||
          (body.limit!==undefined&&(!Number.isInteger(body.limit)||body.limit<1||body.limit>500)))throw new GraphRequestError(400,'invalid_request');
        return reply(await pull(identity,body.cursor,body.limit??100));
      }
      throw new GraphRequestError(400,'invalid_request');
    }catch(error){
      if(error instanceof GraphRequestError)return reply({error:error.code,...(error.conflict?{conflict:error.conflict}:{})},error.status);
      // No raw PostgREST errors, SQL text, JWTs or travel content in logs/replies.
      return reply({error:'service_unavailable'},503);
    }
  };
}
