# Carry 文件接口与后台清理验收记录
日期：2026-10-29。组件进度；完整账户/同步/AI 产品未交付。

## 接口契约
- `POST /functions/v1/carry-assets/reserve`：当前原生 Apple 会话；JSON 只允许 id/entityID/entityKind/slot/sha256/byteCount/contentType。稳定身份绑定账户、对象、槽位和摘要。返回 pending/verified，不因此发布行程或切换归属。
- `POST .../tus`：空请求体，固定 TUS 1.0；元数据必须匹配私有记录。返回 Carry 自身的 opaque UUID Location，永不返回 Storage URL/服务器密钥。HEAD/PATCH 只处理此会话所属对象，PATCH 单块至多 6 MiB，整个文件至多 50 MiB。
- `POST .../verify`：只接收 id。服务端读取当前 provider 对象实际字节，增量计数及 SHA256，数据库重新验证账户、会话、删除状态和同一对象版本后才返回 verified。响应丢失可重试；暂时故障不误记成文件损坏。
- `POST /functions/v1/carry-cleanup`：独立 Vault 256-bit capability + 保留 JWT 网关，空体或 `{}`；账户列表由服务端选择，调用方不能指定。最多两个账户并行，每账户一次有租约的清理；回复仅 processed/deferred 计数。专用能力不能读取行程、原文件或换取登录会话。

## 根因与 Review
1. 单份对象预留不足以约束重复/未知 TUS 上传：先落盘创建尝试，再请求 Storage；未知空 POST 计入待处理数量，允许写入字节前原子记录 may_have_bytes。已知有字节的孤儿继续占额度，确认 provider 移除后才清账。
2. 上传/校验/删除存在跨 HTTP 竞争：短数据库锁与持久操作租约包住状态转换，不在网络期间持有数据库事务；迟到创建和 ACK 保留清理线索，不恢复被删除账户。
3. Supabase Storage 可保留同一路径的历史版本：读当前非 delete-marker 对象，按 immutable version 校验及删除；旧版本回收不能移除当前已验证文件。对象查询使用 provider 索引的 C collation。
4. 定时回收不能依赖手机请求：pg_cron + pg_net + Vault，每两分钟检查，空闲不调用 Edge；全局租约及轮换账户避免重复执行与饥饿。失败保留数据库任务。尚无完整账户删除 job，这里仅完成文件回收执行器。
5. 未发起上传的过期预留没有 TUS attempt：增加无 attempt、无 provider 对象的原子清理路径，避免永久占额度。
6. 托管发现 pg_net 默认 PUBLIC 队列表/Schema 权限可能泄露凭据：追加 `restrict_cleanup_transport` 收紧，而非只在文档提醒。没有其他应用共用该新启用扩展。

## 验证
- 本地服务：`/tmp/carry-cleanup-runtime-round{1,2}.log` 每轮 81/81，实际 PGlite 执行全部九份数据/权限迁移；Storage/Auth 网络为合成依赖，不能作为真实 Apple/S3 上传证明。
- PGlite 不支持 pg_cron/pg_net/Vault/provider buckets。`migration-fixture.mjs` 显式只排除三份带 hosted-only 标记的 provider 基础设施迁移，标记与白名单不符即失败；这些迁移在托管库安装和检查，不吞 SQL 错误。
- 原生完整组件两轮 `/tmp/carry-asset-broker-resumed-round{1,2}.log`，每轮 109/109；真实 loopback HTTP 连接本地合成服务。之前一次测试因 8891 未启动失败，日志保留 `/tmp/carry-asset-broker-complete-round1.log`，未算通过。
- Release `/tmp/carry-asset-broker-release.log` 成功，strict codesign 成功；九语言 `/tmp/carry-asset-broker-i18n.log`。Debug Widget 曾报告 metadata extraction 无 AppIntents 依赖，Release 具备 Metadata.appintents；未用关告警掩盖，Debug 问题待独立根因确认。
- Deno 2.9.6 类型检查 `/tmp/carry-cleanup-deno.log` 通过；此前首次缺依赖检查错误通过官方 `--node-modules-dir=auto` 配置修正，未抑制类型错误。
- 托管 `hosted-assets-smoke.sql` 事务检查后 rollback，资产和 attempts 均为 0。首次正向清理夹具尝试 SQL 删除合成 Storage 元数据，被 provider protect_delete 拒绝；已移除此操作，保留待清理记录检查，并尊重 Storage API。没有禁用触发器或修改 provider 删除保护。
- carry-assets v2（SHA d263f166bfec51d0b06a288f203792281b5c85b690a3c30ed7b2843386046424）、carry-data v3（SHA 35c884cee471b3ac07d7679bb2779eb4fcfe6608c7587450502699f3d5d5e74e）、carry-cleanup v1（SHA eb0471aa49297fdc9d9e2e898f7fa1366498e58acc11a4f6e743d476424ffa15）部署，verify_jwt 均 true；应继续读回核对与记录后续版本变化。
- Postman CLI 1.80.0 匿名 reserve 拒绝断言通过，禁用事件上报，日志 `/tmp/carry-assets-hosted-anonymous.log`。只证明匿名拒绝。
- Vault/pg_net 实际调用 carry-cleanup HTTP 200，processed/deferred 均为 0；未取出或输出能力明文。定时任务已登记；另提交一个明确命名的合成过期预留，通过同一 dispatch → pg_net → Edge → 数据库流程清除后检查并删除合成身份，最终 assets/attempts/合成账户均为 0。错误能力得到 HTTP 401。真实含文件清理仍需正向验收。

## 未完成边界
真实 Apple 登录、实际 provider 文件上传/下载、Photos 原图收集、归属迁移、全业务入口、完整账户删除/恢复、AI scope/OAuth/MCP、真机及双设备完整两轮验收仍在继续。入口保持关闭，不上传现有私人行程，不发 TestFlight、不标记最终交付。
