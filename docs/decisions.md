# 决策日志

## 2026-05-31 App Icon / Live Activity

### App Icon 用 Asset Catalog 单 1024，预览另存 imageset
原因：旧实现走 Info.plist `CFBundleAlternateIcons` + bundle 根裸 PNG（要 @2x@3x、手动加 Copy Bundle Resources），繁琐易错。Asset Catalog 方式单张 1024 即可，与主图标一致。
实现：每图标 `<id>.appiconset`（`INCLUDE_ALL_APPICON_ASSETS=YES` 自动注册为 alternate icon）；删 Info.plist 旧声明。
关键坑：iOS **禁止** `UIImage(named:)` 读取 app icon 资源（含 alternate），故 app 内缩略图必须另存一份普通 `<id>Preview.imageset`（同图）。这是业界标准模式（Things/Carrot 等），非冗余 hack。

### Live Activity 仅出发前 7 天内激活
原因：原 `startIfNeeded` 只挡「已出发」，无上限——打开任意未出发行程（哪怕数月后）的清单都会在锁屏常驻活动。Live Activity 面向临近/进行中事件，远期行程无紧迫性。
实现：`activationWindowDays = 7`，`0 <= daysUntilDeparture <= 7` 才激活。

### Settings 右侧状态：按「信息是否有用」区别对待，不统一
原因：右侧状态文字应服务「不进二级页就获取有用信息」。Calendar 的 On/Off 是真状态（有用）；Live Activity 的「开」只是「允许」、真展示还取决于有无临近行程（开≠在用，显示会误导）；App Icon 名字是冗余信息（桌面可见）但显示更精致对称。
决定：Calendar 显 On/Off、Live Activity 不显、App Icon 显图标名。

## 2026-05-31 Quick Actions / 桌面 Widget

### 主屏幕 Quick Actions 复用 UserDefaults 分发，不新建通道
原因：`AppShortcutsProvider`（Siri/Spotlight）不填充图标长按菜单，后者需 `UIApplicationShortcutItems`。
实现：动态 `shortcutItems`（SF Symbol 图标 + 复用语义 key 本地化）；`CarrySceneDelegate` 接收冷/热启动回调写 `carry_shortcut_action`，复用 ContentView 既有的 `UserDefaults.didChangeNotification` 监听分发，零导航改动。
放弃：Info.plist 静态声明（SF Symbol 受限、本地化分散到 InfoPlist.xcstrings）。
真机验证（已确认）：冷/热启动 × 3 动作均正常；SceneDelegate 未破坏 WindowGroup（无黑屏）；图标菜单**只显示 3 项**——iOS 16+ 自动把自建 `UIApplicationShortcutItem` 与 `AppShortcutsProvider` 合并，不重复，无需移除自建那套。

### Widget 数据共享用 App Group UserDefaults 快照，不共享 SwiftData 容器
原因：Widget 独立进程读不到主 App SwiftData。改 `ModelContainer` 为 App Group 容器会迁移现有用户数据存储位置，有丢数据风险。
实现：主 App 在 launch/background 把「即将出发 top 3」精简快照（`WidgetTripSnapshot`）写入 App Group UserDefaults JSON，Widget 解码同字段镜像 struct。倒计时按天数分支（0/1/>1）绕开各语言复数规则。
放弃：共享 SwiftData 容器（迁移风险）；SharedSources 共享 struct（需改 pbxproj，改用两侧镜像 + JSON 规避）。
依赖：两个 target 需加 App Group capability（开发者在 Xcode 操作）；未配置则 widget 降级空状态、不崩。

### Widget 主标题用行程名 name，不用 destinationCity
原因：App 内行程卡片以 `name`（用户自起的行程名）为主、城市为副；widget 初版误用 `destinationCity` 为主，导致同一行程 App 内显示「回家」、widget 显示「上海」，割裂。
实现：widget 三处主标题改为 `name.isEmpty ? destinationCity : name`（优先 name，回退城市）。

