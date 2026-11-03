-- A bounded large atomic commit needs a longer function-specific budget.
-- Ordinary requests retain their default timeouts. No role/global change.
alter function public.carry_graph_commit_stage(uuid,uuid,uuid) set statement_timeout='55s';
notify pgrst,'reload schema';
