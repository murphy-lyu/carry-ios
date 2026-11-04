import {test} from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {fixture,account,session,ticket,subject,audience} from './deletion-recovery-fixture.mjs';
const url=process.env.CARRY_QA_POSTGRES_URL;
async function realFixture(){
 const target=new URL(url);
 if(target.hostname!=='127.0.0.1'||target.pathname!=='/postgres')throw Error('local_synthetic_postgres_only');
 const admin=new pg.Pool({connectionString:target.href,max:1});
 const name='carry_qa_recovery_'+crypto.randomUUID().replaceAll('-','');await admin.query('create database '+name);target.pathname='/'+name;
 const pool=new pg.Pool({connectionString:target.href,max:6}),ended=[];
 pool.on('connect',client=>ended.push(new Promise(resolve=>client.once('end',resolve))));
 const closePool=async()=>{await pool.end();await Promise.all(ended);};
 const bootstrap=await pool.connect();
 try{
  const f=await fixture({files:true,database:{query:(...x)=>bootstrap.query(...x),exec:x=>bootstrap.query(x)}});
  await bootstrap.query('reset role');bootstrap.release();
  const rpc=async(name,args)=>{const c=await pool.connect();try{await c.query('begin');await c.query('set local role service_role');await c.query("set local statement_timeout='5s'");
    const result=(await c.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args.map(v=>Array.isArray(v)?JSON.stringify(v):v))).rows[0].result;
    await c.query('commit');return result;
   }catch(e){await c.query('rollback');throw e;}finally{c.release();}};
  return{pool,f,rpc,prepare:op=>rpc('carry_account_recovery_prepare',[account,session,ticket,subject,audience,op]),
   commit:p=>rpc('carry_account_recovery_commit',[account,session,ticket,subject,audience,'fresh-encrypted-token',p.operationID,p.fingerprints,p.assets]),
   async close(){await closePool();await admin.query('drop database '+name);await admin.end();}};
 }catch(e){bootstrap.release();await closePool();await admin.query('drop database '+name);await admin.end();throw e;}
}

test('real PostgreSQL independent recovery preparations admit only one fenced operation',{skip:!url},async()=>{
 const f=await realFixture();try{
  const results=await Promise.allSettled([f.prepare(crypto.randomUUID()),f.prepare(crypto.randomUUID())]);
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);assert.match(results.find(r=>r.status==='rejected').reason.message,/recovery_not_ready/);
  const p=results.find(r=>r.status==='fulfilled').value;assert.deepEqual(await f.commit(p),{status:'cancelled'});
 }finally{await f.close();}
});

test('real PostgreSQL recovery races safely with stale asset cleanup completion',{skip:!url},async()=>{
 const f=await realFixture();try{
  const old=(await f.pool.query('select id,operation_id from carry_private.asset_upload_attempts')).rows[0];
  const oldSession=crypto.randomUUID();await f.pool.query('insert into auth.sessions(id,user_id) values($1,$2)',[oldSession,account]);
  const p=await f.prepare(crypto.randomUUID());
  const result=await Promise.allSettled([f.commit(p),f.rpc('carry_asset_cleanup_finish',[account,old.id,old.operation_id])]);
  assert.equal(result[0].status,'fulfilled');assert.equal(result[1].status,'rejected');assert.match(result[1].reason.message,/cleanup_operation_superseded/);
  await assert.rejects(f.rpc('carry_account_require_session',[account,oldSession]),/session_expired/);
  await assert.rejects(f.rpc('carry_graph_pull',[account,oldSession,0,10]),/session_expired/);
  await f.rpc('carry_account_require_session',[account,session]);
  assert.deepEqual(await f.rpc('carry_account_deletion_status',[ticket]),{status:'cancelled'});
  assert.equal((await f.pool.query('select state from carry_private.assets')).rows[0].state,'verified');
  assert.equal(Number((await f.pool.query('select count(*) from storage.objects')).rows[0].count),1);
 }finally{await f.close();}
});
