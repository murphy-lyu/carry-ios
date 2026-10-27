create function carry_private.graph_schema() returns jsonb
language sql immutable security invoker set search_path = '' as $schema$
 select '{"trip":{"parents":[],"fields":{"name":{"type":"string","max":500},"destinationCity":{"type":"string","max":2000},"days":{"type":"number","integer":true,"min":0,"max":3650},"dateRange":{"type":"string","max":2000},"departureDate":{"type":"string","format":"date-time","max":64},"isDateless":{"type":"boolean"},"createdAt":{"type":"string","format":"date-time","max":64},"selectedSceneKeys":{"type":"array","max":1000,"item":{"type":"string","max":500}},"dismissedSurpriseNames":{"type":"array","max":1000,"item":{"type":"string","max":500}},"sceneCardDismissed":{"type":"boolean"},"remindersEnabled":{"type":"boolean"},"reminderConfigData":{"type":"string","max":32000},"additionalDestinationsData":{"type":"string","max":64000,"optional":true},"backgroundsData":{"type":"string","max":64000,"optional":true},"countryCode":{"type":"string","max":2},"latitude":{"type":"number","min":-90,"max":90},"longitude":{"type":"number","min":-180,"max":180}}},"section":{"parents":["trip"],"fields":{"title":{"type":"string","max":500},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"packingItem":{"parents":["section"],"fields":{"name":{"type":"string","max":500},"quantity":{"type":"number","integer":true,"min":1,"max":1000000},"isPacked":{"type":"boolean"},"isAlert":{"type":"boolean"},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"day":{"parents":["trip"],"fields":{"title":{"type":"string","max":500},"note":{"type":"string","max":16000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"stop":{"parents":["day"],"fields":{"name":{"type":"string","max":500},"latitude":{"type":"number","min":-90,"max":90},"longitude":{"type":"number","min":-180,"max":180},"address":{"type":"string","max":2000},"categoryRaw":{"type":"string","max":100},"plannedStartMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"stayMinutes":{"type":"number","integer":true,"min":0,"max":5256000},"note":{"type":"string","max":16000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000},"costAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"costCurrencyCode":{"type":"string","pattern":"^[A-Z]{3}$","max":3,"optional":true},"costHomeAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"fromPhotos":{"type":"boolean","optional":true},"phone":{"type":"string","max":100,"optional":true},"timeZoneId":{"type":"string","format":"timezone","max":100,"optional":true}}},"transport":{"parents":["day"],"fields":{"modeRaw":{"type":"string","values":["flight","train","bus","ferry","carRental","other"]},"carrier":{"type":"string","max":2000},"number":{"type":"string","max":2000},"fromName":{"type":"string","max":2000},"fromCode":{"type":"string","max":2000},"fromTerminal":{"type":"string","max":2000},"toName":{"type":"string","max":2000},"toCode":{"type":"string","max":2000},"toTerminal":{"type":"string","max":2000},"seat":{"type":"string","max":2000},"confirmationCode":{"type":"string","max":2000},"fromLatitude":{"type":"number","min":-90,"max":90},"fromLongitude":{"type":"number","min":-180,"max":180},"fromTimeZoneId":{"type":"string","format":"timezone","max":100},"toLatitude":{"type":"number","min":-90,"max":90},"toLongitude":{"type":"number","min":-180,"max":180},"toTimeZoneId":{"type":"string","format":"timezone","max":100},"departDayOrder":{"type":"number","integer":true,"min":0,"max":3650},"departLocalMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"arriveDayOrder":{"type":"number","integer":true,"min":0,"max":3650},"arriveLocalMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"note":{"type":"string","max":16000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000},"costAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"costCurrencyCode":{"type":"string","pattern":"^[A-Z]{3}$","max":3,"optional":true},"costHomeAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"aircraftType":{"type":"string","max":2000,"optional":true},"cabinClass":{"type":"string","max":2000,"optional":true},"eticketNumber":{"type":"string","max":2000,"optional":true},"routeName":{"type":"string","max":2000,"optional":true},"coachNumber":{"type":"string","max":2000,"optional":true},"seatClass":{"type":"string","max":2000,"optional":true},"serviceType":{"type":"string","max":2000,"optional":true},"vehicleModel":{"type":"string","max":2000,"optional":true},"licensePlate":{"type":"string","max":2000,"optional":true},"fromAddress":{"type":"string","max":2000,"optional":true},"toAddress":{"type":"string","max":2000,"optional":true},"phone":{"type":"string","max":2000,"optional":true},"distanceMeters":{"type":"number","min":0,"max":10000000000,"optional":true},"durationMinutes":{"type":"number","integer":true,"min":0,"max":5256000,"optional":true},"remindersMuted":{"type":"boolean","optional":true}}},"lodging":{"parents":["trip"],"fields":{"name":{"type":"string","max":500},"address":{"type":"string","max":2000},"latitude":{"type":"number","min":-90,"max":90},"longitude":{"type":"number","min":-180,"max":180},"checkInDayOrder":{"type":"number","integer":true,"min":0,"max":3650},"nights":{"type":"number","integer":true,"min":1,"max":3650},"checkInMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"checkOutMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"confirmationCode":{"type":"string","max":2000},"note":{"type":"string","max":16000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000},"costAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"costCurrencyCode":{"type":"string","pattern":"^[A-Z]{3}$","max":3,"optional":true},"costHomeAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"phone":{"type":"string","max":100,"optional":true},"timeZoneId":{"type":"string","format":"timezone","max":100,"optional":true},"remindersMuted":{"type":"boolean","optional":true}}},"photo":{"parents":["stop"],"fields":{"assetLocalIdentifier":{"type":"string","max":2000},"thumbnailAssetID":{"type":"string","format":"uuid","max":36},"timestamp":{"type":"string","format":"date-time","max":64},"latitude":{"type":"number","min":-90,"max":90},"longitude":{"type":"number","min":-180,"max":180},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"attachment":{"parents":["stop","transport","lodging"],"fields":{"kindRaw":{"type":"string","max":2000},"displayName":{"type":"string","max":2000},"fileName":{"type":"string","max":2000},"utiOrExt":{"type":"string","max":2000},"urlString":{"type":"string","max":2000},"thumbnailAssetID":{"type":"string","format":"uuid","max":36,"optional":true},"fileAssetID":{"type":"string","format":"uuid","max":36,"optional":true},"addedAt":{"type":"string","format":"date-time","max":64},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"libraryItem":{"parents":[],"fields":{"name":{"type":"string","max":2000},"collectionName":{"type":"string","max":2000},"category":{"type":"string","max":2000},"defaultQuantity":{"type":"number","integer":true,"min":1,"max":1000000},"quantityModeRaw":{"type":"string","values":["fixed","tripDays","everyNDays"]},"quantityIntervalDays":{"type":"number","integer":true,"min":1,"max":1000000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000},"createdAt":{"type":"string","format":"date-time","max":64},"updatedAt":{"type":"string","format":"date-time","max":64}}}}'::jsonb;
