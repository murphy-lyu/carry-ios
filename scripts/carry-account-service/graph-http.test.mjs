import {test} from 'node:test';
import assert from 'node:assert/strict';
import * as jose from 'jose';
import {createGraphHandler} from './graph-http.mjs';
import {createGraphAdapter} from './graph-adapter.mjs';
const account='00000000-0000-0000-0000-000000000001',session='00000000-0000-0000-0000-000000000002';
const identity={accountID:account,sessionID:session};
function handler(overrides={}){return createGraphHandler({authenticate:async()=>identity,rateLimit:async()=>true,
  apply:async(i,c)=>({identity:i,command:c}),pull:async(i,c,l)=>({identity:i,cursor:c,limit:l}),...overrides});}
function request(body,options={}){return new Request('https://test.invalid/functions/v1/carry-data',{
  method:'POST',headers:{authorization:'Bearer synthetic','content-type':'application/json',...options.headers},body:JSON.stringify(body),...options});}
const projectURL='https://graph-qa.invalid';
const token=claims=>`${btoa(JSON.stringify({alg:'HS256'}))}.${btoa(JSON.stringify({sub:account,session_id:session,iss:projectURL+'/auth/v1',exp:Math.floor(Date.now()/1000)+3600,...claims}))}.synthetic`;
const user={id:account,identities:[{provider:'apple'}]};
const adapter=(fetcher)=>createGraphAdapter({configuration:{projectURL,serviceKey:'server-only-synthetic'},jose,fetcher});

test('HTTP binds identity only to verified bearer, rejects caller-supplied ownership',async()=>{
  const h=handler();const valid=await h(request({action:'apply',command:{requestID:account,mutations:[{}]}}));
  assert.equal(valid.status,200);assert.deepEqual((await valid.json()).identity,identity);
  for(const field of ['owner','accountID','sessionID','grant'])assert.equal((await h(request({action:'pull',cursor:0,[field]:account}))).status,400);
});
test('HTTP bounds bytes while streaming without trusting Content-Length',async()=>{
  const h=handler();const bytes=new TextEncoder().encode('x'.repeat(2097153));
  const body=new ReadableStream({start(c){c.enqueue(bytes);c.close();}});
  const response=await h(new Request('https://test.invalid',{method:'POST',headers:{authorization:'Bearer synthetic','content-type':'application/json'},body,duplex:'half'}));
  assert.equal(response.status,413);assert.deepEqual(await response.json(),{error:'body_too_large'});
});
test('HTTP cancellation interrupts a stalled body read and releases its reader',async()=>{
  const abort=new AbortController();let cancelled=false;
  const body=new ReadableStream({pull(){queueMicrotask(()=>abort.abort());return new Promise(()=>{});},cancel(){cancelled=true;}},{highWaterMark:0});
  const response=await handler()(new Request('https://test.invalid',{method:'POST',headers:{authorization:'Bearer synthetic','content-type':'application/json'},body,signal:abort.signal,duplex:'half'}));
  assert.equal(response.status,408);assert.equal(cancelled,true);assert.equal(body.locked,false);
});
test('HTTP rejects invalid cursor, content, absent identity and exhausted budget',async()=>{
  const h=handler();for(const cursor of [-1,0.5,'0',null])assert.equal((await h(request({action:'pull',cursor}))).status,400);
  assert.equal((await h(request({action:'pull',cursor:0,limit:501}))).status,400);
  assert.equal((await h(request({}, {headers:{'content-type':'text/plain',authorization:'Bearer synthetic'}}))).status,415);
  assert.equal((await handler({authenticate:async()=>null})(request({}))).status,401);
  assert.equal((await handler({rateLimit:async()=>false})(request({}))).status,429);
  const failed=await handler({apply:async()=>{throw new Error('sensitive SQL and trip content');}})(request({action:'apply',command:{requestID:account,mutations:[{}]}}));
  assert.equal(failed.status,503);assert.deepEqual(await failed.json(),{error:'service_unavailable'});
});
test('adapter verifies user before parsing session claims and rejects subject/issuer/expiry mismatch',async()=>{
  let calls=[];const a=adapter(async(url,options)=>{calls.push({url:String(url),options});return Response.json(user);});
  assert.deepEqual(await a.authenticate(token({})),identity);assert.equal(calls[0].url,projectURL+'/auth/v1/user');
  for(const claims of [{sub:session},{iss:'https://attacker.invalid/auth/v1'},{exp:0},{session_id:'bad'},{client_id:'synthetic-mcp-client'}])await assert.rejects(a.authenticate(token(claims)),e=>e.code==='unauthorized');
  await assert.rejects(adapter(async()=>Response.json({id:account,identities:[{provider:'email'}]})).authenticate(token({})),e=>e.code==='unauthorized');
});
test('adapter derives RPC identifiers from server identity and never accepts a caller URL',async()=>{
  const calls=[];const a=adapter(async(url,options)=>{calls.push({url:String(url),body:JSON.parse(options.body),options});return Response.json({status:'saved_to_account'});});
  const command={requestID:'example',mutations:[]};await a.apply(identity,command);await a.pull(identity,0,50);
  assert.deepEqual(calls[0].body,{p_account:account,p_session:session,p_command:command});
  assert.equal(calls[0].url,projectURL+'/rest/v1/rpc/carry_graph_apply');assert.equal(calls[0].options.redirect,'error');
  assert.equal(calls[1].body.p_cursor,0);assert.equal(calls[1].body.p_limit,50);
});
test('adapter returns bounded conflict details and hides unexpected backend errors',async()=>{
  const conflict={current:{id:account,fields:{name:'Phone'}},fields:['name'],proposed:{name:'AI'}};
  const a=adapter(async()=>Response.json({code:'P0001',message:'field_conflict',details:JSON.stringify(conflict)},{status:400}));
  await assert.rejects(a.apply(identity,{}),e=>e.status===409&&e.conflict.current.fields.name==='Phone');
  for(const data of [{code:'28000',message:'session_expired'},{code:'22023',message:'trip_date_impact'},{code:'22P02',message:'contains raw UUID'},{code:'42501',message:'database internal secret'}]){
    const a=adapter(async()=>Response.json(data,{status:400}));
    await assert.rejects(a.pull(identity,0,100),e=>e.code!==data.message||['session_expired','trip_date_impact'].includes(e.code));
  }
});
