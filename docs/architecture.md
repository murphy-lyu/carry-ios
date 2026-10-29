# Carry 架构说明

## 账户数据与独立副本（开发中 · 2026-10-27）

2026-10-28 文件链路补充：`CarryAssetUploader` 为独立 actor，TUS 分块、保护缓存、账户固定及令牌逐请求刷新；`CarryAccountService.assetUploader` 指向尚未部署的 Carry 文件代理。`asset-storage.mjs` 流式读取实际对象并核对 SHA256/尺寸，私有文件迁移尚未部署。对象预留不能覆盖重复/未知的 TUS 会话，必须接完上传尝试持久额度、并发租约及物理清理后再开放 Storage；详情见 `carry-account-assets-qa.md`。没有给客户端直接写文件的权限，不能把合成传输测试当成真实资产迁移。

`CarryAccountService` 为数据传输创建绑定账户 ID 的令牌提供器，刷新后再次核对缓存所属身份。`CarryGraphTransport` 调用开发库的 `carry-data`；`CarryAccountSyncEngine` 串行执行有界发送/拉取，不把 ACK 当作已经接收全部远端变化。

`CarryAccountReplica` 使用独立 `.none` ModelContainer：原有业务模型加 `CarryReplicaRecord/Checkpoint`，**不修改原 iCloud SchemaV1**。投影回调、逐字段意图、冻结请求、冲突与拉取游标共用本地 save/rollback。账户身份固定写在 checkpoint；缓存不得跨账户复用。当前尚未路由原 TripStore 的全部真实写入口，不能用这些组件替代完整原生接入验收。

副本热路径按对象 UUID 查找，持久 pending 标志筛选待同步记录；旧缓存默认 true 并在队列读取时归一。`accept/receive/resolveFields` 的投影参数是改变后的本地快照增量，包含墓碑，消费者必须在同一 context 原子应用；不得当作完整图替换。空页不重新投影全部业务对象。

服务端是 `carry_private` 中的父子数据图、账户提交序号、变更日志及请求回执；同一账户写入取得事务锁，业务、日志与回执原子提交。独立字段可以合并，同字段冲突保留当前值/提议值。祖先子树版本也作为变更事件同步，用于检测删除预览之后的子项编辑；移动同时更新两条祖先路径。账户管理和数据入口均核对当前数据库中的有效原生会话；登记新账户不预先要求已登记身份，数据写入再核对登记/删除状态。只有读取 Auth 会话的私有谓词使用 definer，其余 public RPC 和图状态检查为 invoker。账户数据入口只接受有效原生用户会话，OAuth 客户端必须另经尚待实现的 AI 权限层。

`CarryGraphMigrationCodec` 在后台以完整 Backup DTO 编解码选中范围，核对文件内容与引用；Photos 资料库原图明确列为待源设备采集。纯值 DTO 显式 nonisolated/Sendable，数据库和 UI 仍按原有 actor 隔离。实际 Storage 上传、源图归属切换、旧设备分叉、完整删除及新 MCP 链路仍在开发中。部署、组件测试与待完成门禁见 `docs/carry-account-graph-qa.md`。

## Codex 受限自动化连接（2026-10-25）

**方向变更**：以下描述分支中的既有实现。用户已确认手机关闭时也应可完成 AI 操作，并同意适合时使用 Apple 登录。新方案为 `specs/carry-cloud-and-ai.md` 的可选账户、首选 Apple 身份、独立数据服务与离线同步；工程选型与风险验证见 `docs/adr-carry-account-and-sync.md`。尚未实现完整账户/同步，不能把下文前台执行当作最终产品约束。

`scripts/carry-mcp/worker.js` 提供 Streamable HTTP MCP、OAuth/PKCE、授权快照与请求队列。`CarryAutomationConnection` 管理 ThisDeviceOnly Keychain 凭据、前台轮询和撤销；`CarryAutomationProtocol`/`CarryAutomationQueries` 校验并调用现有 SwiftData 业务操作。业务数据和 `AutomationExecutionRecord` 在隔离事务中一起保存，成功后发布新的观察图；服务端不直接修改 CloudKit 私人记录。