### Upcoming 标签两边对齐地道翻译（非保留英文）
原因：首页 `home.upcoming` 此前 de/es/fr/ja/ko/pt-BR 仅留英文 "Upcoming"（漏翻）；widget 各自翻译会与首页割裂。App 未上线，无改已上线文案顾虑。
实现：`home.upcoming`（主 App）与 `widget.header.upcoming`（widget，各自 xcstrings 无法共享 key）统一为同一套地道译法，9 语言一致。

### Quick Actions 可能与 AppShortcutsProvider 在图标菜单重复（待真机确认）
发现：iOS 16+ `AppShortcutsProvider` 的 App Shortcuts 本就出现在图标长按菜单（最初判断有误），与本轮自建 `UIApplicationShortcutItem` 可能重复。
决定：先保留两套提交；真机确认后若重复，则移除自建 `UIApplicationShortcutItem` + `AppDelegate`/`SceneDelegate`，直接依赖 `AppShortcutsProvider`（更简、少黑屏风险）。

## 2026-05 架构类

### 选择 SwiftData + versioned schema
原因：与 SwiftUI 集成自然，MigrationPlan 保障 schema 变更安全。
放弃：CoreData（boilerplate 过多），UserDefaults（不适合复杂模型）。

### NavigationRouter 集中管理导航路径
原因：AppIntents 需要从外部触发导航（Siri/Spotlight 启动 App 后跳转），
集中管理避免子 View 各自持有 NavigationPath 导致状态混乱。
约定：所有 router.path 操作只在 ContentView 和 CarryApp 层做，子 View 通过 EnvironmentObject 访问。

### Tab Bar tint 用 .primary 而非品牌色
原因：Carry 的视觉定位是克制、系统融合，彩色 tint 在深色模式下显突兀。
效果：Tab Bar 图标随系统主题自然切换，不抢眼。

### Roadmap 支持远程 JSON 更新
原因：roadmap 内容需要频繁调整，不想每次发版。
实现：本地 roadmap.json 作 fallback，Settings 内可配置远程 URL。

## 2026-05-30 地图合规

### TW/HK/MO 归并逻辑改为仅对中国大陆 storefront 生效
原因：原实现全局将 HK/MO/TW 归并为 CN，台湾/香港用户的行程会被显示为"中国"，体验冒犯。
实现：`normalizedCountryCode` 增加 `isChinaStorefront` 前置判断，通过 `SKPaymentQueue.default().storefront?.countryCode == "CHN"` 检测是否为大陆 storefront。非大陆 storefront 保留原始 country code。
放弃：按设备 Locale 判断（不准，无法区分 diaspora 用户与大陆用户）。

### 删除 countries-110m.geojson
原因：GeoJSON 文件从未被任何 Swift 代码引用（Globe 使用 MapKit Annotation pin，不绘制多边形），是死代码。文件内 Taiwan 以 `"TYPE": "Sovereign country"` 描述，存在中国区审核风险。直接删除，无功能影响。

### 旅行证件推荐按 storefront 差异化
原因：大陆居民去港澳台用的是通行证而非护照，给大陆 storefront 用户推护照既不实用，"护照去台湾"的表述也有审核风险。
实现：`generatePackingSections` 新增 `destinationCodes` 参数；大陆 storefront + HK/MO → 推「港澳通行证」并移除护照，+ TW → 推「台湾通行证」并移除护照；其他 storefront 保持推护照（外籍用户去港澳台仍需护照）。逻辑集中在 `generatePackingSections` 内，禁止散落判断。
放弃：按目的地一刀切移除护照（外籍用户场景会出错）。

