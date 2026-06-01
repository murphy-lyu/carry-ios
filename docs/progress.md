# 项目进度

## 最后更新
2026-06-01

## 上次改动摘要（Settings 信息架构优化 · 2026-06-01）

- **「通用」分区超载拆分**：原「通用」一张卡塞了 6–7 行且混了两类心智（"App 长什么样" + "Carry 在哪儿提醒/出现"）。拆为两组——**个性化**（外观 · 应用图标 · 语言）+ **提醒与显示**（日历 · 灵动岛 · 小部件 · 经期）。每卡降到 3–4 行，扫读成本降低。纯层级调整，行/跳转/功能与 `#if`、`CycleInference.isAvailable` 条件全部原样。
- **个性化组内换序**：App Icon 移到语言之前——外观+图标都是"App 视觉外观"放一起，语言（跳转 iOS 系统设置、会离开 App）置于该组最末。
- 本地化：新增 `settings.section.personalization` / `settings.section.reminders_display` × 9 语言（zh-Hant 用台湾术语「個人化」）；删除已无引用的 `settings.section.general`。
- 同会话另：小部件引导页（设置新增「小部件」入口，单张预览图占位 `WidgetPreview` + 版本无关的"长按主屏幕添加"说明，不做分步）；「编辑分类」空状态用 `containerRelativeFrame(.vertical)` 在可视区垂直居中。

## 上次改动摘要（日期选择器视觉优化 · 2026-06-01）

- **底部「先规划，日子以后再定」入口**：从 TripInfoView / EditTripView 的内联链接移进 `TripDateRangePickerSheet` 底部（`.safeAreaInset`），两处内联入口代码及占位注释全部删除。底部栏背景用 `footerBlendColor` 与 `CarrySubtleBackground` 渐变底色精确匹配（light 暖白 / dark 深色），0.5pt 极淡发丝线替代硬 Divider，无割裂感。
- **清除日期后日期框文案**：`tripdates.unset` 改为「日子待定 / Dates to come」× 9 语言，与首页行程卡无日期标签完全一致，产品内表述统一。
- **日历空白修复**：修复 `LazyVStack` + 可变高度月份 + `scrollTo` 跳中部时视口下方 realize 留白问题（之前是底部「Plan now」容器被 GeometryReader 死循环撑高所致，确认根因后回退无关改动，保持原 241 月 LazyVStack 不变）。
- **日期区间高亮换行圆角**：换行处(行尾/行首)背景形状加 `isRowStart`/`isRowEnd` 判断，用 `UnevenRoundedRectangle` 分别圆角；所有"端点"侧加 `endpointEdgeInset` 保证形状宽度一致；`maxCornerRadius` 18→100（SwiftUI 自动 clamp 到半高=完美半圆），与端点实心圆视觉完全一致。

## 上次改动摘要（无日期「规划中」行程 · 2026-06-01）

- 允许创建不设出发/返程日期的「规划中」行程（参考 Tripsy），单独分组、补日期可"转正"、清空日期可"退回"。spec：`specs/dateless-planning-trips.md`。
- **模型/数据**：`TripBundle.isDateless`（+ `TripInfo.isDateless`）；保持单一 SchemaV1 + SwiftData 自动轻量迁移（加字段，零数据风险）；`BackupTrip.isDateless`（可选，兼容旧备份）。⚠️ 曾误加 SchemaV2（models 仍指向同一 live 类）导致 "Duplicate version checksums detected" 启动崩溃，已改回单版本——多版本需冻结旧模型快照，本项目无线上数据无需如此。
- **降级守卫（防 bug 关键）**：所有读 `departureDate` 的地方先 `guard !isDateless`——`countsAsVisited`（防占位日期误判到访）、首页 upcoming/past 分区（防自己跳到 Past）、提醒、Live Activity、日历、Widget 快照、Nearest Trip、天气、经期/气候 nudge（`tripDateRange` 返回 nil 自动跳过）。
- **创建**：TripInfoView 加次级按钮「暂不设置日期」。**首页**：新增「规划中」分区（Upcoming 与 Past 之间），卡片隐藏日期行、显示"规划中"标签。**编辑**：EditTripView 支持补日期转正 / 清空日期退回，`updateTripInfo` 在退回时取消提醒、结束 Live Activity。
- 复制行程保留 `isDateless`。本地化新增 `home.planning` / `tripinfo.skip_dates` / `trip.card.no_dates` / `edittrip.set_dates` / `edittrip.clear_dates` × 9 语言。
- 通过 iPhone 17 Pro simulator build。**已知小限制**：退回时旧日历事件不自动移除（CalendarManager 无删除 API）。**待办**：模拟器/真机全流程验收（建无日期→不进 upcoming/past/到访/widget/提醒/天气；转正副作用到位；退回撤销；备份还原与复制保 isDateless）。

