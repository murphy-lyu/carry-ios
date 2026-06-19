# 项目进度

## 最后更新
2026-06-19

## 上次改动摘要（底部交互/导航视觉打磨：底栏通透·新建 sheet 化·设置对齐·App Icon 行 · 2026-06-19）

> 本会话独立于并行的航班/租车会话，**只动自己的文件、逐 hunk 隔离**（避开 ItineraryView/PackingListView 等共享文件里并行的在途代码）。下面均**已提交、未 push**（commit 见括号）。

- **🟢 行程/打包底部切换器「通透磨砂化」**（`e7365e7`）：浮动 glass 胶囊原垫 `bottomBarScrim`（实心兜底 + 22pt 顶部渐变）——较高的实心区把可视内容区视觉压短，且胶囊背景用 `Color.opacity` 平涂半透（只调暗不模糊）→ 胶囊后清晰文字直接穿透显脏。改：① 新增 `bottomBarFade`（透明→底端半透 0.92 的**通透**垫底）取代实心；② 胶囊背景平涂 → `.regularMaterial` **磨砂玻璃**（模糊背后内容、通透却不脏，对齐 iOS 原生悬浮栏）。其余 6 处 `bottomBarScrim` 是整宽 CTA 实底，保持不动。
- **🟢 死代码清理：「编辑场景」ScenePicker `.edit` 模式**（`b38f81c`，净删 275 行）：`CreationRoute.editScenes` 全仓从不 push、`showEditScenesSheet` 从不置 true → 整条 `.edit` 模式 + 两入口 + 只它在用的 `regenerateScenes`/`presetItemNames` + 两个孤立文案全删，只留活的 `.suggest`/`.autoPack`。
- **🟢 新建行程 `fullScreenCover → .sheet`**（`dc1cf56`，仅 iPhone）：创建流早简化为单屏（TripInfo 填完直接建、不再 push），全屏 cover 是旧多步流遗留、且方角内容撞屏幕物理圆角不协调。改 page sheet（对齐 Apple 新建事件/提醒）+「草稿放弃确认」（有草稿时拦下滑、取消问「放弃这个新行程?」，`tripinfo.discard.*` 3 key×9 语言）+ 复用 `PresenterRecedeEffect`（首页后退缩放，与设置/搜索/Trip Book 四个 sheet 统一）。
- **🟢 行程页「…」菜单：探索移底部 → 全回退 → 强化右上角**（`7dd6e40`）：曾试「底部三件套（···/切换器/➕）」，但 ➕ 跨 tab 变义有心智负担、··· 放左下是最难够的角、把低频动作塞进拇指黄金区本末倒置 → **整套回退**。结论：低频溢出动作就该在右上角（iOS 惯例、靠惯例可发现）；原「不好发现」真因是图标太弱（14pt 灰）→ 提到 17pt 主色、与返回键等分量（iOS 26 系统自动套同款玻璃圆）。
- **🟢 设置 Picker 箭头结构性对齐**（`47d2e00`，取代 `f05f884` 的 -12 补偿）：外观/距离单位用原生 `.menu` Picker、自带尾部内边距 → `⇅` 比其它行 `>`/`↗` 偏左。先用 -12pt 负 trailing 补偿（治标、OS 版本敏感），后改根因解：菜单行与其它行**同构渲染**（`Menu`+内联 Picker，自定义 label 只含值+`settingsAccessory(.menu)`、标题留 Menu 外避开闪空坑）→ 箭头走同一段代码、必然同列、无魔数。
- **🟢 App Icon 行副标题「选中即换行」**（`0aefe71`）：对勾原 `if isSelected` 才插入 → 选中挤窄文案换行。改：对勾位置**恒定预留**（`opacity` 切显隐）+ 副标题 `lineLimit(1)+minimumScaleFactor(0.85)` → 选不选中布局一致、恒单行。
- **待办**：① 我这几条（`e7365e7`/`b38f81c`/`dc1cf56`/`7dd6e40`/`f05f884`/`47d2e00`/`0aefe71`）+ 并行提交一起 push（用户定，push 会一并推上并行会话提交）；② App Icon 行 + 草稿放弃确认 + 底栏通透**真机验收**（模拟器宽屏看不出 App Icon 原换行现象，需真机）。

## 上次改动摘要（行程交通：租车入口收口 + 类型菜单/表单打磨 · spec: itinerary-car-rental.md · 2026-06-19）

> 与「航班搜索优先」并行会话**共享** `ItineraryView.swift` / `TransportEditView.swift` / `Localizable.xcstrings`，逐 hunk 交织、不可分割提交 → 由用户合入**同一 commit `1dc5cca`**（含航班搜索）。**编译绿、未 push**。⚠️ 该 commit 仍含硬编码 `appToken`（`FlightLookupService.swift:22`），push 前须处理（用户在航班会话另行处理）。**真机验收待办。**

- **🟢 租车入口收口（根因）**：原本「加租车」走的是**地点类别选择器**（`StopCategory.carRental`）→ 搜一个坐标点（搜不到小公司/公司不在机场）。根因＝把「边」（交通段）当成「点」（地点）。解：① `StopCategory.placeSelectableCases`（在地体验+住宿+兜底）从地点类别**撤掉** carRental/cruise/flight/train（枚举 case 保留，旧数据仍渲染）；② 租车升为「+」**交通组顶层入口**，走现成 `TransportSegment` / `TransportEditView`（公司=自由文本、取/还车地点可选、取/还车日期时间）。
- **🟢 类型菜单单一数据源 + 嵌套子菜单**：`TransportMode.ordered = commonModes[航班/火车/租车] + moreModes[巴士/渡轮/其他]`，「+」菜单与表单内类型选择器**共用同一份**（内外一致、不再分叉）。菜单交通组＝常用直列 + **「更多交通」嵌套子菜单**（巴士/渡轮/其他，各直接落位）——外层轻、低频也一步可达，否决「全屏 hub」与「其他交通→进表单再选」。
- **🟢 还车地点同取车开关**（默认开，仅 carRental）：只折叠还车「地点」，还车日期/时间独立；保存时把取车地点拷给还车端。无存储位，编辑时从数据派生回填。
- **🔴 canSave 修复**：租车隐藏班次号、地点又可选，原「班次号 || 出发地名」导致**只填公司存不了**；改为租车以「公司名 || 取车地点」为准。
- **🟢 表单顶部「类型」行移除 → 标题承载类型**：外层已选定类型，页内不再重复展示/可改；标题改「添加{类型}」/「编辑{类型}」。**类型固定在创建时**，改类型 → 删除重加（极少见、各类型字段本就不同）。
- **🔴 两个 `??` 死代码警告（根因修非消音）**：`ymdDate` 返回非可选，`??` 是死代码，且暴露 bug——作者本意「无起飞时刻→落到出发日」因 `ymdDate` 把 nil 吞成「今天」从未生效；改为调用前显式判 nil，恢复回退本意。
- **文案**：`itinerary.transport.mode.carRental`「自驾/Car」→「**租车/Car rental**」；新增 `add.section.transport`（交通）/`add.more_transport`（更多交通）/`transport.field.same_return_location`（还车地点同取车）/`transport.{add,edit}.title.typed`（带 %@，各语言占位符位置按习惯）；删旧 `transport.{add,edit}.title` / `transport.section.type` / `kind.other_transport`。均 9 语言齐。
- **待办**：① 真机验收（菜单交通组 + 更多交通子菜单 + 还车开关 + 类型标题各语言）；② `appToken` 移出源码后再 push（航班会话处理）。

## 上次改动摘要（机场搜索内置库 + 行程地图/时间轴/视觉一串根因修复 · 2026-06-19）

> 本会话与「航班搜索优先」「照片回溯行程」两个并行会话**共用多个文件**（`Itinerary.swift` / `PackingListView.swift` / `TransportEditView.swift` / `CarryBottomSheetFX.swift` 等）。提交时**一律只 surgical 暂存自己的 hunk**（以 HEAD 为基补我那段、再还原工作区），**绝不卷入并行会话的在途代码**（如 `placeSelectableCases`、`FlightSearchSheet`/`prefill`、Photo* 系列）。全部**编译绿、未 push**。下面均已提交（commit 见括号）。

- **🟢 机场搜索改用内置机场数据库**（多 commit：`0c58f3c`/`68e8ca1`/`40cb12f`/`a80afe0`/`a0e6f13`，spec: `itinerary-airport-search.md`）：根因——航班机场选点原复用 MapKit 通用 POI 搜索，大陆设备走高德、境外覆盖差且 App 无法切供应商。解：`Carry/Resources/airports.json`（~4100 机场 / OurAirports+OpenFlights 时区+Wikidata 多语言名，含 ICAO 兜底抓取）+ `AirportDatabase`(actor) + `AirportSearchSheet`，全球可搜、离线、回填 IATA/坐标/IANA 时区。9 语言机场名 + 城市别名（搜索匹配）。`AboutView` 加数据来源署名（OpenFlights ODbL 要求）。构建脚本见 `scripts/airports/`。
- **复制行程移出左滑 → 行程内 ··· 菜单 + 回首页扫光高亮**（`3469a79`）：根因——左滑展开态下插入新行 SwiftUI 无法平滑收起该行（对照实验：contextMenu 无左滑插入完全干净）。解：复制从行程内 ··· 菜单触发（首页不在左滑态），复制后 `router.path=空` 回首页 + 复用既有 `shimmerTripId` 扫光高亮副本。新增 `TripStore.pendingShimmerTripId`。左滑只留删除。
- **日期选择器三处打磨**（`7a3895b`/`5110bf4`）：头部 Departure/箭头/Return 固定列宽不抖动（隐藏「最宽参考」+ monospacedDigit + lineLimit(1) 防隐藏参考换行顶歪标题）；「今天」圆点选中态白色；选中日数字 Dark 下也白色。
- **行程规划页底部空一片**（`c59e453`）：根因——日历横条用 `ScrollView(.horizontal)` 没约束高度、撑满竖直空间、日期格被摆在高框顶部、下方空 ~160pt 把列表顶到屏幕下半。解：`.fixedSize(horizontal:false, vertical:true)`。（实测定位：collection 内容在自己顶部 originY=549、空白在其上方。）
- **行程地图取景由地点驱动**（`ed7f6db`，`ItineraryMapView.swift`）：根因——`fittedRegion` 把交通段 from/to 端点（机场可相距数千公里）算进总包围盒 → 加航班后地图缩成跨国尺度、市内地点变针尖。解：新增 `framingCoordinates`，预览取景只用停靠点、排除交通端点（纯航班日才回退含端点）；全屏维持框住全程。
- **航班时间轴定位：早班机不再被无时间地点压到底**（`2e83805`，`Itinerary.swift` `timeline`）：根因——原逻辑只把定时航班相对「其它定时项」插入，Carry 地点常不填钟点 → 航班无锚点落末尾。解：base 全无时间地点时，按航段出发时间相对正午定位（上午<12:00 置顶领起当天、午后/傍晚置底）。
- **底部消隐渐变 Dark 灰雾**（`88c467e` 首页 sheet + `2dae40d`→`243a2b4` 行程详情）：① `CarryBottomSheetFX` 的 `FXBottomFadeView` 用 CAGradientLayer+CGColor 不跟 trait → 深色停白，改 `registerForTraitChanges` 重设。② 行程详情两个 tab 内容层都铺 `systemBackground`+`ignoresSafeArea(.bottom)` 盖住容器 `CarrySubtleBackground` → 底部真实纯黑，但 `bottomBarFade` 淡出到 0.08 baseColor 起灰雾；改为两面都淡出 `systemBackground`。**已全项目排查 8 处 fade/scrim：目标色须 == 该页「底部最上层不透明层」色（不是页面根！），其余 7 处均已匹配。**
- **开发流程铁律新增**（`CLAUDE.md`）：驱动模拟器的许可是「按当次请求」的，**绝不跨任务/跨轮沿用**；没有当轮明确「跑/调模拟器」就只编译、不自跑（computer-use 抢屏会突然打断用户）。
- **待办**：① 全部未 push（本地 main 领先 origin 一堆，发布前用户拍板）；② `CarryBottomSheetFX` 的 `traitCollectionDidChange→registerForTraitChanges` 现代化改在工作区**未单独提交**（依赖并行会话的 `updateEmptyStateSurface`，留着随空态 feature 一起提）；③ 遗留非阻塞：`PKX`/`TFU` 等新机场时区暂空（OpenFlights 旧数据 + 中国多时区不兜底，显示降级）。④ 未来想法（先记不做）：多城市的一天**按航班切两段**（上午·A 城 → ✈ → 下午·B 城，各自小地图）；航班行可选「抵达/飞往 + 时间」到达/出发口吻文案。

## 上次改动摘要（添加航班「搜索优先」+ 航司表 + 交通段日期/时间融合 chip · spec: itinerary-flight-search-first.md · 2026-06-19）

> 把「添加航班」从手动优先翻转为**检索优先 + 手动兜底**，并把交通段编辑表单的日期/时间重做成 Tripsy 式融合 chip。**编译绿（主 app + Widget）+ 模拟器 iOS 26.5 实测通过**。**全部未提交**。与并行租车会话共享 `TransportEditView.swift`，只动了我的 hunk（航班预填接入 + 日期时间 chip + sheet 合并），未碰其租车逻辑。

- **🟢 第1段 `FlightSearchSheet`（新）**：渐进式单框——输航班号 → 即时识别航司（新 `AirlineDatabase`，实测 MU→中国东方航空）→ 竖排日期列表（本行程的天 + 「选择其他日期」日历）→ **点日期即触发查询**（对齐 Flighty，不预填、不加按钮）→ 结果确认卡 → 点卡 push 进**预填**的 `TransportEditView`。底部常驻低权重「手动输入」兜底（春秋 9C 等查不到的航班）。
- **🟢 航司表**：`scripts/airlines/`（OpenFlights `airlines.dat` + Wikidata 多语言名，英文名也优先 Wikidata——9C 旧名 "China SSS" 已修为 "Spring Airlines/春秋航空"）→ `Carry/Resources/airlines.json`（986 航司，~225KB，已确认进 bundle）+ `AirlineDatabase`（actor）+ `FlightNumberParser`。
- **🟢 `TransportEditView` 改造**：① 加 `prefill`/`embedInOwnNavigationStack`/`onFinish`，被 `FlightSearchSheet` push 时不自带 NavigationStack、保存经 `onFinish` 关整张 sheet；② 移除原内嵌「✨自动填」块（前移到第1段）；③ **日期/时间融合 chip**（`📅 [日期 chip][时间 chip]`）取代「day Picker 行 + 时间开关行」——日期 chip 显示行程天（点选换天）、时间 chip 可选（点开滚轮 sheet、可清除）。
- **🔴 根因解·行高跳变**：原「时间开关一开，把比开关高的 compact DatePicker 塞进同一行 → 行被撑高」。根因＝控件硬塞进开关行；融合 chip 后无开关、选择器移弹出层、chip 普通行高 → 行高恒定（曾用的「隐形占位」是 workaround，已废弃）。地点搜索 + 时间选择合并为单一 `.sheet` 枚举（防多 sheet 互抑）。
- **🟢 工程**：`FlightLookupService` 上游 DTO 补 `nonisolated`，根治 Swift 6「main-actor 隔离 Decodable 不能在 nonisolated 解码」报错。「+」菜单航班入口改走 `FlightSearchSheet`。埋点 `flightSearchManualFallback`（即定义即接线）。文案 `flight.search.*` + `clear_time`（9 语言齐全），删死键 `itinerary.flight.lookup.*` / `itinerary.transport.field.day`。
- **留作单独立项**：日期「真正可选」（脱离按天分组、需「未排期」区 + schema 迁移），与按天分组架构冲突且重叠并行租车工作，单独 spec 后再做。
- **待办**：① 真机走完整验收（搜索→预填→保存、春秋手填、融合 chip）；② 提交（按用户指示）；③ 上架前切 API.market + 给 Worker 加 `APP_TOKEN`；④ 隐私政策补「航班号发第三方查询」一句。

