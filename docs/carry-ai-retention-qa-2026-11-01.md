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
- 部署事务已准备在本机 `/tmp/carry-ai-retention-deploy-20261101.sql`，包含两份迁移及其真实历史记录，尚未执行。
- 已按浏览器规则请求用户当次确认启用不可恢复的过期记录清理；确认前不运行删除或安装自动排程。启用后仍需读回两份迁移、唯一 active job、执行结果及权限。当前不能声称托管排程完成。
