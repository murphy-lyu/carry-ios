# 抹掉所有数据（本地一键重置）

Status: In Progress（2026-06-21 立项 + 实现）
关联：`itinerary-cost-tracking.md`（费用快照）、`itinerary-attachments.md`（附件文件）、`notification-budget.md`（通知调度）

## 背景与定位

Carry **本地优先、无账号、零服务器存储**——这本身已满足 GDPR/PIPL 数据主体权利的实质（访问/更正=端上直接编辑；可携带=已有备份导出；删除=删行程/删 App）。**因此不做** Flighty 那种「Account Data / 删除账户」模块（Carry 无账号、无服务器数据可删，做了反而误导）。

本功能是**可选的体验增强**（非合规硬性要求）：在设置里提供「抹掉所有数据」一键入口，让用户**不必删 App** 就能把本机数据清空，并让「被遗忘权」**显性可见**（监管与用户都偏好看到这种入口）。语义 = 「等同删 App 重装的内容部分」。

## 范围（抹什么 / 不抹什么）

**抹除（用户的「数据/内容」+ 其所有副作用存储）——必须覆盖全部，漏一处即留孤儿：**
1. **SwiftData**：全部 `TripBundle`（级联 days/stops/segments/lodging/attachments/sections/items）+ 全部 `MyItem`（自定义物品库）。
2. **沙盒文件**：背景图（`BackgroundImageStore`）、附件字节（`AttachmentStore`）——`deleteOrphans(keeping: [])` 全删。
3. **挂起通知**：所有 `carry.trip.*` 本地通知（新增 `NotificationManager.cancelAll()`）。
4. **系统日历事件**：Carry 写入的全部事件（新增 `CalendarManager.removeAllCarryEvents()`，删整个 Carry 日历更稳，含孤儿）。
5. **Live Activity**：`LiveActivityManager.endAll()`。
6. **本地备份文件**：`DataBackupManager.clearBackup()`——否则「抹除后下次 restore 又回来」，与「被遗忘」矛盾。
7. **Widget 快照**：抹除后 `writeWidgetSnapshot()` 刷成空。

**不抹（App 配置 / 偏好，非「个人数据」）：** 外观模式、单位、App 图标、通知默认时间/档位、各 opt-in 开关（经期/日历同步等权限态由系统管）。理由：这些是 App 配置不是用户内容；重置它们对「只想清空行程」的用户是惊扰而非帮助。confirm 文案明确「抹除全部行程与打包数据」，不含「设置」，避免误解。

## 交互与视觉

- **位置**：一级菜单只留单行入口「数据与恢复」（归「管理」分区）→ 进二级页 `dataManagementPage`（导出/导入/本地备份/抹掉所有数据）。低频 + 破坏性操作不裸露在一级（尤其抹除）。抹除行**独立成卡、置于二级页底部**，措辞克制不恐吓。
- **样式**：一行**红色（破坏性）文字按钮**（非整块红卡，避免页面焦虑感）；图标 `trash`，遵循 design-system 的 destructive token、明暗双模。
- **二次确认**：`confirmationDialog`（iOS 原生 action sheet）destructive 按钮 + 取消；标题点明「不可恢复」、副文案列出将抹除的内容。**不做「输入文字确认」**（对纯本地、无账号的内容重置过重；原生 destructive 确认足够，且与 Carry 克制气质一致）。
- **执行后**：触觉反馈 + 回到空状态首页（`trips` 已空，首页自然显空态）。无需 toast（空首页即结果）。
- **撤销窗口（防后悔缓冲）**：确认后**不立即删**，延迟 `eraseUndoWindow`（=9 秒）；底部吐司带**倒计时环 + 递减秒数**（`TimelineView` 帧驱动按真实流逝时间算，不靠 withAnimation，确定可靠；环不显 0，归零=删除=吐司退场）+「撤销」（品牌强调色逃生口）。9 秒内点撤销则取消（数据本就还没删）。窗口时长是单一常量 `eraseUndoWindow`，同时驱动延迟删除与环耗尽，避免双时长漂移。
- **离开页面即中止（关键安全语义）**：撤销逃生口绑在二级页；若任由全局 Task 在后台跑完，会「撤销没了、删除照常」两头落空。故 `dataManagementPage.onDisappear`（返回 / 关设置）即 `cancelPendingEraseOnLeave()` 取消待执行抹除——**离开 = 中止，一律朝「不删」方向**。用户已过 alert 强确认，真要删再来一次即可。

## 实现要点

- 单一入口 `TripStore.eraseAllData()`（`@MainActor`）：按「先副作用、后 SwiftData、最后刷新」顺序执行，每步独立 try/容错（某步失败不阻断整体，记日志）。
- 顺序：取所有 trip id/文件名快照 → 取消通知 → endAll Live Activity → 删日历事件（若曾启用）→ 删沙盒文件（背景/附件 deleteOrphans 空集）→ `context.delete` 全部 trip+myItem → `save()` → `clearBackup()` → `fetchTrips()`（空）→ `writeWidgetSnapshot()`。
- 埋点：新增 `CarryLogger.Event.allDataErased`，在 `eraseAllData` 成功末尾调用（埋点闭环）。
- 文案 9 语言齐、中文全角。

## 决策与非目标

- **不做删除账户 / 服务器 DSAR**：无账号、无服务器数据（架构层已「不收集」）。Apple 5.1.1(v) 仅约束「支持注册」的 App，不触发。
- **不重置偏好设置**：见范围「不抹」。
- **不做输入确认/冷静期**：纯本地内容重置，原生 destructive 二次确认即足够。
- **备份文件一并清除**：保证「被遗忘」彻底；用户若想留存应先用「导出」。confirm 文案提示「可先导出」。

## 验证

- 编译绿（主 app + Widget）。
- 建含交通/住宿/附件/背景图/已写日历/已排通知的行程 → 抹除 → 确认：SwiftData 空、沙盒无残留文件、无挂起 `carry.trip.*` 通知、Carry 日历事件清空、备份文件消失、首页空态、Widget 空。
