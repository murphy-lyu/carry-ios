# Carry 架构说明

## 整体结构

### iOS（2026-06-12 起：根级不再是 TabView，见 `specs/app-navigation-framework.md`，feature 分支未合并）
SplashView（启动过渡）
└─► ContentView → **单个 NavigationStack → HomeView**（根=行程首页，足迹地球 + UIKit Sheet）
    ├─► HomeView hero 右上 gear → **SettingsView（sheet 呈现，非 tab）**；右下 FAB → 创建
    └─► navigationDestination
        ├─► UUID → PackingListView（行程详情，**两张脸**）
        └─► CreationRoute → 创建流程（tripInfo / itemPicker / scenePicker / packingList(isNewTrip) / editScenes）

**行程详情（PackingListView）两张脸**——底部悬浮胶囊切换「行程 ｜ 打包」：
- **打包**：`packingContent`（正常态走 `ReorderableItemCollection` 拖拽重排）。
- **行程规划**：`ItineraryView`（地图头 + `ItineraryReorderCollection` 按天时间轴，停靠点可**跨天拖拽**）。
- 默认面：新建→打包；已有→`TripDetailFaceStore`（UserDefaults per trip）记的上次面，无则行程规划。trip 动作「…」两面常驻。

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
- TripBundle：行程容器（包含 PackingList、TripInfo、`itineraryDays` 等）
- MyItem：用户自定义物品
- PackingList：打包清单
- **ItineraryDay / ItineraryStop**（`Models/Itinerary.swift`，行程路线规划）：行程=多个有序 Day，每 Day=有序 Stop（name/坐标/类别/计划时段/停留/note/sortOrder）。挂在 `TripBundle.itineraryDays`（级联）。新增 model 属 SwiftData 轻量迁移（加表，保持单一 SchemaV1）。备份经 `BackupItineraryDay/Stop`（可选字段，兼容旧备份）
- **TransportSegment / LodgingStay**（`Models/Itinerary.swift`，交通段 + 住宿，spec: `itinerary-transport-lodging.md`）：行程的「边」与「跨度」，与 Stop 并列三类对象。
  - `TransportSegment`（边）：连接两点的一段移动（mode=flight/train/bus/ferry/carRental/other；承运方·班次·起讫站+code+坐标+IANA 时区+航站楼·跨天起降 dayOrder/minutes·座位·确认号·**预留 `liveStatusData` 给未来航班动态**）。挂 `ItineraryDay.segments`（级联，归出发日）；与 Stop 共享时间轴 sortOrder。
  - `LodgingStay`（跨度）：横跨 N 晚（`checkInDayOrder` + `nights`，`covers(dayOrder:)`），挂 `TripBundle.lodgingStays`（级联，不绑单天）。
  - `ItineraryDay.timeline`（`TimelineItem` 枚举）：stop + transport 合并的单一数据源——**停靠点保持手动 sortOrder，设了时间的交通段按时间「就位」插入**（详见 decisions 2026-06-15）。
  - 备份 `BackupTransportSegment/BackupLodgingStay`（可选字段，兼容旧备份）；`duplicateTrip` 深拷贝；`syncItineraryDays` 缩短天数时交通段同停靠点挪到保留天、住宿 dayOrder 夹回（防数据丢失）。
  - **签证行程单导出**：`ItineraryPDFRenderer`（`UIGraphicsPDFRenderer` A4 分页）+ `ItineraryDocumentText`（文档固定文案 EN/ZH 代码字典，按所选语言渲染、不走设备 locale）+ `ExportItinerarySheet`（导出选项）；概览图复用 `TripShare.renderRouteMap`。spec: `itinerary-export-document.md`。
- **费用记录（`CostBearing` 协议，spec: `itinerary-cost-tracking.md`）**：`ItineraryStop` / `TransportSegment` / `LodgingStay` 三实体 conform `CostBearing`，各加 `costAmount`（金额，原币种）+ `costCurrencyCode`（ISO 4217，空=未记录）+ `costHomeAmount`（录入时折算成本位币的快照，-1=未捕获→实时折算兜底）。**真相 = 金额 + 原币种**（永不丢），快照只为历史值稳定。加列属轻量迁移（无 SchemaV2）；备份 `Backup*` 三处加可选字段、`duplicateTrip` 深拷贝带上。写入统一经 `TripStore.setStopCost/setTransportCost/setLodgingCost`（单一漏斗 + 就地捕获快照）；改本位币 → `recomputeCostSnapshots()` 从原始金额重算（不变式：快照永远以当前本位币计）。
- Scene / SceneItemMap：场景与物品映射（智能推荐基础）
- ItemCatalog：物品目录（预置数据）
- TripReminderConfig：行程提醒配置（含 `presets` 档位、`localizedLabel`）
- ReminderPreferences（UserDefaults）：全局默认提醒偏好（已开启档位 + 默认时间）。新建行程时**快照**进该行程的 reminderConfigData（非实时联动）；设置「通知」二级页（NotificationSettingsView）编辑
- SurpriseItemMap："顺手考虑一下"功能的物品映射

