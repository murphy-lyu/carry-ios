-- Native-only staged commands. Existing ordinary-call bounds remain intact.
alter table carry_private.graph_changes add column metadata_only boolean not null default false;
-- Compound commands compare subtree previews to transaction-start metadata.
-- Keep the original migration immutable; replace only this service-only RPC.
create function carry_private.graph_apply_command(p_account uuid, p_session uuid, p_command jsonb) returns jsonb
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
  perform carry_private.graph_require_session(p_account,p_session);
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
    if action in ('create','move') then
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
            perform carry_private.graph_record(p_account,parent_before,request,null);
          end if;
        end if;
      else
        if m ? 'fields' or m ? 'parentID' then raise exception 'invalid_mutation' using errcode='22023'; end if;
        if jsonb_typeof(m->'baseSubtreeVersion') is distinct from 'number' or (m->>'baseSubtreeVersion') !~ '^\d+$'
          then raise exception 'subtree_version_required' using errcode='22023'; end if;
        subtree := (m->>'baseSubtreeVersion')::bigint;
        if base<>entity.version or subtree<>coalesce((start_subtrees->>entity_id::text)::bigint,-1) then raise exception 'subtree_conflict' using errcode='P0001',detail=before::text; end if;
        if action='restore' and (entity.deleted_at is null or entity.deleted_at<statement_timestamp()-interval '30 days')
          then raise exception 'restore_expired' using errcode='22023'; end if;
        batch := case when action='delete' then request else entity.deletion_batch end;
        -- A later independent deletion is never revived by a parent restore.
        for child in with recursive tree as (
          select * from carry_private.graph_entities where account_id=p_account and id=entity_id
          union all select e.* from carry_private.graph_entities e join tree t on e.parent_id=t.id
            where e.account_id=p_account
        ) select * from tree where (action='delete' and deleted_at is null)
          or (action='restore' and deletion_batch=batch) order by id loop
          update carry_private.graph_entities set version=version+1,
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
  select coalesce(jsonb_agg(jsonb_build_object('sequence',c.sequence,'entity',c.snapshot,'metadataOnly',c.metadata_only) order by c.sequence),'[]'::jsonb)
    into results from carry_private.graph_changes c where c.account_id=p_account and c.sequence>start_sequence;
  result := jsonb_build_object('status','saved_to_account','requestID',request,'changes',results,
    'cursor',(select sequence from carry_private.graph_accounts where account_id=p_account));
  insert into carry_private.graph_receipts values(p_account,request,digest,result);
  return result;
end;
$$;

