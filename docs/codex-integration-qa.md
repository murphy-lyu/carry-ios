# Codex 接入验收与代码审查

日期：2026-10-21～25。分支：`codex/carry-integration`。两轮本地自动验收与自行代码审查已完成；最新线上复查见下文，正确 Apple 团队及真机界面验收仍未完成，不标记整件任务交付完成。

## 隔离与范围

- 使用独立 Git worktree 和专用模拟器 `Carry Codex QA`（iOS 26.5），不修改现有真机行程。
- SwiftData 测试每例新建临时磁盘数据库，验证真实持久化和关系，不用 JSON mock 替代模型事务。
- MCP 测试使用合成行程和临时配对，完成后撤销；不读取或上传现有旅行数据。
- 用户已明确授权本任务自行全面验收两轮并进行代码 Review；此授权不延伸至其他任务。

## 已发现问题与处理

| 编号 | 发现方式 | 根因与修复 | 回归验证 |
|---|---|---|---|
| QA-01 | 静态审查与单日用例 | 内部 `days` 表示晚数，直接用至少为 1 的输入辅助值会使单日行程多出一天；命令入口按日期差保存真实晚数 | `testSingleDayTripDoesNotCreateAnExtraDay` |
| QA-02 | 分类生命周期审查 | 启动清理既会反复运行，也把有名字的空分类视为脏数据；改为每次 Store 初始化仅清理一次，保留有名字的空分类 | 空分类添加物品、重启两类用例 |
| QA-03 | 权限/冲突审查 | 公开快照的版本号无法反映新增私有附件；用本地备份镜像的元数据计算设备密钥 HMAC，只有结果出设备，照片字节不参与 | `testPrivateAttachmentsNeverAppearInProjection` 同时验证版本变化 |
| QA-04 | 第一轮真实 SwiftData 测试失败 | `ModelContext.rollback()` 删除了新对象，但观察中的关系数组仍残留插入对象；改用隔离事务 Context，失败丢弃，成功后用新 Context 发布已提交图 | `testInvalidStopRollsBackAlreadyChangedFields`、注入保存失败用例 |
| QA-05 | 网络恢复路径 Review | 回执已到服务端但响应丢失时，重复回执原被拒绝；改为核对请求摘要后幂等接受。服务端范围与本地批准范围取交集，只有本地创建回执能扩展授权 | JS 重复回执、丢失响应与本地授权边界测试 |
| QA-06 | 生命周期/权限 Review | iCloud 验证回调可能在 App 已退后台后返回；增加会话代数、取消、前台和本地数据版本检查，撤销期间禁止继续发布快照 | 代码路径核对；真实切换 iCloud 账号、前后台竞争仍待真机验证 |
| QA-07 | 服务端数据边界 Review | 不能仅依赖客户端不上传私有字段；服务端对查询投影再次使用白名单裁剪，未知字段不进入快照 | Live relay 附件字段裁剪用例 |
| QA-08 | 真实 Miniflare 首次失败 | 预期鉴权错误抛出 `blockConcurrencyWhile` 会重置实际 Durable Object，mock 未暴露，401 变成 500；在并发块内捕获并返回鉴权响应 | 真实 HTTP 撤销后返回 401；两轮 live 检查 |
| QA-09 | 存储限额与大数据审查 | 单值快照上限会让较长行程无法同步；改为 UTF-8 分块存储，元数据最后发布，按天分页查询，撤销删除所有分块 | 大 Unicode 快照、跨分块 emoji、分页和撤销测试 |
| QA-10 | 进程退出窗口 Review | 仅异步通知撤销，可能在还原/清空后立即退出时丢失；先同步写 Keychain 撤销标记，失败阻止数据动作，随后发送通知 | 真实 Keychain 重建连接管理器测试，旧备份还原测试 |
| QA-11 | 复制代码审查 | 原 UI 复制附件失败会降级，远程回执却可能误报完整复制成功；远程命令核对本地附件和背景文件复制数，失败不提交，回收孤儿文件 | 缺失附件复制失败、独立模型图、打包状态重置测试 |
| QA-12 | UI 状态同步审查 | 事务提交发布新 Context 后，模型 persistent ID 保持不变，首页缓存仅看模型相等性可能不重建；首页改观察实例标识列表，沿用既有缓存刷新流程 | 实际持久化后 ID 不变、实例变化测试；界面视觉仍列为未验收 |
| QA-13 | Keychain 测试环境失败 | 禁止签名的测试构建无法正常使用安全存储；没有删除安全校验来“修复”测试，改用签名模拟器构建 | 两轮均 34 通过、0 失败、0 跳过；含真实 Keychain 用例 |
| QA-14 | OAuth 客户端展示审查 | 动态客户端显示名由客户端提供，不能作为可信身份；预览补充注册的返回地址主机，供用户核对 | 协议测试核对预览返回地址；9 语言文案 |
| QA-15 | 生产配置启用后本地测试失败 | Wrangler 本地开发继承生产 route 后会改变 HTTP Host，发现文档 issuer 不再是本地地址；增加显式 local 环境，清空 routes，避免测试和生产混用 | 本地真实 HTTP 12 项重新通过 |
| QA-16 | 容量与资源审查 | 清理、请求摘要和队列扫描不应一次加载所有记录；改为每页 100 条扫描，只保留最新 20 条摘要或待执行集合；单操作写入前检查 120000 字节上限 | 超过一页的请求选择/清理、超大操作拒绝测试 |
| QA-17 | 任务取消语义 Review | 前台执行循环调用 disconnect 会取消自身，使撤销网络请求无法发送；拆分停止执行与完成撤销，待撤销状态在前台每 5 秒有界重试 | 注入首次网络失败，验证第二次请求未被取消并清除真实 Keychain；真实 HTTP 撤销另有端到端测试 |
| QA-18 | 最小权限 Review | 库专用授权不应上传行程；设备不能仅信服务端扩大范围或只读授权下的写命令。补齐两端 scope 检查、本地授权交集、配对返回值核对和创建 UUID 碰撞拒绝。更换配对码清空旧选择，打开行程也要求写权限 | 库专用授权无行程快照；设备只读拒写；未批准 ID 不加入；未共享 UUID 不能冒充新建；打开回执明确不等于视觉可见 |
| QA-19 | 私有字段摘要 Review | 普通 SHA 摘要可能让短预订码遭离线猜测；改为 HMAC-SHA256，256 位随机密钥只存 ThisDeviceOnly Keychain，不进入 Carry JSON 备份、CloudKit 或服务器。库版本只摘要其已明确共享字段 | 真实 Keychain 密钥下结果稳定、与普通摘要不同；私有附件变更仍触发冲突 |