## 上次改动摘要（Settings 信息架构与一致性大修 + 我的物品自定义分类 + 多处交互根治 · 2026-06-18）

> 一整轮 Settings 打磨 + 一个新功能（自定义分类）+ 若干交互 bug 根治。均已提交并 push（最新 `656fb5f`）。

- **Settings 全面收口**（多 commit `c0bf997`/`27e0fa3`/`7b53ac9`/`95f00d8`/`656fb5f`）：
  - **IA**：无主题的「General」→「**Language & Region**」（语言/货币/距离单位归一组，对标 iOS）；Personalization 收回为纯外观（Appearance/App Icon），Language 下移到 Language & Region。
  - **可供性对齐 HIG**：`›` 仅 push；离开 App 用 `↗`；开 in-app sheet 不挂箭头；就地弹菜单用原生 `.menu` Picker 的上下箭头。子页背景统一 `systemGroupedBackground`（App Icon/About/Roadmap 原误用首页氛围渐变）。
  - **杂项**：Roadmap 由 sheet 改 push；Currency 一级行去币种符号；一级「通知」→「行程提醒」；Support Carry 移到 About 上方。
  - **全栈审查修复**：通知授权态接回 Notifications 行（原死代码）；打赏失败弹窗 release 不再露调试转储；分享文案本地化；导入后刷新备份日期；RoadmapView 远程拉取加固（https+超时+256KB 上限）；清多处死代码 + 补 VoiceOver 标签。
  - **外观/距离单位下拉时标题变空白根治**：标题原本包在自定义 `Menu` 的 label 里（展开被快照渲染空）→ 标题移出菜单、值用原生 `.menu` Picker。
- **🟢 我的物品「自定义分类」复用/重命名/删除**（新功能，spec: `my-item-custom-categories.md`，`8a4be62`）：分类派生自 `MyItem.category`（无独立实体）。加物品时列已建分类可直接选；左滑行内重命名 / 即时删除（删除只清分类、**物品保留→暂不分类**）。**全程无 modal**（见 decisions 的 SwiftUI 坑）。store 加 `customCategoryNames / renameMyItemCategory / deleteMyItemCategory`。
- **日历叠加层默认勾选修复**（`95f00d8`）：首次默认原是「所有只读非生日日历」→ 误勾 TickTick/Tripsy；加标题节假日识别（9 语言）只勾法定节假日。⚠️ 仅首次初始化生效，验证需重装。
- **微信输入法中文丢字修复**（`7334833`）：行程名/目的地框原用「if isEmpty 显隐占位符叠层」+ 空占位符 TextField；marked text（预编辑态）下占位符不消失且选词提交丢字。改用**原生 TextField 占位符**。
- **分享/弹窗呈现统一**（`ad67d98`）：所有 `UIActivityViewController` 改走新增 `UIApplication.presentActivitySheet`（走到最顶层 presenter），修 Settings 导出等「点了没反应」（Settings 改 sheet 后 rootVC 已有 presented）。
- 行程详情「⋯」菜单调序（`3e9ea1d`）。
- **未做/待办**：深色首页空态 Sheet **磨砂玻璃**（HomeView/FX）实现过、用户验过好看，但模拟器有「按钮下方点不动」疑似伪影（真机正常），**未单独由我提交**（与用户在途 HomeView/FX 纠缠）；需真机最终确认后再决定提交。

## 上次改动摘要（备用图标根因修 + xcstrings 重排噪声根治 + 真机启动崩溃定位 · 2026-06-18 续）

> 三件事：①修好「换桌面图标不生效」；②根治 `.xcstrings` 反复出现的整文件重排噪声；③定位真机启动崩溃（结论：非 app 代码）。**两项代码改动已提交并 push**（`79e08a8`、`e53f23c`）。

- **🟢 备用图标桌面不生效（已修 + 模拟器实测过，已 push `79e08a8`）**：根因——`IconCat`/`IconDog` 只声明单张 `1024×1024`。这对**主图标**有效（系统运行时降采样出 120/180 桌面尺寸），但对 **alternate icon 无效**：`setAlternateIconName` 要求 bundle 里**实际存在**桌面尺寸渲染，否则切换静默回退主图标。**修复**：用 `sips` 从 1024 生成全尺寸（20–1024，iPhone+iPad），两个 appiconset 改经典多尺寸 `Contents.json`。`assetutil` 验证渲染从 `[1024]` → 全套含 120/180；模拟器 Dock 图标实测确实切换成功。⚠️ 仅模拟器验过，**真机待验**（但真机当前被启动崩溃挡住，见下）。
- **🟢 xcstrings 重排噪声（根治，已 push `e53f23c`）**：根因——`Localizable.xcstrings`（6 万行）有两个写入者各用各的 key 顺序（Xcode 规范排序 vs 脚本插入顺序），谁动一次基线就偏离、下次 Xcode 一碰整篇重排出巨 diff。**根治**：装 git **clean filter**（`scripts/xcstrings-normalize.py` + `.gitattributes`），在 git 边界把 catalog 规范化成单一确定顺序——谁用什么顺序写,git 都存同样字节,重排 diff **结构性消失**,真实文案改动照常显示。已证：倒序/改缩进等"敌对写入"后 `git diff` 仍为空。⚠️ **filter 命令在 `.git/config`、不随仓库提交**——换机/重新 clone 要跑一次 `git config filter.xcstrings.clean "python3 scripts/xcstrings-normalize.py"`，否则噪声回来（已存记忆）。
- **🔵 真机启动崩溃（已定位 = 环境/工具链问题，非 app 代码，待用户回另一台电脑确认版本号）**：症状——另一台电脑 Xcode Run 到真机，启动即崩 + 反复恢复上次页面、只能重启手机；控制台 `objc[...] -[OS_dispatch_mach_msg _setContext:]: unrecognized selector`。**真机 `bt` 决定性**：崩溃在 `dyld → libSystem_initializer → _libxpc_initializer → _xpc_init_pid_domain → _xpc_serializer_pack → objc_defaultForwardHandler → _objc_fatal`，**全在系统库、发生在 `CarryApp.main()` 之前、栈里无一帧 Carry 代码**。故**排除**：图标改动、diffable、近期所有改动。旁证：重启手机能恢复（app 代码 bug 不可能被重启修好）。**最可能诱因**：那台 Mac 的 Xcode 版本 < 手机 iOS 版本（缺 Device Support）。**本机对照**：Xcode 26.5、有到 iOS 27 的 DeviceSupport、部署目标 26.5，本机构建正常。**下一步**：用户回那台电脑给「Xcode 版本 + 手机 iOS 版本」；对策＝升级那台 Xcode 或直接用本机装机 + 手机删 app 重启重装清脏状态。
  - 顺带澄清：之前那份本地 6/14 模拟器崩溃（diffable `reconfigureItems` 传重复 id）是**修复前**的旧日志，已在 `18721e7`（6/15）修掉，与本次真机崩溃无关——我一度误判为同一处，已纠正。
- **🔵 切图标系统弹窗标题间距（不修，非可控）**：那个「你已更改"启程"的图标。」弹窗由 **iOS 系统**在 `setAlternateIconName` 成功后自动弹出，标题位置/间距全由系统排版，app 零控制权（代码仅调 API、不创建弹窗）。**纠正**我之前「补尺寸会顺带修好间距」的错误预期——图标已能正常渲染，但间距是系统弹窗固有样子，不是 bug、也不该用私有 API 去抑制。
- **未在本会话提交的在途文件**：用户自己的自定义分类工作（`Localizable.xcstrings` 内容、`PackingListView.swift`，其中菜单重排是用户提交的 `3e9ea1d` 已 push）——我**未触碰**。

## 上次改动摘要（航班号 → 自动填航班信息 · spec: `itinerary-flight-lookup.md` · 2026-06-18）

> 新功能：航班模式下输航班号+日期 → 一键自动填全段（航司/机场/起降时刻/航站楼/机型）。起步只做**静态基础信息**，实时动态留 Pro 阶段。**编译绿 + 启动不崩 + Worker 真实联调通过**（curl 验证 AA100 国际、MU5433 国内均完整）。**待真机走完整验收**。**未提交**。

- **架构**：App → 自家 **Cloudflare Worker 代理**（藏 API key + 服务端缓存 + 防盗刷）→ AeroDataBox。一次性「富化」、之后纯静态、永不再调。失败回退现有手动录入。
- **选型/成本**：AeroDataBox。**RapidAPI 太贵（$49.99/月）→ 走 API.market（Pro ~$5/月、6000 次、含商用）**。测试期用 RapidAPI 免费档，上架前切 API.market（只改 Worker 变量、App 不动）。Worker 上游地址/鉴权做成可配，两个市场通用。
- **数据覆盖实测**：AeroDataBox **国际 + 大陆国内都覆盖良好**（之前从 MU5101 单坏样本误判「国内弱」，已被 MU5433 完整数据纠正）。个别航班可能残缺 → App「尽力填、缺的手填」。
- **落点**：`FlightLookupService`（解析 全/残/多实例/跨午夜）、`TransportSegment.aircraftType`（新字段，四处同步：模型/备份/duplicate/schema）、`TransportEditView` 自动填块、`TransportDetailView` 展示机型、`scripts/flight-proxy/`（Worker + 部署文档，已部署 `carry-flight.murphy-latte.workers.dev`）、`CarryLogger` 4 事件、6 个 `itinerary.flight.*` 文案 9 语言。
- **时间映射要点**：起降时刻按**机场当地时区的时:分**存（与现有 `minutes(from:)` 范式一致）；dayOrder 按航班当地日期相对行程首日算，跨午夜 → `arriveDayOrder > departDayOrder`（PVG 20:50 起飞、CKG 次日 00:05 到达已验）。
- **待办**：① 真机验收自动填；② 上架前切 API.market $5 + 给 Worker 加 `APP_TOKEN`（同步填 `FlightLookupConfig.appToken`）；③ 隐私政策补「航班号发第三方查询」一句（spec 已列）；④ Pro 阶段实时动态（飞常准/FlightAware，填 `liveStatusData`）。

## 上次改动摘要（行程页性能根因2 + 去重 + 照片可见 + 隐私政策上线 · 2026-06-18 续）

> 用户反馈：**空的 180 天行程**也卡——切「行程规划」Tab、进入行程、返回首页都卡（不导入照片、不建地点）。证据明确，定位根因并修复。另落地去重、照片可见、隐私政策。**编译绿 + 启动不崩**；**滚动/切换体感需真机验**。**Carry 未提交；carry-legal 已 push main**。

- **🔴 性能根因2（O(N²)，已修）**：`ItineraryView.calendarEntries` 给每天做 `days.first(where: sortOrder==offset)`（O(N) 查找）× 181 天 = O(N²)，且每次 `days` 还重排 181 元素 → 每次 body 求值约 25 万次比较；叠加日历条用普通 `HStack` 一次性构造 181 个 chip。这是**空 180 天行程**切 Tab/进入/返回都卡的主因（与 stop/照片无关）。**修复**：① `calendarEntries` 建一次 `sortOrder→day` 字典，O(N²)→O(N)；② 日历条 `HStack`→`LazyHStack`，只构造可见 chip。进入/返回/切 Tab 都受益（都触发 body 求值）。地图对 181 天是 O(N)、可接受。
- **🟢 重复导入去重（已做）**：`importItineraryFromPhotos` 以「拍摄时间(秒)+经纬度(~1m)」为指纹，跟该行程已有照片比对，命中跳过；地点照片全重复则跳过该地点。零授权下没有 assetLocalIdentifier，故用此锚点。埋点带 `dupSkipped`。
- **🟢 照片可见（补的真实缺口）**：之前导入的照片存了 `StopPhoto` 却**没在行程里显示**（只在导入预览见过）。在 `StopDetailView` 头部加横向照片条 + 点击全屏放大（看的是约 640px 缩略图；零授权不取系统原图）。看法：点由照片生成的地点 → 详情头部即照片条。
- **单次上限 40→50**（系统选择器自带强制+计数提示，无需自定义文案）。
- **加载态「印相纸」**：处理时所选照片逐张缩略图浮现（`extract` 回调增量传缩略图）+ 确定式 `X/总数` + 可取消（Task 取消 + onDisappear 兜底）。
- **🟢 隐私政策（carry-legal 已 push main）**：`privacy/zh.html` + `index.html` §5 加「照片访问」段（端上读 EXIF、零授权、不上传不存原图、仅本地缩略图）、§6 调和「相册」表述、日期更新。GitHub Pages 部署（raw CDN ~5min 缓存，按 CLAUDE.md 用 GitHub API 确认）。

## 上次改动摘要（照片回溯行程 · 性能根因 + 隐私/入口/文案迭代 · 2026-06-18）

> 承接 `photo-trip-reconstruction.md`。用户反馈：180 天行程+约百张照片导入后，**行程页滚动卡到无法使用**（未崩）。本轮定位根因并机制级修复，外加一串产品/隐私/文案打磨。**编译绿 + 模拟器启动不崩**；**滚动性能需真机+真照片验证**（模拟器无带 GPS 照片，无法复现 100-stop 滚动）。**未提交**。

- **🔴 性能根因（机制级，非止血）**：collection 滚动中每过一个「天界」就回写 `focusedDayId` @State → 触发 `ItineraryView.body` 整体重算（`daySections` 逐天重建 `timeline` + 地图重建全部 `Annotation` + 快照重建）。长行程下快速滚动连触发几十轮整页重建 → 卡死。180 天空行程不卡（无 stop），照片灌入上百 stop 后引爆。**修复**：把 focused 天回写从「滚动途中持续」改为「滚动停下时一次」（`ItineraryReorderCollection` 新增 `scrollViewDidEndDragging/Decelerating`，移出 `scrollViewDidScroll`）→ 滚动过程零 body 重算、纯 UIKit 列表滚动。代价：日历条高亮改为滚动停下时更新（可接受）。
- **未做的更深优化（留真机 profile 再动，不盲改核心视图）**：地图 100+ 标注重建、`daySections` memoization、`safeItineraryDays` 每访问重排、`stopRow` 的 O(天×点) 查找。已在报告/本节记录，建议配合 Instruments 做。
- **单次导入上限 40 张**（防 stop 爆炸 + 控耗时/内存）；落库是「追加」、可多次导入。
- **入口弱化**：从行程页直出的照片按钮 → 收进右上角 `ellipsis.circle`「更多」菜单（偏小众 + 涉相册权限，不宜显眼）。仅有日期行程显示。
- **隐私安心文案**：导入首屏加一行（盾图标）「照片只留在本机、只读时间地点、绝不上传、只存一张缩略图」——打消「上传/挪用/撑爆存储」顾虑。
- **文案去程序味**：`Build from photos` → 标题「从照片还原行程」/ 菜单「用照片还原行程」（避免 "Build" 的工程感）。
- **EXIF 直读兜底**（承上轮）：`PHAsset.location` 为 nil 时用 `CGImageSource` 直读文件 EXIF GPS，与系统相册同源——解决「相册有位置、Carry 说没有」。
- **待整理拆两诚实区块**：`没有位置信息`（文件真无 GPS）/ `不在行程日期内`（有位置但越界，显示拍摄日）——让用户秒懂原因、不疑为 bug。
- **资源释放**：原图永不拷贝；导入内存（draft+缩略图）随导入页 dismiss 释放；落库仅存小缩略图（约 40 张 × ~40KB ≈ 1.6MB）。
- **合规**：`docs/photo-trip-launch-checklist.md` 沉淀——App Store 隐私问卷填「未收集」（端上处理、零传输）；`PrivacyInfo.xcprivacy` 无需新增 Required-Reason API；隐私政策（独立仓库 `carry-legal`）待补「照片」段。
- **🟢 零相册授权（用户当场拍板，已实现）**：彻底改用「仅 PHPicker、不绑库、不索权」——`PhotosPickerItem.loadTransferable(Data)` → `CGImageSource` 直读 EXIF（GPS+时间）+ 缩略图。**连「访问所有照片」弹窗都没有**（隐私敏感用户最大顾虑，从源头消除），顺带消除「相册有位置 Carry 说没有」。删 `PhotoLibraryAccess.swift`、移除 `NSPhotoLibraryUsageDescription`（不再需要）。取舍：逐张载入原图数据略重（40 张上限兜住）；不存 assetLocalIdentifier，本版不做「回相册看原图」。**需真机验**：真照片 EXIF 读取/聚类/分桶、大批量导入观感。

