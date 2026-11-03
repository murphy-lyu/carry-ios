-- carry-test-runtime: hosted-only
-- Provider-owned bucket metadata only. No client Storage policy is introduced.
insert into storage.buckets(id,name,public,file_size_limit)
  values('carry-account-assets','carry-account-assets',false,52428800)
  on conflict(id) do nothing;
do $$begin
  if not exists(select 1 from storage.buckets where id='carry-account-assets'
    and not public and file_size_limit=52428800) then
    raise exception 'carry_asset_bucket_configuration_mismatch';
  end if;
end;$$;
