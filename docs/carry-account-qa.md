# Carry 账户接入验收记录

日期：2026-10-26。结论：账户入口与身份接入代码已有本地测试；完整云账户/同步产品尚未交付，未合入主线、未部署账户服务、未发布 TestFlight。

## 本次范围

- 采用用户已确认的首页齿轮/头像、设置顶部横向账户卡片、原生 Apple 登录与独立账户页。
- 同一账户状态源处理 checking、signedIn、offline、temporarilyUnavailable、needsReauthentication；缓存身份不当作当前有效授权。
- Keychain 保存会话与首次姓名；nonce/state、重复回调与异步互斥；服务端确认 enrollment 后才发布登录成功。
- 使用官方 Supabase Swift Auth 2.55.5，依赖精确固定并提交 Package.resolved；SDK 隔离在账户服务适配层。
- Edge Function 及数据库生命周期代码已写入，但没有生产项目/真实服务验证；完整数据删除故意保持失败门禁。账户入口默认关闭，不替代现有设备执行器、不上传旧行程。

## 已发现并处理

| 问题 | 根因与修复 | 证据 |
|---|---|---|
| Keychain 集成测试全部失败 | 未签名模拟器构建无法正常使用 Keychain；改为签名测试构建，保留真实 Keychain 测试 | 最终签名回归通过，未将存储替换为永远成功的测试桩 |
| 服务错误后仍可能保留 verified 状态 | 失败默认分支未降级状态；增加 temporarilyUnavailable，保留身份但收回会话可用判断 | 状态机检查与原生回归 |
| enrollment 失败可在下次恢复时绕过 | 单独 Auth session 不代表 Carry 生命周期就绪；restore 再查询 enrollment 状态 | 真实 SDK + 注入网络测试拒绝失败/伪 200 |
| SDK 会吞掉部分持久化错误 | 读取官方实现确认；显式保存并读回 session，核对账户及 refresh token 后才成功 | Keychain 与 SDK 适配测试 |
| 自动刷新与退出可能竞争 | 使用统一账户操作锁；关闭 SDK 自动刷新，由账户状态恢复时触发必要刷新；先远程退出再清本机 | 并发状态测试、离线退出保留凭据测试 |
| 删除只清身份可能遗留业务数据 | 后端删除流程先持久标记，完整 purge 未实现时拒绝成功；不清原 iCloud 私人库 | PostgreSQL 门禁测试、依赖失败与调用顺序测试 |
| 账号标题可能显示本地化 key | 条件字符串不能依赖文字字面量的隐式本地化；改用显式 LocalizedStringKey | 代码审查、九语言审计 |
| 新 initializer 默认值有 actor 警告 | 在主 actor 的 convenience init 中读取 bundled 配置 | 后续构建无该警告 |

日志只记录固定事件和错误类别，不记录姓名、邮箱、Apple code、token 或行程正文。

## 两轮本地结果

两轮最终原生回归均为 **60/60**，无失败/跳过：账户状态 18、真实 SDK/Keychain 适配 4、原有业务自动化 37、模型导出 1。明确排除需启动独立 HTTP relay 的 RelayRoundTripTests；此次没有重跑真实 HTTP 或生产 relay，不计入 60 项。

两轮最终服务端测试均为 **21/21**，无失败/跳过：请求契约 12、真实 JOSE/AES 与适配器 8、PostgreSQL/PGlite 1。没有真实 Apple/Supabase 网络调用；不计作托管数据库或真实身份验收。

日志：`/tmp/carry-account-native-final-round1.log`、`/tmp/carry-account-native-final-round2.log`、`/tmp/carry-account-service-final-round1.log`、`/tmp/carry-account-service-final-round2.log`。早期 18/18、22/22、未签名失败等历史记录不冒充最终两轮。

九语言审计（主 App/Widget）0 errors、0 warnings。最终 Release 主 App/Widget 编译通过，编译日志无 warning/error（`/tmp/carry-account-release-final.log`）；这是关闭代码签名的构建，不能据此声称 Apple 登录 capability 或发布签名已通过。

## 尚未通过的门禁

1. **真实身份**：开通 Supabase 项目；Apple capability/profile、Services ID 与回调；真实原生/网页登录同一账户、不同用户隔离、服务器撤销通知与异常恢复。
2. **完整产品**：账户行程库、全业务命令/原生 outbox、冲突、资产备份迁移、完整账户删除、AI 权限与账户 API，用户确认范围后才可迁移真实数据。
3. **可视验收**：未完成截图/交互验收。当前工具不能选取 Simulator 应用；不以成功安装/启动或 XCTest 通过冒充页面已看过。真机也未覆盖安装本次账户版本。
4. **地区和运行**：国内无代理 Wi-Fi/蜂窝与境外真实请求、备份恢复演练、费用与监控。
5. **云端配置操作**：用户已经在应用内浏览器登录 Supabase；截图显示暂无组织。读取该页面时工具明确返回 `Local browser use is disabled in Work settings`，未尝试绕过此限制、创建组织或购买服务。

继续保留同一草稿分支与 PR，后续在同一交付链完成；上述本地结果不构成分批发布或完整交付声明。