## 上次改动摘要（照片回溯行程：从相册自动生成行程 · spec: `photo-trip-reconstruction.md` · 2026-06-17）

> 新功能（需求：玩完之后把相册照片回溯成行程，与正向规划互为镜像）。**编译绿**（Carry / iPhone 17 Pro，零 warning）+ **聚类内核 7 断言 PASS**（swiftc 离线跑，项目无测试 target）+ **模拟器启动不崩**（新 `StopPhoto` schema 迁移已验）。**待真机验收**（需带 GPS 真照片走完生成→编辑→保存；模拟器自带图无 GPS 只到空态）。**未提交**。Status: Implemented (Phases 1–4)。

- **🟢 链路**：建行程定日期 → `PHPicker` 选图 → 读 `PHAsset` 时间/位置 → 坐标按 storefront 归一 → 时空聚类成「天→地点」→ `CLGeocoder` 反向命名 → 预览微调（草稿态）→「保存」批量落库。
- **三个暗礁的正解**：① **坐标系**——EXIF 是 WGS-84、项目库内境内存 GCJ-02，写库前按 `isChinaStorefront` 转换（`CoordinateTransform`，天安门偏移 556m 验证正确）；② **`PHPicker` 拿不到位置**——用 `assetIdentifier` 回查 `PHAsset.location`，需 `NSPhotoLibraryUsageDescription`；③ **SwiftData**——新增 `StopPhoto` 表属轻量迁移，注册进 `SchemaV1`、未升 SchemaV2。
- **聚类内核**（`ItineraryPhotoClustering`，纯函数可单测）：分天用凌晨 4 点 cutoff（夜生活/凌晨看日出不被劈两天）；地点用「时空一起判」——近则并、短暂走远又折返算地点内走动、持续远离才切新地点；松/中/紧三档阈值，预览页可切换重算（仅重跑 `assemble`、免重读相册）。
- **铁律四处同步**：`StopPhoto` 进 `DataBackupManager`（**带 thumbnailData 字节**、分享/导出路径不带照片——隐私+体积）+ `duplicateTrip` 深拷；`CarryLogger` 5 个 `photoImport*` 事件即定义即接线，`photoImportFailed` 入 `errorEvents`。
- **照片存储策略（产品决策）**：缩略图字节入库 + 原图引用相册（`assetLocalIdentifier`）。App 不囤原图，备份/换机能看缩略图，点开回相册取原图。对标 Apple 自家做法。
- **预览/微调页**（`PhotoTripReviewView`）：结果是「草稿」不是「结果」（顶部「保存」非「完成」）；改名铅笔露在标题边（反向编码偶给怪名）；合并/拆分/挪照片用菜单动作（不用脆弱拖拽）；待整理抽屉收无位置/越界照片，不报错不丢。
- **本地化**：`Localizable.xcstrings` 加 36 个 `phototrip.*`、`InfoPlist.xcstrings` 加权限文案，9 语言齐全、中文全角、日语常体、韩语해요体。surgical 文本插入（避开 Xcode 序列化格式坑），JSON 校验零重复键、现有键无损。
- **⚠️ 提示**：`Localizable.xcstrings` 本轮 diff（~2100 行）即这 36 个键本体、非 Xcode 重排噪声；**勿 blanket `git checkout` 该文件**（会连新键一起丢）。
- **遗留（后续打磨，非阻塞）**：合并/拆分改拖拽手势；两层「景区→地点」折叠（字段已留）；待整理照片拖回某地点；离群「路上随手拍」识别。

## 上次改动摘要（修复：Settings 导出/所有分享面板「点了没反应」· 2026-06-17）

> 编译绿（Carry scheme / iOS Simulator），用户已真机验收正常。本次修复独立提交（不含机场搜索等在途改动）。

- **🟢 修复「Settings → Export 点击无响应」**：**根因**——导航层把根级从 TabView 改成「Settings 以 `.sheet` 呈现」后，`rootViewController` 已持有 presented sheet（即 Settings 本身）；而分享面板仍用 `rootVC.present(activityVC)` 弹出，对一个「正在 present 别人」的 controller 再 present 会被 UIKit **静默吞掉**（不报错、无反应）。TabView 时代 Settings 是 tab 无此问题，故「最近才坏」。
- **覆盖所有触发路径**：同一错误写法（直接 `rootVC.present`）在 3 处都坏——Settings 导出备份、关于页导出日志、打包面分享清单。另有 3 处分享各自手写「走到最顶层 presenter」的正确逻辑（行程文件 / 海报 / 推荐 App）——正是这种 copy-paste 写法分裂导致总有几处漏更新。
- **根因解 + 消除该类 bug**：新增统一入口 `Carry/Views/UIApplication+ActivityPresenter.swift`（`presentActivitySheet`），沿 `presentedViewController` 链走到最顶层 presenter 再 present，并统一处理 iPad/Mac popover anchor。**全部 6 处分享调用点**改走此入口，删除各自手写的 presenter 查找。今后「在 sheet 之上弹模态」不会再因漏改某处而复发。
- **约定**：凡弹 `UIActivityViewController` / 任何模态，统一走 `UIApplication.shared.presentActivitySheet(...)`，禁止再直接 `rootViewController.present`。

## 上次改动摘要（首页：底栏失灵根因修复 + 空态固定缩放浮卡 · 2026-06-17）

> 在 `main`、**已提交并 push**。与并行「照片重建行程」会话共享工作区，全程只提自己的文件、未卷入其 WIP。commit `c104c36`（底栏）、`25f9054`（空态，spec: `home-empty-fixed-scaled-sheet.md`）。

- **🔴 修首页底栏三按钮失灵（根因解）**：费用功能把 `@ObservedObject ExchangeRateManager` 挂在**根 HomeView**——而根 HomeView 是首页 UIKit FX sheet（含底栏）的宿主，汇率每 publish 令根整体失效、透过 UIKit 宿主破坏底栏命中测试 → 三按钮永久点不动。解：把观察**下沉到真正的消费者**（新增 `ExchangeRateScope` 子视图承载花费卡），根 HomeView 不再观察汇率（底栏不受牵连），花费卡仍随汇率到达自动刷新、零回归。诊断用控制变量法（摘掉观察→底栏恢复）坐实，未凭推算。
- **底部消隐带调透**：`bottomContentFade` 加 `peakOpacity`（默认 1.0 保原行为、物品选择页不受影响），首页传 0.9。
- **🟢 空态固定缩放浮卡（spec: `home-empty-fixed-scaled-sheet.md`，Implemented）**：无行程时底部 Sheet 锁成固定、不可拖的缩放浮卡，**复用有行程折叠态同一组常量**（侧 8 / 缩放 (w-16)/w / 底 8 / 圆角 36·56，逐项几何一致、非另写近似值）。禁拖走 `shouldReceive` 直接 `return false`；隐藏把手；`mapCityOpacity=1` 让地图样式/定位按钮可用 + 地图可交互（卡外触摸经 `FXPassthroughView` 穿透）。仅动空态，有行程态全不碰。代码交叉验证：空态与折叠态四项几何同源、根因解、无性能问题、死代码已清。
- **教训**：空态底部留白来回调多轮——根源是「卡片底缘锚定 + 内容顶对齐」让 `bottomBreathing` 同时控「底部留白」与「卡片总高」（耦合）。中途凭脑内几何反复算错 → 改用真机 `NSLog` 取真值（h/expandedHeight/lift/visibleHeight）才稳。提醒：浮卡几何问题先仪表化取数，别凭推算。

## 上次改动摘要（机场搜索改用内置机场数据库 · 2026-06-17）

> 编译绿（Carry scheme / iPhone 17 Pro），`airports.json` 已确认打进 app bundle。**待用户真机验收**（CLAUDE.md：用户在场，UI 验收默认交给用户）。**未提交**。

- **🟢 航班机场搜索根治（新功能，spec: `itinerary-airport-search.md`，Status: Implemented 待验收）**：原问题「添加航班搜不到国外机场」。**根因**：航班机场选点复用通用地图 POI 搜索（`MKLocalSearchCompleter`），大陆设备 MapKit POI 由 Apple 自动切高德、境外覆盖差且区域锁定、App 无法切供应商；叠加 150km 目的地偏置。**解**：航班机场改走**内置机场数据库**（`AirportDatabase` actor + `AirportSearchSheet`），全球可搜、离线、不受设备区域影响，并回填 IATA + 坐标 + IANA 时区（`TransportSegment` 早预留的 `fromCode`/`fromTimeZoneId` 首次真正被填）。非航班交通方式仍走原 `ItineraryPlaceSearchSheet`。
- **数据集 `Carry/Resources/airports.json`**（约 4100+ 机场 / ~850KB）：OurAirports（列表，public domain）+ OpenFlights（IANA 时区，ODbL）+ Wikidata（简繁中文名，CC0）。构建脚本 + 来源/许可见 `scripts/airports/`。裁剪=有定期航班的机场+所有大型机场；时区覆盖 ~92%（单时区国家安全兜底，多时区国家留空不猜）；中文名覆盖 ~76%。
- **中文搜索/显示**：为防「中文搜国内机场回归」，bundle 简繁中文名，**搜索匹配中文 + 按设备语言显示**（中文设备显中文、其它显英文原名）。修订了 spec 里原「英文原名」的决定（前提已变：本就必须取中文名）。
- **城市中文别名（搜索补全，如「纽约」→ JFK）**：境外机场中文名常不含中文城市（JFK=约翰·肯尼迪国际机场，不含「纽约」），纯靠机场名会漏。从 Wikidata `P931`（机场服务城市）取简繁城市名作 `cs` 别名字段（仅匹配、不显示，覆盖 ~2800 机场）。`AirportDatabase.matchScore` 纳入 `cs`。
- **数据署名**：`AboutView` 新增「数据来源」卡（OurAirports / OpenFlights / Wikidata + 许可），满足 OpenFlights ODbL 署名要求。新增 `about.data` key（9 语言）。
- **本地化**：新增 `airport.search.*`（5 个）+ `about.data`，9 语言齐全、中文全角、日语常体、韩语해요体。surgical 文本插入。
- **⚠️ 仓库提示**：`Carry/Localizable.xcstrings` 在仓库里是「压缩式」序列化（非 Xcode 规范式），每次 `xcodebuild` 后 Xcode 会把整文件重排成规范式 → 1.5 万行 diff 噪声。本轮已 `git checkout` 丢弃该重排、保持最小 diff。建议择机单独做一次「整文件规范化」提交，之后构建就不再 churn。
- **多语言补齐到全部 9 种界面语言**：数据模型从 `hans/hant` 泛化为 `nm`（{langKey: 机场名}，en 用原名、其余 8 语言取自 Wikidata）；`cs` 城市别名扩到全语言。显示按设备语言（`AirportLocale.languageKey`），搜索跨全语言匹配（뉴욕/ニューヨーク/München/파리 都能命中）。覆盖：fr 91% / ja 82% / zh 75% / de 61% / es 54% / ko·pt-BR 24%，缺失回落英文。数据 ~1.6MB。抓取脚本统一为 `fetch_names.py` + `fetch_cities.py`（替代原 zh-only 两个）。
- **代码审查加固**：解码失败不再永久失能（仅成功置 `loaded`）；`build_airports.py` 加 IATA 唯一/格式硬断言。
- **遗留**：PKX/TFU 等新机场时区暂空（OpenFlights 旧数据 + 中国多时区不兜底，显示可降级，非阻塞）；口语别名如「羽田」搜不到（用 東京/HND/Haneda 可达），非阻塞。

## 上次改动摘要（日历事件叠加层 + 一连串交互/视觉打磨 · 2026-06-16 晚）

> 接费用功能之后的一长串迭代，均已提交并 push 到 `origin/main`、编译绿、多数在模拟器自验过（用户授权自跑）。

- **🟢 日历事件叠加层（新功能，spec: `itinerary-calendar-overlay.md`，Status: Implemented + 自验通过）**：把用户**勾选的**系统日历里、落在行程区间内的事件，作**只读叠加层**显示进行程时间轴（左侧日历色竖条 + 标题 + All-day，轻量、不挂 rail marker）。**隐私红线**：事件只活在视图层临时查询、**永不入 model / 分享 / 导出 / 备份**（由「不入 model」构造保证）。`CalendarManager` 加 `availableCalendars`/`overlayEvents`（排除 `carry://` 自写事件防回环）/`selectedOrDefaultOverlayIDs`（首次默认勾「只读公共日历」=节假日类，非生日/非可编辑）。设置「日历同步」加主开关 + 「选择要显示的日历」卡。点事件 → **Carry 内详情浮层**（`CalendarEventDetailView`，**不跳系统日历**，避免误触跳出 app）。`ItineraryReorderCollection` 加 `.calendarEvent(id:day:)` 行（带天序保唯一）。模拟器实测：端午节/夏至渲染、跨天全天事件每天显示、不崩。
- **设置 UI 打磨**：日历多选从「一列开关」改回**轻量勾选样式 + 默认勾节假日**（用默认那个勾教用户「这些可勾选」，比堆开关又轻又聪明；节假日是公开信息、零隐私）。
- **住宿条对齐根治**：去掉灰底 pill（pill 内边距把图标/文字顶离 rail 网格）→ 床图标落 rail 列、文字落内容列、与停靠点同列；并**接入按天分色**（床图标染当天色，进 Carry 日间色系，比纯灰更暖、不靠盒子）。
- **dateless（PLANNING）行程**：① 整趟还没地点 → **空态引导**（「想去哪些地方?」+ 图标 + 「添加地点」CTA，抑制地图自带提示避免双 CTA）；② 单天标题「Day 1」→ **「想去的地点」**（dateless 永远 1 天、本质是愿望清单）。改日期后地点留在第一天（`syncItineraryDays` 既有行为，已核实）。
- **「地点排序」提到行程面菜单第一位**：本屏规划主任务（先加一堆地点→统一划分到每天），且修复两面菜单不一致（打包面本就「本面专属操作置顶」，行程面现同构）。
- **「地点排序」空天可拖入**：diffable 原生重排无法拖进 0-item section → 空天补 `.emptyDayDrop` 占位落点（「拖到这里」虚线框），可接收落点、提交时被过滤。模拟器实测拖入成功。
- **交通录入表单按类型自适应**（决策详见 decisions）：Type 为单一权威，改它整屏切标签/字段、隐藏无关字段、保存清空隐藏字段。
- **Trip Book 花费卡位置**：移到所有「出行习惯/统计」卡之后（最末，压轴）。**货币 sheet** 选择模式补「取消」。**住宿/航班时间行**布局收成单行（标签·时间·开关）。
- **🔴 修调试开关卡死**：「模拟首页空态」误开后值存进 UserDefaults、每次启动模拟空态（像白屏），Xcode 重装不清 UserDefaults → 重装也不好。改为**每次启动无条件重置为关**（init `=false` + 清 key）；实测 plist 仍 true 时新构建首页仍正常。
- **i18n/性能小修**：费用金额改 locale 感知解析（逗号小数 locale）；`CurrencyCatalog.allCodes` 缓存；新增汇率拉取失败埋点。
- **本地化**：以上所有新文案 9 语言齐全；已核「无硬编码、无缺语言」（脚本扫描通过）。

## 上次改动摘要（费用记录 + 本位币 + Trip Book 花费沉淀 · 2026-06-16）