## 运行记录与证据

| 检查 | 第一轮 | 第二轮 | 证据 |
|---|---|---|---|
| 签名模拟器真实 SwiftData/Keychain/设备执行链路 | 34/34，0 跳过 | 34/34，0 跳过 | `/tmp/CarryCodexQA-accepted34-round1.xcresult`、`/tmp/CarryCodexQA-accepted34-round2.xcresult` |
| Node 协议/隔离/保留期/容量测试 | 16/16 | 16/16 | `node --test scripts/carry-mcp/test/relay.test.js`，最终日志 `/tmp/carry-mcp-final-round*.log` |
| 实际 Miniflare HTTP 配对→队列→回执→撤销 | 12/12 | 12/12 | `test/live-relay.mjs`，最终日志 `/tmp/carry-mcp-live-final-round*.log`；测试连接已撤销 |
| 主 App + Widget Release（arm64 iOS） | 通过 | 最后源码增量构建通过 | `/tmp/carry-codex-release.log`、`/tmp/carry-codex-release-final34.log`；均为构建验证，未签名分发或上传 |
| 本地化 | 9 语言 | 0 errors、0 warnings | `python3 scripts/i18n-audit.py`；39 个新增键，构建使用 `SWIFT_EMIT_LOC_STRINGS=NO`，避免抽取覆盖 |
| 工程与 diff | PBX lint 通过 | `git diff --check` 通过 | 无新源码编译 warning；SDK beta 环境日志与业务测试结果分别记录 |

