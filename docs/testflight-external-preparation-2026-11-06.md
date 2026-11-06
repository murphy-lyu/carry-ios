# 外部 TestFlight 发布准备与真机安装（2026-11-06）
## 版本与源码
- 基础功能源码 `c8e297050f3d12722231ba92a849691ba7cafcad`，已 push 至 `codex/header-device-integration` 和 `codex/testflight-friends`。包含已验收的日期单行/不透明吸顶修复、原生编辑弹窗实际生命周期释放编辑锁修复。
- 版本 `1.0 (4)`。App 与 Widget 的 Debug/Release 构建号统一为 4；已产出的归档和真机包均以同值构建，版本配置调整不改变功能代码。
- 发布工作树隔离；未合并 main。发布包的忽略配置明确开启账户和 AI，不提交配置内容或密钥。
## 构建与测试
- AI 131 项通过；首次全套中跳过的 4 项真实 PostgreSQL 并发测试另行补跑，4/4 通过。
- 账户服务 140 项通过；首次全套中跳过的 2 项真实 PostgreSQL 恢复竞争测试另行补跑，2/2 通过。
- 账户网页 24/24 通过。所有真实 PostgreSQL 回归使用本机隔离合成数据库，不接触托管用户数据。
- Release archive/export 均成功。分发 IPA 为 31,996,412 bytes，SHA256 `4ac9cde46bac40928ac6ff68364e9c9ac64da8489fe853d96aac69f5fa86d6b7`。App/Widget 严格签名校验通过，build 4、beta-reports-active=true、get-task-allow=false；App CloudKit=Production。
- 手机开发包 Debug 构建成功，账户/AI 开启，保持既有 Development CloudKit 环境。App 数据容器及共享容器均已备份；原位安装成功并启动成功。功能交互验收由用户进行，不把启动成功写成完整验收。
## 已部署的账户/AI 更新
- 用户本次明确批准新增过期客户端注册记录的永久回收范围后，应用 `20261103144256_ai_connection_operations.sql`，部署完整 carry-ai 第 9 版，ACTIVE；保持原服务密钥、verify_jwt=false 和既有授权边界。
- 产物 SHA256 `64214c8072f017b9b171ea832cc9669ef73c5b556bf27a78140b33933bddc43d`；平台部署包 SHA256 `bd97ec7ee9710347f4ce581fc04e68ebe32302fff6e10491b014ea8759a90edf`。两者分别对应源码文件和平台打包产物，不混作同一摘要。
- MCP 迁移工具初始登记版本 `20261106142903`；成功部署后，使用单事务、版本不存在和受影响行数检查，将唯一登记记录对齐到仓库版本 `20261103144256`，SQL 内容不变。最终历史读回已确认。
- 四个函数的 prosrc MD5 与已审核迁移完全一致；均 SECURITY INVOKER，anon/authenticated 无 EXECUTE，service_role 有 EXECUTE。
- 唯一 AI retention cron 仍为每 15 分钟；14:30 UTC 自然成功，晚于更新部署；过去一小时无失败。新诊断表已有真实请求聚合事件，不记录行程、账户标识、IP 或令牌。
- 回退维护函数定义已保存；旧 r8 来源基线 `701e353` 重建回退产物已留存。旧产物下载接口不可用，重建产物不冒充线上旧文件的逐字节副本。
## 分发边界
- 用户明确朋友属于外部测试者；不添加 App Store Connect 后台权限，不启用公开邀请链接，不自动给已有外部组所有人发邀请。
- 账户文件预算当前每账户 150 MiB、最多 3 个 pending、项目预分配池 450 MiB；已分配 150 MiB，尚可接纳两个完整新账户预算。本次不改变容量或购买服务。
- TestFlight 测试说明及审核备注已保存，说明可选 Apple 登录、显式本地迁移、账户同步和第一方 AI 预览批准流程；未提供个人 Apple 凭据。
- 22:33（上海时间）Xcode 明确返回 Upload succeeded / Uploaded Carry，安装包已上传，Apple 开始处理构建。尚未提交外部审核，未发出邀请；后台处理结果继续读回。归档、导出、上传、处理、提交审核、审核通过、发出邀请与用户验收是不同状态。
## 证据
本机 `/tmp/carry-testflight-20261106/` 保存 archive/export/upload 日志、分发验证 JSON、服务端测试日志、服务部署产物与 SHA、手机备份/安装/启动记录。备份目录限制本机访问，不提交真实数据。

## 部署后复核
- Supabase security advisor 无新增 WARN/ERROR；新私有聚合表出现与既有默认拒绝表一致的 RLS 无策略 INFO。既有密码泄漏检测 WARN 不涉及本版新增内容；账户使用 Apple 登录。
- 未认证 MCP 实际返回 401；OAuth discovery 的本机重试出现间歇 TLS 超时，初始准备阶段曾返回 200。本轮不把网络失败计作接口通过，后续仍需重新核对。
