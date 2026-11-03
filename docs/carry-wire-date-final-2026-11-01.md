# 账户日期契约修复（2026-11-01）
## 已证实问题
纯合成检查分别调用实际 AI `compilePlan`、最新 PostgreSQL `graph_validate_value` 和当前 native `CarryBackupDates.parse`：`2026-11-01T24:00:00Z` 在 AI 和数据库均通过，native 拒绝，会导致写入云端后无法投影。数据库还把秒 60 归一化为下一分钟；AI 则接受 2 月 30 日、缺秒或缺时区，但这些已被数据库挡住。极端 `+23:59` 偏移原来抛出未捕获的 SQL `22009`。本轮只使用本机合成数据，无云端坏数据写入。
## 修改
AI 日期校验使用整串 RFC3339 形态，显式检查 Gregorian 年/月/日、闰年、小时 00–23、分秒 00–59，以及数据库此前支持的带冒号偏移范围（小时 00–15、分钟 00–59）。拒绝日期归一化、部分日期、缺时区及尾随文本。数据库验证函数在原有整串形态和真实日期解析前增加时分秒检查，并把 `invalid_time_zone_displacement_value` 转为 false。
有效的 UTC 整秒、可变精度小数、带冒号的正负时区偏移、闰日均保持原字符串，不做重写。24:00 属于 ISO8601 的扩展表达，未包含在当前 RFC3339 wire 格式内。native 的兼容解析范围保持原样；服务端此前拒绝的 compact offset 和极端偏移没有新增支持。秒 60 按 native 既有能力拒绝。本次不涉及新的日期、时区或日历功能。
`graph-date-validation.sql` 是当前完整 validator 的可执行规范源，保留现有 object/array 递归、时区目录和字符串等全部校验；`graph-transactions.sql` 的基础版本同步日期规则。CLI 生成 `20261101111847_strict_graph_wire_dates.sql` 作为前向替换迁移，旧迁移不改。迁移只替换验证函数并保留客户端执行拒绝/service_role 执行，不扫描、删除或改写现有数据。若原来已有非法日期记录，其后续编辑需要一并修正日期；本任务未擅自处理存量记录。
## 验证与 Review
定向 AI 2/2、service 2/2 已通过，分别覆盖完整计划编译入口、基础 SQL 与替换迁移、各类日期返回 false 而非 SQL 异常、执行权限，以及应用全部 migration 后真实 Graph 写入。所有无效日期写入均拒绝，graph_entities 保持 0 行；随后有效日期均可创建。Review 检查了完整消费字符串、非闰世纪年/四百年闰年、时区偏移边界、事务失败后的数据状态，以及最新 validator 的非日期分支和权限没有丢失。
全量 AI 两轮各 114/114、service 两轮各 128/128，均无失败、跳过；`git diff --check` 通过。日志前缀 `/tmp/carry-ai-date-full-r{1,2}.log`、`/tmp/carry-service-date-full-r{1,2}.log`。
## 部署
已在 carry-dev 安装 `20261101111847_strict_graph_wire_dates.sql`，随后部署包含 `domain.mjs` 的 carry-ai 独立 ESM。两个步骤均需部署，单独收严 AI 无法覆盖 native 直接账户 API。该后端校验修改本身不要求重新安装手机。Git 提交与合并状态以分支当前状态为准。

托管只读核验：installed=true、anon_execute=false、user_execute=false、service_execute=true；invalid_existing_dates=0；24:00、2月30日、秒60、极端偏移均返回false，毫秒日期返回true。没有修改或删除现有行程数据。

部署产物 `/tmp/carry-ai-index-20261101-r7.txt`（同内容 `.mjs`）SHA256 `ced05611cb7a968c7131bc0b45c4ddaa27f0ea13f8472f2dce90f0eb4378259f`。Deno check、禁止网络的启用初始化及关闭503均通过。控制台部署对话框未及时结束，未重复提交；实际当前对话 MCP 对 `2026-11-01T24:00:00Z` 返回 `invalid_field`，正常合成创建随后成功，证明线上新 AI 校验路径已生效。未将页面等待状态当成部署成功证据。

另用 `preview_plan` 输入2月30日，实际返回invalid_field；该路径在编译计划时拒绝，尚未进入Graph写入，排除了只由新数据库validator拒绝的混淆。r6产物不含wireDateValid、r7包含该函数；不能只用apply_changes的同名错误区分两层验证。

随后刷新控制台，index.ts无M、部署按钮恢复。Functions列表部署次数7；通过管理台Download as ZIP只读下载实际托管index.ts，2,618,693 bytes，SHA256 `b53ab67d78cf3fd4d897a3fcc04406109bd633e8e3c815591a366ba8755def4b`。字节比对确认与本机r7仅差一个末尾换行（本机文件=托管文件+LF），其余完全一致；包含wireDateValid与刷新scope校验。由产物读回和实际preview拒绝共同确认部署，不依赖卡住的页面状态。

后续发现高精度输入及UTC年份闭包边界，已进一步修复并部署新的前向迁移与AI r8；上述r7为阶段记录，最新部署、产物摘要及验证见 `docs/carry-date-precision-final-2026-11-01.md`。保留可变小数输入形态，实际精度按JS毫秒截取；UTC瞬间必须仍能用既有年份范围往返。

部署后可只读核对存量日期和权限（仅返回计数/布尔值，不返回行程内容）：
```sql
select count(*) as invalid_date_field_count
from carry_private.graph_entities e
cross join lateral jsonb_each(e.fields) f
where carry_private.graph_schema()->e.kind->'fields'->f.key->>'format'='date-time'
 and not carry_private.graph_validate_value(f.value,carry_private.graph_schema()->e.kind->'fields'->f.key);
select exists(select 1 from supabase_migrations.schema_migrations where version='20261101111847') as migration_installed,
 has_function_privilege('anon','carry_private.graph_validate_value(jsonb,jsonb)','execute') as anon_can_validate,
 has_function_privilege('authenticated','carry_private.graph_validate_value(jsonb,jsonb)','execute') as authenticated_can_validate,
 has_function_privilege('service_role','carry_private.graph_validate_value(jsonb,jsonb)','execute') as service_can_validate;
```
