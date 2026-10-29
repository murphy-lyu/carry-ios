-- Cleanup-only capability. Plaintext is provisioned in Vault, never in a client.
create table carry_private.asset_cleanup_dispatch (
  singleton boolean primary key default true check(singleton),
  token_hash text not null check(token_hash ~ '^[0-9a-f]{64}$'),
  lease_until timestamptz not null default '-infinity'
);
alter table carry_private.asset_cleanup_dispatch enable row level security;
revoke all on carry_private.asset_cleanup_dispatch from public,anon,authenticated;
grant select,update on carry_private.asset_cleanup_dispatch to service_role;

-- Round-robin accounts so a permanently failing provider object cannot starve
-- another account's cleanup behind the oldest reservation.
create table carry_private.asset_cleanup_turns (
  account_id uuid primary key references auth.users(id) on delete cascade,
  dispatched_at timestamptz not null
);
alter table carry_private.asset_cleanup_turns enable row level security;
revoke all on carry_private.asset_cleanup_turns from public,anon,authenticated;
grant select,insert,update,delete on carry_private.asset_cleanup_turns to service_role;

create function carry_private.asset_cleanup_candidates()
returns table(account_id uuid, oldest timestamptz)
language sql stable security invoker set search_path='' as $$
  select f.account_id,min(f.reserved_at) from carry_private.assets f
  where exists(select 1 from carry_private.carry_apple_credentials c where c.account_id=f.account_id and c.status='deleting')
    or f.state='deleting' or (f.state='pending' and f.expires_at<=statement_timestamp())
    or exists(select 1 from carry_private.asset_upload_attempts a where a.account_id=f.account_id and a.asset_id=f.id
      and (a.state in ('uncertain','deleting') or (a.state='creating' and a.lease_until<=statement_timestamp())))
  group by f.account_id
$$;
revoke all on function carry_private.asset_cleanup_candidates() from public,anon,authenticated;
grant execute on function carry_private.asset_cleanup_candidates() to service_role;

create function public.carry_asset_cleanup_accounts(p_token text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare config carry_private.asset_cleanup_dispatch; result jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='28000',message='invalid_cleanup_capability';
  end if;
  select * into config from carry_private.asset_cleanup_dispatch where singleton for update;
  if not found or config.token_hash<>encode(sha256(convert_to(p_token,'UTF8')),'hex') then
    raise exception using errcode='28000',message='invalid_cleanup_capability';
  end if;
  if config.lease_until>statement_timestamp() then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(account_id),'[]'::jsonb) into result from (
    select c.account_id from carry_private.asset_cleanup_candidates() c
      left join carry_private.asset_cleanup_turns t on t.account_id=c.account_id
      order by t.dispatched_at nulls first,c.oldest,c.account_id limit 2
  ) candidates;
  insert into carry_private.asset_cleanup_turns(account_id,dispatched_at)
    select value::uuid,statement_timestamp() from jsonb_array_elements_text(result)
    on conflict(account_id) do update set dispatched_at=excluded.dispatched_at;
  update carry_private.asset_cleanup_dispatch set lease_until=statement_timestamp()+interval '120 seconds' where singleton;
  return result;
end;
$$;
revoke all on function public.carry_asset_cleanup_accounts(text) from public,anon,authenticated;
grant execute on function public.carry_asset_cleanup_accounts(text) to service_role;

-- Expired reservations with no upload attempt need no network deletion.
create function public.carry_asset_cleanup_empty(p_account uuid)
returns void language plpgsql security invoker set search_path='' as $$
begin
  if p_account is null then raise exception 'invalid_cleanup_account'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  delete from carry_private.assets f where f.account_id=p_account
    and (f.state='deleting' or (f.state='pending' and f.expires_at<=statement_timestamp())
      or exists(select 1 from carry_private.carry_apple_credentials c where c.account_id=p_account and c.status='deleting'))
    and not exists(select 1 from carry_private.asset_upload_attempts a where a.account_id=f.account_id and a.asset_id=f.id)
    and not exists(select 1 from storage.objects o where o.bucket_id='carry-account-assets'
      and o.name collate "C"=p_account::text||'/'||f.id::text||'/'||f.sha256);
end;
$$;
revoke all on function public.carry_asset_cleanup_empty(uuid) from public,anon,authenticated;
grant execute on function public.carry_asset_cleanup_empty(uuid) to service_role;
