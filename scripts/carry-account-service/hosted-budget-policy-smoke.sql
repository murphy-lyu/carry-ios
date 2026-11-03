-- carry-dev only, after account_asset_budget_policy. Synthetic metadata only;
-- no Apple login, provider upload or lasting configuration/data change.
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); sa uuid:=gen_random_uuid(); sb uuid:=gen_random_uuid();
  entity_a uuid:=gen_random_uuid(); entity_b uuid:=gen_random_uuid(); allocated bigint; sha text:=encode(sha256(decode('01020304050607','hex')),'hex');
  fixture_a jsonb; fixture_b jsonb; result jsonb;
begin
  insert into auth.users(id) values(a),(b);
  insert into auth.sessions(id,user_id) values(sa,a),(sb,b);
  set local role service_role;
  perform public.carry_account_enroll(a,'qa-budget-a','app.nevestudio.carry','synthetic-only');
  perform public.carry_account_enroll(b,'qa-budget-b','app.nevestudio.carry','synthetic-only');
  if exists(select 1 from carry_private.asset_budgets where account_id in (a,b)) then raise exception 'qa_enrollment_allocated_budget'; end if;
  select coalesce(sum(maximum_bytes),0)::bigint into allocated from carry_private.asset_budgets;
  update carry_private.asset_budget_policy set enabled=true,per_account_bytes=52428800,maximum_pending=1,total_allocated_bytes=allocated+52428800 where singleton;
  fixture_a:=jsonb_build_object('id',carry_private.asset_identity(a,entity_a,'file',sha),'entityID',entity_a,'entityKind','attachment','slot','file','sha256',sha,'byteCount',7,'contentType','application/octet-stream');
  fixture_b:=jsonb_build_object('id',carry_private.asset_identity(b,entity_b,'file',sha),'entityID',entity_b,'entityKind','attachment','slot','file','sha256',sha,'byteCount',7,'contentType','application/octet-stream');
  result:=public.carry_asset_reserve(a,sa,fixture_a);
  if result->>'status'<>'pending' or not exists(select 1 from carry_private.asset_budgets where account_id=a and maximum_bytes=52428800 and maximum_pending=1) then raise exception 'qa_automatic_budget_missing'; end if;
  perform public.carry_asset_reserve(a,sa,fixture_a);
  if (select count(*) from carry_private.assets where account_id=a)<>1 then raise exception 'qa_retry_not_idempotent'; end if;
  begin
    perform public.carry_asset_reserve(b,sa,fixture_b); raise exception 'qa_cross_session_accepted';
  exception when invalid_authorization_specification then null; end;
  begin
    perform public.carry_asset_reserve(b,sb,fixture_b); raise exception 'qa_project_pool_exceeded';
  exception when raise_exception then if sqlerrm<>'asset_budget_pool_exhausted' then raise; end if; end;
  if exists(select 1 from carry_private.asset_budgets where account_id=b) then raise exception 'qa_failed_admission_persisted'; end if;
  update carry_private.asset_budget_policy set enabled=false where singleton;
  perform public.carry_asset_reserve(a,sa,fixture_a);
  begin
    perform public.carry_asset_reserve(b,sb,fixture_b); raise exception 'qa_closed_policy_accepted';
  exception when raise_exception then if sqlerrm<>'asset_budget_not_configured' then raise; end if; end;
  reset role;
end;
$$;
rollback;
select 'hosted_budget_policy_rollback_passed' as check,
 (select count(*) from carry_private.graph_entities) as existing_entities,
 (select count(*) from carry_private.assets) as existing_files;
