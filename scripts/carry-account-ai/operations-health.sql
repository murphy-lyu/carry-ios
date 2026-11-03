-- Operator-only, read-only. No token, account, address or trip columns.
with snapshot as (
 select carry_ai.operations_snapshot(floor(extract(epoch from clock_timestamp())*1000)::bigint) as data
), usage as (
 select data,(data->>'clients')::numeric/1024 as count_ratio,
 (data->>'clientBytes')::numeric/16777216 as bytes_ratio from snapshot
)
select data,case when greatest(count_ratio,bytes_ratio)>=0.90 then 'critical'
 when greatest(count_ratio,bytes_ratio)>=0.75 then 'warning' else 'ok' end as registry_capacity
from usage;

-- These are natural pg_cron run results; manual invocations do not count.
select j.active,j.schedule,
 (select max(end_time) from cron.job_run_details d where d.jobid=j.jobid and d.status='succeeded') as last_success,
 (select count(*) from cron.job_run_details d where d.jobid=j.jobid and d.status='failed' and d.start_time>now()-interval '1 day') as failures_last_day,
 case when not j.active then 'disabled'
  when not exists(select 1 from cron.job_run_details d where d.jobid=j.jobid and d.status='succeeded' and d.end_time>now()-interval '45 minutes') then 'critical'
  else 'ok' end as retention_health
from cron.job j where j.jobname='carry-ai-retention';
