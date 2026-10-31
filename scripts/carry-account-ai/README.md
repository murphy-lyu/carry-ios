# Carry 账户 AI 服务组件

该目录实现新账户协议和领域编译器，取代“配对手机前台执行”作为最终架构。已有 `edge-entry.ts` 与 PostgreSQL 运行时，尚未部署，也不会连接旧 relay。生产不使用内存存储；实际部署、查询/文件/导出适配及完整产品验收仍未完成。详细原子边界见 `store-contract.md`。

## 已实现

- OAuth2.1 public client registration、S256 PKCE、精确 redirect/resource、单次短期 code、轮换 refresh family、每请求撤销/过期核验、当前账户状态、第一方连接管理。
- 云同步身份与 AI grant 分开；精确行程、仅本连接新建、物品库、附件、偏好和私密预订字段独立授权。导入内容、搜索结果和备注不授予任何权限。
- MCP stateless Streamable HTTP JSON；返回 `saved_to_account` 与 `deviceState:not_observed`，不创建或等待设备任务。只有服务器确认业务图/回执同事务落盘后才返回成功。
- 十类业务对象的字段清单、父子约束、版本/字段基线、创建/编辑/移动/完整排序/删除/恢复、完整行程及天创建、脱敏复制。
- 确定性行程/子项身份与计划内 `@ref/day/N` 引用；一整套计划编译成一个逻辑事务。字段校验复用账户 Graph manifest，最终领域规则仍由同一个 Graph core 在事务内判断。
- 不可变预览、具体修改前后值、版本与影响范围；第一方用户批准 contentHash 后同请求原子提交。任何 `confirmed:true` 或相同 requestID 的普通写入都不能跳过已建立的预览。
- 撤销由 store 依据已接受的 before/after image 生成带版本的反向计划，再经预览/确认。后续编辑产生冲突，不能整库覆盖回旧快照。
- 私有资产最多64KiB分块读取，每次重新核验 grant，必须在本次所选行程中找到对应资产引用。不返回 provider/signed URL。Native资产服务本身不接受OAuth；实际适配必须走经过授权的共同核心。
- 行程/物品库读取有数量和1MiB页面边界，行程后续页面可绑定 expectedSubtreeVersion，版本变化要求重新读取。

## 尚需主线接入

1. 将已实现的 PostgreSQL 事务 store、共享 Graph core 适配器接入托管连接池；不伪造原生 auth.sessions。`postgres-store.mjs` 已持久保存 code/token/grant/preview/receipt，Graph 验证/执行/撤销回调必须使用相同事务连接；`postgres-schema.sql` 是私有 schema；已通过 CLI 生成迁移 `20261031013432_account_ai_shared_graph_core.sql`，尚未托管部署。`postgres-graph-core.mjs` 在同一事务连接调用私有业务 core，原生入口继续单独验证真实 session。
2. 已接入账户网站的真实会话、CSRF、HMAC 服务端桥接、授权/连接/计划对照页面，并完成本地 HTTP/SQL 联调。原生与网页登录的实际 Apple 身份一致性、托管部署与域名仍待验收。动态客户端名称只作未认证显示文字，同时展示精确 client ID/redirect 目的地。
3. 服务端机场/境内外地点查询、航班、路线与推荐适配。没有安装的查询明确 capability_unavailable，不能调用手机MapKit或健康数据充数。
4. 附件/原图/封面实际ledger读取与导出生成器，保持账户同步和AI文件权限分离。当前clone默认不复制私有文件/照片/背景和预订凭据，完整私有复制不是默许能力。
5. 全场景迁移、原生/网页同账户、手机关闭与两设备、失败恢复/撤销、两轮整体验收和Review。原生 `carry://packing/{id}` 现可明确打开打包；通用 `carry://trip/{id}` 保持上次显示页面，本组件不声称能强制打开行程脸或已打开手机。

## 本地验证

Node24；Graph manifest 复用账户服务，SQL 测试依赖固定版本的 PGlite，运行前在本目录执行 `npm ci --ignore-scripts`。网页集成测试还需在相邻 `carry-account-web` 目录安装其锁定依赖。运行 `npm test`。生产 Deno 入口的 pg/jose 使用显式固定版本，不把 Node 测试依赖打入应用。

`synthetic-store.mjs` 是明确非持久的测试夹具，handler必须显式 `synthetic:true` 才接受。不能将其赋值 durability=transactional 冒充生产实现。`http.test.mjs` 在临时loopback端口建立真实HTTP边界，完成注册、授权、PKCE、账户写入/读回、撤销；无手机或任何上游网络/真实账户/私人文件。它证明协议运行路径，不能证明真实PostgreSQL持久化、Apple身份、托管接口或生产分发。

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
