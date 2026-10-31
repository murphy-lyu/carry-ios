-- Shared business core, accessible only to the reviewed server role. Native
-- sessions and AI grants keep separate authorization boundaries.
create function carry_private.graph_require_active_account(p_account uuid) returns void
language plpgsql security invoker set search_path='' as $$
begin
  if p_account is null then raise exception 'account_unavailable' using errcode='28000';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  if not exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and status='active')
    or exists(select 1 from carry_private.carry_apple_credentials where account_id=p_account and status='deleting')
    then raise exception 'account_unavailable' using errcode='28000';end if;
end;$$;
create or replace function carry_private.graph_apply_core(p_account uuid, p_command jsonb) returns jsonb
language plpgsql security invoker set search_path = '' as $$
<<command>>
declare request uuid; digest bytea; receipt carry_private.graph_receipts; m jsonb;
  entity carry_private.graph_entities; child carry_private.graph_entities;
  entity_id uuid; parent uuid; action text; kind text; base bigint; subtree bigint;
  fields jsonb; versions jsonb; k text; conflicts jsonb; before jsonb;
  results jsonb := '[]'::jsonb; result jsonb; batch uuid; parent_before uuid; start_sequence bigint; start_subtrees jsonb;
begin
  if p_command is null or jsonb_typeof(p_command)<>'object'
    or exists(select 1 from jsonb_object_keys(p_command) as keys(value) where keys.value not in ('requestID','mutations'))
    or jsonb_typeof(p_command->'mutations') is distinct from 'array'
    then raise exception 'invalid_command' using errcode='22023'; end if;
  if octet_length(p_command::text)>16777216 or jsonb_array_length(p_command->'mutations') not between 1 and 20000
    then raise exception 'invalid_command_size' using errcode='22023'; end if;
  request := (p_command->>'requestID')::uuid;
  if request is null then raise exception 'invalid_request_id' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_active_account(p_account);
  insert into carry_private.graph_accounts(account_id) values(p_account) on conflict do nothing;
  select sequence into start_sequence from carry_private.graph_accounts where account_id=p_account;
  digest := sha256(convert_to(p_command::text,'UTF8'));
  select * into receipt from carry_private.graph_receipts where account_id=p_account and request_id=request;
  if found then
    if receipt.digest<>digest then raise exception 'request_id_reused' using errcode='22023'; end if;
    return receipt.result;
  end if;
  -- Capture delete/restore preview baselines before this transaction's own
  -- moves/edits update ancestor metadata. Outside concurrent changes remain
  -- visible here, so this does not weaken the preview's conflict protection.
  select coalesce(jsonb_object_agg(e.id::text,e.subtree_version),'{}'::jsonb)
    into start_subtrees from carry_private.graph_entities e where e.account_id=p_account
      and e.id in(select (x->>'id')::uuid from jsonb_array_elements(p_command->'mutations') x);
  -- Do not allow touching the same entity twice in one logical operation. This
  -- keeps field baselines and undo sources unambiguous.
  if exists(select 1 from jsonb_array_elements(p_command->'mutations') x group by x->>'id' having count(*)>1)
    then raise exception 'duplicate_mutation' using errcode='22023'; end if;
  for m in select value from jsonb_array_elements(p_command->'mutations') loop
    if jsonb_typeof(m)<>'object' or exists(select 1 from jsonb_object_keys(m) as keys(value)
      where keys.value not in ('id','kind','action','baseVersion','baseSubtreeVersion','parentID','fields','fieldVersions'))
      then raise exception 'invalid_mutation' using errcode='22023'; end if;
    entity_id := (m->>'id')::uuid; parent := (m->>'parentID')::uuid;
    kind := m->>'kind'; action := m->>'action';
    if entity_id is null or kind is null or not carry_private.graph_schema() ? kind
      or action is null or action not in ('create','patch','move','delete','restore')
      or jsonb_typeof(m->'baseVersion') is distinct from 'number'
      or (m->>'baseVersion') !~ '^\d+$'
      then raise exception 'invalid_mutation' using errcode='22023'; end if;
    if action in ('create','move') or (action='restore' and m ? 'parentID') then
      if parent is null then
        if jsonb_array_length(carry_private.graph_schema()->command.kind->'parents')>0
          then raise exception 'invalid_parent' using errcode='22023'; end if;
      elsif parent=entity_id or not exists(select 1 from carry_private.graph_entities p
        where p.account_id=p_account and p.id=parent and p.deleted_at is null
          and (carry_private.graph_schema()->command.kind->'parents' ? p.kind)) then
        raise exception 'invalid_parent' using errcode='22023';
      end if;
    end if;
    if action not in ('patch','move') and m ? 'fieldVersions' then raise exception 'invalid_field_versions' using errcode='22023'; end if;
    base := (m->>'baseVersion')::bigint;
    select * into entity from carry_private.graph_entities where account_id=p_account and id=entity_id;
    before := case when found then carry_private.graph_snapshot(entity) else null end;
    if action='create' then
      if base<>0 or entity.id is not null then raise exception 'entity_exists' using errcode='22023'; end if;
      fields := m->'fields'; perform carry_private.graph_validate_fields(kind,fields);
      select coalesce(jsonb_object_agg(key,1),'{}'::jsonb) into versions from jsonb_each(fields);
      insert into carry_private.graph_entities values(p_account,entity_id,kind,parent,1,0,fields,versions,null,null);
    else
      if entity.id is null or entity.kind<>kind then raise exception 'entity_not_found' using errcode='22023'; end if;
      if action<>'restore' and entity.deleted_at is not null then raise exception 'deleted_entity' using errcode='22023'; end if;
      if base<1 or base>entity.version then raise exception 'invalid_version' using errcode='22023'; end if;
      if action in ('patch','move') then
        if jsonb_typeof(m->'fields') is distinct from 'object' or (m->'fields'='{}'::jsonb and action='patch')
          then raise exception 'invalid_patch' using errcode='22023'; end if;
        if action='patch' and m ? 'parentID' then raise exception 'use_move' using errcode='22023'; end if;
        if action='move' and (not m ? 'parentID' or base<>entity.version)
          then raise exception 'move_conflict' using errcode='P0001', detail=before::text; end if;
        if m ? 'fieldVersions' then
          if jsonb_typeof(m->'fieldVersions') is distinct from 'object'
            or exists(select 1 from jsonb_object_keys(m->'fieldVersions') f where not m->'fields' ? f)
            or exists(select 1 from jsonb_object_keys(m->'fields') f where not m->'fieldVersions' ? f)
            or exists(select 1 from jsonb_each(m->'fieldVersions') f where jsonb_typeof(f.value)<>'number' or (f.value #>> '{}') !~ '^\d+$')
            then raise exception 'invalid_field_versions' using errcode='22023'; end if;
          select jsonb_agg(key) into conflicts from jsonb_object_keys(m->'fields') key
            where coalesce((entity.field_versions->>key)::bigint,0)<>(m->'fieldVersions'->>key)::bigint;
        else
          select jsonb_agg(key) into conflicts from jsonb_object_keys(m->'fields') key
            where coalesce((entity.field_versions->>key)::bigint,0)>base;
        end if;
        if conflicts is not null then raise exception 'field_conflict' using errcode='P0001',
          detail=jsonb_build_object('current',before,'fields',conflicts,'proposed',m->'fields')::text; end if;
        fields := entity.fields || (m->'fields'); perform carry_private.graph_validate_fields(kind,fields);
        versions := entity.field_versions;
        for k in select jsonb_object_keys(m->'fields') loop
          versions := versions || jsonb_build_object(k,entity.version+1);
        end loop;
        parent_before := entity.parent_id;
        update carry_private.graph_entities set fields=command.fields,field_versions=versions,version=version+1,
          parent_id=case when action='move' then parent else parent_id end where account_id=p_account and id=entity_id;
        -- Moving a child changes BOTH parents' subtree revisions.
        if action='move' and parent_before is distinct from parent then
          if parent_before is not null then
            perform carry_private.graph_record_ancestor(p_account,parent_before,request);
          end if;
        end if;
      else
        if action='delete' and (m ? 'parentID' or m ? 'fields') then raise exception 'invalid_mutation' using errcode='22023'; end if;
        if action='restore' and m ? 'fields' then
          if jsonb_typeof(m->'fields') is distinct from 'object' then raise exception 'invalid_mutation' using errcode='22023';end if;
          perform carry_private.graph_validate_fields(kind,entity.fields || (m->'fields'));
        end if;
        if jsonb_typeof(m->'baseSubtreeVersion') is distinct from 'number' or (m->>'baseSubtreeVersion') !~ '^\d+$'
          then raise exception 'subtree_version_required' using errcode='22023'; end if;
        subtree := (m->>'baseSubtreeVersion')::bigint;
        if base<>entity.version or subtree<>coalesce((start_subtrees->>entity_id::text)::bigint,-1) then raise exception 'subtree_conflict' using errcode='P0001',detail=before::text; end if;
        if action='restore' and (entity.deleted_at is null or entity.deleted_at<statement_timestamp()-interval '30 days')
          then raise exception 'restore_expired' using errcode='22023'; end if;
        batch := case when action='delete' then gen_random_uuid() else entity.deletion_batch end;
        -- A later independent deletion is never revived by a parent restore.
        for child in with recursive tree as (
          select * from carry_private.graph_entities where account_id=p_account and id=entity_id
          union all select e.* from carry_private.graph_entities e join tree t on e.parent_id=t.id
            where e.account_id=p_account
        ) select * from tree where (action='delete' and deleted_at is null)
          or (action='restore' and deletion_batch=batch) order by id loop
          versions:=child.field_versions;fields:=child.fields;
          if action='restore' and child.id=entity_id and m ? 'fields' then
            fields:=fields || (m->'fields');
            for k in select jsonb_object_keys(m->'fields') loop versions:=versions || jsonb_build_object(k,child.version+1);end loop;
          end if;
          if action='restore' and child.id=entity_id and m ? 'parentID' and child.parent_id is distinct from parent and child.parent_id is not null then
            perform carry_private.graph_record_ancestor(p_account,child.parent_id,request);
          end if;
          update carry_private.graph_entities set version=version+1,fields=command.fields,field_versions=versions,
            parent_id=case when action='restore' and child.id=entity_id and m ? 'parentID' then parent else parent_id end,
            deleted_at=case when action='delete' then statement_timestamp() else null end,
            deletion_batch=case when action='delete' then batch else null end
            where account_id=p_account and id=child.id;
          perform carry_private.graph_record(p_account,child.id,request,carry_private.graph_snapshot(child));
        end loop;
        continue;
      end if;
    end if;
    perform carry_private.graph_record(p_account,entity_id,request,before);
  end loop;
  perform carry_private.graph_check_hierarchy(p_account);
  select coalesce(jsonb_agg(jsonb_build_object('sequence',c.sequence,'entity',c.snapshot,'metadataOnly',c.metadata_only,'previousVersion',c.previous->'version','previousSubtreeVersion',c.previous->'subtreeVersion') order by c.sequence),'[]'::jsonb)
    into results from carry_private.graph_changes c where c.account_id=p_account and c.sequence>start_sequence;
  result := jsonb_build_object('status','saved_to_account','requestID',request,'changes',results,
    'cursor',(select sequence from carry_private.graph_accounts where account_id=p_account));
  insert into carry_private.graph_receipts values(p_account,request,digest,result);
  return result;
end;
$$;

create or replace function carry_private.graph_apply_command(p_account uuid,p_session uuid,p_command jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  return carry_private.graph_apply_core(p_account,p_command);
end;$$;
revoke all on function carry_private.graph_require_active_account(uuid),carry_private.graph_apply_core(uuid,jsonb) from public,anon,authenticated;
grant execute on function carry_private.graph_require_active_account(uuid),carry_private.graph_apply_core(uuid,jsonb) to service_role;

-- Installed only by the server's migration runner. No public RPC or client grant.
create schema if not exists carry_ai;
revoke all on schema carry_ai from public;
create table if not exists carry_ai.records (
  bucket text not null check (bucket in ('client','authorization','grant','code','access','refresh','preview','receipt','undo')),
  id text not null,
  account_id uuid,
  grant_id uuid,
  request_id uuid,
  value jsonb not null check (jsonb_typeof(value) = 'object'),
  primary key (bucket,id)
);
create index if not exists ai_records_account on carry_ai.records(account_id,bucket);
create unique index if not exists ai_preview_request on carry_ai.records(grant_id,request_id) where bucket='preview';
create unique index if not exists ai_receipt_request on carry_ai.records(grant_id,request_id) where bucket='receipt';
create table if not exists carry_ai.rate_limits (
  key text primary key,
  account_id uuid,
  window_id bigint not null,
  count integer not null check (count > 0)
);
alter table carry_ai.records enable row level security;
alter table carry_ai.rate_limits enable row level security;
revoke all on all tables in schema carry_ai from public;
-- Intentionally no anon/authenticated policies. The server role must have only
-- reviewed access to this schema and the validated graph-core entrypoint.

alter table carry_ai.rate_limits add constraint ai_rate_account_user_fk foreign key(account_id) references auth.users(id) on delete cascade;
alter table carry_ai.records add constraint ai_records_account_user_fk foreign key(account_id) references auth.users(id) on delete cascade;
grant usage on schema carry_ai to service_role;
grant select,insert,update,delete on all tables in schema carry_ai to service_role;

-- Register AI owned records in the existing guarded account deletion transaction.
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
        'asset_cleanup_turns','account_deletions','graph_command_stages','graph_command_chunks','graph_rate_buckets')) then raise exception 'unregistered_account_store';end if;
  if exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    join pg_catalog.pg_attribute a on a.attrelid=c.oid
    where n.nspname='carry_ai' and c.relkind in ('r','p') and a.attname='account_id' and not a.attisdropped
      and c.relname not in ('records','rate_limits')) then raise exception 'unregistered_account_store';end if;
  delete from carry_ai.records where account_id=p_account_id;
  delete from carry_ai.rate_limits where account_id=p_account_id;
  delete from carry_private.graph_command_stages where account_id=p_account_id;
  delete from carry_private.graph_rate_buckets where account_id=p_account_id;
  delete from carry_private.graph_accounts where account_id=p_account_id;
  delete from carry_private.asset_budgets where account_id=p_account_id;
  delete from carry_private.asset_rate_buckets where account_id=p_account_id;
  delete from carry_private.carry_account_rate_buckets where account_id=p_account_id;
  delete from carry_private.asset_cleanup_turns where account_id=p_account_id;
end;
$$;
