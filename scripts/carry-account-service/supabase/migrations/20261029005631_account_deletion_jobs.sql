-- This durable job deliberately survives Auth deletion. It contains no profile,
-- itinerary or plaintext capability; completed receipts expire after 30 days.
alter table carry_private.carry_apple_credentials add column revoked_at timestamptz;
create table carry_private.account_deletions (
  account_id uuid primary key,
  ticket_hash text not null unique check(ticket_hash ~ '^[0-9a-f]{64}$'),
  stage text not null check(stage in ('revoking','purging','deleting_auth','deleted')),
  requested_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  operation_id uuid,
  lease_until timestamptz,
  retry_at timestamptz not null default statement_timestamp(),
  attempts integer not null default 0 check(attempts>=0)
);
create index account_deletions_pending on carry_private.account_deletions(stage,retry_at);
alter table carry_private.account_deletions enable row level security;
revoke all on carry_private.account_deletions from public,anon,authenticated;
grant select,insert,update,delete on carry_private.account_deletions to service_role;

create function public.carry_account_request_deletion(p_account uuid,p_session uuid,p_subject text,p_audience text,p_encrypted_token text,p_ticket text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions; ticket_digest text;
begin
  if p_account is null or p_ticket is null or p_ticket !~ '^[0-9a-f]{64}$' then raise exception 'invalid_deletion_request'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform public.carry_account_require_session(p_account,p_session);
  ticket_digest:=encode(sha256(convert_to(p_ticket,'UTF8')),'hex');
  select * into job from carry_private.account_deletions where account_id=p_account for update;
  if found then
    if job.ticket_hash<>ticket_digest then raise exception 'deletion_receipt_mismatch';end if;
    return jsonb_build_object('status',case when job.stage='deleted' then 'deleted' else 'deleting' end);
  end if;
  perform public.carry_account_begin_delete(p_account,p_subject,p_audience,p_encrypted_token);
  insert into carry_private.account_deletions(account_id,ticket_hash,stage) values(p_account,ticket_digest,'revoking');
  return jsonb_build_object('status','deleting');
end;
$$;

create function public.carry_account_deletion_status(p_ticket text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions;
begin
  if p_ticket is null or p_ticket !~ '^[0-9a-f]{64}$' then raise exception using errcode='28000',message='invalid_deletion_receipt';end if;
  select * into job from carry_private.account_deletions where ticket_hash=encode(sha256(convert_to(p_ticket,'UTF8')),'hex');
  if not found then
    if exists(select 1 from carry_private.account_deletion_receipts where ticket_hash=encode(sha256(convert_to(p_ticket,'UTF8')),'hex'))
      then return jsonb_build_object('status','deleted');end if;
    raise exception using errcode='28000',message='invalid_deletion_receipt';
  end if;
  return jsonb_build_object('status',case when job.stage='deleted' then 'deleted' else 'deleting' end);
end;
$$;

create function public.carry_account_deletion_claim(p_account uuid,p_operation uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions;
begin
  if p_account is null or p_operation is null then raise exception 'invalid_deletion_operation';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  select * into job from carry_private.account_deletions where account_id=p_account for update;
  if not found or job.stage='deleted' or job.retry_at>statement_timestamp()
    or (job.operation_id is not null and job.lease_until>statement_timestamp()) then return null;end if;
  update carry_private.account_deletions set operation_id=p_operation,lease_until=statement_timestamp()+interval '120 seconds',
    attempts=least(attempts+1,1000000) where account_id=p_account;
  return jsonb_build_object('accountID',p_account,'stage',job.stage);
end;
$$;

create function carry_private.require_deletion_operation(p_account uuid,p_operation uuid)
returns carry_private.account_deletions language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  select * into job from carry_private.account_deletions where account_id=p_account for update;
  if not found or job.operation_id is distinct from p_operation or job.lease_until<=statement_timestamp()
    or p_operation is null then raise exception 'deletion_operation_superseded';end if;
  return job;
end;
$$;

-- A narrow, unexposed Auth predicate; the service role has no general SELECT
-- privilege on auth.users. This is the sole reason for SECURITY DEFINER here.
create function carry_private.deletion_identity_exists(p_account uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from auth.users where id=p_account)
$$;
revoke all on function carry_private.deletion_identity_exists(uuid) from public,anon,authenticated;
grant execute on function carry_private.deletion_identity_exists(uuid) to service_role;

create function public.carry_account_deletion_credential(p_account uuid,p_operation uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions; credential carry_private.carry_apple_credentials;
begin
  job:=carry_private.require_deletion_operation(p_account,p_operation);
  if job.stage<>'revoking' then raise exception 'invalid_deletion_stage';end if;
  select * into credential from carry_private.carry_apple_credentials where account_id=p_account and revoked_at is null
    order by audience,apple_subject limit 1;
  if not found then return null;end if;
  return jsonb_build_object('account_id',credential.account_id,'apple_subject',credential.apple_subject,
    'audience',credential.audience,'encrypted_token',credential.encrypted_token);
end;
$$;

create function public.carry_account_deletion_revoked(p_account uuid,p_operation uuid,p_subject text,p_audience text,p_token_hash text)
returns void language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions;
begin
  job:=carry_private.require_deletion_operation(p_account,p_operation);
  if job.stage<>'revoking' then raise exception 'invalid_deletion_stage';end if;
  update carry_private.carry_apple_credentials set revoked_at=statement_timestamp()
    where account_id=p_account and apple_subject=p_subject and audience=p_audience and status='deleting'
      and encode(sha256(convert_to(encrypted_token,'UTF8')),'hex')=p_token_hash;
  if not found then raise exception 'deletion_credential_changed';end if;
end;
$$;

create function public.carry_account_deletion_advance(p_account uuid,p_operation uuid,p_stage text)
returns void language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions;
begin
  job:=carry_private.require_deletion_operation(p_account,p_operation);
  if job.stage='revoking' and p_stage='purging' then
    if not exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account)
      or exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and (status<>'deleting' or revoked_at is null))
      then raise exception 'deletion_revocation_incomplete';end if;
  elsif job.stage='purging' and p_stage='deleting_auth' then
    if exists(select 1 from carry_private.assets where account_id=p_account)
      or exists(select 1 from carry_private.asset_upload_attempts where account_id=p_account)
      or exists(select 1 from storage.objects where bucket_id='carry-account-assets'
        and name collate "C" like p_account::text||'/%') then raise exception 'deletion_files_pending';end if;
    -- Purge is intentionally still gated until every owned domain/AI store has
    -- joined this transaction. The worker must persist/retry this failure.
    perform public.carry_account_purge_owned_data(p_account);
  elsif job.stage='deleting_auth' and p_stage='deleted' then
    if carry_private.deletion_identity_exists(p_account) then raise exception 'deletion_auth_pending';end if;
  else raise exception 'invalid_deletion_stage';end if;
  if p_stage='deleted' then
    insert into carry_private.account_deletion_receipts(ticket_hash,completed_at) values(job.ticket_hash,statement_timestamp())
      on conflict(ticket_hash) do nothing;
  end if;
  update carry_private.account_deletions set stage=p_stage,operation_id=null,lease_until=null,
    retry_at=statement_timestamp(),attempts=0,completed_at=case when p_stage='deleted' then statement_timestamp() else null end
    where account_id=p_account;
end;
$$;

create function public.carry_account_deletion_release(p_account uuid,p_operation uuid,p_failed boolean)
returns void language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions;
begin
  job:=carry_private.require_deletion_operation(p_account,p_operation);
  update carry_private.account_deletions set operation_id=null,lease_until=null,
    retry_at=case when p_failed then statement_timestamp()+make_interval(secs=>least(3600,30*power(2,least(job.attempts,7)))::integer)
      else statement_timestamp() end,attempts=case when p_failed then attempts else 0 end
    where account_id=p_account;
end;
$$;
revoke all on function public.carry_account_request_deletion(uuid,uuid,text,text,text,text),
  public.carry_account_deletion_status(text),public.carry_account_deletion_claim(uuid,uuid),
  public.carry_account_deletion_revoked(uuid,uuid,text,text,text),
  public.carry_account_deletion_advance(uuid,uuid,text),public.carry_account_deletion_release(uuid,uuid,boolean),
  public.carry_account_deletion_credential(uuid,uuid),carry_private.require_deletion_operation(uuid,uuid) from public,anon,authenticated;
grant execute on function public.carry_account_request_deletion(uuid,uuid,text,text,text,text),
  public.carry_account_deletion_status(text),public.carry_account_deletion_claim(uuid,uuid),
  public.carry_account_deletion_revoked(uuid,uuid,text,text,text),
  public.carry_account_deletion_advance(uuid,uuid,text),public.carry_account_deletion_release(uuid,uuid,boolean),
  public.carry_account_deletion_credential(uuid,uuid),carry_private.require_deletion_operation(uuid,uuid) to service_role;

-- Purge the currently implemented owned stores only after durable authorization,
-- Apple revocation and confirmed physical file removal. Any future account_id
-- store must explicitly join this purge; an unknown store blocks deletion.
create or replace function public.carry_account_purge_owned_data(p_account_id uuid)
returns void language plpgsql security invoker set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account_id::text,0));
  if not exists(select 1 from carry_private.account_deletions where account_id=p_account_id and stage='purging'
    and operation_id is not null and lease_until>statement_timestamp()) then raise exception 'account_deletion_not_authorized';end if;
  if exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account_id and (status<>'deleting' or revoked_at is null))
    then raise exception 'deletion_revocation_incomplete';end if;
  if exists(select 1 from carry_private.assets where account_id=p_account_id)
    or exists(select 1 from carry_private.asset_upload_attempts where account_id=p_account_id)
    or exists(select 1 from storage.objects where bucket_id='carry-account-assets'
      and name collate "C" like p_account_id::text||'/%') then raise exception 'deletion_files_pending';end if;
  if exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    join pg_catalog.pg_attribute a on a.attrelid=c.oid
    where n.nspname='carry_private' and c.relkind in ('r','p') and a.attname='account_id' and not a.attisdropped
      and c.relname not in ('carry_apple_credentials','carry_account_rate_buckets','graph_accounts','graph_entities',
        'graph_changes','graph_receipts','assets','asset_budgets','asset_upload_attempts','asset_rate_buckets',
        'asset_cleanup_turns','account_deletions')) then raise exception 'unregistered_account_store';end if;
  delete from carry_private.graph_accounts where account_id=p_account_id;
  delete from carry_private.asset_budgets where account_id=p_account_id;
  delete from carry_private.asset_rate_buckets where account_id=p_account_id;
  delete from carry_private.carry_account_rate_buckets where account_id=p_account_id;
  delete from carry_private.asset_cleanup_turns where account_id=p_account_id;