### geocoding 完成前用本地城市表同步推断国家码
原因：证件推荐依赖目的地 country code，但 `CLGeocoder` 是异步的，首次进入打包清单时 code 尚未就绪，会先按"无 code"推出护照，geocoding 回来再纠正——用户会看到护照闪现。
实现：`TripStore` 新增 `inferCountryCodes` / `inferIsInternational`，用本地 `cityLookup` / `countryKeywords` 城市表同步推断；`cityLookup` / `countryKeywords` 补全 `taiwan` / `台湾` / `台灣` → TW 映射；`ItemPickerView` 各模式透传 `tripDestinationCodes`，`.create` / `.autoPackReview` 的 `tripIsInternational` 从 nil 改为本地表推断。
放弃：仅依赖 geocoding 异步结果（首屏证件会闪现错误项）。

## 2026-05-30 Home Sheet

### 快速上滑 spring overshoot 露出 MapKit — 用 containerView 向下延伸修复
原因：fallback 版 `SheetViewController` 的 snap 用 `UIViewPropertyAnimator` spring，expand 时 presentation 层 overshoot 飞过静止位；`containerView` 高度固定 = `expandedHeight`、背景 clear、底部直角，一上移底部就透出 ZStack 底层的地图。
实现：`containerView` 向下延伸 `bottomExtension = 400`（静止时在屏外、底部本就直角，正常不可见）+ 设 `backgroundColor` 为 `CarrySubtleBackground` 底部色；`hostingView` 仍只占 `expandedHeight`，内容布局不变。overshoot 露出的是延伸背景而非地图。
放弃：跟踪 presentation 层动态填缝（复杂度高）；改 dampingRatio 消除 overshoot（损失设计想要的弹性手感）。
排查教训：`HomeView` 有两个 Sheet 实现（`CarryBottomSheet` fallback / `CarryBottomSheetFX` ultimate），默认走 fallback。最初 4 次改在了 ultimate 文件上全部“无效”，靠红色填充块仍不可见才定位。已写入 `docs/home-sheet-debug-playbook.md` §6/§7。

## 2026-05-27 隐私与合规

### CarryLogger geocodeFailed 按编译模式区分 context
原因：Release 包不应将用户输入的目的地城市名写入本地日志（隐私最小化原则）。
实现：`#if DEBUG` 记录完整城市名；`#else` 仅记录字符数（`city_len`），保留调试价值。

### 隐私政策补充位置访问声明
原因：App 使用 CLLocationManager（MapKit 定位按钮）和 CLGeocoder，原隐私政策 Section 6 声称"不收集位置信息"与实际不符，存在审核风险。
修复：Section 5 扩充为"本地通知与位置访问"，说明 MapKit 和 CLGeocoder 的使用方式；Section 6 删除位置信息条目；Section 7 补充 Apple MapKit/CLGeocoder 作为第三方服务。

### 运营方由 Luma Studio 改为 TIAN LYU
原因：以个人身份上线 App Store，统一使用个人真实姓名。

### Roadmap 远程 URL 更新为真实地址
原因：原代码内默认 URL 为占位符，导致所有用户只能看到内置默认数据，远程更新机制形同虚设。
修复：`RoadmapRemote.urlString` 更新为 `https://raw.githubusercontent.com/murphy-lyu/carry-ios/main/roadmap.json`；同步更新 `embeddedDefault` 与 `roadmap.json` 内容一致。

## 2026-05-29 日历同步

### CalendarManager 独立单例，不复用 EKEventStore.reset()
原因：`reset()` 本意是响应系统外部变更通知，在权限授权后调用会导致 `store.calendars()` 暂时返回空，使专属日历查找失败、事件静默丢失。
实现：`@MainActor` 单例，`EKEventStore` 持久持有，权限回调后直接使用无需 reset。

### 去重记录不随 toggle 关闭清除
原因：早期实现在 toggle 关闭时调用 `clearAddedIds()`，导致再次开启时重复添加同一行程。
实现：关闭同步只是停止新增，`UserDefaults` 中的已添加 ID 集合保留；仅当用户显式执行「重置日历同步记录」时才清除。

### 全天事件日期必须规范化到本地午夜
原因：`TripBundle.departureDate` 存储为 UTC 时间戳，直接作为 `EKEvent.startDate` 在跨时区场景下会偏移一天。
实现：`writeEvents` 用 `Calendar.current.dateComponents([.year,.month,.day])` 提取本地日期分量后重建，确保 `isAllDay` 事件落在正确日历日。

