# Carry 与 Codex 接入

Status: Superseded as final product architecture — 2026-10-25。用户已明确长期要求手机关闭时也可完成对话操作，最终方向转为账户服务与可靠离线同步，见 `carry-cloud-and-ai.md`（产品方向已确认，具体方案待确认）。本文保留既有设备执行实现与验收历史，不能按旧方案作为最终功能发布。已实现 40 项工具、完成本地测试及配对恢复修复；CloudKit Production 结构已部署并读回。未上传新 TestFlight、未合并主线；最新证据见 `docs/codex-integration-qa.md`。

## 目标与验收口径

用户在 Codex 对话中查询、创建和修改 Carry 的旅行数据，操作结果能在 Carry 内查到，并继续通过现有 CloudKit 同步。无需反复导出备份、生成导入文件或点按界面完成日常操作。

“已完成”须有设备端持久化成功的回执；服务端收件、排队、缓存更新均不能代替此回执。查询须附快照时间，不能把离线快照描述成设备实时状态。

## 已核实的项目约束

- `CarryApp.container` 使用 SwiftData + CloudKit `.automatic`，容器 `iCloud.app.nevestudio.carry`。设备本身的 iCloud 登录提供同步身份，App 内没有 Apple 登录。
- `TripStore.init` 异步加载数据；外部命令执行须在数据加载完成之后，且数据库为持久化模式。in-memory fallback 下禁止执行外部写入或发布空快照。
- `CarryShortcuts.swift` 的创建入口转交 App 导航；它不能作为“已创建行程”的调用结果。
- 行程/地点/交通/住宿/物品大部分写入集中在 `TripStore`，但存在保存异常只记录日志、返回值不区分保存成败的路径。接入前必须建立可抛错的事务边界，不能调用后无条件回报成功。
- 通知重排、日历、Live Activity、费用快照、Widget 和附件清理有现成约定，外部命令须与 App 操作共用业务逻辑。
- 旧 spec 的 Status 可能滞后于代码，例如交通/住宿 spec 的初始 Draft 标记；实现现状以真实入口调用链与当前代码为准。
- 现有约定不加入“使用 Apple 登录”；本提案沿用这一决定。云端连接采用单独、可撤销的设备配对授权。

## 已确认方案

`Codex → 远程 MCP → 已配对请求队列 → Carry 命令执行器 → SwiftData/CloudKit → 持久化回执`

远程 MCP 提供 Streamable HTTP 接口，已部署在 `https://connect.nevestudio.app/mcp`，使用 Cloudflare Worker 与 SQLite Durable Object。2026-10-25 已重新部署最终源码，生产完整合成链路两轮各 12/12 通过；原生设备、CloudKit 与界面验收单独记录于 `docs/codex-integration-qa.md`。

云端保存授权范围内的结构化查询快照、请求、执行状态与回执。SwiftData/CloudKit 保持旅行数据的真实来源；查询快照可重建。云端不直接编辑 SwiftData 自动管理的 CloudKit records，也不持有开发者私钥来读取用户私有库。

配对设备负责执行。用户指定一台执行设备，其他设备继续走 CloudKit 同步；更换执行设备须完成旧设备停用和未决请求交接，不能同时派发给多个设备。首次版本不做自动执行设备抢占。

### 必须接受的使用边界

- Carry 正在运行且联网：请求可立即尝试执行，返回具体结果。
- Carry 被系统挂起、退出或离线：请求保持 `queued`；后台机会只用于加速，不承诺必达或即时运行。用户下次打开 Carry 后执行。
- 只有收到本地持久化成功回执后，才能回报 `applied`。它不保证其他 iCloud 设备已同步完成。
- 查询离线快照时返回 `capturedAt`、执行设备、同步状态；要求实时查询且设备不可达时返回不可用。
- 如果产品要求“所有设备都关闭时依然立即修改且立即读回”，需单独确认服务端作为旅行数据主存储的方案及迁移，不能以本方案承诺该体验。

## 能力范围

