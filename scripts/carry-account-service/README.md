# Carry 账户与数据服务（免费开发环境）

2026-10-27：`carry-dev` 已部署五份迁移及 `carry-data` v1；原生/网页身份生命周期 `carry-account` 仍未部署。完整验收范围见 `../../docs/carry-account-graph-qa.md`，早期身份验证见 `../../docs/carry-account-hosted-qa.md`。

当前已有账户图事务、独立原生副本、完整备份图/文件编解码组件；全 App 写入口路由、实际资产迁移、网页登录同身份、新 AI 权限/执行和完整删除尚未完成。**不能开启 App 账户发布门禁或直接向真实用户发布。**

## 模块

- `lifecycle.mjs` / `supabase-adapter.mjs`：Apple 新授权/代码交换二次绑定、AES-GCM 凭据保管、限流和删除状态。`carry-account/index.ts` 需要 Apple 服务端配置，仍未部署。
- `graph-schema.mjs`：业务字段封闭契约；`graph-schema.test.mjs` 对照原生 Backup DTO 检查遗漏。原始费用/币种保持真相，兼容空币种和 -1 快照，不将真实 0 元费用当成未记录。
- `graph-transactions.sql`：首份数据图迁移的可读源码；已部署历史不可重写，后续变更追加迁移。私有表开启 RLS、客户端无访问权限，RPC 仅服务端可调用。
- `graph-http.mjs` / `graph-adapter.mjs`：请求体有界、当前用户验证、会话/账户绑定、业务错误去敏化。全账户接口拒绝 OAuth 客户端 JWT/会话，不能把 AI 登录自动升级为全账户访问。
- `supabase/functions/carry-data/index.ts`：已部署开发接口。保留 `verify_jwt=true`，handler 再查询当前用户，数据库核对有效非 OAuth 会话与已登记账户。服务密钥只使用 Edge 自带的服务器环境，不进入 App。
- `hosted-graph-smoke.sql`：托管库合成事务与 rollback，覆盖实际 service_role、隔离/版本/失败回滚/费用等。
- `hosted-http-smoke.mjs`：Data API 六项权限负向检查；`hosted-edge-smoke.mjs`：平台与实际 handler 身份拒绝检查。只允许显式开发地址/public key；可选 legacy anon JWT 必须是当前项目的公开 anon 身份，禁止服务 key。
- `graph-qa-server.mjs`：仅本地真实 HTTP/PostgreSQL QA。必须 `CARRY_GRAPH_QA=synthetic-only`，固定合成身份，监听 127.0.0.1；**不可部署**，不是真实认证替代品。

## 本地验证

运行需 Node 24+，安装依赖使用 `npm ci --ignore-scripts`。本机运行时：`/Users/murphy/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node`。在本目录执行 `--test *.test.mjs`，当前测试集 44 项；provider 网络返回为合成夹具，PostgreSQL/PGlite 实际执行。

原生实际 HTTP 测试先启动 `graph-qa-server.mjs`，再运行共享 `CarryAutomationTests` scheme，排除需要另一个旧服务的 `RelayRoundTripTests`。`AccountGraphMigrationTests` 的费用集成项与 `AccountGraphRoundTripTests` 都依赖 127.0.0.1:8891；不应在未启本地 QA 服务时把网络失败跳过并算通过。

历史失败、修复和正式复跑日志路径记录在 QA 文档；编译/模拟器/实际 HTTP/真实 Apple/物理设备/生产验收分别记录。

## 外部配置（尚未完成）

Supabase 免费开发项目已建立；原生 App ID/正确团队签名能力及 Supabase 原生 provider 已核对；关联的网页 Services ID、域名回调和 Apple 私钥尚需配置。原生用户使用自己的 Apple 身份；开发者账户只用于发行配置。

服务端环境需要：`SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`、`CARRY_APPLE_TEAM_ID`、`CARRY_APPLE_KEY_ID`、`CARRY_APPLE_PRIVATE_KEY`、逗号分隔的 `CARRY_APPLE_CLIENT_IDS`，以及 32 字节随机 AES 密钥的 Base64 值 `CARRY_ACCOUNT_ENCRYPTION_KEY`。密钥只放服务端安全配置，不写入仓库、App 或日志。换加密密钥前必须有版本化重加密与恢复方案，不能直接覆盖旧密钥。

App 仅从被 gitignore 的 `Carry/Resources/Secrets.plist` 读取 `CarryAccountProjectURL` 和 **publishable** key `CarryAccountPublishableKey`。拒绝 `sb_secret_`；`CarryAccountReleaseReady` 必须显式为 true 才开放入口。该标记当前保持缺省/关闭，只有完整产品链路验收通过后才可开启。DEBUG 可用进程参数 `--carry-account-design` 检查未配置页面；它不持久化、不创建假身份，Apple 按钮保持禁用。

## 删除门禁与恢复

`carry_account_purge_owned_data` 当前明确报错 `account_data_purge_not_implemented`，防止只删除 Auth 用户却遗留行程、文件和 AI 授权。这是尚未完成的工程门禁，不是可上线的删除实现。

后续必须在同一账户删除流程中：阻断账户 API/AI 新写入，撤销所有身份对应 Apple 授权，清理账户数据/文件与设备和 AI 授权，最后删除 Auth 用户。各步骤要有持久进度、失败恢复和重试证据；幂等删除、离线设备副本、令牌重放、Apple 撤销失败、附件清理失败、并行登录/删除都需真实验收。当前事务将账户标成 deleting，禁止重新登录将其恢复 active；并发跨外部服务的完整恢复仍待实现。

生产还需 Apple 服务器通知及其验证、撤销后阻断账户会话、完整备份恢复、国内无代理和境外网络测试、日志与费用告警、隐私说明更新。首次验证只使用合成数据，不上传既有 13 个真实行程。