## 上次改动摘要（预览页 Toast → 内容入场 + 件数 inline · 2026-06-01）

- **去掉会"跳"的 Toast**：物品清单预览页（`PackingListView(isNewTrip:true)`）顶部「已添加 N 件」Toast 原本和列表是 `mainContent` 同一 VStack 的兄弟节点、参与布局，出现/消失时把列表顶下去又弹回。已移除 Toast 及其死代码（`toastBanner`/`showToastMessage`/`showToast`/`toastVisible`/`toastText`）。
- **改用"内容入场"作确认**：进入预览时各分类 chips 按分区交错淡入+上浮（`easeOut 0.34s`，每区 delay 50ms，惊喜区/场景卡稍晚一拍），由 `didRevealPreview` 在 onAppear 触发。"物品落进清单"本身即确认，零浮层、零位移。
- **顶部常驻件数行**：新增 `previewSummaryRow`（实时 `totalCount`），保留旧 Toast 唯一信息量（件数），固定在布局里不闪现。新增本地化 key `packing.preview.summary` × 9 语言（无复数风格，沿用 `added_count`）。
- **死代码清理**：`initialItemCount` 透传链原仅 Toast 使用，已移除——`CreationRoute.packingList` 去掉该参，连带 ContentView / ItemPickerView（2 处）/ PackingListView 同步。
- 通过 iPhone 17 Pro simulator build。

## 上次改动摘要（到访国家/地图点亮按"出发次日"判定 · 2026-06-01）

- **未出发行程被点亮修复**：地图点亮国家/城市、首页 Trip Overview「到访国家数」原用裸 `trip.departureDate <= Date()`，而 `departureDate` 存的是出发当天 00:00（`TripInfo`），导致"今天出发但尚未启程"的行程一过零点就被点亮/计数（用户反馈：未出发的希腊雅典/圣托里尼被点亮）。
- **修复（根因 + 去重）**：在 `TripBundle` 新增共享判据 `countsAsVisited`（`startOfDay(now) > startOfDay(departureDate)`，即**出发日期次日起**才算到访），替换全部 5 处散落判据——HomeView 的 `visitedCountriesCount` / `visitedCities` / `visitedCountries` + `MacGlobePanel` 的 2 处。与工程其余按天比较（CalendarManager / LiveActivityManager）保持一致。
- **规则选择**：采用"出发次日"而非"出发当天"——到访应代表确已身处当地，出发当天可能仍在途。如需改回"出发当天"，将判据的 `>` 改为 `>=` 即可。语义上「跨国旅」这类当天/在途行程仍留在 UPCOMING 列表，但不计入到访，两套语义各自正确。
- **模拟器确定性验证通过**：含一笔今天（6/1）出发的多城行程「跨国旅」，到访国家数 6 → 3（剔除仅由该行程贡献的 GB/AT/JP），符合预测。

## 上次改动摘要（ScenePicker 去重同步 + merge selectedSceneKeys 闭环 · 2026-06-01）