end;
$$;

-- A completed opaque receipt has no account/profile mapping. Keep this minimal
-- marker after the diagnostic job expires so a phone offline for >30 days can
-- still distinguish confirmed deletion from a request that never arrived.
create table carry_private.account_deletion_receipts (
  ticket_hash text primary key check(ticket_hash ~ '^[0-9a-f]{64}$'),
  completed_at timestamptz not null
);
alter table carry_private.account_deletion_receipts enable row level security;
revoke all on carry_private.account_deletion_receipts from public,anon,authenticated;
grant select,insert on carry_private.account_deletion_receipts to service_role;

create table carry_private.account_deletion_dispatch (
  singleton boolean primary key default true check(singleton),
  token_hash text not null check(token_hash ~ '^[0-9a-f]{64}$'),
  lease_until timestamptz not null default '-infinity'
);
alter table carry_private.account_deletion_dispatch enable row level security;
revoke all on carry_private.account_deletion_dispatch from public,anon,authenticated;
grant select,update on carry_private.account_deletion_dispatch to service_role;

create function public.carry_account_deletion_accounts(p_token text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare config carry_private.account_deletion_dispatch; result jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception using errcode='28000',message='invalid_maintenance_capability';end if;
  select * into config from carry_private.account_deletion_dispatch where singleton for update;
  if not found or config.token_hash<>encode(sha256(convert_to(p_token,'UTF8')),'hex')
    then raise exception using errcode='28000',message='invalid_maintenance_capability';end if;
  if config.lease_until>statement_timestamp() then return '[]'::jsonb;end if;
  select coalesce(jsonb_agg(account_id),'[]'::jsonb) into result from (
    select account_id from carry_private.account_deletions where stage<>'deleted' and retry_at<=statement_timestamp()
      and (operation_id is null or lease_until<=statement_timestamp()) order by retry_at,account_id limit 2
  ) jobs;
  update carry_private.account_deletion_dispatch set lease_until=statement_timestamp()+interval '120 seconds' where singleton;
  return result;
end;
$$;
revoke all on function public.carry_account_deletion_accounts(text) from public,anon,authenticated;
grant execute on function public.carry_account_deletion_accounts(text) to service_role;
