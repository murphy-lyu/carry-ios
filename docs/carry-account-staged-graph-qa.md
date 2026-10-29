# 大操作分块提交与分页回执验收
日期：2026-10-29。范围：账户协议组件；整体产品尚未完成。

## 实现与 Review
- 普通写入保持 500 项/2 MiB；大操作按有界块暂存，最多 40 块、20,000 项、数据库规范 JSON 16 MiB。每账户最多两份未完成暂存，过期一小时；每小时由私有调度清理。客户端无暂存表权限。
- 完整提交在同一数据库事务校验、写业务图并保存不可变回执。失败回滚业务写入并清理拒绝的暂存；丢响应重试复用原请求 ID 与内容摘要。
- 回执和拉取按条数与 4 MiB 字节分页。祖先事件只传元数据，保留每个连续序号；原生仅用可信同版本完整快照补齐。缺少基线时先拉取，不能用尚未上传的本地字段伪造远端状态。
- SwiftData 单独保存回执 offset；每页与进度一起落盘，完成全部 ACK 才释放在途命令。重开数据库恢复；首个 ACK 页后继续编辑也不会丢失。缓存冻结命令与 mutation 索引，避免逐页重复解码大请求。
- Review 去掉数据库循环中未使用的 JSON 数组拼接。托管函数 profile 实测发现普通字符串的布尔表达式触发时区目录 InitPlan：2,522 次字段校验占约 9.53 秒。改为时区字段专用 PL/pgSQL 分支，保留全部语义校验；同一 503 项回滚夹具约 10.63 秒降到 1.48 秒。
- 大事务单独使用 55 秒数据库、58 秒上游、60 秒原生截止时间；普通请求仍维持原超时。没有更改角色或全局超时。按 Supabase 官方函数级配置执行：https://supabase.com/docs/guides/database/postgres/timeouts 。20,000 项是协议上限，尚无该极限规模的托管性能验收。

## 证据
- 最终第一轮原生 120/120：`/tmp/carry-staged-final-native-r1.log`，`/tmp/CarryStagedFinalR1.xcresult`。包含 503 项、真实 URLSession/PGlite/SwiftData、首个回执页断线、数据库重开续传及元数据压缩检查；认证为合成夹具。
- 最终第一轮服务端 94/94：`/tmp/carry-staged-final-server-r1.log`。最终第二轮服务端 94/94、原生 120/120，日志 `/tmp/carry-staged-final-server-r2.log`、`/tmp/carry-staged-final-native-r2.log`，结果 `/tmp/CarryStagedFinalR2.xcresult`。
- 托管三次 503 项事务验证通过，全部 rollback；权限、分页连续序号、提交前无业务记录及提交后无暂存检查通过。脚本：`scripts/carry-account-service/hosted-graph-staging-smoke.sql`。真实 Apple/OAuth 身份不在此夹具范围内。
- carry-dev 追加四份迁移（共十八份），carry-data v5 ACTIVE、JWT 开启，部署 SHA256 `0a62a9c46f53c8df1a71bd1ff51c96bb2470007fe8778e678de49daf7a361915`。安全 Advisor 为十八项私有表默认拒绝策略的 INFO，无 WARN/ERROR。
- Deno 检查通过。Release/strict codesign/九语言检查已通过；最终原生截止时间变动后重新构建亦通过：`/tmp/carry-staged-final-release.log`；strict codesign 与九语言 0 errors/0 warnings 复核通过。匿名 Postman 请求返回 401：`/tmp/carry-staged-postman-unauthorized.log`。
- 保留失败记录：第一次误选不含 test action 的 Carry scheme；修正为 CarryAutomationTests。新测试曾把 sequence=2 的快照误写 subtreeVersion=1，夹具修正。增加大历史后，旧丢响应测试假定一次有界同步就能结束，改为沿用其 drain helper；未扩大生产单次处理循环来迁就测试。

## 未完成的产品门禁
原生全部业务保存/删除/恢复入口、原生完整投影、迁移归属与文件生命周期、网页登录同身份、新 OAuth/MCP、真实设备与双设备验收仍待完成。账户门禁保持关闭；本组件不构成最终交付，不安装此中间版本，不上传真实行程。