配对先在 Keychain 保存随机连接 UUID、设备凭据和 `AutomationPendingPair`，再请求批准。服务端只保存凭据及原始授权输入的摘要，精确重复请求返回同一连接；待完成状态不传快照、不执行操作。取消和批准使用同一服务端串行入口，取消未使用的配对码或撤销已创建连接，防止迟到批准重新启用权限。OAuth `/revoke` 与设备撤销共用清理逻辑，删除快照、队列及令牌映射。恢复配对不延长 OAuth 授权码有效期。

Debug/Release 的 `CARRY_CLOUDKIT_ENVIRONMENT` 分别为 Development/Production，实际签名 entitlement 单独核对。完整模型由原生 API 导出并初始化，不能手工猜字段；开发与生产结构快照保存在 `scripts/cloudkit-schema-bootstrap/schema/`。真实跨设备同步、原生线上链路与本地测试分别验收。

## 原生保存边界（2026-10-29）

`CarryPersistence` 为 TripStore 和 DataBackupManager 的显式保存入口；关闭业务 Context 的 autosave，writer 可在同一次 save 捕获账户日志。失败时物化待删除的级联对象后回滚、隔离旧 Context，TripStore 重新加载持久图；普通编辑、草稿与还原均可重试。文件删除等副作用仅在保存成功后执行。

`CarryBackupFileStage` 将外部备份的引用映射到新文件名；提交成功发布引用，失败只清本次文件。外部输入不能借用本机私有文件或导入分享外的附件。自动本地备份才可复用仍存在的本地文件。详见 `carry-native-persistence-qa.md`；日志、协议桥接、投影与账户子库尚待实现，不能把 writer 注入当成已接通同步。

## 整体结构