### carry:// URL Scheme 实现深链接
原因：打包提醒事件触发时用户需要快速跳回 App 查看清单，系统日历的 URL 字段可直接唤起。
实现：Info.plist 注册 `carry` scheme；`EKEvent.url` 写入 `carry://trip/{uuid}`；`CarryApp` 的 `.onOpenURL` 解析后写入 `NavigationRouter.pendingTripId`，由 `ContentView` 监听切换 tab 并推入对应行程。

### 打包提醒 notes 为创建时快照
原因：EventKit 事件创建后不会随 App 数据变化自动更新，notes 内容为写入时刻的清单状态。
实现：`packingListNotes(for:)` 按 section 分组生成纯文本，物品均显示数量（`× N`）；清单为空时不写 notes。

## 2026-05-29 Mac Catalyst

### Mac 布局：ZStack 全窗口而非 HStack 左右分割
原因：地球作为全窗口背景，功能面板浮于其上（参考 Tripsy 设计语言）。HStack 方案地球只占右半部分，缺乏层次感与视觉深度。
实现：`MacGlobePanel().ignoresSafeArea()` 铺满 ZStack 底层；NavigationStack 用 `.frame(width: 360)` + `padding(leading: 32, top: 24, bottom: 48)` + `RoundedRectangle(cornerRadius: 18)` + shadow 形成浮层卡片。

### HomeView.macBody 独立 Mac 专用 body
原因：iOS 的 `HomeView.body` 包含 globe 背景、底部 sheet 容器、stagger reveal 动画，这些在 Mac 上不适用（globe 已是全局背景，没有触摸手势，窗口常驻无需展开动画）。
实现：`#if targetEnvironment(macCatalyst)` 下新增 `macBody` 属性，使用 `List + .scrollContentBackground(.hidden)`，`onAppear` 直接设 `initialRevealProgress = 1.0`，跳过 iOS 的分阶段显现动画。
放弃：在原有 body 里加条件分支——会大量增加条件噪音，影响 iOS 代码可读性。

### Map Style 改为单次点击循环
原因：`MapStyleOption` 只有两个选项（Standard、Hybrid），Menu 需要"点击 → 展开菜单 → 再选"两步操作，增加摩擦。
实现：Button 点击时用 `allCases.firstIndex` + 取模计算下一个选项，直接更新 `mapStyleRaw`。

## 2026-05-30 Live Activity

### PackingActivityAttributes 放在 SharedSources 而非两个 target 各自定义
原因：ActivityKit 用类型的完整 Swift 名（含 module）匹配 ActivityConfiguration。两份副本分属 `Carry` 和 `CarryWidgetExtension` 两个不同 module，导致 `Activity.request()` 成功但锁屏无法渲染（系统找不到匹配的 widget configuration）。
实现：`SharedSources/PackingActivityAttributes.swift` 通过 pbxproj `PBXSourcesBuildPhase.files` 显式加入两个 target，两边编译出同一类型全名。
放弃：在 CarryWidget 保留副本（结构相同）→ module name 不同，ActivityKit 无法配对。

### 所有可变数据放入 ContentState，ActivityAttributes 只保留 tripId
原因：`ActivityAttributes` 是 ActivityKit 的静态标识，启动后不可修改。tripName / destinationCity / departureDate / totalItems 等用户可改的字段若放在 attributes，修改后锁屏不刷新。
实现：`ContentState` 包含 packedItems / totalItems / isCompleted / tripName / destinationCity / departureDate；`attributes` 只保留 `tripId`（真正不变的唯一标识符）。

### terminateAll() 先快照再异步 end
原因：`terminateAll()` 内用 `Task` 异步调 `end`，`Activity.request()` 在 Task 执行前已创建新 Activity；Task 执行时查询 `.activities` 会把新 Activity 一并 end，导致锁屏从不显示。
实现：调用 `terminateAll()` 时先 `let snapshot = Array(Activity<...>.activities)`，Task 只 end snapshot 里的旧 Activity，新建的不受影响。