> 新功能（spec: `itinerary-cost-tracking.md`，Status: Implemented）。Carry app target **编译绿**、待真机验收。**未提交**。与并行会话共享工作区（其正改 `ItineraryReorderCollection.swift`/`ItineraryView.swift` header + progress.md）——我只动自己的 hunk。两个产品决策由用户拍板：**每笔可选币种** + **Trip Book 每趟总花费 + 分类目**；卡片视觉过了 north-star ADA 自审后定稿（比例带 + 单一烟蓝三档 + 去分隔线 + 空态）。

- **🔁 决策反转**：Trip Book 此前「坚决不做花费」（trip-book.md）——前提已变（费用现为用户主动录入数据），反转并落地，已在 trip-book.md 标注。
- **数据地基**：`ItineraryStop`/`TransportSegment`/`LodgingStay` 各加 `costAmount`+`costCurrencyCode`+`costHomeAmount`（抽 `CostBearing` 协议）。**真相=金额+原币种**（永不丢）；`costHomeAmount`=录入时按当时汇率折算的本位币**快照**（推翻初稿「不存快照」——长期记忆 + JPY 等高波动币种下实时折算会算错历史值）。加列=轻量迁移（无 SchemaV2）；`DataBackupManager` 序列化/还原/复制行程全链路带上（可选字段、向后兼容、additive）。
- **本位币**：`ExchangeRateManager` 升共享单例 + base 读 `preferred_currency_code`（设备 locale 默认）；新增 `convertToHome`/`refreshBaseCurrency`/`fetchNow`。设置「通用」组加「货币」行 → `CurrencyPickerView`（全屏可搜索 + 建议分区）。改本位币 → `store.recomputeCostSnapshots()` 按原始金额重算快照（单一不变式：快照永远以当前本位币计）。`DestinationInfoView` 改用共享实例。
- **录入**：抽 `CostInputRow`（金额 + 币种 chip→选择器）；接入 `StopEditView`/`TransportEditView`/`LodgingEditView`，经 `TripStore.setStopCost/setTransportCost/setLodgingCost` 单一漏斗写入 + 就地捕获快照。地点详情 `StopDetailView` 加只读费用行（显真实付款币种，不折算）。
- **Trip Book**：`TripSpendStats`（纯函数 + `CostResolver` 快照优先/实时兜底/未折算诚实标注）；`tripBookSpendCard` 总额 + 比例带 + 三类目 +「查看全部花费」每趟明细。仅 `countsAsVisited` 行程计入；观察共享汇率，rates 到位自动刷新。
- **埋点**：`costAdded`/`costRemoved`（带 category）/`preferredCurrencyChanged`。**本地化**：16 结构化 key × 9 语言（含显式 en、中文全角），脚本 additive 插入（944 + / 0 -，无格式重排）。
- **遗留**：① 交通/住宿时间轴行的行内费用展示（仅地点详情已加）；② `TripSpendStats`/`CostResolver` 单测（无 test scheme）；③ 真机验收；④ Widget target 编译失败是**并行会话**改的 `ItineraryReorderCollection.swift`（`showsOptimize`）所致、非本功能。

## 上次改动摘要（行程：优化顺序入口移到 day header 尾部 · 2026-06-16）

> UX 打磨（无 spec，会话内分析 + 用户拍板）。commit `78bb5a8`，**已 push**。真机验收通过（明暗两态、各天 header 等高、吸顶可达）。与并行会话共享 `ItineraryView.swift`——其费用 hunk 同文件并存，提交时用 patch 精确只暂存自己的 4 个 hunk（`git add -p` 不可交互）、未卷入 cost。
>
> **问题**：「Optimize order」原为每天列表**底部**的内联灰行——地点越多越该用、却被顶得越靠下（相关性与可达性反向），且与高频的 `Add` 等重抢戏、语义上像「路线里又一个节点」。
>
> **解（按 north-star §1 退后 / §2 层级 / §9 顺平台）**：移到当天 **day header 尾部**（对齐 Apple section-header accessory）。
- **可达性**：header 是 `pinToVisibleBounds` 吸顶 → 不论这天多少地点，入口永远在屏幕顶部一伸手可及。
- **层级**：`Add`（追加内容）留内容流；`Optimize`（作用于整天）落标题栏层级；中性 secondary 色 = 工具非主 CTA（不用烟蓝）。
- **门槛**沿用坐标点 ≥4（固定首尾后中间需 ≥2 可重排）；**排序模式下隐藏**（此时在手动拖拽）。
- **§5 节奏**：按钮垂直内边距压到最小（`.padding(.vertical, 4)`），使有/无优化的天 header 近似等高；点击区靠横向铺开补回（矮而宽，对齐「See All」式附属按钮）。图标 `accessibilityHidden`，VoiceOver 只读完整标签。
- **清理**：删 `ItineraryReorderCollection` 的 `.optimize` 行类型 / `optimizeContent` 闭包 / `ItineraryDaySection.showsOptimize` 字段、`ItineraryView.optimizeRow`，无死代码；文案复用既有 `itinerary.optimize.button`、零新增。
- **遗留（可选，当前不做）**：多天均满足 ≥4 时「Optimize order」会出现在每个合格天的 header（已是轻量灰字、契合「每天独立优化」语义）；若日后觉重复仍想更收敛再议。

## 上次改动摘要（距离单位设置：自动/公里/英里 · 2026-06-16）

> spec：`specs/distance-unit-setting.md`。commit `2c53c1c`，**已 push**。模拟器/真机验收通过（英里 `20 mi/6.1 mi/3.8 mi` ↔ 公里 `33 km/9.9 km/6.1 km`，时间轴段距实时切换）。**一级菜单分组/排序待后续统一调整**（用户明确留到后面统一调）。

- **新增 `Carry/Models/DistanceUnit.swift`**：`DistanceUnit` 枚举（automatic/kilometers/miles），`.automatic → MKDistanceFormatter.units = .default`（交回 locale）→ 设备地区默认零回归；存 `@AppStorage("distance_unit")`。同文件 `CarryDistanceFormat.string(meters:unit:)` 为**全 App 距离展示单一入口**（每次 new 轻量 formatter，不复用全局可变 formatter 避竞态）。
- **根因覆盖（消灭两套 formatter）**：原有 2 个 `MKDistanceFormatter`、3 个展示点——① `ItineraryView` 全局 `legDistanceFormatter`（驱动时间轴段距 `ItineraryLegConnector` + 地点详情「到下一站」路程模块，二者共用 `legLabel`）；② `OptimizeRouteView` 自建 formatter。两处删本地 formatter、统一改 helper + `@AppStorage("distance_unit")`，切换后**实时重渲染**（不退页面）。全仓确认无第四处距离展示（仅剩温度 `MeasurementFormatter`，不相关）。
- **设置 UI**：`SettingsView` 在「个性化」后新增**「通用 / General」分组**，「距离单位」行完全对标「外观」行（Button + 右侧当前值 + chevron，点按弹 `confirmationDialog` 列三档）。
- **本地化**：5 个结构化 key × 9 语言（含显式 en）——`settings.section.general`/`settings.units.distance`/`distance_unit.{automatic,kilometers,miles}`。混合格式 xcstrings 用定向文本插入（295 行纯新增、其余字节未动、格式匹配 Xcode），957→962 key。
- **工程**：文件系统同步分组，新文件自动纳入 target 无需改 pbxproj；无 schema/迁移/备份改动（设备级偏好，同 Appearance 惯例）；编译绿（主 app + Widget）。

## 上次改动摘要（行程地点详情：交通方式选择器 + 联动导航 + 修复打磨 · 2026-06-16）

> 续上「停靠点只读详情」线（spec: `itinerary-stop-travel-modes.md`，Status: 已拍板 Path C）。在 main、未 push。与并行会话共享工作区，全程 hunk 隔离、只提自己改动。commit `151197c`/`1751765`/`e80202f`/`bee632d`/`3663726`。真机验收（地图调起）待用户。

- **交通方式选择器 + 联动导航**：详情路程模块在 Get Directions 之上加 4 段选择器（驾车默认 / 公交 / 步行 / 骑行），选中即联动外部地图调起的方式。**否决「App 内显时长」**（Apple `MKDirections` 无骑行 + 用户明确不接路由 API）→ **Path C：只选方式 + 调起、不显时长**；到下一站直线距离保留。
- **各家 × 方式过滤**：`MapNavigationApp.supports(_:)` —— 仅 **Apple 无骑行**，选骑行时 List 隐藏 Apple、其余照常；0 可用时置灰 + 提示。`open(_:mode:)` 各家拼方式 URL（Apple Driving/Walking/Transit、高德 t=0/1/2/3、Google driving/transit/walking/bicycling、百度 driving/transit/walking/riding）。过滤在视图层就地做（`navApps.filter`，复用 onAppear 缓存、不重跑 `canOpenURL`）。
- **公交（决策反转纳入）**：原 spec「不做公交」——评估后纳入。与骑行相反：公交四家 deep-link 文档上**都支持**（含 Apple），故 `supports` 公交暂全 true、**待真机实测**再定稿过滤。选择器 4 段、文字 `lineLimit(1)+minimumScaleFactor(0.8)` 防窄屏/长语言挤压。
- **底部留白修正**：`StopDetailView` 去 NavigationStack 后，`contentDetents` 的 `+72`（含已不存在的导航栏 ~44pt）成了 Edit 下方凭空留白 → 重算为 `+28`（仅留 home-indicator 气口）。
- **🔴 修崩溃（code-review high 抓到）**：点某天**末站**（有坐标时）→ `distanceToNextStop` 算出 `index+1==count` 传入 `legLabel`，后者只挡 `index>0`、未挡上界 → `stops[index]` 越界 SIGABRT。根因解：末站返回 nil + `legLabel` 下标加 `index<count` 兜底（覆盖所有调用路径）。
- **质量收口**：删死代码 `availableApps(for:)`；`open()` Apple 分支由 `default` 改穷举 switch（加方式即编译报错、不静默退化驾车，与高德/Google/百度一致）。
- **地点名 ↔ 时间垂直居中**：名称行原 `.firstTextBaseline` 共享基线 → 小字号时间视觉中心落在名称中心之下、看着偏下；改 `.center` 居中（对标日历/Mail）。
- **文案**：方式名 ×4 + `no_app_for_mode` × 9 语言，定向插入 xcstrings、无格式重排。**埋点** `itineraryStopNavigated` context 带所选 mode。
- **遗留待办**：真机验四家地图 × 四方式调起（尤其**公交**各家是否正常），据此决定 `supports()` 是否过滤某家公交。

## 上次改动摘要（行程停靠点：只读详情 + 导航入模块 + 列表打磨 · 2026-06-15）

> 在 `main` 上一串迭代（spec: `itinerary-stop-detail.md`）。与并行会话共享工作区，全程 hunk 隔离、只提自己改动、未卷入并行代码；所有视觉/交互在模拟器逐版自验（用户授权自跑）。未 push。

- **点停靠点 → 只读详情态（`StopDetailView`，半高 sheet）**，不再直接进编辑：契合「这屏多数来看信息」、避免误改时间/位置；编辑收到右上角 Edit 入口（钻入 `StopEditView`，@Model 可观察、保存后详情自动反映）。
- **导航从每行外层 ↗ 收进详情「路程模块」**（Get Directions 复用 `MapNavigationService` + 到下一站直线距离）；行尾腾空 → **开始–结束时间移到名称行右对齐**（地点=什么、时间=何时，对标日历/Flighty/Tripsy）；行内只留「无坐标」轻提示。
- **🔴 修回归**：时间移进名称行后外层 content 失去贪婪 Spacer，body 默认居中 VStack 把「无时间 + 有备注」的行（恒大）主行居中挤偏右。给内容块 `.frame(maxWidth:.infinity, .leading)` 恒满宽左齐修正。**排查靠 debug 边框**（代码层查不出 → 上可观测手段）。
- **长备注**：详情里备注默认折叠 6 行 + 展开/收起（`ExpandableText`，同字体同宽测全文/折叠高度对比判断是否截断，非字数启发式）；避免长备注撑满、把导航模块挤到底。
- **地址点按复制**（发给同行/粘进打车 App 的高频需求）：触感 + 绿勾「已复制」1.6s 反馈 + copy 图标提示。**VoiceOver**：装饰图标隐藏、导航/地址有朗读标签与 hint、点击区 ≥44pt（ADA §9）。
- **sheet 高度贴合内容**：稀疏地点不再留半屏空白（量内容高定 detent），内容多自然撑大、展开长备注随之长高。用有意留白消灭空旷而非塞空字段（评估后**否决「Tripsy 式显示空字段」**：那是它的编辑页、Carry 已分离查看/编辑、空占位违克制）。
- **列表去备注预览**：两行备注让行高参差、破坏工整 → 列表只承载名称/时间/地址，备注留详情。
- 新增 detail 文案（edit/navigate/to_next/note_more/note_less/address_copied/copy_hint）× 9 语言，定向插入 xcstrings、无格式重排。
- commit：`086fe3c`/`449365e`/`3baed14`/`7dd30d5`/`2885ef0`/`15d7495`（均在 main、未 push）。

## 上次改动摘要（修复：首页 Sheet 展开吸附过冲漏 MapKit · 2026-06-15）

> 果冻回弹（§19/spec home-sheet-snap-spring）上线后用户报"展开到顶回弹时底部仍漏地图"。真机确认 + 代码层定位真因后一行根因解。commit `b58b478`，已 push。详见 playbook §20。

- **真因**：FX 卡片三层 `outerView/innerView/hostingView` **本身全透明**，Sheet 底色仅由内容里的 `CarrySubtleBackground` 画；内容固定高 = expandedHeight、钉在 innerView 顶部。展开吸附 spring 过冲把 `innerView.bounds` 瞬间撑过 expandedHeight → 底部约 56pt 一条「无内容无背景」透明带 → 漏 MapKit。
- **解**：给 `innerView` 自身一层不透明兜底背景 = `CarrySubtleBackground.baseColor`（渐变底端同色）；`ViewModifiers` 暴露 `baseUIColor` 作单一动态色源。卡片从此不透明、过冲带露出同色而非地图。不碰几何/吸附/手势/内容尺寸。
- **走过的弯路（已回退）**：先误判为"卡片底缘被抬起"去改 outerView 锚点——逐帧推算证明底缘全程 ≥ 屏幕底、并未抬起，那是修错地方、已完全回退。教训：动画漏底先分清"位移"还是"覆盖不足"。
- **通用教训**：固定高内容 + 透明卡片，遇"可视窗口瞬间撑过内容高度"的动画（过冲/橡皮筋）必漏底——卡片应自带不透明背景。

## 上次改动摘要（行程「地点排序」模式 · 2026-06-15）

> 从行程页 "…" 菜单进入的专门排序态，解决「拖拽可发现性低」+「批量跨天重排累」。commit `518a121`；模拟器自测通过、待用户真机验收。spec：`itinerary-reorder-mode.md`。分支 `feature/itinerary-transport-lodging`、与并行会话共享工作区，全程只提自己的 4 个文件。

- **入口**：`PackingListView` 行程面 "…" 菜单加「地点排序」（`itinerary.reorder.menu`，≥2 地点才显示，与每日 Optimize 成手动/自动一对）；进入后工具栏 …→完成（复用 `common.done`）、隐藏底部「行程/打包」切换器。
- **模式表现**：`ItineraryView` 模式内 stopRow 渲染**压缩行**（类别图标 + 名称 + ≡ 手柄）、不挂 tap（锁误触）；`ItineraryReorderCollection` 只渲染 day header + `.stop` 行（隐 leg/交通/住宿/Add/Optimize），长按 `minimumPressDuration` 0.4→0.15（即抓即拖、>0 防滚动误判）。
- **机制**：collection `.id` 含 `isReordering` → 进出模式重建、cell 刷新；提交复用既有 `onArrange`（跨天改归属），无新数据路径/迁移。**保留常驻长按拖拽**（非独占）。新增 `itinerary.reorder.menu` 9 语言。
- **自测**：天内/跨天拖拽 ✅、地图随拖实时更新 ✅、退出恢复完整行+chrome ✅、常驻长按未被破坏 ✅、无约束冲突/AttributeGraph 重入/崩溃。

