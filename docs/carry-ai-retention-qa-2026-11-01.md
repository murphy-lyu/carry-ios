# AI 过期记录清理验收

日期：2026-11-01。承接已有保留政策，不新增公开接口、清理密钥或业务数据删除能力。

## 实现与边界

- 原 `maintainAIRecords` 的 SQL 收敛为 `maintenance.sql` 中唯一的 `carry_ai.maintain_records(bigint,integer)`，Node 适配器及数据库定时任务调用相同函数。
- 每次每类最多 1,000，默认排程每 15 分钟各 500；候选行使用 `FOR UPDATE SKIP LOCKED`，全部处理在同一事务中。调用者不能扩大上限或传空参数。
- 清除过期 authorization/code/access/export/refresh、过期超过一天的 preview、30 天前的 undo，以及超过一天的限流窗口。有效 refresh（包括已使用凭据的重放证据）继续保留。
- 30 天前 receipt 仅去掉 before/after/mutations 并标记 undoExpired，请求身份及其余幂等证据保留；不删除 native graph 回执、行程、附件或 Storage 对象。
- 函数 SECURITY INVOKER、空 search_path、完整限定表名；public/anon/authenticated 不可执行，只有已有 service_role 与数据库作业所有者可调用。没有新增 HTTP 清理入口或密钥。
- 两份迁移由 Supabase CLI 生成：`20261101081026_account_ai_bounded_retention.sql` 与 `20261101081124_install_ai_retention_scheduler.sql`。后者为明确列入 fixture 白名单的 hosted-only pg_cron 安装，不以本地执行冒充排程已运行。

## 检查与修正

- 新测试核对部署迁移包含精确的 canonical routine、客户端执行拒绝、service 执行权限、每批上限、receipt 正文清除与身份保留、有效 refresh 保留、非法参数与排空后幂等。
- 保留原实际 SQL 的 refresh 轮换/重放检查，改走同一私有函数。局部 13/13 通过。
- 首次完整回归因新增 hosted-only 迁移尚未登记 fixture 白名单而报 `migration_runtime_marker_mismatch`，均未计为通过。按现有显式列举机制登记新排程后，重新执行完整两轮：AI 各 101/101；账户服务各 120/120，0 失败。
- 本机证据 `/tmp/carry-ai-retention-final-r{1,2}-20261101.log`、`/tmp/carry-service-retention-final-r{1,2}-20261101.log`。旧失败日志保留。
- 自行 Review：不同保留时间未混淆；有效 refresh 与请求身份不清除；新表为 0，不需要修改账户删除白名单；作业不依赖手机、浏览器会话、公开 HTTP 能力或 Secrets。单次限量不会变成无限循环。

## 云端状态

- 只读预检查实际返回：pg_cron 已安装、名为 carry-ai-retention 的作业 0、AI grant 0；迁移历史表字段已核对。
- 用户在本次确认回复中要求按建议直接操作，随后完成部署。两份迁移历史及唯一 active job 已实际读回为 `2 / 1`，排程为 `*/15 * * * *`，每类处理上限 500；没有新增 HTTP 清理凭据。
- 实际函数体 MD5 与审核源码一致、SECURITY INVOKER 为 true；迁移历史中两份 SQL 的 SHA-256 均与仓库文件匹配。anon/authenticated 执行权限 false，service_role true。
- 首次手动执行同一定时命令成功：records=0、compactedReceipts=0、rateBuckets=0，当前没有到期项。行程实体/文件仍为 `4 / 1`。核验片段：`https://supabase.com/dashboard/project/lbxsvguuoqqpctkinpwy/sql/ee200b71-012d-4cef-a1a5-d82809e63c18`。
- 真实托管 PostgreSQL 上再执行合成事务：到期 preview 清除、30 天前 receipt 正文去除但身份保留、有效且已使用 refresh 证据保留、旧限流桶清除、每类上限生效。事务全部 rollback，读回 `hosted_retention_rollback_passed / 0 / 4 / 1`，没有遗留合成记录。核验片段：`https://supabase.com/dashboard/project/lbxsvguuoqqpctkinpwy/sql/98507974-7c54-4d29-82d2-043aca5b94bd`。
- 定时任务已启用，手动实际执行和合成回滚验收通过；首个自然调度的 cron 运行日志尚未观察，不把手动执行称为自动调度已运行。
