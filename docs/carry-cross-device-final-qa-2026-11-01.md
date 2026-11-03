# Mac 与 iPhone 联合验收

日期：2026-11-01。仅操作名称带 QA / Acceptance 的合成测试行程；未迁移原私人行程。Mac 登录由用户本人完成 Touch ID。以下各节保留阶段记录；最新结论以末尾「最终日期契约与实体机补验」为准。

## 已验证

- 工程原来把 iOS Widget 同时嵌入 Catalyst，触发平台不匹配构建失败。给嵌入项和 target dependency 加 iOS platform filter；iOS Widget 保留，Catalyst 不再嵌入不兼容扩展。
- Mac Catalyst 未签名和正确团队开发签名均构建成功。Xcode 自动注册当前 Mac 并生成原 Bundle ID `app.nevestudio.carry` 的开发 profile，未另建检查 App。strict codesign 验证通过。
- Mac 验收包仅将构建产物 `CarryAccountReleaseReady` 设 true；账户 AI 门禁及仓库发布门禁仍关闭。用户完成 Apple 登录，设置实际显示 Signed in；启用同步后显示 Changes saved to your account。
- Mac 拉回 iPhone 已发布的合成行程、上海博物馆地点、CNY 42 与合成文件名，证明实际物理客户端账户读回链路可用。原 iCloud 行程在 Mac 仍按旧路径显示，未迁入账户。
- 打开地点详情连续两次崩溃，已保存 17:02:06 / 17:02:24 的系统 ips。栈为 `EnvironmentObject.error → StopDetailView.store.getter → stopScheduleSubtitle`。统一行程 sheet 根显式注入当前 owner store/router，覆盖地点、交通、住宿和编辑。修正版正确团队构建通过，实际再次打开同一地点，详情费用和文件均正常显示，编辑页也可保存。
- Mac 将合成地点名称修改为 `Carry QA Museum — Mac verified` 并保存。Mac replica 的已接受远端版本为3、pending=false；新 iPhone 包启动后，只读复制账户数据库到受限诊断目录，完整性 ok，匹配到同一测试名称/remote version 3/pending=false，Mac→账户→iPhone 的实际数据收敛通过。未读取 Keychain 或迁移真实旧行程。反向修改及冲突仍待继续观察，不把数据库读回冒充最终界面验证。
- 合并后原生全量两轮各 351 通过、1 项手动物理检查跳过，0 失败、0 runtime warnings。结果 `/tmp/CarryIntegratedFinalQA-20261101/round-{1,2}.xcresult`。这两轮先于上述 sheet 注入修正；修正后 Simulator、Mac 和 iPhone Debug 构建另行通过。
- 上述 sheet 修正及所有 Review 修复后的最终全量又两轮各351通过、1手动物理检查跳过、0失败、0 runtime warnings：`/tmp/CarryIntegratedPostReviewQA-20261101/round-{1,2}.xcresult`。
- 最新 iPhone Debug 同 Bundle ID 安装成功、strict/deep codesign 通过，冷启动保留账户和行程，多个已有照片封面正常显示。最终 iOS Release 编译通过；九语言审计0错误/0警告。更多冷图操作另行记录，不能把 iPhone 17 Pro 的显示结果称为 iPhone 12 性能实测。

## Codex 真实连接

- 官方 CLI 已登记 `carry-account`，连接 `https://connect.nevestudio.app/mcp`；原配置先保存受限备份，没有改动既有服务。
- 实际 Codex DCR HTTP 400；使用 loopback 合成元数据服务捕获公开注册字段，确认 CLI 发送 `application_type: native`。旧服务错误地拒绝未知 DCR 元数据。
- 按 RFC 7591 仅在注册端点投影支持字段，忽略未知字段，验证/回显 native 或 web，仍保持服务器生成 client ID、精确 redirect、PKCE、resource 与本人 consent。独立 Review 没有发现授权边界扩大；顺带修复 auth_method 的 truthy 校验，显式 null/false/0/空字符串均拒绝。
- AI 全量两轮各 104/104；最后 auth_method 收紧的 Worker 定向 37/37，随后最新完整源码又两轮各104/104。实际 Codex 尚未取得授权，不宣称已连接成功。
- Supabase 最初网页部署失败已取得明确错误：既有跨目录 `index.ts` 导入在网页打包时解析成不存在的 `/carry-account-ai/edge-entry.ts`。失败没有更新线上服务；随后已用完整打包入口部署为 carry-ai v4，实际 Codex 动态客户端注册成功，后续进入本人授权页面。已用现有 esbuild 生成独立 ESM、保留锁定 npm 导入，Deno check、无网络 enabled runtime 初始化和 disabled 503 检查通过。没有导出浏览器凭据或私钥。
- `curl`/Node 经当前代理 TLS 停滞，Foundation URLSession 与真正 Codex 可达；没有更改代理配置。网络探针不是实际 OAuth 成功证明。