## 上次改动摘要（行程时间轴视觉打磨 + 打包重命名闪退修复 + 首页空态蒙层 · 2026-06-15）

> 分支 `feature/itinerary-transport-lodging`，与并行会话共享工作区；以下全程按 hunk 隔离、只提自己的改动，未卷入并行代码。所有视觉改动在模拟器 1:1 逐版验过。

- **🔴 修崩溃（打包重命名 → 返回闪退）**：左滑「编辑」进重命名态后点返回，`ReorderableItemCollection.applySnapshot` 给 diffable `reconfigureItems` 传了**重复 identifier**（`previousEditing == editingItemId` 时 `[prev, cur]` 给出同一 id 两次）→「item identifiers are not unique」断言 → SIGABRT。改为只 reconfigure「编辑表现真正切换」的行 = 两者的**对称差**（天然去重；未变→空集，顺带不再每次按键重建编辑行），并把 reconfigure 从异步 completion 移到同步紧跟 apply，消除拆除竞态。
- **行程日期头去分隔线**：流式/吸顶**全程不画线**——粗体圆体标题 + 当天彩色圆点 + 留白本身层级已足，吸顶时不透明 systemBackground 已切开内容，再加线是多余 chrome（对标 Tripsy/Flighty/原生）。打包分区头是 ALL-CAPS 小灰字、分量轻，**保留**锚定基线（两屏差异有意、说得通）；曾尝试「仅吸顶显示」的 UIKit 检测机制，定稿为「永不画」后**整套删除、无死代码**。
- **Timeline 类别图标放大**：圆点 24→28、字形 11→13，rail 列 26→30 四处（停靠点圆点/日期头圆点/段距/内联动作）同步对齐——更可扫读且仍明显轻于地点名。
- **备注预览**：去前导 `note.text` 图标、纯文本左齐（名称/地址/备注共一条左缘），配色 secondary→tertiary，落成 primary/secondary/tertiary 三层标签层级，与地址一眼分得开。
- **时间轴连线 + 段距**：① 修 `noteRow` 连线列填满整行高——带备注停靠点处竖线原本断一截，现全程连续；② 段距（29 km…）定稿为**夹在竖线里**（数字居中压在 spine、上下两段线接住），切口加横向 5pt + 上下 1.5pt 气口，不挤不飘。`#2` 带备注处距离不落在两圆点几何正中——经判断**保持现状**（距离在「含备注的内容块」下方居中，符合 Maps 等惯例；强行几何居中会让距离与备注并排、更乱）。
- **首页空态去蒙层**：`bottomContentFade` 本给「列表滚到底部浮条下消隐」用，却无条件加在容器上；空态时 sheet 按内容收缩、只有一张空态卡片、无可滚动列表，这条 120pt 渐变反而把卡片下半截（含「Add First Trip」按钮）蒙白。改为 `height: isEffectivelyEmpty ? 0 : 120`（空态不铺）。模拟器 DEBUG 空态开关复现 before/after 验证闭环。全 app 扫查确认同类隐患仅此一处（ItemPicker 的 fade 是 smart-only + 顶部锚定内容，安全；bottomBarScrim 是实心底栏，非蒙层）。

## 上次改动摘要（行程交通段 + 住宿 + 签证 PDF 导出 · 2026-06-15）

> **已合并 `main` 并 push**（merge `4cacbc8`，功能分支已删、远端旧分支已清理）。全程编译绿（主 app + Widget）、**待真机验收存航班/住宿两条流程**。spec：`itinerary-transport-lodging.md`（规划层）+ `itinerary-export-document.md`（导出）。借 Tripsy 的「节点+边+跨度」数据模型，用 Carry 克制审美定呈现与范围。

- **数据地基**（`Itinerary.swift`/`CarrySchema`/`TripStore`/`DataBackupManager`）：新增 `TransportSegment`（边：航司/班次、起讫站+代码+坐标+时区+航站楼、跨天起降、预留 `liveStatusData` 给未来航班动态）、`LodgingStay`（跨度：day sortOrder 锚定、`covers`）；`ItineraryDay.timeline` 把 stop+transport 按共享 sortOrder 合并（`TimelineItem`）。轻量迁移加表、单一 SchemaV1；CRUD + duplicate 深拷贝 + 备份/还原/导入全链路（可选字段，向后兼容）。
- **录入 UI**：`TransportEditView`（航班/火车/通用，起降站可地理搜索）、`LodgingEditView`（名称/地址+入住日+晚数+时间）；抽共享 `ItineraryPlaceSearchSheet`。
- **接入时间轴**：`ItineraryReorderCollection` 行模型加 `.transport`/`.lodging(stay:day:)`，section 改有序 `entries`，leg 仅在相邻两停靠点间无交通段时插；交通/住宿固定行、仅 `.stop` 参与重排（拖拽逻辑不动）。`ItineraryView` 底部「+」改统一 Menu（地点/航班/火车/住宿）；交通连接行 `TransportTimelineRow`、住宿三态 `LodgingBannerRow`（入住/过夜/退房）。地图航班画大圆弧虚线、取景/空态纳入交通端点。
- **🔴 修崩溃**：住宿跨 N 天时 `.lodging(stay.id)` 在多 section 重复 → diffable item 标识须全局唯一会崩；行 ID 改带 day 维度。
- **签证 PDF 导出**：`ItineraryPDFRenderer`（A4 分页，头部+概览图+逐日+住宿汇总+页脚）、`ItineraryDocumentText`（文档文案 EN/ZH 代码字典，按所选语言渲染）、`ExportItinerarySheet`（语言/申请人姓名·目的[选填本地存·不含护照号]/含地图开关）；入口在行程「…」菜单。定位为「行程说明」非预订凭证/官方文件。
- **埋点**：`transportAdded/Removed`、`lodgingAdded/Removed`、`itineraryExported`、`itineraryExportFailed`。**文案**：交通 24 + 住宿 14 + 菜单 2 + 导出 6 = 46 个 key × 9 语言。
- **埋点**：交通段时间就位（设了出发时间按时间插入停靠点序列、停靠点保持手动序）+ 地图交通端点标记。
- **协作注**：与并行会话共享工作区，`ItineraryView.swift` 编辑期间一度被并行进程瞬时回退（已即时编译+提交锁定，无丢失）。
- **🔴 健壮性修复**：① 缩短行程天数原会随删天**级联丢交通段**（`syncItineraryDays` 现把交通段同停靠点一起挪到保留天、起降天序回收）；② 住宿 `checkInDayOrder` 越界夹回有效区间（不再孤立看不见）；③ PDF 文件名日期改手拼 `yyyyMMdd`（locale 会重排成 MMddyyyy）。
- **自验（模拟器，2026-06-15）**：迁移安全（真实 14 行程启动无崩）、统一「+」菜单、航班表单、导出页、**PDF 端到端**（标题+路线图+逐日含地址+页脚、中文无乱码）均✓；新文件无未守卫强解包、住宿跨天 item 唯一。**未自验**（模拟器自动键盘输入乱码）：存航班/住宿后的时间轴行 + 跨天住宿三态崩溃，交真机验。
- **范围定稿（已与用户确认）**：航班动态需外部 API、PDF 中英对照、Excel 导出——三项均**不做/留后续**，核心功能无半截。
- ✅ **已合并 `main` + push + 清理仓库**：merge `4cacbc8`（代码零冲突、仅 progress.md 摘要块冲突已解）；删本地功能分支 + 远端 3 个已并入旧分支（home-ui-redesign / globe-camera-race / zh-punctuation），本地远端现仅剩 `main`。
- ⏳ **待办（交真机）**：① 存一条航班/火车 → 时间轴连接行 + 地图弧线 + 端点标记；② 加 ≥2 晚住宿、来回切天 → 入住/过夜/退房三态**不崩**（跨天行 ID 修复已编译+审计、未运行时验）；③ 备份还原 / 复制行程后交通+住宿保真；④ 缩短行程日期后交通段不丢、住宿夹回（健壮性修复，建议验）。

## 上次改动摘要（首页 Sheet 自动吸附：克制果冻回弹 · 2026-06-15）

> 下拉收起/上拉展开松手落位带**克制 spring 过冲**（非明显果冻）。仅改 `commitSnap` 直接吸附分支两个参数：展开 `dampingRatio 0.74 / 0.52s`、收起 `0.82 / 0.46s`（临界阻尼 1.0 → 欠阻尼）。真机验收 + 全盘审计通过、已提交（未 push）。

- **推翻旧禁令**：playbook §5/§13"直接吸附必须无回弹"已受控放开——旧禁令针对多驱动竞争伪影，根因已随单一 CA 通道重构消除；现过冲由唯一 animator 干净插值、只经唯一漏斗 `placeSheet`，是设计效果。仍禁第二驱动源 / 动画开始推 `shapeProgress` 终态 / `startSnapShapeFollow`。
- **几何安全**：展开过冲推底缘出屏、收起过冲只放大浮动间隙 → 均不漏 MapKit；底栏搭同一 animator 一起弹。
- **打断安全**：`beginInteractiveControl` 先增 generation 再停 + presentation 层钳位双保险。
- 文档：spec `home-sheet-snap-spring.md`（Shipped）、playbook §5 放开注脚、decisions 2026-06-15 条。

## 上次改动摘要（首页底栏随 Sheet 同步缩放·终极版 + 全盘审计 · 2026-06-14）

> 首页底栏（搜索 / 行程册 / 创建 FAB）从 HomeView 的 `.safeAreaInset` **移进 `FXSheetViewController`**，与卡片由**同一个 `UIViewPropertyAnimator`** 驱动 → 像素级同步缩放（取代基线近似版 `b2be676` 的 SwiftUI `scaleEffect`）。已提交 `main`（`7a5a900` 实现 + `efddd1d` playbook §19 审计存档）、真机+模拟器双验收通过。详见 `docs/home-sheet-debug-playbook.md` §19。

- **机制（同 animator·无第二驱动）**：底栏宿主钉 `view` 底（约束=原 18pt padding）、z 序在卡片上、不入 outerView；缩放在唯一漏斗 `placeSheet` 里对 `barView` 施加**底边锚定**同 `scale` transform（`translate(0,(1-s)·h/2)·scale(s)` ≈ `.scaleEffect(anchor:.bottom)`）。吸附时 `placeSheet(at:target)` 在 snap animator 块内被调用 → 底栏被同一 animator 插值；拖拽时逐帧 set（无隐式动画）跟手。守住 playbook §5（不加第二驱动）。
- **手势穿透（头号风险·已守住）**：底栏空白区 HostingController 返回 nil → pan 穿透到列表（从底栏上滑仍能滚列表）；按钮吃 tap；列表底部 124/176pt 占位行兜底。删除基线的 `SheetScaleModel`/`onScaleChanged`/`BottomBarScaleSync`/`import Combine`（不留过渡件）。
- **全盘审计结论**：静态全链路 + iPhone 17 Pro 模拟器实测，无 bug/崩溃/死锁/循环引用；运行时零 Auto Layout 约束冲突、零 AttributeGraph 循环、零泄漏；展开/收起/新建/滚动/三按钮全通过。正确性由构造保证（所有运动经 `placeSheet`、底栏与卡片天然同步）。
- **唯一已知取舍（非 bug）**：去掉基线"透明吸 tap 背景"后，底栏三按钮间两条 ~14pt 空隙的**点击**会穿透到列表行——为保住"底栏上滑滚列表"而做的架构性取舍（二者在 UIKit 兄弟视图下互斥），危害可忽略，保持现状。
- **还原点**：`b2be676`（`git checkout b2be676 -- Carry/Views/CarryBottomSheetFX.swift Carry/Views/HomeView.swift`）。

## 上次改动摘要（行程地图预览：空态改「地图永不为空」· 2026-06-14）

> `ItineraryMapView` 顶部预览的空态原是灰色渐变占位盒（map 图标 + 「还没有地点」），用户反馈「空空的」。根因＝把内容位让给了 chrome 占位盒，且当天空时常谎称整趟空白。按 north-star §1（内容为王）/§8（叙事）/§9（顺平台，对齐 Apple Maps「地图永不是灰盒」）重做。已提交 `main`、编译绿（主 app + Widget）、待真机验收。

- **预览三档判定（`PreviewMode`）**：① 当天有地点 → 正常路线图（不变）；② 当天空、整趟别处有地点 → 铺**整趟真地图、其它天针/线淡化**（marker opacity 0.4、polyline 0.3）+ 底部胶囊「这天还没安排地点」（`itinerary.empty.map.day_hint`），给地理上下文、不谎称空白；③ 整趟空、目的地已解析 → 居中**目的地真地图**（复用 `TripBundle.latitude/longitude`，0,0=未解析则跳过；span 0.6 区域级、无针）+ 底部胶囊「添加第一个地点」（`itinerary.empty.map.invite`，出发邀请）；④ 兜底（整趟空且目的地未知，如无日期行程/geocode 未完成）→ 保留原灰盒空态。
- **可展开门控**：`isExpandable` 仅 route/context 为真（有真实路线可看才点开全屏）；destination/placeholder 不可点，避免展开到空世界图。
- **重构**：抽 `expandControl`、通用 `mapHint(_:systemImage:)`（material 胶囊 + 圆体，空当天/邀请共用）；`mapContent`/`mapAnnotations`/`stopMarker` 加 `dimmed` 参数（仅 context 预览淡化，全屏与正常态不受影响）。
- **删单点提示**（后续微调）：route 态 `coordinateCount == 1` 原显示「再加一个地点就能连成路线」——针本身自解释、添加入口就在下方列表，属多余 hand-holding（§1），去掉；`itinerary.single.map.hint` 死 key 连 9 语言一并删除（899→898）。
- **文案**：新增 2 结构化 key × 9 语言（含显式 en），术语沿用「地点」，中文无半角标点；按 Xcode 展开式定向插入（文件为混合格式，避免全量重排大 diff），JSON 校验通过。

## 上次改动摘要（分享行程：海报 + 路线地图 + 预览 + 发送给朋友/导入 · 2026-06-14）

> 「分享」主线落地，均已提交 `main`、编译绿、真机验。两个独立入口（行程「…」菜单，`detailTab==.itinerary` 时）。详见 decisions 2026-06-14。

- **分享行程 → 海报图**（commit `a3affb1`/`83e3488`/`353aecd`；新 `TripSharePoster.swift`/`SharePreviewSheet.swift`）：竖版海报 = 封面照（`FocalCoverImage` 焦点对齐，海报头与卡片比例不同故不用 `PositionedImage`）+ 按天地点时间轴（当天色连接线）+ **底部路线地图带**（`MKMapSnapshotter` + 图钉 + 白描边动线，缩放框住所有点，无坐标/失败降级）+ Carry 水印；固定浅色渲染。**分享前预览页**：点分享先弹大图预览 +「包含路线地图」开关 + `ShareLink`；海报渐进渲染（先无图、地图异步合入）。文件名 `行程名_天数_出发月份_yyyyMMddHHmm.png`。
- **发送给朋友 → `.carrytrip` 文件**（commit `14b4fa6`/`20d3d74`；新 `ImportSharedTripSheet.swift`）：导出仅行程规划（复用 `CarryBackup` 格式）；Info.plist 注册文档类型（UTI `com.murphy.carry.trip` + `LSSupportsOpeningDocumentsInPlace`）→ 点 `.carrytrip` 即唤起 Carry → `onOpenURL` 读摘要 → 确认卡片（行程名/日期/地点数）→ 导入。**新建 / 更新（同 UUID 替换行程规划、不动打包清单）双路径**，沿用发送方 UUID。文件名 `行程名 (出发月份).carrytrip`。`DataBackupManager` 加 `makeItineraryShareFile`/`readSharedTripSummary`/`importSharedTrip`。
- **行程详情默认面：消除「偶尔闪打包」**（commit `07f5b0f`）：初始面改在 `PackingListView.init` 解析（记住每个行程上次的面、无记录则行程规划），不再靠 onAppear 把默认 `.packing` 纠正（push 动画里会闪）。
- **全 App 模态总审计完成**（commit `0cfe203`）：按 Carry Modal Convention 5 条逐个核对，全部合规、无违规。
- 埋点 `itineraryShared/itineraryFileSent/itineraryImported/itineraryImportFailed`；新增文案均补全 9 语言（`itinerary.share*`/`itinerary.import.*`/`itinerary.send_to_companion`=「Send to friend / 发送给朋友」）。
- 工程约定：CLAUDE.md 新增「验收默认交给用户、不主动驱动模拟器自跑」（commit `6d923e3`）；`.gitignore` 加 `.claude/`（`bd4578d`）。

