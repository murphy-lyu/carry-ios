# Mac 与 iPhone 联合验收

日期：2026-11-01。仅操作 `Carry QA Sync 20261101` 合成测试行程；未迁移原 13 趟私人行程。Mac 登录由用户本人完成 Touch ID。

## 已验证

- 工程原来把 iOS Widget 同时嵌入 Catalyst，触发平台不匹配构建失败。给嵌入项和 target dependency 加 iOS platform filter；iOS Widget 保留，Catalyst 不再嵌入不兼容扩展。
- Mac Catalyst 未签名和正确团队开发签名均构建成功。Xcode 自动注册当前 Mac 并生成原 Bundle ID `app.nevestudio.carry` 的开发 profile，未另建检查 App。strict codesign 验证通过。
- Mac 验收包仅将构建产物 `CarryAccountReleaseReady` 设 true；账户 AI 门禁及仓库发布门禁仍关闭。用户完成 Apple 登录，设置实际显示 Signed in；启用同步后显示 Changes saved to your account。
- Mac 拉回 iPhone 已发布的合成行程、上海博物馆地点、CNY 42 与合成文件名，证明实际物理客户端账户读回链路可用。原 iCloud 行程在 Mac 仍按旧路径显示，未迁入账户。
- 打开地点详情连续两次崩溃，已保存 17:02:06 / 17:02:24 的系统 ips。栈为 `EnvironmentObject.error → StopDetailView.store.getter → stopScheduleSubtitle`。统一行程 sheet 根显式注入当前 owner store/router，覆盖地点、交通、住宿和编辑。修正版正确团队构建通过，实际再次打开同一地点，详情费用和文件均正常显示，编辑页也可保存。
- Mac 将合成地点名称修改为 `Carry QA Museum — Mac verified` 并保存；iPhone 接收这一修改、反向修改及冲突仍待继续观察，不把已保存界面冒充云端收敛。
- 合并后原生全量两轮各 351 通过、1 项手动物理检查跳过，0 失败、0 runtime warnings。结果 `/tmp/CarryIntegratedFinalQA-20261101/round-{1,2}.xcresult`。这两轮先于上述 sheet 注入修正；修正后 Simulator、Mac 和 iPhone Debug 构建另行通过。
- 最新 iPhone Debug 同 Bundle ID 安装成功、strict/deep codesign 通过，冷启动保留账户和行程，多个已有照片封面正常显示。Release、最新两端界面及更多冷图操作另行记录，不能把 iPhone 17 Pro 的显示结果称为 iPhone 12 性能实测。

## Codex 真实连接

- 官方 CLI 已登记 `carry-account`，连接 `https://connect.nevestudio.app/mcp`；原配置先保存受限备份，没有改动既有服务。
- 实际 Codex DCR HTTP 400；使用 loopback 合成元数据服务捕获公开注册字段，确认 CLI 发送 `application_type: native`。旧服务错误地拒绝未知 DCR 元数据。
- 按 RFC 7591 仅在注册端点投影支持字段，忽略未知字段，验证/回显 native 或 web，仍保持服务器生成 client ID、精确 redirect、PKCE、resource 与本人 consent。独立 Review 没有发现授权边界扩大；顺带修复 auth_method 的 truthy 校验，显式 null/false/0/空字符串均拒绝。
- AI 全量两轮各 104/104；最后 auth_method 收紧的 Worker 定向 37/37。实际 Codex 尚未取得授权，不宣称已连接成功。
- Supabase 网页部署失败已取得明确错误：既有跨目录 `index.ts` 导入在网页打包时解析成不存在的 `/carry-account-ai/edge-entry.ts`。失败没有更新线上服务；本地修复仍需用完整打包入口部署。已用现有 esbuild 生成独立 ESM、保留锁定 npm 导入，Deno check、无网络 enabled runtime 初始化和 disabled 503 检查通过。没有导出浏览器凭据或私钥。
- `curl`/Node 经当前代理 TLS 停滞，Foundation URLSession 与真正 Codex 可达；没有更改代理配置。网络探针不是实际 OAuth 成功证明。

## 继续验收 / 待办

- 继续 Mac ↔ iPhone 双向编辑、删除恢复、离线/冲突、附件实际预览。
- 用户已同意将第二台 iOS 设备验收记待办；Mac ↔ iPhone 可以先完成跨平台物理同步验收，不能替代 iOS ↔ iOS 专项。
- 完整 Codex 授权、手机关闭时创建/修改/读回、撤销重连和原生 AI 入口验收。
- 新预算策略默认关闭，代码/两轮测试已完成，托管迁移、容量核对和受限开发策略启用尚待执行。见云端运维报告。
- iPhone 12 原“点击无反应”仍缺对应设备轨迹；已修复可达冷封面主线程读取，但不宣称原反馈根因已证实。
- 无正式发布、无主线合并、无 TestFlight 新版上传。

依据：[RFC 7591](https://www.rfc-editor.org/rfc/rfc7591)、[OpenID 注册元数据](https://openid.net/specs/openid-connect-registration-1_0.html)、[Codex MCP 文档](https://developers.openai.com/codex/mcp)。
