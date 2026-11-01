-- Private short-lived export approvals. No export bytes or public download
-- capability are stored; current owner session and grant are checked each time.
alter table carry_ai.records drop constraint records_bucket_check;
alter table carry_ai.records add constraint records_bucket_check check
  (bucket in ('client','authorization','grant','code','access','refresh','preview','receipt','undo','export'));
create unique index ai_export_request on carry_ai.records(grant_id,request_id) where bucket='export';