### Live Activity 设置放二级页面而非 inline toggle
原因：inline toggle 没有上下文说明，用户不清楚"锁屏打包进度"是什么、会看到什么效果，开启率低。
实现：`LiveActivitySettingsView` 二级页面，包含引导截图 + 功能说明文案 + toggle；参考 Flighty 外层圆角容器、图片顶部贴合容器上沿的视觉风格。
放弃：在 toggle 下加 footer 文字 → 文字量大，Settings 页显得臃肿。

## 2026-05-30 日历设置 / 埋点

### 日历打包提醒改为独立子开关，与行程事件解耦
原因：「在日历里看到行程」和「出发前一天收到打包提醒」是两个独立的用户需求。原实现 `writeEvents()` 强制同时写入两类事件，想单独使用其中一个无法做到。
实现：`CalendarManager` 的 `writeEvents` / `addTrip` / `addAllUpcoming` 新增 `includePackReminder: Bool` 参数（默认 `true`，存量行为不变）；`SettingsView` 的 `CalendarSettingsView` 新增 `@AppStorage("calendar_pack_reminder_enabled")` 子开关（默认开启），主开关关闭时子开关和时间 picker 同时 dim；时间 picker 仅在两个开关均开启时可交互。`TripStore.commitDraft()` 从 UserDefaults 读取 `calendar_pack_reminder_enabled` 并透传。
放弃：完全平级的两个独立开关——对大多数用户而言行程事件是主功能，打包提醒是附加选项，主从层级更清晰且改动量更小。

### CarryLogger errorEvents 引用未定义 case 的编译隐患
原因：`errorEvents` 集合中引用了 `.apiTimeout` / `.apiError`，但这两个 case 从未在 `Event` enum 中定义，是潜在的编译错误。
修复：在 `Event` enum 中补充两个 case（`api_timeout` / `api_error`），并将其加入 `errorEvents`；同时新增 `coffeeSheetOpened` / `reminderScheduleFailed` / `sceneSelected` / `packingListShared` 4 个新业务埋点。

### 通知点击跳转由 PackReminderNotificationDelegate 统一处理
原因：原来通知点击只打开 App，用户需要自行找到行程再进打包清单，Live Activity 才触发；链路太长用户体验差。
实现：`PackReminderNotificationDelegate` 实现 `UNUserNotificationCenterDelegate`，`didReceive` 中解析通知 identifier 里的 tripId，写入 `NavigationRouter.pendingTripId` 直接跳转 → `PackingListView.onAppear` 触发 Live Activity。
约定：通知 identifier 格式为 `carry.trip.{uuid}.reminder.{uuid}`，`NotificationManager.tripId(fromIdentifier:)` 负责解析。

## 2026-05-31 HealthKit 经期预测

### 只接经期，不接用药 / 生理性别
原因：接 HealthKit 的固定成本（权限弹窗掉授权率、健康数据最高敏感等级合规、App Store 审核用途说明）是一次性大头，只有"经期预测行程是否重叠"这一个场景能产生手动选项替代不了的动态增量。用药拿到的是药名字符串，物品库只有笼统的 `Daily medication`，无处落地；生理性别唯一用途是"男性不推经期"，用 onboarding 让用户点一下比申请 Health 更轻更准、且无 `.notSet` 兜底与审核成本。
实现：授权请求只申请 `.menstrualFlow` 读权限。
放弃：用药 / 性别 / 过敏的 HealthKit 接入——摊薄收益、放大审核风险。

### HealthKit 调用全部收敛在 CycleInference
原因：健康数据是最敏感等级，调用面越散越难审计合规边界。
实现：`import HealthKit` 与所有 `HKHealthStore` 调用只允许出现在 `CycleInference.swift`；上层（ScenePicker / Settings）只通过 `isAvailable` / `requestAuthorization()` / `tripOverlapsPredictedPeriod()` 三个纯接口交互，不感知 HealthKit 类型。

