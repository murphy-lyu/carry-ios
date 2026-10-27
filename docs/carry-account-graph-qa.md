# 账户数据图、离线副本与迁移编解码验收

日期：2026-10-27。范围：已确认 `specs/carry-cloud-and-ai.md` 的内部实现与组件验收。**整项功能尚未交付**，不将本文结果当成真实 Apple 登录、全 App 同步或生产验收。

## 已实现

- PostgreSQL 私有数据图：10 类业务对象、账户/父子复合外键、封闭字段和类型规则、对象版本、字段基线、账户内提交序号、事务回执。一次计划原子保存，重试复用请求 ID；同字段冲突返回当前值和提议值。删除级联使用同批墓碑，30 天内恢复不复活此前独立删除的孩子。
- 原生独立副本：SwiftData 账户容器明确 `.none`，不把队列模型加入原 iCloud `SchemaV1`。业务投影回调和待同步意图在同一 context/save；自动保存关闭，失败整体 rollback。冻结的请求和冲突内容落盘，重启不换请求 ID，上传 ACK 不推进拉取游标。
- 并发编辑：ACK 期间的新编辑保留；晚到 ACK 不覆盖已拉取的新版本；逐字段保留冲突基线。使用本地/远端/编辑后的版本解决冲突时绑定原请求和审阅的服务器版本，重新生成请求。
- 原生 HTTP 传输与串行同步泵：令牌刷新后仍核对缓存所属账户；同步批次和分页有界，未完成返回继续状态。网络失败保留 flight；永久错误停止自动重复，等待处理。
- 迁移编解码：沿用完整 Backup DTO，保留 10 类业务图、日期/时区、原币及汇率快照、照片缩略图、附件原文件、封面和裁剪。限定选中的行程，物品库和提醒偏好分别 opt-in；资产 ID 按账户/对象/用途/内容稳定生成，核对 SHA-256、归属及引用，缺失或损坏时失败。后台纯值处理，关系与资产查询建立索引，避免逐对象全图扫描。
- **Photos 原图边界**：旧 `CarryBackup` 只含照片回溯缩略图和本机 Photos 标识，不含 Photos 资料库原图。packet 明确列出 `photosRequiringOriginalCollection`；原图采集、权限与账户缓存尚未接入，不能凭编解码往返通过就切换这些照片的归属。

## 已部署的免费开发环境

仅 `carry-dev` / `lbxsvguuoqqpctkinpwy` / 新加坡，仍是 Free，未购买生产服务。

| 资源 | 实际状态 |
|---|---|
| `20261027004907_account_graph_transactions` | 已部署，与本地历史一致 |
| `20261027011218_account_graph_native_cost_semantics` | 已部署，兼容原生空币种和 -1 汇率快照，以及 0 元且有币种的真实费用 |
| `20261027013832_account_graph_compound_subtrees` | 已部署，事务内移动/删除使用事务起始子树基线，仍拦截外部并发 |
| `carry_private.graph_accounts/entities/changes/receipts` | 已开启 RLS，客户端没有 schema/table 权限 |
| `carry_graph_apply/pull` | SECURITY INVOKER，只允许 service_role；账户/有效会话/已登记 Apple 身份均核对 |
| `carry_private.graph_require_session` | 唯一需要读取 Auth 会话的现为 invoker；调用私有 `account_require_native_session` 的最小 Auth 查询，固定 search_path、仅服务端可调用 |
| `carry-data` Edge Function | ACTIVE v1，`verify_jwt=true`，SHA-256 `3d34ed61f5752b9073c98b83d11c670a037d2e09980ad82d6f007ee1b716327b` |
| 账户数据接口的 AI 隔离 | JWT client_id 和 Auth OAuth 会话均拒绝；未来 AI 需要另一个受行程授权限制的入口，不能复用全账户接口 |
| Apple provider / 生命周期函数 | 原生 Apple 已启用，Client IDs 为 `app.nevestudio.carry`，公开 settings 读回 true；`carry-account` 未部署，专用 P8 已注册并本地安全保管；Services ID/服务端密钥安装/真实登录未就绪 |

原 `20261027004907` 迁移保持不可变；费用修正以新迁移追加。`graph-transactions.sql` 是首次迁移的可读源码，不用于重写已经部署的历史。

