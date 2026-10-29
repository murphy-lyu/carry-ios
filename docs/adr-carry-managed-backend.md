# ADR：Carry 长期托管方案与费用边界

日期：2026-10-26。状态：工程推荐；已创建免费开发项目并验证数据库隔离，未购买或部署生产服务。用户要求先满足长期产品与维护质量，再在合适方案中选择价格适中的方案。

## 背景

Carry 面向国内及全球；本地使用不需要账户，云端必须能在手机关闭时保存 AI 操作。旅行包含多层关系、附件、排序、批量修改和撤销。现有 SwiftData/CloudKit 不可与新服务对同一旅行双主写入。选型要同时评估开发与运维工作、故障恢复、地域访问、长期迁移和账单，不能仅比较免费额度或 GitHub 热度。

## 推荐

采用托管 PostgreSQL、成熟托管认证、受控业务 API 与独立本地副本。优先验证 Supabase 的数据库/Apple 认证/存储，沿用现有 Cloudflare MCP 入口；不预先另加一套身份供应商、数据库供应商和同步 SaaS。

Supabase 是当前首选供应商，未通过地区访问、真实身份、恢复与同步验证前不标记为生产选型验收通过。数据库、认证 SDK 与业务/UI 通过窄接口隔离；不为了可替换性自行重写 OAuth，不把 SDK 缓存会话等同于已验证身份。

## 对比

| 方案 | 产品适配 | 长期维护与取舍 | 判断 |
|---|---|---|---|
| Supabase 托管 PostgreSQL + Auth + Storage | 关系、事务、迁移脚本、导出适合旅行图；同一认证可用于原生与网页 | Swift SDK 可用，但不能直接提供 Carry 所需的离线合并、撤销与资产恢复；这些仍需开发和验收 | 优先验证 |
| Firebase Auth + Firestore | 原生移动 SDK 与离线缓存成熟 | Firestore 同文档离线修改默认最后写入获胜，不能直接满足 Carry 冲突约定；文档模型和按操作计费需要额外设计。Firebase 的其他 SQL 产品需另行评估，不能将整个 Firebase 等同于 Firestore | 可行备选；本项目当前不优先 |
| Cloudflare Workers + D1/DO/R2 + 外部认证 | 可复用既有设施，初期基础设施账单可低 | 仍要完成身份集成、业务事务、备份与恢复；若自行补齐身份服务，运维与安全维护工作增加。低账单不等于低维护成本 | 保留 Worker 入口，暂不把全部基础服务自研 |
| 自建 VPS PostgreSQL/整套 Supabase | 可控，数据库易取得 | 要承担升级、补丁、备份、监控、证书与故障值守；单机和本人有空与否会影响服务 | 当前不采用 |

## 费用（2026-10-26 官方价，美元）

- 开发验证可以先用 Supabase Free，不代表适合正式承载长期用户数据。Free 一周不活跃可能暂停，限制两个活跃项目。
- Supabase Pro 起价 **$25/月**，包含一个 Micro 项目的计算抵扣；第二个持续运行的 Micro 项目通常增加 **$10/月**。数据库/附件/流量/活跃用户等超额按官方价另计，不能承诺总价封顶。
- 如另需 Cloudflare Workers Paid，基础订阅为 **$5/月**；是否已有订阅、用量与计费范围需在账户中核对，不能重复计算或当成全部服务费用。
- 一个生产项目加 Worker Paid 的示例基础账单约 **$30/月**；再增加一个常开 Micro 测试项目约 **$40/月**。这是包含额度内的基础组合示例，不是购买授权，也未包含超额、税费、额外备份和可选服务。
- 不提前购买 Team、PITR、额外同步 SaaS 或更大计算规格；当恢复目标、用量或测试证明有必要时再评估。
- 不以几十个后续产品共用一个数据项目来隐藏成本。每个产品的身份、数据和故障范围需要隔离；项目增加应如实计入预算。实际是否拆分按产品与安全边界决定。