独立部署产物：`/tmp/carry-ai-index-20261101.mjs`（同内容 `.txt` 供原生编辑器复制）。SHA-256 `e8cb08a3b599b8232ab399dd6ac44a7ba64ebbf1a9f95d9518805d0dbd495aee`。由现有 web 模块 esbuild 对 `scripts/carry-account-ai/edge-entry.ts` 使用 `--bundle --format=esm --platform=node --external:npm:*` 生成，静态资源包含在产物中，没有环境秘密。Deno cached-only + 禁止网络的初始化检查分别验证启用/关闭两个分支。该产物已成功部署；失败部署未替换线上版本，最终成功版本为 carry-ai v4。

## 继续验收 / 待办

- 继续 Mac ↔ iPhone 双向编辑、删除恢复、离线/冲突、附件实际预览。
- 用户已同意将第二台 iOS 设备验收记待办；Mac ↔ iPhone 可以先完成跨平台物理同步验收，不能替代 iOS ↔ iOS 专项。
- 完整 Codex 授权、手机关闭时创建/修改/读回、撤销重连和原生 AI 入口验收。
- 新预算策略默认关闭，代码/两轮测试已完成，托管迁移、容量核对和受限开发策略启用尚待执行。见云端运维报告。
- iPhone 12 原“点击无反应”仍缺对应设备轨迹；已修复可达冷封面主线程读取，但不宣称原反馈根因已证实。
- 无正式发布、无主线合并、无 TestFlight 新版上传。

