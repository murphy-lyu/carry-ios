# Carry AI 连接与注册运维
本轮基线：2026-11-03，开发环境 carry-dev。正式发布开关仍关闭。此文区分已实现的保护、实际测量与待部署验证；不把开发测试参数当作正式套餐。

## 保护与诊断
- Access 15分钟、refresh 30天，OAuth grant另有自己的期限。未使用注册24小时、用过注册退役至少90天；这些不是同一个“失效时间”。每次轮换仍单次使用，旧refresh重放会提交整个grant撤销，不能用错误scope绕过。
- 令牌端点对过期、撤销、停用客户端或不可用账户统一返回400 invalid_grant；MCP资源接口继续401 invalid_token。数据库故障503，限流429；429和注册容量不足503带Retry-After:60，禁止客户端无间隔循环重试。
- 生产连接池每实例最多2条，建连/借用5秒、单条客户端查询20秒；数据库statement 15秒、lock 5秒。连接5分钟轮换、空闲30秒释放、启用TCP keepalive。空闲socket错误被固定标签吸收，不把provider消息或连接串写日志。
- 私有诊断只存UTC日、固定类别、计数，保留14天，批量清理有界。refresh_ok/replay/missing/invalid/scope/unavailable和端点成功/拒绝/限流/不可用分别计数；二者不可混加作请求总量。指标采集失败不改变OAuth决策；写指标的SQL/锁等待分别限1秒/250毫秒。
- “刷新已提交但响应丢失”会使客户端仍持有旧令牌，再重试触发重放保护。实际PostgreSQL故障注入已证明此路径，不自动把它认作攻击，也不放开旧令牌重复使用。先核对聚合故障/重放趋势，再让受影响连接按原范围重新授权；不同进程不得共享同一个可写refresh凭据文件。

## 注册生命周期
容量保持1024条/16MiB元数据，首次usedAt预留40字节；原有记录与legacy记录仍计费。达到容量时在同一注册锁下最多回收32条已经满足条件的记录，重新核算；仍不足明确拒绝新注册，已授权读取/刷新不受注册门禁影响。
- 从未使用：v1标记、注册至少24小时，且无authorization/code/grant引用。
- 曾经使用：v1标记、createdAt/usedAt以及最后grant结束或撤销至少90天，且无authorization/code引用、有效未撤销grant、未过期access或refresh。spent refresh同样保护。未知grant/token到期时间保守保留；无版本legacy不自动回收。
- 回收只删除client元数据，旧grant、业务图、文件、receipt/request身份不删。回收和注册、待确认创建、后台维护使用同一registry advisory锁。
- 不按应用名称/redirect内容自动把新的DCR请求复用成旧client；这些公开字段不足以标识同一次安装。后续正式静态客户端注册可另行评估，不能把新连接隐式继承为旧授权。
- 15分钟自然清理仍是唯一job。部署的新函数由原job调用，不增设公开维护接口或携带新清理密钥的HTTP任务。

## 健康核对与告警
只读SQL：`scripts/carry-account-ai/operations-health.sql`。私有function `carry_ai.operations_snapshot(now_ms)`输出聚合容量、首次授权耗时分桶、有效grant/refresh与spent证据数、近14天事件，不输出账户、邮箱、IP、client ID、令牌或行程。
已有授权的数据库运维环境可执行Node24脚本 `scripts/carry-account-ai/operations-check.mjs`，连接串只通过环境变量CARRY_AI_DATABASE_URL传入，不在命令行参数或聊天中发送。脚本只读、输出固定聚合JSON：退出0=健康，1=需查看，2=无法核对；不发送外部通知或自动改限额/撤销授权。
起始阈值：容量75% warning、90% critical；清理停用或45分钟无自然成功critical；过去一天有清理失败warning；近期出现refresh_replay、OAuth服务不可用至少5次、至少20次token请求中拒绝率≥20%时warning。阈值需按真实量校准，不能根据目前开发账户承诺长期容量。
外部告警接收渠道尚未设置。只读SQL/脚本和判定逻辑已准备，不把它们称为已经24小时在线的外部值守服务。托管平台自身的可用性/账单告警须按选定生产套餐和通知渠道接入。

## 处置顺序
1. 先区分HTTP：429稍后重试；503核对数据库/网络/池及自然清理；400 invalid_grant重新授权；资源401可先正常refresh。不要把查询超时、模型不可用或UI工具故障统称“认证失效”。
2. 旧CLI故障缺少当时完整证据，仍不能定根因。本轮修正错误语义、连接超时和空闲错误处理，并完成实际多连接/多进程与响应丢失测试；不回填历史故障为已证明的重放。
3. 容量临界先看未用/已用/legacy占比、授权耗时、自然维护。不要批量清有效客户端或调到无限；业务增长超过开发池时先评估成本、合适容量与正式客户端复用。
4. 不需要用户管理临时注册或逐次确认自动清理；运维部署前对新增不可恢复回收范围按工具规则当次确认。

## 部署与回退
先应用`20261103144256_ai_connection_operations.sql`（新private表/函数/index、替换维护例程），再部署完整carry-ai产物，保持原Secrets和verify_jwt=false；无新公开诊断/授权范围。用schema/function定义摘要、角色权限、自然cron与聚合读回验证，不能只看Deploying或旧实例200。
迁移和服务端均须记录具体部署版本。普通用户已安装App无需新包才能使用服务端修复。回退服务端产物可用上一版r8；数据迁移不自动回滚。若需停用新的曾用client回收，应部署上一版维护例程并停止DCR的压力回收新入口，不应删除指标、恢复已回收client或改真实grant。保留旧有效令牌与重放证据。

## 规范依据
- OAuth令牌错误：[RFC6749 §5.2](https://www.rfc-editor.org/rfc/rfc6749#section-5.2)
- 轮换及重放：[RFC9700 §4.14](https://www.rfc-editor.org/rfc/rfc9700#section-4.14)
- 连接池/客户端超时：[node-postgres Pool](https://node-postgres.com/apis/pool)、[Client](https://node-postgres.com/apis/client)
