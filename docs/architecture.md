# Carry 架构说明

## 整体结构

### iOS
SplashView（启动过渡）
└─► ContentView（TabView）
    ├─► Tab 0：NavigationStack → HomeView
    │   └─► navigationDestination
    │       ├─► UUID → PackingListView（直接打开行程）
    │       └─► CreationRoute → 创建流程
    │           ├─► tripInfo → TripInfoView（行程基本信息）
    │           ├─► itemPicker → ItemPickerView（选物品）
    │           ├─► scenePicker → ScenePickerView（选场景）
    │           ├─► packingList → PackingListView（新建完成）
    │           └─► editScenes → ScenePickerView（编辑场景）
    └─► Tab 1：NavigationStack → SettingsView

### Mac Catalyst
ContentView 在 `#if targetEnvironment(macCatalyst)` 下使用 `macLayout`（独立属性，同样用条件编译包裹）：

```
ZStack（全窗口）
├─► MacGlobePanel（Globe/MacGlobePanel.swift）— .ignoresSafeArea()，铺满背景
└─► NavigationStack（宽 360pt，浮层卡片样式）→ HomeView.macBody
    └─► navigationDestination（同 iOS）
```

- **MacGlobePanel**：3D 地球，点亮到访国家，与 iOS 的 GlobeView 独立实现
- **HomeView.macBody**：Mac 专用 body，使用 `List + .scrollContentBackground(.hidden)`，不包含 globe 背景、底部 sheet 容器、stagger reveal 动画；`onAppear` 时直接设 `initialRevealProgress = 1.0`
- **Settings**：通过 toolbar 按钮 `showSettingsOnMac` 打开 sheet，不使用 Tab Bar
- **导航**：统一走 `NavigationRouter`，与 iOS 共用同一套 `CreationRoute`

## 核心数据模型
- TripBundle：行程容器（包含 PackingList、TripInfo 等）
- MyItem：用户自定义物品
- PackingList：打包清单
- Scene / SceneItemMap：场景与物品映射（智能推荐基础）
- ItemCatalog：物品目录（预置数据）
- TripReminderConfig：行程提醒配置（含 `presets` 档位、`localizedLabel`）
- ReminderPreferences（UserDefaults）：全局默认提醒偏好（已开启档位 + 默认时间）。新建行程时**快照**进该行程的 reminderConfigData（非实时联动）；设置「通知」二级页（NotificationSettingsView）编辑
- SurpriseItemMap："顺手考虑一下"功能的物品映射

## 状态管理
- TripStore（@StateObject，全局）：行程数据的读写、refresh
- NavigationRouter（@StateObject，全局）：导航路径管理
- AppearanceMode（@AppStorage）：外观模式（system/light/dark）

## 持久化
- SwiftData，versioned schema（CarrySchema.swift）
- MigrationPlan（CarryMigrationPlan）保障升级安全
- ModelContainer 初始化失败时 fallback 到 in-memory store

## 其他模块
- CarryLogger：单例日志，记录关键生命周期事件和 DB 错误
- NotificationManager：本地通知（行程提醒）；`tripId(fromIdentifier:)` 从通知 ID 解析行程 UUID
- PackReminderNotificationDelegate：`UNUserNotificationCenterDelegate`，点击打包提醒后解析 tripId 写入 `NavigationRouter.pendingTripId`，实现自动跳转
- DataBackupManager：数据备份
- CoffeeStore：StoreKit 内购（打赏功能）
- CarryShortcuts / AppIntents：Siri/Spotlight 快捷指令
  - create_trip：创建新行程
  - open_trip：打开指定行程
  - show_map：展示地球地图
- GlobeView：3D 地球视图（MapKit Annotation pin 点亮到访国家，不绘制多边形边界）
- RoadmapView：产品路线图（支持远程 JSON 更新）
- LiveActivityManager：`@MainActor` 单例，管理打包进度 Live Activity 生命周期（start / update / end / endIfDeparted）

## 政策合规（中国大陆上架）
> 完整约定见 CLAUDE.md「政策合规约定」章节，此处仅记模块归属。
- `isChinaStorefront`（`SceneItemMap.swift` 顶层函数）：通过 `SKPaymentQueue` storefront 检测是否大陆区，Debug 可用 UserDefaults 覆盖。所有大陆差异化行为的唯一判断入口
- `HomeView.normalizedCountryCode(_:)`：仅大陆 storefront 下将 HK/MO/TW 归并为 CN（仅展示层，存储层保持 ISO 原值）
- `generatePackingSections(destinationCodes:)`：大陆 storefront 下按目的地推荐港澳通行证 / 台湾通行证替代护照
- `TripStore.inferCountryCodes` / `inferIsInternational`：geocoding 异步完成前用本地城市表同步推断国家码，避免证件误推

## Widget Extension（CarryWidgetExtension）
- 独立 target，bundle ID `com.murphy.carry.CarryWidget`
- `CarryWidgetBundle`：注册 `CarryWidgetLiveActivity`（Live Activity 配置）
- `CarryWidgetLiveActivity`：锁屏卡片（LockScreenView）+ 灵动岛（展开/紧凑/最小态）
- `CarryWidget/Localizable.xcstrings`：widget 专属本地化（9 种语言）

## SharedSources
- `SharedSources/PackingActivityAttributes.swift`：ActivityKit 共享类型，通过 pbxproj 同时编译进 Carry 和 CarryWidgetExtension 两个 target
- `ActivityAttributes`：只含 `tripId`（静态标识符）
- `ContentState`：packedItems / totalItems / isCompleted / tripName / destinationCity / departureDate（全部动态，支持实时更新）
