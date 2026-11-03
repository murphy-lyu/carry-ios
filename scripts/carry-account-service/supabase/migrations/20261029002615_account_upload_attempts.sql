-- Private TUS attempt records. Never grant clients direct Storage INSERT.
-- Persist before contacting Storage; uncertain creations remain charged until
-- a trusted cleanup worker confirms removal. Time alone never releases quota.
create table carry_private.asset_upload_attempts (
  account_id uuid not null,
  id uuid not null,
  asset_id uuid not null,
  creation_id uuid not null,
  state text not null check(state in ('creating','active','uncertain','complete','deleting')),
  location text,
  storage_version uuid,
  may_have_bytes boolean not null default false,
  acknowledged_bytes bigint not null default 0 check(acknowledged_bytes >= 0),
  operation_id uuid,
  lease_until timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  primary key(account_id,id),
  foreign key(account_id,asset_id) references carry_private.assets(account_id,id)
);
create unique index asset_upload_one_active on carry_private.asset_upload_attempts(account_id,asset_id)
  where state in ('creating','active');
create index asset_upload_cleanup on carry_private.asset_upload_attempts(state,created_at);
create index asset_upload_asset on carry_private.asset_upload_attempts(account_id,asset_id);
alter table carry_private.assets add column verified_version uuid;
alter table carry_private.asset_upload_attempts enable row level security;
revoke all on carry_private.asset_upload_attempts from public,anon,authenticated;
grant select,insert,update,delete on carry_private.asset_upload_attempts to service_role;

create function carry_private.asset_usage(p_account uuid)
returns table(charged_bytes bigint,pending_units bigint)
language sql stable security invoker set search_path='' as $$
  select
    (select coalesce(sum(case when state='verified' then byte_count else 52428800 end),0)::bigint
       from carry_private.assets where account_id=p_account)
      + (select count(*)*52428800 from carry_private.asset_upload_attempts where account_id=p_account and may_have_bytes
          and (state in ('uncertain','deleting') or (state='creating' and lease_until<=statement_timestamp()))),
    (select count(*) from carry_private.assets where account_id=p_account and state<>'verified')
      + (select count(*) from carry_private.asset_upload_attempts where account_id=p_account
          and (state in ('uncertain','deleting') or (state='creating' and lease_until<=statement_timestamp())));
$$;
revoke all on function carry_private.asset_usage(uuid) from public,anon,authenticated;
grant execute on function carry_private.asset_usage(uuid) to service_role;

