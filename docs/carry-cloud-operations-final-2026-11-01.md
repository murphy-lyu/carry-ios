# 账户文件预算与供应商运行准备

日期：2026-11-01。承接已确认的账户/云同步/AI spec（附件要求配额与清理）。前几节为方案与本地验证记录，实际部署以末尾收尾记录为准；不制定正式收费方案，不购买套餐。

## 文件预算根因与实现

真实入口为 `carry-assets → createAssetUploadAdapter.reserve → public.carry_asset_reserve`。原链路仅查人工插入的 `asset_budgets`，没有新账户分配路径；此前唯一开发账户的手工预算不能使其他账户正常上传。

新增 CLI 生成的 `20261101084027_account_asset_budget_policy.sql`：

- 私有 singleton policy 显式配置 enabled、每账户字节数、pending 数、项目已分配总额上限。默认关闭、数值为0，部署本身不会给账户分配容量。
- 登录/注册不分配容量。首次有效且已通过原生会话校验的文件 reserve 遇到缺预算时，才按策略幂等分配；畸形参数或跨账户会话不占项目池。
- 原账户事务锁保留；自动分配及预算 DML 共用 policy 行 `FOR UPDATE`；预算表 BEFORE STATEMENT 在任何预算行锁之前取得全局锁，避免运营方批量更新与账户 purge 反向锁序。既有手工预算全额计入全项目池，超额拒绝新分配/增额。池上限低于既有分配时不修改或撤销旧账户预算。
- 关闭策略阻止新自动分配，既有预算继续使用。并发/重试受账户预算主键及事务锁约束，单一有效请求不会创建多份预算。
- 预算触发器禁止更换 account_id；禁止把额度降至已计费资源以下；文件或上传尝试尚未物理清理时不能提前删除预算释放项目容量。
- 保留原已审计的 manifest/身份/上传尝试记账函数为私有 `asset_reserve_core`，public 同名包装只处理精确的缺预算异常，其他错误原样拒绝。不复制或放宽原50 MiB最坏物理上传计费逻辑。
- 新 policy 无 account_id，属于运营配置；账户 purge 既有未来表防护不需要放行新用户数据表。表和函数保持私有/RLS默认拒绝、SECURITY INVOKER，客户端不能读改配额。

## 验证与部署范围

- 预算专属6/6通过：默认关闭、登录不分配、非法/跨会话拒绝、原人工预算与池耗尽、关闭后已有预算、重复/竞争请求、物理资源保留、非法配置与权限。
- 最终Review把预算DML全局锁从行级提前到语句级，避免批量更新/删除的锁序问题。修正后服务完整两轮各126/126（原120项加6项），0失败；日志 `/tmp/carry-cloud-budget-final-r{1,2}-20261101.log`。首次测试命令从仓库根找不到测试文件，仅命令路径错误，未计通过；改为服务目录后运行。
- PGlite 是单连接，Promise 竞争用例不声称真实多 PostgreSQL 会话争用已实测；全局写锁与原账户锁均已逐行Review，真实多会话/托管行为仍需外部验收。
- 已准备且在本地实际 PostgreSQL兼容引擎通过 `scripts/carry-account-service/hosted-budget-policy-smoke.sql`（读回 rollback_passed、实体/文件0/0；不当作真实云端通过）：在托管 PostgreSQL 中建立纯合成会话/manifest，核验原人工分配计入池、有效请求分配、重复请求、跨会话、池满和关闭门禁，事务全部 rollback，无供应商上传。
- 本 agent 未直接部署；无需改 Edge Function，因为 RPC 名称、参数和响应保持不变。主 agent 应先安装 migration 并执行托管 rollback 检查，再按运营环境配置策略。

## carry-dev 受限验收配置建议

