# Carry 开发环境部署与实体机验收

日期：2026-11-01。承接 `carry-migration-ai-local-qa-2026-10-31.md` 的本地交付。用户已恢复 Apple Developer / Supabase 登录并连接 iPhone；本次仅推进既有 carry-dev 开发环境与已授权的实体机验收，不发布 TestFlight 或合并主线。

## 已验证

- Apple Developer 当前登录 Bing Xue，Team `25RAM7275Z`；iPhone 已配对、开发者模式已启用。浏览器扩展读取超时后改用 Chrome 原生界面核对，未更改浏览器权限。
- 部署前开发库的 auth 用户、graph 账户、业务实体和文件均为 0；既有 SQL 函数定义及六个已部署函数源码已在本机受限文件中留存。
- 五份已审核迁移实际部署为 `20261101041523`、`20261101041526`、`20261101041529`、`20261101041532`、`20261101041536`，云端历史共24份。本地仅对齐文件版本名，SQL正文未改；未重写云端既有历史。
- `carry-data` v5与当前源码一致，无需重发；`carry-assets` v3、`carry-cleanup` v3、`carry-account` v2、`carry-account-status` v2、`carry-maintenance` v2 已发布。原有 JWT 配置保持原样。
- 云端结构/ACK/删除批次/重放检查两轮通过；文件预留/清理账本及权限检查两轮通过，合成写入均回滚。HTTP私有表/原生RPC拒绝检查两轮各6项通过。新增函数均为 SECURITY INVOKER，anon/authenticated 不可执行，service_role 可执行。Security Advisor 无 ERROR/WARN；20项 INFO 为私有表启用RLS且不向客户端提供策略的预期默认拒绝。
- 经本次明确授权，Supabase Apple provider及生命周期服务加入 `app.nevestudio.carry.web`，原生ID保留；回调仍仅为 `https://account.nevestudio.app/auth/apple/callback`。桥接、origin、上游代理token等八项服务端配置逐项校验SHA256。既有Apple私钥及长期凭据AES key未轮换。
- `carry-account-web-dev` 已绑定 `account.nevestudio.app`；网页登录仅针对 carry-dev 开发验收启用，新AI网页入口仍关闭。`GET /login`实际返回200、Apple按钮及表单存在，Secure/HttpOnly/SameSite Cookie、no-store及CSP均存在。`wrangler.toml` 的 `acceptance` 环境记录实际配置，默认环境仍关闭且无路由。网站只保存自身flow key、桥接key和publishable key，不保存数据库或Apple私钥。
- `carry-ai` v2 已部署到 Supabase，使用实际导入映射和完整机场/打包目录。开发环境显式开启；真实元数据读取200、合成OAuth客户端注册201，实际TLS数据库连接与service_role事务通过。该次唯一合成client已精确清理。`connect.nevestudio.app` 仍属于旧relay，尚未切到新AI服务；不能把Supabase直连检查称为Codex已连通。
- 手机原Carry完整数据容器已备份到本机独立受限目录：43个文件、31,197,855字节，SHA256清单已保存，4个SQLite数据库quick_check均为ok。备份不会上传到Git或云端。
- 新实体机Debug验收包编译通过，Swift告警/错误0、strict codesign通过，Bing Xue团队、原Bundle ID、CloudKit Development；仅此验收产物开启账户入口，源Secrets和正式Release门禁仍为false。已安装并启动原Carry，现有13趟行程正常显示，设置顶部登录入口与Apple系统授权页已截图核对。系统显示使用用户自己的Apple ID，并需要本人设备密码/Face ID，尚未将调起授权等同于登录完成。

## 联调发现与修复

- 首次真实AI请求404：Supabase内部函数路径为 `/carry-ai/*`，本地原入口只处理外部 `/functions/v1/carry-ai/*`。新增独立路由适配，同时接受两个精确挂载点；拒绝相似前缀和无关路径，保留请求体、查询和认证头。增加3项回归；实际部署后不再返回错误404。
- 数据库连接优先使用专用 `CARRY_AI_DATABASE_URL`，缺省使用平台服务端 `SUPABASE_DB_URL`，始终验证TLS证书、连接上限2，并在事务内切换service_role。不向网站复制数据库凭据。
- 初次网站检查503：部署时flow key采用带padding的普通Base64，实际codec要求无padding Base64URL。改为同一32字节密钥的Base64URL表示后返回200，没有通过放宽codec解决配置错误；以后部署必须使用Base64URL。
- Review同时修正网站隐私链接缺少Carry产品路径的问题，统一指向法务站既有 `/carry/privacy/`。法务站独立HTTP探针本次TLS握手超时，不算页面可达验收。
- 首次Deno检查的npx环境找不到Node运行时lib目录，未算通过；改用本机已缓存的Deno实际二进制后check通过。

## 本次回归证据

| 检查 | 结果 | 本机证据 |
|---|---|---|
| AI完整回归两轮 | 各99/99，含3项新路由测试 | `/tmp/carry-ai-hosted-router-20261101-r1.log`、`r2.log` |
| 服务完整回归 | 117/117，使用对齐后的迁移文件 | `/tmp/carry-service-hosted-migrations-20261101.log` |
| 网站回归 | 23/23 | `/tmp/carry-web-hosted-config-regression-20261101.log` |
| AI实际权限边界 | 元数据200、无效MCP bearer401、缺少第一方proof403 | `/tmp/carry-ai-hosted-http-20261101.json` |
| Deno实际入口check | 通过 | `/tmp/carry-ai-hosted-deno-20261101.log` |
| 实体机编译/安装/启动 | 通过，未替换Bundle ID或切换手机iCloud | `/tmp/carry-device-acceptance-{build,install,launch}-20261101.log` |
| HTTP权限拒绝两轮 | 各6项 | `/tmp/carry-hosted-http-20261101-r{1,2}.log` |
| 网站实际页面与安全头 | 200 | `/tmp/carry-web-login-20261101.{html,headers}`，文件含短期flow凭据，仅本机0600 |

上一轮原生336/336两轮与Release/i18n证据仍见本地QA文档；本次原生源码未修改，不声称重新执行336项或已通过完整真机验收。

## 仍需完成

本节为首轮部署时快照。后续真实登录及用户主动删除已确认，邮箱显示与删除流程修复见 `carry-account-email-deletion-qa-2026-11-01.md`；重新登录及原生/网页同身份仍需验收。

1. 用户本人完成手机Apple授权，读回真实身份登记；网页登录使用同一Apple身份，核对账户一致。
2. 新AI的公共域名切换与第一方桥接/Codex OAuth全链路；旧relay尚未替换，网站AI入口未开。高德Web服务凭据仍未配置，不能把境内AI地点查询称为线上可用。
3. 用明确选择的合成行程做实体机同步、文件、撤销、离线与迁移验收；涉及真实旧行程时另列范围并确认，不自动上传。真实Storage版本/Range与双设备仍要实测。
4. 真机完整视觉/无障碍、iPhone12性能、最终回退/删除演练与正式入口发布。未合并主线、未发布App Store/TestFlight。
