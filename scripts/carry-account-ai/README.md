# Carry 账户 AI 服务组件

该目录实现新账户协议和领域编译器，取代“配对手机前台执行”作为最终架构。2026-11-01，carry-dev及公共connect账户网关已明确启用用于验收，旧设备relay保留。真实Apple原生/网页同账户、Codex OAuth、当前对话创建/改名/读回及一次真实自动续期已通过；合成行程已到Mac/iPhone，附件上传、核验下载及Mac Quick Look通过。这些证据不代表已正式发布。最新状态见 `../../docs/carry-cross-device-final-qa-2026-11-01.md`；剩余物理场景及原生并发编辑修复以该报告和progress为准。

## 已实现

- OAuth2.1 public client registration、S256 PKCE、精确 redirect/resource、单次短期 code、轮换 refresh family、每请求撤销/过期核验、当前账户状态、第一方连接管理。
- 云同步身份与 AI grant 分开；精确行程、仅本连接新建、物品库、附件、偏好和私密预订字段独立授权。导入内容、搜索结果和备注不授予任何权限。
- MCP stateless Streamable HTTP JSON；返回 `saved_to_account` 与 `deviceState:not_observed`，不创建或等待设备任务。只有服务器确认业务图/回执同事务落盘后才返回成功。
- 十类业务对象的字段清单、父子约束、版本/字段基线、创建/编辑/移动/完整排序/删除/恢复、完整行程及天创建、脱敏复制。
- 确定性行程/子项身份与计划内 `@ref/day/N` 引用；一整套计划编译成一个逻辑事务。字段校验复用账户 Graph manifest，最终领域规则仍由同一个 Graph core 在事务内判断。
- 不可变预览、具体修改前后值、版本与影响范围；第一方用户批准 contentHash 后同请求原子提交。任何 `confirmed:true` 或相同 requestID 的普通写入都不能跳过已建立的预览。
- 撤销由 store 依据已接受的 before/after image 生成带版本的反向计划，再经预览/确认。后续编辑产生冲突，不能整库覆盖回旧快照。
- 私有附件、原图及封面最多64KiB分块读取，实际适配绑定当前账户/grant/所选行程、活跃实体槽位、verified ledger 和不可变 Storage version；网络读取前后重新授权，不返回 provider/signed URL。Native资产服务继续单独验证原生会话。
- 完整选定行程导出为可还原的 CarryBackup，保留关系、原币/时区、打包状态、封面裁剪、附件、缩略图及照片原图；缺失原图明确拒绝。完整导出与原生恢复共用128MiB总文件预算（含缩略图）、附件原文件25MiB/其他资产50MiB上限；包含metadata、manifest、base64和JSON结构的最终文件上限256MiB，AI生成前精确估算，原生写出后与读入前均检查；原生恢复最多20,000个全局唯一业务实体；超限明确报错，保留按行程导出，不截断文件。分享导出为脱敏 .carrytrip，排除打包、照片、附件、背景、私密预订字段及提醒设置。
- 导出生成、第一方具体内容预览/批准、私人下载与发送分开。10分钟有效期，真实 owner 会话、CSRF及HMAC桥接；每个至多64KiB输出块重新授权，取消立即停止上游，完整文件流检查字节数/SHA-256，失败不完成可解析的残缺备份。
- 本地机场目录、境内高德/境外地点代理、真实航班代理、固定端点路线预览及原生打包规则已接入运行时。地点按声明国家及坐标地理范围复核，CN/HK/MO不会交给境外地点查询；路线明确为大圆距离估计。生成规则包含原生数量、九语言、补充推荐和气候场景，排除 personal_ 健康场景与HealthKit推断。
- 行程/物品库读取有数量和1MiB页面边界，行程后续页面可绑定 expectedSubtreeVersion，版本变化要求重新读取。

## 本地发布入口

现有 Supabase service 项目已准备 `scripts/carry-account-service/supabase/functions/carry-ai/index.ts`，导入本目录的 `edge-entry.ts`；函数自己的 `deno.json` 显式将 `tz-lookup` 映射到固定版本 `npm:tz-lookup@6.1.25`。`supabase/config.toml` 已指定该 entrypoint/import_map，并设置 `verify_jwt=false`，由新协议自行验证 OAuth bearer 和第一方 owner proof，而非使用原生 JWT 网关。功能仍以 `ACCOUNT_AI_ENABLED` 默认关闭；默认配置不会自动开启服务；carry-dev本次已明确开启用于托管验收。内部 `/carry-ai/*` 与外部 `/functions/v1/carry-ai/*` 由同一精确路由适配。

从实际 service 项目根、使用该函数 import map 的 Deno check 已通过。此证据覆盖本地模块解析，不能代替托管打包上传、真实凭据、生产网络或设备验收。

Supabase网页编辑器无法解析跨目录入口时，不能直接粘贴上述import stub。使用本仓库既有锁定的esbuild依赖打包完整入口（在仓库根运行，Node24）：
```sh
node scripts/carry-account-web/node_modules/esbuild/bin/esbuild scripts/carry-account-ai/edge-entry.ts --bundle --format=esm --platform=node '--external:npm:*' --outfile=/tmp/carry-ai-deploy.mjs
deno check /tmp/carry-ai-deploy.mjs
```
该产物包含实际领域代码及静态机场/时区数据，保留固定版本的npm导入，不包含环境变量值。部署时用完整产物替换函数index.ts，保留服务器Secrets；校验网关元数据、未认证401及真实授权后的拒绝/成功路径。不要把浏览器卡在Deploying、单独Deno check或旧实例仍可请求视为最终产物已生效；必要时用只在新版拒绝的无效preview输入区分新版编译器与数据库验证。当前部署SHA及核验见日期专项报告。