## 验证与证据

- 本地服务端最终测试集：44 项，含 PostgreSQL/PGlite 实际执行、会话/账户隔离、分页、字段冲突、父子删除/移动/恢复、幂等、整批回滚、原生费用语义、HTTP 边界和 Backup 字段覆盖。正式两轮结果见本节末尾记录。
- 原生最终测试集：74 项。原有 37 项业务、18 项账户状态、5 项身份适配、8 项副本、4 项完整备份迁移、1 项实际 HTTP 双副本、1 项模型导出。旧 `RelayRoundTripTests` 明确不选入，它需要独立的旧执行器服务；不是通过或跳过了该项。
- `AccountGraphRoundTripTests` 使用真实 SwiftData、URLSession 和本地实际 HTTP/PostgreSQL，身份明确为合成夹具。覆盖客户端均未运行同步时服务端保存、两份离线副本收敛、同字段冲突/解决、提交后丢回执、重启和 exactly-once。**不代表真实 Apple 登录、Supabase 用户 JWT 正向写入或两台物理设备。**
- 托管库 `hosted-graph-smoke.sql`：真实 service_role 执行，合成用户/会话只在事务中创建，最终 rollback；保存/读回/幂等/独立字段合并/竞争字段拒绝/中途失败回滚/会话撤销/权限检查通过。清理后 users/accounts/entities/changes/receipts 均为 0。这些是 Auth 元数据夹具，不是实际注册或登录。
- 实际 Data API 权限负向检查 6/6：私有表 404/PGRST205，RPC 401/42501；不把无效 API key 的网关 401 算作 SQL 权限验证。
- Edge 实际 HTTP：无用户 bearer、畸形 bearer 均由平台拒绝；合法公开 anon JWT 通过平台后，被已部署 handler 的当前用户检查返回 `401 unauthorized`。没有伪造用户或读取真实数据。
- Security Advisors：六个私有服务表默认拒绝策略的 INFO，无 WARN/ERROR；Performance 无提示。说明见 [RLS Enabled No Policy](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)。未为了消除 INFO 给客户端放宽访问。
- 测试宿主仍会输出模拟器未登录 iCloud 的既有 CloudKit 日志；本次副本容器不使用 CloudKit，不将宿主日志当成云同步通过或失败。真实设备和生产网络仍须单独验收。

### 检查与修复记录

| 编号 | 发现及修复 | 验证 |
|---|---|---|
| G01 | PL/pgSQL 局部名与列冲突；显式块标签和表列引用 | PostgreSQL 实际执行 |
| G02 | 父项子树版本变化若只改表不发变更，会令设备删除预览一直过期；祖先元数据也进入有序日志，移动覆盖两条祖先路径 | 子项并发、移动和游标测试 |
| G03 | 仅用对象整体基线无法表达 ACK 后继续编辑；补逐字段期望版本 | 不同字段合并与因果后续编辑 |
| G04 | 晚到 ACK 会倒退已拉取数据或误放宽基线；保留最新远端与 ACK 的独立因果版本 | 原生晚 ACK/新编辑测试 |
| G05 | 冲突仅存在于内存不可恢复；冲突内容持久化，审阅版本绑定解决 | 重启保留和实际 HTTP 冲突解决 |
| G06 | 全账户接口若接受 OAuth 用户令牌，会绕过未来 AI 行程授权；同时拦 JWT client_id 和 OAuth 会话 | HTTP 适配及实际 PostgreSQL 负向测试 |
| G07 | 原生 0 元、空币种、-1 汇率快照与最初规则不一致；追加兼容迁移，不改旧迁移 | 原生模型→备份→wire→HTTP→PostgreSQL |
| G08 | Codable 纯值类型继承默认 MainActor 会限制后台迁移；纯值类型显式 nonisolated/Sendable，存储和 UI 保持原隔离 | Task.detached 往返及无编译警告构建 |
| G09 | QA 服务保留历史后超过单页，测试错误假定只拉一页；改为使用同步泵完整补页，不清空历史掩盖问题 | 保留失败 `/tmp/CarryAccountGraphVerifiedRound2.xcresult`，修复后重新完整验收 |
| G11 | 同一事务先移动子项再删父项会把自己的修改误报冲突；以事务开始时的子树版本核对预览，保留外部竞争保护 | 新增失败复现后修复，44 项本地回归及真实托管 service_role 复合事务通过 |
| G10 | 缺失文件、文件名/归属不一致或缩略图冒充原图均不能作为迁移完成；完整字节和元数据往返核对，显式列出待采集 Photos 原图 | 损坏/缺失/范围/字段覆盖测试 |