下表是能力边界与长期目标，不代表每项都已开放。当前默认连接实现行程/地点/交通/住宿/打包/费用、可单独授权物品库、搜索、路线预览、行程提醒开关和打开行程；具体 40 项以 `scripts/carry-mcp/README.md` 与工具目录为准。附件、健康、日历叠加、全局偏好、分享文件导出、整库备份/还原/清空没有开放，不属于本连接的默认授权，客户端须明确说明限制。

最终目标覆盖可授权的用户功能；工具目录公开每项能力的 `supported`、授权范围和依赖条件，未接通的操作不得伪装成功。

| 功能 | 对话操作与实际业务入口 | 约束 |
|---|---|---|
| 行程 | 查询、创建、编辑、复制、删除；`createTrip` / `updateTripInfo` / `duplicateTrip` / `removeTrip` | 支持无日期规划；目的地走结构化解析；UUID 寻址 |
| 地点与天 | 查询、增改删、跨天移动、排序；`add/update/removeItineraryStop` / `moveItineraryStop` / `applyItineraryArrangement` | 不越过合法天数；缩短行程沿用 App 的保留数据规则 |
| 航班与交通 | 查询、增改删；`add/update/removeTransportSegment` | 独立两端地点、当地时间和时区；调用现有航班服务时沿用密钥与限流规则 |
| 住宿 | 查询、增改删；`add/update/removeLodgingStay` | 入住/退房均须合法，不把住宿当成普通地点 |
| 打包清单 | 分类与物品增改删、数量、明确设置打包状态、排序、场景推荐 | API 使用 `isPacked=true/false`，不使用重试后反转的 toggle 语义 |
| 我的物品 | 查询、增改删、分类与集合维护 | 区分物品库与某次行程清单 |
| 费用与备注 | 三类实体的费用与备注；`setStopCost` / `setTransportCost` / `setLodgingCost` | 保存原币金额；沿用本位币快照与缺汇率标注 |
| 提醒与偏好 | 查询和设置 App 可配置项 | 尊重设备权限；系统授权弹窗由用户在设备完成 |
| 搜索与路线 | 机场/目的地/地点检索、路线优化预览与采纳 | 复用既有服务；境内地点不发送到境外 POI 检索服务 |
| 统计与分享 | 行程册/花费查询、生成现有分享产物、打开行程 | 分享排除附件；生成文件与发送给第三方是分开的动作 |
| 附件与照片 | 独立授权后的受控导入/读取/删除、照片重建行程 | 默认没有读取字节权限；文件须有明确来源与范围 |
| 备份与清空 | 导出、还原、抹除 | 独立高权限；先展示影响范围和恢复方式，再明确确认 |
| 系统 UI 与购买 | 打开对应 App 页面 | 摄像头、系统权限、StoreKit 支付需设备交互，不声称可无交互执行 |

## MCP 与设备命令协议

- 查询：`list_trips`、`get_trip`、`list_capabilities`、`get_operation` 等；按行程与字段最小化返回，支持分页。
- 写入：按业务域提供明确的 typed tools，避免任意执行代码、SQL、路径或模型字段的“万能工具”。
- 请求包含 `protocolVersion`、`requestId`、配对上下文、操作名、实体 UUID、输入字段、预期数据版本、截止时间。
- 身份与授权从服务端凭据上下文取得，禁止相信调用参数传入的用户 ID 或任意 `tripId`。
- 更新明确区分字段缺省（不修改）、空值（清除）和新值（替换）；日期用日历日期、事件时间用当地时刻 + IANA 时区，不把设备当前时区当作请求时区。
- `TimeZoneCanonicalizer` 处理自动解析得到的大陆地理时区别名，保留用户显式覆盖；坐标必须成对、范围合法，金额须有限，枚举须在已支持集合内。
- 新建实体 UUID、规范化输入和执行结果须随请求持久化，重试沿用同一 ID，不能重复创建。
- 结果包含状态、实体 ID、保存版本、快照时间和结构化错误码；技术协议字段不作为 App UI 文案直接展示。

## 写入一致性与错误处理

### 配对批准响应丢失（2026-10-25 真机验收补充）

