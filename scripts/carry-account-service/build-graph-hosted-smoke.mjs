import {graphSchema} from './graph-schema.mjs';
import {writeFile} from 'node:fs/promises';
function defaults(kind){return Object.fromEntries(Object.entries(graphSchema[kind].fields).filter(([,r])=>!r.optional).map(([k,r])=>[k,
  r.values?.[0]??(r.type==='string'?(r.format==='date-time'?'2026-11-01T00:00:00Z':''):r.type==='number'?Math.max(0,r.min):r.type==='array'?[]:false)]));}
const fields={...defaults('trip'),name:'Synthetic hosted SQL QA',days:3};
const unrecorded={...defaults('lodging'),costAmount:0,costCurrencyCode:'',costHomeAmount:-1};
const free={...unrecorded,costCurrencyCode:'JPY'};
const day=defaults('day'),stop=defaults('stop');
const sql=`-- Isolated carry-dev only. Metadata is synthetic; no real Auth login, emails or tokens.
-- Everything, including fake user/session rows, is rolled back.
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); bs uuid:=gen_random_uuid(); o uuid:=gen_random_uuid();
 d1 uuid:=gen_random_uuid(); d2 uuid:=gen_random_uuid(); place uuid:=gen_random_uuid(); day_before jsonb;
 t uuid:=gen_random_uuid(); request uuid:=gen_random_uuid(); result jsonb; original jsonb; command jsonb; e jsonb; seq bigint;
begin
 insert into auth.users(id) values(a),(b);
 insert into auth.sessions(id,user_id) values(s,a),(bs,b);
 set local role service_role;
 perform public.carry_account_require_session(a,s);
 begin
   perform public.carry_account_require_session(a,bs);raise exception 'qa_lifecycle_cross_session_accepted';
 exception when invalid_authorization_specification then null;
 end;
 reset role;
 insert into auth.oauth_clients(id,registration_type,redirect_uris,grant_types,client_type,token_endpoint_auth_method)
   values(o,'manual','https://synthetic.invalid/callback','authorization_code','public','none');
 update auth.sessions set oauth_client_id=o where id=s;
 set local role service_role;
 begin
   perform public.carry_account_require_session(a,s);raise exception 'qa_lifecycle_oauth_accepted';
 exception when invalid_authorization_specification then null;
 end;
 reset role;
 update auth.sessions set oauth_client_id=null,not_after=now()-interval '1 minute' where id=s;
 set local role service_role;
 begin
   perform public.carry_account_require_session(a,s);raise exception 'qa_lifecycle_expired_accepted';
 exception when invalid_authorization_specification then null;
 end;
 reset role;
 update auth.sessions set not_after=null where id=s;
 set local role service_role;
 perform public.carry_account_enroll(a,'synthetic-a','app.nevestudio.carry','synthetic-encrypted');
 perform public.carry_account_enroll(b,'synthetic-b','app.nevestudio.carry','synthetic-encrypted');
 set local role service_role;
 perform carry_private.graph_validate_fields('lodging','${JSON.stringify(unrecorded)}'::jsonb);
 perform carry_private.graph_validate_fields('lodging','${JSON.stringify(free)}'::jsonb);
 command:=jsonb_build_object('requestID',request,'mutations',jsonb_build_array(jsonb_build_object(
   'id',t,'kind','trip','action','create','baseVersion',0,'fields','${JSON.stringify(fields).replaceAll("'","''")}'::jsonb)));
 result:=public.carry_graph_apply(a,s,command); original:=result;
 if result->>'status'<>'saved_to_account' then raise exception 'qa_save_failed'; end if;
 if public.carry_graph_apply(a,s,command)<>result then raise exception 'qa_retry_failed'; end if;
 if jsonb_array_length(public.carry_graph_pull(b,bs,0)->'changes')<>0 then raise exception 'qa_account_leak'; end if;
 begin
   perform public.carry_graph_pull(a,bs,0);raise exception 'qa_cross_session_accepted';
 exception when invalid_authorization_specification then null;
 end;
 perform public.carry_graph_apply(a,s,jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
   jsonb_build_object('id',t,'kind','trip','action','patch','baseVersion',1,'fields',jsonb_build_object('name','Phone')))));
 perform public.carry_graph_apply(a,s,jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
   jsonb_build_object('id',t,'kind','trip','action','patch','baseVersion',1,'fieldVersions',jsonb_build_object('destinationCity',1),'fields',jsonb_build_object('destinationCity','Tokyo')))));
 select carry_private.graph_snapshot(x) into e from carry_private.graph_entities x where account_id=a and id=t;
 if e->'fields'->>'name'<>'Phone' or e->'fields'->>'destinationCity'<>'Tokyo' then raise exception 'qa_merge_failed'; end if;
 begin
   perform public.carry_graph_apply(a,s,jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
     jsonb_build_object('id',t,'kind','trip','action','patch','baseVersion',1,'fields',jsonb_build_object('name','Stale')))));
   raise exception 'qa_conflict_overwritten';
 exception when raise_exception then if sqlerrm<>'field_conflict' then raise; end if;
 end;
 seq:=(public.carry_graph_pull(a,s,0)->>'cursor')::bigint;
 if seq<>3 then raise exception 'qa_unexpected_cursor'; end if;
 perform public.carry_graph_apply(a,s,jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
   jsonb_build_object('id',d1,'kind','day','action','create','baseVersion',0,'parentID',t,'fields','${JSON.stringify(day)}'::jsonb),
   jsonb_build_object('id',d2,'kind','day','action','create','baseVersion',0,'parentID',t,'fields','${JSON.stringify(day)}'::jsonb||jsonb_build_object('sortOrder',1)),
   jsonb_build_object('id',place,'kind','stop','action','create','baseVersion',0,'parentID',d1,'fields','${JSON.stringify(stop)}'::jsonb))));
 select carry_private.graph_snapshot(x) into day_before from carry_private.graph_entities x where account_id=a and id=d1;
 perform public.carry_graph_apply(a,s,jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
   jsonb_build_object('id',place,'kind','stop','action','move','baseVersion',1,'parentID',d2,'fields','{}'::jsonb),
   jsonb_build_object('id',d1,'kind','day','action','delete','baseVersion',1,'baseSubtreeVersion',day_before->'subtreeVersion'))));
 if not exists(select 1 from carry_private.graph_entities where account_id=a and id=place and parent_id=d2 and deleted_at is null)
   then raise exception 'qa_compound_move_failed'; end if;
 if not exists(select 1 from carry_private.graph_entities where account_id=a and id=d1 and deleted_at is not null)
   then raise exception 'qa_compound_delete_failed'; end if;
 seq:=(public.carry_graph_pull(a,s,0)->>'cursor')::bigint;

 begin
   perform public.carry_graph_apply(a,s,jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
     jsonb_build_object('id',t,'kind','trip','action','patch','baseVersion',3,'fields',jsonb_build_object('name','Must rollback')),
     jsonb_build_object('id',gen_random_uuid(),'kind','trip','action','create','baseVersion',0,'fields',jsonb_build_object('owner',b)))));
   raise exception 'qa_partial_commit';
 exception when invalid_parameter_value then null;
 end;
 if (public.carry_graph_pull(a,s,0)->>'cursor')::bigint<>seq then raise exception 'qa_failed_write_advanced_cursor'; end if;
 if public.carry_graph_apply(a,s,command)<>original then raise exception 'qa_receipt_mutated'; end if;
 reset role;
 delete from auth.sessions where id=s;
 set local role service_role;
 begin
   perform public.carry_account_require_session(a,s);raise exception 'qa_lifecycle_revoked_accepted';
 exception when invalid_authorization_specification then null;
 end;
 begin
   perform public.carry_graph_pull(a,s,0);raise exception 'qa_revoked_session_accepted';
 exception when invalid_authorization_specification then null;
 end;
 reset role;
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname like 'carry_%' and
   (p.prosecdef or has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')))
   then raise exception 'qa_public_grant_leak'; end if;
 if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='carry_private' and p.prosecdef)<>1 then raise exception 'qa_unexpected_definer'; end if;
end;
$$;
rollback;
select jsonb_build_object('users',(select count(*) from auth.users),
 'sessions',(select count(*) from auth.sessions),'oauthClients',(select count(*) from auth.oauth_clients),
 'accounts',(select count(*) from carry_private.graph_accounts),
 'entities',(select count(*) from carry_private.graph_entities),
 'changes',(select count(*) from carry_private.graph_changes),
 'receipts',(select count(*) from carry_private.graph_receipts)) as synthetic_cleanup;
`;
await writeFile(new URL('./hosted-graph-smoke.sql',import.meta.url),sql);
