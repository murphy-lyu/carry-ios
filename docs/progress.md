# 项目进度

## 最后更新
2026-06-07

## 上次改动摘要（物品行拖拽重排换 UICollectionView 原生 interactive movement · 2026-06-07）

> 分支 `feat/smooth-drag-reorder`，**未合并**。spec：`specs/smooth-drag-reorder.md`。全程编译绿 + 模拟器实跑验证。

- **根因**：旧实现（已删的 `LongPressDragBridge` + `row/contentRow` 拖拽视觉）被拖行从不跟手——只加 `scaleEffect`，靠 `translation/44` 量化跳格且拖拽中反复写 SwiftData。机制错，非参数问题。
- **方案（用户选 B：整页换 UICollectionView）**：新增 `Carry/Views/ReorderableItemCollection.swift`（`UIViewRepresentable` 隔离 UIKit），正常模式物品行改用 `UICollectionView` compositional list layout + diffable data source + 原生 `beginInteractiveMovementForItem`/`updateInteractiveMovementTargetPosition`/`endInteractiveMovement`。被拖行快照贴手指 1:1 跟随，其它行 rubber-band 让位，**松手经 `reorderingHandlers.didReorder` 只提交一次** `store.reorderItems`。
  - 行内容（`PackingItemRow`/内联编辑/add-item/section header/DestinationInfo）全部经闭包从 `PackingListView` 传入、`UIHostingConfiguration` 承载，**样式/本地化/动画零重复**。
  - 内容刷新（勾选/数量/名称）**不手动 reconfigure**——`PackingItem` 是 SwiftData `@Model`（Observable），属性变化自动刷新宿主 SwiftUI；只在"进/出编辑态"那一行 reconfigure（切 `PackingItemRow`↔`InlineEditRow`）。
  - 内联编辑改为 `InlineEditRow`（自带 `@FocusState`，新 cell `onAppear` 聚焦——编辑行永远是新插入 cell，可靠）；删旧 `@FocusState focusedItemId` / `isAdvancingEdit` 全套残留管线。
  - DestinationInfo 作为 collection 顶部**不可重排、随列表滚动**的第一个 section（用户确认保持原滚动行为）。
  - 跨 section 拖拽**夹断**：手势级 Y 夹断（把目标 Y 限制在起点 section 首/末行之间，比 `targetIndexPathForMoveFromItemAt` 委托可靠）。section 重排（独立编辑视图）/ 新建预览 / 跨 section 拖拽**不动**。
- **拆分**：`packingList` → `previewPackingList`（新建模式，留旧 List）+ `normalPackingList`（走新 collection）。删 `row`/`contentRow`/`editableRow`/`moveItems`/`LongPressDragBridge` 及 `draggingItemId` 等 4 个死 @State。净 −258/+125 行（PackingListView）+ 新文件 357 行。
- **模拟器实测通过**：无崩溃（修了一处 header elementKind 不匹配的 SIGABRT）、布局对齐、长按 1:1 跟手重排提交并持久化（有/无 info section 均正确）、跨组夹断生效、内联新增提交、点击别处提交编辑、点击勾选经 Observable 自动刷新。修了一处 info-section 在时 `lastReorderableRow` 的 off-by-one。

**待办**：真机验收（拖拽手感/掉帧观感、swipe 删除视觉、Dark Mode、9 语言）；确认无回归后合并 `main`。

## 上次改动摘要（样式定稿收尾：精简样式 + 退役 Sheet fallback + 单一强调色 · 2026-06-07）

> 接上一条同日工作。本轮"定稿 + 清理"三件事 + 合并上线,全程编译绿。**已合并到 `main` 并推送**(`d033a8f`,feature 分支整包快进合并)。