create function public.carry_asset_upload_begin(p_account uuid,p_session uuid,p_asset uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item carry_private.assets; attempt carry_private.asset_upload_attempts;
  budget carry_private.asset_budgets; usage record; attempt_id uuid; creation_id uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  select * into item from carry_private.assets where account_id=p_account and id=p_asset;
  if not found then raise exception 'asset_not_found'; end if;
  if item.state='verified' then return jsonb_build_object('status','verified','assetID',p_asset); end if;
  if item.state<>'pending' or item.expires_at<=statement_timestamp() then raise exception 'asset_unavailable'; end if;
  select * into attempt from carry_private.asset_upload_attempts
    where account_id=p_account and asset_id=p_asset and state in ('creating','active');
  if found then
    if attempt.state='active' then return jsonb_build_object('status','active','id',attempt.id); end if;
    if attempt.lease_until>statement_timestamp() then return jsonb_build_object('status','creating','id',attempt.id); end if;
    update carry_private.asset_upload_attempts set state='uncertain',operation_id=null,lease_until=null
      where account_id=p_account and id=attempt.id;
  end if;
  select * into budget from carry_private.asset_budgets where account_id=p_account for update;
  if not found then raise exception 'asset_budget_not_configured'; end if;
  select * into usage from carry_private.asset_usage(p_account);
  if usage.charged_bytes>budget.maximum_bytes or usage.pending_units>budget.maximum_pending
  then raise exception 'asset_budget_exceeded'; end if;
  attempt_id:=gen_random_uuid(); creation_id:=gen_random_uuid();
  insert into carry_private.asset_upload_attempts(account_id,id,asset_id,creation_id,state,lease_until)
    values(p_account,attempt_id,p_asset,creation_id,'creating',statement_timestamp()+interval '120 seconds');
  return jsonb_build_object('status','create','id',attempt_id,'creationID',creation_id,
    'assetID',item.id,'sha256',item.sha256,'byteCount',item.byte_count,'contentType',item.content_type);
end;
$$;

-- Finalization is service-only and intentionally persists even AFTER session
-- revocation/account deletion began: otherwise a late upstream response would
-- lose the actual Storage location needed by cleanup. It grants no user access.
create function public.carry_asset_upload_created(p_account uuid,p_id uuid,p_creation uuid,p_location text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare attempt carry_private.asset_upload_attempts; item carry_private.assets; next_state text;
  encoded text; decoded text; parts text[]; v_storage_version uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  select * into attempt from carry_private.asset_upload_attempts where account_id=p_account and id=p_id for update;
  if not found or p_creation is null or attempt.creation_id<>p_creation then raise exception 'upload_attempt_not_found'; end if;
  if p_location is not null and (length(p_location)>4096 or p_location !~ '^https://[a-z0-9.-]+/storage/v1/upload/resumable/[A-Za-z0-9_=-]+$')
  then raise exception 'invalid_upload_location'; end if;
  if p_location is not null then
    select * into item from carry_private.assets where account_id=p_account and id=attempt.asset_id;
    encoded:=substring(p_location from '/resumable/([^/]+)$');
    decoded:=convert_from(decode(translate(encoded,'-_','+/')||repeat('=',mod(4-mod(length(encoded),4),4)),'base64'),'UTF8');
    parts:=string_to_array(decoded,'/');
    if array_length(parts,1)<>5 or parts[1]<>'carry-account-assets' or parts[2]<>p_account::text
       or parts[3]<>item.id::text or parts[4]<>item.sha256
       or parts[5]!~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then raise exception 'invalid_upload_location'; end if;
    v_storage_version:=parts[5]::uuid;
  end if;
  if attempt.location is not null then
    if attempt.location is distinct from p_location then raise exception 'upload_location_mismatch'; end if;
    return jsonb_build_object('status',attempt.state,'id',attempt.id);
  end if;
  if attempt.state not in ('creating','uncertain','deleting') then raise exception 'upload_attempt_state'; end if;
  if p_location is null then
    next_state:=case when attempt.state='deleting' or exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and status='deleting')
      then 'deleting' else 'uncertain' end;
  elsif attempt.state='deleting' or exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and status='deleting')
    or not exists(select 1 from carry_private.assets where account_id=p_account and id=attempt.asset_id and state='pending')
    or exists(select 1 from carry_private.asset_upload_attempts where account_id=p_account and asset_id=attempt.asset_id and id<>p_id and state in ('creating','active'))
    then next_state:='deleting';
  else next_state:='active'; end if;
  update carry_private.asset_upload_attempts set state=next_state,location=p_location,storage_version=v_storage_version,lease_until=null,operation_id=null
    where account_id=p_account and id=p_id;
  return jsonb_build_object('status',next_state,'id',p_id);
end;
$$;

