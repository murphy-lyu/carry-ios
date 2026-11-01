import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { applyPortableMigrations } from './migration-fixture.mjs';
const unit=50*1024*1024;
const first=randomUUID(),second=randomUUID(),third=randomUUID();
const sessions=new Map([[first,randomUUID()],[second,randomUUID()],[third,randomUUID()]]);
async function fixture() {
  const db=new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create table auth.users(id uuid primary key);
    create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);`);
  for(const [id,session] of sessions) {
    await db.query('insert into auth.users values($1)',[id]);
    await db.query('insert into auth.sessions values($1,$2,null,null)',[session,id]);
  }
  await applyPortableMigrations(db);
  await db.exec('set role service_role');
  for(const id of sessions.keys()) await db.query('select public.carry_account_enroll($1,$2,$3,$4)',[id,'synthetic-'+id,'app.nevestudio.carry','synthetic-only']);
  return db;
}
function asset(owner) {
  const entityID=randomUUID(),sha256=createHash('sha256').update('budget-synthetic-only').digest('hex');
  const hex=createHash('sha256').update(`${owner}/${entityID}/file/${sha256}`).digest('hex').slice(0,32);
  const id=[hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
  return {id,entityID,entityKind:'attachment',slot:'file',sha256,byteCount:7,contentType:'application/octet-stream'};
}
const reserve=(db,owner,item=asset(owner),session=sessions.get(owner))=>db.query('select public.carry_asset_reserve($1,$2,$3) as result',[owner,session,item]);
const policy=(db,{enabled=true,bytes=2*unit,pending=2,total=4*unit}={})=>db.query('update carry_private.asset_budget_policy set enabled=$1,per_account_bytes=$2,maximum_pending=$3,total_allocated_bytes=$4 where singleton',[enabled,bytes,pending,total]);
const budgetCount=async db=>(await db.query('select count(*) from carry_private.asset_budgets')).rows[0].count;

test('default policy stays closed; enrollment and invalid/native-mismatched requests never allocate',async()=>{
  const db=await fixture();try {
    assert.equal(await budgetCount(db),0);
    await assert.rejects(reserve(db,first),/asset_budget_not_configured/);
    assert.equal(await budgetCount(db),0);
    await policy(db);
    await assert.rejects(reserve(db,first,{...asset(first),byteCount:0}),/invalid_asset/);
    await assert.rejects(reserve(db,first,asset(first),sessions.get(second)),/session_expired/);
    assert.equal(await budgetCount(db),0);
    const item=asset(first);await reserve(db,first,item);await reserve(db,first,item);
    const rows=(await db.query('select maximum_bytes,maximum_pending from carry_private.asset_budgets')).rows;
    assert.deepEqual(rows,[{maximum_bytes:2*unit,maximum_pending:2}]);
    assert.equal((await db.query('select count(*) from carry_private.assets')).rows[0].count,1);
  }finally{await db.close();}
});

test('project cap counts previous manual budgets and freezes admission without revoking existing assignments',async()=>{
  const db=await fixture();try {
    await db.query('insert into carry_private.asset_budgets values($1,$2,3)',[first,3*unit]);
    await policy(db,{bytes:unit,pending:1,total:2*unit});
    await reserve(db,first);
    await assert.rejects(reserve(db,second),/asset_budget_pool_exhausted/);
    assert.equal(await budgetCount(db),1);
    assert.deepEqual((await db.query('select maximum_bytes,maximum_pending from carry_private.asset_budgets')).rows,[{maximum_bytes:3*unit,maximum_pending:3}]);
    await db.query('update carry_private.asset_budgets set maximum_pending=2 where account_id=$1',[first]);
    await assert.rejects(db.query('update carry_private.asset_budgets set maximum_bytes=$1 where account_id=$2',[4*unit,first]),/asset_budget_pool_exhausted/);
    await policy(db,{bytes:unit,pending:1,total:4*unit});
    await reserve(db,second);
    assert.equal((await db.query('select sum(maximum_bytes)::bigint as total from carry_private.asset_budgets')).rows[0].total,4*unit);
    await assert.rejects(reserve(db,third),/asset_budget_pool_exhausted/);
  }finally{await db.close();}
});

test('disabling automatic admission preserves existing budgets and blocks new allocations',async()=>{
  const db=await fixture();try {
    await policy(db);await reserve(db,first);
    await policy(db,{enabled:false});await reserve(db,first);
    await assert.rejects(reserve(db,second),/asset_budget_not_configured/);
    assert.equal(await budgetCount(db),1);
  }finally{await db.close();}
});

test('same-account retries are unique and competing requests cannot over-allocate the bounded pool',async()=>{
  const db=await fixture();try {
    await policy(db,{bytes:unit,pending:1,total:unit});
    const item=asset(first);
    const repeated=await Promise.all([reserve(db,first,item),reserve(db,first,item)]);
    assert.equal(repeated.length,2);assert.equal(await budgetCount(db),1);
    const results=await Promise.allSettled([reserve(db,second),reserve(db,third)]);
    assert.ok(results.every(r=>r.status==='rejected'&&/asset_budget_pool_exhausted/.test(r.reason.message)));
    assert.equal(await budgetCount(db),1);
    // PGlite serializes its connection. Check the shared global row lock in
    // both SQL paths too; live multi-session contention remains a hosted gate.
    for(const fn of ['ensure_asset_budget','asset_budget_write_lock']) {
      const source=(await db.query('select prosrc from pg_proc where pronamespace=\'carry_private\'::regnamespace and proname=$1',[fn])).rows[0].prosrc;
      assert.match(source,/asset_budget_policy where singleton for update/);
    }
  }finally{await db.close();}
});

test('manual budget changes cannot reassign ownership, hide active bytes or release physical capacity early',async()=>{
  const db=await fixture();try {
    await policy(db,{bytes:3*unit,pending:3,total:6*unit});
    await reserve(db,first);await reserve(db,first);
    await assert.rejects(db.query('update carry_private.asset_budgets set maximum_bytes=$1 where account_id=$2',[unit,first]),/asset_budget_below_usage/);
    await assert.rejects(db.query('delete from carry_private.asset_budgets where account_id=$1',[first]),/asset_budget_cleanup_pending/);
    await assert.rejects(db.query('update carry_private.asset_budgets set account_id=$1 where account_id=$2',[second,first]),/asset_budget_identity_immutable/);
    assert.equal(await budgetCount(db),1);
  }finally{await db.close();}
});

test('policy and allocation helpers are private, invoker-only and invalid settings fail closed',async()=>{
  const db=await fixture();try {
    for(const options of [{bytes:unit-1},{pending:0},{total:unit,bytes:2*unit}]) await assert.rejects(policy(db,options),/check constraint/);
    const functions=(await db.query("select proname,prosecdef,has_function_privilege('anon',oid,'execute') as anon,has_function_privilege('authenticated',oid,'execute') as authenticated from pg_proc where proname in ('ensure_asset_budget','asset_budget_write_lock','asset_budget_guard','asset_reserve_core','carry_asset_reserve')")).rows;
    assert.equal(functions.length,5);assert.ok(functions.every(r=>!r.prosecdef&&!r.anon&&!r.authenticated));
    await db.exec('reset role;set role authenticated');
    await assert.rejects(db.query('select * from carry_private.asset_budget_policy'),/permission denied/);
    await assert.rejects(db.query('update carry_private.asset_budget_policy set enabled=true'),/permission denied/);
  }finally{await db.close();}
});
