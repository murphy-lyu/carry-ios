# 网页账户适配与副本时序复核 · 2026-10-28

## 交付边界
本次为已批准完整功能中的内部实现与 Review，**仍非产品交付**。网页服务未部署、入口关闭，无新 DNS 路由；原生/网页真实 Apple 身份、完整删除、业务写入口、资产迁移及 AI 范围授权尚未完成。用户要求全部完成、自检后备份并安装已连接 iPhone，目前未安装。

## 网页账户
- 官方 Supabase SSR SDK，Apple REST `form_post` + ID token 验证与 Carry enroll，共用原生账户服务。原生 client assertion 不带 redirect_uri；网页仅使用运营配置中的精确回调，未配置映射拒绝启动，测试用真实 JOSE 校验 client assertion audience。
- SDK 会话采用 HttpOnly/Secure/Lax Cookie；十分钟认证 flow 独立 AES-GCM 加密，按 origin/purpose 绑定，只有 flow Cookie 使用 None 以接收跨站 POST。服务器不接收 P8/service role，不向页面输出 token。
- 同源表单 CSRF、随机 state/hashed nonce、已核对发起账户绑定、固定站内恢复目标、请求/响应/Cookie 大小限制、重复键拒绝、失败撤销和不缓存保护。
- 九语言页面；官方 Apple 按钮 2x/3x，按深浅色选择黑/白版。实际 Chromium 桌面及 320×812 深浅色截图检查；修复最初按钮低密度模糊及中文窄屏末尾孤字。截图 `/tmp/carry-web-login-zh-20261028-final.png`、`/tmp/carry-web-login-zh-{dark,light}-320-final.png`。不是 Safari/真机/VoiceOver 验收；调试外观/设备模拟已恢复。

### Review 修复
1. Apple 跨站 POST 不带 Lax 会话，回调里单独 getUser 无法可靠发现换账户。把发起时验证过的 account ID 绑定到加密 flow，新增缺少 Lax Cookie 的真实语义反例。
2. SDK 可能先更新 Cookie 再抛异常。异常路径也撤销新会话、丢弃其 Cookie；已验证旧会话的刷新 Cookie 保留，避免网络暂时失败丢失刷新令牌。
3. 身份请求的暂时网络错误不能当“已退出”，避免创建无账户绑定的登录流程。
4. SDK Cookie parser 已去重，解析后查重无效。改为先检查原始 Cookie 键，再由官方 parser 解析。
5. Apple 启动表单的 CSP 需允许 Apple 目标；仍限制其他来源。浏览器 DevTools 自身 appspecific 探测被 default-src 拒绝属于调试访问，不为清理控制台而放宽策略；浏览器扩展的 runtime.lastError 与产品分开记录。

### 最终两轮证据
- Node/实际 SSR SDK（网络合成）：**20/20 × 2**，`/tmp/carry-web-verified-round{1,2}.log`。
- 真实 workerd、同一 Wrangler bundle、禁止 Worker 所有出站 IO：**4/4 × 2**，`/tmp/carry-web-verified-workerd{1,2}.log`，覆盖渲染、加密 Cookie、精确 Apple 跳转、CSRF 拒绝。
- Wrangler dry-run 打包通过：`/tmp/carry-web-verified-build.log`。`npm install --ignore-scripts` 审计 0 vulnerabilities；版本和 lockfile 精确固定。
- 生命周期服务新增 web redirect 测试后 **48/48 × 2**：`/tmp/carry-account-web-redirect-round{1,2}.log`。提供者返回为合成；没有真实 Apple code exchange。
- 最初 Miniflare 5 新 API 参数校验失败，改用工具自带兼容适配器。随后 file-backed loader 内部错误在最小文件模块同样出现，而内存最小模块正常；QA 将同一已打包源码内存传入运行时后通过。日志 `/tmp/carry-web-workerd-round{1,2}.log` 及 `/tmp/carry-web-workerd-inline-round1.log` 保留，失败不计为通过。未修改产品验证或用 Node 测试冒充 workerd。

## 原生离线副本时序
- 移动意图单独持久化原版本；普通 pull 不能推进它。移动在途被用户撤回、晚 ACK/第三方移动、与字段 patch 并发时分别处理；只有匹配自己回执、已知父归属的变化能推进后续移动基线。
- 新 `resolveParent` 绑定被拒 request ID、服务端版本和用户看到的本地 parent；可采纳远端、保留本地或选择另一 parent。原 field resolver 也拒绝把已拉取的较新版本降回旧冲突快照。
- 创建请求 ACK 到达前，远端更新按未确认快照持久保留；ACK 绑定该创建后再合并。不能在游标已经推进后丢弃这些更新。覆盖重启、晚 ACK、后续本地字段意图及无本地改动两种情形。
- 多实体 native edit 在一次事务排队和投影；投影失败整个批次回滚。尚未接入 TripStore 所有真实业务入口，不能宣称完整本地命令层已完成。
- 两轮最终原生 **96/96**：`/tmp/CarryReplicaOrderingRound{1,2}.xcresult`；日志 `/tmp/carry-replica-ordering-round{1,2}.log`。包含真实 HTTP/PostgreSQL 的并发移动拒绝及显式解决后重试；旧 Relay 服务未选入。
- Release 构建 `/tmp/carry-replica-ordering-release.log` 成功，编译 warning/error 为零；deep/strict codesign 通过，入口保持关闭。模拟器缺 iCloud 身份的环境日志不能当作 CloudKit 验收。

## 继续实现
必须完成真实身份和同账户验证、可恢复账户删除、全业务命令/归属、Storage/完整资产迁移、新 OAuth/MCP 细粒度授权/确认/撤销、设备会话、生产恢复与设备/UI/网络验收后，才能统一交付和安装。Supabase 的 OAuth OIDC scope 不限制旅行数据；已部署全账户 API 继续拒绝 OAuth token，不为接通 AI 放宽权限。
