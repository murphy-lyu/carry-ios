-- Native account management must also reject revoked/OAuth sessions before
-- enrollment. Reading a current Auth user alone does not revoke a live JWT.
create function carry_private.account_require_native_session(p_account uuid, p_session uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if p_account is null or p_session is null or not exists (
    select 1 from auth.sessions where id=p_session and user_id=p_account
      and oauth_client_id is null
      and (not_after is null or not_after > statement_timestamp())
  ) then raise exception using message='session_expired', errcode='28000'; end if;
end;
$$;
revoke all on function carry_private.account_require_native_session(uuid, uuid) from public, anon, authenticated;
grant execute on function carry_private.account_require_native_session(uuid, uuid) to service_role;

create function public.carry_account_require_session(p_account uuid, p_session uuid)
returns void language sql stable security invoker set search_path = '' as $$
  select carry_private.account_require_native_session(p_account, p_session);
$$;
revoke all on function public.carry_account_require_session(uuid, uuid) from public, anon, authenticated;
grant execute on function public.carry_account_require_session(uuid, uuid) to service_role;

-- The graph adds enrollment/deletion checks using existing service privileges.
-- Only the narrowly scoped auth.sessions lookup above needs definer rights.
create or replace function carry_private.graph_require_session(p_account uuid, p_session uuid) returns void
language plpgsql security invoker set search_path = '' as $$
begin
  perform carry_private.account_require_native_session(p_account, p_session);
  if not exists(select 1 from carry_private.carry_apple_credentials
    where account_id=p_account and status='active') or exists (
    select 1 from carry_private.carry_apple_credentials where account_id=p_account and status='deleting'
  ) then raise exception using message='account_unavailable', errcode='28000'; end if;
end;
$$;