$schema$;
-- Private graph storage. No direct client SQL grants and no public definer RPCs.
create table carry_private.graph_accounts (
  account_id uuid primary key references auth.users(id) on delete cascade,
  sequence bigint not null default 0 check(sequence >= 0)
);
create table carry_private.graph_entities (
  account_id uuid not null references carry_private.graph_accounts(account_id) on delete cascade,
  id uuid not null, kind text not null, parent_id uuid,
  version bigint not null check(version > 0), subtree_version bigint not null,
  fields jsonb not null, field_versions jsonb not null,
  deleted_at timestamptz, deletion_batch uuid,
  primary key(account_id, id),
  foreign key(account_id, parent_id) references carry_private.graph_entities(account_id, id)
);
create index graph_entities_parent on carry_private.graph_entities(account_id, parent_id);
create table carry_private.graph_changes (
  account_id uuid not null references carry_private.graph_accounts(account_id) on delete cascade,
  sequence bigint not null, entity_id uuid not null, snapshot jsonb not null,
  request_id uuid not null, previous jsonb,
  primary key(account_id, sequence)
);
create table carry_private.graph_receipts (
  account_id uuid not null references carry_private.graph_accounts(account_id) on delete cascade,
  request_id uuid not null, digest bytea not null, result jsonb not null,
  primary key(account_id, request_id)
);
alter table carry_private.graph_accounts enable row level security;
alter table carry_private.graph_entities enable row level security;
alter table carry_private.graph_changes enable row level security;
alter table carry_private.graph_receipts enable row level security;
revoke all on carry_private.graph_accounts, carry_private.graph_entities,
  carry_private.graph_changes, carry_private.graph_receipts from public, anon, authenticated;
