# AI 注册存量与云端收尾核验（2026-11-01）

## 修复与边界
公开 DCR 原来只按分钟限流，成功注册永久留在数据库；攻击者可以持续增加数据库占用。新增持久存量上限：1024 个客户端、16MiB 规范 JSON 元数据（每个尚未使用的注册额外预留 40 bytes，用于首次授权标记）。历史注册和手动插入的数据均计入；超过上限时仅拒绝新注册，返回 `client_registration_capacity_exhausted` / 503。现有授权、访问令牌和刷新不受注册容量门禁影响。服务端注入参数允许调低限额，禁止调至无限或超过默认上限。这是资源保护参数，不是商业套餐政策。

注册、创建待确认请求和维护任务共用事务级 advisory lock，核算与插入在同一数据库事务内完成。成功授权给客户端写入 `usedAt`；之后即使删除用户导致 grant 被清除，该客户端仍保留。维护每次最多清理 `p_limit` 个超过 24 小时、带新版本标记且从未使用、没有 authorization/code/grant 引用的客户端。有效待确认请求有引用，不能被清理；刚过期请求先清除，客户端在下一轮才可能进入候选。历史无版本标记的注册无法证明从未使用，全部保留。注册拥塞时不自动扩容；需要运维查看计数并判断滥用或容量调整。

增加 `ai_records_client_reference` 部分表达式索引，避免每个候选都扫描所有账户数据。原有 10 分钟 pending TTL 不变。无真实行程、文件、凭据变更。

## 部署项
需要重新部署使用 `postgres-store.mjs` 的 carry-ai Edge Function，并安装 CLI 生成的新 migration `20261101101210_bounded_ai_client_registry.sql`。建议先安装 migration（只回收带新标记记录，旧代码不会产生该标记），再部署 Edge Function。原有 cron 名称与调度无需变更；新维护函数增加 `unusedClients` 计数。历史已部署 migration 不修改。未在本任务部署或提交。

## 测试与 Review
定向命令：Node 24 `--test postgres-store.test.mjs maintenance.test.mjs`。两轮各 15/15，通过容量拒绝、重复 ID、原授权及 refresh、维护有界性、有效 pending、历史及已用客户端保留、过期 pending 下一轮清理、客户端角色权限与新 migration 原文一致性。日志 `/tmp/carry-registry-r1.log`、`/tmp/carry-registry-r2.log`。PGlite 是单连接测试，不能据此声称完成真实 PostgreSQL 多连接并发实测；互斥锁顺序和事务边界已静态 Review。

## 尚需真实云端读回的最短步骤
1. 读回资产预算 migration 是否安装、所有 Storage 对象总字节/未知大小数与已有预算总额。
2. 若未安装，安装 `20261101084027_account_asset_budget_policy.sql`（默认关闭），运行 `hosted-budget-policy-smoke.sql` 的全事务回滚验收，再显式启用受限开发额度：每账户 150MiB / 3 pending，全项目已分配池 450MiB，包含既有手动额度。已有总额超过池时禁止新分配，已有额度保留。不要把该值当正式收费方案。
3. 读回 policy、触发器和执行权限；自然 cron 从运行历史确认成功，勿以手动执行代替自然调度验收。
4. 核对 Supabase Edge Secrets 是否有 `CARRY_AMAP_WEB_KEY`。本机开发秘密目录仅查键名/文件名未发现匹配，不代表云端不存在。不能用 `vault.secrets` 代替 Edge Secrets 检查，也不能把 iOS SDK key 当 Web 服务 key。已有授权 CLI 可 `supabase secrets list --project-ref lbxsvguuoqqpctkinpwy`，只转出名称及目标键存在布尔值；不打印值或 digest。缺少 Web 服务 key 时国内查询按现有协议返回 `domestic_places_configuration_required` / 503，不回退境外服务。

以下 SQL 全部只读，不返回账户身份、文件名、令牌或行程内容。policy 查询需先确认 migration 已安装。

