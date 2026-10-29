-- Only after the worker has independently completed the synthetic Auth deletion.
-- Never manually delete the Auth fixture to turn a failed run into a pass.
do $$declare token text; job carry_private.account_deletions;begin
  select decrypted_secret into token from vault.decrypted_secrets where name='carry_deletion_qa_receipt';
  if token is null then raise exception 'qa_fixture_missing';end if;
  select * into job from carry_private.account_deletions where ticket_hash=encode(sha256(convert_to(token,'UTF8')),'hex');
  if not found or job.stage<>'deleted' or exists(select 1 from auth.users where id=job.account_id)
    then raise exception 'qa_deletion_incomplete';end if;
  if public.carry_account_deletion_status(token)->>'status'<>'deleted' then raise exception 'qa_receipt_not_confirmed';end if;
  delete from carry_private.account_deletions where account_id=job.account_id;
  -- Confirm a long-offline phone still sees completion after diagnostics expire.
  if public.carry_account_deletion_status(token)->>'status'<>'deleted' then raise exception 'qa_receipt_not_retained';end if;
  delete from carry_private.account_deletion_receipts where ticket_hash=job.ticket_hash;
  delete from vault.secrets where name='carry_deletion_qa_receipt';
end;$$;
select (select count(*) from auth.users where email like 'carry-deletion-qa-%@example.invalid') as synthetic_users,
  (select count(*) from carry_private.account_deletions) as jobs,
  (select count(*) from carry_private.account_deletion_receipts) as receipts;