### 正式复跑

| 项目 | 第一轮 | 第二轮 |
|---|---|---|
| 原生完整组件回归 | 74/74，0 失败、0 跳过 | 74/74，0 失败、0 跳过 |
| Node/JOSE/HTTP/PostgreSQL | 44/44 | 44/44 |
| 托管 PostgreSQL 合成事务 | 通过，全部 rollback | 通过，全部 rollback |
| 实际 Data API 权限负向 | 6/6 | 6/6 |
| Edge 身份负向 | 3/3（含实际 handler） | 3/3（含实际 handler） |

原生证据：`/tmp/CarryAccountGraphCompoundRound1.xcresult`、`/tmp/CarryAccountGraphCompoundRound2.xcresult`；文本日志 `/tmp/carry-account-graph-compound-round{1,2}.log`。服务端日志 `/tmp/carry-account-compound-after.log`、`/tmp/carry-account-server-compound-round2.log`。这是当前组件集的两轮，不是 spec 要求的全产品/两设备完整验收。

## 尚未达到的发布门禁

1. 新副本还未路由原 `TripStore` 的所有真实写入口；本地删除/恢复、备份导入/还原、Siri、地理回填和系统副作用须统一接入、逐项回归。不能仅因独立副本测试通过就发布账户同步入口。
2. 实际 Storage 上传/续传/配额/清理、Photos 原图收集、迁移批次提交、源图只读标记、旧 TestFlight 分叉审核及账户缓存/Widget/备份的统一展示还未完成。
3. 原生/网页 Apple 同一身份、Services ID/关联域名/P8、服务端登记/删除任务、设备会话和 AI 授权管理仍未联调。网页 tab 控制持续超时，已用 CUA 原生 Chrome 窗口接入既有已登录会话，完成原生 provider 配置；未要求用户重登 Supabase。Apple Developer 网站会话实际需要登录，用户随后完成登录，已核对 Bing Xue / 25RAM7275Z 并经当次确认注册 Carry 专用登录密钥；后续 Apple/Supabase 页面持续加载，未配置网页 Services ID 或服务端 secrets。
4. 新 MCP 账户执行、按行程/物品库/附件授权、预览绑定确认、撤销、搜索/航班/推荐等全部业务适配仍未完成。生产旧 Worker 未切换；未把既有前台执行器描述成手机关闭后可用。
5. 数据过期正文清理/保留知识、完整备份恢复演练、账户 purge、国内/境外真实网络、真机 UI 与双设备完整两轮验收仍未完成。单批 500 条的上限也不能替代大型迁移 staging/提交流程。

实际账户发布开关仍为 false；未安装覆盖真实手机、未合并主线、未上传 TestFlight、未上传现有私人行程。

## 构建与配置证据

Release 真机目标构建通过，无编译警告/错误；strict codesign 通过。App 为 Team `25RAM7275Z`、`25RAM7275Z.app.nevestudio.carry`、Apple 登录 `Default`、CloudKit `Production`，profile 同时允许 Production/Development。日志 `/tmp/carry-account-graph-release.log`；仅核对构建与签名，未运行真实设备/CloudKit 或导出上传。九语言审计 0 errors/0 warnings。

原生 Apple provider 保存后重新打开核对，公开 `/auth/v1/settings` 再读回 true。OAuth secret 留空，当前仅配置原生 bundle，网页流程与生命周期 P8 已注册并安全保管在本机，服务端安装和网页流程仍待。私有本地截图 `/tmp/carry-apple-provider-enabled.png`；不上传包含浏览器上下文的截图至 GitHub。

## 登录密钥与会话/缓存复核（2026-10-27 晚）

