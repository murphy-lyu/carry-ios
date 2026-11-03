-- carry-test-runtime: hosted-only
-- Expired abandoned staging is private temporary data, not a committed graph.
-- Run as the scheduler owner; no client or Edge-function privileges are added.
create function carry_private.prune_graph_stages()
returns void language sql security invoker set search_path='' as $$
  delete from carry_private.graph_command_stages where expires_at<=statement_timestamp();
$$;
revoke all on function carry_private.prune_graph_stages() from public,anon,authenticated,service_role;
select cron.schedule('carry-graph-stage-cleanup','17 * * * *','select carry_private.prune_graph_stages();');
