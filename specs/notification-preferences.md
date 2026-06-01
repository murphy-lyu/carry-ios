# Notification Preferences（通知中枢 + 用户自定义默认提醒）

> **Status: Implemented（已实现，待真机验收）** — 2026-06-02 完整实现并通过 simulator build。两步一次做完：① 默认软化（`TripReminderConfig.defaults` → 仅「出发前1天」）② 设置「通知」二级页 + 全局偏好 + 创建时快照 + 备份字段。
>
> **一句话**：把"新行程默认提醒"从对所有用户硬编码的 `[提前3天 + 出发当天]`，改为用户在设置「通知」二级页里自定义的习惯（档位开关，默认只开"出发前1天"）；创建行程时把该默认**快照**进行程，单行程后续在物品清单里继续独立微调。设置页结构可生长，为 Carry 转向行程规划 App 后的更多通知场景（航班/协作等）预留中枢。
>
> **来源**：PM 提出现有硬编码默认太强硬；参考 Tripsy「通知」设置（一般旅行提醒 / 航班提醒 / 协作 三组开关）。

## 动机

现状（代码）：
- 提醒规则 `TripReminderConfig { daysBeforeDeparture, hour, minute }`（0 = 出发当天）。
- `TripReminderConfig.defaults = [提前3天@9, 出发当天@7]` —— **对所有用户硬编码**。
- 机制：新行程 `TripBundle.reminderConfigData` 为空时，getter **回退**到 `defaults`。即"默认"是 getter fallback，非创建时写入。
- `TripReminderConfig.options = [出发当天, 前1/2/3天, 前1周, 前2周]` —— 选项现成。
- 每个行程 `reminderConfigData` 独立存储，互不影响（per-trip 隔离已成立）。

问题：对所有人套同一套强默认（提前3天+当天）不尊重个体出行习惯；且把"默认提醒规则"的管理隐含在物品清单的 `TripReminderSheet` 里，**作为行程规划 App 不可扩展**——未来航班/酒店/协作等通知场景需要一个集中管理处。

## 核心设计原则

1. **全局默认 = 创建时快照，而非实时联动**（关键）。设置里的默认档位，仅在**新建行程那一刻**拷贝进该行程的 `reminderConfigData`。之后用户改设置，**不影响任何已建行程**；单行程在 `TripReminderSheet` 的微调也只动自己。
   - 好处：① 完全保留 Carry 独有的"逐行程提醒"能力；② **不动存量行程**——老用户已排程的通知不会因本次改动被悄悄改变（若改 getter fallback 或做实时联动，则老行程通知会被动变更，体验糟，且涉及重排通知）。
2. **设置页可生长**。二级页按"分组 + 开关"组织（参考 Tripsy）。首版只做「一般旅行提醒」组（打包提醒档位）；预留未来「航班」「协作」等组的加入位置，结构不变。
3. **克制默认**。开箱默认只开「出发前1天」，其余档位留给用户按需开启。允许全部关闭（= 新行程默认无提醒，合法选择）。
4. **不照搬 Tripsy 的纯全局模型**。Tripsy 无 per-trip 提醒，其设置全局实时生效；Carry 是"全局默认（快照）+ 逐行程覆盖"。

## 信息架构（IA）

- 入口：在设置「**提醒与显示 / Reminders & Display**」分区内新增一行 **「通知」**（结构化 key 如 `settings.notifications.entry`）。
  - 分区内建议顺序：通知 → 日历 → 灵动岛 → 小部件 → 经期。
  - 备注：分区名含"提醒"、行名"通知"，中文近义略重叠，可接受；待未来通知场景增多，再评估把「通知」提为独立一级分区。
- 二级页 `NotificationSettingsView`（新建），首版分组：
  - **一般旅行提醒**（首版唯一组）：对应 `TripReminderConfig.options` 的档位开关——出发当天 / 前1天 / 前2天 / 前3天 / 前1周 / 前2周。默认仅"前1天"开。
  - （占位，未来）航班提醒 / 协作 —— 本版不做，仅在 spec 记录生长方向。
- 文案口吻参考 Tripsy 的人话风格（如「出发当天」可考虑更暖表述），但保持 Carry 克制；复杂项（未来航班类）开关下加一行说明。

## 数据模型