初始 11 个设备测试有 2 个失败断言，均定位为 QA-04；结构性修复后 13 个通过，之后扩展至最终 34 个。旧库测试最终使用与旧版一致的 VersionedSchema 1.0.0 标记，不只验证无版本临时库。保留失败记录，不用成功复测覆盖历史。未签名 Keychain 构建另有一次失败，原因和处理见 QA-13。

端到端设备测试实际执行：临时配对并交换 OAuth token → MCP 创建请求 → 设备领取 → SwiftData 提交并查询磁盘 → 重复回执 → 上传白名单快照 → MCP 读回同一 revision → 撤销后 401。只用合成数据，没有读取或上传用户现有行程。

已覆盖旧库轻量迁移、旧 JSON 备份还原、内存 fallback 禁止命令/快照、未授权对象、版本冲突、请求重用、保存失败、单日与无日期转换、关系移动/排序/级联删除、打包幂等与推荐、独立物品库授权、缺失附件复制、结构化多目的地、提醒开关、机场查询、路线预览与行程打开参数。对第三方实时航班/地点服务未宣称全网络覆盖通过；沿用 App 的现有调用与错误处理。

## 2026-10-25 线上复查

- GitHub 功能分支推送成功，远程 `codex/carry-integration` 已核对为实现提交 `15a8212fa98774bc71887665387489d2b62d66bb`；`origin/main` 仍为 `98ab2b5`，未合并主线。
- 生产 Worker 最终源码部署成功，版本 `14cc66af-d01a-4a71-a9c3-c60c9842d822`，包含 QA-18 的权限修复。协议回归 16/16、0 跳过通过；本轮没有修改 App 实现。
- 中文政策已从正式域名完整读取至 `/tmp/carry-privacy-zh-20261025.html`；解码 Cloudflare 邮箱保护并移除其注入脚本后，全文与已提交源码逐字一致。源码 SHA256：`fd4aa59e3758f8b2c07c29f7da38674e21de7e9a2b8659b7d4ee998832b8262f`。
- 普通 DNS 解析已恢复，直接通过原域名和有效 HTTPS 证书读取 `/health`、OAuth authorization-server 与 protected-resource 配置成功；IPv4/IPv6 健康检查分别 4.48s/6.32s 返回 HTTP 200。没有硬编码 IP、关闭证书验证或修改系统 DNS/代理。
- 早期重试记录：原始脚本、仅在进程中绕过代理的诊断、HTTP/2 诊断分别在健康、发现文档、授权状态或令牌请求发生 20s 传输超时；部分请求已有响应正文。失败后已执行设备撤销请求，但未计为完整撤销链路验收。HTTP/1.1 压缩发现文档单独读取也返回 200，暂不能把失败归因于特定 HTTP 版本。诊断脚本仅在 `/tmp` 增加请求路径日志和传输选项，没有改变业务请求、打印凭据或纳入生产代码。失败日志保留于 `/tmp/carry-mcp-production-20261025-round1.log`、`/tmp/carry-mcp-production-20261025-direct-round1.log`、`/tmp/carry-mcp-production-20261025-http2.log`。
- 随后原始 Node fetch 生产合成脚本连续两轮各 **12/12 通过**，覆盖真实部署的注册、PKCE 配对/令牌、投影脱敏、命令重复去重、队列、重复回执和撤销后 401；使用普通 DNS、有效证书与未修改的业务脚本，无固定地址或重试放宽。日志：`/tmp/carry-mcp-production-fetch-20261025.log`、`/tmp/carry-mcp-production-fetch-20261025-round2.log`。两轮成功连接均确认撤销。
- 只输出路由、方法、结果和执行时长的脱敏 Worker tail 观察到上述请求 `outcome=ok`，执行约 11～65ms；独立健康探针总耗时约 2.11s。没有读取或保存请求正文、授权头或令牌。该证据支持服务端处理正常，不能证明所有代理/网络路径稳定；未为网络波动修改生产业务。
- 原生补充验收：测试专用 `CARRY_RELAY_TEST_BASE_URL` 允许显式连接生产服务，默认仍为本地；配置仅在生成的 `.xctestrun` 副本中传入，未改 App 的 endpoint 或 scheme。只记录 endpoint、请求路径与状态，不输出临时授权查询参数、正文或令牌。测试超时与 App 请求一致为 20s，没有增加自动重试或跳过失败。
- 两次原生生产尝试均未通过：首次为 `URLSession -1001`，失败结果已打印，随后 Xcode 卡在诊断收集，本会话终止该次诊断进程，未把未完成的结果包当作完整证据；第二次完整结果为 **0/1 通过、1 失败、0 跳过**。第二次路径日志确认注册、配对、PKCE 令牌、创建命令、SwiftData 落盘数量断言及首个回执全部成功，随后第二次 `/device/receipt` 请求超时；catch 清理 `/device/revoke` 返回 200。尚未到达快照与 MCP 读回，不记为原生生产全链路通过。完整结果：`/tmp/CarryCodexProductionNative-20261025-diagnostic.xcresult`；日志：`/tmp/carry-codex-production-native-20261025-diagnostic.log`。测试库显式 `cloudKitDatabase: .none`，不能将宿主无 iCloud 账号告警当作这次网络超时的根因。
- 新测试配置回归：显式选择 `AutomationTests` 和 `RelayRoundTripTests` 两个测试类，本地 **34/34 通过、0 失败、0 跳过**；原生回归路径确认为默认本地 relay，完整保存/快照/读回/撤销检查通过。结果：`/tmp/CarryCodexRegressionExplicit-20261025.xcresult`；日志：`/tmp/carry-codex-regression-explicit-20261025.log`。此前不带类选择的同一测试配置停留在 Xcode 启动宿主之前，终止该次未启动的测试进程后重新执行，未将其算作测试通过。测试构建与九语言审计通过；没有修改生产 Swift/Worker 源码，也没有为了环境问题加入生产补丁。
- CloudKit 登录后续已完成，详见下节；真机界面与双设备同步仍待完成。不上传新 TestFlight 构建，不配对或上传真实旅行数据。

