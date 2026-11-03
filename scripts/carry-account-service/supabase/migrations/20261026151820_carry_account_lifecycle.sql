-- Infrastructure only. No existing Carry/iCloud records are read or migrated.
create table public.carry_apple_credentials (
  account_id uuid not null references auth.users(id) on delete cascade,
  apple_subject text not null,
  audience text not null,
  encrypted_token text not null,
  status text not null default 'active' check (status in ('active', 'deleting')),
  updated_at timestamptz not null default now(),
  primary key (account_id, apple_subject, audience)
);
alter table public.carry_apple_credentials enable row level security;
revoke all on public.carry_apple_credentials from public, anon, authenticated;
grant select, insert, update, delete on public.carry_apple_credentials to service_role;

create table public.carry_account_rate_buckets (
  account_id uuid primary key references auth.users(id) on delete cascade,
  window_start timestamptz not null,
  requests integer not null
);
alter table public.carry_account_rate_buckets enable row level security;
revoke all on public.carry_account_rate_buckets from public, anon, authenticated;

create function public.carry_account_rate_limit(p_account_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into public.carry_account_rate_buckets as bucket values (p_account_id, now(), 1)
  on conflict (account_id) do update set
    requests = case when bucket.window_start < now() - interval '1 minute' then 1 else bucket.requests + 1 end,
    window_start = case when bucket.window_start < now() - interval '1 minute' then now() else bucket.window_start end
  returning requests into n;
  return n <= 20;
end;
$$;

create function public.carry_account_enroll(p_account_id uuid, p_subject text, p_audience text, p_encrypted_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account_id::text, 0));
  if exists(select 1 from public.carry_apple_credentials where account_id = p_account_id and status = 'deleting') then
    raise exception 'account_deletion_pending';
  end if;
  insert into public.carry_apple_credentials values (p_account_id, p_subject, p_audience, p_encrypted_token, 'active', now())
  on conflict (account_id, apple_subject, audience) do update set encrypted_token = excluded.encrypted_token, updated_at = now();
end;
$$;

create function public.carry_account_begin_delete(p_account_id uuid, p_subject text, p_audience text, p_encrypted_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account_id::text, 0));
  update public.carry_apple_credentials set status = 'deleting', updated_at = now() where account_id = p_account_id;
  insert into public.carry_apple_credentials values (p_account_id, p_subject, p_audience, p_encrypted_token, 'deleting', now())
  on conflict (account_id, apple_subject, audience) do update set encrypted_token = excluded.encrypted_token, status = 'deleting', updated_at = now();
end;
$$;

-- Safe release gate. Replace only when the real account graph and attachment purge
-- can be demonstrated end-to-end; never silently delete just the auth user.
create function public.carry_account_purge_owned_data(p_account_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'account_data_purge_not_implemented';
end;
$$;

revoke all on function public.carry_account_rate_limit(uuid) from public, anon, authenticated;
revoke all on function public.carry_account_enroll(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.carry_account_begin_delete(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.carry_account_purge_owned_data(uuid) from public, anon, authenticated;
grant execute on function public.carry_account_rate_limit(uuid) to service_role;
grant execute on function public.carry_account_enroll(uuid, text, text, text) to service_role;
grant execute on function public.carry_account_begin_delete(uuid, text, text, text) to service_role;
grant execute on function public.carry_account_purge_owned_data(uuid) to service_role;