- **新增全局偏好 = 已开启档位的集合**（不存时间）。`@AppStorage`/`UserDefaults` 存一组 `daysBeforeDeparture` 值（如 JSON `[1]`）。
  - 默认值 = `[1]`（仅"出发前1天"）。
- **时间不另设、不自定义**（已定）：每个档位的提醒时间**直接取 `TripReminderConfig.options` 里该档位既有的时间**（出发当天 7:00 / 其余 9:00），与物品清单 `TripReminderSheet` 现用的一致。设置页**不出现时间选择**。
  - 即：创建行程时，快照 = `options` 中 `daysBeforeDeparture` 落在"已开启集合"内的那些条目（连带其固有时间）。
- **不改 `TripBundle` schema**：仍用现有 `reminderConfigData`。仅改"创建时如何填充它"。

## 实现要点

1. **创建流程**：在 `ItemPickerView.confirmSelection()`（`.create` 分支构造 `TripBundle` 处）把全局默认档位**写入** `bundle.reminderConfigData`（而非留空）。
   - ⚠️ 一旦创建时显式写入，`reminderConfigData` 不再为空，getter 的 `defaults` fallback 对新行程不再触发——这正是我们要的。
2. **getter fallback 处理**：`TripBundle.reminderConfigData` 为空时的 fallback（当前 → `defaults`）。为保护存量行程**保持现状或谨慎处理**：存量老行程多为空 → 仍回退老 `defaults`，**不要**改成读全局偏好（否则老行程通知被动变更）。新行程因创建时已写入，不走 fallback。
3. **设置页**：`NotificationSettingsView` 读/写全局偏好；开关切换即存。空集合（全关）合法。
4. **NotificationManager 不变**：仍按 `trip.reminderConfigs` 调度、跳过已过 `fireDate`。
5. **本地化**：新页所有文案 + 入口名 × 9 语言（含显式 en）；中文全角标点（见 CLAUDE.md 新规）。

## 边界 / 陷阱

- **存量行程**：绝不能因改默认而改变已建行程的已排程通知。靠"创建时快照 + 不动 fallback"保证。
- **无日期「规划中」行程**：无 `departureDate` → 本就不排提醒（已有 guard）。补日期转正时按现有逻辑处理；默认档位是否在"转正"时套用需明确（建议：转正沿用创建时快照的 config，不重新套全局）。
- **全部关闭**：新行程 `reminderConfigData` = 空数组（注意与"从未设置"的空 Data 区分！空数组 = 用户明确要 0 提醒；空 Data = 未初始化走 fallback）。需在编码/解码层区分这两者，否则"全关"会被误当成"用默认"。**这是最易埋 bug 的点。**
- **备份/还原**：per-trip config 已随备份走；全局偏好是否纳入备份——建议纳入（小字段），否则换机后默认丢失。待定。
- **埋点**：档位开关变更、默认被套用等可评估加 `CarryLogger.Event`（遵守"定义即接线"闭环）。

## 分阶段

| 阶段 | 内容 | 风险 |
|---|---|---|
| **上线前（可选，1 行）** | 把 `TripReminderConfig.defaults` 从 `[提前3天@9, 出发当天@7]` 软化为 `[出发前1天@9]`，立即不那么强硬 | 极低（仅影响"创建后未设提醒"的新行程默认值） |
| **上线后** | 完整功能：`NotificationSettingsView` + 全局偏好 + 创建时快照 + 空数组/空Data 区分 + 9 语言 | 中（重点测存量行程不受影响、全关场景） |

## 已确认决策（2026-06-02）

1. ✅ **时间不另设、不自定义**：每档位直接取 `TripReminderConfig.options` 既有时间（出发当天 7:00 / 其余 9:00），与物品清单一致；设置页无时间选择。精调仍靠 per-trip `TripReminderSheet`。
2. ✅ **默认仅开「出发前1天」**。
3. ✅ **全局偏好纳入备份**（`DataBackupManager` 增一个字段；缺省时按默认 `[1]`，兼容旧备份）。
4. ✅ **档位标签用更暖口吻**（参考 Tripsy：如「您的旅行今天开始」「出发前 1 天」等）；9 语言均按此口吻，非直译。
5. ✅ **入口放「提醒与显示」分区内**（不另开一级分区；未来通知场景增多再评估提升）。
