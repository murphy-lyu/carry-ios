-- Installed only by the server's migration runner. No public RPC or client grant.
create schema if not exists carry_ai;
revoke all on schema carry_ai from public;
create table if not exists carry_ai.records (
  bucket text not null check (bucket in ('client','authorization','grant','code','access','refresh','preview','receipt','undo')),
  id text not null,
  account_id uuid,
  grant_id uuid,
  request_id uuid,
  value jsonb not null check (jsonb_typeof(value) = 'object'),
  primary key (bucket,id)
);
create index if not exists ai_records_account on carry_ai.records(account_id,bucket);
create unique index if not exists ai_preview_request on carry_ai.records(grant_id,request_id) where bucket='preview';
create unique index if not exists ai_receipt_request on carry_ai.records(grant_id,request_id) where bucket='receipt';
create table if not exists carry_ai.rate_limits (
  key text primary key,
  account_id uuid,
  window_id bigint not null,
  count integer not null check (count > 0)
);
alter table carry_ai.records enable row level security;
alter table carry_ai.rate_limits enable row level security;
revoke all on all tables in schema carry_ai from public;
-- Intentionally no anon/authenticated policies. The server role must have only
-- reviewed access to this schema and the validated graph-core entrypoint.