## 2026-10-25 CloudKit 正确团队复核

- 控制台确认团队 `Bing Xue / 25RAM7275Z`，容器 `iCloud.app.nevestudio.carry`；账户登录门禁通过。分别切换 Development / Production，等待类型列表加载后，两边均只有 `Users`（7 fields），没有 `CD_TripBundle` 或其他 Carry 模型。未查询私人记录、切换系统 iCloud、导入 schema、修改权限或执行生产部署。
- 这项不是只补 `AutomationExecutionRecord`：完整业务 schema 尚未在这两个环境出现，现有 iCloud 同步不能据工程 entitlement 或本地初始化通过就宣称已验收。先由原生模型初始化完整 Development schema，再核对差异并部署 Production，最后验证双设备同步。
- 根据 Apple 官方 SwiftData 同步文档，用 `NSManagedObjectModel.makeManagedObjectModel(for: SchemaV1.models)`、独立临时 Core Data 库与 `initializeCloudKitSchema(options: .dryRun)` 做了一次明确不上传记录的验证。源码编译成功，但执行 **0/1 通过、1 失败**：错误链 `134060 → 134406 → 134400 / CKAccountStatusNoAccount`。dry-run 仍需 mirroring delegate 完成 iCloud 账户初始化，不能以网页会话代替设备会话，也不能绕过校验或手填猜测字段。
- 证据：`/tmp/CarryCloudKitSchemaDryRun-20261025.xcresult`、`/tmp/carry-cloudkit-schema-dryrun-20261025.log`；探针源码保留于 `/tmp/CarryCloudKitSchemaTests-20261025.swift`。该实验未解决设备账户前提，按最小有效改动原则从默认测试套件移除，未加入生产代码或把失败改成跳过；原有 34 项测试源保持不变。
- 当前可见 `Murphy’s iPhone` 物理设备连接，但未检查其私人 iCloud 身份、安装或覆盖 App。已询问用户是否能提供账户持有人的 iPhone 作为初始化测试设备；设备和备份核对完成前不覆盖现有 Carry。
- 依据：[Apple SwiftData 同步与初始化说明](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)、[Apple dryRun 定义](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainerschemainitializationoptions/dryrun)。