create function public.carry_asset_upload_claim(p_account uuid,p_session uuid,p_id uuid,p_operation uuid,p_method text,p_offset bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare attempt carry_private.asset_upload_attempts; item carry_private.assets;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  if p_operation is null or p_method is null or p_method not in ('HEAD','PATCH') then raise exception 'invalid_upload_operation'; end if;
  select * into attempt from carry_private.asset_upload_attempts where account_id=p_account and id=p_id for update;
  if not found or attempt.state<>'active' or attempt.location is null then raise exception 'upload_attempt_not_found'; end if;
  select * into item from carry_private.assets where account_id=p_account and id=attempt.asset_id;
  if item.state<>'pending' or item.expires_at<=statement_timestamp() then raise exception 'asset_unavailable'; end if;
  if attempt.operation_id is not null and attempt.lease_until>statement_timestamp() then raise exception 'upload_busy'; end if;
  if p_method='PATCH' and (p_offset is null or p_offset<>attempt.acknowledged_bytes or p_offset>=item.byte_count)
  then raise exception 'upload_offset_mismatch'; end if;
  update carry_private.asset_upload_attempts set operation_id=p_operation,lease_until=statement_timestamp()+interval '120 seconds',
    may_have_bytes=may_have_bytes or p_method='PATCH'
    where account_id=p_account and id=p_id;
  return jsonb_build_object('id',p_id,'location',attempt.location,'assetID',item.id,'sha256',item.sha256,
    'offset',attempt.acknowledged_bytes,'byteCount',item.byte_count,'contentType',item.content_type);
end;
$$;

create function public.carry_asset_upload_finish(p_account uuid,p_id uuid,p_operation uuid,p_offset bigint,p_gone boolean default false)
returns void language plpgsql security invoker set search_path='' as $$
declare attempt carry_private.asset_upload_attempts; item carry_private.assets;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  select * into attempt from carry_private.asset_upload_attempts where account_id=p_account and id=p_id for update;
  if not found or p_operation is null or attempt.operation_id is distinct from p_operation
  then raise exception 'upload_operation_superseded'; end if;
  select * into item from carry_private.assets where account_id=p_account and id=attempt.asset_id;
  if p_offset is not null and (p_offset<attempt.acknowledged_bytes or p_offset>item.byte_count)
  then raise exception 'invalid_upload_offset'; end if;
  update carry_private.asset_upload_attempts set
    acknowledged_bytes=coalesce(p_offset,acknowledged_bytes),operation_id=null,lease_until=null,
    state=case when p_gone is true or item.state='deleting'
      or exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and status='deleting')
      then 'deleting' else state end
    where account_id=p_account and id=p_id;
end;
$$;

revoke all on function public.carry_asset_upload_begin(uuid,uuid,uuid),
  public.carry_asset_upload_created(uuid,uuid,uuid,text),
  public.carry_asset_upload_claim(uuid,uuid,uuid,uuid,text,bigint),
  public.carry_asset_upload_finish(uuid,uuid,uuid,bigint,boolean) from public,anon,authenticated;
grant execute on function public.carry_asset_upload_begin(uuid,uuid,uuid),
  public.carry_asset_upload_created(uuid,uuid,uuid,text),
  public.carry_asset_upload_claim(uuid,uuid,uuid,uuid,text,bigint),
  public.carry_asset_upload_finish(uuid,uuid,uuid,bigint,boolean) to service_role;