grant select, insert, update, delete on carry_private.graph_accounts, carry_private.graph_entities,
  carry_private.graph_changes, carry_private.graph_receipts to service_role;

-- Only this private predicate needs Auth's session table privilege. It is never
-- exposed to Data API clients. Session ID and account originate from a verified
-- bearer, not from the request's JSON. Revocation is checked on every transaction.
create function carry_private.graph_require_session(p_account uuid, p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_account is null or p_session is null or not exists (
    select 1 from auth.sessions where id=p_session and user_id=p_account
      and oauth_client_id is null
      and (not_after is null or not_after > statement_timestamp())
  ) then raise exception using message='session_expired', errcode='28000'; end if;
  if not exists(select 1 from carry_private.carry_apple_credentials
    where account_id=p_account and status='active') or exists (
    select 1 from carry_private.carry_apple_credentials where account_id=p_account and status='deleting'
  ) then raise exception using message='account_unavailable', errcode='28000'; end if;
end;
$$;

create function carry_private.graph_validate_value(v jsonb, rule jsonb) returns boolean
language plpgsql stable security invoker set search_path = '' as $$
declare item jsonb; s text; n numeric;
begin
  if v = 'null'::jsonb then return coalesce((rule->>'optional')::boolean,false); end if;
  if v is null or jsonb_typeof(v) <> rule->>'type' then return false; end if;
  if rule->>'type' = 'string' then
    s := v #>> '{}';
    if length(s) > (rule->>'max')::int then return false; end if;
    if rule ? 'values' and not ((rule->'values') ? s) then return false; end if;
    if rule ? 'pattern' and s !~ (rule->>'pattern') then return false; end if;
    if rule->>'format' = 'uuid' and s !~* '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' then return false; end if;
    if rule->>'format' = 'date-time' then
      if s !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' then return false; end if;
      perform s::timestamptz;
    end if;
    if rule->>'format' = 'timezone' and s <> '' and not exists (
      select 1 from pg_catalog.pg_timezone_names where name=s
    ) then return false; end if;
  elsif rule->>'type' = 'number' then
    n := (v #>> '{}')::numeric;
    if n < (rule->>'min')::numeric or n > (rule->>'max')::numeric then return false; end if;
    if rule->>'integer' = 'true' and trunc(n) <> n then return false; end if;
  elsif rule->>'type' = 'array' then
    if jsonb_array_length(v) > (rule->>'max')::int then return false; end if;
    for item in select value from jsonb_array_elements(v) loop
      if not carry_private.graph_validate_value(item,rule->'item') then return false; end if;
    end loop;
  end if;
  return true;
exception when invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then return false;
end;
$$;

create function carry_private.graph_validate_fields(p_kind text, p_fields jsonb) returns void
language plpgsql stable security invoker set search_path = '' as $$
declare definition jsonb; k text; rule jsonb;
begin
  definition := carry_private.graph_schema()->p_kind->'fields';
  if definition is null or jsonb_typeof(p_fields) is distinct from 'object' or octet_length(p_fields::text)>262144
    then raise exception 'invalid_fields' using errcode='22023'; end if;
  for k in select jsonb_object_keys(p_fields) loop
    if not definition ? k then raise exception 'unknown_field' using errcode='22023'; end if;
  end loop;
  for k, rule in select key,value from jsonb_each(definition) loop
    if not p_fields ? k and coalesce((rule->>'optional')::boolean,false) then continue; end if;
    if not carry_private.graph_validate_value(p_fields->k,rule)
      then raise exception 'invalid_field' using errcode='22023',detail=k; end if;
  end loop;
  if p_fields ? 'costAmount' and (p_fields->'costAmount' <> 'null'::jsonb) and
    (not p_fields ? 'costCurrencyCode' or p_fields->'costCurrencyCode'='null'::jsonb)
    then raise exception 'cost_currency_required' using errcode='22023'; end if;
end;
$$;

create function carry_private.graph_snapshot(e carry_private.graph_entities) returns jsonb
language sql immutable security invoker set search_path = '' as $$
  select jsonb_build_object('id',e.id,'kind',e.kind,'parentID',e.parent_id,'version',e.version,
    'subtreeVersion',e.subtree_version,'fields',e.fields,'fieldVersions',e.field_versions,
    'deletedAt',e.deleted_at,'deletionBatch',e.deletion_batch);
$$;

-- A change and its account-local sequence are in the SAME transaction. A global
-- identity/sequence would let concurrent commits make a cursor skip late commits.
create function carry_private.graph_record(p_account uuid, p_id uuid, p_request uuid, p_before jsonb) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare seq bigint; result jsonb; ancestor_id uuid; ids uuid[];
begin
  with recursive ancestors as (
    select parent_id from carry_private.graph_entities where account_id=p_account and id=p_id
    union all select e.parent_id from carry_private.graph_entities e join ancestors a on e.id=a.parent_id
      where e.account_id=p_account
  ) select array_agg(parent_id) filter(where parent_id is not null) into ids from ancestors;
  -- Parent metadata changes also need durable change events. Otherwise a device
  -- could receive the child but retain a stale delete-preview revision forever.
  foreach ancestor_id in array array_prepend(p_id,coalesce(ids,'{}'::uuid[])) loop
    update carry_private.graph_accounts set sequence=sequence+1 where account_id=p_account returning sequence into seq;
    update carry_private.graph_entities set subtree_version=seq where account_id=p_account and id=ancestor_id;
    select carry_private.graph_snapshot(e) into result from carry_private.graph_entities e where account_id=p_account and id=ancestor_id;
    insert into carry_private.graph_changes values(p_account,seq,ancestor_id,result,p_request,
      case when ancestor_id=p_id then p_before else null end);
  end loop;
  select carry_private.graph_snapshot(e) into result from carry_private.graph_entities e where account_id=p_account and id=p_id;
  return result;
end;
$$;

create function carry_private.graph_check_hierarchy(p_account uuid) returns void
language plpgsql stable security invoker set search_path = '' as $$
begin
  if exists(select 1 from carry_private.graph_entities e
    left join carry_private.graph_entities p on p.account_id=e.account_id and p.id=e.parent_id
    where e.account_id=p_account and e.deleted_at is null and (
      (e.parent_id is null and jsonb_array_length(carry_private.graph_schema()->e.kind->'parents')>0)
      or (e.parent_id is not null and (p.id is null or p.deleted_at is not null
        or not (carry_private.graph_schema()->e.kind->'parents' ? p.kind)))
    )) then raise exception 'invalid_parent' using errcode='22023'; end if;
  -- Day moves and shortening a trip are validated against the final transaction,
  -- so a coordinated move can succeed and a destructive partial edit cannot.
  if exists (
    select 1 from carry_private.graph_entities e join carry_private.graph_entities trip
      on trip.account_id=e.account_id and trip.id=e.parent_id
    where e.account_id=p_account and e.deleted_at is null and trip.kind='trip' and (
      (e.kind='day' and (e.fields->>'sortOrder')::int > case when (trip.fields->>'isDateless')::boolean then 0 else (trip.fields->>'days')::int end)
      or (e.kind='lodging' and ((trip.fields->>'isDateless')::boolean
        or (e.fields->>'checkInDayOrder')::int+(e.fields->>'nights')::int > (trip.fields->>'days')::int))
    )
  ) then raise exception 'trip_date_impact' using errcode='22023'; end if;
  if exists(
    select 1 from carry_private.graph_entities e join carry_private.graph_entities d on d.account_id=e.account_id and d.id=e.parent_id
      join carry_private.graph_entities trip on trip.account_id=d.account_id and trip.id=d.parent_id
    where e.account_id=p_account and e.deleted_at is null and e.kind='transport' and (
      (e.fields->>'departDayOrder')::int<>(d.fields->>'sortOrder')::int
      or (e.fields->>'arriveDayOrder')::int>(trip.fields->>'days')::int
    )
  ) then raise exception 'transport_date_impact' using errcode='22023'; end if;
  if exists(select 1 from carry_private.graph_entities where account_id=p_account and deleted_at is null and kind='day'
    group by parent_id,fields->>'sortOrder' having count(*)>1)
    then raise exception 'duplicate_day' using errcode='22023'; end if;
end;
$$;

create function public.carry_graph_apply(p_account uuid, p_session uuid, p_command jsonb) returns jsonb
language plpgsql security invoker set search_path = '' as $$
<<command>>
declare request uuid; digest bytea; receipt carry_private.graph_receipts; m jsonb;
  entity carry_private.graph_entities; child carry_private.graph_entities;
  entity_id uuid; parent uuid; action text; kind text; base bigint; subtree bigint;
  fields jsonb; versions jsonb; k text; conflicts jsonb; before jsonb;
  results jsonb := '[]'::jsonb; result jsonb; batch uuid; parent_before uuid; start_sequence bigint;
begin
  if p_command is null or jsonb_typeof(p_command)<>'object'
    or exists(select 1 from jsonb_object_keys(p_command) as keys(value) where keys.value not in ('requestID','mutations'))
    or jsonb_typeof(p_command->'mutations') is distinct from 'array'
    then raise exception 'invalid_command' using errcode='22023'; end if;
  if octet_length(p_command::text)>2097152 or jsonb_array_length(p_command->'mutations') not between 1 and 500
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
        if base<>entity.version or subtree<>entity.subtree_version then raise exception 'subtree_conflict' using errcode='P0001',detail=before::text; end if;
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
          results := results || jsonb_build_array(carry_private.graph_record(p_account,child.id,request,carry_private.graph_snapshot(child)));
        end loop;
        continue;
      end if;
    end if;
    results := results || jsonb_build_array(carry_private.graph_record(p_account,entity_id,request,before));
  end loop;
  perform carry_private.graph_check_hierarchy(p_account);
  select coalesce(jsonb_agg(jsonb_build_object('sequence',c.sequence,'entity',c.snapshot) order by c.sequence),'[]'::jsonb)
    into results from carry_private.graph_changes c where c.account_id=p_account and c.sequence>start_sequence;
  result := jsonb_build_object('status','saved_to_account','requestID',request,'changes',results,
    'cursor',(select sequence from carry_private.graph_accounts where account_id=p_account));
  insert into carry_private.graph_receipts values(p_account,request,digest,result);
  return result;
end;
$$;

create function public.carry_graph_pull(p_account uuid, p_session uuid, p_cursor bigint, p_limit integer default 100) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare head bigint; changes jsonb; cursor bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  select coalesce(max(sequence),0) into head from carry_private.graph_accounts where account_id=p_account;
  if p_cursor is null or p_cursor<0 or p_cursor>head or p_limit is null or p_limit not between 1 and 500
    then raise exception 'invalid_cursor' using errcode='22023'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('sequence',c.sequence,'entity',c.snapshot) order by c.sequence),'[]'::jsonb),coalesce(max(c.sequence),p_cursor)
    into changes,cursor from (select * from carry_private.graph_changes where account_id=p_account and sequence>p_cursor order by sequence limit p_limit) c;
  return jsonb_build_object('changes',changes,'cursor',cursor,'hasMore',cursor<head);
end;
$$;

revoke all on function carry_private.graph_schema(),carry_private.graph_require_session(uuid,uuid),
  carry_private.graph_validate_value(jsonb,jsonb),carry_private.graph_validate_fields(text,jsonb),
  carry_private.graph_snapshot(carry_private.graph_entities),carry_private.graph_record(uuid,uuid,uuid,jsonb),
  carry_private.graph_check_hierarchy(uuid),public.carry_graph_apply(uuid,uuid,jsonb),public.carry_graph_pull(uuid,uuid,bigint,integer)
  from public,anon,authenticated;
grant execute on function carry_private.graph_schema(),carry_private.graph_require_session(uuid,uuid),
  carry_private.graph_validate_value(jsonb,jsonb),carry_private.graph_validate_fields(text,jsonb),
  carry_private.graph_snapshot(carry_private.graph_entities),carry_private.graph_record(uuid,uuid,uuid,jsonb),
  carry_private.graph_check_hierarchy(uuid),public.carry_graph_apply(uuid,uuid,jsonb),public.carry_graph_pull(uuid,uuid,bigint,integer)
  to service_role;