## 上次改动摘要（编辑地点重构：标签/位置分离 + 开始结束时间 + 备注预览 · 2026-06-14）

> 经多轮真机走查打磨。合并提交 `bafa93c`（多会话共编同批行程文件 + Xcode 重排 xcstrings，无法干净 hunk 隔离，按用户决定一次合并；编译绿）。

- **编辑地点（StopEditView）重排为「地点 / 详情」两段**：
  - **地点**段：名称＝**显示标签**（可自定义、不动地图定位）/ 地址（只读 + mappin）/ **更换地点**；footer「在行程里显示的名字，可自定义」——分清「改标签 vs 换地点」（用户原困惑「名称是做啥用的」）。段标题用「地点(Place)」而非「位置(Location)」。
  - **详情**段：类型 + 设定时间（**开始 + 结束**，结束以现成 `stayMinutes` 存，不改 model）。时间轴行 stayMinutes>0 时显示「开始–结束」。
- **更换地点**：`AddStopView` 加 relocate 模式（`relocateStopId`/`onRelocated`）——复用搜索，选中结果调 `updateItineraryStop` 改坐标/地址/名称（类别不动、隐藏类别菜单）。`updateItineraryStop` 扩展 `latitude/longitude/address`。
- **备注行内预览**（TimelineStopRow）：有备注的行在主行下方挂**独立预览行**（note 图标 + 截断 2 行）+ 左侧延续连线列——**不动固定 46pt rail 几何**，零几何风险。
- **Type 行 原生 Picker → 自定义 Menu**：菜单 Picker 的「收起选中值」由系统紧凑渲染、无视选项自定义间距（下拉松/收起挤、SwiftUI 不可控）；改 Menu 后收起值标签手搓，图标↔文字 6pt 呼吸感；下拉仍系统 Picker。
- 新增 `itinerary.stop.edit.*` 9 语言（start/end_time·location/details_header·name_footer·relocate·set_location）；`location_header` 值改「地点/Place」。xcstrings 用脚本法（`separators=(',', ' : ')`）原子编辑避开 Xcode 补壳竞争。
- 注：本批与并行会话的停靠点导航 / leg 行 / 行程分享深度交织，合并一并收进。

## 上次改动摘要（行程页日历↔列表联动 + 添加地点背景 + 首页搜索标题 · 2026-06-14）

> 三处交互/视觉打磨，均编译绿、iOS 26.5 模拟器实地走查（Light/Dark），按文件隔离提交、未卷入并行会话改动。commit：双向联动 `944ec24`、添加地点背景 `653ef83`、搜索标题 `08dbc2a`。

- **行程页 日历 ↔ 列表 双向联动**（`944ec24`，`ItineraryReorderCollection` + `ItineraryView`）：切日历某天→列表把该天 section 吸顶（header 本就 `pinToVisibleBounds`，落位即吸顶）；反向手动滚列表→上方日历高亮跟随当前吸顶天 + 日历条横向自动居中。**防回授**：`lastScrolledDayId` 单一真相 + `isProgrammaticScroll` 标志切断「程序滚动→didScroll→回写选中→再程序滚动」环。
- **🔴 末日吸顶补偿**：最后一天地点少时下方无内容可顶→吸不到顶。按需补底部 `contentInset`（=视口高−末段高，数学上与吸顶偏移对齐 `maxY==targetY`）；够长的日子算 0 不补、内容增删后自动重算。末段高用「首行 minY − header 高」反推，避开 pinned header 坐标失真。
- **添加地点页 Light 顶部背景割裂**（`653ef83`，`AddStopView`）：根因＝搜索框 band 涂 `systemGroupedBackground`、而 `.insetGrouped` List 在 sheet 里默认渲染白底，两块底色交界出现硬边。改为不靠两块各自上色赌一致→`scrollContentBackground(.hidden)` + 显式铺一层统一 grouped 底，接缝从根上消除。
- **首页搜索态保留「我的行程」大标题**（`08dbc2a`，`HomeView.searchSheet`）：进搜索后只剩搜索框、顶部失重显空。让首页大标题延续进搜索态（30pt rounded、与首页主标题一致，标题在上搜索框在下），接近原生大标题搜索；不加「搜索行程」这种与 placeholder 重复的冗余标题（用户拍板字号维持 30pt，连续感优先）。

## 上次改动摘要（行程优化页：钉底 CTA + 道路口径判定 + 背景无缝 · 2026-06-14）

> 接行程规划视觉审查 P1/P2，针对优化路线页做真机走查打磨，并落地「道路口径判定」行为变更。我的三个 commit 已 push 到 `main`（字体系统 `2b1dc4a`、优化页打磨 `035425c`、钉底+道路判定 `50af4ea`）。按 hunk 隔离、未卷入并行会话改动。

- **优化页地图针/标题/按钮**（`035425c`）：系统 `Marker` 气泡 → 自定义圆形序号针（与行程主图 `stopMarker` 同语言）；删正文重复的「优化路线」H1、以「第 N 天」为主行；底部从「取消/采用」双按钮（`.bordered` 与自定义实心混搭、圆角不一致的 bug）收成单个全宽 CTA。
- **底部 CTA 钉底常驻**（`50af4ea`，`safeAreaInset(.bottom)`）：长清单无需滚到底即可采用；进出走顶部常驻「取消」。文案「采用这个顺序」→「采用此顺序」（zh-Hans/zh-Hant；其余 7 语言本就简洁未动）。
- **🔴 道路口径判定是否改进**（`50af4ea`）：修「优化却没省/变长（节省 0）」——排序仍用直线，但「是否算改进」改用**道路距离**（可得时）；没省/更长→「已较优」、离线/6s 超时→退回直线+注脚。方案 A 渐进披露（地图/顺序先出、判定区后定）。`RouteOptimizer.isImprovement` 抽纯函数（7 例独立验证）。详见 `decisions.md` + `specs/itinerary-optimize-road-gating.md`。
- **底部钉条背景无缝**：原 `.regularMaterial` 在深背景上偏亮成色带；改为**实心 `CarrySubtleBackground.baseColor`**（= design-system「底部主按钮容器实心、禁渐变」规范的二级页色，新增 `baseColor` 单一色源）——同色无缝。注：本条收尾时发现初版用了渐变、违反该规范，已改回实心对齐。
- **遗留 / 待办**：① 道路判定 4 态真机验收（improved/notImproved/computing/offline）；② P1/P2 其余视觉审查项已全部落地。`progress.md` 由并行会话维护，本块仅记我这摊。

## 上次改动摘要（修复背景图构图无法缩放/拖动 · 2026-06-14）

> 用户报 bug：行程/打包页「上传背景图」选图后被放大到很大、且无法缩放（以前可调）。回归源于 6 天前重构 `a0d64b7`。已提交 `5fcdf20`，iOS 26.5 模拟器实测验证。

- **根因**：重构把构图重配判定从 `configured: Bool`（配一次）改成比较整个 `scrollView.bounds`。但 `UIScrollView.bounds.origin` **就是 `contentOffset`**——捏合/拖动时必变 → `configureIfNeeded` 每个手势都重新触发、把 `zoomScale` 与偏移重置回 `fillScale`，导致画面卡在填充态、动一下就被打回。
- **修复**（`BackgroundReposition.swift`）：只比较 `bounds.size`（窗口尺寸），不比较携带滚动偏移的 origin。`lastConfiguredBounds: CGRect` → `lastConfiguredSize: CGSize`。保留"窗口真正改尺寸（转场落定/旋转）时重算"的本意，交互时不再误重置用户构图。
- **诊断方式**（守纪律）：纯读码推断两次未定位 → 改用可观测手段：加 `NSLog` 跑模拟器，日志直接显示 `configured` 随 `bounds.origin` 变化反复触发（size 恒定）。修复后实测 `configured` 仅 1 次、拖动平移后画面停住不弹回。调试日志已移除。

## 上次改动摘要（搜索框统一组件 CarrySearchField · 2026-06-14）

> 三处搜索框（首页搜索行程 / 添加地点 / 添加物品）原各写一份、圆角不一致（首页 24pt、其余 12pt）。抽共享组件收成单一真源。已提交 `395d52d`；明暗双模真机/模拟器走查，三框已视觉一致。

- **新增 `CarrySearchField`**（`ViewModifiers.swift`，与其它共享 View 组件同处，无需改 pbxproj）：单一形态——12pt `.continuous` 圆角 / 44pt 高 / body 字号 / 放大镜 + 清除按钮（`common.clear` a11y）+ `.spring(0.2,0.1)` 清除动画。表面走 design-system「描边主导」唯一款：`systemBackground.opacity(0.84)` + 细描边（Dark 0.12 / Light 0.08）——描边让它通吃任何底色，故不分上下文（曾短暂引入 `.plain/.grouped/.floating` 三表面枚举，后按用户拍板「全描边主导」删枚举、收单一形态，避免死代码）。带可选 `trailing` slot。
- **三处替换**：HomeView `searchSheet`（24→12，去掉内联实心框，旁留「取消」）；AddStopView `searchField`（`.grouped` slot 放类别菜单，外层 `systemGroupedBackground` 底条保留）；ItemPickerView `searchBar`（删随之失效的 `searchPlaceholderText` 死代码）。
- **回写 design-system.md** §搜索框：组件 + 形状 + 描边主导唯一表面 + 通吃底色的原理（纯实心才有「同灰隐形」坑）。

## 上次改动摘要（模态呈现规范统一：创建/快速添加改 cover/sheet · 2026-06-14）

> UI 走查呈现方式。确立 **Carry Modal Convention**（详见 `design-system.md` §Carry Modal Convention + `decisions.md` 2026-06-14）：按语义选 push/sheet/cover。均已提交、编译绿、真机/模拟器验。

- **创建行程：push → `fullScreenCover`**（commit `195f362`）。自包含任务而非根层级——iPhone 用 cover + 独立 `NavigationStack(creationPath)` 跑三步链，`finishCreation` 关 cover 并把根 path 落到新行程（保留建完即进入的动量）。`NavigationRouter` 加 `creationPath/showCreation/seed` + `begin/finish/cancel/pushCreation`；后两者在 `showCreation==false` 时退化为根 path → Mac Catalyst（仍 push）与 autoPack 流不受影响、一套代码两平台。TripInfoView cover 内显示「取消」。
- **快速添加物品：push → `.sheet`**（commit `bdcbb66`）。行程内子任务，与编辑场景/分类/提醒一致。PackingListView 三处 `.addItems` push → `showAddItemsSheet`；ItemPicker merge 模式 `removeLast`→`dismiss` + 加「取消」；清掉死掉的 `.addItems` 路由。
- **其余流程（编辑行程/场景/分类/提醒/背景图）经 chrome 核对本就合规，未改**（不为改而改）。
- **范围**：仅行程生命周期相关流程；全 App 模态总审计（设置 hub/Roadmap/关于/行程内部 sheet/地图全屏/picker 等）未做。

> 接字体系统对齐之后，处理视觉审查里剩下的 P1/P2，并把字体走查中三处「保守判定」按拍板回调。均编译绿（独立 DerivedData），未提交。

- **字体判断微调（拍板后）**：① Departure / Return 日期卡字段标签从圆体**回退 SF**（字段标签属功能角色，与下方日期值同声音、卡内自洽）；② design-system 补**按钮子规则**——主 CTA 圆体 / 次级·工具动作 SF / 字段标签 SF；③「物品名 vs 场景 chip」维持不统一（不同角色，正确）。另：上轮 agent 误报的 `HomeView.statPill` 死代码经 grep 核实**根本不存在**（错记了被调用的 `statusPill`），无清理动作。
- **P1-① AddStop 类别下沉**（`AddStopView`）：类别从「结果上方一整行 Section」收成**搜索框尾部紧凑 `Menu`**（当前类别图标 + 原生勾选菜单切换），搜索结果紧贴搜索框、首屏不再被「选类别」挤占（north-star §2）。补 `accessibilityLabel`。删原 `categoryPicker`。
- **P1-② 优化页卡中卡收敛**（`OptimizeRouteView`）：去掉最外层 28pt 半透大卡 → 内容直接铺 `CarrySubtleBackground`；新顺序列表去掉每行 14pt 小卡、改时间轴同款「序号圈 + 名称」plain 行；圆角从 28/20/18/14 四档**收成 20 一档**（地图 + 距离对比条两个面）。删距离条里与右上 hero 大数字重复的 saved 胶囊 + 清孤儿 key `itinerary.optimize.saved`（9 语言）。
- **P2-③ 地图预览精简**（`ItineraryMapView`）：去左上 scope 胶囊（与正下方日历条选中态重复，并修掉「全部天时误显 Day 1」隐患，删死代码 `scopeLabel`）；展开钮 accent 蓝 → **中性 `.secondary`**（chrome affordance，对齐 Apple Maps）。保留单点引导提示。
- **P2-④ leg 距离字号**（`TimelineStopRow`）：连线段间距离 9 → **10.5pt**，抬到可读舒适区，几何不变。

## 上次改动摘要（字体系统定稿 + 全 app 对齐 · 2026-06-13）

> 起于行程规划视觉审查发现「同屏混用 SF Rounded / 默认 SF」。先把行程规划三屏整屏圆体化（P0），再确认这是全 app 普遍现象——但「全圆体」并非对的解。**定稿一套角色制字体系统**并全 app 对齐。均编译绿（主 app + Widget Extension，独立 DerivedData），未提交。

- **🔴 字体系统定稿（`design-system.md` Typography 章节重写）**：两种字形按**角色**分配，非按字号、非机械替换。**SF Rounded**＝展示型标题 / 数字（序号·计数·距离·价格·读数）/ 结构性短标题（Day 头·分区标题·卡片标题）/ 短突出标签（胶囊·chip·badge·浮层）/ 紧贴 hero 标题的副标题；**SF（默认）**＝密集列表正文 / 表单输入 / 长段落说明 / 系统控件（Form·Picker·Toggle·navigationTitle·toolbar·Section，绝不强制圆体）。口诀「被展示/醒目/数字/短标签→圆体；密集正文/表单/系统控件→SF」，**拿不准默认 SF**。理由：Apple 自家 Rounded 只给数字/短标签/展示标题，密集正文用 SF——大面积圆体在小字号长列表下可读性降、偏重偏童趣。这才是 north-star §3「字形统一」的正确解（统一＝一致遵守同一套角色规则）。
- **行程规划三屏整屏对齐**（P0）：`ItineraryView` / `ItineraryMapView` / `OptimizeRouteView` 的停靠点名、地址、序号、距离、时间、标题、按钮、空态、地图针等全部内容文字 → 圆体；SF Symbol 与系统控件保持系统体。
- **全 app 走查对齐**（约 120 处 / 18 文件）：首页统计数字与卡片标题、打包清单空态/分区标题/进度件数/CTA、物品库空态/分类头/计数 badge、场景选择/智能推荐的标题与 chip、创建/编辑/Splash 的 hero 副标题与分区/日期短标签、提醒与日期选择器的时间数字/日历数字/preset 短标签、目的地实用信息读数（温度/电压/货币/汇率）与卡片标题、路线图条目标题/分区/Latest badge、打赏档位与价格、图标名、`ConfirmDialog` 标题与按钮、足迹地球城市/国家浮层标签、**Widget（锁屏卡片+灵动岛+主屏小组件）的行程名/倒计时/件数/百分比** 等 → 圆体。各文件密集列表正文（物品名/搜索结果）、表单输入、成段说明、系统 `Form` 设置页（Settings/About 等）一律保持 SF。
- **方法**：定义系统 → 多 agent 按文件并行走查（一文件一 agent、互不冲突）→ 每处回报角色判定与「保守保持 SF」的争议点 → 统一编译绿。判定保守、有据。
- **遗留**：① 行程规划审查的 P1/P2（AddStop 类别下沉 / 优化页卡中卡收敛 / 地图浮层精简 / leg 距离 9pt 偏小）未做；② 发现 `HomeView.statPill(value:label:)` 为零调用死代码。

