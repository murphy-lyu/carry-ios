-- Run only against the named, isolated carry-dev project. Everything is rolled back.
-- This tests database behavior, not a real Apple/Supabase login or a valid HTTP JWT.
begin;
do $$
declare
  fixture uuid := gen_random_uuid();
  other_fixture uuid := gen_random_uuid();
  allowed boolean;
  n integer;
begin
  insert into auth.users(id) values (fixture), (other_fixture);
  perform public.carry_account_enroll(fixture, 'carry-qa-subject', 'app.nevestudio.carry', 'qa-encrypted-placeholder');
  select count(*) into n from public.carry_account_credentials(fixture);
  if n <> 1 then raise exception 'qa_enrollment_missing'; end if;
  select count(*) into n from public.carry_account_credentials(other_fixture);
  if n <> 0 then raise exception 'qa_account_isolation_failed'; end if;
  for i in 1..21 loop
    allowed := public.carry_account_rate_limit(fixture);
    if allowed is distinct from (i <= 20) then raise exception 'qa_rate_budget_failed'; end if;
  end loop;
  update carry_private.carry_account_rate_buckets set window_start = now() - interval '2 minutes' where account_id = fixture;
  if not public.carry_account_rate_limit(fixture) then raise exception 'qa_rate_reset_failed'; end if;
  perform public.carry_account_begin_delete(fixture, 'carry-qa-subject', 'app.nevestudio.carry', 'qa-encrypted-updated');
  begin
    perform public.carry_account_enroll(fixture, 'carry-qa-subject', 'app.nevestudio.carry', 'must-not-revive');
    raise exception 'qa_deleted_account_revived';
  exception when raise_exception then
    if sqlerrm <> 'account_deletion_pending' then raise; end if;
  end;
  begin
    perform public.carry_account_purge_owned_data(fixture);
    raise exception 'qa_incomplete_purge_claimed_success';
  exception when raise_exception then
    if sqlerrm <> 'account_data_purge_not_implemented' then raise; end if;
  end;
  if exists(select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.proname like 'carry_account_%'
      and (p.prosecdef or has_function_privilege('anon', p.oid, 'EXECUTE')
        or has_function_privilege('authenticated', p.oid, 'EXECUTE'))) then
    raise exception 'qa_rpc_privileges_failed';
  end if;
end;
$$;
rollback;
select jsonb_build_object(
  'credentials_after_rollback', (select count(*) from carry_private.carry_apple_credentials),
  'rate_buckets_after_rollback', (select count(*) from carry_private.carry_account_rate_buckets),
  'auth_users_after_rollback', (select count(*) from auth.users)
) as isolated_dev_cleanup;
