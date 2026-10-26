# Carry 账户生命周期服务（未部署）

这份实现连接原生 Apple 登录与 Supabase Auth，提供身份二次核验、服务端 Apple 凭证保管、速率限制与可恢复的删除状态。它不是行程云服务，尚未实现账户旅行图、文件迁移、持久 outbox、网页登录同身份、生产通知和完整删除。**禁止打开 App 的账户发布门禁或直接部署给真实用户。**

## 文件与验证

- `lifecycle.mjs`：有界请求解析、从服务端会话确定账户、Apple 新授权与代码交换的身份绑定、成功回执边界。
- `supabase-adapter.mjs`：使用 JOSE 验证 Apple RS256/JWKS/issuer/audience/exp/iat/nonce，短期 ES256 client secret，代码交换、AES-GCM 凭据保管、Supabase 用户查询和事务 RPC。客户端不能传入 owner 来指定账户。
- `supabase/functions/carry-account/index.ts`：Deno Edge Function 入口；保留平台 JWT 检查，另向 Auth 查询当前用户。尚未在 Deno/托管环境部署验证。
- SQL：仅新增账户生命周期设施，不读写原 Carry/iCloud 数据。凭据表开启 RLS，并撤销 anon/authenticated 的直接访问与 RPC 执行权。
- 三组测试共 21 项：接口边界、真实 JOSE/加密与调用顺序、PGlite 本地 PostgreSQL 权限与状态。PGlite 不代表真实 Supabase 环境已验收；网络测试全部注入合成响应。

运行需 Node 24+：先 `npm ci --ignore-scripts`，再 `npm test`。本机 Node 24 位于 `/Users/murphy/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node`，可直接运行 `--test *.test.mjs`。测试不访问 Apple/Supabase 真实服务。

## 外部配置（尚未完成）

Supabase 项目、Apple App ID 的 Sign in with Apple 能力、关联的网页 Services ID、域名回调、Apple 私钥与团队配置均需在正确账户下核对。原生用户使用自己的 Apple 身份；开发者账户只用于发行配置。

服务端环境需要：`SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`、`CARRY_APPLE_TEAM_ID`、`CARRY_APPLE_KEY_ID`、`CARRY_APPLE_PRIVATE_KEY`、逗号分隔的 `CARRY_APPLE_CLIENT_IDS`，以及 32 字节随机 AES 密钥的 Base64 值 `CARRY_ACCOUNT_ENCRYPTION_KEY`。密钥只放服务端安全配置，不写入仓库、App 或日志。换加密密钥前必须有版本化重加密与恢复方案，不能直接覆盖旧密钥。

App 仅从被 gitignore 的 `Carry/Resources/Secrets.plist` 读取 `CarryAccountProjectURL` 和 **publishable** key `CarryAccountPublishableKey`。拒绝 `sb_secret_`；`CarryAccountReleaseReady` 必须显式为 true 才开放入口。该标记当前保持缺省/关闭，只有完整产品链路验收通过后才可开启。DEBUG 可用进程参数 `--carry-account-design` 检查未配置页面；它不持久化、不创建假身份，Apple 按钮保持禁用。

## 删除门禁与恢复

`carry_account_purge_owned_data` 当前明确报错 `account_data_purge_not_implemented`，防止只删除 Auth 用户却遗留行程、文件和 AI 授权。这是尚未完成的工程门禁，不是可上线的删除实现。

后续必须在同一账户删除流程中：阻断账户 API/AI 新写入，撤销所有身份对应 Apple 授权，清理账户数据/文件与设备和 AI 授权，最后删除 Auth 用户。各步骤要有持久进度、失败恢复和重试证据；幂等删除、离线设备副本、令牌重放、Apple 撤销失败、附件清理失败、并行登录/删除都需真实验收。当前事务将账户标成 deleting，禁止重新登录将其恢复 active；并发跨外部服务的完整恢复仍待实现。

生产还需 Apple 服务器通知及其验证、撤销后阻断账户会话、完整备份恢复、国内无代理和境外网络测试、日志与费用告警、隐私说明更新。首次验证只使用合成数据，不上传既有 13 个真实行程。