## 上次改动摘要（UI 走查：首页 Sheet 高度 + 根 Sheet 退后 + 行程详情默认面 · 2026-06-13）

> 接续本日设计走查，聚焦首页底部 Sheet。两条均已提交 `main`、编译绿、真机验收。与并行的 appearance 修复会话共用 `HomeView`，按 hunk 隔离提交。注：退后效果那条 commit (`7d25e52`) 因误用 `git commit -- <path>`（提交工作区而非暂存的 index），把并行未提交的 `preferredColorScheme` 4 行一并带入——功能无误、无丢失/重复，因未 push 且用户在并行提交，未改写历史。

- **首页 Sheet 默认展开高度（有数据态）**（commit `85a6184`）：`屏高 × 0.86` → `屏高 −（topSafeAreaInset + 28）`，与空态一致地从真实安全区推导。地球露出带跨机型恒为「安全区下方 28pt」一线（不随屏高浮动），原本顶端被截断的海洋标签噪音随括高一并裁掉；内容优先、地球作下拉彩蛋。新增 `topSafeAreaInset` helper 镜像既有 `bottomSafeAreaInset`，未碰 FX 吸附/手势/mask 雷区。详见 decisions 2026-06-13。
- **首页根 Sheet 弹出复刻系统「堆叠卡片」退后**（commit `7d25e52`）：设置 / 搜索 / 行程册三张根 Sheet 弹出时，首页整体缩放退后（`continuous` 圆角 + 黑底露边），复刻 iOS Sheet 叠 Sheet 的原生质感（根之上弹 Sheet 本不缩放，非缺陷，主动复刻）。实现 `PresenterRecedeEffect`：挂在被呈现 Sheet 内的不可见 `UIViewControllerRepresentable`，借 `transitionCoordinator.animate(alongsideTransition:)` 变换呈现者视图（首页层）→ 交互式下拉全程跟手（`@State` 布尔驱动的 `scaleEffect` 做不到，已否决）。iPad / Reduce Motion 跳过；静止退后态 `shouldRasterize` 防每帧离屏渲染。根因坑：取消式下拉会补发 `viewWillAppear`，completion 终态须以 `presentingViewController != nil` 判定，不能用「取消取反」（否则首页被误复位、后续下拉失去跟手）。详见 decisions 2026-06-13。
- **行程详情默认面：消除「偶尔闪打包」**（commit `07f5b0f`）：诊断确认"偶尔默认打包"非 bug，是「记住每个行程上次看的面」设计（`TripDetailFaceStore`，已有→上次面、无记录→行程规划），用户选保留该行为（A）。真正的隐患是 `detailTab` 初值写死 `.packing`、靠 `onAppear` 纠正 → 打开「行程规划」行程时 push 动画里会先闪一下打包。修法：初始面改在 `PackingListView.init` 里解析（首帧即正确），删冗余 onAppear 块 + `didInitFace`；并改正 `TripDetailFaceStore` 上「已有一律行程规划」的误导注释。未处理「陈旧记忆」（久前随手切过打包的行程会一直默认打包），按用户范围暂留。

## 上次改动摘要（设计北极星 + 三大界面走查 + 行程天自动生成 · 2026-06-13）

> 本会话聚焦视觉优化,均在 `main`,已分模块提交、编译绿、真机验收。与并行的「我的行程册」会话共用部分文件(HomeView/TripStore/xcstrings),提交时按显式路径隔离、互不覆盖。

- **设计最高标准**:新增 `docs/design-north-star.md`(奔 Apple 年度最佳应用的 9 条 ADA 审视框架),凌驾于 `design-system.md` 之上;CLAUDE.md 设计段落与文件索引指向它。原则:克制是手段、卓越是目标,不用「不为设计而设计」当借口停在「够用」。
- **统一空态语言**:抽 `CarryEmptyStatePrimaryButtonStyle`(ViewModifiers)——首页/行程/打包三处空态共用同款胶囊 CTA。三处空态全部重构为**单一表面居中列**(图标→rounded 标题→副标题→统一 CTA),不再套卡片面板。
- **首页空态**:Sheet 高度由「屏高比例」改为**内容实测驱动**(GeometryReader,设备无关);右上角写死头像 → 圆形齿轮(secondary,回设计系统 §124);卡片对齐 16pt。
- **首页有数据态**:`Trip Book`→`My Trip Book`;hero(即将出发)用 elevation **抬起**成三级深度阶梯(hero>规划中>已结束);0 物品不画空进度条;**规划中行程隐藏件数 pill + 进度条**(日期未定、打包信息不可行动);底部三件去冗余双层阴影、统一柔和。
- **行程规划有数据态**:**自定义圆形地图针**(当天色+白序号,替代原生气泡);地图预览 176→200;日历圆点改当天色、非行程日灰度语义化;Day 头 rounded;时间轴名称加粗;内联动作行(添加地点/优化顺序)统一 secondary 灰(对齐打包)。
- **🔴 天按行程日期自动生成(不再手动增删)**:`TripStore.syncItineraryDays` 把 ItineraryDay 数量幂等对齐到行程实际天数;缩短行程时被删天的地点并入最后保留的天(不丢数据)。在 `updateTripInfo`(改日期后)+ `ItineraryView.onAppear`(兜底/存量)调用。移除「添加第一天」空态、Day 头「⋯」菜单(重命名/删除天)及随之死掉的 `addItineraryDay/removeItineraryDay/updateItineraryDay` + 2 个埋点事件。转有/无日期用 `.id` 强制 collection 重建刷新 Day header。
- **🔴 天数两套口径**:`TripBundle.spanDays` = 含两端**实际天数**(首页卡片、行程页、My Trip Book 旅行天数、日期选择器/分享文本显示);`trip.days` = **晚数/时长**(打包数量、提醒沿用,不变)。日期选择器与分享文本改为「A 天 B 晚」(新增 `date.days_nights`,位置化、日/韩先晚后天)。
- **文案·停靠点→地点**:全 App 用户可见「停靠点」统一改「地点」(14 key × 9 语言,es/fr/pt 阴阳性/冠词随改);补全 `itinerary.empty.map.*`/`single.map.hint` 缺失的 7 语言;清理一批死 key(empty.*/day.menu.*/day.rename.*/date.night/nights)。
- **修复**:① 关闭「模拟空态」开关后首页列表空白需重启(rebuildTripLists 漏听 flag,DEBUG-only 加 onChange);② **Release 构建崩溃**——Swift 6.3.2 优化器 `EarlyPerfInliner` 内联 `CarryBottomSheetFX.Coordinator` 合成 deinit 时无限递归,加显式 `@_optimize(none) deinit{}` 绕开(详见 playbook §18);③ 点「添加地点」**SIGABRT**——`ItineraryReorderCollection.sizeThatFits` 内 `layoutIfNeeded()` 在 SwiftUI 更新周期重入,移除即解。
- **Apple 登录**:spec 写好(`specs/apple-sign-in-icloud-sync.md`,身份+iCloud 同步/登录可选,schema 已核实兼容),**搁置等付费开发者账号**(约 2026-06-16)后做 Phase A。

## 上次改动摘要（行程册 + 首页搜索 + 按钮配色系统 + 外观修复 · 2026-06-13）

> 分支已切到 `main`（用户有意）。以下均已提交，编译绿 + 纯函数单测 + 真机截图验证。注：部分修复（PackingList `ellipsis`/勾选圈、ItineraryMapView `stopMarker`、HomeView 设置 sheet `preferredColorScheme`）夹在用户 itinerary WIP 文件里，随该 WIP 一起提交。

- **设置/sheet 关闭按钮统一**：抽 `SheetCloseButton`（ViewModifiers）——iOS 26 用原生 `Button(role:.close)`（系统单层玻璃 X，修掉「自定义 glassCircleButton 塞进工具栏 → 双层玻璃」），iOS 17–25 回退 toolbar xmark + `common.close`。SettingsView / CoffeeSheetView / ItineraryMapView 三处工具栏关闭统一走它；自定义头部（Roadmap/ScenePicker/SuggestionPreview）保留 glassCircleButton（不在工具栏、单层正确）。
- **首页搜索（自定义 in-sheet）落地**：`HomeView.searchSheet`——补齐本地化（`Search trips`/`No matching trips` 原为空块→ 9 语言）、无结果居中空状态、自动聚焦、`onDismiss` 事件驱动跳转（去掉 `asyncAfter` 延迟 hack）、结果列表 `ScrollView+LazyVStack` 收紧行距 + 下拉收键盘、右侧 `xmark.circle.fill` 清空按钮（`common.clear`）。
- **我的行程册升级为旅行数据回顾**（spec: `specs/trip-book.md`）：3 行统计 → 可滚动卡片流。hero（国旗排 + 自 YYYY 起旅行 + 抽象航线弧线点缀 + count-up 数字，尊重减弱动态）、国家和地区（Top + 全球占比）、大洲、国内/国际比例条、季节（南北半球翻转）。**明确不做航班里程/住宿晚数/花费**（无数据 + 越界定位）。区域名用系统、不自定义（合规）。20 个 `tripbook.*` key × 9 语言。
- **数据层**：`TripBookStats`（纯函数 + 27 项单测）/ `TripBookStats+Trips` 适配器；`CountryData`（脚本 `scripts/gen_country_data.py` 生成校验：ISO alpha-3→alpha-2 + 国家→大洲 249 条）。
- **`homeCountryCode` 单一来源重构**：见 decisions 2026-06-13。`isInternational`/`inferIsInternational` 改 storefront 基准（大陆→CN 零回归）；`normalizedCountryCode`/`flagEmoji` 移共享、去重。
- **行程册口径细化（用户反馈后）**：所有统计只算**已发生**行程（`countsAsVisited`，已出发+进行中，排除未来/无日期），修掉「旅行数算全部、国家数只算去过」的内部不一致；hero 文案「自 YYYY 起旅行」→「YYYY 年第一次出发」（`tripbook.since`→`first_trip`，对齐首页 footer 语气）；首页 Trip Book 胶囊副标题改用 `visitedTripsCount` 与册内同口径；国家卡列**全部**到访国家（不再截断 Top 3，数字与列表自洽）。
- **按钮颜色系统定稿 + 全 App 走查落地**（`docs/design-system.md`「按钮颜色规范」）：
  - 三档：Tier 1 主操作 CTA = 实心黑/白；Tier 2 强调/可点/选中/工具栏提交 = 烟蓝；Tier 3 chrome/离开导航 = 中性灰。
  - **关闭 X** 三处不一致（蓝/黑/灰）统一为中性灰（`SheetCloseButton` 显式 `.tint(.secondaryLabel)`；自定义头部 xmark `.secondary`）；**更多菜单** `ellipsis` → `.secondary`。
  - **选中态黑 → 烟蓝**（ItemPicker 勾选圈/三段分段控件/智能推荐 chip、ScenePicker 场景 chip、SuggestionPreview 勾选圈）——对齐「彩色=选中」哲学。
  - 铁律：工具栏「提交（✓/Save 蓝）vs 离开（关闭/返回 灰）」；返回用系统原生不改色；「选中（烟蓝）vs 完成（打包态退后变灰）」；空状态主 CTA 保持 Tier 1 黑（非强调色）。
- **修复：设置页内切外观不立即生效**：`.sheet` 不继承根的 `.preferredColorScheme`；给设置 sheet（HomeView / ContentView Mac）显式套 `.preferredColorScheme`，读同一份 `@AppStorage("appearance_mode")`，与根锁步即时更新。

## 待办 / 下一步（截至 2026-06-12）

> 行程规划 Phase 1–5 + 导航框架 + 跨天拖拽：均在 `feature/itinerary-route-planning` 分支，**已实现 + 模拟器验证，未提交 / 未合并**。

- [ ] **合并前真机验收**：跨天拖拽手感/掉帧、时间轴长清单观感、底部胶囊单手可达、设置 sheet、Dark Mode、9 语言、大陆 storefront 高德底图。
- [x] **首页搜索（自定义 in-sheet）**：已落地——自定义 Sheet 内搜索（`HomeView.searchSheet`，`CarrySearchField` + 取消 + 行程列表/空态），2026-06-14 补「我的行程」大标题延续进搜索态。原生 `.searchable` 在「足迹地球 + UIKit Sheet、无 nav bar」首页不适用，故自定义。
- [ ] **主列表段间「道路耗时」**（可选）：目前是 Haversine 直线距离（即时/离线）；如需真实耗时，做懒加载 + 缓存的 MKDirections 增量。
- [ ] **跨天拖拽落点软夹断**（可选打磨）：目前不夹断，可把 stop 拖到某天 add/optimize 行下方——落库会正确归该天、不报错；若觉天边界落点不够精准再加软夹断。
- [ ] **拖拽短距离过冲（待真机录屏确认）**：用户反馈短距离重排易过冲（想 #3→#5 却到 #7，偶发、上下都有）。代码侧确认我们喂的是手指原始位置、换位用 UIKit 原生中点判定（无放大）；大概率是**短视口（地图+日历占上半屏，列表仅露约 5 行）下触发边缘 auto-scroll**，列表在手指下自滚把行带过头。auto-scroll 速度/触发带无公开 API 可调，禁止手写自定义 auto-scroll 对抗框架。**下一步**：真机录 3 秒确认过冲时列表是否在滚——在滚→找不对抗框架的收敛办法；没滚→属实时回流的固有手感、不值得加复杂度。详见 `ItineraryReorderCollection.handleLongPress`。
- [ ] **提交 / 合并**：用户验收后再 commit 到分支并评估合并。

## 视觉修正：时间轴行序号与名称对齐（2026-06-13）

> 用户反馈「视觉重叠错乱」。根因：`TimelineStopRow` 的 leading 是 `[16pt 上连线][圆点]` 竖排，圆点中心被压到 ~28pt，而名称在 ~14pt → 序号圆点掉到**地址行**，整列错位。
> 修法（顺结构、不硬调偏移）：把段间距离拆成名称上方的**间隙段**（仅连线+距离），主行里圆点与名称**顶对齐**。模拟器在真实昆明 7 停靠点 Day 1 上验证：序号 1–7 各对齐名称、间隙距离在连线上、无重叠 ✓。

## 上次改动摘要（单日重排：固定首尾、只优化中间 · 2026-06-13）

> 分支 `feature/itinerary-route-planning`，**未合并/未提交**。编译绿 + 算法单测三例通过。spec 已更新（方案 A）。

