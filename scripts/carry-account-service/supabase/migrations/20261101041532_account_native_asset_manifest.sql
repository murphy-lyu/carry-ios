-- Native-only metadata for already published, verified assets. The endpoint
-- never exposes a signed/provider URL or allows OAuth grants to bypass scope.
create function public.carry_asset_download_manifest(p_account uuid,p_session uuid,p_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item carry_private.assets; graph carry_private.graph_entities; field_name text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_account::text,0));
  perform carry_private.graph_require_session(p_account,p_session);
  select * into item from carry_private.assets where account_id=p_account and id=p_id;
  if not found then raise exception 'asset_not_found'; end if;
  if item.state<>'verified' or item.verified_version is null then raise exception 'asset_unavailable'; end if;
  select * into graph from carry_private.graph_entities where account_id=p_account and id=item.entity_id and deleted_at is null;
  if not found or graph.kind<>item.entity_kind then raise exception 'asset_not_found'; end if;
  field_name:=case item.slot when 'thumbnail' then 'thumbnailAssetID' when 'original' then 'originalAssetID' when 'file' then 'fileAssetID' end;
  if (field_name is not null and lower(graph.fields->>field_name) is distinct from item.id::text)
    or (field_name is null and (item.entity_kind<>'trip' or item.slot !~ '^background:[0-9]{1,4}:[0-9]{1,4}$'
      or lower(graph.fields->'backgroundAssetIDs'->>item.slot) is distinct from item.id::text)) then
    raise exception 'asset_not_found';
  end if;
  perform 1 from storage.objects o where o.bucket_id='carry-account-assets'
    and o.name collate "C"=p_account::text||'/'||item.id::text||'/'||item.sha256
    and o.version=item.verified_version::text and o.archived_at is null and not o.is_delete_marker for share;
  if not found then raise exception 'asset_unavailable'; end if;
  return jsonb_build_object('id',item.id,'accountID',p_account,'entityID',item.entity_id,'entityKind',item.entity_kind,
    'slot',item.slot,'sha256',item.sha256,'byteCount',item.byte_count,'status','verified','storageVersion',item.verified_version);
end;
$$;
revoke all on function public.carry_asset_download_manifest(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.carry_asset_download_manifest(uuid,uuid,uuid) to service_role;
