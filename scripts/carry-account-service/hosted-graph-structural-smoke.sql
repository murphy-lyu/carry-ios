-- Synthetic only. All Auth, graph and receipt writes roll back.
begin;
do $$
declare a uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); t uuid:=gen_random_uuid();
 d1 uuid:=gen_random_uuid(); d2 uuid:=gen_random_uuid(); p uuid:=gen_random_uuid();
 sec uuid:=gen_random_uuid(); item uuid:=gen_random_uuid(); r uuid:=gen_random_uuid();
 result jsonb; root jsonb; leaf jsonb; command jsonb;
begin
 insert into auth.users(id) values(a);insert into auth.sessions(id,user_id) values(s,a);
 set local role service_role;
 perform public.carry_account_enroll(a,'synthetic-structural-qa','app.nevestudio.carry','synthetic-encrypted');
 perform public.carry_graph_apply(a,s,jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
 jsonb_build_object('id',t,'kind','trip','action','create','baseVersion',0,'fields','{"name":"Synthetic structural hosted QA","destinationCity":"","days":3,"dateRange":"","departureDate":"2026-11-01T00:00:00Z","isDateless":false,"createdAt":"2026-11-01T00:00:00Z","selectedSceneKeys":[],"dismissedSurpriseNames":[],"sceneCardDismissed":false,"remindersEnabled":false,"reminderConfigData":"","countryCode":"","latitude":0,"longitude":0}'::jsonb),
 jsonb_build_object('id',d1,'kind','day','action','create','baseVersion',0,'fields','{"title":"","note":"","sortOrder":0}'::jsonb,'parentID',t),jsonb_build_object('id',d2,'kind','day','action','create','baseVersion',0,'fields','{"title":"","note":"","sortOrder":1}'::jsonb,'parentID',t),
 jsonb_build_object('id',p,'kind','stop','action','create','baseVersion',0,'fields','{"name":"","latitude":0,"longitude":0,"address":"","categoryRaw":"","plannedStartMinutes":0,"stayMinutes":0,"note":"","sortOrder":0}'::jsonb,'parentID',d1),
 jsonb_build_object('id',sec,'kind','section','action','create','baseVersion',0,'fields','{"title":"Synthetic","sortOrder":0}'::jsonb,'parentID',t),
 jsonb_build_object('id',item,'kind','packingItem','action','create','baseVersion',0,'fields','{"name":"Synthetic","quantity":1,"isPacked":false,"isAlert":false,"sortOrder":0}'::jsonb,'parentID',sec))));
 result:=public.carry_graph_apply(a,s,jsonb_build_object('requestID',r,'mutations',jsonb_build_array(
 jsonb_build_object('id',p,'kind','stop','action','move','baseVersion',1,'parentID',d2,'fields','{}'::jsonb),
 jsonb_build_object('id',d1,'kind','day','action','patch','baseVersion',1,'fields',jsonb_build_object('title','Edited')))));
 if (select count(*) from carry_private.graph_changes where account_id=a and request_id=r and entity_id=d1 and not metadata_only)<>1
 then raise exception 'old_parent_false_ack';end if;
 if exists(select 1 from carry_private.graph_changes where account_id=a and request_id=r and metadata_only and (snapshot->'fields'<>'{}'::jsonb or snapshot->'fieldVersions'<>'{}'::jsonb))
 then raise exception 'metadata_fields_leaked';end if;
 select carry_private.graph_snapshot(e) into root from carry_private.graph_entities e where account_id=a and id=t;
 select carry_private.graph_snapshot(e) into leaf from carry_private.graph_entities e where account_id=a and id=item;
 command:=jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
 jsonb_build_object('id',item,'kind','packingItem','action','delete','baseVersion',leaf->'version','baseSubtreeVersion',leaf->'subtreeVersion'),
 jsonb_build_object('id',t,'kind','trip','action','delete','baseVersion',root->'version','baseSubtreeVersion',root->'subtreeVersion')));
 result:=public.carry_graph_apply(a,s,command);
 if public.carry_graph_apply(a,s,command)<>result then raise exception 'receipt_replay_changed';end if;
 select carry_private.graph_snapshot(e) into root from carry_private.graph_entities e where account_id=a and id=t;
 select carry_private.graph_snapshot(e) into leaf from carry_private.graph_entities e where account_id=a and id=item;
 if root->>'deletionBatch'=leaf->>'deletionBatch' then raise exception 'independent_deletes_share_batch';end if;
 perform public.carry_graph_apply(a,s,jsonb_build_object('requestID',gen_random_uuid(),'mutations',jsonb_build_array(
 jsonb_build_object('id',t,'kind','trip','action','restore','baseVersion',root->'version','baseSubtreeVersion',root->'subtreeVersion'))));
 if not exists(select 1 from carry_private.graph_entities where account_id=a and id=item and deleted_at is not null)
 then raise exception 'parent_restore_revived_independent_delete';end if;
 if exists(select 1 from carry_private.graph_entities where account_id=a and id<>item and deleted_at is not null)
 then raise exception 'parent_restore_incomplete';end if;
 if has_function_privilege('authenticated','carry_private.graph_record_changes(uuid,uuid,uuid,jsonb,boolean)','EXECUTE')
 or has_function_privilege('anon','carry_private.graph_record_ancestor(uuid,uuid,uuid)','EXECUTE')
 then raise exception 'helper_privilege_leak';end if;
 reset role;
end;$$;
select 'metadata_ack_delete_batches_replay_and_permissions_passed' as result;
rollback;