```sql
select exists(select 1 from supabase_migrations.schema_migrations
 where version='20261101084027') as budget_migration_installed,
 to_regclass('carry_private.asset_budget_policy') is not null as policy_exists,
 to_regprocedure('carry_private.ensure_asset_budget(uuid,uuid)') is not null as allocation_helper_exists;

with sizes as (
 select bucket_id,case when metadata->>'size' ~ '^[0-9]+$'
 then (metadata->>'size')::numeric end as bytes from storage.objects
)
select coalesce(sum(bytes),0) as stored_bytes,
 coalesce(sum(bytes) filter(where bucket_id<>'carry-account-assets'),0) as other_bucket_bytes,
 count(*) filter(where bytes is null) as unknown_size_objects,
 (select coalesce(sum(maximum_bytes),0) from carry_private.asset_budgets) as assigned_budget_bytes
from sizes;

select enabled,per_account_bytes,maximum_pending,total_allocated_bytes,
 (select coalesce(sum(maximum_bytes),0) from carry_private.asset_budgets) as assigned_budget_bytes,
 exists(select 1 from pg_trigger where tgrelid='carry_private.asset_budgets'::regclass
  and tgname='asset_budget_write_lock' and tgenabled='O') as budget_lock_enabled,
 exists(select 1 from pg_trigger where tgrelid='carry_private.asset_budgets'::regclass
  and tgname='asset_budget_guard' and tgenabled='O') as budget_guard_enabled,
 has_function_privilege('anon','carry_private.ensure_asset_budget(uuid,uuid)','execute') as anon_can_allocate,
 has_function_privilege('authenticated','carry_private.ensure_asset_budget(uuid,uuid)','execute') as authenticated_can_allocate,
 has_function_privilege('service_role','carry_private.ensure_asset_budget(uuid,uuid)','execute') as service_can_allocate
from carry_private.asset_budget_policy where singleton;

select j.schedule,j.active,last.status,last.start_time,last.end_time,
 (select max(end_time) from cron.job_run_details d where d.jobid=j.jobid and d.status='succeeded') as last_success,
 (select count(*) from cron.job_run_details d where d.jobid=j.jobid and d.status='failed'
  and d.start_time>now()-interval '1 day') as failed_last_day
from cron.job j left join lateral (
 select status,start_time,end_time from cron.job_run_details d
 where d.jobid=j.jobid order by start_time desc limit 1
) last on true where j.jobname='carry-ai-retention';

select count(*) as client_count,
 coalesce(sum(octet_length(value::text)),0) as client_json_bytes,
 count(*) filter(where value->>'registryVersion'='1') as bounded_version_clients,
 count(*) filter(where value->>'usedAt' is not null) as used_clients
from carry_ai.records where bucket='client';
select exists(select 1 from supabase_migrations.schema_migrations
 where version='20261101101210') as registry_retention_migration_installed,
 to_regclass('carry_ai.ai_records_client_reference') is not null as reference_index_exists;
```

## 实际 Codex 刷新请求兼容补验
真实客户端刷新可能携带 `scope` 并省略 `resource`。协议层将缺省 resource 绑定到服务端 canonical resource，授权码交换仍强制精确 resource；存储层仅接收已解析 `requestedScopes`。新增校验要求 scope 集合与已授权范围完全一致（顺序可不同），未知、扩大、缩小或错误类型均 `invalid_scope`，且不消费原刷新令牌。不存在刷新时修改授权范围的能力。spent 令牌重放先执行 family 撤销并提交，错误 scope 不能跳过撤销。生产 PostgreSQL adapter 与纯合成 adapter 同步实现。

定向运行 `--test postgres-store.test.mjs synthetic-refresh.test.mjs` 两轮各 14/14；包括 scope 不符多次失败后原 token 仍可精确 scope 刷新、原 grant scope 不变、spent 携带错误 scope 仍撤销新 access，且在重新打开 PostgreSQL store 后撤销仍有效。日志 `/tmp/carry-refresh-scope-r1.log`、`/tmp/carry-refresh-scope-r2.log`。本项无需额外 SQL migration，重新打包 Edge 即可。

## 后续改进待办
用户已要求正式上线前评估更优的注册生命周期方案。完整清单见 specs/carry-cloud-and-ai.md「生产前待办：AI 客户端注册生命周期」：依据脱敏实际指标调整TTL/容量，减少重复注册，设计已用客户端安全退役和上限恢复体验。当前保护参数仅供开发验收，不等同于生产最终方案；后台自动维护，不向普通用户反复请求清理确认。

## 桌面重新认证实测（2026-11-01）
用户截图显示 carry-account 认证过期及重新认证未完成。当前对话 `list_trips` 首次实测返回 `Authentication required`。在用户已打开的重新认证页面完成原范围授权（创建、读取、编辑，仅限此连接创建的行程），浏览器显示 `Authentication complete`；随后当前对话 `list_trips` 成功返回空集合。新连接不会自动继承旧连接创建的测试行程权限，空集合不代表删除账户或行程。本次只证明重新认证恢复成功；此前认证失效原因及长期刷新稳定性仍待核验，不能记为已修复根因。

随后持续用当前桌面连接完成正常创建及多次读回，跨过15分钟access有效期后仍成功。只读后台计数由spent_refreshes=0变为1，同时live_refreshes=1、live_accesses=1、revoked=false，实际桌面自动续期成功一次。旧CLI连接未撤销、保留有效refresh，不能将旧会话失效归因为已证实的重放；本次未再次启动共享凭据的独立app-server，避免在验收中引入第二个令牌使用者。短周期自动续期通过不等于长期多进程兼容性已全部验收。

## 国内云端地点服务选型待办（2026-11-01）
已从高德控制台核实个人支付宝认证通过，尚未创建或安装 Web 服务 Key。手机地点搜索现用 Apple MapKit；本项只涉及新增的云端 AI 国内地点查询。启用前须核实正式产品用途、新加坡后端及全球用户的许可和服务适用性，个人实名认证不能代替上述许可。参考 https://lbs.amap.com/pages/terms/ 。选型确认前保持云端对应查询关闭，不影响现有手机地点搜索，不购买套餐。
