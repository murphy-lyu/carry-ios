-- carry-test-runtime: hosted-only
-- pg_net defaults permit PUBLIC table access. Cron headers contain a private
-- cleanup capability, so only the database's cron owner may inspect its queue.
revoke all on all tables in schema net from public,anon,authenticated,service_role;
revoke all on all sequences in schema net from public,anon,authenticated,service_role;
revoke usage on schema net from public,anon,authenticated,service_role;
-- Future extension-owned tables must not inherit client grants either.
alter default privileges in schema net revoke all on tables from public,anon,authenticated,service_role;