## 2026-10-25 既有 iPhone 与隔离初始化工具

- 用户确认继续使用自己的既有测试 iPhone。不能仅从设备归属推断 CloudKit 访问权限，最初直接要求账户持有人的手机过早；后续改为以实际账户/容器接口结果判断，不要求预先切换 Apple ID。
- 设备检查：iPhone 17 Pro、iOS 27.0.1、已配对、开发者模式开启；现有 Carry 仍是 `1.0 (3)`，开发构建的数据容器可访问。只检查元数据与容器目录，没有读取旅行记录或声称已建立完整备份，没有覆盖或卸载现有 Carry。
- 新增开发工具 `scripts/cloudkit-schema-bootstrap`：单独 Bundle ID `app.nevestudio.carry.schema-bootstrap`，独立 App ID/profile，不创建 App Store Connect 应用记录。实际签名和 profile 核对为团队 `25RAM7275Z`、唯一工具标识、容器 `iCloud.app.nevestudio.carry`、`Development`、包含已连接设备；没有 Carry App Group 或 HealthKit。工具只有模型检查、dry-run 和显式 Development 初始化三种模式，没有生产部署入口。
- 原生模型由 `CloudKitModelExportTests` 使用 Apple API 从当前 `SchemaV1.models` 导出并安全归档，验证全部 11 个实体以及读回后的实体版本哈希。导出不打开 CloudKit store、不读取用户数据库。独立工具在模拟器中 `--inspect-model` 成功读取全部 11 个实体，证明不依赖 Carry 应用模块中的类来手填结构。产物为 21608 字节，构建使用的模型 SHA256 `df7a4c1bc5b696818d60e888fa1a63a5b2587bb73708caac36b39ef2a4c8ff61`；产物与生成的 Xcode project 不提交。
- 工具模拟器/真机编译通过；首轮通用目标方向配置告警已通过声明完整支持方向解决，最终真机构建无该告警。临时库在成功和失败路径均卸载与清理，错误只保存阶段及域/码，不保存凭据、账户标识或用户内容。工具源代码已自行检查；只有测试与运维辅助代码变化，Carry 生产业务代码未改。
- 独立工具已安装到已连接 iPhone。启动默认 dry-run 时系统返回 `FBSOpenApplicationErrorDomain:7 / Locked`，未进入工具的账户状态检查，也没有结果文件，不能报告 iCloud 访问通过或结构已初始化。随后只读锁状态确认 `passcodeRequired=true`；已请用户解锁并保持亮屏。现有 Carry 再次查询仍为 `1.0 (3)`。
- 新测试加入后的两轮本地全量回归均 **35/35、0 失败、0 跳过**；第二轮增加归档实体版本哈希相等校验。结果：`/tmp/CarryCodexRegression35-20261025.xcresult`、`/tmp/CarryCodexRegression35-final-20261025.xcresult`。独立工具模型读取结果：`/tmp/carry-bootstrap-model-inspection-20261025.json`；最终真机构建日志：`/tmp/carry-schema-bootstrap-device-build-final-20261025.log`。这两轮不替代此前未通过的原生 MCP 线上往返、真实 CloudKit 初始化或双设备同步验收。