## 外部门禁

1. 托管SQL共享核心、私有导出、预算策略、注册维护和严格日期迁移已部署到carry-dev，域名及原生/网页真实身份已验。开发入口可使用专用 `CARRY_AI_DATABASE_URL`，缺省读取平台服务端 `SUPABASE_DB_URL`，TLS校验保持开启。`postgres-schema.sql` 是结构参考，运行时Graph/回执使用同一事务连接，不创建原生auth.sessions。独立高德Web Key尚未配置，需先核实公开产品/境外服务器许可；已有App MapKit查询不需要该Key。
2. 用真实 Apple 身份核验原生与网页同账户、连接授权/撤销，以及托管私有 Storage 的 Range、不可变 version、较大文件时延和取消行为。本地 provider 合成测试不能代替这些验收。
3. 完成原生旧行程迁移、手机关闭、两设备同步、失败恢复/撤销的整体验收。原生 `carry://packing/{id}` 可明确打开打包；通用 `carry://trip/{id}` 保持上次显示页面，返回 `deviceState:not_observed` 不代表已验证手机界面。
4. 托管唯一维护任务已启用，每15分钟有界处理过期记录；自然调度成功已观察。用户确认后新增未使用注册记录清理，保留活跃授权、已用客户端和有效刷新重放证据。开发保护参数仍需在生产前评估。clone继续默认排除私有文件/照片/背景及预订凭据。

## 本地验证

Node24；Graph manifest 复用账户服务，SQL 测试依赖固定版本的 PGlite，运行前在本目录执行 `npm ci --ignore-scripts`。网页集成测试还需在相邻 `carry-account-web` 目录安装其锁定依赖。运行 `npm test`。生产 Deno 入口的 pg/jose 使用显式固定版本，不把 Node 测试依赖打入应用。

`synthetic-store.mjs` 是明确非持久的测试夹具，handler必须显式 `synthetic:true` 才接受。不能将其赋值 durability=transactional 冒充生产实现。`http.test.mjs` 在临时loopback端口建立真实HTTP边界，完成注册、授权、PKCE、账户写入/读回、撤销；无手机或任何上游网络/真实账户/私人文件。它证明协议运行路径，不能证明真实PostgreSQL持久化、Apple身份、托管接口或生产分发。

日期契约修复后的AI全套两轮各114/114，账户服务各128/128；账户网站24/24。`files-exports.test.mjs` 运行实际本地SQL迁移、ledger和provider协议，产出纯合成原生备份契约夹具；原生备份、迁移和投影共用CarryBackupDates编解码，兼容原整秒和服务器毫秒。loopback协议、SQL、原生自动测试和托管/实体机验收分别提供不同证据，最终数量以各报告对应源码为准。

安全审查修正记录：

- 预览重试原先重新编译 createdAt 后可能返回新摘要、旧预览ID；现返回持久预览的原内容/摘要。
- requestID 的输入摘要使用canonical JSON，参数键顺序不会产生重复或误判。
- 显式预览即使内容属于普通编辑，也不能通过 apply_changes 同请求绕过批准。
- scope必须在最终事务再次核验；预览获批不固定保留后来被收回的文件权限。
- 动态客户端名不能代表已验证的Codex品牌，consent返回精确客户端和redirect。
- 计划预览包含具体前后值与删除级联数量，不能只向用户展示mutation数量和字段名。


PostgreSQL 适配器验证：`postgres-store.test.mjs` 使用真实 PGlite SQL，覆盖单次 code、refresh 重放撤销持久保存、新实例读取、账户删除、错误 client 撤销、SQL 写入后异常回滚、图与回执幂等、预览强制与内容摘要、固定窗口限流。该文件的测试 Graph core 只负责合成 SQL 写入；`postgres-graph-core.test.mjs` 则运行完整真实迁移和 Carry 业务 core，验证创建天、原生拉取、级联删除/恢复、竞争回滚、撤销、session 隔离与权限。`postgres-driver.mjs` 绑定单个连接的 BEGIN/COMMIT/ROLLBACK，设置事务内语句/锁超时并释放连接。

部署适配器必须显式提供经过平台验证的 `trustedAddress(request)`；默认共享匿名限流，忽略来访者伪造的 CF-Connecting-IP。私有 rate bucket 应由服务维护任务删除旧窗口；不能向客户端开放清理权限。token/code 只存 SHA256 摘要，过期 refresh 的重放证据须保留至对应 grant 过期。账户删除必须在共同账户锁内删除本 schema 的账户记录，不因 JWT 仍未过期而继续允许访问。


共享 core 审查修正：AI restore 的 deletionBatch 是用户预览绑定，需在锁内与真实当前批次一致后剥离，传给既有 Graph 字段白名单。Native wrapper 的 session 检查保持独立；AI 账户执行不依赖原生 session 是否仍活跃。已接受的 commit 在预览过期后的重试、已接受的 undo 重试均先核对不可变回执，不重新编译旧草稿。随机未知路径统一限流分组，防止通过变路径制造无界 SQL bucket。

- 交叉Review补齐导出普通JSON metadata的逐块授权、撤销后首次读取零敏感字节、行程授权范围缩小，以及挂起provider读取时立即取消；不只检查附件字节。
- 地点国内分支按CN/HK/MO分别核验坐标地理时区，避免把上海地点发布为HK国家；查询UUID统一大小写，多目的地打包推荐读取结构化次目的地，港澳与其他国际目的地混合保留护照。
