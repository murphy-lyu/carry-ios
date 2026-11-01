# AI 与原生日期互操作修复验收

日期：2026-11-01。子任务仅操作本地代码、合成数据及只读脱敏诊断；未操作界面、真实设备、Keychain、浏览器 Cookie 或生产行程。

## 结论与根因

AI 账户操作成功后，原生同步在模型投影阶段失败。AI 默认日期由 JavaScript `toISOString()` 生成，包含毫秒；原生投影器原先使用默认 `ISO8601DateFormatter`，无法解析这些日期。纯合成 Foundation 验证确认无毫秒可解析，`.000Z` 无法解析。

本地固定码日志仅报告 `workspace_sync/native_projection`，没有 Graph HTTP 或令牌获取失败。只读数据库一致快照确认 AI 测试行程已进入 replica，3 条记录等待投影；其中两个日期字段均带小数秒。仅输出计数、结构有效性及存在布尔值，没有输出记录、字段值或身份信息。

主任务随后报告：真实 Mac 原 Carry 首页已出现 AI 创建并改名的合成行程。该结果来自主任务实际界面验收，本子任务没有直接操作或观察界面。

## 修改范围

- `CarryBackupDates.swift`：统一日期 parse、规范化 string、JSON encoder/decoder。兼容旧整秒、毫秒及合法时区偏移；检查完整输入与日历组件，拒绝不存在的日期、非法偏移和尾随文本，不填入当前时间。
- `CarryNativeGraphProjector.swift`、`CarryNativeEntitySource.swift`：共用同一解析和编码规则。保留旧整秒表示；有小数时按 JavaScript 精度四舍五入到三位毫秒，避免 AI → 原生 → capture 截秒。
- `DataBackupManager.swift`：三个生产备份输出点统一使用新 encoder，不改备份版本或数据结构。
- `CarryAccountConflictReview.swift`：日期复核展示复用同一 parser。
- `CarryAccountWorkspace.swift`、`CarryGraphTransport.swift`：保留主任务授权的本地白名单诊断，仅含固定阶段/动作/错误类别、HTTP 数字状态和 URLError 数字码。不记录 description、URL、请求/响应内容、令牌、邮箱或行程。

Foundation fractional FormatStyle 对二进制表示的 `.123` 曾输出 `.122`。规范化输出显式取整毫秒并生成 UTC 后缀，避免该截断；高于毫秒的精度按最近毫秒规范化，最大量化误差为半毫秒。整秒仍输出原来的无小数格式。

## 回归与 Review

新增六个有业务意义的 XCTest 用例：

1. 完整 AI `create_trip` 必填默认字段与 day 经 replica → 原生 → capture → journal → bridge；保留 `.123` 时间与默认字段，重复投影无变更，显式改名后 wire mutation 只有 name。
2. 旧整秒、无小数偏移和有小数偏移日期保持同一时间值，整秒 capture 保持旧表示。
3. 非法 AI 日期拒绝整轮投影，既有模型、持久化图和工作 context 不受污染。
4. 真实生产 `makeExportFile → restoreFromData` 保留创建/出发日期毫秒且不新增虚假 journal transaction。
5. 冲突日期复核对新旧日期显示相同的可读日期。
6. 毫秒跨秒/跨日进位、负 epoch、普通整秒及非法输入边界。

原有同 UUID 备份恢复测试仍使用非整秒日期，改用生产 encoder，保留“行程只修改 name”的断言，没有通过固定整秒或放宽预期绕过失败。首轮暴露的备份截秒已在生产路径修复。新增 receipt 测试夹具初版 subtreeVersion 与 sequence 不符，已按协议修正，未改 replica 校验规则。

## 已通过的证据

- 日期主路径定向两轮：每轮 49/49、零失败。结果 `/tmp/CarryUnifiedDateR1-20261101.xcresult`、`/tmp/CarryUnifiedDateR2-20261101.xcresult`。
- 加入进位/负 epoch/非法日历边界后两轮：每轮 50/50、零失败。结果 `/tmp/CarryUnifiedDateFinalR1-20261101.xcresult`、`/tmp/CarryUnifiedDateFinalR2-20261101.xcresult`；对应日志 `/tmp/carry-unified-date-final-r1-20261101.log`、`/tmp/carry-unified-date-final-r2-20261101.log`。
- 最终该轮构建 `/tmp/carry-unified-date-final-build-20261101.log` 成功，无编译 warning/error；所有修改文件 `git diff --check` 通过。
- 最后 Review 将正则结束锚点换为绝对结束 `\z`，并给 XCTest 的非法输入列表追加尾随换行。这一微调发生在上述 binary 构建之后；最终 helper 原始源码另经 Swift 直接执行，10 个进位/解析往返断言、5 个非法输入拒绝断言均通过，脚本 `/tmp/carry-date-helper-final-smoke.swift`。不将上述 50 项结果冒称为已运行了最后新增的换行断言。

## 交接状态

源码已稳定，未提交代码。专用 8981 合成夹具已停止，两个最终测试进程均正常完成，没有需要终止的 xcodebuild/runner，也未重置或擦除模拟器。最后精确源码的全量两轮构建/测试、Mac 与 iPhone 验收及安装由主任务执行；本报告不把本地 XCTest 当作真机同步证据。

## 迁移安全备份追加核对

全项目只读核对进一步发现迁移链路三个文件仍使用旧整秒 encoder，已在主任务明确授权后统一：`CarryGraphMigrationCodec` 的对象 encoder 和 packet.createdAt 重建、`CarryMigrationBackupPreparation` 的 source.json、`CarryAccountTripMigration` 的 encoded helper。文件格式和版本不变。新增完整 migration packet → restore 毫秒精度回归，以及实际 source.json 在非整秒保真、整秒与旧 encoder 逐字节相同的回归；迁移测试读取生产数据时使用生产 decoder/encoder，保留原断言。

持久化 digest 核对：计划、graph digest 和 asset manifest 编码的结构没有直接 Date 属性，日期字段已经是协议字符串，因此 encoder 切换不会改变已存字符串或已有 digest。安全备份文件仍按保存的原始字节 SHA256 校验，未重新编码或改写旧文件。源快照 fingerprint 使用原生字段；若旧源原有小数秒被过去的整秒编码掩盖，新 capture 更精确可能触发已有 sourceChanged 检查，这时停在复核流程，不覆写已存 fingerprint 或强制继续。旧整秒 source.json 的字节相等回归保证原本整秒资料不受影响。没有读取或改写用户真实迁移数据。

追加迁移回归记录：`/tmp/carry-migration-date-build-20261101.log` 精确当前源码构建通过、零 warning/error；R1 19/19 通过（`/tmp/CarryMigrationDateR1-20261101.xcresult`）。R2 执行 19 项，18 通过、1 个真实 HTTP 迁移用例因 loopback 8891 夹具未运行而连接拒绝（URLError -1004），没有日期或业务断言失败，不计作第二轮通过。选定范围原本排除了 cost HTTP 用例，但遗漏同类 migration HTTP 用例，按证据如实记录，不改生产逻辑。未启动新服务、未占用端口；runner 和所属 xcodebuild 已释放，后续精确全量两轮由主任务独立新 QA 环境执行。主任务已报告其 R1 359 passed、0 failed、1 manual skip、0 runtime warnings，最终 R2 结果由主任务报告。本子任务不据此提前声称总体验收完成。
