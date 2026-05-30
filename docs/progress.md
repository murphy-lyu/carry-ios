# 项目进度

## 最后更新
2026-05-30

## 上次改动摘要（上架前质量收尾 · 2026-05-30）
- **埋点补全**：CarryLogger 新增 6 个 Event case（`coffeeSheetOpened` / `reminderScheduleFailed` / `sceneSelected` / `packingListShared` / `apiTimeout` / `apiError`），修复 `errorEvents` 集合引用未定义 case 的编译隐患；8 处此前已定义但从未调用的埋点补齐调用（`notificationTapped` / `siriShortcutExecuted` ×3 / `reminderScheduled` / `mapOpened` / `mapStyleChanged` / `coffeeSheetOpened` / `sceneSelected` / `packingListShared`）
- **App Store 合规审计**：确认 `NSLocationWhenInUseUsageDescription` 已配置于 Build Settings、Privacy Manifest 完整、消耗型 IAP 无需恢复购买；`release-checklist.md` 补充 3 条 App Store Connect 操作待办
- **日历设置解耦**：行程日历事件与出发前打包提醒拆分为两个独立开关；`CalendarManager.addTrip` / `addAllUpcoming` / `writeEvents` 新增 `includePackReminder` 参数；`TripStore` 透传 `calendar_pack_reminder_enabled` UserDefaults 键；`SettingsView` 新增子开关，时间 picker 联动两个开关
- **文案优化**：`settings.calendar.add_trips` 缩短为「Add Trips to Calendar」；`settings.calendar.packtime` 从重复说明改为「Reminder Time」；9 种语言同步

## 已上线功能（V1.0 完成）
- [x] 行程创建与管理（TripBundle）
- [x] 打包清单（PackingList）
- [x] 场景选择与智能推荐清单
- [x] 自定义分类
- [x] 物品数量
- [x] 物品与分类排序
- [x] 复制行程
- [x] "顺手考虑一下"功能
- [x] 3D 地球视图（GlobeView）
- [x] Mac Catalyst 支持（浮层卡片面板 + 地球背景 + macBody）
- [x] 多套 App Icon 切换
- [x] Siri/Spotlight 快捷指令（创建行程、打开行程、显示地图）
- [x] 行程提醒（本地通知）+ 点击通知自动跳转打包清单
- [x] 数据备份
- [x] 打赏（CoffeeStore / StoreKit）
- [x] 产品路线图页面（支持远程更新）
- [x] 本地化（Localizable.xcstrings，9 种语言全程维护）
- [x] 外观模式切换（深色/浅色/跟随系统）
- [x] 日历同步（CalendarManager / EventKit）
- [x] **Live Activity**（锁屏打包进度卡片 + 灵动岛，CarryWidget Extension）

## 待开发（V1.x 迭代方向）
1. [ ] 目的地实用信息 — UI 已完成，待开启 WeatherKit
   - ✅ 插头/电压卡片、货币+汇率卡片均已可用
   - ⚠️ 天气卡片：开发者账号注册后 → Xcode Signing & Capabilities 添加 WeatherKit → Developer Portal App ID 勾选 → 重新下载 Profile
2. [ ] 个人资料（性别等字段，提升推荐精准度）— spec 待写
3. [ ] 邮件 / 订单导入行程
4. [ ] 行程统计增强

## 进行中
- 无

## 已知问题 / 技术债
- Bottom Sheet 自动吸附链路（Home Sheet 容器）
  - 典型现象：快速下拉松手后，出现“先上弹/中弹再下落”或“半空先压缩高度再落下”。
  - 根因结论：手动跟随链路正常，问题来自自动吸附链路与手动链路不一致（双通道驱动 position/shape），导致时序竞争与末段突变。
  - 禁忌改法（明确避免）：
    - 在下落主动画开始阶段提前推进 `shapeProgress -> target`。
    - 为同一条直降路径同时启用多套驱动（例如主 animator + shape displayLink 竞争写入）。
    - 通过反复切换 A/B/C 方案做补丁式修复，而不先固定单一决策源。
  - 当前稳定原则：
    - 先固定单通道：自动吸附与手动链路使用同一套几何模型与状态收敛逻辑。
    - 把手下拉自动收起使用非反弹时序（当前为 `easeIn` 方向），优先保证单向下落与可控性。
    - 下落过程中不得提前触发明显高度压缩；shape 收敛应避免前置到半空阶段。
  - 回归检查清单（每次改动后必测）：
    - 快速短行程下拉松手：不得出现先上弹/中弹。
    - 下落中段：不得出现“先压缩到最矮再掉落”。
    - 左右边距、底部边距、圆角变化：避免只在最后一瞬集中变化。
    - 慢速全程跟手拖拽：视觉连续性需与自动吸附保持一致。

## 工作流配置
- [x] CLAUDE.md
- [x] docs/design-system.md
- [x] docs/architecture.md
- [x] docs/decisions.md
- [x] docs/progress.md
- [ ] specs/ 目录（按需创建）