服务端消费配对码后，网络可能丢失返回的设备凭据。必须在第一次批准请求前，把随机设备凭据、连接 UUID、授权范围和待完成配对信息保存至 ThisDeviceOnly Keychain；保存失败时不发批准请求。待完成连接不得执行操作或上传快照。相同凭据与相同输入重试必须返回同一连接，不扩权、不重复授权；App 重启后可恢复。退出/账号变化必须先取消待完成配对或撤销已经成立的连接，并持久化撤销状态；不能清除本地记录后留下无法管理的授权。服务端只保存凭据及恢复输入的摘要，不保存明文设备凭据；取消先于批准到达时，也必须阻止迟到请求创建连接。补充 OAuth 令牌撤销端点以管理客户端授权和清理失败测试连接。

1. 从实际数据加载完成点启动命令接收，主 actor 串行执行本设备的写入。
2. 校验授权、作用域、协议版本、截止时间、对象归属和请求去重，再校验业务输入。
3. 基于当前数据重新核对预期版本；过期快照命令返回 `conflict`，不静默覆盖用户刚在 App 里做的修改。iCloud 为最终一致，同步尚未到达的跨设备修改不能承诺强一致，须列入验收。
4. 抽取现有业务写入逻辑，建立显式 `throws` 的保存边界；模型变更与请求执行凭据在同一持久化事务提交。失败回滚，禁止吞错。
5. 保存成功后更新发布状态，沿用通知、费用、日历和 Live Activity 业务入口；外部副作用失败单独回报、可重放，不撤销已提交的数据或重建实体。
6. 回执发送失败时重试发送已有回执；崩溃恢复时先查本地执行凭据，再决定是否执行。明确不承诺网络层 exactly-once。
7. 同 `requestId` 不同内容返回错误；过期或已撤销的请求不能在设备下次启动时悄悄执行。
8. 初始批量操作使用单一行程作为事务范围，执行前验证全部子操作；禁止循环调用会各自保存的现有方法来假装批量原子性。

状态至少包含 `queued`、`executing`、`applied`、`failed`、`conflict`、`expired`、`cancelled`。设备执行权失联时不能未经核实把 `executing` 改派后再次写入。

## 配对、隐私与撤销

- 默认关闭；设置页提供“连接 Codex”，说明可访问的行程、字段、云端保存内容及设备在线要求。
- 采用有时限、一次性配对流程，用户在 Carry 确认范围后向特定客户端授予连接；不采集 Apple ID 密码，不新增 Apple 登录。
- MCP 客户端使用标准授权方式（优先 OAuth 2.1 + PKCE）；设备凭据与客户端凭据分离，限制 audience、scope 与绑定关系。
- 凭据存 Keychain/服务端安全存储；云端仅存必要的凭据哈希与可撤销关系。token、配对码不入日志、备份、公开仓库或对话。
- 默认只授权用户选定行程的旅行数据；不包含 HealthKit、系统日历叠加事件、原图、文件附件、完整备份与设备日志。读取附件和预订确认号等敏感字段须另列范围。
- 导入内容、备注、网页、附件均是用户数据，不提供改变授权、执行命令的权限。
- App 内可查看、暂停、撤销连接及取消未执行命令。撤销同时停止新快照、拒绝队列领取和回执外的写请求，并执行云端数据清理策略。
- 定义查询快照、已完成请求、失败请求的保留期与主动删除接口；具体期限随本 spec 产品确认，不在未实现前宣称已清理。
- 实施默认期限：配对流程 10 分钟、授权码 1 分钟、访问令牌 1 小时、刷新令牌 30 天；命令 24 小时过期，已结束请求保留 7 天，查询快照在 14 天未刷新后清理。撤销立即删除查询快照、尚未执行请求及凭据关系；执行中的请求可能已保存，需如实显示该边界。
- 实现上传前更新 `neve-web` 中英隐私政策、PIPL 对应条款与 ASC 数据声明；新能力默认关闭至说明和授权流程都可用。

## 实施与验证顺序

