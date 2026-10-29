-- carry-test-runtime: hosted-only
-- Apply only to the named development project after carry-cleanup deployment.
-- Requires a Vault secret carry_cleanup_anon containing the project's public
-- legacy anon JWT. No privileged API key is stored in cron SQL or its logs.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

do $$
declare token text;
begin
  if not exists(select 1 from vault.secrets where name='carry_cleanup_capability') then
    token:=encode(extensions.gen_random_bytes(32),'hex');
    perform vault.create_secret(token,'carry_cleanup_capability','Carry file cleanup only; never a user/API session');
  end if;
  select decrypted_secret into token from vault.decrypted_secrets where name='carry_cleanup_capability';
  insert into carry_private.asset_cleanup_dispatch(singleton,token_hash)
    values(true,encode(sha256(convert_to(token,'UTF8')),'hex'))
    on conflict(singleton) do update set token_hash=excluded.token_hash;
end;
$$;

-- All callers remain unprivileged unless both the project gateway and the
-- database's cleanup-only capability validation succeed. Keep verify_jwt=true.
create or replace function carry_private.dispatch_asset_cleanup()
returns void language plpgsql security invoker set search_path='' as $$
begin
  if exists(select 1 from carry_private.asset_cleanup_dispatch where lease_until<=statement_timestamp())
    and exists(select 1 from carry_private.asset_cleanup_candidates()) then
    perform net.http_post(
      url:='https://lbxsvguuoqqpctkinpwy.supabase.co/functions/v1/carry-cleanup',
      headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||
        (select decrypted_secret from vault.decrypted_secrets where name='carry_cleanup_anon'),
        'x-carry-cleanup',(select decrypted_secret from vault.decrypted_secrets where name='carry_cleanup_capability')),
      body:='{}'::jsonb,timeout_milliseconds:=115000);
  end if;
end;
$$;
revoke all on function carry_private.dispatch_asset_cleanup() from public,anon,authenticated,service_role;
select cron.schedule('carry-asset-cleanup','*/2 * * * *','select carry_private.dispatch_asset_cleanup();');