### iOS（2026-06-12 起：根级不再是 TabView，见 `specs/app-navigation-framework.md`，feature 分支未合并）
SplashView（启动过渡）
└─► ContentView → **单个 NavigationStack → HomeView**（根=行程首页，足迹地球 + UIKit Sheet）
    ├─► HomeView hero 右上 gear → **SettingsView（sheet 呈现，非 tab）**；右下 FAB → 创建（iPhone 为 `.sheet`，单屏 TripInfo 表单，2026-06-19 由 `fullScreenCover` 改）
    └─► navigationDestination
        ├─► UUID → PackingListView（行程详情，**两张脸**）
        └─► CreationRoute → 创建流程（tripInfo / itemPicker / packingList(isNewTrip)；`editScenes` 路由 2026-06-19 作为死代码删除）

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
  - `TransportSegment`（边）：连接两点的一段移动（mode=flight/train/bus/ferry/carRental/other；承运方·班次·起讫站+code+坐标+IANA 时区+航站楼·跨天起降 dayOrder/minutes·座位·确认号·**按 mode 裁剪的字段**（航班 e-ticket/舱位/机型；火/巴/渡 线路名 routeName·车厢 coachNumber·席别 seatClass·类型 serviceType，详见 spec `itinerary-ground-transport-fields.md`）·**预留 `liveStatusData` 给未来航班动态**）。挂 `ItineraryDay.segments`（级联，归出发日）；与 Stop 共享时间轴 sortOrder。
  - `LodgingStay`（跨度）：横跨 N 晚（`checkInDayOrder` + `nights`，`covers(dayOrder:)`），挂 `TripBundle.lodgingStays`（级联，不绑单天）。
  - `ItineraryDay.timeline`（`TimelineItem` 枚举）：stop + transport 合并的单一数据源——**停靠点保持手动 sortOrder，设了时间的交通段按时间「就位」插入**（详见 decisions 2026-06-15）。
  - 备份 `BackupTransportSegment/BackupLodgingStay`（可选字段，兼容旧备份）；`duplicateTrip` 深拷贝；`syncItineraryDays` 缩短天数时交通段同停靠点挪到保留天、住宿 dayOrder 夹回（防数据丢失）。
  - 注：原「签证行程单导出」（PDF）已于 2026-06-24 下线（与产品预期不符、待重做），相关代码已删除、spec `itinerary-export-document.md` 保留作重做参考（见 decisions 2026-06-24）。
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
- CalendarManager（`Managers/CalendarManager.swift`，`@MainActor` 单例）：EventKit 集成。① **写**：把行程写入专属「Carry」日历（事件带 `carry://trip/{uuid}` URL）；② **读（日历叠加层，spec: `itinerary-calendar-overlay.md`）**：`overlayEvents(start:end:calendarIDs:)` 读用户勾选日历在行程区间内的只读事件（排除 `carry://` 自写防回环）、`availableCalendars`/`selectedOrDefaultOverlayIDs`（首次默认勾节假日类只读公共日历）。**叠加事件只活在视图层临时态（`ItineraryView.overlayEventsByDay`），永不入 model/分享/导出/备份**（隐私红线，构造保证）。渲染：`ItineraryReorderCollection` 的 `.calendarEvent(id:day:)` 行 + 点击弹 `CalendarEventDetailView`（Carry 内浮层，不跳系统日历）
- PackReminderNotificationDelegate：`UNUserNotificationCenterDelegate`，点击打包提醒后解析 tripId 写入 `NavigationRouter.pendingTripId`，实现自动跳转
- DataBackupManager：数据备份（JSON 镜像 + 还原/合并）。自动备份合并采样、Sendable 镜像 utility 串行编码/原子写入；generation 防抹除后在途写复活。设置/恢复页异步读取一次 metadata；模型读取仍在主 actor，SwiftData 保存不延迟。性能证据见 `performance-review-2026-10-28.md`。**含非 SwiftData 关联文件**：背景图字节随备份带上（`CarryBackup.backgroundImages` 文件名→base64），还原时写回沙盒；裁剪元数据走 `BackupTrip.backgroundsData`
- 行程背景图（`feature/home-ui-redesign` 分支，Phase 1）：
  - `TripBackground.swift`：`TripBackgroundEntry`（条目，含归一化裁剪框 `BackgroundCrop`，存于 `TripBundle.backgroundsData`）+ `BackgroundImageStore`（沙盒 `Application Support/TripBackgrounds/`，压缩存图/取图/裁剪缓存；存图时烘焙方向+scale 1 以保裁剪坐标正确）
  - `BackgroundPicker.swift`：`PhotoPicker`（PHPicker 封装，`.compatible`，只转发 itemProvider/cancel，不自行 dismiss/加载）
  - `BackgroundReposition.swift`：`loadBackgroundImage`(loadObject→loadDataRepresentation 回退，iCloud 健壮加载) + `BackgroundRepositionView`(UIScrollView pan/zoom 选裁剪框) + `PositionedImage`(焦点居中、固定比例展示，设备无关 WYSIWYG)
  - `DestinationMapThumbnail.swift`：`TripBackgroundView`(有图→`PositionedImage`；无图→`.monogram` 墨色字母块 / `.map` 实时 MKMapView)；入口在 `PackingListView` 详情页「…」菜单
  - `HomeStyleFlag.swift`：`HomeCardStyle`（现仅 `.featured`=2·Map 默认正式样式 / `.glass`=4·Map 实验；1·Plain/3·Thumb 已删）。Dev Options 仍可切 2↔4；若最终只留 2·Map,再删此文件 + 切换器
