#!/usr/bin/env node
// Operator entrypoint: supply the already-authorized server DB URL in the
// environment. Never accept an account ID or print provider errors/credentials.
import pg from 'pg';
import {createDatabasePool} from './database-pool.mjs';
import {evaluateOperationsHealth} from './operations-health.mjs';
const connection=process.env.CARRY_AI_DATABASE_URL;
if(!connection){console.log(JSON.stringify({status:'unavailable',error:'database_configuration_required'}));process.exitCode=2;}
else{
 const pool=createDatabasePool(pg,connection,{onIdleError:()=>{}});
 try{
  const now=Date.now(),snapshot=(await pool.query('select carry_ai.operations_snapshot($1::bigint) as data',[now])).rows[0].data;
  const cron=(await pool.query(`select j.active,
    (select max(end_time) from cron.job_run_details d where d.jobid=j.jobid and d.status='succeeded') as "lastSuccess",
    (select count(*) from cron.job_run_details d where d.jobid=j.jobid and d.status='failed' and d.start_time>now()-interval '1 day') as "failuresLastDay"
    from cron.job j where j.jobname='carry-ai-retention'`)).rows[0];
  const result=evaluateOperationsHealth(snapshot,cron,{now});console.log(JSON.stringify(result));process.exitCode=result.status==='ok'?0:1;
 }catch{console.log(JSON.stringify({status:'unavailable',error:'operations_read_failed'}));process.exitCode=2;}
 finally{await pool.end();}
}