- **ScenePickerView 同步"上移去重"**：编辑场景 / suggest 界面也改为"一个场景一个位置"。`SceneGroupSection` 新增 `excludedLabels`（过滤已上移标签、全空隐藏整组）；顶部用统一 `nudgeSection`，chip 选中后留原地、不瞬移。删除旧 `nudgeSceneKeys`/`showCycleNudge`/分身式 section。现在两个场景界面（ItemPicker / ScenePicker）行为一致。
- **merge 回写 selectedSceneKeys 闭环**：ItemPicker merge 路径由 `mergeItems` 改调既有 `store.addScenesAndMerge`，把二次添加时选的场景 key 也写入 `selectedSceneKeys`，使多次添加之间"不重复推荐已用场景"彻底闭环。
- 验证：`NSHealthShareUsageDescription` 9 语言已确认全部打进编译产物各 `.lproj/InfoPlist.strings`（授权弹窗按设备语言显示，非缺失）。
- 通过 iPhone 17 Pro simulator build。

## 上次改动摘要（深链进入返回首页空列表修复 + 足迹文案 · 2026-06-01）

- **首页行程卡片空列表修复**：从 Widget（4×1 / 1×1）、Quick Action、本地通知深链冷启动进入某行程后，返回首页时 upcoming 卡片不显示（只剩 Trip Overview 头卡）。根因：`HomeView.triggerUpcomingReveal` 的 +0.28s 延迟闭包有 `guard router.path.isEmpty`，冷启动时深链已把 path 推成非空 → 揭示被永久跳过 → `didRevealUpcoming` 卡在 false → upcoming 卡片停在 opacity 0。修复：在 `sheetContent` 的 `onReceive(router.$path)` 的 `path.isEmpty`（返回首页根）分支补一次揭示（已 true 时不重复触发，安全无回归）。Widget/通知/Quick Action 三类入口共用同一导航链路，一处修复全覆盖。**真机验证通过。**
- **时序竞争复现说明**：此类冷启动深链 bug 在模拟器复现不出来（`simctl openurl` 有「Open?」确认框延迟送达；`defaults` 注入与真机 scene 时序不符），须真机验证——已记入开发者 memory。
- **Quick Action「足迹」文案**：中文环境（zh-Hans / zh-Hant）由「足迹/足跡」改为「我的足迹/我的足跡」（保留繁体「跡」字），其余 7 种语言不变。`"Footprint"` key 同时被 Quick Action 标题与 Siri shortcut shortTitle 共用，两处同步生效。

## 上次改动摘要（场景推荐去重重构 + Add items 交互打磨 · 2026-05-31）

- **场景推荐"上移去重"**：被推荐场景（气候 + 经期）只在 ItemPicker 顶部「Suggested」区出现一次，经 `promotedSceneLabels` 从固定分组排除；顶部 chip 选中后留在原地显示选中态，消除旧实现的"重复展示 + 选中态在分身间瞬移"的别扭交互。
- **ScenePicker 气候 nudge 时序修复**：`countryCode` 未回填时回退到 `store.inferCountryCodes(目的地文字)`，与 ItemPicker 同源，解决"同一泰国行程 ItemPicker 有气候 nudge、ScenePicker 没有"的不一致。
- **空清单创建直达**：创建流程啥都不选点确认 → `finalizeEmptyTrip` 直接提交行程并进正式清单页（isNewTrip:false，有 ⋯ 菜单），跳过无内容的新建预览，消除 Add item↔Add items 空跳转循环。
- **确认按钮按模式可点性**：创建模式始终可点（允许空清单），追加模式无选择时置灰，消除死点击。
- **merge 去冗余**：二次添加时通过 `alreadyAppliedSceneKeys` 排除创建时已应用的场景 nudge；预设场景保持 fresh（mergeItems 已按名去重）。
- **死代码清理**：删除 `CreationRoute.scenePicker` + `ScenePickerView.Mode.create` / `init(tripInfo:)`（ContentView + ScenePickerView）。
- 全部通过 iPhone 17 Pro simulator build + 真机视觉验证（设置入口、Health 授权、两 nudge 同屏、空创建直达均确认）。
- **待办**：ScenePickerView 的场景推荐去重尚未同步（编辑场景流程仍是旧的分身式）；merge 回写 `selectedSceneKeys` 的边界闭环未做。