## 必须补齐的维护能力

1. **地域验证**：用真实认证、API 和附件链路，分别测国内无代理 Wi-Fi/蜂窝及境外网络；不是只测官网或经代理请求。记录成功率、延迟、刷新会话及故障恢复。未通过则调整地区或重新选供应商，不声称加一个自有域名就保证国内可用。
2. **离线与冲突**：本地业务修改和待同步请求在同一事务保存；服务端事务记录结果、幂等与游标；重放/乱序/断网/崩溃/同字段冲突均验收。不用 Realtime 订阅替代持久变更日志。
3. **完整恢复**：Pro 每日数据库备份保留 7 天，但不备份 Storage 对象本身；文件必须单独备份、核对摘要并做恢复演练。维护产品自己的导出格式，验证数据库迁移和账户身份迁移的工作，不能把“标准 PostgreSQL”描述成全服务无成本迁移。
4. **身份生命周期**：原生/网页登录同一账户、凭证撤销、刷新竞争、设备会话和 AI 授权分离、账户删除都须有真实端到端证据。
5. **可观测与费用**：记录无敏感正文的结构化错误、服务健康与限流；配置供应商支持的费用控制和告警，说明其覆盖范围，避免误称硬封顶。
6. **部署可复现**：schema/RLS/函数版本化；测试与生产凭据隔离；服务密钥不进入 App、日志和公开仓库。

## 当前实施顺序

账户状态、官方 Apple 登录、设置交互与测试按已确认方案实施，供应商相关代码集中在适配层。用户已创建组织并授权插件，独立 Free 开发项目已建立；报价 $0/月，未付费。Apple 配置和完整产品门禁就绪前，不发布无效登录入口，不用假会话冒充真实登录完成。开发库证据见 `carry-account-hosted-qa.md`。

## 官方依据

- [Supabase 价格](https://supabase.com/pricing)
- [Supabase 架构](https://supabase.com/docs/guides/getting-started/architecture)
- [Supabase Apple 登录](https://supabase.com/docs/guides/auth/social-sign-in/auth-apple?platform=swift)
- [Supabase 备份与文件边界](https://supabase.com/docs/guides/platform/backups)
- [Supabase 地区](https://supabase.com/docs/guides/platform/regions)
- [Firebase 价格](https://firebase.google.com/pricing)
- [Firestore 离线与冲突语义](https://firebase.google.com/docs/firestore/manage-data/enable-offline)
- [Cloudflare Workers 价格](https://developers.cloudflare.com/workers/platform/pricing/)

## 网页账户实现补充（2026-10-28）
浏览器同样使用 Supabase 官方 SSR SDK。Apple 采用 REST `form_post` 返回 code/id_token，由服务端 SDK 验证身份，再进入原生共用的 Carry enroll；专用 P8 在既有生命周期服务生成五分钟 client assertion。这样不需要在 Supabase 配置一个人工每六个月更换的长效网页 client secret。只登记已批准的 account 域名/精确回调；web audience 与 redirect 必须服务端配置绑定，不能接受调用者指定任意回调。

Cookie 会话与十分钟认证 flow 分离；flow 单独加密/绑定 state、nonce、发起账户和站内恢复目标。账户服务完成 enroll 前不发布 Cookie。名字为显示 metadata，不能作为授权。浏览器不持有 Apple 私钥或数据库 service key。

Supabase 当前 OAuth 自定义 scope 尚不支持，OIDC scopes 只控制身份字段，**不会限制旅行数据访问**。Carry 仍须实现私有授权表、逐客户端/行程/类别/动作的服务端校验与版本绑定确认，不能把 OAuth 成功或 email/profile scope 视为全账户权限。已部署全账户入口继续拒绝 OAuth token；不得为了接通 AI 放宽它。

实现与验证位置：`scripts/carry-account-web/`、`carry-account-web-qa.md`。网页/生命周期/授权未完成前维持关闭，不将本组件测试当成产品交付。