- Apple Developer 已实际登录并核对 Bing Xue / Team `25RAM7275Z`。注册前核对团队现有 Keys 为空；用户当次确认后注册 `Carry Account Sign In` / Key ID `8LRP72FMZY`，只启用 Sign in with Apple，主 App 为 `app.nevestudio.carry`。下载完成后移入本机受限目录（目录 0700、文件 0600）；私钥未进入 Git、App 或工具输出。使用 JOSE 本地导入 ES256 密钥并验证 5 分钟客户端断言；这不等于实际 Apple 代码交换成功。
- 本机服务端配置及 32 字节随机 AES 密钥已准备，使用独占新建、0600 文件，已存在配置不会覆盖。尚未上传 Supabase secrets，`carry-account` 仍未部署；网页 Services ID 尚未创建，不能把已注册 P8 当作原生/网页真实登录完成。
- 第六份迁移 `20261027145234_account_native_sessions` 已部署并对齐本地历史。新增服务端专用会话检查：允许尚未登记的新原生会话进入 enrolment，但拒绝会话不存在、跨账户、到期和 OAuth 来源。数据图再检查账户登记/删除状态。唯一 private definer 现在只读取 Auth session，图检查改为 invoker；所有 public RPC 仍仅 service_role 可执行。
- 生命周期适配器在 Auth 验证当前 bearer 后核对 issuer/sub/session/expiry，拒绝 client_id，并查询当前数据库会话；避免仅凭尚未过期的 JWT/用户查询接受已撤销会话。此适配器尚未随 `carry-account` 部署，不能把数据库已部署描述成生命周期服务已上线。
- 副本编辑按 UUID 查找，outbox 使用持久 pending 标志筛选；旧缓存新增字段默认 true，由首次队列读取安全归一。ACK/拉取/冲突投影仅传改变后的本地快照（包括墓碑），不是全图替换；空页不重投影。显式 `localEntities()` 仍是完整读取并报告坏记录。
- 新回归放入无关且明确损坏的 clean payload：编辑、冻结请求、ACK、远端合并和增量投影均不读取它；显式全量读取必须报错。另验证 pending 标志在本地撤回、重开缓存和无上传时保持一致。没有用计时阈值或吞错冒充性能验证；尚无真实大型行程的性能成绩。
- 修复测试过早 unlink 仍打开的 SQLite：把账户副本及真实 HTTP 测试的目录清理移至 XCTest teardown，测试局部容器释放后再删除；修复后对应日志没有 vnode-unlinked/API-violation。

| 晚间最终组件复跑 | 第一轮 | 第二轮 |
|---|---|---|
| 原生完整组件集 | 76/76，0 失败、0 跳过 | 76/76，0 失败、0 跳过 |
| Node/JOSE/HTTP/PostgreSQL | 47/47 | 47/47 |
| 实际托管 service_role SQL | 通过，包含原生新会话、跨账号/过期/撤销/OAuth 拒绝及原数据事务 | 通过，所有夹具 rollback |

原生最终证据：`/tmp/CarryAccountDeltaSessionRound1.xcresult`、`/tmp/CarryAccountDeltaSessionRound2.xcresult`，文本 `/tmp/carry-account-delta-session-round{1,2}.log`；服务端 `/tmp/carry-account-native-session-round{1,2}.log`。托管检查用事务内合成 Auth 用户/会话/OAuth 客户端（不是实际注册或 OAuth 授权），回滚后 users/sessions/oauthClients/accounts/entities/changes/receipts 全为 0。Security Advisors 仍仅六项 INFO，Performance 无提示。

浏览器阻塞的实际观察：Apple 切换 Services IDs 后长时间空白；Supabase 控制台显示 “Taking longer than expected”。普通刷新、完整重新加载与组织页导航未恢复，内置浏览器绑定也超时。没有清除 cookies、退出登录、修改代理或要求用户重登；没有从浏览器内部提取会话凭据。Supabase 插件数据库操作正常，不能据此归因为 Apple/Supabase 账户权限不够。

以上是同一功能开发中的组件检查，完整发布门禁保持未完成。

本次最终 Release 真机目标构建通过，strict codesign、Team `25RAM7275Z`、Apple 登录 `Default`、CloudKit `Production` 与打包后账户门禁关闭均核对通过，无编译警告/错误；日志 `/tmp/carry-account-session-queue-release.log`。九语言最终审计 0 errors/0 warnings，日志 `/tmp/carry-account-session-i18n.log`。未安装真实手机或上传 TestFlight。
