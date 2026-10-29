-- Disposable carry-dev acceptance only. Simulate completed Apple revocation
-- explicitly; this does NOT test actual Apple login/revocation. The worker must
-- perform the real data purge and real Auth Admin deletion over HTTPS.
do $$
declare a uuid:=gen_random_uuid();s uuid:=gen_random_uuid();op uuid:=gen_random_uuid();
  ticket text:=encode(extensions.gen_random_bytes(32),'hex');
begin
  if exists(select 1 from vault.secrets where name='carry_deletion_qa_receipt') then raise exception 'qa_fixture_already_exists';end if;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
    raw_app_meta_data,raw_user_meta_data,confirmation_token,recovery_token,email_change,email_change_token_new,
    email_change_token_current,phone_change,phone_change_token,reauthentication_token)
  values(a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'carry-deletion-qa-'||a::text||'@example.invalid','',statement_timestamp(),statement_timestamp(),statement_timestamp(),
    '{}','{}','','','','','','','','');
  insert into auth.sessions(id,user_id) values(s,a);
  perform public.carry_account_enroll(a,'synthetic-maintenance-deletion-qa','app.nevestudio.carry','synthetic-encrypted');
  perform public.carry_account_request_deletion(a,s,'synthetic-maintenance-deletion-qa','app.nevestudio.carry','synthetic-encrypted',ticket);
  perform public.carry_account_deletion_claim(a,op);
  perform public.carry_account_deletion_revoked(a,op,'synthetic-maintenance-deletion-qa','app.nevestudio.carry',
    encode(sha256(convert_to('synthetic-encrypted','UTF8')),'hex'));
  perform public.carry_account_deletion_advance(a,op,'purging');
  perform vault.create_secret(ticket,'carry_deletion_qa_receipt','Disposable synthetic deletion acceptance only');
end;$$;
select carry_private.dispatch_account_maintenance();