### 不依赖授权状态分支，统一静默降级
原因：HealthKit 读权限的授予状态对 App 不可查询（Apple 隐私设计：query 永远成功，无权限返回空）。
实现：不写"已授权/未授权"分支；设备不支持 / 拒权 / 无记录 / 样本<2 / 不重叠 → 一律不 nudge，无提示无报错。开关 ON 但实际拒权时也不强行回退开关状态。
放弃：试图反推授权状态做 UI 分支——不可靠且违背平台设计。

### 显性 opt-in 开关 + 预测前移到新建流程（修正照抄 ClimateInference 的 gate）
原因：① 经期是敏感数据，需要用户显性同意而非静默惰性申请，且需要一个可发现的总开关。② 初版照抄 `ClimateInference` 把预测限定在 `.edit`/`.suggest`（已有行程）——但 climate 排除新建流程是因为依赖异步回填的 `countryCode`，而 cycle **只需日期**，新建当下 `TripInfo` 即有，限制纯属误植，导致推荐后置。
实现：设置 → 通用 →「经期提醒」二级页（`CycleReminderSettingsView`），`@AppStorage("cycleNudgeFeatureEnabled")` 默认关，开启时触发系统授权弹窗。`ScenePickerView.runCyclePredictionIfNeeded` 以该开关为总闸；新增 `tripDateRange` 跨 mode 统一取日期，`.create`/`.autoPack`/`.edit`/`.suggest` 全部生效。
放弃：inline toggle（参照 Live Activity 决策，敏感功能需二级页解释用途再授权）；以及"仅已有行程才预测"的后置体验。

### nudge 接到 ItemPickerView 而非（仅）ScenePickerView，并把气候 nudge 一并迁入
原因：排查时发现新建主流程是 `HomeView → TripInfoView → ItemPickerView(Smart picks) → PackingList`，**根本不经过 ScenePickerView**——`CreationRoute.scenePicker(TripInfo)` 只在枚举里定义、全工程无人 push，是死代码（`ScenePickerView(tripInfo:)` 的 `.create` 分支不可达）。ScenePickerView 仅在 editScenes / suggest（已有行程）出现。而经期 / 气候 nudge 原先只写在 ScenePickerView，导致两者在新建主流程里从未显示——经期是我初版的实现错误，气候是既有功能本身就有的同一缺口。
实现：在 `ItemPickerView.smartRecommendationView` 顶部加 `nudgeSection(titleKey:labels:)` 通用轻推区块，复用 `sceneChipGrid` 的选择/样式；气候用 `ClimateInference.inferredSceneKeys(主目的地码, 出发日)`（新建时目的地码由 `store.inferCountryCodes` 同步推断，不依赖异步回填），经期用 `CycleInference` 预测，均以 `cycleNudgeFeatureEnabled` / DEBUG 强制开关为闸。ScenePickerView 的两个 nudge 保留（覆盖编辑场景流程），两个界面行为一致。
遗留（已清理）：`CreationRoute.scenePicker` + `ScenePickerView` 的 `.create(TripInfo)` 分支为死代码，已删除（ContentView 移除 route case 与 destination 分支；ScenePickerView 移除 `Mode.create` 与 `init(tripInfo:)`）。

### ScenePickerView 气候 nudge 在 countryCode 未回填时回退到即时推断
原因：真机验证发现同一个泰国行程，ItemPicker 显示气候 nudge 而 ScenePicker(编辑/suggest) 不显示。根因是两者数据源不同：ItemPicker 用 `store.inferCountryCodes(目的地文字)`（本地即时），ScenePicker 用 `bundle.countryCode`（依赖异步 CLGeocoder 回填）。刚创建的行程 countryCode 尚未回填 → ScenePicker 气候 nudge 缺失。
实现：`nudgeSceneKeys` 中 `bundle.countryCode` 为空时回退到 `store.inferCountryCodes(for: bundle.destinationCity).first`，与 ItemPicker 同源，消除时序依赖。

