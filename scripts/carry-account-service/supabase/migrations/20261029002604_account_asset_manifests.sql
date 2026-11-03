-- Private reservation/verification ledger. This migration grants no Storage
-- access and creates no bucket. An upload-session ledger/broker, physical
-- cleanup and graph publication must be connected before enabling accounts.
-- Per-object reservations alone do NOT bound duplicate/orphaned TUS sessions.
create table carry_private.asset_budgets (
  account_id uuid primary key references auth.users(id) on delete cascade,
  maximum_bytes bigint not null check (maximum_bytes >= 52428800),
  maximum_pending integer not null check (maximum_pending between 1 and 100)
);
create table carry_private.assets (
  account_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null, entity_id uuid not null, entity_kind text not null,
  slot text not null, sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  byte_count bigint not null check (byte_count between 1 and 52428800),
  content_type text not null,
  state text not null check (state in ('pending', 'verified', 'deleting')),
  reserved_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null,
  verified_at timestamptz,
  primary key (account_id, id),
  unique (account_id, entity_id, slot, sha256)
);
create index assets_cleanup on carry_private.assets(state, expires_at);
alter table carry_private.asset_budgets enable row level security;
alter table carry_private.assets enable row level security;
revoke all on carry_private.asset_budgets, carry_private.assets from public, anon, authenticated;
grant select, insert, update, delete on carry_private.asset_budgets, carry_private.assets to service_role;

create function carry_private.asset_identity(p_account uuid, p_entity uuid, p_slot text, p_sha256 text)
returns uuid language sql immutable security invoker set search_path = '' as $$
  select substr(encode(sha256(convert_to(p_account::text || '/' || p_entity::text || '/' || p_slot || '/' || p_sha256, 'UTF8')), 'hex'),1,32)::uuid;
$$;
revoke all on function carry_private.asset_identity(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function carry_private.asset_identity(uuid,uuid,text,text) to service_role;

create function public.carry_asset_reserve(p_account uuid, p_session uuid, p_asset jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  asset_id uuid; entity_id uuid; kind text; slot_name text; sha text; bytes bigint; mime text;
  existing carry_private.assets; budget carry_private.asset_budgets;
  charged bigint; pending_count integer;
begin
  -- Same account lock as graph writes and account deletion. Recheck identity
  -- AFTER acquiring it so a request waiting on deletion cannot start an upload.
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  if p_asset is null or jsonb_typeof(p_asset) <> 'object'
     or (select count(*) from jsonb_object_keys(p_asset)) <> 7
     or not (p_asset ?& array['id','entityID','entityKind','slot','sha256','byteCount','contentType'])
     or exists(select 1 from jsonb_each(p_asset) where key <> 'byteCount' and jsonb_typeof(value) <> 'string')
     or jsonb_typeof(p_asset->'byteCount') <> 'number'
     or (p_asset->>'byteCount') !~ '^[0-9]+$'
  then raise exception 'invalid_asset'; end if;
  asset_id := (p_asset->>'id')::uuid; entity_id := (p_asset->>'entityID')::uuid;
  kind := p_asset->>'entityKind'; slot_name := p_asset->>'slot'; sha := p_asset->>'sha256';
  bytes := (p_asset->>'byteCount')::bigint; mime := p_asset->>'contentType';
  if bytes not between 1 and 52428800 or sha !~ '^[0-9a-f]{64}$'
     or length(mime) > 200 or mime !~ '^[A-Za-z0-9.+_-]+/[A-Za-z0-9.+_-]+$'
     or not ((kind='photo' and slot_name in ('thumbnail','original'))
       or (kind='attachment' and slot_name in ('thumbnail','file'))
       or (kind='libraryItem' and slot_name='image')
       or (kind='trip' and slot_name like 'background:%' and octet_length(substr(slot_name,12)) between 1 and 255
           and substr(slot_name,12) not in ('.','..') and substr(slot_name,12) !~ '[/\\]'))
     or asset_id <> carry_private.asset_identity(p_account,entity_id,slot_name,sha)
  then raise exception 'invalid_asset'; end if;
  select * into existing from carry_private.assets where account_id=p_account and id=asset_id;
  if found then
    if existing.entity_id <> entity_id or existing.entity_kind <> kind or existing.slot <> slot_name
       or existing.sha256 <> sha or existing.byte_count <> bytes or existing.content_type <> mime
    then raise exception 'asset_identity_mismatch'; end if;
    if existing.state='deleting' then raise exception 'asset_cleanup_pending'; end if;
    if existing.state='pending' then
      update carry_private.assets set expires_at=statement_timestamp()+interval '24 hours'
        where account_id=p_account and id=asset_id;
    end if;
    return jsonb_build_object('id',asset_id,'status',existing.state);
  end if;
  select * into budget from carry_private.asset_budgets where account_id=p_account for update;
  if not found then raise exception 'asset_budget_not_configured'; end if;
  -- Pending or deleting objects consume their worst-case finalized size until
  -- the server verifies bytes or confirms physical removal. Expiry alone MUST
  -- NOT release quota while an interrupted TUS upload can still exist. The
  -- broker must separately charge every uncertain/orphaned creation attempt.
  select coalesce(sum(case when state='verified' then byte_count else 52428800 end),0),
    count(*) filter(where state <> 'verified') into charged,pending_count
    from carry_private.assets where account_id=p_account;
  if charged+52428800 > budget.maximum_bytes or pending_count >= budget.maximum_pending
  then raise exception 'asset_budget_exceeded'; end if;
  insert into carry_private.assets(account_id,id,entity_id,entity_kind,slot,sha256,byte_count,content_type,state,expires_at)
    values(p_account,asset_id,entity_id,kind,slot_name,sha,bytes,mime,'pending',statement_timestamp()+interval '24 hours');
  return jsonb_build_object('id',asset_id,'status','pending');
end;
$$;
revoke all on function public.carry_asset_reserve(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.carry_asset_reserve(uuid,uuid,jsonb) to service_role;

-- Only trusted service-side byte inspection may supply these measurements.
-- No HTTP route may pass a client's reported digest/size into this function.
create function public.carry_asset_confirm(p_account uuid,p_session uuid,p_id uuid,p_sha256 text,p_bytes bigint)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare item carry_private.assets;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  select * into item from carry_private.assets where account_id=p_account and id=p_id for update;
  if not found then raise exception 'asset_not_found'; end if;
  if item.state='deleting' then raise exception 'asset_cleanup_pending'; end if;
  if item.state='verified' then
    if p_sha256 is null or p_bytes is null or item.sha256 <> p_sha256 or item.byte_count <> p_bytes
    then raise exception 'asset_verification_mismatch'; end if;
    return jsonb_build_object('id',p_id,'status','verified');
  end if;
  if p_sha256 is null or p_bytes is null or item.sha256 <> p_sha256 or item.byte_count <> p_bytes
     or (item.state='pending' and item.expires_at <= statement_timestamp()) then
    update carry_private.assets set state='deleting' where account_id=p_account and id=p_id;
    return jsonb_build_object('id',p_id,'status','rejected');
  end if;
  update carry_private.assets set state='verified',verified_at=coalesce(verified_at,statement_timestamp())
    where account_id=p_account and id=p_id;
  return jsonb_build_object('id',p_id,'status','verified');
end;
$$;
revoke all on function public.carry_asset_confirm(uuid,uuid,uuid,text,bigint) from public, anon, authenticated;
grant execute on function public.carry_asset_confirm(uuid,uuid,uuid,text,bigint) to service_role;
