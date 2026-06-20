# Notification Center — 通知中心整体改造

Status: Implemented — 待实机验收（2026-06-20）。模拟器明暗双模已自验：设置中心 6 类分组、多档可增删、渐进展开均正常。
Owner: 行程提醒系统化

## 目标
把 Carry 所有「本地通知」统一收进 **设置 → 行程提醒**，做成一个按类型分组、可成长、Settings 为唯一真相源的中心。
用户一眼看清「Carry 会在什么时候提醒我什么」，每类是一条**全局规则、自动套到所有行程/事件**，默认值**可见可调可多条**，并允许**逐事件静音**。

## 现状（实现前的事实）
- 全部调度在 `NotificationManager`，**只有一种**：出发倒计时（出发当天/前 1/2/3 天/1/2 周，可设时间），由 `TripReminderConfig` 驱动、创建时快照进 `TripBundle.reminderConfigs`，per-trip 在 `TripReminderSheet`（行程 ··· 菜单）编辑。
- 文案写成「提醒你打包」，故「打包提醒」与「行程提醒」**本是同一套**。
- 日历同步（EventKit）写系统日历、提醒由系统发——独立通道，不归本中心。
- 经期提醒是 App 内加物品建议，**不发推送**。

## 锚点分类（架构骨架）
| 锚点 | 触发相对于 | 配置 |
|---|---|---|
| **A 出发日锚** | 出发前 N 天 | 全局档位（多条）+ 时间 |
| **B 事件时刻锚** | 某行程事件起始时刻前 X | 全局提前量（多条）+ 逐事件静音 |
| **C 行程日锚** | 每个行程日某时刻 | 全局开关 + 时间 |

## 通知类别（全部一次做）
| 类别 | 锚 | 档位/配置 | 默认 | 逐事件静音 |
|---|---|---|---|---|
| **出发提醒**（含打包催促） | A | 当天/前1/2/3天/1/2周（多选）+ 时间 | 当天+前1天，09:00 | — |
| **打包进度提醒** | A | 出发前 N 天，仅未打完才发「还剩 X 件」 | 关；前1天 | — |
| **交通出发提醒**（航班/火车/巴士/渡轮） | B | 提前量（多条，如 3h、1h）| 开；起飞前 3h | ✅ 逐段 |
| **租车取/还车提醒** | B | 提前量（多条）| **关**；前 1 天 | ✅ 逐段 |
| **住宿提醒**（入住/退房） | B | 入住/退房各提前量 | 关；入住当天 9:00、退房前 1 天 | ✅ 逐条 |
| **每日行程摘要** | C | 每个行程日某时刻推当天计划 | 关；08:00 | — |
| 航班实时动态 | B | 实时 | 远期（Pro，需推送基建） | — |

## 配置模型（统一）
- 每类别 = **一组档位/提前量**（可增删多条、可改值、Settings 明示每条的值）+ 总开关。
- 全部存全局（UserDefaults，扩展现 `ReminderPreferences` 为多类别）；**无 per-trip 快照**。
- A 类档位 = 「出发前天数」集合 + 触发时刻；B 类提前量 = 「事件前时长」集合；C 类 = 触发时刻。

## per-trip / per-event
- **删行程 ··· 菜单「行程提醒」** + `TripReminderSheet` / `ReminderPickerSheet` + per-trip 编辑函数（addReminder/removeReminder/updateReminderTime/setRemindersEnabled）。出发提醒全局驱动。
- **逐事件静音**：`TransportSegment`、`LodgingStay` 加可选 `remindersMuted: Bool`（默认 false=提醒）。在交通/住宿**详情或编辑页**放「不提醒此项」开关。调度时跳过 muted。

## 工程规则（实现必须遵守）
- **绝对时刻**：B 类把「行程出发日 + dayOrder + 当天分钟 + 事件时区」算成绝对 `Date` 再倒推提前量；trigger components 显式写 `timeZone`（沿用 C8 时区锁定）。
- **identifier 命名空间**：出发 `carry.trip.{id}.depart.{offset}`；打包进度 `…pack.{offset}`；交通 `…transport.{segId}.{leadMin}`；住宿 `…lodging.{stayId}.{in|out}.{leadMin}`；每日 `…daily.{dayOrder}`。互不串、可独立取消。
- **重排即重排**：交通/住宿/地点/天 任一变更、行程 create/restore/merge/duplicate、**改任一全局设置** → 全量 `cancel + reschedule` 受影响行程。改全局设置触发「重排所有行程」。
- **打包进度**：调度时按当前未打完数算 body；打包状态变化 / 全打完 → 重排或取消（打完不吵）。
- **跳过**：muted / 无时刻 / 事件或出发日已过 → 不排；同一档位同一事件只一条（去重）。
- **数据迁移**：新增可选 `remindersMuted` 走 versioned schema 轻量迁移；`DataBackupManager` 备份/还原带上（可选、向后兼容）；`duplicateTrip` 深拷贝带上。
- **文案**：每类型 9 语言齐，中文全角；租车用「取车/还车」、住宿用「入住/退房」口吻。
- **埋点闭环**：新增 `CarryLogger.Event`（如 `transportReminderScheduled`/`lodgingReminderScheduled`/`dailySummaryScheduled`/`reminderMutedToggled`）同次接线，错误类入 `errorEvents`。
- **点击跳转**：所有类别点开跳对应行程（沿用 `notificationTapped` + identifier 解析 tripId）。

## 设置 → 行程提醒 IA
```
出发提醒          [开]  出发前：☑当天 ☑前1天 ☐前2/3天 ☐1/2周    时间 09:00
打包进度提醒       [关]  出发前1天还没打完 → 提醒「还剩 N 件」
交通出发提醒       [开]  起飞前：· 3 小时  (+ 添加)              ← 明示档位、可加多条
租车取/还车提醒    [关]  前：· 1 天  (+ 添加)
住宿提醒          [关]  入住当天 09:00 / 退房前 1 天
每日行程摘要       [关]  每个行程日 08:00 推当天计划
```
+ 顶部沿用现有「通知权限横幅」（denied→去设置 / notDetermined→应用内授权）。
逐事件静音不在此页，在交通/住宿详情/编辑页就近放。

## 实现顺序（一个整体、分阶段编译验证）
1. 配置模型：扩 `ReminderPreferences` 为多类别 + 档位集合（含默认值）。
2. 调度引擎：重写 `NotificationManager`（A/B/C 三类 + 命名空间 + 取消 + 去重 + 时区 + muted/过期跳过）。
3. 数据 & 迁移：`TransportSegment`/`LodgingStay` 加 `remindersMuted` + schema + 备份 + duplicate。
4. Store 接线：所有交通/住宿/天/行程变更点 + 「改设置重排所有行程」漏斗；删 per-trip 编辑函数。
5. Settings 重构：分组中心 + 多档位可见可增删；删 `TripReminderSheet` 等 + ··· 菜单入口。
6. 逐事件静音 UI：交通/住宿详情/编辑页开关。
7. 文案 9 语言 + 埋点 + 通知点击跳转。
8. 编译 + 你实机验收。

## 远期
航班实时动态（延误/登机口/登机）—— 需 Worker 推送基建，单独立项。