- CurrencyCatalog（`Models/CurrencyCatalog.swift`）：国家码→币种（code+符号）静态表 + 展示助手（`deviceDefaultCode`/`homeCurrencyCode`/`allCodes`/`localizedName`/`symbol`/`format`/`amountText`）；币种名/格式走 `Locale`，不进 xcstrings
- TripSpendStats（`Models/TripSpendStats.swift`，纯函数）：Trip Book **跨行程**花费聚合——按本位币把已发生行程的费用按 `SpendCategory` **7 类**聚合（`TripSpendBreakdown.byCategory`：交通/住宿 + 地点拆 餐饮/景点/活动/购物/其他）+ 交通再按 `TransportMode` 拆（`transportByMode`，供下钻分行）+ 每趟明细（`TripSpendRow` 带 `departureDate` 供时间轴）；`CostResolver.homeValue` 快照优先/实时兜底/无汇率诚实标注（`hasUnconverted`/`approximate`）。注入 `convert` 闭包解耦汇率源（便于单测）
- TripSpendDetail（`Models/TripSpendDetail.swift`，纯函数）：**单行程**花费聚合（7 类 + 按天/按币种维度 + 逐笔 `SpendItem`，含 `mode` 决定逐笔图标）；与 `TripSpendStats` **共用 `SpendCategory`**，口径不漂移。供单行程花费页（`Views/TripSpendView.swift`）。
- TripBookStats（`Models/TripBookStats.swift` + `+Trips.swift` 适配器，纯函数）：Trip Book 各卡聚合（国家/大洲/季节/国内国际/打包率 + 飞行里程·时长·机型·机场 + 住宿晚数 + 在地足迹 `StopCategory` 计数 + 最远一程 `FlightLeg`）；`homeCountry`/`normalize` 默认取 storefront 口径、可注入单测
- CurrencyPickerView / CostInputRow（`Views/`）：货币选择器（全屏可搜索 + 建议分区，本位币模式写设置/选择模式回传 code）；费用录入行（金额 + 币种 chip），三处编辑页共用
- CoffeeStore：StoreKit 内购（打赏功能）
- CarryShortcuts / AppIntents：Siri/Spotlight 快捷指令
  - create_trip：创建新行程
  - open_trip：打开指定行程
  - show_map：展示地球地图
- GlobeView：3D 地球视图（MapKit Annotation pin 点亮到访国家，不绘制多边形边界）
- 首页底部 Sheet：`CarryBottomSheetFX`——`UIViewControllerRepresentable` 桥接的 UIKit 自定义 sheet。两侧/底部缩放视觉，纯 Core Animation 驱动（吸附用 `UIViewPropertyAnimator`，无 CADisplayLink）；内容固定尺寸 + transform 缩放 + 运动期 `shouldRasterize`，嵌套 cornerRadius 层做上下异半径圆角。HomeView 直接调用,无变体开关（无缩放 fallback 与 `SheetFeatureFlag` 已于 2026-06-07 退役删除）。**首页底栏（搜索/行程册/创建 FAB）自 2026-06-14 经 `bottomBar:` 闭包托管进本控制器**（`installBottomBar`，钉 `view` 底），与卡片由同一 animator 同步缩放（见 playbook §19）。触碰此模块**必读** `docs/home-sheet-debug-playbook.md`（手势/吸附/滚动锁的踩坑史与纪律）。
- RoadmapView：产品路线图（支持远程 JSON 更新）
- LiveActivityManager：`@MainActor` 单例，管理**两类** Live Activity 生命周期。① 打包进度（`PackingActivityAttributes`）：start / update / end / endIfDeparted。② 出行日「下一程」交通（`TransportActivityAttributes`，spec: widget-transit-live-activity.md）：`startTransitIfNeeded(trips:)`（A 自动起，冷启动 + 回前台扫所有行程取最临近一程）/ `startTransit`·`userStopTransit`（B 详情页显式起停）/ `endTransitIfArrived` / `endTransit`。`endAll()` 同时清两类；关单个开关用 `endAllPacking()` / `endTransit()` 不误伤另一类。用户显式停过的段记 `liveActivityTransitDismissed`、A 跳过。schedule-based（`Text(timerInterval:)` 自走，`pushType:nil`），未接实时航班动态
- **机场数据库（`Models/AirportDatabase.swift`，actor；spec: `itinerary-airport-search.md`）**：航班机场选点专用的**内置离线机场库**。`Bundle` 内 `Carry/Resources/airports.json`（~4100 个有定期航班的机场，OurAirports 列表 + OpenFlights IANA 时区 + Wikidata 9 语言机场名/城市别名；IATA 未命中用 ICAO 兜底抓取）。actor 首次检索时懒加载解码、不阻塞主线程；`search()` 按 IATA/ICAO/英文名·城市/各语言名匹配，全球无区域过滤。`Airport.id = iata`（数据生成脚本硬断言唯一非空）。UI 走 `Views/AirportSearchSheet.swift`，仅 `TransportEditView` 航班模式接入（回填 IATA/坐标/IANA 时区）；其它交通方式仍走通用地图 POI（`ItineraryPlaceSearchSheet`）。数据重建脚本 `scripts/airports/`；数据许可 OpenFlights ODbL 已在 `AboutView`「数据来源」卡署名。
- **添加航班「搜索优先」（spec: `itinerary-flight-search-first.md`）**：两段式。**第 1 段** `Views/FlightSearchSheet.swift`（新）——渐进式单框：输航班号→即时识别航司→竖排日期列表（本行程的天 + 系统日历，**点日期即触发查询**）→结果确认卡→点卡 push 进**预填**的 `TransportEditView`（`prefill:` + `embedInOwnNavigationStack:false` + `onFinish`，复用同一 NavigationStack、避免嵌套栈）；底部常驻「手动输入」兜底。**第 2 段** = 既有 `TransportEditView`（含日期/时间融合 chip）。航司识别走 **`Models/AirlineDatabase.swift`**（actor，`Carry/Resources/airlines.json` ~986 航司，OpenFlights `airlines.dat` + Wikidata 多语言名，英文名也优先 Wikidata；脚本 `scripts/airlines/`）+ `FlightNumberParser`（拆「航司前缀+班次」）。查询经 `Models/FlightLookupService.swift` → 自家 Cloudflare Worker（`scripts/flight-proxy/worker.js`，藏上游 key + 服务端缓存 + APP_TOKEN 门槛 + Rate Limiting 绑定）。**密钥纪律**：`FlightLookupConfig.appToken` 不硬编码，从 gitignore 的 `Carry/Resources/Secrets.plist` 读取（见 CLAUDE.md 密钥约定）。

