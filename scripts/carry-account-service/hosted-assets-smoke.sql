-- carry-dev only. Synthetic metadata and sessions; no login, email, token or
-- actual file upload. Every row, including temporary Storage metadata, rolls back.
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); bs uuid:=gen_random_uuid();
  entity uuid:=gen_random_uuid(); file uuid; v_version uuid:=gen_random_uuid(); operation uuid:=gen_random_uuid();
  sha text:=encode(sha256(decode('01020304050607','hex')),'hex');
  manifest jsonb; attempt jsonb; result jsonb; target jsonb; v_name text; location text;
begin
  insert into auth.users(id) values(a),(b);
  insert into auth.sessions(id,user_id) values(s,a),(bs,b);
  set local role service_role;
  perform public.carry_account_enroll(a,'synthetic-assets-a','app.nevestudio.carry','synthetic-encrypted');
  perform public.carry_account_enroll(b,'synthetic-assets-b','app.nevestudio.carry','synthetic-encrypted');
  insert into carry_private.asset_budgets values(a,157286400,3);
  file:=carry_private.asset_identity(a,entity,'file',sha);
  manifest:=jsonb_build_object('id',file,'entityID',entity,'entityKind','attachment','slot','file','sha256',sha,'byteCount',7,'contentType','application/octet-stream');
  result:=public.carry_asset_reserve(a,s,manifest);
  if result->>'status'<>'pending' then raise exception 'qa_asset_reserve_failed'; end if;
  begin
    perform public.carry_asset_reserve(a,bs,manifest);raise exception 'qa_asset_cross_session_accepted';
  exception when invalid_authorization_specification then null;
  end;
  attempt:=public.carry_asset_upload_begin(a,s,file);
  if attempt->>'status'<>'create' or public.carry_asset_upload_begin(a,s,file)->>'status'<>'creating'
  then raise exception 'qa_upload_creation_not_durable'; end if;
  v_name:=a::text||'/'||file::text||'/'||sha;
  location:='https://lbxsvguuoqqpctkinpwy.storage.supabase.co/storage/v1/upload/resumable/'||
    rtrim(translate(replace(encode(convert_to('carry-account-assets/'||v_name||'/'||v_version::text,'UTF8'),'base64'),E'\n',''),'+/','-_'),'=');
  result:=public.carry_asset_upload_created(a,(attempt->>'id')::uuid,(attempt->>'creationID')::uuid,location);
  if result->>'status'<>'active' then raise exception 'qa_upload_location_not_persisted'; end if;
  perform public.carry_asset_upload_claim(a,s,(attempt->>'id')::uuid,operation,'PATCH',0);
  begin
    perform public.carry_asset_upload_claim(a,s,(attempt->>'id')::uuid,gen_random_uuid(),'HEAD',null);
    raise exception 'qa_upload_concurrent_operation_accepted';
  exception when raise_exception then if sqlerrm<>'upload_busy' then raise; end if;
  end;
  perform public.carry_asset_upload_finish(a,(attempt->>'id')::uuid,operation,7,false);
  if (select state from carry_private.assets where account_id=a and id=file)<>'pending'
  then raise exception 'qa_upload_prematurely_verified'; end if;
  -- Metadata only, not an S3 write. This tests real service_role access and the
  -- provider schema/version lock; actual streamed inspection has separate QA.
  insert into storage.buckets(id,name,public) values('carry-account-assets','carry-account-assets',false) on conflict do nothing;
  insert into storage.objects(bucket_id,name,version,metadata) values('carry-account-assets',v_name,v_version::text,'{"size":7}'::jsonb);
  target:=public.carry_asset_inspection_target(a,s,file);
  if target->>'storageVersion'<>v_version::text then raise exception 'qa_storage_version_lookup_failed'; end if;
  result:=public.carry_asset_inspection_finish(a,s,file,v_version::text,sha,7);
  if result->>'status'<>'verified' or (select state from carry_private.asset_upload_attempts where account_id=a and id=(attempt->>'id')::uuid)<>'complete'
  then raise exception 'qa_inspection_commit_failed'; end if;
  if public.carry_asset_cleanup_claim(a,gen_random_uuid()) is not null then raise exception 'qa_active_file_cleanup_allowed'; end if;
  perform public.carry_account_begin_delete(a,'synthetic-assets-a','app.nevestudio.carry','synthetic-encrypted');
  operation:=gen_random_uuid();
  result:=public.carry_asset_cleanup_claim(a,operation);
  if result->>'storageVersion'<>v_version::text then raise exception 'qa_cleanup_wrong_version'; end if;
  begin
    perform public.carry_asset_cleanup_finish(a,(attempt->>'id')::uuid,operation);
    raise exception 'qa_cleanup_unconfirmed_removal_allowed';
  exception when raise_exception then if sqlerrm<>'cleanup_not_confirmed' then raise; end if;
  end;
  -- Hosted Storage rejects direct metadata deletion, including synthetic rows.
  -- Respect its protection: retain the durable cleanup job and roll back the
  -- fixture. Successful removal is verified separately through Storage's API.
  if not exists(select 1 from carry_private.assets where account_id=a)
    or not exists(select 1 from carry_private.asset_upload_attempts where account_id=a)
  then raise exception 'qa_cleanup_ledger_prematurely_cleared'; end if;
  reset role;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'carry_asset_%'
    and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')))
  then raise exception 'qa_asset_rpc_public_grant'; end if;
  if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='carry_private'
    and c.relname in ('assets','asset_budgets','asset_upload_attempts','asset_rate_buckets') and not c.relrowsecurity)
  then raise exception 'qa_asset_rls_disabled'; end if;
end;
$$;
rollback;
select 'hosted_asset_rollback_checks_passed' as check,
  (select count(*) from carry_private.assets) as remaining_assets,
  (select count(*) from carry_private.asset_upload_attempts) as remaining_attempts;
