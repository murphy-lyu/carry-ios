import {randomUUID,createHash} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
import {applyPortableMigrations} from './migration-fixture.mjs';
export const account=randomUUID(),session=randomUUID(),other=randomUUID(),ticket='a'.repeat(64),subject='synthetic-subject',audience='app.nevestudio.carry';
export async function fixture({files=false,evidence=true,database=null}={}){
 const db=database ?? new PGlite();
 await db.exec(`do $$begin
 if not exists(select 1 from pg_roles where rolname='anon') then create role anon;end if;
 if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated;end if;
 if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role bypassrls;end if;
 end$$;
 create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),not_after timestamptz,oauth_client_id uuid);
 create schema storage;create table storage.objects(bucket_id text,name text,version text,archived_at timestamptz,is_delete_marker boolean not null default false);
 grant usage on schema storage to service_role;grant select,update on storage.objects to service_role;`);
 await db.query('insert into auth.users values($1),($2)',[account,other]);await db.query('insert into auth.sessions(id,user_id) values($1,$2)',[session,account]);
 await applyPortableMigrations(db);await db.exec('set role service_role');
 const rpc=async(name,args)=>(await db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;
 await rpc('carry_account_enroll',[account,subject,audience,'old-encrypted-token']);
 await db.query('insert into carry_private.graph_accounts(account_id) values($1)',[account]);
 const trip=randomUUID();await db.query("insert into carry_private.graph_entities(account_id,id,kind,fields,version,subtree_version,field_versions) values($1,$2,'trip',$3,1,1,'{}')",[account,trip,{name:'Synthetic retained graph'}]);
 if(files){
  const entity=randomUUID(),sha=createHash('sha256').update('synthetic file').digest('hex'),id=randomUUID(),version=randomUUID();
  await db.query("insert into carry_private.assets(account_id,id,entity_id,entity_kind,slot,sha256,byte_count,content_type,state,expires_at,verified_at,verified_version) values($1,$2,$3,'attachment','file',$4,14,'text/plain','verified',now()+interval '1 day',now(),$5)",[account,id,entity,sha,version]);
  await db.exec('reset role');await db.query("insert into storage.objects(bucket_id,name,version) values('carry-account-assets',$1,$2)",[account+'/'+id+'/'+sha,version]);await db.exec('set role service_role');
  await db.query("insert into carry_private.graph_entities(account_id,id,parent_id,kind,fields,version,subtree_version,field_versions) values($1,$2,$3,'attachment',$4,1,1,'{}')",[account,entity,trip,{fileName:'synthetic.txt',fileAssetID:id}]);
  await db.query("insert into carry_private.asset_upload_attempts(account_id,id,asset_id,creation_id,state,location,storage_version,may_have_bytes,acknowledged_bytes,operation_id,lease_until) values($1,$2,$3,$4,'deleting','https://synthetic.invalid/tus',$5,true,14,$6,'infinity')",[account,randomUUID(),id,randomUUID(),version,randomUUID()]);
  await db.query("update carry_private.assets set state='deleting' where account_id=$1",[account]);
 }
 await rpc('carry_account_request_deletion',[account,session,subject,audience,'deletion-encrypted-token',ticket]);
 await db.query("update carry_private.carry_apple_credentials set revoked_at=now() where account_id=$1",[account]);
 await db.query("update carry_private.account_deletions set stage='purging',retry_at='infinity',operation_id=null,lease_until=null,recovery_hold_at=now()-interval '5 minutes' where account_id=$1",[account]);
 if(evidence)await db.query("update carry_private.account_deletions set recovery_provider_cleared_at=now()-interval '1 minute',recovery_provider_evidence_digest=$1 where account_id=$2",['e'.repeat(64),account]);
 const prepare=(operation=randomUUID(),overrides={})=>rpc('carry_account_recovery_prepare',[overrides.account??account,overrides.session??session,overrides.ticket??ticket,overrides.subject??subject,overrides.audience??audience,operation]);
 const commit=p=>rpc('carry_account_recovery_commit',[account,session,ticket,subject,audience,'fresh-encrypted-apple-token',p.operationID,p.fingerprints,p.assets]);
 return{db,rpc,prepare,commit,trip};
}
