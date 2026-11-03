-- carry-test-runtime: hosted-only
-- No HTTP dispatch, Vault value or new cleanup credential. The database-owned
-- job calls the same private bounded routine exercised by the server adapter.
create extension if not exists pg_cron;
select cron.schedule('carry-ai-retention','*/15 * * * *',
  'select carry_ai.maintain_records(floor(extract(epoch from clock_timestamp())*1000)::bigint,500);');
