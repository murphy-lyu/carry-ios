-- Credentials and rate metadata are not resources in the exposed Data API schema.
create schema carry_private;
revoke all on schema carry_private from public, anon, authenticated;
grant usage on schema carry_private to service_role;

alter table public.carry_apple_credentials set schema carry_private;
alter table public.carry_account_rate_buckets set schema carry_private;
grant select, insert, update, delete on carry_private.carry_account_rate_buckets to service_role;

-- The service role already holds the required explicit table privileges and bypasses RLS.
-- Invoker functions avoid privileged public SECURITY DEFINER entrypoints entirely.
create or replace function public.carry_account_rate_limit(p_account_id uuid) returns boolean
language plpgsql security invoker set search_path = '' as $$
declare n integer;
begin
  insert into carry_private.carry_account_rate_buckets as bucket values (p_account_id, now(), 1)
  on conflict (account_id) do update set
    requests = case when bucket.window_start < now() - interval '1 minute' then 1 else bucket.requests + 1 end,
    window_start = case when bucket.window_start < now() - interval '1 minute' then now() else bucket.window_start end
  returning requests into n;
  return n <= 20;
end;
$$;

create or replace function public.carry_account_enroll(p_account_id uuid, p_subject text, p_audience text, p_encrypted_token text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account_id::text, 0));
  if exists(select 1 from carry_private.carry_apple_credentials where account_id = p_account_id and status = 'deleting') then
    raise exception 'account_deletion_pending';
  end if;
  insert into carry_private.carry_apple_credentials values (p_account_id, p_subject, p_audience, p_encrypted_token, 'active', now())
  on conflict (account_id, apple_subject, audience) do update set encrypted_token = excluded.encrypted_token, updated_at = now();
end;
$$;

create or replace function public.carry_account_begin_delete(p_account_id uuid, p_subject text, p_audience text, p_encrypted_token text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account_id::text, 0));
  update carry_private.carry_apple_credentials set status = 'deleting', updated_at = now() where account_id = p_account_id;
  insert into carry_private.carry_apple_credentials values (p_account_id, p_subject, p_audience, p_encrypted_token, 'deleting', now())
  on conflict (account_id, apple_subject, audience) do update set encrypted_token = excluded.encrypted_token, status = 'deleting', updated_at = now();
end;
$$;

create or replace function public.carry_account_purge_owned_data(p_account_id uuid) returns void
language plpgsql security invoker set search_path = '' as $$
begin
  raise exception 'account_data_purge_not_implemented';
end;
$$;

create function public.carry_account_credentials(p_account_id uuid)
returns table(account_id uuid, apple_subject text, audience text, encrypted_token text, status text)
language sql stable security invoker set search_path = '' as $$
  select account_id, apple_subject, audience, encrypted_token, status
  from carry_private.carry_apple_credentials where account_id = p_account_id;
$$;
revoke all on function public.carry_account_credentials(uuid) from public, anon, authenticated;
grant execute on function public.carry_account_credentials(uuid) to service_role;