官方 [Supabase Pricing](https://supabase.com/pricing) 于2026-11-01核对：Free 含1 GB文件存储；这是供应商总量，不是 Carry 向用户承诺的免费额度。

建议仅在 carry-dev 验收使用每账户150 MiB、最多3个pending、项目总分配450 MiB（包含当前人工150 MiB）：可容纳3份完整预算，为供应商其他占用/后台清理保留余量，无需为此购买套餐。启用前仍须读回项目所有桶实际用量及现有预算总额；存储分配保护不替代供应商流量、数据库、备份和告警管理。

```sql
update carry_private.asset_budget_policy
set enabled=true, per_account_bytes=157286400,
    maximum_pending=3, total_allocated_bytes=471859200
where singleton;
```

这是已分配预算的严格容量池，未用满的账户额度仍占池，不按稀疏实际占用软超配。这组参数未自动启用。正式单用户额度、超额后的产品文案/升级途径、是否收费仍属于上线产品政策，不能根据目前一个测试账户推导或擅自承诺；机制已可配置，不必为这些商业数值重写存储链路。

## 高德 AI 查询准备

- 实际调用链：`edge-entry.ts` 从服务端环境读取 `CARRY_AMAP_WEB_KEY`，传入 `queries.mjs` 的境内地点查询；固定上游为 `https://restapi.amap.com`，缺配置会返回 `domestic_places_configuration_required`，没有返回空成功或转发境内查询到海外提供商。
- 对受限配置目录仅检索键名/文件位置，未读取或打印值：`/Users/murphy/Library/Application Support/Carry Development Secrets/*.json` 与 `*.env` 未找到 `CARRY_AMAP_WEB_KEY` / `AMAP_WEB_KEY` / `AMAP_API_KEY` / `GAODE...KEY`。这不能证明云端不存在该 Secret；主 agent 需在已登录管理台核对键名。
- App现有地点搜索走Apple MapKit，没有独立高德SDK接入。新增云端AI查询才需要单独服务选型及合法Web服务凭据；不能让用户误以为现有手机搜索依赖这次高德注册。本 agent 未新建高德账户、接受条款、创建密钥、购买或发起真实付费供应商请求。

## 实际 carry-dev 收尾（主任务，2026-11-01）
- 已只读核对全部Storage：1个合成对象，131072 bytes，未知大小0；既有人工预算157286400 bytes。
- 安装20261101084027迁移后读回默认false/0/0/0。空白SQL查询完整执行hosted-budget-policy-smoke.sql等价合成事务，返回hosted_budget_policy_rollback_passed，现有实体/文件7/1（包含Codex新建测试trip的3个实体），未留下合成账户或manifest。首次编辑器粘贴未完全替换旧SQL导致语法错误，未当通过；只读活动查询无锁等待，重建空白输入后通过。
- 已显式启用carry-dev受限策略：enabled=true，per_account_bytes=157286400，maximum_pending=3，total_allocated_bytes=471859200，当前assigned=157286400。
- 预算write_lock与guard均启用；anon/authenticated不能执行ensure_asset_budget，service_role可以。未购买服务或改变正式收费政策。
- 原retention唯一active job，近2小时自然成功7次。用户当次确认后已安装20261101101210临时注册清理，维护body MD5 17f5839f0cddf2ed4766cadd49032e58与本地原文一致，引用索引存在；客户端数8，无扩大客户端权限。
- Supabase Edge Secrets完整名称清单已检查：包含现有Apple/bridge/flight/places等配置，但没有CARRY_AMAP_WEB_KEY。仅检查名称，未读取/输出值或digest。境内AI地点查询仍需合法的高德Web服务Key，现有海外places代理明确排除境内，不能转去境外或复用iOS SDK Key冒充Web Key。
- 用户后续自行完成高德个人支付宝认证，已从控制台只读确认成功。未创建Key或购买套餐；正式产品用途、新加坡后端及全球用户的许可仍需单独核实，详见AI registry报告的服务选型待办。手机MapKit搜索不受该待办影响。
