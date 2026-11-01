-- Private bounded retention. Keep request identities and still-valid refresh
-- replay evidence; only expired content and old rate windows are removed.
create or replace function carry_ai.maintain_records(p_now bigint, p_limit integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare removed integer; compacted integer; rates integer;
begin
  if p_now is null or p_now not between -9007199254740991 and 9007199254740991
    or p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'invalid_maintenance_input';
  end if;
  with candidates as (
    select bucket,id from carry_ai.records where
      (bucket='authorization' and (value->>'expiresAt')::bigint<p_now) or
      (bucket='code' and (value->>'codeExpiresAt')::bigint<p_now) or
      (bucket='access' and (value->>'expiresAt')::bigint<p_now) or
      (bucket='preview' and (value->>'expiresAt')::bigint<p_now-86400000) or
      (bucket='export' and (value->>'expiresAt')::bigint<p_now) or
      (bucket='undo' and (value->>'createdAt')::bigint<p_now-2592000000) or
      (bucket='refresh' and (value->>'expiresAt')::bigint<p_now)
    order by bucket,id limit p_limit for update skip locked
  ) delete from carry_ai.records r using candidates c where r.bucket=c.bucket and r.id=c.id;
  get diagnostics removed = row_count;
  with old as (
    select bucket,id from carry_ai.records where bucket='receipt' and (value->>'createdAt')::bigint<p_now-2592000000
      and not coalesce((value->>'undoExpired')::boolean,false)
    order by id limit p_limit for update skip locked
  ) update carry_ai.records r set value=(r.value-'before'-'after'-'mutations')||'{"undoExpired":true}'::jsonb
    from old where r.bucket=old.bucket and r.id=old.id;
  get diagnostics compacted = row_count;
  with old as (
    select key from carry_ai.rate_limits where window_id<floor(p_now::numeric/60000)-1440
    order by key limit p_limit for update skip locked
  ) delete from carry_ai.rate_limits r using old where r.key=old.key;
  get diagnostics rates = row_count;
  return jsonb_build_object('records',removed,'compactedReceipts',compacted,'rateBuckets',rates);
end;
$$;
revoke all on function carry_ai.maintain_records(bigint,integer) from public;