create function public.carry_asset_descriptor(p_account uuid,p_session uuid,p_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item carry_private.assets;
begin
  perform carry_private.graph_require_session(p_account,p_session);
  select * into item from carry_private.assets where account_id=p_account and id=p_id;
  if not found then raise exception 'asset_not_found'; end if;
  if item.state='deleting' then raise exception 'asset_cleanup_pending'; end if;
  return jsonb_build_object('id',item.id,'accountID',p_account,'sha256',item.sha256,
    'byteCount',item.byte_count,'contentType',item.content_type,'status',item.state);
end;
$$;
revoke all on function public.carry_asset_descriptor(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.carry_asset_descriptor(uuid,uuid,uuid) to service_role;

create table carry_private.asset_rate_buckets (
  account_id uuid primary key references auth.users(id) on delete cascade,
  window_start timestamptz not null,
  requests integer not null
);
alter table carry_private.asset_rate_buckets enable row level security;
revoke all on carry_private.asset_rate_buckets from public,anon,authenticated;
grant select,insert,update,delete on carry_private.asset_rate_buckets to service_role;
create function public.carry_asset_rate_limit(p_account uuid,p_session uuid)
returns boolean language plpgsql security invoker set search_path='' as $$
declare n integer;
begin
  perform carry_private.graph_require_session(p_account,p_session);
  insert into carry_private.asset_rate_buckets as bucket values(p_account,statement_timestamp(),1)
    on conflict(account_id) do update set
      requests=case when bucket.window_start<statement_timestamp()-interval '1 minute' then 1 else least(bucket.requests+1,61) end,
      window_start=case when bucket.window_start<statement_timestamp()-interval '1 minute' then statement_timestamp() else bucket.window_start end
    returning requests into n;
  return n<=60;
end;
$$;
revoke all on function public.carry_asset_rate_limit(uuid,uuid) from public,anon,authenticated;
grant execute on function public.carry_asset_rate_limit(uuid,uuid) to service_role;

-- The provider's real object version binds byte inspection to the completed
-- TUS attempt, including a lost last-chunk acknowledgement. Supabase owns the
-- storage schema; no client privileges or provider tables are changed here.
create function public.carry_asset_inspection_target(p_account uuid,p_session uuid,p_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item carry_private.assets; object_version text;
begin
  perform carry_private.graph_require_session(p_account,p_session);
  select * into item from carry_private.assets where account_id=p_account and id=p_id;
  if not found then raise exception 'asset_not_found'; end if;
  if item.state='deleting' then raise exception 'asset_cleanup_pending'; end if;
  select version into object_version from storage.objects where bucket_id='carry-account-assets'
    and name collate "C"=p_account::text||'/'||item.id::text||'/'||item.sha256 and archived_at is null and not is_delete_marker;
  if not found or object_version is null then return jsonb_build_object('id',p_id,'status','not_uploaded'); end if;
  return jsonb_build_object('id',item.id,'accountID',p_account,'sha256',item.sha256,
    'byteCount',item.byte_count,'contentType',item.content_type,
    'status',case when item.state='verified' and item.verified_version::text=object_version then 'verified' else 'pending' end,'storageVersion',object_version);
end;
$$;

create function public.carry_asset_inspection_finish(p_account uuid,p_session uuid,p_id uuid,p_version text,p_sha256 text,p_bytes bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item carry_private.assets; result jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  select * into item from carry_private.assets where account_id=p_account and id=p_id;
  if not found then raise exception 'asset_not_found'; end if;
  -- Lock provider metadata for this short commit only, never across HTTP.
  perform 1 from storage.objects where bucket_id='carry-account-assets'
    and name collate "C"=p_account::text||'/'||item.id::text||'/'||item.sha256 and version=p_version
    and archived_at is null and not is_delete_marker for share;
  if not found then return jsonb_build_object('id',p_id,'status','retry'); end if;
  if exists(select 1 from carry_private.asset_upload_attempts where account_id=p_account and asset_id=p_id
      and storage_version::text=p_version and state='deleting' and operation_id is not null)
  then return jsonb_build_object('id',p_id,'status','retry'); end if;
  result:=public.carry_asset_confirm(p_account,p_session,p_id,p_sha256,p_bytes);
  if result->>'status'='verified' then
    update carry_private.assets set verified_version=p_version::uuid where account_id=p_account and id=p_id;
  end if;
  update carry_private.asset_upload_attempts set
    state=case when result->>'status'='verified' and storage_version::text=p_version then 'complete' else 'deleting' end,
    acknowledged_bytes=case when result->>'status'='verified' and storage_version::text=p_version then item.byte_count else acknowledged_bytes end,
    operation_id=null,lease_until=null
    where account_id=p_account and asset_id=p_id and state<>'complete';
  return result;
end;
$$;
revoke all on function public.carry_asset_inspection_target(uuid,uuid,uuid),
  public.carry_asset_inspection_finish(uuid,uuid,uuid,text,text,bigint) from public,anon,authenticated;
grant execute on function public.carry_asset_inspection_target(uuid,uuid,uuid),
  public.carry_asset_inspection_finish(uuid,uuid,uuid,text,text,bigint) to service_role;

-- Internal cleanup claims serialize with verification and deletion, then leave
-- the transaction before contacting Storage. Only exact immutable versions may
-- be removed. An unknown creation had no request body and was never PATCH-able.
create function public.carry_asset_cleanup_claim(p_account uuid,p_operation uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare attempt carry_private.asset_upload_attempts; item carry_private.assets; deleting_account boolean;
begin
  if p_account is null or p_operation is null then raise exception 'invalid_cleanup_operation'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  deleting_account:=exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and status='deleting');
  if (select count(*) from carry_private.asset_upload_attempts where account_id=p_account and state='deleting'
      and operation_id is not null and lease_until>statement_timestamp())>=2 then return null; end if;
  select a.* into attempt from carry_private.asset_upload_attempts a
    join carry_private.assets f on f.account_id=a.account_id and f.id=a.asset_id
    where a.account_id=p_account and (a.operation_id is null or a.lease_until<=statement_timestamp())
      and (a.state in ('uncertain','deleting') or (a.state='creating' and a.lease_until<=statement_timestamp())
        or deleting_account or f.state='deleting' or (f.state='pending' and f.expires_at<=statement_timestamp()))
      and not (f.state='verified' and not deleting_account and (
        coalesce(a.storage_version=f.verified_version,false) or exists(select 1 from storage.objects o
          where o.bucket_id='carry-account-assets' and o.name collate "C"=p_account::text||'/'||f.id::text||'/'||f.sha256
            and o.version=a.storage_version::text and o.archived_at is null and not o.is_delete_marker)))
    order by a.created_at,a.id limit 1;
  if not found then return null; end if;
  select * into item from carry_private.assets where account_id=p_account and id=attempt.asset_id;
  if deleting_account or item.state='deleting' or (item.state='pending' and item.expires_at<=statement_timestamp())
    or (item.state='pending' and exists(select 1 from storage.objects where bucket_id='carry-account-assets'
      and name collate "C"=p_account::text||'/'||item.id::text||'/'||item.sha256 and version=attempt.storage_version::text
      and archived_at is null and not is_delete_marker)) then
    update carry_private.assets set state='deleting' where account_id=p_account and id=item.id;
  end if;
  update carry_private.asset_upload_attempts set state='deleting',operation_id=p_operation,lease_until=statement_timestamp()+interval '120 seconds'
    where account_id=p_account and id=attempt.id;
  return jsonb_build_object('id',attempt.id,'accountID',p_account,'assetID',item.id,'sha256',item.sha256,
    'byteCount',item.byte_count,'location',attempt.location,'storageVersion',attempt.storage_version,'mayHaveBytes',attempt.may_have_bytes);
end;
$$;

create function public.carry_asset_cleanup_finish(p_account uuid,p_id uuid,p_operation uuid)
returns void language plpgsql security invoker set search_path='' as $$
declare attempt carry_private.asset_upload_attempts; item carry_private.assets;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  select * into attempt from carry_private.asset_upload_attempts where account_id=p_account and id=p_id for update;
  if not found then return; end if;
  if p_operation is null or attempt.operation_id is distinct from p_operation or attempt.state<>'deleting'
  then raise exception 'cleanup_operation_superseded'; end if;
  select * into item from carry_private.assets where account_id=p_account and id=attempt.asset_id;
  if attempt.may_have_bytes and (attempt.location is null or attempt.storage_version is null)
  then raise exception 'cleanup_location_missing'; end if;
  if exists(select 1 from storage.objects where bucket_id='carry-account-assets'
    and name collate "C"=p_account::text||'/'||item.id::text||'/'||item.sha256 and version=attempt.storage_version::text)
  then raise exception 'cleanup_not_confirmed'; end if;
  delete from carry_private.asset_upload_attempts where account_id=p_account and id=p_id;
  if item.state='deleting' and not exists(select 1 from carry_private.asset_upload_attempts where account_id=p_account and asset_id=item.id)
    and not exists(select 1 from storage.objects where bucket_id='carry-account-assets' and name collate "C"=p_account::text||'/'||item.id::text||'/'||item.sha256) then
    delete from carry_private.assets where account_id=p_account and id=item.id;
  end if;
end;
$$;
revoke all on function public.carry_asset_cleanup_claim(uuid,uuid),public.carry_asset_cleanup_finish(uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.carry_asset_cleanup_claim(uuid,uuid),public.carry_asset_cleanup_finish(uuid,uuid,uuid) to service_role;

-- Reservation admission includes uncertain upload attempts as well as objects.
create or replace function public.carry_asset_reserve(p_account uuid, p_session uuid, p_asset jsonb)
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
  select charged_bytes,pending_units into charged,pending_count from carry_private.asset_usage(p_account);
  if charged+52428800 > budget.maximum_bytes or pending_count >= budget.maximum_pending
  then raise exception 'asset_budget_exceeded'; end if;
  insert into carry_private.assets(account_id,id,entity_id,entity_kind,slot,sha256,byte_count,content_type,state,expires_at)
    values(p_account,asset_id,entity_id,kind,slot_name,sha,bytes,mime,'pending',statement_timestamp()+interval '24 hours');
  return jsonb_build_object('id',asset_id,'status','pending');
end;
$$;
revoke all on function public.carry_asset_reserve(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.carry_asset_reserve(uuid,uuid,jsonb) to service_role;