- **问题**：旧重排只固定起点、末尾浮动 → 「酒店出发→景点→回酒店」往返日里，末尾那个酒店会被算法挪到中间，这天"结束在某景点"。
- **方案 A（类似 Google Maps 优化途经点）**：`RouteOptimizer` 锚点集合从 `{0}∪timed` 改为 **`{首, 尾}∪timed`**——固定当天第 1 和最后 1 个停靠点，只重排中间（复用现成的端点固定 NN+2-opt）。往返=两端填酒店；单程=末尾点（机场）也不被挪。
- **入口阈值** `showsOptimize` 由坐标点 ≥3 → **≥4**（固定首尾后需中间 ≥2 点才有可优化空间）。
- **预览提示**：优化预览加 footer「起点与终点保持不变，只重排中间」（`itinerary.optimize.endpoints_fixed`，9 语言），解释首尾为何不动。
- **算法单测**：① 往返 [0,1,2,3,4]→[0,2,3,1,4]（首尾 0/4 固定、中间重排、1556→1112km）；② 单程末尾机场固定；③ 往返+中间时间锚点三者都钉住。✓

## 上次改动摘要（行程跨天拖拽：原生 UICollectionView · 2026-06-12）

> 分支 `feature/itinerary-route-planning`，**未合并/未提交**。编译绿 + 模拟器实测跨天拖拽通过。解决「停靠点只能日内重排、跨天得删了重加」。

- **新组件** `ItineraryReorderCollection.swift`：复刻打包清单 `ReorderableItemCollection` 的原生 interactive movement（长按 1:1 跟手），但**放开跨 section（跨天）拖拽**——去掉 `clampLocationToSection` 夹断，`.changed`/auto-scroll 直接喂原始位置，UIKit 自然把被拖行带过天边界。**不碰稳定敏感的打包 collection**（姊妹实现，隔离）。行类型 `.stop` 可拖、`.addStop`/`.optimize` 不可拖；日期表头非吸顶（免背景透出）。
- **落库** `TripStore.applyItineraryArrangement(tripId:dayOrders:)`：松手时 `didReorder` 从 finalSnapshot 取**所有天**的新 stop 顺序，一次性重设每个 stop 的 `day`（SwiftData 关系 inverse 自动维护两边）+ `sortOrder`。跨天则 log `itineraryStopMovedDay`，否则 `itineraryStopReordered`。
- **ItineraryView 接入**：`List` → `ItineraryReorderCollection`；时间轴行/日期头/加点/优化按钮经闭包 + `UIHostingConfiguration` 承载（样式复用）；移除 `EditButton`（长按拖拽常驻）、`.onMove`/`.onDelete`、`editMode`。地图头/加天按钮/sheets 保留。
- **实测**：Day1(Temple) + Day2(空) → 长按 Temple 拖入 Day2 → Day1 空、Day2 得 Temple 并重编号为 1，落库持久；日期头/加点/优化/删天菜单在 collection 内均正常 ✓。

## 上次改动摘要（导航框架重构：去 TabView + 底部胶囊切换 · 2026-06-12）

> 分支 `feature/itinerary-route-planning`，**未合并**。spec：`specs/app-navigation-framework.md`。编译绿 + 模拟器逐项验证。解决「打包/行程顶部 Segmented 不对等、高频行程规划难单手够到」的结构问题。

- **根级去 TabView**：`ContentView` iPhone 不再是 TabView；根=`HomeView`（足迹地球 + UIKit Sheet 原样）。设置→`HomeView` 右上 gear 以 sheet 打开（`SettingsView` 加 `dismiss` + path 为空时的 Done）；创建→右下悬浮 FAB（烟蓝）。空状态也放了设置 gear（零行程用户可达）。**首页 TRIP OVERVIEW/足迹/分组列表原样保留**。
- **行程内顶部 Segmented → 底部胶囊切换**：`PackingListView` 移除顶部 Picker；底部 `bottomFaceSwitch` 胶囊（行程 ｜ 打包，拇指可达，spring 0.3/0.2）。**默认面规则**：新建→打包；已有→`TripDetailFaceStore`（UserDefaults per trip）记住的上次面，无记录则行程规划。**已验证记忆生效**。
- **「…」trip 动作两面常驻**：ungate 到 `if !isNewTrip`，打包专属动作（从库添加/标记完成/编辑分区/分享清单）用 `if detailTab == .packing` 内部门控；trip 级（提醒/编辑/封面/删除）两面都在。
- **埋点**：`detailFaceSwitched`（to=packing/itinerary），衡量两面频次。
- **有意延后（见 spec）**：① 首页搜索——首页是地球+UIKit Sheet 无 nav bar，原生 `.searchable` 不适用，需自定义 in-sheet 搜索，单独排期；② 行程内底部「+」——两面已有清晰内联添加，全局「+」语义含糊且不克制，不做。
- **模拟器验证**：根无 Tab 栏、设置 sheet 带 Done、创建 FAB、概览/足迹保留 ✓；已有行程默认行程规划、切到打包、记忆生效、「…」两面常驻 ✓。

## 上次改动摘要（行程路线规划 Phase 5：行程视图视觉升级 · 2026-06-12）

> 分支 `feature/itinerary-route-planning`，**未合并**。编译绿 + 模拟器截图验证。本轮是视觉/交互打磨，无新增用户文案（删了 1 个废弃 key `itinerary.map.empty`）。

- **Day 头部显示真实日期**：有日期行程显示「Day N」+ 次行「周几 月/日」（由 `departureDate + sortOrder` 推算，`Date.formatted` 本地化）；isDateless 仍纯序号。`ItineraryView.dayDateLabel`。
- **停靠点列表改时间轴**：`StopRow` → `TimelineStopRow`——leading 序号圆点 + 上下连线（首/末点半段隐藏）；`index>0` 在连线上显示与上一点的 **Haversine 直线距离**（即时本地，不在主屏发 MKDirections，保「即时/离线」）。List 隐藏分隔线，保留 onMove/onDelete/EditButton。
- **主地图升级**：Marker 改用**访问序号**作 label（+ 类别图标）；预览**整块可点**进全屏（原来只有小按钮）；**坐标点 <2 时不显示地图块**（省垂直空间，单点不再占 200px）。
- **时间锚点 pin 图标**：设了时间的行显示 `pin.fill` + 时间，传达「优化时不动」。
- **模拟器实跑验证**：日期头部「Day 1 · Fri, Jun 19」✓；时间轴序号圆点 + 连线 + 「48 km」段间距离 ✓；地图标注 1/2 + ≥2 才出现 + 点整块展开全屏 ✓。

**待办**：合并前真机验收（时间轴在长清单的性能/观感、Dark Mode、9 语言、大陆 storefront 高德底图）。可选：主列表段间补「道路耗时」（懒加载+缓存，目前是直线距离）。

## 上次改动摘要（行程路线规划 Phase 4：时间锚点 + 真实道路距离 · 2026-06-11）

> 分支 `feature/itinerary-route-planning`，**未合并**。spec：`specs/itinerary-route-planning.md`。编译绿 + 算法单测 + 模拟器真机数据实跑验证通过。
> **产品决策**：MKDirections「**只用于展示**」（排序仍 Haversine，保即时/离线），不改排序为联网道路矩阵。

- **时间锚点（Phase 4-B）**：
  - `StopEditView` 加「设定时间」开关 + 时间选择器（写 `plannedStartMinutes`，-1=未设）；`StopRow` 有时间则显示（如「9:00」）。让时间锚点有可达入口（此前字段无 UI = 不可达）。
  - `RouteOptimizer` 改为锚点感知：设了时间的停靠点 + 起点 = 固定锚点保持原位；只在相邻锚点之间的「自由段」内重排，用端点固定的 NN+2-opt。无时间则退化为现有行为。
- **真实道路距离（Phase 4-A）**：
  - `RouteDistanceService`（actor）：MKDirections `calculateETA` 逐段算驾车距离，**串行**发出防限流 + 按 (from→to) 会话缓存；任一段失败/离线返回 nil。
  - `OptimizeRouteView`：先显示 Haversine，异步算到道路距离后替换原始/优化两个数字，加「🚗 By road / 直线距离 / 计算中」说明；道路下若无节省则隐藏 saves 标签（诚实）。失败记 `itineraryRouteCalcFailed`。
- **本地化**：6 个新文案 × 9 语言（append-only 干净 diff）。
- **算法单测**（standalone swift）：无锚点 → 50% 优化；钉住 idx1 → 该点留在原位仅重排其余；钉住 idx2 → 单元素段不动，锚点保持位置。
- **真机实跑验证**：①StopEditView 时间开关/选择器/footer 渲染，存档后 StopRow 显示「9:00」；②优化预览数字换成 **MKDirections 真实道路距离**（实测昆明三点：7,163 km → 3,632 km，省 3,531 km，「By road」标识），采用/放弃两段式正常；③拖拽重排实测生效。

**行程规划 Phase 1–4 全部完成。** 待办：合并前真机验收（拖拽手感、Dark Mode、9 语言显示、大陆 storefront 高德底图、道路距离在大陆的可用性）。

## 上次改动摘要（行程路线规划 Phase 3：单日智能重排 · 2026-06-11）

> 分支 `feature/itinerary-route-planning`，**未合并**。spec：`specs/itinerary-route-planning.md`。编译绿 + 算法单测 + 模拟器真机数据实跑全流程验证通过。

- **算法**：`RouteOptimizer.swift`（纯函数）——最近邻构造 + 2-opt 局部优化，Haversine 直线距离，**起点固定**为当天第一个停靠点（开放路径，非闭环）。`isImprovement` 阈值：节省 >50m 且 >1% 才算改进（滤噪声）。`optimize` 仅在有坐标停靠点 ≥3 时返回结果。
- **UI**：`OptimizeRouteView.swift` 两段式——预览（新路线地图带编号 Marker + 距离对比「旧→新 + 省 X」+ 建议顺序列表）→「采用」才走 `store.reorderItineraryStops`（坐标点新序 + 无坐标点原序追加）；「放弃」不动；已近最优时只读「Already efficient」提示。入口按钮在 `ItineraryView` 当天 section，**当天坐标停靠点 ≥3 才露**。
- **埋点**：`itineraryOptimizeShown/Applied/Discarded`（applied 带 saved_m），定义即接线。
- **本地化**：9 个 optimize 文案 × 9 语言（append-only 干净 diff）。
- **算法单测**（standalone swift）：zig-zag 顺序 [0,1,2,3] → 优化为 [0,2,3,1]，省 50%，起点固定；已排序输入保持不变（→ already efficient）。
- **真机实跑验证**：①≥3 坐标点时按钮出现；②真实数据（昆明 Temple/机场 + 误落在西安的 GREE）正确判「已最优」（不乱重排）；③手动拖成「昆明→西安→昆明」回折后优化，预览显示 **2,306 km → 1,188 km，省 1,118 km**，采用后列表写回优化顺序；④拖拽重排实测生效。

**待办**：合并前真机验收（拖拽手感、Dark Mode、9 语言显示、大陆 storefront 高德底图）；可选 Phase 4（重排距离从 Haversine 升级 MKDirections 实际耗时校验、时间锚点约束）。

## 上次改动摘要（行程路线规划 Phase 2：行程视图 + 地图 + 地理搜索 · 2026-06-11）

> 分支 `feature/itinerary-route-planning`，**未合并**。spec：`specs/itinerary-route-planning.md`。编译绿 + **模拟器真机数据实跑全流程验证通过**（在带真实行程的 iPhone 17 Pro 上跑，迁移后 17 个行程数据完好）。

- **入口**：`PackingListView` 顶部 **Segmented**（`detail.tab.packing/itinerary`），`!isNewTrip` 才露；行程 tab 渲染 `ItineraryView`。打包页的 trailing 菜单按 `detailTab == .packing` 收起。
- **新视图**：`ItineraryView.swift`（空状态 / 按 Day 分组 / 加 Day·Stop / `.onMove` 拖拽重排 / `.onDelete` / EditButton·≥2 stop 才露 / StopEditView 改名·类型·备注·删）、`AddStopView.swift`（`MKLocalSearchCompleter` 边输边补全，区域偏置到行程目的地坐标；选中走 `MKLocalSearch` 解析真实坐标+地址入库；无补全时「手动加无地点停靠点」）、`ItineraryMapView.swift`（顶部常驻预览+可全屏，`Marker` 按 category 标注、每天 `MapPolyline` 直线连线、`fittedRegion` 自动包络）、`StopCategoryStyle.swift`（category→SF Symbol/标题 key）。
- **Store/埋点**：`TripStore` 加 itinerary CRUD（addDay/removeDay+重排 sortOrder/updateDay、addStop/updateStop/removeStop/reorderStops）；`CarryLogger` 加 6 个 itinerary 事件（含 `itineraryRouteCalcFailed` 入 errorEvents），定义即接线。
- **本地化**：29 个新 key × 9 语言已补全（脚本 round-trip 验证格式，append-only 干净 diff，中文全角，zh-Hant 台湾用语）。复用既有 `Save`/`common.cancel`/`common.done`。
- **本轮修的两个真机 bug**（都已根因修复并复验）：
  1. **同一视图挂两个 `.sheet(item:)` 相互抑制** → 合并为单一 `ItinerarySheet` 枚举驱动。
  2. **根 ZStack 的 `.simultaneousGesture(TapGesture)`（点空白收键盘）吞掉行程页 List 行内按钮的 touch-up**（加 Day/加 Stop 无响应，而 Menu 走 touch-down 正常）→ 把该手势从根 ZStack 收窄到只包打包内容的 `packingContent`。
- **范围说明（诚实记录）**：地图为**直线连线**基线；`MKDirections` 实际道路路径/逐段耗时**未做**——在没有展示耗时的「路线详情」UI 前先建 RouteCalculator 会是零调用死代码，违反「定义即接线」，故留待有承载 UI 时再接（spec Phase 4 / 后续）。

**待办**：Phase 3（单日智能重排：最近邻+2-opt、预览→采纳两段式）。合并前真机验收（拖拽手感、Dark Mode、9 语言、大陆 storefront 底图）。

## 上次改动摘要（行程路线规划 Phase 1：数据地基 · 2026-06-11）

> 分支 `feature/itinerary-route-planning`，**未合并**。spec：`specs/itinerary-route-planning.md`（已确认产品/UI 决策：单日智能重排 / 顶部 Segmented 切换 / 地图常驻+可展开 / StopCategory 6 类）。本轮只做 Phase 1 数据地基，编译绿 + 模拟器启动验证（轻量迁移无崩溃）。

- **新模型**：`Carry/Models/Itinerary.swift` — `ItineraryDay`（按天，`sortOrder` 驱动顺序，兼容 isDateless）/ `ItineraryStop`（POI：name/lat-long/address/category/计划时段/停留时长/note/sortOrder，含 `hasCoordinate`、`coordinate`、未知 category 兜底 `.other`）/ `StopCategory` 6 类枚举。`TripBundle` 加 `itineraryDays` 级联关系 + `safeItineraryDays`。
- **迁移**：新增 model（建新表）属轻量迁移，保持单一 `SchemaV1`、空 stages（model 列表已加两类），**不引入 SchemaV2**（避免 checksum 重复崩溃）。模拟器启动验证：app 正常进入空状态首页，进程存活、无 crash log → 迁移干净。
- **备份**：`DataBackupManager` 新增 `BackupItineraryDay`/`BackupItineraryStop` 镜像类型，`BackupTrip.itineraryDays` 可选（兼容旧备份），`makeBackup` 序列化 + restore/merge 共用 `restoreItineraryDays` 重建（id 保真）。发布前不升 `currentBackupVersion`。
- **复制行程**：`duplicateTrip` 深拷贝 days/stops（新 UUID），避免共享/丢失。

**Phase 1 验证现状**：✅ build 通过 ✅ 启动迁移无崩溃。⏳ 建/删 Day·Stop、备份还原、复制独立等数据流**尚无 UI 可触发**，待 Phase 2 接入「行程」视图后实跑验证（当前为编译期正确 + 逻辑对齐既有 sections/backgrounds 范式）。

**待办**：Phase 2（行程视图 + Segmented 切换 + 地理搜索选点 + 地图 Annotation/Polyline + MKDirections 节流缓存 + 拖拽重排 + 9 语言 + 埋点）→ Phase 3（单日重排）。

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