## 状态管理
- TripStore（@StateObject，全局）：行程数据的读写、refresh
- NavigationRouter（@StateObject，全局）：导航路径管理
- AppearanceMode（@AppStorage）：外观模式（system/light/dark）
- DistanceUnit（`Models/DistanceUnit.swift`，`@AppStorage("distance_unit")`）：距离单位偏好（automatic/kilometers/miles），`.automatic`=跟随设备 locale。`CarryDistanceFormat.string(meters:unit:)` 为全 App 距离展示**单一格式化入口**（每单位一个固定的全局 `MKDistanceFormatter`，缓存且无 `.units` mutation）；行程时间轴段距 / 地点详情路程模块 / 优化页距离统一走它
- CarryAccent（`AppearanceMode.swift`）：App 唯一强调色「烟蓝」。SwiftUI 层 `.tint(CarryAccent.color)`（ContentView 注入）+ UIKit 层 `UIWindow.appearance().tintColor = CarryAccent.uiColor`（`CarryApp.init`，覆盖系统弹窗/菜单/导航栏）。无用户可见主题切换
- ExchangeRateManager（`@MainActor` 共享单例 `.shared`）：汇率拉取/按天缓存 + 本位币口径。base 读 `preferred_currency_code`（`@AppStorage`，未设回退设备 locale）；`convertToHome` 折算、`refreshBaseCurrency`/`fetchNow` 改币种后切 base+重拉。目的地汇率屏与费用折算共用同一实例（`CarryApp` 启动预热）

## 持久化
- SwiftData，versioned schema（CarrySchema.swift）
- MigrationPlan（CarryMigrationPlan）保障升级安全
- ModelContainer 初始化失败时 fallback 到 in-memory store

## 行程路线规划模块（`feature/itinerary-route-planning`，未合并；spec: `specs/itinerary-route-planning.md`）
- **ItineraryView**：行程规划主视图（地图头 + 按天时间轴 + 加天/加点/优化入口 + sheets）
- **ItineraryReorderCollection**：按天的 `UICollectionView` 拖拽容器，**放开跨 section（跨天）**——复刻打包 `ReorderableItemCollection` 但去掉 `clampLocationToSection` 夹断；松手经 `TripStore.applyItineraryArrangement` 提交所有受影响天（重设 stop 的 `day` + `sortOrder`）。另承载**日历 ↔ 列表双向联动**：入参 `scrollTargetDayId`（切日历→吸顶该天）、回调 `onFocusDay`（滚列表→回写选中天），靠 `lastScrolledDayId` 单一真相 + `isProgrammaticScroll` 防回授；末日地点少时按需补底部 `contentInset` 使其也能吸顶（详见 `decisions.md` 2026-06-14）
- **ItineraryMapView**：地图头（`Marker` 按访问序号编号 + `MapPolyline` 每天连线；坐标点 <2 不显示；整块可点全屏）
- **AddStopView**：`MKLocalSearchCompleter` 地理搜索选点（偏置到目的地）或手动无坐标点
- **OptimizeRouteView**：单日重排预览→采纳（距离对比 + 新路线地图）
- **StopEditView**：停靠点编辑（名/类别/时间锚点/备注/删）
- **RouteOptimizer**（纯函数）：最近邻 + 2-opt，**固定首尾** + 时间锚点作段端固定（Haversine 搜序）；`isImprovement(original:optimized:)` 纯函数判定「省 >50m 且 >1%」，直线/道路口径共用
- **RouteDistanceService**（actor）：优化预览的真实道路距离——`MKDirections` 串行 + 会话缓存 + 失败回退直线。**道路距离不仅用于展示，还是「是否算改进」的判定口径**（道路没省/更长 → 「已较优」不采纳）；离线 / 6s 超时退回直线判定。详见 `specs/itinerary-optimize-road-gating.md`

