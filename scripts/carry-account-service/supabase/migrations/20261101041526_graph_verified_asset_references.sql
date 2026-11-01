-- Immutable asset references must already name verified account-owned bytes.
create or replace function carry_private.graph_schema() returns jsonb
language sql immutable security invoker set search_path = '' as $schema$
 select '{"trip":{"parents":[],"fields":{"name":{"type":"string","max":500},"destinationCity":{"type":"string","max":2000},"days":{"type":"number","integer":true,"min":0,"max":3650},"dateRange":{"type":"string","max":2000},"departureDate":{"type":"string","format":"date-time","max":64},"isDateless":{"type":"boolean"},"createdAt":{"type":"string","format":"date-time","max":64},"selectedSceneKeys":{"type":"array","max":1000,"item":{"type":"string","max":500}},"dismissedSurpriseNames":{"type":"array","max":1000,"item":{"type":"string","max":500}},"sceneCardDismissed":{"type":"boolean"},"remindersEnabled":{"type":"boolean"},"reminderConfigData":{"type":"string","max":32000},"additionalDestinationsData":{"type":"string","max":64000,"optional":true},"backgroundsData":{"type":"string","max":64000,"optional":true},"backgroundAssetIDs":{"type":"object","max":256,"keyPattern":"^background:[0-9]{1,4}:[0-9]{1,4}$","item":{"type":"string","format":"uuid","max":36},"optional":true},"countryCode":{"type":"string","max":2},"latitude":{"type":"number","min":-90,"max":90},"longitude":{"type":"number","min":-180,"max":180}}},"section":{"parents":["trip"],"fields":{"title":{"type":"string","max":500},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"packingItem":{"parents":["section"],"fields":{"name":{"type":"string","max":500},"quantity":{"type":"number","integer":true,"min":1,"max":1000000},"isPacked":{"type":"boolean"},"isAlert":{"type":"boolean"},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"day":{"parents":["trip"],"fields":{"title":{"type":"string","max":500},"note":{"type":"string","max":16000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"stop":{"parents":["day"],"fields":{"name":{"type":"string","max":500},"latitude":{"type":"number","min":-90,"max":90},"longitude":{"type":"number","min":-180,"max":180},"address":{"type":"string","max":2000},"categoryRaw":{"type":"string","max":100},"plannedStartMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"stayMinutes":{"type":"number","integer":true,"min":0,"max":5256000},"note":{"type":"string","max":16000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000},"costAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"costCurrencyCode":{"type":"string","pattern":"^([A-Z]{3})?$","max":3,"optional":true},"costHomeAmount":{"type":"number","min":-1,"max":1000000000000,"optional":true},"fromPhotos":{"type":"boolean","optional":true},"phone":{"type":"string","max":100,"optional":true},"timeZoneId":{"type":"string","format":"timezone","max":100,"optional":true}}},"transport":{"parents":["day"],"fields":{"modeRaw":{"type":"string","values":["flight","train","bus","ferry","carRental","other"]},"carrier":{"type":"string","max":2000},"number":{"type":"string","max":2000},"fromName":{"type":"string","max":2000},"fromCode":{"type":"string","max":2000},"fromTerminal":{"type":"string","max":2000},"toName":{"type":"string","max":2000},"toCode":{"type":"string","max":2000},"toTerminal":{"type":"string","max":2000},"seat":{"type":"string","max":2000},"confirmationCode":{"type":"string","max":2000},"fromLatitude":{"type":"number","min":-90,"max":90},"fromLongitude":{"type":"number","min":-180,"max":180},"fromTimeZoneId":{"type":"string","format":"timezone","max":100},"toLatitude":{"type":"number","min":-90,"max":90},"toLongitude":{"type":"number","min":-180,"max":180},"toTimeZoneId":{"type":"string","format":"timezone","max":100},"departDayOrder":{"type":"number","integer":true,"min":0,"max":3650},"departLocalMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"arriveDayOrder":{"type":"number","integer":true,"min":0,"max":3650},"arriveLocalMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"note":{"type":"string","max":16000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000},"costAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"costCurrencyCode":{"type":"string","pattern":"^([A-Z]{3})?$","max":3,"optional":true},"costHomeAmount":{"type":"number","min":-1,"max":1000000000000,"optional":true},"aircraftType":{"type":"string","max":2000,"optional":true},"cabinClass":{"type":"string","max":2000,"optional":true},"eticketNumber":{"type":"string","max":2000,"optional":true},"routeName":{"type":"string","max":2000,"optional":true},"coachNumber":{"type":"string","max":2000,"optional":true},"seatClass":{"type":"string","max":2000,"optional":true},"serviceType":{"type":"string","max":2000,"optional":true},"vehicleModel":{"type":"string","max":2000,"optional":true},"licensePlate":{"type":"string","max":2000,"optional":true},"fromAddress":{"type":"string","max":2000,"optional":true},"toAddress":{"type":"string","max":2000,"optional":true},"phone":{"type":"string","max":2000,"optional":true},"distanceMeters":{"type":"number","min":0,"max":10000000000,"optional":true},"durationMinutes":{"type":"number","integer":true,"min":0,"max":5256000,"optional":true},"remindersMuted":{"type":"boolean","optional":true}}},"lodging":{"parents":["trip"],"fields":{"name":{"type":"string","max":500},"address":{"type":"string","max":2000},"latitude":{"type":"number","min":-90,"max":90},"longitude":{"type":"number","min":-180,"max":180},"checkInDayOrder":{"type":"number","integer":true,"min":0,"max":3650},"nights":{"type":"number","integer":true,"min":1,"max":3650},"checkInMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"checkOutMinutes":{"type":"number","integer":true,"min":-1,"max":1439},"confirmationCode":{"type":"string","max":2000},"note":{"type":"string","max":16000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000},"costAmount":{"type":"number","min":0,"max":1000000000000,"optional":true},"costCurrencyCode":{"type":"string","pattern":"^([A-Z]{3})?$","max":3,"optional":true},"costHomeAmount":{"type":"number","min":-1,"max":1000000000000,"optional":true},"phone":{"type":"string","max":100,"optional":true},"timeZoneId":{"type":"string","format":"timezone","max":100,"optional":true},"remindersMuted":{"type":"boolean","optional":true}}},"photo":{"parents":["stop"],"fields":{"assetLocalIdentifier":{"type":"string","max":2000},"thumbnailAssetID":{"type":"string","format":"uuid","max":36,"optional":true},"originalAssetID":{"type":"string","format":"uuid","max":36,"optional":true},"timestamp":{"type":"string","format":"date-time","max":64},"latitude":{"type":"number","min":-90,"max":90},"longitude":{"type":"number","min":-180,"max":180},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"attachment":{"parents":["stop","transport","lodging"],"fields":{"kindRaw":{"type":"string","max":2000},"displayName":{"type":"string","max":2000},"fileName":{"type":"string","max":2000},"utiOrExt":{"type":"string","max":2000},"urlString":{"type":"string","max":2000},"thumbnailAssetID":{"type":"string","format":"uuid","max":36,"optional":true},"fileAssetID":{"type":"string","format":"uuid","max":36,"optional":true},"addedAt":{"type":"string","format":"date-time","max":64},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000}}},"libraryItem":{"parents":[],"fields":{"name":{"type":"string","max":2000},"collectionName":{"type":"string","max":2000},"category":{"type":"string","max":2000},"defaultQuantity":{"type":"number","integer":true,"min":1,"max":1000000},"quantityModeRaw":{"type":"string","values":["fixed","tripDays","everyNDays"]},"quantityIntervalDays":{"type":"number","integer":true,"min":1,"max":1000000},"sortOrder":{"type":"number","integer":true,"min":0,"max":1000000},"createdAt":{"type":"string","format":"date-time","max":64},"updatedAt":{"type":"string","format":"date-time","max":64}}}}'::jsonb;