- **海外地点检索（spec: `itinerary-overseas-poi-search.md`；Worker `scripts/places-proxy/`）**：大陆设备 MapKit POI 走高德、搜不到境外地点，故「地点/住宿」检索走**双源**——国内 MapKit/高德 + 境外自家 Cloudflare Worker（`places.nevestudio.app`）。App 侧 `Views/AddStopView.swift` 的 `StopSearchCompleter` 把两源合并成统一 `PlaceSuggestion`（300ms debounce、防乱序、关闭取消在途），选中按来源分流解析。Worker **多源抽象** `SEARCH_PROVIDER = mapbox|geoapify|auto`（Mapbox 主 + Geoapify 自动降级，零发版换源防单点；suggest id 带 `mb:`/`ga:` 前缀路由回来源，Geoapify 把 retrieve 数据编进 id 离线解析）；藏 Mapbox/Geoapify key + Azure Translator（中文 query 翻英文）+ tz-lookup（坐标转 IANA 时区）+ APP_TOKEN 门槛 + 缓存。**合规红线**：境内（country code CN/HK/MO **或**坐标时区落沪/乌/港/澳）一律不经 Worker 出、交高德。运维/排查见 docs/infrastructure.md。

## 政策合规（中国大陆上架）
> 完整约定见 CLAUDE.md「政策合规约定」章节，此处仅记模块归属。
- `isChinaStorefront`（`SceneItemMap.swift` 顶层函数）：通过 `SKPaymentQueue` storefront 检测是否大陆区，Debug 可用 UserDefaults 覆盖。所有大陆差异化行为的唯一判断入口
- `TimeZoneCanonicalizer`（`Models/Itinerary.swift`）：大陆境内地理时区别名（`Asia/Urumqi`/`Kashgar`/`Harbin`/`Chongqing`）统一归一到北京时间 `Asia/Shanghai`（中国全国单一民用时区）；在 MapKit 地点解析 + 备份导入两入口应用，避免纯国内行程被误判跨时区。港澳/境外不动
- `HomeView.normalizedCountryCode(_:)`：仅大陆 storefront 下将 HK/MO/TW 归并为 CN（仅展示层，存储层保持 ISO 原值）
- `generatePackingSections(destinationCodes:)`：大陆 storefront 下按目的地推荐港澳通行证 / 台湾通行证替代护照
- `TripStore.inferCountryCodes` / `inferIsInternational`：geocoding 异步完成前用本地城市表同步推断国家码，避免证件误推

