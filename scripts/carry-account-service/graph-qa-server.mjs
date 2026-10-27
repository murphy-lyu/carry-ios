// LOCAL TEST HARNESS ONLY. Fixed synthetic identities are deliberately not real
// authentication. Never bundle this module into a deployed function.
import {createServer} from 'node:http';
import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir} from 'node:fs/promises';
import {graphSchema} from './graph-schema.mjs';
import {createGraphHandler,GraphRequestError} from './graph-http.mjs';
if(process.env.CARRY_GRAPH_QA!=='synthetic-only')throw new Error('explicit_synthetic_qa_required');
const account='00000000-0000-0000-0000-000000000001',session='00000000-0000-0000-0000-000000000003';
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
  create schema auth;create table auth.users(id uuid primary key);
  create table auth.sessions(id uuid primary key,user_id uuid,not_after timestamptz,oauth_client_id uuid);
  insert into auth.users values('${account}');insert into auth.sessions values('${session}','${account}',null,null);`);
const directory=new URL('./supabase/migrations/',import.meta.url);
for(const name of (await readdir(directory)).filter(n=>n.endsWith('.sql')).sort())await db.exec(await readFile(new URL(name,directory),'utf8'));
await db.exec('set role service_role');
await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[account,'synthetic-subject','app.nevestudio.carry','synthetic-encrypted']);
async function rpc(name,args){try{
  const placeholders=args.map((_,i)=>'$'+(i+1)).join(',');
  return(await db.query(`select public.${name}(${placeholders}) as result`,args)).rows[0].result;
}catch(error){
  if(error.code==='P0001')throw new GraphRequestError(409,error.message,JSON.parse(error.detail));
  if(error.code==='22023')throw new GraphRequestError(422,error.message);
  if(error.code==='28000')throw new GraphRequestError(401,'session_expired');
  throw error;
}}
const handler=createGraphHandler({
  authenticate:async bearer=>bearer==='synthetic-native-qa'?{accountID:account,sessionID:session}:null,
  rateLimit:async()=>true,
  apply:(identity,command)=>rpc('carry_graph_apply',[identity.accountID,identity.sessionID,command]),
  pull:(identity,cursor,limit)=>rpc('carry_graph_pull',[identity.accountID,identity.sessionID,cursor,limit]),
});
const fixture=Object.fromEntries(Object.entries(graphSchema.trip.fields).filter(([,rule])=>!rule.optional).map(([key,rule])=>[key,
  rule.type==='string'?(rule.format==='date-time'?'2026-11-01T00:00:00Z':''):rule.type==='number'?Math.max(0,rule.min):rule.type==='array'?[]:false]));
fixture.name='Synthetic native HTTP QA';fixture.days=3;
const server=createServer(async(incoming,outgoing)=>{
  try{
    if(incoming.url==='/__fixture'){outgoing.writeHead(200,{'content-type':'application/json','cache-control':'no-store'});outgoing.end(JSON.stringify({accountID:account,fields:fixture}));return;}
    if(incoming.url!=='/functions/v1/carry-data'){outgoing.writeHead(404);outgoing.end();return;}
    const request=new Request('http://127.0.0.1:8891'+incoming.url,{method:incoming.method,headers:incoming.headers,
      ...(incoming.method==='POST'?{body:incoming,duplex:'half'}:{})});
    const response=await handler(request);outgoing.writeHead(response.status,Object.fromEntries(response.headers));outgoing.end(Buffer.from(await response.arrayBuffer()));
  }catch{outgoing.writeHead(503);outgoing.end('{"error":"qa_unavailable"}');}
});
server.listen(8891,'127.0.0.1',()=>process.stdout.write('Synthetic-only graph QA ready on 127.0.0.1:8891\n'));
async function stop(){await new Promise(resolve=>server.close(resolve));await db.close();process.exit(0);}
process.on('SIGINT',stop);process.on('SIGTERM',stop);
