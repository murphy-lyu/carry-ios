# Carry MCP

远程 Streamable HTTP MCP、OAuth 2.1 + PKCE 配对、受限查询快照与设备请求队列。无需 OpenAI API key，也不直接读取 CloudKit 私有数据库。SwiftData 是真实数据来源。

## 状态与使用前提

- MCP 地址：`https://connect.nevestudio.app/mcp`。Cloudflare Worker 与 SQLite Durable Object 已部署；最终部署版本、线上连通性与发布门禁见 `docs/codex-integration-qa.md`。
- 需要包含本功能的 Carry 构建；旧 TestFlight build 3 没有连接设置，不能配对。
- Carry 仅在前台、联网、持久化数据库加载完成后执行。设备离线、挂起或退出时请求排队，不承诺后台即时运行。
- 本功能默认关闭，不自动选择或上传任何已有行程。真机配对、CloudKit Production schema 与跨设备同步尚未验收时，不上传新 TestFlight 构建。

## 配对

已核对本机 Codex CLI 支持以下命令；应在完整发布验收后使用：

```sh
codex mcp add carry --url https://connect.nevestudio.app/mcp
codex mcp login carry
```

浏览器显示配对码后，在 Carry → 设置 → 连接 Codex 输入该码，核对客户端、授权返回地址和权限，选择行程后批准。客户端显示名由客户端提供，仅批准自己刚发起的连接。物品库默认不共享，需要另外开启授权。无需提供 Apple ID 密码，不引入 Apple 登录。

手机先把随机设备凭据及待完成配对存入 ThisDeviceOnly Keychain，再发批准请求。响应丢失时显示待完成状态，恢复联网/前台后使用同一连接和同一输入继续；期间不上传快照或执行命令。断开会取消尚未消费的配对码，或撤销已建立的授权，迟到的批准不能重新建立连接。OAuth 客户端也可通过发现文档中的 `/revoke` 撤销自己的授权。恢复设备配对不会延长 OAuth 授权码有效期；客户端授权已过期时需断开并重新发起授权。

## 能力与边界

40 项 typed tools，实际目录通过 `tools/list` 与 `list_capabilities` 返回，按授权过滤：

- 行程：查询、创建、编辑日期/无日期状态、结构化多目的地、行程提醒开关、复制、删除、打开行程。
- 地点：增改删、跨天移动、排序、路线优化预览与采纳。优化返回直线距离口径，固定首尾；不是道路导航或交通时间。
- 交通/住宿：增改删、独立两端时区与当地时刻、备注和费用。
- 打包：分类/物品增改删与排序、明确设置打包状态、既有场景推荐预览及选定物品合并；不自动读取 HealthKit。
- 可单独授权的自定义物品库：查询、增改删、集合/分类及数量规则；不影响已经生成的行程清单。
- 机场离线检索、MapKit 地点检索、既有航班服务查询。地点检索不把境内查询转发给境外 POI 代理。
- 请求状态查询、取消未执行请求、撤销连接。

默认连接明确不开放附件/原图、HealthKit、系统日历叠加事件、完整备份与还原、整库清空、全局偏好和分享文件导出。系统授权、相机和购买确认需要设备交互。以上不支持的能力不会伪装为成功，也没有通用 SQL、代码执行或任意字段写入工具。

### 请求与回执

1. 读取授权快照及 `revision`；`capturedAt` 是快照时间，不是设备实时在线证明。`get_trip` 可按 `dayOffset/dayLimit` 分页。
2. 更新须带当前 `expectedRevision`。每次逻辑请求生成一个 UUID `requestId`，网络重试复用它；同 ID 不同内容会被拒绝。
3. 写入与设备查询都可能先返回 `queued`，用 `get_operation` 等待终态。设备查询结果在 `result.data`。
4. `applied` 只确认设备已经提交数据或持久化查询回执，不确认另一台 iCloud 设备已经同步。
5. 版本过期返回 `conflict`，重新读取后再确认修改；不得静默覆盖。删除须先确认精确对象。

新建行程会加入当前连接的授权范围。现有未选行程不会自动加入。单台配对执行设备负责串行保存；没有自动执行设备抢占。

## 数据与限额