## 上次改动摘要（nudge 接到正确界面 + 气候 nudge 迁入 · 2026-05-31）

- **修正接错界面**：真机验证发现新建主流程是 `TripInfoView → ItemPickerView(Smart picks) → PackingList`，不经过 ScenePickerView（`CreationRoute.scenePicker` 是死代码）。原先经期/气候 nudge 只在 ScenePickerView，新建时从不出现。
- 在 `ItemPickerView.smartRecommendationView` 顶部新增通用 `nudgeSection(titleKey:labels:)`：气候 nudge（`ClimateInference`，主目的地码同步推断）+ 经期 nudge（`CycleInference`），复用 `sceneChipGrid`，以 `cycleNudgeFeatureEnabled` / DEBUG 强制开关为闸。
- **气候 nudge 一并迁入**：既有气候 nudge 同样只在 ScenePickerView、新建流程从未显示，本次顺带补到 ItemPickerView，消除"有经期 nudge 没气候 nudge"的不一致。ScenePickerView 两个 nudge 保留（编辑场景流程）。
- 遗留：`CreationRoute.scenePicker` + ScenePickerView `.create` 分支为死代码，已 spawn 独立任务清理。
- 通过 simulator build + 真机视觉验证（设置入口、Health 授权弹窗、设置页均确认）。

## 上次改动摘要（经期提醒：显性入口 + 预测前移 · 2026-05-31）

- **交互重构**：经期功能改为**设置内显性 opt-in**。设置 → 通用 → 「经期提醒」→ `CycleReminderSettingsView`（新文件），开关 `cycleNudgeFeatureEnabled`（默认关）。开启时触发 HealthKit 系统授权弹窗（`CycleInference.requestAuthorization()`）。页面含功能说明 + 隐私脚注（仅本机/不存储/不上传/可随时关）。仅 `CycleInference.isAvailable` 的设备显示该入口。
- **关键修正**：预测从"仅 `.edit`/`.suggest`（已有行程）"**前移到全部 mode（含 `.create`/`.autoPack`）**。早期照抄 `ClimateInference` 把新建流程排除是错的——climate 排除是因依赖异步回填的 `countryCode`，而 cycle 只需日期，新建当下 `TripInfo` 即有。新增 `tripDateRange` 跨 mode 统一取日期。现在用户新建行程填完日期、进场景选择就能被推荐，不再后置。
- 预测总闸：`runCyclePredictionIfNeeded` 先过 `cycleNudgeFeatureEnabled`，关则完全不碰 HealthKit。
- `CycleInference` 新增 `isAvailable` / `requestAuthorization()` 公开 API。
- 本地化：`settings.cycle.entry/toggle/description/privacy` × 9 语言。
- DEBUG 强制开关（`debugForceCycleNudge`）保留，短路在总闸之前，不受 opt-in 影响。
- 通过 iPhone 17 Pro simulator build。

## 上次改动摘要（HealthKit 经期预测轻推 · 2026-05-31）