依据：[RFC 7591](https://www.rfc-editor.org/rfc/rfc7591)、[OpenID 注册元数据](https://openid.net/specs/openid-connect-registration-1_0.html)、[Codex MCP 文档](https://developers.openai.com/codex/mcp)。

## OAuth 浏览器授权跳转修复（继续验收）
- 用户手动 Allow 同样无反应后，使用真实 Chrome + 合成 loopback 表单复现。Chrome 控制台明确报告 `form-action` 阻断跨来源 303；服务端已收到 POST，但客户端回调未收到。加入特定回调来源后，相同真实 Chrome 立即显示合成回调成功。
- 仅在当前 consent GET 及其 POST 303 响应追加经过 owner bridge 精确注册校验的回调 origin。其余网页 CSP 保持不变；仅允许 HTTPS 或本机 HTTP，拒绝用户名及 CSP 指令注入。不是开放任意 HTTP/HTTPS 跳转，OAuth 后端仍精确匹配 redirect URI 和 PKCE。
- 增加 loopback 端到端授权码兑换测试，并检查 GET/POST 策略一致；定向5/5通过，AI完整106/106通过，账户网页24/24通过。
- 最新 account-web acceptance 部署：`7d25c89c-0551-450c-a629-db4159794982`。保留现有账号和 AI 验收开关；源码默认关闭不变。
- 实际 Codex OAuth 已成功：r9 CLI 返回 Successfully logged in；凭据由 Codex 正常保存，未读取或导出。前几轮重复提交曾取消正在进行的 POST，后续只单次提交并等待真实客户端结果。实际 MCP 行程操作另行验收。
- 两轮最终 AI 完整各106/106通过；网页24/24通过，安全Review保留精确注册redirect、PKCE、scope、owner CSRF与独立行程授权。
- iPhone 编辑的合成地点备注已在 Mac 原生 account.store 读回（只输出精确测试文本匹配布尔值），Mac→iPhone 与 iPhone→Mac 物理编辑方向均有证据。

## Codex MCP 原生客户端协议验收（继续）
- CLI 模型推理入口被当前 ChatGPT 账户拒绝（model_not_found），不能由此判断 Carry API 认证失败。改用同一 Codex CLI 的 app-server 公开 `mcpServerStatus/list` / `mcpServer/tool/call` 协议和 ephemeral 测试会话，凭据仍由 Codex 自己使用，从未提取令牌。
- Carry 服务状态为 oAuth，实际成功发现18个工具；首次 list_capabilities 返回 invalid_request。用独立合成本机 MCP 端点捕获真实 Codex 公开请求结构，确认为 tools/call.params 自动带 `_meta`，内容字段为 threadId(string)、progressToken(number)。没有捕获任何用户数据或凭据。
- 仅允许有界对象元数据（64键/16KiB）并丢弃，不解释为账户、scope、行程选择或操作权限；工具arguments仍保持原有严格验证。新增伪造accountID/scopes/tripIDs/onlyCreated不能读取旧行程的回归，畸形和过大meta拒绝；Worker定向38/38。
- 合并注册存量保护后的完整AI两轮各109/109，0失败。独立部署产物 r5 SHA256 `ede7a14ca0a1399902b2870ef5f2df9e5bc7d1ea1331ccaf7d8f6c41665aa082`；Deno check及禁止网络的启用/关闭运行检查通过。
- 真实只读数据库核验：预算策略尚未安装；1个Storage对象，131072 bytes，未知大小对象0，既有预算157286400 bytes。唯一active retention job，近2小时自然执行成功7次。新注册清理迁移待用户当次确认；仅注册容量保护可随Edge先部署，清理不会因代码包更新自动开启。

## 真实刷新与当前对话 MCP 操作
- 真实 Codex 刷新请求经独立纯合成 loopback OAuth 发行器确认只带 grant_type/refresh_token/scope/client_id，未带resource。兼容省略resource的刷新仍由数据库绑定到当前canonicalresource；授权码兑换仍要求显式精确resource。scope只能重复原授权集合，变更须重新owner授权。校验在事务内spent检查之后、消费之前，错误scope不消费有效token，也不能绕过spent家族撤销。
- 最终AI合并两轮各112/112，Deno check、无网络运行门禁通过；r6产物SHA256 `cd073022add5dee7317d2009ee882aceac0057c10879a74457f8f23c51b683a4` 已部署。
- 当前对话已加载Carry账户工具，并真实调用 list_capabilities、list_trips（初始为空，已有行程不可见）、apply_changes创建、get_trip、apply_changes改名、get_trip/list_trips读回。测试行程 `9c348e86-4b2b-57fb-a079-0f26f50089c8` 最终名 `Carry Codex QA 20261101 — verified`，version=2。创建requestID `518db27c-4a3d-4363-8365-7ecbfcc3404c`，改名requestID `5d4b1dd2-dc2c-4abc-8bf2-48dfef265b65`。只创建合成数据，未授权读取原有行程/文件/物品库；server saved_to_account与手机到达分开验收。
- 用户确认启用新临时注册清理后，已安装20261101101210维护迁移，引用索引读回true、唯一active job=1。配额机制迁移20261101084027也已安装，读回默认关闭false/0/0/0；托管rollback与显式开发配额启用仍待执行。

- 本轮真实查询补验：search_airports(data.query=NRT,language=zh-Hans) 返回成田国际机场 RJAA / Asia/Tokyo / WGS-84 坐标。首次调用误把查询参数放顶层，被协议按预期拒绝；按现有data嵌套契约重试通过，无产品代码修改。

- 配额托管回滚首轮界面粘贴未完整替换旧SQL，返回unterminated dollar-quoted string，属于编辑器输入错误，未计验收通过。另开只读pg_stat_activity检查无活动查询/锁等待；接下来在新空白查询中以明确完整文本重做，不重复执行混合脚本。

- 进一步真实幂等验收：重复原创建requestID及完全相同operation后只返回原receipt；list仍仅1个合成trip且保留已改名version2，没有重复创建或覆盖后续修改。
- 原生Mac一次带安全日志的实际同步确认失败为native_projection；7条replica中新增3条待投影、无pending本地写/asset引用、身份和父关系有效。已确认AI ISO8601日期带毫秒、Native projector旧formatter不接受毫秒，修复及新增往返回归继续，不能仅凭MCP成功称端到端通过。
- 配额与自然cron、注册维护实际部署及权限读回已完成，详见cloud-operations-final报告；高德Web Key云端未配置，保留该外部前置项。

## 最终日期契约与实体机补验
- 根因：AI 合法生成毫秒 RFC3339 日期，旧原生投影器只接受整秒。统一备份、迁移、投影、导出和冲突显示的日期编解码；保留旧整秒格式，毫秒精度往返不再制造虚假字段修改。数据库与 AI 另外拒绝 native 无法消费的归一化日期，完整记录见日期专项报告。
- 最终统一源码全量两轮各359通过、1项手动物理检查跳过、0失败、0 runtime warnings。结果 `/tmp/CarryUnifiedDateFullFinalQA-v2-20261101/round-{1,2}.xcresult`；环境 iPhone 17 Pro 模拟器 / iOS26.5，不代表 iOS17 或 iPhone12 性能实测。最终 Release 构建成功，九语言审计0错误0警告。
- 最终 iPhone 构建成功并同 Bundle ID 覆盖安装，安装前完整容器备份53文件/36,854,440 bytes、6个SQLite完整性检查通过，受限本机目录保存；未导出Keychain。strict/deep签名验证通过，源码账户/AI发布门禁不变，验收构建仅启用账户入口。镜像首页实际显示 `Carry Codex QA 20261101 — verified` 及正确日期，旧私人行程仍在原列表。
- Mac 最终统一源码重新构建/正确团队签名/strict验证通过，原 Carry 中保持已登录，Sync now完成后显示Changes saved to your account。首页实际出现上述 Codex 行程和新 `Carry Final Acceptance 20261101`。
- 在 Mac 原 Carry 打开合成地点及附件，Quick Look实际显示 `Carry synthetic attachment acceptance fixture. No personal travel data.` 内容；不是只读到文件名。手机本轮可截图观察，但点击接口返回noWindowsAvailable，尚未据此补记手机附件预览通过。
- 数据库日期迁移已安装，存量非法日期0，权限未扩大。AI r7线上无效日期请求返回invalid_field；有效合成创建成功：requestID `7847cc9b-5120-4e08-8fa0-ae9cef277749`，trip `66d13076-3778-53bb-abdb-d6cd37e1a115`，只属于本次连接自建行程。
- 桌面认证过期后，已通过原范围重新认证，当前对话MCP恢复成功；新连接不自动继承旧连接的行程权限。只读核验旧CLI grant未撤销、有1个spent和1个有效refresh、当时access已过期；新桌面grant未撤销且token有效。尚不能归因为refresh重放，更不能仅凭重连成功宣布长期续期修复。
- 仍保留的验收项：真实撤销后的拒绝与重连、物理离线/同字段冲突/删除恢复、手机附件预览、原生新AI入口视觉和生产发布门禁；iOS↔iOS按用户要求延期，iPhone12原反馈缺硬件轨迹。高德个人认证已通过，云端国内地点许可/服务选型未确认，未创建Key或购买套餐。

## 真实查询与授权边界补验
- 当前桌面连接真实调用海外search_places的suggest与retrieve：Tokyo首项检索后返回JP / Asia/Tokyo及WGS-84坐标，未保存进用户行程。suggest仍是候选；最终retrieve会再次验证所请求国家及境内排除，不能把候选标题当作已验证地点。
- 原生打包建议实际返回recommendations_only，包含中文displayName与原生规则修订标识；仅查询，没有应用到行程，未使用健康数据。
- 新桌面连接读取旧连接创建的合成trip返回trip_not_authorized；未单独授权的物品库读取返回insufficient_scope，未返回内容。重新认证不会继承旧连接权限，旧测试数据未删除。
- 自动续期实际补验：access过期后list_trips仍成功；后台current_desktop_connection的spent_refreshes由0变1、live_refreshes=1、live_accesses=1、revoked=false。旧CLI会话失效仍仅作为诊断项，未放松重放撤销保护。

## 本轮 Review 新发现（修复中，尚不称最终交付）
- 原生旧draft与后台pull：EditTripView持有旧@State表单，后台materialization更新后保存整表单，会用新版fieldVersions发出旧内容，造成同字段冲突丢失和未改字段回写。现有双客户端测试不覆盖尚未保存的表单窗口；正在用统一编辑会话及投影生命周期修复。
- 高精度合法日期：纯合成25向量中4个`.999999999`边界被AI/PG接受、native因浮点进位误拒绝。高精度迁移codec的字段精确比较也需验证；正在修复输入量化与语义校验。此前359×2只证明当时源码，不涵盖这两项后续修复。

## 编辑会话合并首轮验收（失败记录）
所有UI入口适配、账户owner/group保护、同机窗口互斥及高精度日期修复合并后，完整supervisor首轮实际378通过、2失败、1手动物理检查跳过、0runtime warnings；未继续第二轮，不计验收通过。结果 `/tmp/CarryEditorUnifiedFinalQA-20261101/round-1.xcresult`。失败为NativeEditorLeaseTests中的“bypass忙拒后owner继续保存”及“creationStore facade忙拒后owner写library”，其他测试通过。
根因为CarryPersistence.commit对任何错误都隔离当前context；编辑忙拒虽未进行I/O，却也进入隔离，TripStore保留相同context后合法保存被invalidatedContext拦住。修复将授权检查前置到commit之前，忙拒只回滚未保存Model修改、不隔离；真实I/O/journal失败继续隔离。原两项完整断言保留，修复后必须再次统一两轮。首次整App编译中PhotoTripImport旧错误状态引用及ViewBuilder/actor closure告警已修正，未压制告警；本轮Release构建及九语言0/0已通过，但该Release先于忙拒修复，最终仍须重建。

## 编辑保护整体验收与单日行程发现（2026-11-01）
- admission 修复后统一 v2 两轮各382项：381通过、1手工跳过、0失败、0运行时警告；17项编辑测试实际执行。Release/iPhone/Mac编译均成功且0编译警告；九语言审计0/0。
- iPhone安装并launch成功；安装前容器副本53文件、33,592,201 bytes、6个SQLite integrity_check全部ok，权限目录0700/文件0600。容器复制并非停机原子快照。镜像明确提示iPhone in Use，本轮不声称手机UI通过。
- 专用Mac/iPhone构建产物单独开启账户与AI门禁并重新签名，源码发布门禁继续关闭。Mac实际账户续存、Sync now成功、Connect AI连接地址和管理入口均可见。
- Mac打开本连接合成trip 66d13076-3778-53bb-abdb-d6cd37e1a115编辑目的地Tokyo，编辑期间MCP请求3cddf49b-08c7-4f3b-8d5c-80a705542d59把name改为Remote Name，服务器v2。Mac保存后服务器v3同时保留远端名称与本地Tokyo。此记录证明不同字段并发写保留；尚不证明编辑期间已发生原生pull。
- 同次真实UI暴露单日缺陷：days=0经TripInfo保存被钳为1，新增第二个day，显示日期与服务端dateRange也不一致。已交由native agent根因修复并新增真实Store回归。v2是修复前结果，不能当最终统一交付。

## 单日修复后最终统一结果
- `/tmp/CarryEditorSingleDayFinalQA-20261101`两轮均383 total/382 passed/1 manual skipped/0 failed/0 runtime warnings，真实Store单日回归实际执行。最终Release/Mac/iPhone构建0警告通过，九语言0/0。签名iPhone已再次安装启动，Mac重开成功。
- 同字段冲突实测：request4b6adf5c-af88-401e-bbb6-53ab6b634e96写远端name v4，Mac保存本地name后server仍v4远端值；设置显示Some changes need your review，Review逐项显示双方名称。选择Other changes并Save后显示No changes need review，重开Mac为远端名。先前请求6104f992因未带name真实fieldVersion=2而被field_conflict拒绝，没有写入；随后新request携带正确fieldVersions成功。
- 最终Mac单日trip25fb0d37-8e9d-504e-acd9-9e452900047b只改名后server v2/days0/原day不变，确认实机修复；新增dateRange展示元数据不计为日期变更。汇总及剩余界限见carry-account-delivery-2026-11-01.md。
