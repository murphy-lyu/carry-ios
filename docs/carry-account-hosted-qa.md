# Carry 免费开发环境与云端数据库验收

日期：2026-10-26。结论：Supabase 插件授权已验证，`Neve Studio` 下的独立 `carry-dev` 项目已创建并健康；开发库结构及权限检查通过。生产账户、Apple 登录、同步和对话操作尚未交付。

2026-10-27 补充：开发库已追加数据图/费用兼容迁移，部署 `carry-data`，新增原生副本与迁移编解码组件；下面是 10 月 26 日的历史记录。最新证据及尚未完成的整项门禁见 [账户数据与离线副本验收](carry-account-graph-qa.md)。

## 实际变更

- 组织当前 Free，创建项目报价为 $0/月；未升级套餐、开付费分支或额外服务。
- 地区 `ap-southeast-1`（新加坡），PostgreSQL `17.11.0.003`，GA。项目状态读回为 `ACTIVE_HEALTHY`。
- 新建时检查 public 无业务表；随后部署两个生命周期迁移。云端历史与本地文件版本均为 `20261026151820_carry_account_lifecycle`、`20261026152013_account_private_credentials`。后者由 Supabase CLI 2.122.0 生成，应用后按实际云端版本对齐文件名。
- 凭据与限流表移到 `carry_private`，启用 RLS，撤销 public/anon/authenticated 的 schema/表访问。后台明确获得所需权限，凭据读取改经仅 service_role 可执行的 RPC。
- 五个公开 schema 的生命周期 RPC 全为 `SECURITY INVOKER`，固定空 search_path；anon/authenticated 无 EXECUTE，service_role 有 EXECUTE。无需 public SECURITY DEFINER 绕过权限。
- 取得项目 publishable key，写入本 worktree 被 gitignore 的 `Secrets.plist`，权限 0600；保留其他既有配置。账户发布标记仍为 false；未把 key、服务端密钥或 Apple 私钥加入仓库。
- Edge Functions 列表为空。未把缺少 Apple 密钥/完整删除的服务部署成可用登录入口，也未更动现有 Cloudflare MCP Worker。
- 用系统 Xcode 账户执行允许更新 provisioning 的真机 Debug 构建，成功签名；实际 App 和 embedded profile 均含 `com.apple.developer.applesignin = [Default]`，Team 为 `25RAM7275Z`、App ID 为 `25RAM7275Z.app.nevestudio.carry`、CloudKit 为 Development。`codesign --verify --deep --strict` 通过。未安装到用户手机，不把签名通过等同于 Apple 登录成功。
- 通过项目公开 Auth settings 读回 `apple=false`、`email=true`、`anonymous_users=false`。Apple provider 尚未配置；没有创建邮箱测试用户或发送验证邮件。现有插件工具不提供 Auth provider 配置或 Secret 管理，不能凭 SQL 权限声称这些外部配置已完成。

## 两轮检查

| 范围 | 第一轮 | 第二轮 | 实际边界 |
|---|---|---|---|
| 本地服务代码、JOSE/AES、PGlite | 21/21 | 21/21 | 合成 provider 响应，不是 Apple 登录 |
| 托管 PostgreSQL 生命周期脚本 | 通过 | 通过 | 真实新加坡开发库，合成 auth fixture，全部事务回滚 |
| 真实 HTTP 权限负向探针 | 3/3 | 3/3 | 使用 publishable key，不使用任何真实用户会话 |

托管脚本 `scripts/carry-account-service/hosted-lifecycle-smoke.sql` 验证登记、账户隔离、20 次限流与窗口恢复、删除状态不可被重新登记复活、未实现 purge 必须报错，以及 RPC 权限。两轮回滚后 auth 用户、凭据、限流记录均为 0。此检查不能冒充通过 Supabase Auth API 创建、登录或撤销了真实身份。

HTTP 脚本 `scripts/carry-account-service/hosted-http-smoke.mjs` 必须显式传入开发项目地址与 publishable key，不打印 key。私有凭据表请求返回 404/PGRST205；读取凭据与登记 RPC 均返回 401/42501（数据库权限拒绝）。通用网关 401、无效 key 或网络超时不会被算作测试通过。

本地服务日志 `/tmp/carry-account-private-round{1,2}.log`；HTTP 日志 `/tmp/carry-account-hosted-http-round{1,2}.log`。原生代码未在本次改动中修改，沿用 `carry-account-qa.md` 中独立的两轮 60/60 记录，不冒充本次重跑。

## Advisors 与工具边界

- Security：无 ERROR/WARN；有两条 INFO `rls_enabled_no_policy`，对应后台专用私有表。无公开策略配合撤销访问权限，保持默认拒绝；不为了消除提示而开放用户权限。[官方说明](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)
- Performance：无提示。
- CLI 的 `migration list --local` 因本机没有运行本地 Supabase PostgreSQL（127.0.0.1:54322 拒绝连接）未通过。没有为此安装/启动额外服务；云端版本由插件读取核对，本地行为由 PGlite 实际运行验证，不能称为完整 CLI 本地环境验收。
- 浏览器重启后能发现 Supabase 标签页，读取仍超时。改用已授权插件完成云端操作，没有继续修改用户浏览器权限。
- 已读取 Supabase changelog，核对 TLS CBC 退役及 PostgreSQL 17.11 升级说明；本次使用系统现代 TLS、AES-GCM，无遗留 CBC/PGP 数据和相关旧索引。此核对不替代国内无代理的设备网络验收。

## 尚需完成

1. Apple App ID 登录 capability 与正确团队 Development 签名现已验证；关联 Services ID/回调、安全保存的 Apple key、Supabase Apple provider，以及原生/网页实际身份归并仍未完成。插件授权只授予其已提供工具的管理访问，不等于已完成所有 Apple 配置。
2. 完整账户旅行图、持久 outbox、迁移与附件、冲突与恢复、AI 权限、完整账户删除和服务器撤销通知；现有 purge 门禁继续拒绝成功。
3. 真实设备 UI、双设备、国内无代理/境外网络、完整备份与恢复演练。

用户休息期间只推进已授权的免费开发环境和合成数据检查。没有真实行程上传、现有私人库迁移、付费升级、生产发布或 TestFlight 上传。