### 场景推荐用"上移去重"而非"顶部分身"
原因：旧实现把推荐场景在顶部再渲染一份 chip，而它在固定分组里本就存在 → 同一场景重复展示；点顶部 chip 时它消失、底部那份亮起，选中态在两个一模一样的 chip 间"瞬移"，交互别扭，违反"点谁谁响应"。
实现：被推荐的场景（气候 + 经期）只在顶部「Suggested」区出现一次，通过 `promotedSceneLabels` 从 `groupedSmartScenesView` 的固定分组中排除；顶部 chip 选中后留在原地显示选中态，不消失、不瞬移。原则：一个场景 = 一个 chip = 一个位置。
放弃：原位高亮（经期在最后一组易被漏看）、智能预选（替用户对敏感的经期项做决定）。

### 二次添加（merge）的场景状态处理
原因：用户问"创建时选过的场景，二次添加时如何处理"。预设场景方面，`mergeItems` 按名去重 + smart preview 扣除已有物品，重选场景只补缺、不重复，也不会把用户删过的项加回来——故 merge 时场景从空开始（fresh）是正确的，无需带出。Nudge 方面，旧逻辑会在二次添加时重复推荐创建时已用过的场景（如泰国行程又推 Tropical），冗余。
实现：预设场景保持 fresh，不改。Nudge 在 merge 模式下通过 `alreadyAppliedSceneKeys`（读 `bundle.selectedSceneKeys`）排除创建时已应用的场景；但保留"创建后才开启经期提醒"等新相关推荐。merge 应用场景时改调 `store.addScenesAndMerge`（既有方法，union scene keys + mergeItems），把本次场景回写 `selectedSceneKeys`，使多次添加之间"不重复推荐"彻底闭环。

### ScenePickerView 场景推荐同步"上移去重"
原因：编辑场景 / suggest 走 ScenePickerView，仍是旧的"分身式"（顶部推荐 + 固定分组重复 + 选中态瞬移），与 ItemPicker 已修好的体验不一致。
实现：`SceneGroupSection` 加 `excludedLabels` 参数（过滤已上移标签，全空则整组隐藏）；ScenePickerView 以 `promotedSceneLabels`（气候 `climateSuggestedLabels` + 经期 `periodNudgeLabel`，均不按已选过滤）驱动顶部统一 `nudgeSection(titleKey:labels:logAccepted:)`，chip 点击切换且留在原地。删除旧的 `nudgeSceneKeys` / `showCycleNudge` / 两个独立 nudge section。两个场景界面行为一致。

### 空清单创建直达正式清单页，避免多余预览与死循环
原因：允许"空选择创建"后，会落到新建预览（isNewTrip:true）——但该界面无内容可看、无 ⋯ 菜单，且点 Add item 回到 Add items、再不选又会卡住，形成空跳转循环。且预览页空状态文案"use the ⋯ menu"在此语境无对应 UI。
实现：`confirmSelection` 创建模式 `sections.isEmpty` 时走 `finalizeEmptyTrip`（复刻预览页 "Save list"：`commitDraftTrip` + `updateCountryCode` + `router.path = NavigationPath([id])` + 通知授权），跳过预览直达正式清单页（isNewTrip:false，有 ⋯ 菜单，原空状态文案天然衔接）。非空创建仍走预览。
放弃：为新建预览单独写一条不提 ⋯ 的空状态文案（治标不治本，多余跳转仍在）。

### Add items 确认按钮按模式区分可点性
原因：右上确认按钮原先恒显可点，但无选择时 `confirmSelection` 因 `guard !sections.isEmpty` 静默 return → 死点击。
实现：`.disabled(!isCreateMode && !canConfirm)`——创建模式始终可点（允许空清单，见上），追加模式无选择时置灰，给诚实反馈。