## 其他模块
- CarryLogger：单例日志，记录关键生命周期事件和 DB 错误
- NotificationManager：本地通知（行程提醒）；`tripId(fromIdentifier:)` 从通知 ID 解析行程 UUID
- PackReminderNotificationDelegate：`UNUserNotificationCenterDelegate`，点击打包提醒后解析 tripId 写入 `NavigationRouter.pendingTripId`，实现自动跳转
- DataBackupManager：数据备份（JSON 镜像 + 还原/合并）。**含非 SwiftData 关联文件**：背景图字节随备份带上（`CarryBackup.backgroundImages` 文件名→base64），还原时写回沙盒；裁剪元数据走 `BackupTrip.backgroundsData`
- 行程背景图（`feature/home-ui-redesign` 分支，Phase 1）：
  - `TripBackground.swift`：`TripBackgroundEntry`（条目，含归一化裁剪框 `BackgroundCrop`，存于 `TripBundle.backgroundsData`）+ `BackgroundImageStore`（沙盒 `Application Support/TripBackgrounds/`，压缩存图/取图/裁剪缓存；存图时烘焙方向+scale 1 以保裁剪坐标正确）
  - `BackgroundPicker.swift`：`PhotoPicker`（PHPicker 封装，`.compatible`，只转发 itemProvider/cancel，不自行 dismiss/加载）
  - `BackgroundReposition.swift`：`loadBackgroundImage`(loadObject→loadDataRepresentation 回退，iCloud 健壮加载) + `BackgroundRepositionView`(UIScrollView pan/zoom 选裁剪框) + `PositionedImage`(焦点居中、固定比例展示，设备无关 WYSIWYG)
  - `DestinationMapThumbnail.swift`：`TripBackgroundView`(有图→`PositionedImage`；无图→`.monogram` 墨色字母块 / `.map` 实时 MKMapView)；入口在 `PackingListView` 详情页「…」菜单
  - `HomeStyleFlag.swift`：`HomeCardStyle`（现仅 `.featured`=2·Map 默认正式样式 / `.glass`=4·Map 实验；1·Plain/3·Thumb 已删）。Dev Options 仍可切 2↔4；若最终只留 2·Map,再删此文件 + 切换器
- CurrencyCatalog（`Models/CurrencyCatalog.swift`）：国家码→币种（code+符号）静态表 + 展示助手（`deviceDefaultCode`/`homeCurrencyCode`/`allCodes`/`localizedName`/`symbol`/`format`/`amountText`）；币种名/格式走 `Locale`，不进 xcstrings
- TripSpendStats（`Models/TripSpendStats.swift`，纯函数）：Trip Book 花费聚合——按本位币把已发生行程的费用折算成交通/住宿/地点三类目 + 每趟明细；`CostResolver.homeValue` 快照优先/实时兜底/无汇率诚实标注（`hasUnconverted`/`approximate`）。注入 `convert` 闭包解耦汇率源（便于单测）
- CurrencyPickerView / CostInputRow（`Views/`）：货币选择器（全屏可搜索 + 建议分区，本位币模式写设置/选择模式回传 code）；费用录入行（金额 + 币种 chip），三处编辑页共用
- CoffeeStore：StoreKit 内购（打赏功能）
- CarryShortcuts / AppIntents：Siri/Spotlight 快捷指令
  - create_trip：创建新行程
  - open_trip：打开指定行程
  - show_map：展示地球地图
- GlobeView：3D 地球视图（MapKit Annotation pin 点亮到访国家，不绘制多边形边界）
- 首页底部 Sheet：`CarryBottomSheetFX`——`UIViewControllerRepresentable` 桥接的 UIKit 自定义 sheet。两侧/底部缩放视觉，纯 Core Animation 驱动（吸附用 `UIViewPropertyAnimator`，无 CADisplayLink）；内容固定尺寸 + transform 缩放 + 运动期 `shouldRasterize`，嵌套 cornerRadius 层做上下异半径圆角。HomeView 直接调用,无变体开关（无缩放 fallback 与 `SheetFeatureFlag` 已于 2026-06-07 退役删除）。**首页底栏（搜索/行程册/创建 FAB）自 2026-06-14 经 `bottomBar:` 闭包托管进本控制器**（`installBottomBar`，钉 `view` 底），与卡片由同一 animator 同步缩放（见 playbook §19）。触碰此模块**必读** `docs/home-sheet-debug-playbook.md`（手势/吸附/滚动锁的踩坑史与纪律）。
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