1. 确认本 spec 的云端数据处理与离线待执行体验，随后定稿权限矩阵、字段协议、保留期限和配对流程。
2. 实现命令执行层及有保存结果的事务 API；先验证创建/读取/修改/删除同一测试行程的完整链路，覆盖重试、冲突、保存失败和副作用。
3. 实现远程 MCP、配对、查询投影、队列和回执；仅使用合成数据进行协议和隔离测试。
4. 在同一业务命令层补齐能力矩阵，逐项开放工具并更新 capability 结果；不把未完成项标记支持。
5. 完成 9 语言、隐私文档、迁移/备份兼容验证，构建 App 与 Widget，最后运行本地化审计。
6. 用户真机验收：配对、创建与修改、日本跨时区行程、离线→恢复、回执丢失重试、重启、撤销、另一 iCloud 设备同步。UI 自动点按沿用 CLAUDE.md 的单次授权要求。

验收还必须覆盖：两个独立配对无法互读；未授权行程不可改；附件/健康/系统日历数据未进入快照；保存失败无成功回执；旧备份可导入；取消命令不在下次启动执行；切换 iCloud 账号后暂停旧连接；非持久化数据库禁止外部写入。

## 当前实现与发布门禁

2026-10-25 CloudKit 复核：账户持有人已登录正确团队；Development 和 Production 的 Record Types 均只有系统 `Users`，没有业务类型。Apple 的 `NSManagedObjectModel.makeManagedObjectModel(for:)` 从完整 `SchemaV1.models` 构建模型后，已尝试在独立临时库执行 `initializeCloudKitSchema(options: .dryRun)`，但 mirroring delegate 因设备没有 iCloud 账号而失败；没有上传记录、读取用户库或手工推测字段。失败探针保留于本机证据，未留在默认测试套件。实际初始化须在具备正确 Development 签名和 iCloud 会话的测试设备上显式运行，再核对 Console 中完整业务类型及部署差异；仅登录网页不代表设备端初始化或同步已完成。

用户现已连接自己的既有测试 iPhone；不根据设备归属预先要求切换 Apple ID。为避免覆盖 Carry 1.0(3)，使用独立开发工具 `app.nevestudio.carry.schema-bootstrap`：通过测试目标从当前真实模型安全归档导出 `.mom`，工具只加载该模型并使用新建临时库；不包含 Carry 的 App Group、HealthKit、照片或 WeatherKit 权限。先做设备账户状态与 dry-run 检查，成功后才通过显式参数执行 Development 初始化；签名必须核对为团队 `25RAM7275Z`、容器 `iCloud.app.nevestudio.carry`、环境 `Development`。工具没有生产部署入口，不修改现有 Carry 安装或数据。实际访问失败时依据错误决定后续账号步骤。

- 主项目：`/Users/murphy/Documents/Projects/Carry`。
- 本功能独立 worktree：`/Users/murphy/Documents/Projects/Carry-codex-integration`，分支 `codex/carry-integration`，起点 `98ab2b5`。
- 当前聊天已迁入 Carry 项目；本轮开发与构建使用上述隔离 worktree。
- 新增模型 `AutomationExecutionRecord` 为可加迁移，本地旧库迁移已实际验证；仍须在正确 Apple 团队中核对 Development schema，并部署到 Production 后验证同步。
- 中英隐私政策已提交并推送至 `neve-web`（`7f0aaa2`）；Git 推送未触发 Pages 自动部署，已手动部署到原 `neve-web` 项目（`4d2e404a`）。英文线上已读到新条款；中文于 2026-10-25 完整读取并核对与源码一致（仅 Cloudflare 邮箱保护转换）。
- 生产域名完整合成链路已通过；发布前仍须通过真机配对与界面验收、CloudKit Production schema 和跨设备同步。App 功能默认关闭，实际旅行数据未上传。详见验收记录。

## 来源

- [OpenAI：Codex MCP 支持的传输与授权](https://developers.openai.com/codex/mcp/#supported-mcp-features)。
- [Apple：CloudKit Web Services 身份认证](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html)：server-to-server key 用于 public database，用户数据库访问需要用户身份上下文。
- 项目：`CLAUDE.md`、`docs/architecture.md`、`docs/infrastructure.md`、`docs/progress.md`、`docs/decisions.md`、`docs/release-checklist.md`、`docs/product-design.md`，以及 iCloud、无日期规划、交通/住宿、时区、附件、通知配额和费用规格；上述行为结论核对了 `CarryApp`、`CarryShortcuts`、`TripStore` 与 `DataBackupManager` 的实际入口。