- 新增 `CycleInference.swift`：读 HealthKit Cycle Tracking（仅 `.menstrualFlow` 读权限），中位数外推周期，预测行程区间 `[departureDate, +days]` 是否赶上经期。全部本地推断，不持久化/不上传/不写回；HealthKit import 收敛在此一处。
- `ScenePickerView` 复用现有 nudge 机制：新增独立 `cycleNudgeSection`（贴心标题 `scenepicker.nudge.cycle.title`，9 语言），命中且未手动选中时在场景选择上方轻推「🌸 On / near period」chip。仅 `.edit`/`.suggest` 模式跑预测（`.task` 异步，每生命周期一次）。读不到/无权限/样本<2/不重叠 → 静默降级为现状。
- 工程：`Carry.entitlements` 加 `com.apple.developer.healthkit`；`Info.plist` 加 `NSHealthShareUsageDescription`（聚焦"读经期、仅本地、用于打包提醒"）。HealthKit.framework 走 clang autolink，无需改 pbxproj。
- 埋点：`CarryLogger.Event` 新增 `cycleNudgeShown` / `cycleNudgeAccepted`（只记交互，不记任何健康数据），调用点已接。
- **决策**：明确只做经期，不接用药（物品库只有笼统 `Daily medication`，精确药名无处落地）、不接生理性别（onboarding 让用户点「男/女」更轻更准、无 `.notSet` 兜底与审核成本）。详见 `specs/healthkit-cycle-nudge.md`。
- 已通过 iPhone 17 Pro simulator build。**待办**：真机验证经期预测；隐私政策补"读 HealthKit 经期、仅本地不上传"一句（中英 + PIPL 版）；审核用途文案上线前定稿。

## 上次改动摘要（Calendar Sync 禁用态视觉强化 · 2026-05-31）

- 主开关 `Add Trips to Calendar` 关闭时，从属的 `Day-before Packing Reminder` / `Reminder Time` 原来仅用整行 `opacity(0.45/0.5)` 表达禁用 —— 信号太弱，且 ON 态开关在深色 tint 下 `.disabled()` 不变色，出现「文字灰但开关仍黑亮」的割裂。
- 修复为三重一致信号：标题文字切 `tertiaryLabel`；开关 tint 禁用时切 `systemGray4`（`.disabled()` 不改 tint，须手动控制，否则 ON 开关不灰）；保留 `.disabled()` + `allowsHitTesting(false)`。helper：`rowTitleColor(enabled:)` / `toggleTint(enabled:)`。

## 上次改动摘要（日历行程图标 + App Icon 命名 · 2026-05-31）

- 日历行程事件图标 🗺️ → ✈️（旅行通用符号，与打包提醒 🧳 配对）。
- App Icon 命名对称：`Travel Buddy` → `Travel Pup`（与 Travel Cat 对称、更贴图）。

## 上次改动摘要（Settings tab bar 延迟修复 · 2026-05-31）

- **根因**：Settings 二级页返回时底部 tab bar 恢复有延迟，而 Trips 链路（首页↔物品清单）及时。原因是两条链路 tab bar 控制方式不同：
  - Trips：`.toolbar(.hidden)` 挂在 **NavigationStack 外层**，`router.path.isEmpty` 状态驱动 → pop 时 path 立即变空，tab bar 同步恢复。
  - Settings：`.toolbar(.hidden)` 挂在**每个二级页自身** → 等二级页 dismiss 动画走完才解除，慢半拍。
- **修复**（对齐 Trips 的外层 + 状态驱动）：
  - ContentView 给 Settings 的 NavigationStack 加 `settingsPath`，外层 `.toolbar(settingsPath.isEmpty ? .visible : .hidden)`。
  - `settingsNavigationRow` 由 `NavigationLink(destination:)` 改为 `NavigationLink(value: SettingsRoute)`；二级页解析统一放 SettingsView 内的 `navigationDestination`（private 视图照常访问）。
  - 删除 6 个二级页各自的 `.toolbar(.hidden, for: .tabBar)`。
  - Mac sheet 与 Preview 同步补 `path` 参数。
- **Quick Actions 标记更新**：真机确认图标菜单只显示 3 项（iOS 16+ 自动合并自建 `UIApplicationShortcutItem` 与 `AppShortcutsProvider`，不重复），decisions.md 去掉「待确认」。

