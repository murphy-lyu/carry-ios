-- carry-test-runtime: hosted-only
-- Separate from the file-cleanup capability: this one permits only draining
-- already-authorized deletion jobs. No request can specify an account ID.
do $$declare token text;begin
  if not exists(select 1 from vault.secrets where name='carry_account_maintenance_capability') then
    token:=encode(extensions.gen_random_bytes(32),'hex');
    perform vault.create_secret(token,'carry_account_maintenance_capability','Carry authorized account-deletion jobs only');
  end if;
  select decrypted_secret into token from vault.decrypted_secrets where name='carry_account_maintenance_capability';
  insert into carry_private.account_deletion_dispatch(singleton,token_hash)
    values(true,encode(sha256(convert_to(token,'UTF8')),'hex'))
    on conflict(singleton) do update set token_hash=excluded.token_hash;
end;$$;
create function carry_private.dispatch_account_maintenance()
returns void language plpgsql security invoker set search_path='' as $$
begin
  -- Remove diagnostic identity mappings; retain only the opaque completion
  -- marker so a long-offline device can confirm an already completed request.
  delete from carry_private.account_deletions where stage='deleted' and completed_at<statement_timestamp()-interval '30 days';
  if exists(select 1 from carry_private.account_deletion_dispatch where lease_until<=statement_timestamp())
    and exists(select 1 from carry_private.account_deletions where stage<>'deleted' and retry_at<=statement_timestamp()
      and (operation_id is null or lease_until<=statement_timestamp())) then
    perform net.http_post(
      url:='https://lbxsvguuoqqpctkinpwy.supabase.co/functions/v1/carry-maintenance',
      headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||
        (select decrypted_secret from vault.decrypted_secrets where name='carry_cleanup_anon'),
        'x-carry-maintenance',(select decrypted_secret from vault.decrypted_secrets where name='carry_account_maintenance_capability')),
      body:='{}'::jsonb,timeout_milliseconds:=115000);
  end if;
end;$$;
revoke all on function carry_private.dispatch_account_maintenance() from public,anon,authenticated,service_role;
select cron.schedule('carry-account-maintenance','*/2 * * * *','select carry_private.dispatch_account_maintenance();');
