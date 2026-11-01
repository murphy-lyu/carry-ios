# Native 日期精度与迁移比较修复（2026-11-01）
## 问题与处理
25 个纯合成可变精度日期均被 AI 与 PostgreSQL 接受，旧 native helper 拒绝其中 4 个 `.999999999` 边界值。旧 native 重编码把 `.9995` 四舍五入到下一秒，而 JavaScript 对输入文本的小数截取毫秒；`.123456789` 则重编码为 `.123`。问题来自在 Foundation 解析高精度浮点值后用整秒组件反推日历合法性，进位会让合法输入被拒绝。
`CarryBackupDates.parse` 现在先解析并校验原文整秒与时区，再从小数字符串截取前三位、补足毫秒后构造 Date。支持既有合法日期形态；2 月 30 日、24:00、秒 60、尾随文本等仍拒绝。输入 `.999999999` 得到 `.999`，不会跨秒、分钟或年份；与 JavaScript 输入语义一致。原生 Date 的编码仍稳定舍入到毫秒，防止二进制表示误差导致 `.123` 变成 `.122`；该编码步骤没有变化。
迁移 codec 恢复后，只有现有 schema 的 date-time 字段允许按毫秒瞬间比较：trip 的 departureDate/createdAt、photo 的 timestamp、attachment 的 addedAt、libraryItem 的 createdAt/updatedAt。字段集合必须完全一致，其他字段继续精确比较。普通名称即使长得像日期也不归一化；未知字段、非法日期和损坏资产仍拒绝。原 packet 的日期字符串、资产 SHA256、源文件和摘要不被重写。
## Baseline 与写回
projector 原来就保存重新捕获的本机 canonical source，同时单独保留 raw observed graph；journal 比较的是本机 source baseline。修复保留该分层，没有把云端 raw 日期替换成本机日期。旧 helper 的 21 个可解析样本 no-op 重编码均稳定，不能仅凭 raw/canonical 字符串不同断言会自动写回。新增真实 SwiftData 回归覆盖高精度投影、raw observed 完整保留、无修改 journal 0 条、后续只改 name 不带日期字段的桥接命令。
## 验证记录与边界
- 使用实际更新后的 helper，25 个边界向量均可解析，canonical 与 JS 的毫秒截取一致；涵盖普通秒、59 秒、跨年、+08:00 与不足 1ms。
- 从源码提取实际 codec 比较函数的纯 Swift harness，7/7 通过：高精度/时区语义等价、不同毫秒拒绝、非法日期拒绝、普通文字精确、未知字段拒绝、错误 kind 不能借日期字段放宽、library updatedAt 等价。
- 三个新增/更新 XCTest 文件语法 parse 通过；`git diff --check` 通过。
- 首次整 App `build-for-testing` 的 App 源码已编译；新增测试里的 key-path 在工具字符串传递时丢失转义导致测试编译失败，已改成显式闭包。该次构建不算通过。按 root 协调，编辑租约的多文件工作期间没有重复启动整 App 构建；正式 XCTest 结果由源码稳定后的统一 supervisor 两轮给出。
- 测试范围：BackupDateTests、NativeGraphProjectorTests、AccountGraphMigrationTests。新增回归验证 codec 还原后所有 date-time 字段、packet 编码字节与资产摘要不变、未知字段/非法日期拒绝。

本轮未操作界面、手机、云端、秘密配置或部署；未修改已经部署的 SQL 和 AI wire 范围，未提交。无需新服务或密钥。最终源码与测试交由 root 整合后完整验收。

## 主任务最终托管补验
上述“未部署”为子任务阶段边界。root随后将最新UTC年份闭包合并到AI及service全量测试，两轮分别各114/114和128/128，0失败/跳过；日志 `/tmp/carry-{ai,service}-year-closure-full-r{1,2}.log`。
已安装新的前向迁移 `20261101122423_graph_utc_year_closure.sql`，原严格日期迁移不变。托管只读核验：installed=true，两个UTC跨年越界均拒绝，合法9999年末高精度保留，非法存量日期0，anon/authenticated执行false、service_role=true。无数据改写。
AI独立ESM r8通过Deno check及无网络启用/关闭运行验证并已部署。本机产物SHA256 `1da5830ff230640d0abd8d77df522b1a4486cf4d90b83da2bbd5cf3206997ef8`；管理台重新下载的托管index.ts为2,618,828 bytes、SHA256 `e672ceee708be6a41de00002c1da08ca7d2dea92acb04cdea32eadd1f578ff1d`，仅比本机少一个末尾LF，其余字节完全一致。真实MCP preview_plan对年0001偏移越界返回invalid_field，未生成行程。最终native XCTest仍由编辑并发修复后的统一两轮给出，不能用本节云端证据代替。

## UTC 年份闭包补验与修复
仅追加检查两项：`0001-01-01T00:00:00+15:59`、`9999-12-31T23:59:59.999-15:59`。此前 AI、PG、native 首次均接受，但 native UTC 编码分别产生 year 0、year 10000，备份再次解码失败。现 AI、PG、native 都要求实际 UTC 年份为 1…9999，不扩展年份格式。PG 先把输入小数字符串截取至三位后再构造时间并判年，避免原生 PG 精度舍入把合法 `9999-12-31T23:59:59.999999999Z` 误判至 year 10000。原始存储字符串不变。
新的前向迁移为 `scripts/carry-account-service/supabase/migrations/20261101122423_graph_utc_year_closure.sql`，完整内容即可用于托管安装；已经部署的 `20261101111847_strict_graph_wire_dates.sql` 原文保持不变。基础 SQL 和 `graph-date-validation.sql` 同步。实际 helper 纯 Swift 检查确认两个非法 offset 跨年输入拒绝，UTC year 1 和 year 9999 高精度值均可 parse→encode→decode 稳定往返。`BackupDateTests` 加入相同案例。
最终定向 AI 两轮各 2/2、service 两轮各 2/2 通过；后者覆盖新 migration 原文一致、权限、基础函数、全部 migration 后实际 Graph 写入及错误后 0 行。日志 `/tmp/carry-year-closure-ai-r{1,2}.log`、`/tmp/carry-year-closure-service-r{1,2}.log`；Swift 源码/测试语法 parse 与 `git diff --check` 通过。源码已稳定，完整 native 验收仍交 root 统一执行。本任务未部署、未提交。