## 2026-10-22 线上与真实设备门禁（历史快照）

1. Worker `carry-mcp` 已部署，自定义域名 `connect.nevestudio.app`，最近成功版本 `41e372a1-cfef-44ea-b6b8-a5eead82dfea`。QA-18 的最后服务端权限收紧尚未成功重部署：Cloudflare API 经已有代理发生 TLS/连接失败。健康端点曾成功返回；完整远程合成链路因 DNS/连接超时未完成，不能计为通过，也不能说线上已是最终源码。
2. 当前机器普通 DNS 返回旧的否定缓存；可信 DoH 返回 `104.21.70.104`、`172.67.222.218`。尝试普通访问、已有代理及保留域名 SNI/证书验证的单次地址诊断，仍发生不同端点超时。没有关闭证书验证，也没有改用户系统 DNS/代理配置。域名可用性仍是发布门禁。
3. 中英隐私更新已在 `neve-web` 提交并 push：`7f0aaa2`。核对 Pages 部署列表发现未自动触发，手动发布到原项目，部署 `4d2e404a`。英文线上已完整读到 10 月 22 日和 Codex 条款；中文源码及部署文件已核对，线上完整读取超时，仍需复核。
4. CloudKit 浏览器账号仅显示 `Murphy Lui / 77U9DL9873`，没有 Carry 的 `Bing Xue / 25RAM7275Z` 团队；`cktool` 没有已保存管理 token。已请求用户在保留的 CloudKit 标签页登录正确团队。不创建或索取新的管理凭据来绕过此门禁。
5. `AutomationExecutionRecord` 本地可加迁移已通过，不等于 CloudKit Production schema 已部署。正确团队下仍须核对 Development/Production 差异，部署 schema 后验证真实双设备同步。
6. 此开发环境有 CoreSimulator runtime、能运行真实测试，但 `/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app` 不存在；原生界面工具与 Finder 检查均确认无法打开 Simulator UI。未将无截图的测试冒充界面验收。真机配对、9 语言界面、前后台竞争、iCloud 账号切换和同步仍须完成。
7. 没有新 TestFlight 上传、正式商店发布或现有用户数据配对；旧 build 3 不含本功能。本任务未宣称整件交付完成。
8. 实现、自动测试与审查记录已在独立分支本地提交；GitHub push 同样发生 `SSL_ERROR_SYSCALL`，尚未推送该分支，也未合入 main。原主项目和现有 TestFlight 保持不变。恢复网络后先重部署最终服务端、复核线上完整链路，再继续发布门禁。

## 代码质量审查与去留

- 保留隔离事务 Context：真实 SwiftData 用例证明它修复失败回滚污染观察图的问题；不能改回吞错保存或仅 JSON mock。
- 保留本地独立摘要、同事务回执、Keychain 同步撤销、服务端二次字段白名单、分块和分页扫描：均对应可复现风险与测试。
- 撤回普通 `refresh()` 一律换 Context 的改动：命令提交与快照读取已经有专用边界，无需扩大到所有普通刷新路径。
- 提取并复用既有目的地回填、模型复制、行程天数协调、路线算法、打包推荐、通知/日历/Widget/Live Activity 入口；不另造平行数据模型或直接改 CloudKit records。
- 默认连接不加附件字节、健康信息、全局设置、备份/清空万能权限；没有为了覆盖能力目录而绕过系统交互或隐私边界。
- 自行 Review，未启动多 Agent。密钥配置只在 gitignore 的 `Secrets.plist` 与现有 Cloudflare 凭据中使用，不进入提交、日志或测试报告。

## 产品与系统边界

- `applied` 只证明本机已持久化，不证明另一 iCloud 设备已经同步。
- 云端读取带快照时间；设备未运行时写入保持排队。
- 附件、HealthKit、系统日历叠加事件和完整备份不进入默认授权投影。
- 操作系统授权、相机取景、购买确认等仍需要用户在设备上完成，不能报告为远程无交互执行成功。
