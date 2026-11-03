-- A valid JWT remains cryptographically valid after Auth logout. Keep an
-- application tombstone for every old native session still present at commit.
alter table carry_private.account_deletions add column recovery_revoked_session_ids uuid[] not null default '{}';
create function carry_private.recovery_fence_other_sessions(p_account uuid,p_current uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform carry_private.account_require_native_session(p_account,p_current);
 update carry_private.account_deletions set recovery_revoked_session_ids=array(
  select distinct id from (select unnest(recovery_revoked_session_ids) id union all
   select id from auth.sessions where user_id=p_account and id<>p_current) old_sessions
 ) where account_id=p_account;
end;$$;
revoke all on function carry_private.recovery_fence_other_sessions(uuid,uuid) from public,anon,authenticated;
grant execute on function carry_private.recovery_fence_other_sessions(uuid,uuid) to service_role;
create or replace function carry_private.account_require_native_session(p_account uuid,p_session uuid)
returns void language plpgsql stable security definer set search_path='' as $$
begin
 if p_account is null or p_session is null or not exists(
  select 1 from auth.sessions s where s.id=p_session and s.user_id=p_account
   and s.oauth_client_id is null and (s.not_after is null or s.not_after>statement_timestamp())
   and not exists(select 1 from carry_private.account_deletions r where r.account_id=p_account and s.id=any(r.recovery_revoked_session_ids))
 ) then raise exception using message='session_expired',errcode='28000';end if;
end;$$;

-- Operator-assisted recovery only. No deleted Auth identity or missing file is recreated.
alter table carry_private.account_deletions drop constraint account_deletions_stage_check;
alter table carry_private.account_deletions add constraint account_deletions_stage_check check(stage in ('revoking','purging','deleting_auth','deleted','cancelled'));
alter table carry_private.account_deletions add column recovery_hold_at timestamptz;
-- Set only by an operator after verifying old provider-side deletion ended.
-- A local HTTP timeout or a successful GET is NOT sufficient evidence.
alter table carry_private.account_deletions add column recovery_provider_cleared_at timestamptz;
alter table carry_private.account_deletions add column recovery_provider_evidence_digest text check(recovery_provider_evidence_digest ~ '^[0-9a-f]{64}$');
alter table carry_private.account_deletions add column recovery_operation uuid;
alter table carry_private.account_deletions add column recovery_lease_until timestamptz;
alter table carry_private.account_deletions add column recovery_graph_hash text;
alter table carry_private.account_deletions add column recovery_asset_hash text;
-- A prior manual hold does not prove old HTTP has drained. Start a fresh drain window.
update carry_private.account_deletions set recovery_hold_at=statement_timestamp()
 where stage='purging' and retry_at='infinity'::timestamptz and (operation_id is null or lease_until<=statement_timestamp());
alter table carry_private.account_deletion_receipts add column result text not null default 'deleted' check(result in ('deleted','cancelled'));

create function carry_private.recovery_held(p_account uuid) returns boolean
language sql stable security invoker set search_path='' as $$
 select exists(select 1 from carry_private.account_deletions where account_id=p_account and recovery_hold_at is not null)
$$;
revoke all on function carry_private.recovery_held(uuid) from public,anon,authenticated;
grant execute on function carry_private.recovery_held(uuid) to service_role;

-- Fence all worker entry/late-completion paths. The old implementation moves to
-- the private schema; no new browser RPC or authority is introduced by the wrapper.
alter function public.carry_account_deletion_claim(uuid,uuid) set schema carry_private;
alter function carry_private.carry_account_deletion_claim(uuid,uuid) rename to deletion_claim_unheld;
create function public.carry_account_deletion_claim(p_account uuid,p_operation uuid) returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
 if carry_private.recovery_held(p_account) or exists(select 1 from carry_private.account_deletions where account_id=p_account and stage='cancelled') then return null;end if;
 return carry_private.deletion_claim_unheld(p_account,p_operation);
end;$$;
create or replace function carry_private.require_deletion_operation(p_account uuid,p_operation uuid)
returns carry_private.account_deletions language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
 select * into job from carry_private.account_deletions where account_id=p_account for update;
 if not found or job.operation_id is distinct from p_operation or job.lease_until<=statement_timestamp() or p_operation is null
   or job.recovery_hold_at is not null or job.stage='cancelled' then raise exception 'deletion_operation_superseded';end if;
 return job;
end;$$;

alter function public.carry_asset_cleanup_claim(uuid,uuid) set schema carry_private;
alter function carry_private.carry_asset_cleanup_claim(uuid,uuid) rename to asset_cleanup_claim_unheld;
create function public.carry_asset_cleanup_claim(p_account uuid,p_operation uuid) returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
 if carry_private.recovery_held(p_account) then return null;end if;
 return carry_private.asset_cleanup_claim_unheld(p_account,p_operation);
end;$$;
alter function public.carry_asset_cleanup_empty(uuid) set schema carry_private;
alter function carry_private.carry_asset_cleanup_empty(uuid) rename to asset_cleanup_empty_unheld;
create function public.carry_asset_cleanup_empty(p_account uuid) returns void
language plpgsql security invoker set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
 if carry_private.recovery_held(p_account) then return;end if;
 perform carry_private.asset_cleanup_empty_unheld(p_account);
end;$$;
alter function public.carry_asset_cleanup_finish(uuid,uuid,uuid) set schema carry_private;
alter function carry_private.carry_asset_cleanup_finish(uuid,uuid,uuid) rename to asset_cleanup_finish_unheld;
create function public.carry_asset_cleanup_finish(p_account uuid,p_id uuid,p_operation uuid) returns void
language plpgsql security invoker set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
 if carry_private.recovery_held(p_account) then raise exception 'cleanup_operation_superseded';end if;
 perform carry_private.asset_cleanup_finish_unheld(p_account,p_id,p_operation);
end;$$;
revoke all on function public.carry_account_deletion_claim(uuid,uuid),public.carry_asset_cleanup_claim(uuid,uuid),public.carry_asset_cleanup_empty(uuid),public.carry_asset_cleanup_finish(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.carry_account_deletion_claim(uuid,uuid),public.carry_asset_cleanup_claim(uuid,uuid),public.carry_asset_cleanup_empty(uuid),public.carry_asset_cleanup_finish(uuid,uuid,uuid) to service_role;

create function carry_private.recovery_fingerprints(p_account uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('graph',encode(sha256(convert_to(coalesce((select jsonb_agg(to_jsonb(e) order by id) from carry_private.graph_entities e where account_id=p_account),'[]'::jsonb)::text,'UTF8')),'hex'),
 'providerEvidence',(select jsonb_build_object('at',recovery_provider_cleared_at,'digest',recovery_provider_evidence_digest) from carry_private.account_deletions where account_id=p_account),
 'assets',encode(sha256(convert_to(jsonb_build_object('assets',coalesce((select jsonb_agg(to_jsonb(a) order by id) from carry_private.assets a where account_id=p_account),'[]'::jsonb),
 'attempts',coalesce((select jsonb_agg(to_jsonb(a) order by id) from carry_private.asset_upload_attempts a where account_id=p_account),'[]'::jsonb))::text,'UTF8')),'hex'))
$$;
revoke all on function carry_private.recovery_fingerprints(uuid) from public,anon,authenticated;
grant execute on function carry_private.recovery_fingerprints(uuid) to service_role;

create function public.carry_account_recovery_prepare(p_account uuid,p_session uuid,p_ticket text,p_subject text,p_audience text,p_operation uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions; fingerprints jsonb; manifests jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
 perform public.carry_account_require_session(p_account,p_session);
 select * into job from carry_private.account_deletions where account_id=p_account for update;
 if not found or p_ticket is null or p_ticket!~'^[0-9a-f]{64}$' or job.ticket_hash<>encode(sha256(convert_to(p_ticket,'UTF8')),'hex')
   or not exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and apple_subject=p_subject and audience=p_audience)
   then raise exception using errcode='28000',message='recovery_identity_mismatch';end if;
 if job.stage='cancelled' then return jsonb_build_object('status','cancelled');end if;
 if exists(select 1 from carry_private.account_deletion_receipts where ticket_hash=job.ticket_hash and result='deleted')
   or job.stage<>'purging' or job.completed_at is not null or job.retry_at<>'infinity'::timestamptz or job.recovery_hold_at is null
   or job.recovery_hold_at>statement_timestamp()-interval '110 seconds' or p_operation is null
   or job.recovery_provider_cleared_at is null or job.recovery_provider_evidence_digest is null
   or job.recovery_provider_cleared_at<job.recovery_hold_at+interval '110 seconds' or job.recovery_provider_cleared_at>statement_timestamp()
   or (job.operation_id is not null and job.lease_until>statement_timestamp())
   or (job.recovery_operation is not null and job.recovery_lease_until>statement_timestamp())
   or not carry_private.deletion_identity_exists(p_account)
   or not exists(select 1 from carry_private.graph_accounts where account_id=p_account)
   or exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and revoked_at is null)
   then raise exception 'recovery_not_ready';end if;
 if (select count(*) from carry_private.assets where account_id=p_account)>128
   or (select coalesce(sum(byte_count),0) from carry_private.assets where account_id=p_account)>134217728
   or exists(select 1 from carry_private.assets a where account_id=p_account and (verified_at is null or verified_version is null))
   or exists(select 1 from carry_private.asset_upload_attempts a join carry_private.assets f on f.account_id=a.account_id and f.id=a.asset_id
     where a.account_id=p_account and (a.storage_version is distinct from f.verified_version or a.acknowledged_bytes<>f.byte_count
       or a.location is null or not a.may_have_bytes or (a.operation_id is not null and a.lease_until<>'infinity'::timestamptz)))
   then raise exception 'recovery_files_unverified';end if;
 -- Lock provider metadata too: provider writers do not use our account lock.
 perform 1 from storage.objects o join carry_private.assets a on o.name collate "C"=a.account_id::text||'/'||a.id::text||'/'||a.sha256
   and o.bucket_id='carry-account-assets' and o.version=a.verified_version::text and o.archived_at is null and not o.is_delete_marker where a.account_id=p_account for share of o;
 if exists(select 1 from carry_private.assets a where a.account_id=p_account and not exists(select 1 from storage.objects o
   where o.bucket_id='carry-account-assets' and o.name collate "C"=a.account_id::text||'/'||a.id::text||'/'||a.sha256
    and o.version=a.verified_version::text and o.archived_at is null and not o.is_delete_marker)) then raise exception 'recovery_files_missing';end if;
 fingerprints:=carry_private.recovery_fingerprints(p_account);
 select coalesce(jsonb_agg(jsonb_build_object('accountID',account_id,'id',id,'sha256',sha256,'byteCount',byte_count,'storageVersion',verified_version) order by id),'[]'::jsonb)
 into manifests from carry_private.assets where account_id=p_account;
 update carry_private.account_deletions set recovery_operation=p_operation,recovery_lease_until=statement_timestamp()+interval '5 minutes',
   recovery_graph_hash=fingerprints->>'graph',recovery_asset_hash=fingerprints->>'assets' where account_id=p_account;
 return jsonb_build_object('status','verify','operationID',p_operation,'fingerprints',fingerprints,'assets',manifests);
end;$$;

create function public.carry_account_recovery_commit(p_account uuid,p_session uuid,p_ticket text,p_subject text,p_audience text,p_encrypted_token text,p_operation uuid,p_fingerprints jsonb,p_assets jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions; asset carry_private.assets; expected jsonb; current_fingerprints jsonb;
  entity carry_private.graph_entities; refs jsonb; reference record; now_ms bigint;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
 perform public.carry_account_require_session(p_account,p_session);
 select * into job from carry_private.account_deletions where account_id=p_account for update;
 if not found or p_ticket is null or p_ticket!~'^[0-9a-f]{64}$' or job.ticket_hash<>encode(sha256(convert_to(p_ticket,'UTF8')),'hex')
   or not exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and apple_subject=p_subject and audience=p_audience)
   then raise exception using errcode='28000',message='recovery_identity_mismatch';end if;
 if job.stage='cancelled' then return jsonb_build_object('status','cancelled');end if;
 if job.stage<>'purging' or job.recovery_hold_at is null or job.recovery_operation is distinct from p_operation
   or p_operation is null or job.recovery_lease_until<=statement_timestamp() or job.retry_at<>'infinity'::timestamptz
   or job.recovery_provider_cleared_at is null or job.recovery_provider_evidence_digest is null
   or job.recovery_provider_cleared_at<job.recovery_hold_at+interval '110 seconds' or job.recovery_provider_cleared_at>statement_timestamp()
   or not carry_private.deletion_identity_exists(p_account) or p_encrypted_token is null or length(p_encrypted_token)<16 then raise exception 'recovery_operation_superseded';end if;
 current_fingerprints:=carry_private.recovery_fingerprints(p_account);
 if p_fingerprints is distinct from current_fingerprints or job.recovery_graph_hash is distinct from current_fingerprints->>'graph'
   or job.recovery_asset_hash is distinct from current_fingerprints->>'assets' then raise exception 'recovery_snapshot_changed';end if;
 select coalesce(jsonb_agg(jsonb_build_object('accountID',account_id,'id',id,'sha256',sha256,'byteCount',byte_count,'storageVersion',verified_version) order by id),'[]'::jsonb)
 into expected from carry_private.assets where account_id=p_account;
 if p_assets is distinct from expected then raise exception 'recovery_proof_mismatch';end if;
 for asset in select * from carry_private.assets where account_id=p_account loop
   perform 1 from storage.objects o where o.bucket_id='carry-account-assets'
    and o.name collate "C"=p_account::text||'/'||asset.id::text||'/'||asset.sha256 and o.version=asset.verified_version::text
    and o.archived_at is null and not o.is_delete_marker for share;
   if not found then raise exception 'recovery_files_missing';end if;
 end loop;
 update carry_private.assets set state='verified' where account_id=p_account;
 update carry_private.asset_upload_attempts set state='complete',operation_id=null,lease_until=null where account_id=p_account;
 -- Validate every graph reference without mutating graph versions or fields.
 for entity in select * from carry_private.graph_entities where account_id=p_account loop
   refs:=case entity.kind
    when 'photo' then jsonb_build_object('thumbnail',entity.fields->'thumbnailAssetID','original',entity.fields->'originalAssetID')
    when 'attachment' then jsonb_build_object('thumbnail',entity.fields->'thumbnailAssetID','file',entity.fields->'fileAssetID')
    when 'libraryItem' then jsonb_build_object('image',entity.fields->'imageAssetID')
    when 'trip' then coalesce(entity.fields->'backgroundAssetIDs','{}'::jsonb) else '{}'::jsonb end;
   for reference in select key,value from jsonb_each(refs) where value is not null and value<>'null'::jsonb loop
     if not exists(select 1 from carry_private.assets a where a.account_id=p_account and a.id=(reference.value#>>'{}')::uuid
       and a.entity_id=entity.id and a.entity_kind=entity.kind and a.slot=reference.key and a.state='verified') then raise exception 'recovery_reference_missing';end if;
   end loop;
 end loop;
 -- Fence old native JWTs in the same transaction before restoring access.
 perform carry_private.recovery_fence_other_sessions(p_account,p_session);
 -- Revoked Apple tokens stay revoked. New authorization is the sole active credential.
 delete from carry_private.carry_apple_credentials where account_id=p_account;
 insert into carry_private.carry_apple_credentials(account_id,apple_subject,audience,encrypted_token,status,updated_at,revoked_at)
   values(p_account,p_subject,p_audience,p_encrypted_token,'active',statement_timestamp(),null);
 now_ms:=floor(extract(epoch from statement_timestamp())*1000)::bigint;
 update carry_ai.records set value=value||jsonb_build_object('revokedAt',now_ms)
  where account_id=p_account and bucket='grant' and value->>'revokedAt' is null;
 insert into carry_private.account_deletion_receipts(ticket_hash,completed_at,result) values(job.ticket_hash,statement_timestamp(),'cancelled')
   on conflict(ticket_hash) do nothing;
 update carry_private.account_deletions set stage='cancelled',recovery_operation=null,recovery_lease_until=null,
   recovery_graph_hash=null,recovery_asset_hash=null,operation_id=null,lease_until=null,retry_at='infinity'::timestamptz,
   recovery_hold_at=null where account_id=p_account;
 return jsonb_build_object('status','cancelled');
end;$$;
revoke all on function public.carry_account_recovery_prepare(uuid,uuid,text,text,text,uuid),public.carry_account_recovery_commit(uuid,uuid,text,text,text,text,uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.carry_account_recovery_prepare(uuid,uuid,text,text,text,uuid),public.carry_account_recovery_commit(uuid,uuid,text,text,text,text,uuid,jsonb,jsonb) to service_role;

create or replace function public.carry_account_deletion_status(p_ticket text) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result text;
begin
 if p_ticket is null or p_ticket!~'^[0-9a-f]{64}$' then raise exception using errcode='28000',message='invalid_deletion_receipt';end if;
 select r.result into result from carry_private.account_deletion_receipts r where ticket_hash=encode(sha256(convert_to(p_ticket,'UTF8')),'hex');
 if found then return jsonb_build_object('status',result);end if;
 select case when stage='deleted' then 'deleted' when stage='cancelled' then 'cancelled' else 'deleting' end into result
  from carry_private.account_deletions where ticket_hash=encode(sha256(convert_to(p_ticket,'UTF8')),'hex');
 if not found then raise exception using errcode='28000',message='invalid_deletion_receipt';end if;
 return jsonb_build_object('status',result);
end;$$;

-- A later, explicitly authorized deletion uses a new receipt and new job.
create or replace function public.carry_account_request_deletion(p_account uuid,p_session uuid,p_subject text,p_audience text,p_encrypted_token text,p_ticket text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare job carry_private.account_deletions; ticket_digest text;
begin
  if p_account is null or p_ticket is null or p_ticket !~ '^[0-9a-f]{64}$' then raise exception 'invalid_deletion_request'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform public.carry_account_require_session(p_account,p_session);
  ticket_digest:=encode(sha256(convert_to(p_ticket,'UTF8')),'hex');
  select * into job from carry_private.account_deletions where account_id=p_account for update;
  if found and job.stage='cancelled' then
    if job.ticket_hash=ticket_digest then raise exception 'deletion_receipt_cancelled';end if;
    delete from carry_private.account_deletions where account_id=p_account;
  elsif found then
    if job.ticket_hash<>ticket_digest then raise exception 'deletion_receipt_mismatch';end if;
    return jsonb_build_object('status',case when job.stage='deleted' then 'deleted' else 'deleting' end);
  end if;
  perform public.carry_account_begin_delete(p_account,p_subject,p_audience,p_encrypted_token);
  insert into carry_private.account_deletions(account_id,ticket_hash,stage) values(p_account,ticket_digest,'revoking');
  return jsonb_build_object('status','deleting');
end;
$$;