## 上次改动摘要（App Icon 切换 + Live Activity 窗口 · 2026-05-31）

- **App Icon 切换重新启用**：此前因图标未就绪被注释隐藏（`9c2b790`），现恢复。
  - 改用 **Asset Catalog 单 1024 方式**（替代旧的 Info.plist `CFBundleAlternateIcons` + bundle 根裸 PNG @2x/@3x）：`pbxproj` 设 `INCLUDE_ALL_APPICON_ASSETS = YES`，删除 Info.plist 旧 `CFBundleIcons` 声明。
  - 图标：Default / Travel Cat（旅行小猫）/ Travel Buddy（旅行小狗），每个 `<id>.appiconset`（系统切换用）+ `<id>Preview.imageset`（app 内缩略图，因 iOS 禁止 `UIImage(named:)` 读 app icon 资源）。
  - `AppIconView`：iconOptions 重命名为顶层 `appIconOptions`，新增 `currentAppIconDisplayName()`；清理旧 10 图标占位逻辑。
  - Settings：App Icon 入口移到 Calendar Sync **上方**，右侧显示当前图标名（onAppear / 前台激活刷新）。
  - 文案：`icon.dog.*` / `icon.cat.*` × 9 语言。
- **Live Activity 激活窗口**：`LiveActivityManager.startIfNeeded` 新增上限——仅出发前 `activationWindowDays`（7）天内且未出发才激活。此前打开任意未出发行程（哪怕几个月后）的清单都会在锁屏常驻活动，无紧迫性。
- **Settings 状态显示约定**：Calendar Sync 显示 On/Off（真状态，有用）；Live Activities 不显示（开≠在用，避免误导）；App Icon 显示当前图标名（精致，桌面虽可见但视觉对称）。

## 上次改动摘要（Quick Actions + 桌面 Widget · 2026-05-31）

- **主屏幕 Widget**（已实现，数据已通、视觉定稿）：即将出发行程 + 打包进度，Small / Medium。
  - 数据：App Group `group.com.murphy.carry`（两 target 已配 capability）+ UserDefaults JSON 快照（`WidgetTripSnapshot`），不动 SwiftData 容器、无迁移风险；主 App 在 launch / 进后台时写快照 + `reloadAllTimelines`。
  - UI：header 式布局（suitcase 图标 + UPCOMING 标签）/ 行程名（优先 `name`，与 App 卡片一致）/ 倒计时 / 进度（Small 进度条 + 右侧百分比；Medium 进度环 58pt）；Medium 含第二行程；无行程时空状态降级。
  - 倒计时按天数分支（today / tomorrow / %d days left）绕开各语言复数规则。
  - spec：`specs/home-screen-widget.md`
- **主屏幕图标 Quick Actions**（已实现，待真机验证）：长按图标菜单，3 动作（New Trip / Nearest Trip / Footprint）。`CarryQuickAction` + `CarryAppDelegate` / `CarrySceneDelegate` 接冷 / 热启动回调，写 `carry_shortcut_action`，复用 ContentView 既有 `UserDefaults.didChangeNotification` 监听分发。
  - 两套并存是正确设计：`UIApplicationShortcutItem` 驱动长按图标菜单，`AppShortcutsProvider` 驱动 Siri/Spotlight/Shortcuts App，系统层面完全独立，不重复。
  - spec：`specs/home-screen-quick-actions.md`
- **i18n 对齐**：`home.upcoming`（首页分区 / 统计标签）与 widget `widget.header.upcoming` 统一为地道译法。此前首页 de/es/fr/ja/ko/pt-BR 仅留英文 "Upcoming"，本轮两边补全并对齐（9 语言）。
- **App Group / 工程**：新增 `Carry/Carry.entitlements` + `CarryWidgetExtension.entitlements`（`group.com.murphy.carry`），pbxproj 设 `CODE_SIGN_ENTITLEMENTS`；清理 Xcode 生成的孤儿 entitlements 与 .orig/.bak 临时文件。