- **首页样式精简(保留 2·Map 默认 + 4·Map 实验,删其余)**:
  - `HomeCardStyle` 4 个 → **2 个**(`.featured` / `.glass`);删 `.accent`(1·Plain)/`.hue`(3·Thumb)。
  - 连带删一批死代码:`HomeStylePalette`(随机渐变兜底,无人引用)、`bannerCard`/`bannerChip`/`bannerLeadChipText`、`isHero`/`isBanner`/`isFeatured`/`countdownText`/`daysToDeparture`;`cardSurface` 化简为单一 `cardFill`;`BackgroundImageStore.croppedImage`(+ `croppedCache`/`round4`,展示已改走 `PositionedImage`)。
  - 删 6 个无引用 xcstrings key(`trip.countdown.today/.tomorrow/.days_left`、`trip.background.choose/.hint/.title`)。
- **退役 FX Sheet fallback**:删 `CarryBottomSheet.swift`(无缩放保底)+ `SheetFeatureFlag.swift`(`SheetVariant`)+ Dev Options「Sheet Implementation」开关 + 5 个相关 key;`HomeView` 直接调 `CarryBottomSheetFX`。`specs/sheet-fallback.md` 标记「已退役」,其"行为要求"仍是 FX 的有效规范。
- **单一强调色「烟蓝」**(决定:不做用户可见主题切换,见 decisions):
  - 删 `ThemeAccent`(11 个备选)+ `toggleTint` 环境键(其存在理由 classic 过渡特例已不在)+ Dev Options「Accent Color」选择器。
  - 新建 `CarryAccent`(烟蓝 #5B7A96 / 暗 #7A9CB8,明暗自适应);**SwiftUI 层** `.tint(CarryAccent.color)` 全局注入;**UIKit 层** `UIWindow.appearance().tintColor = CarryAccent.uiColor`——覆盖 SwiftUI tint 够不到的系统组件(`.confirmationDialog`/`.alert`/上下文菜单/导航栏)。所有 `.tint(toggleTint)` → `.tint(CarryAccent.color)`。
  - **有意反转**之前"Toggle 用 .primary 黑白 / 无品牌色"的决策——前提(无品牌色)已变。
- **Roadmap 更新(已推 main、线上生效)**:`iCloud 同步` planned → **done**(挪到"已上线";实际 CloudKit 接入待明天开发者账号到位再做,模型层已满足 CloudKit 约束);新增 `行程规划` 标 **in_progress**(蓝色水波纹);`从日历导入行程` in_progress → planned。roadmap.json + `RoadmapView.embeddedDefault` 同步改。
- **合并上线**:整套首页改版(照片卡 + 背景图 + 烟蓝强调色 + 退役 fallback + 备份 + Quick Actions + roadmap + 文档)已 `--ff` 合并到 `main` 并推送。

**待办**:
- 真机统一验收(单一烟蓝在亮/暗 + 系统弹窗/导航栏的观感;Toggle 烟蓝对比度)。
- **iCloud 同步实际接入(明天账号到位)**:`ModelContainer` 改 CloudKit 配置 + 双机实测 + 定背景图(沙盒文件不随 SwiftData 同步)的缺口。
- 4·Map 仍为实验(不上线);首页若最终只留 2·Map,可再删 4·Map + `HomeStyleFlag.swift` + Dev Options 切换器。
- 分支合并前回归 + 背景图埋点(下同)。

## 上次改动摘要（首页改版：行程背景图 + 卡片样式 + 备份纳入 · 2026-06-07）

> 全部在 `feature/home-ui-redesign` 分支,**未合并**。首页卡片样式仍是 Dev Options 可切的实验(1·Plain / 2·Map / 3·Thumb / 4·Map),本轮把"行程背景图"这条功能从 0 做到可用,并定下方向:**2·Map(照片铺满原始卡)设为默认**。

- **行程背景图(Phase 1,本地上传)**:
  - **入口**:行程详情页右上「…」菜单**单项随状态切换**——无图=「上传背景图」、有图=「移除背景图」。**不放创建流程**(那时还没到目的地、没有照片),**编辑页入口也撤掉**(避免两处);曾在清单顶部放过封面块,因破坏打包界面而移除。
  - **选图 + iCloud 健壮加载**:PHPicker(`.compatible`),`loadObject` 失败回退 `loadDataRepresentation`(触发 iCloud 下载),下载期一个 loading 蒙层兜住。两个独立 sheet(选图 + 裁剪),中间用蒙层串联——曾试"单 sheet 内 picker→裁剪 切换"导致 presentation 错乱(背景透明/无法操作),已回退。
  - **非破坏式裁剪/调位**:存原图 + 归一化 `BackgroundCrop`(可反复重调,原图不损)。`BackgroundRepositionView`(UIScrollView pan/zoom)选区域 → `PositionedImage` 以选区中心为焦点居中展示。**WYSIWYG 根因解**:照片卡用固定比例 `K=4.0`(= 预览窗口比例)作**最小高度**,内容更多时自然长高、只多露不切——设备无关,主体(头顶)不再被裁。
  - **展示**:2·Map=照片铺满整张卡(白字 + 蒙层,色条/进度/状态药丸有图态转白/深底);3·Thumb / 4·Map=56pt 小图。1·Plain 不显示照片(设计如此)。
- **首页样式定向**:**默认样式改为 2·Map**(`HomeView` + `SettingsView` 两处 `@AppStorage` 默认 `.featured`)。3·Thumb=通讯录式"墨色底+城市首字"字母块兜底。4·Map=实时 `MKMapView` 兜底——**仅实验、不上线**(56pt 上 MapKit 署名/大陆审图号无法两全;Apple 商标禁止自叠 logo)。
- **备份/还原纳入背景图**:`BackupTrip.backgroundsData`(条目+裁剪框)+ `CarryBackup.backgroundImages`(图片字节,base64),还原时写回沙盒。均为可选字段。**备份版本号从 2 重置回 1**——产品未发布、无在野旧备份,发布前新增可选字段不升版本。
- **Quick Actions 顺序修正**:`shortcutItems` 数组按"第一个离图标最近"的 iOS 行为倒序定义(footprint→nearest→newTrip),使图标在下半屏时从上到下读作 新建行程 / 最近一趟 / 我的足迹。
- 顺带:帮用户把之前一份真实备份(16 趟、v1)定位出来用于还原(已是 v1,无需转换);清掉模拟器里残留的 v2 备份文件。

**待办**:
- ~~首页样式定稿~~ → **已收尾**(见上方同日新条目:删 1·Plain/3·Thumb + 死代码 + 无用 key + croppedImage;保留 2·Map 默认 + 4·Map 实验)。
- **4·Map 上线合规未解**:若最终想要地图样式,只能用在"够大、能显示 MapKit 自带署名"的尺寸(详情页大图/banner),不能是 56pt 小图。
- **Phase 2(在线图库,已搁置)**:Unsplash/Pexels 搜索 + 大陆可用性 + 署名合规(见 `specs/trip-background-image.md`)。
- 真机全流程验收(裁剪精度用户已确认 OK);背景图功能补埋点(当前实验阶段未加);分支合并前回归。

## 上次改动摘要（FX 缩放 Sheet 丝滑根治 + 设为默认 · 2026-06-03）

把"做一半带 bug"的 FX 缩放 Sheet（`CarryBottomSheetFX`）打磨到生产级：**彻底丝滑 + 视觉定稿 + 设为默认**。完整经过见 `docs/home-sheet-debug-playbook.md` §21–§32。

- **根因链（层层递进，前面是后面的前提）**：① 内容固定尺寸、不每帧 relayout，侧边收窄改**等比 transform**（内容+内边距同步缩，对齐 Flighty/Tripsy）；② 圆角用**嵌套 cornerRadius 层**替代每帧 `CAShapeLayer.path`；③ 运动期 `shouldRasterize` 缓存 blur/阴影，避免 transform 每帧重渲染滤镜；④ **吸附改 `UIViewPropertyAnimator`（纯 Core Animation）替换手写 `CADisplayLink`** —— 这才是掉帧的真根因（锁 60Hz 下 Tripsy 仍丝滑，证伪了"帧率不够"假设）。
- **掉帧定位教训**：纯试错走了 3–4 天才到 CA 这个真解；已把"性能/动画排查纪律"写进 `CLAUDE.md`（先用对照组/竞品做单变量隔离、动画不丝滑先查"机制"是否 CA、历史 workaround 前提变了要重新质疑等）。
- **默认变体切到 FX**（`.ultimate`）；fallback（无缩放）降为 Dev Options A/B 备选，**暂留不删**。`Info.plist` 加 `CADisableMinimumFrameDurationOnPhone`（ProMotion 高刷）。删尽全部 CADisplayLink 机制。
- **最终调定值**：`expandedBottomRadius=40`（≤屏幕圆角、过裁防漏地图）/ `collapsedBottomRadius=56` / 顶角 36 / 收起间距各 8 / 吸附 `0.36s` 临界阻尼无回弹。
- 顺带提交了用户在途的 **Accent Color 主题选择器 + `toggleTint`** 功能（已确认）。两个 commit 已推送：`f358be5`（FX 实现）+ `80ba129`（主题 + 默认切换）。

**待办**：
- 真机 / TestFlight 多跑，确认 FX 长期稳定、无需回退 A/B 后，**退役 fallback**：删 `CarryBottomSheet.swift` + `SheetFeatureFlag.swift` + Dev Options 的 Sheet Implementation 开关，HomeView 直调 `CarryBottomSheetFX`（清洁路径见 `specs/sheet-fallback.md`）。
- 仍有独立 WIP 未提交：`CarryWidget/Localizable.xcstrings`（529 行改动，提交前先确认非格式重排）+ `docs/app-store-metadata.md` / `design-system.md` / `release-checklist.md` / 新文件 `app-store-screenshots.md`。

## 上次改动摘要（QA 全量审计 + 修复 · 2026-06-02）

并行 4 个 agent 从数据完整性 / 边界错误 / 时序异步 / 本地化跨平台四维做静态 QA，列出 28 条候选问题，trust-but-verify 后分 9 批修完（PR #32-#40）。

**关键修复**：
- **数据同步链**：删/改/复制 trip 时补齐日历事件清理（CalendarManager 新增 removeTrip/updateTrip）+ 复制 trip 补排提醒
- **备份还原**：performRestore 加 .pre-restore.json 半原子保护；还原后清旧通知/LA + 重排 + 刷 widget；BackupTrip 加 additionalDestinationsData（多目的地）；版本守护逻辑修正（先 VersionStub 判版本再完整 decode，原顺序错误导致永远走不到）
- **LiveActivity**：endIfDeparted 按 tripId 精确过滤（原 first 取错）；跨时区"出发日"用绝对秒数比较 + 保留出发当天；startIfNeeded 加 isStarting 锁 + terminateAllAndWait 防并发重入
- **通知调度**：updateReminderTime 加 remindersEnabled/isDateless guard；已过 fireDate 不再静默丢弃（60 秒后兜底触发）；components 显式锁 timeZone 防跨时区漂移
- **错误处理**：CalendarManager.requestAccess / NotificationManager.requestAuthorizationIfNeeded / WeatherKit catch 不再吞错，统一记日志
- **深链冷启动**：ContentView.onAppearCommon 主动消费 pendingTripId（防 Splash 期间设值丢失）
- **Minor**：findNearestTrip 优先未来；regenerateScenes 自定义物品 fallback "其他" 收容防丢失
- **本地化**：Agent 报硬编码多为误判（SwiftUI Text 字面量自动当 LocalizedStringKey），真改 CFBundleDisplayName 补 6 语言 + 删 widget 3 个伪 key + DestinationInfoView 加 minimumScaleFactor

**未修**：handlePendingShortcut 的 0.35s asyncAfter（splash + NavigationStack 就绪事件无可观察钩子，根治需重构）— 加了注释明确取舍。

## 上次改动摘要（UI / 文案打磨批次 · 2026-06-02）

- **设置开关启用态**：定为 `Color(.label)`（=`.primary` 黑白）。中途误用品牌橙被否决——主题黑白、无品牌橙（详见 decisions）。
- **闪屏**：logo 跟随所选 App 图标（`currentAppIconPreviewName`）；品牌字中文显示「启程 / 啟程」，与桌面 App 名一致。
- **文案**：`about.tagline` 加「情」+ 句末全角「～」；无日期入口「先规划，日期再说」；Settings 分区改名「提醒与显示 / Reminders & Display」（9 语言重译）；日历开关「自动添加行程到日历」+ 卡片下加 footer「行程进名为 Carry 的日历，未显示请在日历 App 勾选 Carry」。
- **中文全角标点**：修复半角逗号/省略号，并写入 CLAUDE.md「中文文案必须用全角标点」规范防复发。
- **过期行程提醒入口**恢复可点击（去掉 `isHistoricalTrip` 门控，TripReminderSheet 本就支持过期展示）。
- **WeatherKit entitlement** 因免费 Personal Team 不支持、撤回（真机签名会失败），待付费账号到位再加（见 release-checklist 顶部「待付费账号」节）。
- 清理 xcstrings 失效 key；图标换版 CarryLogoThin（用户在 Xcode 内换，已合入）。

## 上次改动摘要（移除日历打包提醒 · 2026-06-02）

- **删掉 Calendar Sync 里的"打包提醒"日历事件 + 时间设置**。理由：与刚做的应用内通知系统重复（都提醒打包），且子开关+时间选择器属冗余配置，违背克制。Calendar Sync 现只剩「自动添加行程到日历」单一开关,职责清晰（日历=显示行程，通知=提醒打包）。
- 改动：`CalendarManager`（删 pack 事件 + packingListNotes + 3 个签名去参）、`CalendarSettingsView`（删子开关/时间行/5 个 helper/3 个 AppStorage）、`TripStore`（创建时不再读 pack 偏好）、删 3 个失效 xcstrings key。通过 simulator build。

## 上次改动摘要（通知偏好 · 自定义默认提醒 · 2026-06-02）

- **新功能：设置 →「通知」二级页**（`NotificationSettingsView`，放「提醒与显示」分区首行）。用户用开关选择"新建行程的默认提醒档位"（出发当天/前1/2/3天/前1周/前2周，复用 `TripReminderConfig.presets` + `reminder.label.*` 文案），默认开「出发当天 + 出发前1天」。spec：`specs/notification-preferences.md`。
- **机制：创建时快照，非实时联动**。`ItemPickerView` 的 `.create`/`.autoPackReview` 在建 `TripBundle` 后 `bundle.reminderConfigs = ReminderPreferences.defaultConfigs`。改设置不影响已建行程；单行程仍可在物品清单独立增删。
- **默认软化**：`TripReminderConfig.defaults` 从 `[提前3天@9 + 出发当天@7]` → `[出发前1天@9]`（仅作存量空配置行程的回退；新行程走快照）。
- **全局偏好**：新增 `ReminderPreferences`（`UserDefaults` 存逗号分隔 offsets；nil→默认[1]，空串→[]全关，二者区分）。**纳入备份**（`CarryBackup.defaultReminderOffsets: [Int]?`，旧备份缺字段则保持现状）。
- **去重**：档位标签逻辑抽到 `TripReminderConfig.localizedLabel`，`TripReminderSheet.reminderLabel` 改为复用。新增 3 个 xcstrings key × 9 语言（entry/section/footer）。
- **全局默认时间**（06-02 加）：通知页顶部一个时间选择器（`defaultMinutes`，默认 09:00），所有已开启档位统一用此时间（去掉原 presets 7:00/9:00 混合的认知缺口）；per-trip 仍可逐条覆盖。`defaults` 回退也统一 9:00。
- **一级设置**（06-02 顺带）：去掉日历同步右侧 On/Off 状态显示（反转 05-31 决定），移除随之死掉的 `calendarSyncEnabled` 声明。
- 通过 simulator build。**待办**：真机验收（改设置档位+时间→新建行程读到对应配置；全关→无提醒；老行程不受影响；备份还原带偏好）。

## 上次改动摘要（电压预警 · 女性出行视角第一弹 · 2026-06-01）

- **新功能：美发电器 × 电压预警**。清单含电热设备（直发棒/吹风机）+ 目的地与家乡电压档位不同（`<160V` 低压 / `≥160V` 高压）时，`DestinationInfoView` 插头卡片的电压行变橙警示，提示"转换插头不变压、可能需变压器"。复用现有 `PlugCatalog` 电压数据 + `Locale.current.region` 家乡判定，纯本地零新增数据源。spec：`specs/voltage-converter-nudge.md`。
- **物品库**：Personal Care 组新增「Hair dryer / 吹风机」（9 语言）。未加 Curling iron——其中文与 Hair straightener 译文「直发棒/卷发棒」重复会致歧义。`heatingAppliances` 集合预留了其余规范名以备扩库。
- **UI 迭代定稿**：警示行最终为**单行 + 保留 Hz**（`⚡️ 120V / 60Hz · may need a converter`，整行橙）。曾试"去掉 Hz"和"两行"版，前者与普通状态信息不一致、后者占空显空，最终单行保留 Hz 最利落一致。`lineLimit(1)+minimumScaleFactor(0.8)` 防长语言破版。
- 本地化新增 `destination.plug.voltage_warning` + `Hair dryer` × 9 语言（含显式 en）。模拟器实测：大陆(220V)→纽约(120V)+直发棒/吹风机 → 橙色警示正常。**待办**：去欧洲(230V，与大陆同档)确认不触发；长语言(德/西)真机扫一眼缩放。
- 同会话另记 4 条女性向待办（见记忆 `project_carry_female_user_ideas`）：电压预警(本次)/液体合规/气候护肤/solo安全，后三者上线后做。

## 上次改动摘要（首页冷启动揭示动画统一 · 2026-06-01）

- **断层根因**：首页分组入场揭示原本是两套系统拼的——Hero/Past 走连续的 `initialRevealProgress`（按阈值 0.16 / 0.78 揭示），而 Upcoming 单开了 `didRevealUpcoming` 布尔 + `triggerUpcomingReveal` 的 `asyncAfter(0.28)`；**Planning 两套都没接**，冷启动时瞬间硬出现，紧跟在浮入的 Upcoming 之后形成视觉断层。`listRevealThreshold = 0.58`（Upcoming 本该用的阈值）是 orphaned 死代码。
- **统一治理**：把 Upcoming + Planning 一起收敛到 `initialRevealProgress >= listRevealThreshold`，与 Hero/Past 同一条 ramp 驱动，形成 Hero(0.16)→Upcoming/Planning(0.58)→Past(0.78) 连续级联。删除 `didRevealUpcoming` 状态、`triggerUpcomingReveal` 函数（连带 `asyncAfter` 反模式，CLAUDE.md 明令禁止用硬编码延迟等动画）、以及已死的 `revealProgress` helper。Planning 加 0.08/0.10s 基准 delay，读起来接在 Upcoming 之后浮入。
- **深链兜底简化 + 更稳**：原 `onReceive(router.$path)` 里救「Upcoming 卡 opacity 0」的分支（因 `triggerUpcomingReveal` 闭包有 `guard router.path.isEmpty` 守卫而需要）改为 `if initialRevealProgress < 1 { … = 1 }`。`initialRevealProgress` 在 macBody/sheetContent 两个 onAppear 里都无 router.path 守卫，本就比旧方案更不易卡深链 bug。
- macBody onAppear 去掉 `didRevealUpcoming = true`（Mac Catalyst 无冷启动动画，`initialRevealProgress = 1.0` 瞬间满状态不变）。通过 iOS Simulator build。**待办**：深链(Widget/QuickAction)冷启动路径须真机验收（模拟器复现不了时序）。

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