$schema$;

-- Only actual timezone values inspect the timezone catalog. All validation rules remain intact.
create or replace function carry_private.graph_validate_value(v jsonb, rule jsonb) returns boolean
language plpgsql stable security invoker set search_path = '' as $$
declare item jsonb; s text; n numeric; object_key text;
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
    -- Keep this catalog query in its own PL/pgSQL branch. An InitPlan inside
    -- a boolean expression can run even for ordinary strings without a format.
    if rule->>'format' = 'timezone' and s <> '' then
      if not exists(select 1 from pg_catalog.pg_timezone_names where name=s) then return false; end if;
    end if;
  elsif rule->>'type' = 'number' then
    n := (v #>> '{}')::numeric;
    if n < (rule->>'min')::numeric or n > (rule->>'max')::numeric then return false; end if;
    if rule->>'integer' = 'true' and trunc(n) <> n then return false; end if;
  elsif rule->>'type' = 'object' then
    if (select count(*) from jsonb_object_keys(v)) > (rule->>'max')::int then return false; end if;
    for object_key,item in select key,value from jsonb_each(v) loop
      if rule ? 'keyPattern' and object_key !~ (rule->>'keyPattern') then return false; end if;
      if not carry_private.graph_validate_value(item,rule->'item') then return false; end if;
    end loop;
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


-- The trigger is shared by native, staged and AI graph transactions. Checking
-- the actual stored row also covers child restoration, not only caller fields.
-- The same account lock is used by reserve/verify/cleanup/account deletion.
create function carry_private.graph_require_verified_assets() returns trigger
language plpgsql security invoker set search_path='' as $$
declare refs jsonb:='{}'::jsonb; entry record; asset_id uuid; item carry_private.assets;
  backgrounds jsonb:='[]'::jsonb; expected_slots text[]:='{}'::text[]; background jsonb; position integer:=0; destination integer; filename text;
begin
  if new.deleted_at is not null then return new; end if;
  if tg_op='UPDATE' and new.fields is not distinct from old.fields and old.deleted_at is null then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended(new.account_id::text,0));
  if new.kind='photo' then
    refs:=jsonb_build_object('thumbnail',new.fields->'thumbnailAssetID','original',new.fields->'originalAssetID');
  elsif new.kind='attachment' then
    if coalesce(new.fields->>'fileName','')<>'' and (new.fields->'fileAssetID' is null or new.fields->'fileAssetID'='null'::jsonb) then
      raise exception 'asset_reference_required' using errcode='22023';
    end if;
    refs:=jsonb_build_object('thumbnail',new.fields->'thumbnailAssetID','file',new.fields->'fileAssetID');
  elsif new.kind='trip' then
    if jsonb_typeof(new.fields->'backgroundAssetIDs')='object' then refs:=new.fields->'backgroundAssetIDs'; end if;
    if coalesce(new.fields->>'backgroundsData','')<>'' then
      begin backgrounds:=convert_from(decode(new.fields->>'backgroundsData','base64'),'UTF8')::jsonb;
      exception when others then raise exception 'invalid_background_data' using errcode='22023'; end;
    end if;
    if jsonb_typeof(backgrounds)<>'array' or jsonb_array_length(backgrounds)>256 then
      raise exception 'invalid_background_data' using errcode='22023';
    end if;
    for background in select value from jsonb_array_elements(backgrounds) loop
      if jsonb_typeof(background)<>'object' or coalesce(background->>'source','') not in ('local','unsplash','pexels')
        or (background ? 'destinationIndex' and (jsonb_typeof(background->'destinationIndex')<>'number'
          or background->>'destinationIndex' !~ '^[0-9]{1,4}$')) then
        raise exception 'invalid_background_data' using errcode='22023';
      end if;
      destination:=coalesce((background->>'destinationIndex')::integer,0);
      if background->'localFileName' is not null and background->'localFileName'<>'null'::jsonb then
        filename:=background->>'localFileName';
        if jsonb_typeof(background->'localFileName')<>'string' or octet_length(filename) not between 1 and 255
          or filename in ('.','..') or filename ~ '[/\\]' then raise exception 'invalid_background_data' using errcode='22023'; end if;
        expected_slots:=array_append(expected_slots,'background:'||destination::text||':'||position::text);
      end if;
      position:=position+1;
    end loop;
    if (select count(*) from jsonb_object_keys(refs))<>cardinality(expected_slots)
      or exists(select 1 from unnest(expected_slots) s where not refs ? s) then
      raise exception 'asset_reference_required' using errcode='22023';
    end if;
  end if;
  for entry in select key,value from jsonb_each(refs) where value is not null and value<>'null'::jsonb loop
    if jsonb_typeof(entry.value)<>'string' or (entry.value #>> '{}') !~* '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
      then raise exception 'invalid_asset_reference' using errcode='22023'; end if;
    asset_id:=(entry.value #>> '{}')::uuid;
    select * into item from carry_private.assets where account_id=new.account_id and id=asset_id;
    if not found or item.entity_id<>new.id or item.entity_kind<>new.kind or item.slot<>entry.key
      or item.state<>'verified' or item.verified_version is null then
      raise exception 'asset_reference_unverified' using errcode='22023';
    end if;
    -- Hold provider metadata stable until this graph transaction commits too;
    -- Storage's own metadata writers do not acquire our account advisory lock.
    perform 1 from storage.objects o where o.bucket_id='carry-account-assets'
      and o.name collate "C"=new.account_id::text||'/'||item.id::text||'/'||item.sha256
      and o.version=item.verified_version::text and o.archived_at is null and not o.is_delete_marker for share;
    if not found then
      raise exception 'asset_reference_unverified' using errcode='22023';
    end if;
  end loop;
  return new;
end;
$$;
revoke all on function carry_private.graph_require_verified_assets() from public,anon,authenticated;
grant execute on function carry_private.graph_require_verified_assets() to service_role;
create trigger graph_verified_asset_references
  before insert or update of fields,deleted_at on carry_private.graph_entities
  for each row execute function carry_private.graph_require_verified_assets();