## 上次改动摘要（上架前质量收尾 · 2026-05-30）

- **Home Sheet 修复**：快速上滑触发 spring overshoot 时 sheet 底部露出 MapKit（fallback 版 `CarryBottomSheet.SheetViewController`）。修复为 `containerView` 向下延伸 400pt + 设 `CarrySubtleBackground` 底部色背景，`hostingView` 内容高度不变；overshoot 露出的是延伸背景而非地图。坑：`HomeView` 有 fallback / ultimate 两个 sheet 实现，默认 fallback，详见 `docs/home-sheet-debug-playbook.md` §6/§7
- **中国大陆合规**：删除未使用的 `countries-110m.geojson`（含台湾独立国家描述，审核风险）；`isChinaStorefront` 提升为 `SceneItemMap.swift` 顶层函数（`SKPaymentQueue` storefront 检测，Debug 可覆盖）；`generatePackingSections` 新增 `destinationCodes` 参数，大陆 storefront + HK/MO 推「港澳通行证」、+ TW 推「台湾通行证」并移除护照；`TripStore` 新增 `inferCountryCodes` / `inferIsInternational`，geocoding 完成前用本地城市表同步推断消除护照误推；HK/MO/TW 归并改为仅大陆 storefront 生效。详见 CLAUDE.md「政策合规约定」
- **埋点补全**：CarryLogger 新增 6 个 Event case（`coffeeSheetOpened` / `reminderScheduleFailed` / `sceneSelected` / `packingListShared` / `apiTimeout` / `apiError`），修复 `errorEvents` 集合引用未定义 case 的编译隐患；8 处此前已定义但从未调用的埋点补齐调用（`notificationTapped` / `siriShortcutExecuted` ×3 / `reminderScheduled` / `mapOpened` / `mapStyleChanged` / `coffeeSheetOpened` / `sceneSelected` / `packingListShared`）
- **App Store 合规审计**：确认 `NSLocationWhenInUseUsageDescription` 已配置于 Build Settings、Privacy Manifest 完整、消耗型 IAP 无需恢复购买；`release-checklist.md` 补充 3 条 App Store Connect 操作待办
- **日历设置解耦**：行程日历事件与出发前打包提醒拆分为两个独立开关；`CalendarManager.addTrip` / `addAllUpcoming` / `writeEvents` 新增 `includePackReminder` 参数；`TripStore` 透传 `calendar_pack_reminder_enabled` UserDefaults 键；`SettingsView` 新增子开关，时间 picker 联动两个开关
- **文案优化**：`settings.calendar.add_trips` 缩短为「Add Trips to Calendar」；`settings.calendar.packtime` 从重复说明改为「Reminder Time」；9 种语言同步

## 上次改动摘要（V1.0 收尾 · Live Activity 完整集成）
- `PackingActivityAttributes` 移至 `SharedSources/`，两个 target 共用，解决 ActivityKit 类型标识符不匹配
- 修复 `terminateAll()` async Task 竞争 bug：调用前先快照 `.activities`，防止 end 掉刚建的新 Activity
- 所有 trip 动态数据（tripName / destinationCity / departureDate / totalItems）移入 `ContentState`，实现实时刷新
- 补全 TripStore 全部 `update`/`end` 触发点（addItem/removeItem/removeSection/removeTrip/updateTripInfo/mergeItems 等共 9 处）
- 通知点击自动跳转行程打包清单（`PackReminderNotificationDelegate`）
- `LiveActivitySettingsView` 二级页面（引导图 + 说明文案 + 开关）
- 设置项标签改为「实时活动 / Live Activities」（Apple 官方译名，9 种语言）
- Widget Extension 新建 `Localizable.xcstrings`，消除硬编码中文
- 所有 imageset 冗余 1x/2x 文件清理，节省约 9MB

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
