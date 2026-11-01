-- Account wire date validation; no stored data is rewritten.
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
      -- timestamptz normalizes 24:00 and second 60; native wire decoding
      -- deliberately rejects both. Validate wall-clock components first.
      if substring(s from 12 for 2)::int > 23
        or substring(s from 15 for 2)::int > 59
        or substring(s from 18 for 2)::int > 59 then return false; end if;
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
exception when invalid_datetime_format or datetime_field_overflow or invalid_time_zone_displacement_value or numeric_value_out_of_range then return false;
end;
$$;

revoke all on function carry_private.graph_validate_value(jsonb,jsonb) from public,anon,authenticated;
grant execute on function carry_private.graph_validate_value(jsonb,jsonb) to service_role;