## Widget Extension（CarryWidgetExtension）
- 独立 target，bundle ID `app.nevestudio.carry.widget`
- `CarryWidgetBundle`：注册 `CarryWidget`（桌面组件）+ `CarryWidgetLiveActivity`（打包 LA）+ `CarryTransitLiveActivity`（交通 LA）
- **`CarryWidget`（桌面组件，spec: widget-trip-companion.md）**：`.systemSmall`/`.systemMedium`，**随旅行相位自适应**——出发前=倒计时+打包进度（现状）；旅行中=`Day N/M` + 下一件事倒计时 + 今晚住哪/退房。数据从 App Group（`group.app.nevestudio.carry` → `carry_widget_trips`）解码 `WidgetTrip`（镜像主 App 的 `WidgetTripSnapshot`）。相位/当前天/下一件事在 Widget 侧按 `entry.date` 推导（事件绝对时刻由 App 预算好），timeline 在「每个未来事件 + 每日午夜」放 entry → 跨天自走、App 不开也对。外观选择器（Automatic/Light/Dark）见 `WidgetColorSchemeOverride`
- `CarryWidgetLiveActivity`：打包进度。锁屏卡片（LockScreenView）+ 灵动岛（展开/紧凑/最小态）
- `CarryTransitLiveActivity`：出行日「下一程」。锁屏卡片（FROM→TO + `Text(timerInterval:)` 倒计时 + 航站楼/座位）+ 灵动岛三态；相位（起飞前/途中/已抵达）渲染时按 `Date()` 判定
- `CarryWidget/Localizable.xcstrings`：widget 专属本地化（9 种语言）。⚠️ 纯数据/分隔符用 `Text(verbatim:)`，避免 `Text("\(a) → \(b)")` 被 Xcode 抽成本地化键

## SharedSources（pbxproj 同时编译进 Carry 与 CarryWidgetExtension 两 target）
- `SharedSources/PackingActivityAttributes.swift`：打包 LA 共享类型。`ActivityAttributes` 只含 `tripId`；`ContentState` = packedItems / totalItems / isCompleted / tripName / destinationCity / departureDate
- `SharedSources/TransportActivityAttributes.swift`：交通 LA 共享类型（spec: widget-transit-live-activity.md）。`ActivityAttributes` = tripId + segmentId；`ContentState` = modeRaw / carrierAndNumber / from·to 码·名 / departureDate / arrivalDate（绝对时刻，App 按两端时区算）/ fromTerminal / seat + 预留 `liveStatus`/`gate`/`actualDepartureDate`（未来航班动态，填充即用、不改结构）
- **桌面组件 snapshot 不走 SharedSources**：`WidgetTripSnapshot`（`TripStore.swift`）与 `WidgetTrip`（`CarryWidget.swift`）是**字段一致的双份镜像**、靠同一 JSON 通信（加字段两处同步改、Widget 侧可选）

## 账户副本与网页登录时序补充（2026-10-28）
- `CarryAccountReplica` 的结构移动保留独立原版本；`resolveParent` 按被拒请求/服务端版本/本地 parent 处理人工选择。pull 不暗中重新授权旧移动，过期冲突不能覆盖已经拉取的新状态。
- 本地创建在 ACK 前收到的远端更新保存在 `unconfirmedRemote`；只有自己的创建 ACK 绑定 UUID 后再合并，不因推进 cursor 丢弃后续变化。多实体 edit 与 native projection 共用一次事务。
- 网页 `scripts/carry-account-web` 由官方 SSR SDK 管 Cookie，会话与十分钟 Apple flow 分开；原生和网页共用生命周期服务，web code exchange 只接受服务端固定回调。范围授权与数据读写仍待实现；入口关闭，不能视为已接通 AI。