- 设备凭据保存在 ThisDeviceOnly Keychain；服务端只保存凭据哈希。配对码 10 分钟、授权码 1 分钟、访问令牌 1 小时、连接及刷新凭据最长 30 天。
- 请求 24 小时过期；终态请求及回执保留 7 天，无法确认执行结果的请求最多 8 天；快照 14 天不刷新后不可读取，按小时清理。撤销立即删除该连接快照、分块、请求与凭据关系。
- 恢复/清空本地数据前，先同步持久化撤销标记；iCloud 账号变化也会暂停并撤销旧连接。
- 单请求体 2 MiB；每连接最多 100 个授权行程、100 个待执行请求和 1000 个保留请求；单操作记录最多 120000 字节，查询结果最多 60000 字节。大快照按 UTF-8 字节分块，避免单值存储限制。
- 公开配对/注册/令牌端点按来源每分钟 30 次，已认证连接每分钟 240 次；来源标识加盐哈希。应用不记录请求正文、凭据或配对码。
- 本地幂等回执与业务写入在同一事务提交，31 天后启动清理；回执不进入 Carry 导出的 JSON 备份。敏感附件等元数据只参与本地版本 HMAC，不进入查询投影；HMAC 密钥只存设备 Keychain，防止短预订码被离线猜测。

本地 QA 的原生回归与 live HTTP 回归须使用独立的 Wrangler `--persist-to` 目录和端口，避免共享 Durable Object 的来源限流预算。例如原生测试保留 8789，live 服务使用 `--port 8790 --persist-to /tmp/carry-live-qa`。不要为了并行测试降低生产限流。

## 开发与验证

需要 Node.js 22 或更新版本。系统旧 Node 18 不适合当前 Wrangler。

```sh
cd scripts/carry-mcp
npm ci --ignore-scripts
npm test
npx wrangler dev --env local --local --ip 127.0.0.1 --port 8789
```

另一终端运行：

```sh
node scripts/carry-mcp/test/live-relay.mjs
xcodebuild -project Carry.xcodeproj -scheme CarryAutomationTests \
  -destination 'platform=iOS Simulator,name=Carry Codex QA' \
  CODE_SIGN_IDENTITY=- SWIFT_EMIT_LOC_STRINGS=NO test
python3 scripts/i18n-audit.py
```

测试目标使用临时磁盘数据库与合成行程，端到端测试连接本地 8789 端口。真实 Keychain 用例需要签名模拟器构建；不要用 `CODE_SIGNING_ALLOWED=NO` 后把 Keychain 失败当成应用业务失败。若设备已有连接，Keychain 测试会跳过，避免覆盖它。最终验收记录必须包含实际 skipped 数量。

远程合成验证：`node scripts/carry-mcp/test/live-relay.mjs https://connect.nevestudio.app`。脚本请求超时有上限，结束会撤销测试配对；失败不得报告为通过。`--curl` 可使用本机已有代理；只有经可信 DNS 核实后才用 `--resolve-address=<IPv4>` 做单次诊断，保留原域名的 Host/SNI 与证书验证，不修改系统 DNS。`--use-proxy` 使该诊断仍经过已有代理。诊断地址不能作为应用硬编码或普通网络可用性的证明。

原生 SwiftData 线上验证：`RelayRoundTripTests` 默认仍连接本地 relay。只有在专用测试设备上，显式给测试进程设置 `CARRY_RELAY_TEST_BASE_URL=https://connect.nevestudio.app` 才会连接生产服务；只允许文档中的本地/生产地址。可在 `build-for-testing` 生成的 `.xctestrun` 副本内，为 `CarryAutomationTests.EnvironmentVariables` 设置该值，再通过 `test-without-building -xctestrun <副本> -only-testing:CarryAutomationTests/RelayRoundTripTests` 执行。副本放在原文件同目录，保留 `__TESTROOT__` 相对路径。不要改默认 scheme 或 App 的运行环境。该测试使用新建临时磁盘库、合成行程和短期配对，不验证 CloudKit 同步或真机 UI。

生产部署：`npx wrangler deploy --env ''`，仅使用顶层生产配置。`local` 环境不继承生产自定义域名。部署后检查健康、发现文档、完整配对/队列/回执/撤销链路，再完成真机与跨设备验收。不得把部署命令成功等同于验收成功。