revoke all on function carry_private.graph_apply_command(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function carry_private.graph_apply_command(uuid,uuid,jsonb) to service_role;

create or replace function public.carry_graph_apply(p_account uuid,p_session uuid,p_command jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if p_command is null or jsonb_typeof(p_command)<>'object' or jsonb_typeof(p_command->'mutations') is distinct from 'array'
    then raise exception 'invalid_command' using errcode='22023';end if;
  if octet_length(p_command::text)>2097152 or jsonb_array_length(p_command->'mutations') not between 1 and 500
    then raise exception 'invalid_command_size' using errcode='22023';end if;
  return carry_private.graph_apply_command(p_account,p_session,p_command);
end;$$;

-- Preserve every sequence while avoiding full parent fields on each child edit.
create or replace function carry_private.graph_record(p_account uuid,p_id uuid,p_request uuid,p_before jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare seq bigint; result jsonb; ancestor_id uuid; ids uuid[]; meta boolean; snapshot_entity carry_private.graph_entities;
begin
  with recursive ancestors as (
    select parent_id from carry_private.graph_entities where account_id=p_account and id=p_id
    union all select e.parent_id from carry_private.graph_entities e join ancestors a on e.id=a.parent_id where e.account_id=p_account
  ) select array_agg(parent_id) filter(where parent_id is not null) into ids from ancestors;
  foreach ancestor_id in array array_prepend(p_id,coalesce(ids,'{}'::uuid[])) loop
    update carry_private.graph_accounts set sequence=sequence+1 where account_id=p_account returning sequence into seq;
    update carry_private.graph_entities set subtree_version=seq where account_id=p_account and id=ancestor_id;
    select * into snapshot_entity from carry_private.graph_entities where account_id=p_account and id=ancestor_id;
    meta:=ancestor_id<>p_id;
    if meta then snapshot_entity.fields:='{}'::jsonb;snapshot_entity.field_versions:='{}'::jsonb;end if;
    result:=carry_private.graph_snapshot(snapshot_entity);
    insert into carry_private.graph_changes(account_id,sequence,entity_id,snapshot,request_id,previous,metadata_only)
      values(p_account,seq,ancestor_id,result,p_request,case when not meta then p_before else null end,meta);
  end loop;
  select carry_private.graph_snapshot(e) into result from carry_private.graph_entities e where account_id=p_account and id=p_id;
  return result;
end;$$;

create or replace function public.carry_graph_pull(p_account uuid, p_session uuid, p_cursor bigint, p_limit integer default 100) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare head bigint; changes jsonb; cursor bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  select coalesce(max(sequence),0) into head from carry_private.graph_accounts where account_id=p_account;
  if p_cursor is null or p_cursor<0 or p_cursor>head or p_limit is null or p_limit not between 1 and 500
    then raise exception 'invalid_cursor' using errcode='22023'; end if;
  with candidates as (
    select sequence,jsonb_build_object('sequence',sequence,'entity',snapshot,'metadataOnly',metadata_only) as value
    from carry_private.graph_changes where account_id=p_account and sequence>p_cursor order by sequence limit p_limit
  ),bounded as (
    select sequence,value,sum(octet_length(value::text)) over(order by sequence) as bytes from candidates
  ) select coalesce(jsonb_agg(value order by sequence),'[]'::jsonb),coalesce(max(sequence),p_cursor)
    into changes,cursor from bounded where bytes<=4194304 or sequence=p_cursor+1;
  return jsonb_build_object('changes',changes,'cursor',cursor,'hasMore',cursor<head);
end;
$$;

create table carry_private.graph_command_stages (
  account_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,total_chunks integer not null check(total_chunks between 1 and 40),
  mutation_count integer not null check(mutation_count between 1 and 20000),
  expires_at timestamptz not null default statement_timestamp()+interval '1 hour',
  primary key(account_id,request_id)
);
create table carry_private.graph_command_chunks (
  account_id uuid not null,request_id uuid not null,chunk_index integer not null check(chunk_index between 0 and 39),
  mutations jsonb not null,byte_count integer not null check(byte_count between 1 and 2097152),
  primary key(account_id,request_id,chunk_index),
  foreign key(account_id,request_id) references carry_private.graph_command_stages(account_id,request_id) on delete cascade
);
create index graph_command_stage_expiry on carry_private.graph_command_stages(expires_at);
alter table carry_private.graph_command_stages enable row level security;
alter table carry_private.graph_command_chunks enable row level security;
revoke all on carry_private.graph_command_stages,carry_private.graph_command_chunks from public,anon,authenticated;
grant select,insert,update,delete on carry_private.graph_command_stages,carry_private.graph_command_chunks to service_role;

create function public.carry_graph_stage(p_account uuid,p_session uuid,p_request uuid,p_index integer,p_chunks integer,p_count integer,p_mutations jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare stage carry_private.graph_command_stages; previous jsonb; size integer;
begin
  if p_request is null or p_index is null or p_chunks is null or p_chunks not between 1 and 40
    or p_index<0 or p_index>=p_chunks or p_count is null or p_count not between 1 and 20000
    or p_mutations is null or jsonb_typeof(p_mutations)<>'array' then raise exception 'invalid_stage' using errcode='22023';end if;
  size:=octet_length(p_mutations::text);
  if size>2097152 or jsonb_array_length(p_mutations) not between 1 and 500 then raise exception 'invalid_stage_size' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  delete from carry_private.graph_command_stages where account_id=p_account and expires_at<=statement_timestamp();
  select * into stage from carry_private.graph_command_stages where account_id=p_account and request_id=p_request for update;
  if not found then
    if (select count(*) from carry_private.graph_command_stages where account_id=p_account)>=2
      then raise exception 'stage_budget_exceeded';end if;
    insert into carry_private.graph_command_stages(account_id,request_id,total_chunks,mutation_count) values(p_account,p_request,p_chunks,p_count)
      returning * into stage;
  elsif stage.total_chunks<>p_chunks or stage.mutation_count<>p_count then raise exception 'request_id_reused' using errcode='22023';end if;
  select mutations into previous from carry_private.graph_command_chunks where account_id=p_account and request_id=p_request and chunk_index=p_index;
  if found then
    if previous<>p_mutations then raise exception 'request_id_reused' using errcode='22023';end if;
  else
    if coalesce((select sum(byte_count) from carry_private.graph_command_chunks where account_id=p_account and request_id=p_request),0)+size>16777000
      then raise exception 'stage_budget_exceeded';end if;
    insert into carry_private.graph_command_chunks values(p_account,p_request,p_index,p_mutations,size);
  end if;
  return jsonb_build_object('status','staged','requestID',p_request,'chunkIndex',p_index);
end;$$;

create function carry_private.compact_graph_receipt(receipt jsonb)
returns jsonb language sql immutable security invoker set search_path='' as $$
  select jsonb_build_object('status',receipt->>'status','requestID',receipt->>'requestID',
    'cursor',receipt->'cursor','changeCount',jsonb_array_length(receipt->'changes'))
$$;
revoke all on function carry_private.compact_graph_receipt(jsonb) from public,anon,authenticated;
grant execute on function carry_private.compact_graph_receipt(jsonb) to service_role;

create function public.carry_graph_apply_compact(p_account uuid,p_session uuid,p_command jsonb)
returns jsonb language sql security invoker set search_path='' as $$
  select carry_private.compact_graph_receipt(public.carry_graph_apply(p_account,p_session,p_command))
$$;

create function public.carry_graph_commit_stage(p_account uuid,p_session uuid,p_request uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare stage carry_private.graph_command_stages; combined jsonb; result jsonb; failure_code text; failure_message text; failure_detail text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  select * into stage from carry_private.graph_command_stages where account_id=p_account and request_id=p_request for update;
  if not found or stage.expires_at<=statement_timestamp() then raise exception 'stage_unavailable' using errcode='22023';end if;
  if (select count(*) from carry_private.graph_command_chunks where account_id=p_account and request_id=p_request)<>stage.total_chunks
    then raise exception 'stage_incomplete' using errcode='22023';end if;
  select jsonb_agg(m.value order by c.chunk_index,m.position) into combined
    from carry_private.graph_command_chunks c cross join lateral jsonb_array_elements(c.mutations) with ordinality m(value,position)
    where c.account_id=p_account and c.request_id=p_request;
  if jsonb_array_length(combined)<>stage.mutation_count then raise exception 'stage_incomplete' using errcode='22023';end if;
  begin
    result:=carry_private.graph_apply_command(p_account,p_session,jsonb_build_object('requestID',p_request,'mutations',combined));
  exception when others then
    get stacked diagnostics failure_code=returned_sqlstate,failure_message=message_text,failure_detail=pg_exception_detail;
    delete from carry_private.graph_command_stages where account_id=p_account and request_id=p_request;
    return jsonb_build_object('failure',jsonb_build_object('code',failure_code,'message',failure_message,'details',failure_detail));
  end;
  delete from carry_private.graph_command_stages where account_id=p_account and request_id=p_request;
  return carry_private.compact_graph_receipt(result);
end;$$;

-- Immutable results, not a later pull that may include unrelated newer edits.
-- Page by count AND bytes: large fields on separate roots remain bounded.
create function public.carry_graph_receipt_page(p_account uuid,p_session uuid,p_request uuid,p_offset integer,p_limit integer default 500)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare receipt jsonb; items jsonb; total integer; next_offset integer;
begin
  perform carry_private.graph_require_session(p_account,p_session);
  if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 500 then raise exception 'invalid_receipt_page' using errcode='22023';end if;
  select result into receipt from carry_private.graph_receipts where account_id=p_account and request_id=p_request;
  if not found then raise exception 'receipt_not_found' using errcode='22023';end if;
  total:=jsonb_array_length(receipt->'changes');
  if p_offset>total then raise exception 'invalid_receipt_page' using errcode='22023';end if;
  with candidates as (
    select value,position,octet_length(value::text) as size from jsonb_array_elements(receipt->'changes') with ordinality e(value,position)
      where position>p_offset and position<=p_offset+p_limit
  ),bounded as (
    select value,position,sum(size) over(order by position) as bytes from candidates
  ) select coalesce(jsonb_agg(value order by position),'[]'::jsonb) into items from bounded where bytes<=4194304 or position=p_offset+1;
  next_offset:=p_offset+jsonb_array_length(items);
  return jsonb_build_object('requestID',p_request,'cursor',receipt->'cursor','changes',items,
    'nextOffset',next_offset,'hasMore',next_offset<total,'changeCount',total);
end;$$;

create table carry_private.graph_rate_buckets (
  account_id uuid not null references auth.users(id) on delete cascade,
  bucket text not null check(bucket in ('requests','writes')),
  window_start timestamptz not null,requests integer not null,
  primary key(account_id,bucket)
);
alter table carry_private.graph_rate_buckets enable row level security;
revoke all on carry_private.graph_rate_buckets from public,anon,authenticated;
grant select,insert,update,delete on carry_private.graph_rate_buckets to service_role;
create function public.carry_graph_rate_limit(p_account uuid,p_session uuid,p_bucket text)
returns boolean language plpgsql security invoker set search_path='' as $$
declare n integer; cap integer;
begin
  perform carry_private.graph_require_session(p_account,p_session);
  if p_bucket not in ('requests','writes') or p_bucket is null then raise exception 'invalid_rate_bucket' using errcode='22023';end if;
  cap:=case when p_bucket='writes' then 120 else 1200 end;
  insert into carry_private.graph_rate_buckets as b values(p_account,p_bucket,statement_timestamp(),1)
    on conflict(account_id,bucket) do update set
      requests=case when b.window_start<statement_timestamp()-interval '1 minute' then 1 else least(b.requests+1,cap+1) end,
      window_start=case when b.window_start<statement_timestamp()-interval '1 minute' then statement_timestamp() else b.window_start end
    returning requests into n;
  return n<=cap;
end;$$;

revoke all on function public.carry_graph_stage(uuid,uuid,uuid,integer,integer,integer,jsonb),
 public.carry_graph_apply_compact(uuid,uuid,jsonb),public.carry_graph_commit_stage(uuid,uuid,uuid),
 public.carry_graph_receipt_page(uuid,uuid,uuid,integer,integer),public.carry_graph_rate_limit(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.carry_graph_stage(uuid,uuid,uuid,integer,integer,integer,jsonb),
 public.carry_graph_apply_compact(uuid,uuid,jsonb),public.carry_graph_commit_stage(uuid,uuid,uuid),
 public.carry_graph_receipt_page(uuid,uuid,uuid,integer,integer),public.carry_graph_rate_limit(uuid,uuid,text) to service_role;

-- Register new owned stores before allowing account purge.
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
  delete from carry_private.graph_command_stages where account_id=p_account_id;
  delete from carry_private.graph_rate_buckets where account_id=p_account_id;
  delete from carry_private.graph_accounts where account_id=p_account_id;
  delete from carry_private.asset_budgets where account_id=p_account_id;
  delete from carry_private.asset_rate_buckets where account_id=p_account_id;
  delete from carry_private.carry_account_rate_buckets where account_id=p_account_id;
  delete from carry_private.asset_cleanup_turns where account_id=p_account_id;
end;
$$;
