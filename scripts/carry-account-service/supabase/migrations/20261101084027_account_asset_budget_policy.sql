-- Operator-controlled admission, closed by default. Budgets reserve physical
-- capacity, including the existing 50 MiB worst-case upload-attempt charge.
-- This is resource policy, not a price/plan decision and not client writable.
create table carry_private.asset_budget_policy (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  per_account_bytes bigint not null default 0 check (per_account_bytes between 0 and 9007199254740991),
  maximum_pending integer not null default 0 check (maximum_pending between 0 and 100),
  total_allocated_bytes bigint not null default 0 check (total_allocated_bytes between 0 and 9007199254740991),
  check (not enabled or (per_account_bytes>=52428800 and maximum_pending>=1 and total_allocated_bytes>=per_account_bytes))
);
insert into carry_private.asset_budget_policy(singleton) values(true);
alter table carry_private.asset_budget_policy enable row level security;
revoke all on carry_private.asset_budget_policy from public,anon,authenticated;
grant select,update on carry_private.asset_budget_policy to service_role;

-- Acquire the shared gate before any budget row locks, including bulk operator
-- updates and account-purge DELETEs. A row trigger alone reverses lock order.
create function carry_private.asset_budget_write_lock()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  perform 1 from carry_private.asset_budget_policy where singleton for update;
  if not found then raise exception 'asset_budget_policy_missing'; end if;
  return null;
end;
$$;
revoke all on function carry_private.asset_budget_write_lock() from public,anon,authenticated;
grant execute on function carry_private.asset_budget_write_lock() to service_role;
create trigger asset_budget_write_lock before insert or update or delete on carry_private.asset_budgets
for each statement execute function carry_private.asset_budget_write_lock();

-- Serializes automatic and manual increases against the same physical pool.
-- Existing assignments count in full; lowering a pool freezes new admission
-- without invalidating already assigned accounts or silently shrinking them.
create function carry_private.asset_budget_guard()
returns trigger language plpgsql security invoker set search_path='' as $$
declare policy carry_private.asset_budget_policy; allocated numeric; usage record; increase boolean;
begin
  select * into policy from carry_private.asset_budget_policy where singleton;
  if TG_OP='DELETE' then
    if exists(select 1 from carry_private.assets where account_id=OLD.account_id)
      or exists(select 1 from carry_private.asset_upload_attempts where account_id=OLD.account_id)
    then raise exception 'asset_budget_cleanup_pending'; end if;
    return OLD;
  end if;
  if TG_OP='UPDATE' then
    if NEW.account_id<>OLD.account_id then raise exception 'asset_budget_identity_immutable'; end if;
    increase:=NEW.maximum_bytes>OLD.maximum_bytes;
  else increase:=true; end if;
  select * into usage from carry_private.asset_usage(NEW.account_id);
  if NEW.maximum_bytes<usage.charged_bytes then raise exception 'asset_budget_below_usage'; end if;
  if policy.enabled and increase then
    select coalesce(sum(maximum_bytes),0) into allocated from carry_private.asset_budgets where account_id<>NEW.account_id;
    if allocated+NEW.maximum_bytes>policy.total_allocated_bytes then raise exception 'asset_budget_pool_exhausted'; end if;
  end if;
  return NEW;
end;
$$;
revoke all on function carry_private.asset_budget_guard() from public,anon,authenticated;
grant execute on function carry_private.asset_budget_guard() to service_role;
create trigger asset_budget_guard before insert or update or delete on carry_private.asset_budgets
for each row execute function carry_private.asset_budget_guard();

create function carry_private.ensure_asset_budget(p_account uuid,p_session uuid)
returns void language plpgsql security invoker set search_path='' as $$
declare policy carry_private.asset_budget_policy; allocated numeric;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  if exists(select 1 from carry_private.asset_budgets where account_id=p_account) then return; end if;
  select * into policy from carry_private.asset_budget_policy where singleton for update;
  if not found or not policy.enabled then raise exception 'asset_budget_not_configured'; end if;
  -- Recheck after the global admission lock, including native-session status.
  perform carry_private.graph_require_session(p_account,p_session);
  if exists(select 1 from carry_private.asset_budgets where account_id=p_account) then return; end if;
  select coalesce(sum(maximum_bytes),0) into allocated from carry_private.asset_budgets;
  if allocated+policy.per_account_bytes>policy.total_allocated_bytes then raise exception 'asset_budget_pool_exhausted'; end if;
  insert into carry_private.asset_budgets(account_id,maximum_bytes,maximum_pending)
    values(p_account,policy.per_account_bytes,policy.maximum_pending);
end;
$$;
revoke all on function carry_private.ensure_asset_budget(uuid,uuid) from public,anon,authenticated;
grant execute on function carry_private.ensure_asset_budget(uuid,uuid) to service_role;

-- Keep the reviewed manifest/identity/attempt accounting core intact. Admission
-- occurs only after a valid request reaches its precise missing-budget guard;
-- malformed input, sign-in and account enrollment never allocate capacity.
alter function public.carry_asset_reserve(uuid,uuid,jsonb) set schema carry_private;
alter function carry_private.carry_asset_reserve(uuid,uuid,jsonb) rename to asset_reserve_core;
revoke all on function carry_private.asset_reserve_core(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function carry_private.asset_reserve_core(uuid,uuid,jsonb) to service_role;
create function public.carry_asset_reserve(p_account uuid,p_session uuid,p_asset jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  begin
    return carry_private.asset_reserve_core(p_account,p_session,p_asset);
  exception when raise_exception then
    if sqlerrm<>'asset_budget_not_configured' then raise; end if;
  end;
  perform carry_private.ensure_asset_budget(p_account,p_session);
  return carry_private.asset_reserve_core(p_account,p_session,p_asset);
end;
$$;
revoke all on function public.carry_asset_reserve(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.carry_asset_reserve(uuid,uuid,jsonb) to service_role;
