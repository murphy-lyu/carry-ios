# Carry AI 连接稳定性与运维补验
日期：2026-11-03。工作树Carry-codex-integration；不合main、不开放正式Release、不发TestFlight。当前真实账户因用户测试删除而被独立紧急任务暂停，不能用该账户鉴权失败判断本轮OAuth修复失败，也不恢复旧授权来凑测试。

## 根因与修复
1. 已复现OAuth错误契约缺陷：过期/撤销grant、disabled client或不可用account在令牌端点抛401 invalid_token。新增失败回归先真实失败（`/tmp/carry-oauth-error-before-20261103.log`），修正授权码兑换/refresh为400 invalid_grant，资源接口继续401。四种状态及HTTP无Bearer challenge回归通过。不是旧CLI具体失效根因的追认。
2. 连接池没有建连上限/空闲error监听，网络异常可能长时间等待或以未处理事件结束实例。增加5秒建连、20秒client query、30秒idle、5分钟lifetime、TCP keepalive；仍max2且严格TLS。实际TCP黑洞模拟在约5秒转503，未伪称invalid_grant。SQL statement15秒/lock5秒仍保留。
3. 用过的DCR元数据原永久积累。新私有回收：v1、至少90天未活动/授权结束、无authorization/code引用、无有效未撤销grant、无任何未过期access/refresh（包括spent）；未知expiry保留。旧无version保留。未用24小时规则延续。容量不足时最多回收32条已经符合条件者再核算，仍满则503+Retry-After，不扩大额度、不动有效连接/业务图/文件/请求身份。注册/维护/待确认创建共享同一registry锁。
4. 私有聚合事件仅day/event/count，固定类别、14天有界清理；metrics写失败不改变OAuth结果。只读snapshot、health SQL和CLI区分容量、自然cron、拒绝/重放/服务错误。没有外部告警收件渠道，不冒称全天值守已上线。

## 实测证据
- PostgreSQL 17.11独立本机QA实例，仅127.0.0.1:55483、独立临时数据库；没有启动开机服务，也不修改用户Mac/iPhone网络。
- 独立连接同refresh竞争只成功一次，重放撤销实际提交；两个独立OS子进程同样验证。12个注册竞争最多插入到设定上限，维护与有效refresh竞争不误回收。
- 在真实COMMIT成功后注入客户端响应丢失：新token已落盘；旧refresh重试按安全设计撤销family。不能用本项证明历史CLI曾发生此路径，亦不放宽重放保护。
- 首次完整回归的强制DROP DATABASE清理触发仍在关闭的idle连接FATAL/未处理error；已改普通DROP并等待pool退出、夹具接收idle错误。无数据库deadlock证据。随后最终完整两轮：AI各129/129（含真实PG四项，0跳过）；账户服务各128/128；网页登录各24/24。权限/生命周期追加定向9/9，anon/authenticated执行新private函数被拒绝。
- 最终两轮日志：`/tmp/carry-operations-delivery-r{1,2}-20261103.log`、`/tmp/carry-service-operations-final-r{1,2}-20261103.log`、`/tmp/carry-web-operations-final-r{1,2}-20261103.log`。早期容量fixture缺createdAt导致store_unavailable已调整为缺可信时间时不尝试回收，保留正常容量拒绝。
- 已添加最小权限CI：固定commit的官方checkout/setup-node，Node24、隔离PostgreSQL17、三套锁定依赖/测试，无生产Secrets、无部署权限。首次GitHub运行另行记录；本机解析通过不等于CI已跑。

## 云端只读基线与待部署
Supabase CLI未认证；既有Chrome登录可用，独立新SQL页执行只读聚合，不复用紧急删除暂停页。
真实读回：9个client、1721 bytes元数据、1个used client、超过90天client=0、8个未撤销且期限未到grant、唯一active retention job；最近自然成功2026-11-03 15:00:00.104206+00。这些grant数量不代表deleting账户仍可读写，账户guard仍独立阻断。
新migration `20261103144256_ai_connection_operations.sql` 和完整carry-ai产物已准备；尚未部署，本轮新增90天曾用client回收需浏览器工具当次确认，已发出具体范围确认。无新密钥、不改现有授权scope。许可未到前不执行新清理或覆盖云端。
部署后还需：函数/角色/索引摘要读回、snapshot事件与自然cron成功、实际新产物版本核验。当前用户账户恢复另有Provider外部删除结束证明与本人fresh Apple验证前置，不能通过重新放开旧session验证MCP。

## 保留限制
- 旧CLI最初失效证据不足，无法追溯定因。本轮完成兼容性修正与可复现竞争/故障验证；聚合诊断用于后续定位，不宣称能凭无ID计数关联到某个人的单次失败。
- 1024/16MiB、24小时/90天和75%/90%告警是起始策略；需要真实使用量校准。读回开发9条记录不足以证明大规模生产容量。
- 正式外部告警渠道/账单套餐、真实生产SLA、iPhone12硬件trace仍未完成。本轮未购买任何服务。
- 手册：`docs/carry-ai-operations-runbook.md`。研究Tripsy、吸顶UI、误触删除止损在用户要求的独立任务；账户UI优化在独立工作树，未混入后端变更。
