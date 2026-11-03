-- Private aggregate diagnostics: no identifiers, addresses, tokens or trip data.
create table if not exists carry_ai.auth_event_counts (
  day bigint not null,
  event text not null check(event in ('refresh_ok','refresh_replay','refresh_missing','refresh_invalid','refresh_scope','refresh_unavailable','register_ok','register_rejected','token_ok','token_rejected','oauth_unavailable','oauth_limited')),
  count bigint not null check(count>0),
  primary key(day,event)
);
alter table carry_ai.auth_event_counts enable row level security;
revoke all on carry_ai.auth_event_counts from public;
create or replace function carry_ai.record_auth_event(p_event text,p_now bigint)
returns void language plpgsql security invoker set search_path='' as $$
begin
  if p_now is null or p_now not between 0 and 9007199254740991 then raise exception 'invalid_event_time'; end if;
  insert into carry_ai.auth_event_counts(day,event,count) values(p_now/86400000,p_event,1)
    on conflict(day,event) do update set count=carry_ai.auth_event_counts.count+1;
end;
$$;
revoke all on function carry_ai.record_auth_event(text,bigint) from public;

-- Registry lock must precede row locks, matching DCR and authorization creation.
-- Used clients can retire only after all live credentials/replay evidence expire.
create or replace function carry_ai.retire_clients(p_now bigint,p_limit integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare unused integer; used integer;
begin
  if p_now is null or p_now not between 0 and 9007199254740991 or p_limit is null or p_limit not between 1 and 1000 then raise exception 'invalid_maintenance_input'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('carry-ai-client-registry',0));
  with candidates as (
    select c.id,c.value->>'usedAt' is not null as used
    from carry_ai.records c where c.bucket='client' and c.value->>'registryVersion'='1'
      and (c.value->>'createdAt')::bigint<p_now-86400000
      and not exists(select 1 from carry_ai.records r where r.bucket='authorization' and r.value->>'clientID'=c.id)
      and not exists(select 1 from carry_ai.records r where r.bucket='code' and r.value->>'clientID'=c.id)
      and (
        (c.value->>'usedAt' is null and not exists(select 1 from carry_ai.records r where r.bucket='grant' and r.value->>'clientID'=c.id))
        or (c.value->>'usedAt' is not null
          and greatest((c.value->>'createdAt')::bigint,(c.value->>'usedAt')::bigint,
            coalesce((select max(case when g.value->>'revokedAt' is not null then (g.value->>'revokedAt')::bigint else (g.value->>'expiresAt')::bigint end)
              from carry_ai.records g where g.bucket='grant' and g.value->>'clientID'=c.id),0))<p_now-7776000000
          and not exists(select 1 from carry_ai.records g where g.bucket='grant' and g.value->>'clientID'=c.id
            and ((g.value->>'expiresAt') is null or (g.value->>'revokedAt' is null and (g.value->>'expiresAt')::bigint>=p_now)))
          and not exists(select 1 from carry_ai.records t join carry_ai.records g on g.bucket='grant' and g.id=coalesce(t.grant_id::text,t.value->>'grantID')
            where t.bucket in ('access','refresh') and g.value->>'clientID'=c.id and ((t.value->>'expiresAt') is null or (t.value->>'expiresAt')::bigint>=p_now))
        )
      )
    order by c.id limit p_limit for update of c skip locked
  ), deleted as (
    delete from carry_ai.records c using candidates x where c.bucket='client' and c.id=x.id returning x.used
  ) select count(*) filter(where not d.used),count(*) filter(where d.used) into unused,used from deleted d;
  return jsonb_build_object('unusedClients',unused,'retiredClients',used);
end;
$$;
revoke all on function carry_ai.retire_clients(bigint,integer) from public;

-- Aggregates only; queryable by the server operator, never through public MCP.
create or replace function carry_ai.operations_snapshot(p_now bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
  if p_now is null or p_now not between 0 and 9007199254740991 then raise exception 'invalid_snapshot_time'; end if;
  select jsonb_build_object(
    'clients',count(*),'clientBytes',coalesce(sum(octet_length(value::text)+case when value->>'usedAt' is null then 40 else 0 end),0),
    'usedClients',count(*) filter(where value->>'usedAt' is not null),
    'legacyClients',count(*) filter(where coalesce(value->>'registryVersion','')<>'1'),
    'authorizedWithinMinute',count(*) filter(where (value->>'usedAt')::bigint-(value->>'createdAt')::bigint between 0 and 60000),
    'authorizedWithinHour',count(*) filter(where (value->>'usedAt')::bigint-(value->>'createdAt')::bigint between 60001 and 3600000),
    'authorizedAfterHour',count(*) filter(where (value->>'usedAt')::bigint-(value->>'createdAt')::bigint>3600000)
  ) into result from carry_ai.records where bucket='client';
  return result||jsonb_build_object(
    'liveGrants',(select count(*) from carry_ai.records where bucket='grant' and value->>'revokedAt' is null and (value->>'expiresAt')::bigint>p_now),
    'liveRefreshes',(select count(*) from carry_ai.records where bucket='refresh' and not coalesce((value->>'spent')::boolean,false) and (value->>'expiresAt')::bigint>p_now),
    'liveReplayEvidence',(select count(*) from carry_ai.records where bucket='refresh' and coalesce((value->>'spent')::boolean,false) and (value->>'expiresAt')::bigint>p_now),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('day',day,'event',event,'count',count) order by day,event),'[]'::jsonb) from carry_ai.auth_event_counts where day between p_now/86400000-13 and p_now/86400000)
  );
end;
$$;
revoke all on function carry_ai.operations_snapshot(bigint) from public;

create index if not exists ai_token_grant_expiry on carry_ai.records
  ((coalesce(grant_id::text,value->>'grantID')),((value->>'expiresAt')::bigint))
  where bucket in ('access','refresh');
