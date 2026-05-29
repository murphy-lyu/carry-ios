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
- TripReminderConfig：行程提醒配置
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
- NotificationManager：本地通知（行程提醒）
- DataBackupManager：数据备份
- CoffeeStore：StoreKit 内购（打赏功能）
- CarryShortcuts / AppIntents：Siri/Spotlight 快捷指令
  - create_trip：创建新行程
  - open_trip：打开指定行程
  - show_map：展示地球地图
- GlobeView：3D 地球视图（countries-110m.geojson）
- RoadmapView：产品路线图（支持远程 JSON 更新）
