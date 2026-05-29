# Calendar Sync

> **Status: Shipped ✅**（2026-05 上线，decisions.md 中有对应决策记录）

## 功能定位

轻量级"一键加入"，不做双向同步。
行程加入日历后，修改行程不会更新日历事件；关闭开关不会删除已有日历事件。

## 入口

Settings → General 区块，现有 Language 行下方新增两行：

1. 开关行：`settings.calendar.toggle`（"Add trips to Calendar"）/ `settings.calendar.subtitle`（"Upcoming trips are added automatically"）
2. 时间选择行（仅开关开启时显示）：`settings.calendar.packtime`（"Pack reminder time"），值为用户选择的时间，默认 20:00，使用 DatePicker `.hourAndMinute` 模式

## 权限

首次打开开关时申请 EventKit 权限（`EKEventStore.requestFullAccessToEvents`）。

| 结果 | 行为 |
|------|------|
| 同意 | 继续，弹"加入现有行程"确认 |
| 拒绝 / 受限 | 开关自动关回，弹 Alert 引导去系统设置开启 |

## 创建的日历事件

每次"加入"一个行程，创建两个事件：

| 事件 | 标题 | 类型 | 时间 |
|------|------|------|------|
| 行程事件 | `trip.name` | 全天，持续 `trip.days` 天 | 出发日 |
| 打包提醒 | `calendar.event.pack.title`（"Pack for %@"） | 用户设定时间（默认 20:00），时长 30 分钟，带弹出 alarm | 出发前 1 天 |

行程事件 notes = `destinationCity` + `dateRange`（可选，若字段不为空）

## 触发时机

1. **新建行程**：若开关开启，`commitDraftTrip` 完成后自动调用
2. **开关首次开启**：弹确认 Alert，询问是否把所有未来行程一次性加入

## 重复加入防护

`UserDefaults` 存 `calendarAddedTripIds: Set<String>`（tripId.uuidString）。
每次加入前检查，已在集合中则跳过。关闭再打开开关不会重复加入。

## 不在此版本范围内

- 修改行程 → 更新日历事件（需持久化 `EKEvent.eventIdentifier`）
- 删除行程 → 删除日历事件
- 过去的行程（`departureDate < today`）

## 本地化 keys

| Key | en |
|-----|----|
| `settings.calendar.toggle` | Add trips to Calendar |
| `settings.calendar.subtitle` | Upcoming trips are added automatically |
| `settings.calendar.permission.denied.title` | Calendar Access Required |
| `settings.calendar.permission.denied.message` | Please enable Calendar access in Settings to use this feature |
| `settings.calendar.bulk.title` | Add Upcoming Trips? |
| `settings.calendar.bulk.message` | %d upcoming trips will be added to your calendar. |
| `settings.calendar.bulk.confirm` | Add |
| `settings.calendar.packtime` | Pack reminder time |
| `calendar.event.pack.title` | Pack for %@ |

## 新增文件

- `Carry/Managers/CalendarManager.swift` — EventKit 封装，负责权限申请和事件写入
