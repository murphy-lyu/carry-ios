-- Synthetic native database acceptance, rolled back including Auth/session rows.
-- No Apple exchange, external file access or real user records.
begin;
select set_config('carry.qa_start',clock_timestamp()::text,true);
do $$
declare a uuid:=gen_random_uuid();s uuid:=gen_random_uuid();r uuid:=gen_random_uuid();
 t uuid:=gen_random_uuid();section uuid:=gen_random_uuid();f jsonb;items jsonb;summary jsonb;page jsonb;offset_value integer:=0;seen bigint:=0;entry jsonb;
begin
 insert into auth.users(id) values(a);insert into auth.sessions(id,user_id) values(s,a);
 perform public.carry_account_enroll(a,'synthetic-staged-qa','app.nevestudio.carry','synthetic-encrypted');
 select jsonb_object_agg(key,case value->>'type'
   when 'string' then to_jsonb(case when value->>'format'='date-time' then '2026-11-01T00:00:00Z' else '' end)
   when 'array' then '[]'::jsonb when 'boolean' then 'false'::jsonb
   else coalesce(value->'min','0'::jsonb) end) into f
 from jsonb_each(carry_private.graph_schema()->'trip'->'fields') where not coalesce((value->>'optional')::boolean,false);
 items:=jsonb_build_array(jsonb_build_object('id',t,'kind','trip','action','create','baseVersion',0,'fields',f),
   jsonb_build_object('id',section,'kind','section','action','create','baseVersion',0,'parentID',t,
     'fields',jsonb_build_object('title','Synthetic section','sortOrder',0)));
 select items||jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'kind','packingItem','action','create','baseVersion',0,'parentID',section,
   'fields',jsonb_build_object('name','Synthetic item','quantity',1,'isPacked',false,'isAlert',false,'sortOrder',i))) into items from generate_series(0,500) i;
 perform public.carry_graph_stage(a,s,r,0,2,503,(select jsonb_agg(value order by ordinality) from jsonb_array_elements(items) with ordinality where ordinality<=500));
 if exists(select 1 from carry_private.graph_entities where account_id=a) then raise exception 'partial_publish';end if;
 perform public.carry_graph_stage(a,s,r,1,2,503,(select jsonb_agg(value order by ordinality) from jsonb_array_elements(items) with ordinality where ordinality>500));
 summary:=public.carry_graph_commit_stage(a,s,r);
 if summary->>'status'<>'saved_to_account' or (select count(*) from carry_private.graph_entities where account_id=a)<>503 then raise exception 'staged_commit_failed';end if;
 while offset_value<(summary->>'changeCount')::integer loop
   page:=public.carry_graph_receipt_page(a,s,r,offset_value,137);
   for entry in select value from jsonb_array_elements(page->'changes') loop
     seen:=seen+1;if (entry->>'sequence')::bigint<>seen then raise exception 'receipt_gap';end if;
   end loop;
   offset_value:=(page->>'nextOffset')::integer;
 end loop;
 if seen<>(summary->>'cursor')::bigint then raise exception 'cursor_mismatch';end if;
 if exists(select 1 from carry_private.graph_command_stages where account_id=a) then raise exception 'stage_not_removed';end if;
 if has_function_privilege('authenticated','public.carry_graph_commit_stage(uuid,uuid,uuid)','EXECUTE')
    or has_table_privilege('authenticated','carry_private.graph_command_chunks','SELECT') then raise exception 'client_privilege_leak';end if;
end;$$;
select 'synthetic_503_item_atomic_commit_and_receipt_passed' as result,
  extract(epoch from clock_timestamp()-current_setting('carry.qa_start')::timestamptz) as database_seconds;
rollback;
