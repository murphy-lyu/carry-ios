# 决策日志

## 2026-06-13 行程「天」按行程日期自动生成（用户不手动增删）

> 起因：行程规划页原本天只能手动「添加第一天/删除当天」，与「行程天数由创建/编辑行程的日期决定」的产品认知冲突。

- **决策（用户明确）**：行程页的「天」由行程实际天数**自动生成**，用户永不手动增删。ItineraryDay 数量恒等于行程实际天数（含两端）；无日期「规划中」行程固定 1 天（Day 1）。
- **实现**：`TripStore.syncItineraryDays(tripId:)` 幂等对齐——不足补天、超出删尾部天；删天时该天停靠点**按序并入最后保留的天**（用户拍板：不丢数据，宁可让用户看到再整理，也不静默删其规划）。在 `updateTripInfo`（改日期/天数后）+ `ItineraryView.onAppear`（新建首开 / 存量兜底）调用。
- **移除**：手动加天 UI 全删——空态「添加第一天」、Day 头「⋯」菜单（重命名/删除当天）、及随之零调用的 `addItineraryDay/removeItineraryDay/updateItineraryDay` 与 `itineraryDayAdded/Removed` 埋点（死代码清理）。
- **反应性坑（已修）**：无日期转有日期后，旧 Day 的 header 因 diffable section id（dayID）不变、未重配而显示旧标签（「第1天」没变成日期）。修法：collection 加 `.id(isDateless + departureDate)`，日期态变化时强制重建刷新所有 header——罕见操作、代价可忽略；日常加减地点不触发。

## 2026-06-13 天数两套口径：实际天数（显示）vs 晚数（打包）

> 起因：6/15–6/17 行程原各处用 `trip.days`（= 返程日−出发日 = 晚数 = 2）显示「2 天」，与用户「6/15–6/17 就是 3 天」的认知冲突；但打包数量按「晚数」算又是对的。两个口径都对、不能合并。

- **决策（用户拍板：两套并存）**：
  - **行程天数（显示）= 含两端实际天数**，`TripBundle.spanDays`（= `isDateless ? 1 : days+1`）。用于首页卡片「· N 天」、行程页天/日历、My Trip Book 旅行天数、日期选择器与分享文本。
  - **打包数量 = 晚数/时长**，`trip.days`（= `durationDays` = 返程日−出发日）。打包推荐数量、提醒沿用，**不变**。
- **不改 `trip.days` 语义**：它是存储字段、全 App 打包/提醒依赖；只新增 `spanDays` 计算属性作「显示天数」单一来源，避免两处口径漂移。
- **日期选择器 / 分享文本**：从「X 晚」改为「A 天 B 晚」（新增 `date.days_nights`，位置化占位符——日/韩按习惯「N 泊 M 日」先晚后天）——把两套口径在用户最该理解处一次讲清。

## 2026-06-13 首页根 Sheet 弹出时复刻系统「堆叠卡片」退后效果

> 起因：UI 走查发现，「设置 → 支持 Carry」是 Sheet 叠 Sheet，享受系统原生的下层缩放退后（丝滑、跟手）；而「首页 → 设置」因为首页是**根页面**（且首页 Sheet 是自绘 FX，非系统 Sheet），弹设置时首页不缩放，缺这份质感。

- **结论**：iOS 的「下层缩成卡片退后」只在 *Sheet 叠 Sheet* 时发生；根之上弹 Sheet 不缩放是平台标准行为，**本非缺陷**。决定主动复刻以提升质感。
- **否决路径 A（`@State` 布尔驱动 `scaleEffect`）**：真机验证——交互式下拉关闭时**拿不到手势进度**，首页脱节不跟手，属 band-aid，弃。
- **采纳路径 B**：在被呈现的系统 Sheet 内部挂一个不可见 `PresenterRecedeEffect`（`UIViewControllerRepresentable`），于 `viewWillAppear/Disappear` 拿 `transitionCoordinator.animate(alongsideTransition:)` 变换**呈现者视图**（首页层）。动画挂在系统转场上 → present/dismiss（含交互式下拉）全程跟手。保留 SwiftUI `.sheet`，不自造呈现。已接 设置 / 搜索 / 行程册 三张根 Sheet。
- **工程要点**：① iPad（form sheet 居中）与 Reduce Motion 下整段跳过；② 圆角 `cornerCurve = .continuous`；③ 静止退后态开 `shouldRasterize`（消除全屏 `cornerRadius+masksToBounds` 每帧离屏渲染），动画期严格关闭——同 §30 性能纪律。
- **踩坑（已根因修复，务必勿重蹈）**：completion 里**不能用「取消就取反端态」判定最终缩放**。交互式下拉被取消时，UIKit 会先 `viewWillDisappear` 再补一次 `viewWillAppear`，两者都挂在同一被取消转场上、completion 均报 `cancelled=true`；取反逻辑会让 `appear(true)` 那次反成 identity，使首页在 Sheet 仍呈现时被错误复位 → 之后每次下拉都没了跟手。**正解：终态以现实判定 `presentingViewController != nil`（Sheet 还在就保持退后，没了才复位）**，与回调次数无关。
- **数值旋钮**：`PresenterRecedeEffect.scale = 0.92` / `cornerRadius = 16`，真机对照系统效果可调。

## 2026-06-13 首页 Sheet 默认展开高度：从屏高分数改为安全区推导（地球只留干净一线）

> 起因：UI 走查首页 Sheet 默认高度。原非空态用 `UIScreen.main.bounds.height * 0.86`，地球露出 ~14%，露出的是 MapKit 截断的海洋标签（北冰洋/巴伦支海）——一条噪音带，既够不上 north-star §8 的「叙事/惊喜」，又违背 §1 的 deference（两头不靠）。且 `0.86` 是无依据的 magic number，与隔壁空态「按内容逐项推导」的严谨度不对等。

- **决策（用户选「内容优先、收干净」方向）**：展开态改为 `屏高 - (topSafeAreaInset + 28)`，与空态一样**从真实安全区推导**。露出的地球带在所有机型上恒为「安全区下方 28pt」（不随屏高浮动），呈一条干净的星空 + 地球弧线；地球作为**下拉才露的彩蛋**，不是默认主角。
- **为何括高反而更干净**：相机中心锁在到访国质心（默认 lat 25），屏幕顶端永远是高纬度（北冰洋标签所在）。括高裁掉的是地球底部，但顶端那条噪音标签落在更靠下、被一起裁掉了——真机/模拟器确认括高后顶端只剩冰盖弧线，无标签戳入。
- **不碰雷区**：只改 `expandedSheetHeight` 一个值（`HomeView.swift`），新增 `topSafeAreaInset` helper 镜像既有 `bottomSafeAreaInset`。`collapsedOffset = expandedHeight - 188` 自动跟随；FX 的吸附/手势/mask 链路（playbook §5 雷区）完全未动。
- **回写**：本条即 north-star「抬高标准后回写」的落地记录。

## 2026-06-13 国内/国际基准改为 storefront 单一来源（home country）

> 起因：「我的行程册」要做国内/国际占比统计。原 `TripBundle.isInternational` 与 `TripStore.inferIsInternational` **硬编码 CN**，且 `isInternational` 还被打包推荐（`generatePackingSections` 过滤 `internationalOnly`）多处使用。

- **决策（用户拍板）**：建唯一来源 `homeCountryCode`（`SceneItemMap.swift`）——读 storefront `countryCode`（ISO alpha-3，如 `CHN`/`USA`），经新增静态表 `CountryData.alpha3ToAlpha2` 转 alpha-2；取不到/大陆默认 `CN`。统计与打包**共用**此基准，避免两处口径漂移、日后重复维护。
- **零回归保证**：大陆 storefront → `homeCountryCode == "CN"`，与历史 CN 硬编码逐字节一致（launch 市场无行为变化）；非大陆 storefront 才按其本国判定（对打包也更正确：US→US 不再误判国际/塞护照）。
- **不用 Locale 替代**：home country 取自 storefront，**禁止**用设备 Locale/Region 替代（与 `isChinaStorefront` 同纪律）。
- **合规未受影响**：旅行证件差异化（护照↔港澳/台湾通行证）在 `generatePackingSections(destinationCodes:)` 内、基于 `isChinaStorefront`+目的地码，不依赖 `isInternational`，未改。
- **测试/已知现象**：`TripBookStats` 单测覆盖 CN 与 US 两种 home 基准；模拟器为美区 storefront 时国内/国际按 home=US 算（去中国算国际），开 Settings「模拟大陆 storefront」开关或真机大陆才是 CN 口径——非 bug。

## 2026-06-13 行程册区域名用系统、不自定义（规避命名合规风险）

> 起因：行程册「国家和地区」里 CN 显示为 Apple 系统名「中国大陆 / China mainland」，用户问可否改成「中国」（Tripsy 风格）、是否有政策风险。

- **决策（用户选保守方案）**：**不自定义区域显示名，一律用系统 `Locale.localizedString(forRegionCode:)`**。大陆 storefront 下 Apple 的区域命名已由 Apple 替大陆市场审定，App 自己越少插手越安全；「中国大陆」本身是正常用语。
- **判断**：显示「中国」本身**无**政策风险（风险方向是把台湾/港澳显示成独立国家，而我们恰恰归并进 CN）；但自定义区域名会开「自己命名争议区域」的口子，保守起见统一交给系统。
- **边界**：港澳台/争议区域永不自定义名；展示层归并仍走 `normalizedCountryCode`（大陆 storefront HK/MO/TW→CN），存储层保持 ISO 原值。

## 2026-06-13 行程按天编号 + 按天分色（破例覆盖单一强调色）

> spec：`specs/itinerary-route-planning.md`「按天编号与按天分色」一节。

### 地图编号与列表编号统一为「按天编号」（地图对齐列表，而非反向）
原因：地图针原先全程连续编号（跨天 1…N 不重置），列表却按天重置（每天从 1 数）。多天行程下两边对不上号，用户无法照着列表在地图上找到对应针。决策：**地图改成按天编号**（每天 1、2、3…），与列表一致。理由是序号要承载「第几天的第几站」这一有意义的语义；列表本就按天分区，「整趟第 14 站」对用户无意义，所以对齐方向是地图向列表靠。

### 按天分色：正式破例覆盖「单一强调色（烟蓝）」原则，**仅限**行程规划
原因：多天路线全用一种强调色画在同一张地图上是一团理不清的乱线，按天编号后不同天还会出现重复的「1、2」针，必须靠颜色区分。这与 2026-06-07 锁定的「唯一强调色＝烟蓝」冲突。PM 决策（2026-06-13，明确知悉冲突后选择）：**为行程规划破例**，引入一组按天色板。
决策与边界：
- 新增 `ItineraryDayPalette`（`AppearanceMode.swift`）：7 色循环、明暗自适应、克制低饱和；**第 1 天＝烟蓝（CarryAccent）保品牌连续**，其余为陶土/鼠尾草绿/梅紫/赭黄/暮蓝/玫灰。按 `ItineraryDay.sortOrder` 取色、超出循环。
- 颜色**同时**作用于地图（针 tint + 路线 stroke）与列表时间轴（`TimelineStopRow` 的序号圆点/连线/类别图标）与天标题色点，使图文可按色+按号双重对照。
- **严格限定**：此破例只属行程规划。App 其余一切交互元素仍只用烟蓝；`ItineraryDayPalette` 不得在行程外引用。行程内的**动作按钮**（添加停靠点/优化/添加一天）仍用 `CarryAccent`，分色只用于「数据节点」（针/路线/序号），不用于控件。
- 纯展示层：颜色由 `sortOrder` 派生，不进 model/schema/备份，零迁移。

### TimelineStopRow 距离标签居中 = 序号圆点垂直居中于内容（根因解）
原因：圆点原对齐名称（内容顶部），但地址在圆点下方又占一段高度，使「连接段内居中」的距离标签落在两圆点之间时偏下。决策：序号圆点改为**垂直居中于整条内容**（上下两段对称连线撑出），两圆点间连线对称，标签自然落在正中。同高内容完全居中，无地址的行偏差 ≈3pt，可接受。同时连接段固定值（`legGap`）取代原先依赖自适应高度的贪婪 frame——后者在自适应 cell 中会撑出不可控幽灵高度，是反复改不对位的真因。

## 2026-06-12 行程路线规划 + 导航框架重构

> 均在 `feature/itinerary-route-planning` 分支（未合并）。spec：`specs/itinerary-route-planning.md`、`specs/app-navigation-framework.md`。

### 导航主框架：去根级 TabView，行程内改底部胶囊切换
原因：旧结构两处别扭——① 根级 TabView（行程/设置）让最低频的设置占一个常驻 tab；② 行程详情顶部 Segmented 把「打包」「行程规划」当对等平级，但二者生命周期/频次完全不同（打包=出发前一次性；行程规划=旅途中高频反复开），结果高频视图被放到最难单手够到的顶部、且默认停在低频的打包。本质是「不对等的两面被当成对称 Tab」。
决策：① **根级取消 TabView**，根=`HomeView`（足迹地球+UIKit Sheet 原样，概览/足迹/列表全保留）；**设置→Sheet 头部右上 gear（sheet 呈现）**、**创建→右下悬浮 FAB**。② **行程详情顶部 Segmented → 底部悬浮胶囊切换（行程 ｜ 打包）**，拇指可达。③ **默认面规则**：新建→打包；已有→记住的上次面（`TripDetailFaceStore`/UserDefaults），无记录则行程规划。④ trip 动作「…」两面常驻，打包专属动作仅打包面。
有意不照抄 Tripsy：**不做**「行程作为 Sheet 盖在地图上」（大改且打包不适配、Carry 已有地图块+足迹地球）、**不做**「Hub+卡片」（会让最高频的行程规划反而深一级，与「每到一地秒开」相悖）。
有意延后/不做：**首页搜索**原生 `.searchable` 在 globe+UIKit Sheet（无 nav bar）首页不适用，改自定义 in-sheet 搜索、单独排期；**行程内底部「+」不做**（两面已有清晰内联添加，全局「+」语义含糊且不克制）。

### 行程地图距离：MKDirections 仅用于「优化预览」展示，排序/主列表用 Haversine 直线
原因：真实道路距离更准，但 `MKDirections` 异步、有速率限制、依赖网络。若放进排序或主列表段间，等于把联网依赖/延迟/限流搬到最常用的屏，违背「即时/本地/克制」。而对**排序结果**而言，Haversine 直线通常与道路一致（差的是绝对数字、不是先后）。
决策：**排序与主列表段间一律用 Haversine 直线（即时、离线）**；`MKDirections` **只**在「优化顺序」预览里把展示数字换成真实道路距离（带节流+会话缓存+失败回退直线），且道路下若无节省就隐藏 saves 标签（诚实）。`RouteDistanceService` actor 串行+缓存防限流。

### 单日智能重排：最近邻 + 2-opt，起点固定，时间锚点作段端固定
原因：需要本地、即时、可解释的顺序优化；规模小（单日通常 ≤8 点）。
决策：`RouteOptimizer`（纯函数）——最近邻构造 + 2-opt 局部优化；**起点（当天首点）固定**；设了时间（`plannedStartMinutes`）的停靠点作**固定锚点**，只在相邻锚点间的「自由段」内重排（端点固定的 NN+2-opt）。`isImprovement` 阈值（省 >50m 且 >1%）滤噪声。两段式预览→采纳，绝不未确认改顺序。

### 跨天拖拽：复刻打包 collection 的原生 interactive movement，放开跨 section
原因：`List.onMove` 不支持跨 section（框架边界）；要跨天拖必须换底层拖拽机制。打包清单已有 `ReorderableItemCollection`（`UICollectionView` 原生 interactive movement，长按 1:1 跟手），它本就**支持跨 section**，只是被 `clampLocationToSection` 主动夹断在起点 section 内。
决策：**写姊妹组件 `ItineraryReorderCollection`（不碰稳定敏感的打包 collection）**，去掉夹断让 stop 可跨天落点；松手 `didReorder` 从 finalSnapshot 取**所有天**的新顺序，经 `TripStore.applyItineraryArrangement` 一次性重设每个 stop 的 `day`（SwiftData 关系 inverse 自动维护）+ `sortOrder`。移除 `EditButton`（长按拖拽常驻）。落点不夹断为已知边界（拖到 add/optimize 行下方仍正确归该天），需要再加软夹断。

## 2026-06-07 样式定稿收尾：精简样式 / 退役 Sheet fallback / 单一强调色

### 首页样式精简：保留 2·Map(默认)+ 4·Map(实验),删其余
原因：背景图方向已定(2·Map 照片卡),1·Plain(纯文字)与 3·Thumb(字母块小图)是探索期的对照样式,不再需要;留着徒增维护面与认知。4·Map(地图)用户想继续探索,保留。
决策：`HomeCardStyle` 收为 `.featured` / `.glass` 两个 case;删 `.accent`/`.hue`。连带按"最小必要集合"清死代码:`HomeStylePalette`(渐变兜底)、`bannerCard`/`bannerChip`/`isHero`/`isBanner`/`isFeatured`/`countdownText`/`daysToDeparture`、`croppedImage`(展示改走 `PositionedImage`)、6 个无引用 xcstrings key。`HomeStyleFlag.swift` + Dev Options 切换器**暂留**(因 4·Map 仍探索),最终只留 2·Map 时再删。

### 退役 FX Sheet fallback(无缩放保底版)
原因：FX(`CarryBottomSheetFX`)已长期稳定丝滑、设为默认;当初为按时上线保留的无缩放保底版(`CarryBottomSheet`)+ A/B 开关已无价值,纯维护负担。CLAUDE.md「历史 workaround 前提变了要重新质疑」。
决策：删 `CarryBottomSheet.swift` + `SheetFeatureFlag.swift`(`SheetVariant`)+ Dev Options「Sheet Implementation」开关 + 5 个相关 key;`HomeView` 直接调 `CarryBottomSheetFX`。`specs/sheet-fallback.md` 标「已退役」,其"行为要求"(手势/吸附/禁止行为)仍是 FX 的有效规范。

### 单一强调色「烟蓝」,不做用户可见主题切换(反转 06-02「无品牌色/Toggle 用 .primary」)
原因：用户问要不要在 Appearance 加主题切换菜单。判断:① 一个有自信的产品该替用户定下样子,摆一排颜色让用户挑反而稀释身份、违背克制(Apple 自家也不让换 app 强调色);② 强调色会重染全 App 交互元素,是大身份杠杆,不宜交给用户。Dev Options 里那 11 个色是探索工具,不是可上线功能。用户喜欢「烟蓝」。**这反转了 06-02「主题黑白、无品牌色、Toggle 用 .primary」的决策——当时前提是"还没定品牌色",现在烟蓝成了正式强调色,Toggle 用烟蓝是标准做法。**
决策：① 确立 `CarryAccent`(烟蓝 #5B7A96 / 暗 #7A9CB8,明暗自适应)为**唯一**强调色;删 `ThemeAccent`(11 选项)+ `toggleTint` 环境键(其存在理由 classic 过渡特例已不在)+ Dev Options「Accent Color」选择器;**不在 Settings 加任何主题切换菜单**。② **双层覆盖**:SwiftUI 层 `.tint(CarryAccent.color)` 全局;**UIKit 层 `UIWindow.appearance().tintColor = CarryAccent.uiColor`**——因 `.confirmationDialog`/`.alert`/上下文菜单/导航栏等系统组件**不跟随 SwiftUI `.tint()`**(证据:旧版全局 tint 为 .primary 黑白,这些菜单仍显系统蓝),必须靠 UIKit 窗口 tint 才能统一。以后新增彩色交互元素一律继承全局 tint / 用 `CarryAccent`,不要散落硬编码 systemBlue 或其它色。

## 2026-06-07 首页改版：行程背景图 / 卡片样式 / 备份

### 首页图像策略：工具期克制缩略图，大图留给规划/回忆期
原因：纠结"首页太素 vs 上大图"时回到产品定位——Carry 当前是打包工具,首页的活是"找行程/看进度/进去打包",真信息是日期/进度/剩余件数。而且**绝大多数行程用户不会专门传图**,围绕"大图"做主设计等于为少数情况优化、把默认体验逼成"渐变/地图兜底"。
决策:**图是可选的锦上添花,不是主角**。卡片设计本身不依赖图(无图也成立)。全幅大图(Tripsy 那种)属于"中期规划功能成熟、一趟行程变成完整的'地方'"之后才配得上,现在不上。本轮落点:2·Map=原始卡 + 有图则照片铺满。

### 背景图定位＝行程后的回忆；入口只在详情页「…」菜单、单项随状态切换
原因：创建行程时人还没到目的地、根本没有那里的照片;这个功能真正的使用时机是**行程结束后回头挑一张最有代表性的照片**。多入口(创建/编辑/详情)既冗余又难维护。
决策:**不放创建流程**;**编辑页入口也撤掉**(避免两处);唯一入口=详情页「…」菜单,**单项随状态切换**(无图「上传背景图」/ 有图「移除背景图」)。曾试详情页清单顶部放封面块→破坏打包专注界面,撤。曾试子菜单/两项平铺/confirmationDialog→分别因丑、累赘、从菜单触发弹窗锚点错乱被否。移除不加二次确认(纯视觉、可逆、原图仍在系统相册)。

### 背景图非破坏式裁剪 + 焦点居中 + 固定比例卡(WYSIWYG 根因解)
原因:照片有横有竖、背景卡是宽幅,用户选的图常需调整露出区域。先后试过:固定比例预览 + 先裁后 `scaledToFill`(二次裁切、切头顶)、焦点居中但卡片比例动态/随设备变(仍切)。根因:**预览裁切比例必须 = 展示卡片比例**,而卡片高度内容/设备相关,任何"猜一个固定比例"都跨设备失准(band-aid)。
决策:① 存原图 + 归一化 `BackgroundCrop`(可反复重调);② 展示用 `PositionedImage` 以选区中心为焦点、按选区大小定缩放、钳制铺满(主体永不被切);③ 照片卡用共享常量 `K=4.0` 作**最小高度**(= 预览窗口比例),内容更多则自然长高、只多露不切。预览与展示共用同一 K,设备无关、WYSIWYG。iOS 无任意比例系统裁剪件,故 UIScrollView 自建 pan/zoom。

### 4·Map(Apple 地图缩略图)仅作实验,不上线
原因:用户问"Luggy 在大陆就这么用,为何不行"。查证后纠正了我之前的过度保守——Apple 地图(含大陆高德底图+审图号)经 MapKit 是**正常授权用法**,关键只是**不能遮挡/裁掉 MapKit 自渲染的署名**,且**不能自叠 Apple logo**(商标禁止;我一度叠 `applelogo` SF Symbol 是错的,已撤)。但:`MKMapSnapshotter` 快照**不带**署名;实时 `MKMapView` 带署名但在 56pt 上署名固定尺寸会"占半块"。
决策:小尺寸(列表 56pt)地图**合规与美观无法两全**,故 4·Map 仅留 Dev Options 实验、**不作上线样式**。若将来要地图,只能用在**够大、能容纳 MapKit 自带署名**的尺寸(详情页大图/banner)。

### 首页默认样式 = 2·Map
原因:背景图功能只在 2·Map(铺满)/3·Thumb·4·Map(小图)显示,1·Plain 不显示;用户确认 2·Map 是方向,且重装会把 `@AppStorage` 重置回默认。
决策:`HomeView` 与 `SettingsView` 两处默认改 `.featured`,新装/重装即显示照片卡。(其余样式仍留作实验,定稿后清理。)

### 备份格式:发布前新增可选字段不升版本号;大文件随备份带上字节
原因:背景图的裁剪元数据在 `TripBundle.backgroundsData`(SwiftData),但图片是沙盒独立文件——之前备份两者都没带,重装/还原会丢封面。另:版本号此前 1→2(也在发布前,按同逻辑本无必要)。
决策:① 备份把每趟 `backgroundsData`(条目+裁剪)+ 顶层 `backgroundImages`(图片字节 base64)一起带上,还原写回沙盒;② **产品未发布、无在野旧备份,发布前新增可选字段一律归 v1、不升版本号**;版本号只在**发布后**因破坏性格式变更才递增(防"新格式备份在旧 App 还原")。已把版本从 2 重置回 1。

### PHPicker 选图加载:loadObject 失败回退 loadDataRepresentation + .compatible
原因:iCloud 未下载的照片(尤其 HEIC),`loadObject(ofClass: UIImage.self)` 常静默返回 nil → "选完毫无反应"。
决策:`preferredAssetRepresentationMode = .compatible`;`loadObject` 失败时回退 `loadDataRepresentation`(强制触发 iCloud 下载),下载期 UI 显 loading 蒙层。选图/裁剪用两个独立 sheet + 蒙层串联,**不要"单 sheet 内把 PHPicker 换成 SwiftUI 视图"**(presentation 状态错乱:背景透明/无法交互)。

## 2026-06-03 FX 缩放 Sheet 根治 + 设为默认

### 自动吸附动画用 Core Animation，禁止手写 CADisplayLink 逐帧动画
原因：FX 自动吸附原用手写 `CADisplayLink` 每帧算位置 + 限步，在任何刷新率都易抖（主线程时序 / 限步追不上理想值）。把 17 Pro 锁 60Hz 后 Tripsy 仍丝滑、我们仍卡——证伪了"帧率不够"，定位到"动画机制"错了。
决策：吸附改 `UIViewPropertyAnimator`（`dampingRatio 1.0` 临界阻尼、无回弹），交渲染服务器 GPU 插值、与刷新率自适应。删除全部 CADisplayLink 机制。**以后动画/吸附一律优先 Core Animation，不手写 displayLink 逐帧改属性。**

### Sheet 缩放：内容固定尺寸 + transform 缩放，绝不每帧 resize
原因：旧实现每帧改 `hostingView.frame` 宽度 → SwiftUI 每帧 relayout 整个列表 → 卡。
决策：SwiftUI 内容布局一次、尺寸固定；侧边收窄用**等比 scale transform**（内容 + 内边距同步缩，对齐 Flighty/Tripsy，而非裁切致内边距趋零）；运动期对内容层 `shouldRasterize` 缓存，避免 transform 每帧重渲染 `.blur`/`.shadow` 滤镜（运动结束/列表滚动时必须关，否则滚动被冻在缓存位图）。

### 圆角用嵌套 cornerRadius 层，不用每帧重建 CAShapeLayer.path
原因：上下不同圆角（顶 36 / 底大）用 path mask 需每帧重建路径 + 整层重栅格化，是 relayout 之后的头号每帧成本。
决策：两层各圆两角的嵌套 layer（GPU 原生 `cornerRadius` + `cornerCurve=.continuous`），零 path、零栅格化。

### 展开态底角半径必须 ≤ 屏幕物理圆角
原因：展开贴屏时底角压在屏幕角上，半径 > 屏幕 → 比屏幕缩进更多 → 角落露出月牙地图（反直觉：不是越大越贴合）。
决策：设 ≤ 屏幕圆角（17 Pro 取 40），让屏幕硬件圆角"过裁"，视觉上正好贴合屏幕的圆、绝不漏。无公开 API 读屏幕圆角（私有 API 禁用），按测试机型手设常量。

### 默认底部 Sheet 切到 FX（`.ultimate`）
原因：FX 已达视觉到位 + 纯 CA 丝滑。
决策：编译期默认改 `.ultimate`；fallback（`CarryBottomSheet`，无缩放）降为 Dev Options A/B 备选，**暂留**（待 FX 长期稳定再退役，见 `specs/sheet-fallback.md` 清洁路径）。

## 2026-06-02 QA 全量审计修复（28 条 → 9 批 PR）

### 删/改/复制 trip 的副作用必须同步 CalendarManager
原因：日历事件靠 carry://trip/{uuid} URL 标记，但 TripStore 删除/编辑/复制 trip 时只清通知和 Live Activity，从不动日历。开启日历同步的用户会在系统日历看到"已删 trip 残留事件 / 改名后日历仍是旧标题"等幽灵。
实现：CalendarManager 新增 removeTrip(UUID)（按 URL 匹配删除）+ updateTrip(TripBundle)（先 remove 再 addTrip）；TripStore 三处写入路径同步调用。

### 备份还原半原子化（pre-restore.json 快照）
原因：SwiftData 无原生 context 回滚，performRestore 先 delete 全表再循环 insert，中途失败可清空所有用户数据。
实现：delete 前把当前 backup.json 复制成 carry_backup.pre-restore.json，失败时记日志，用户/作者可手工恢复。还原成功后强制清旧通知 + 结束所有 LA + 按新数据重排提醒 + 写新 widget snapshot（restoreFromBackup/restoreFromData 共用 applyPostRestoreSideEffects）。

### 备份版本判断必须走 VersionStub 优先
原因：原"先完整 decode 再判 version"顺序错——CarryBackup 含新字段时完整 decode 先抛 decodingFailed（"文件损坏"），unsupportedVersion（"请更新 App"）永远走不到。
实现：先用一个只含 version 字段的 VersionStub decode 判版本，通过后再做完整 decode。

### LiveActivity 防并发重入 + 跨时区出发日比较
原因：① endIfDeparted 用 first(where: { _ in true }) 等价 first，多 Activity 残留时取错条目。② startIfNeeded 内 terminateAll 是 fire-and-forget 异步，紧随的同步 Activity.request 与旧 end Task 竞争，撞 ActivityKit 单 attribute 上限。③ 按 startOfDay 比较"出发日"在跨时区飞行时漂移一天。
实现：① 按 attributes.tripId == currentTripId 精确过滤；② 加 isStarting 锁 + 新增 terminateAllAndWait async 版本，await 真正等旧 end 完成再 request；③ 改为按"departureDate + 1 天 >= now"绝对秒数比较，保留出发当天，仅在出发次日才结束。

### 通知调度：guard 缺失 + 已过 fireDate 降级 + 时区锁定
原因：① updateReminderTime 不 guard 总开关/dateless，关掉总开关后改某档时间会排出本该不存在的通知。② scheduleReminder 用 fireDate > now 严格判断，已过 fireDate 静默丢弃用户错过整个档位。③ UNCalendarNotificationTrigger 按"触发时系统时区"重新解，跨时区飞行后通知时间漂移。
实现：① TripStore.updateReminderTime 加 if remindersEnabled && !isDateless；② NotificationManager.scheduleReminder fireDate 已过时改用 UNTimeIntervalNotificationTrigger 60 秒后触发一次（兜底）；③ 显式 comps.timeZone = TimeZone.current 锁住调度时本机时区。

### 深链冷启动 pendingTripId 主动消费防丢失
原因：CarryApp.onOpenURL 在 SplashView 阶段就可能把 router.pendingTripId 设上（Widget/通知/Universal Link 冷启动），但 ContentView 还没 mount，onChange(of: pendingTripId) 不会重放历史值 → 用户被深链冷启动进 App，看不到目标行程。已记 memory project_carry_deeplink_timing.md。
实现：ContentView.onAppearCommon 末尾主动 if let id = router.pendingTripId { handlePendingTripId(id) }。

### CalendarManager / NotificationManager 不再 try? 吞错
原因：requestAccess、requestAuthorizationIfNeeded 失败原因被吞掉，开关显示"已开"但用户收不到提醒、写日历无效，无任何排查线索。
实现：catch 内记日志（calendarSaveFailed / reminderScheduleFailed），CalendarManager 新增 authorizationStatus computed 供 UI 区分"未决定 / 已拒绝 / 已授权"。

### Agent 报硬编码字符串多为误判
原因：SwiftUI `Text("xxx")` 字面量会自动当 LocalizedStringKey 查 xcstrings，只要表里有 key 就工作正常。Agent 不知道这个 SwiftUI 行为，把所有字面量都报成"硬编码"。
实现教训：本地化审计需先用脚本 verify 每个字面量是否在 xcstrings 中存在 + 是否有完整翻译，再判断是否真硬编码。本轮 28 条候选中本地化部分大幅消减为 3 条真改（CFBundleDisplayName 补 6 语言 + 删 widget 伪 key + DestinationInfoView minimumScaleFactor）。

## 版本升级安全约定（长期有效，每次大版本必查）

### SwiftData 非轻量变更必须冻结旧 schema 快照，否则老用户启动崩溃
症状：新 SchemaV2 的 models 仍指向 live 类 → checksum 与 V1 相同 → 启动崩溃 "Duplicate version checksums detected"（已踩过 isDateless 一次）。这是最严重的升级事故，让所有老用户无法启动。
约定：非轻量变更（重命名/删除字段、改关系类型）时，必须为上一版本建 CarrySchemaV{N}Frozen.swift 冻结快照（只存结构，不含业务逻辑）。详细模板和步骤见 `CarrySchema.swift` 末尾注释。轻量变更（加带默认值字段）不需要新版本，SwiftData 自动处理。
每次变更必做：① 判断轻量/非轻量 ② 非轻量则冻结快照 ③ 真机用老版本数据验证迁移。

### CarryBackup.version 字段须在 restore 时做版本判断
现在备份 version 写了 1，但 restoreFromData 未读 version。一旦备份格式出现不兼容变更（新增非可选字段），用新版备份在旧版 App 还原会崩。约定：每次改 CarryBackup 结构时，同步在 restoreFromData 加 `guard backup.version <= currentVersion` 的降级处理，避免跨版本还原崩溃。当前 v1 尚未上线，首版发布后开始执行。

### UserDefaults / AppStorage key 一旦发布不能改名
改名等于旧用户所有设置丢失（不会崩，但体验差）。约定：key 确定后视为公开接口，只能新增 key + 在 App 首次使用时做一次性迁移（读旧 key 写新 key 然后删旧 key）；不能直接在代码里改 key 字符串。

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

## 2026-06-02 UI / 文案

### 设置开关启用态用 .primary（黑白），不用品牌橙
原因：暗色下单色灰开关（systemGray2/systemGray）开/关都是灰、难分辨（用户反馈"非常不明显"）。中途改用 `Color.accentColor`（橙）被用户否决——**主题是黑白，无品牌橙**（橙仅为个别强调色，不代表品牌）。最终用 `Color(.label)`（= 全局 tint `.primary`，黑/白自适应）：浅色黑轨白滑块；深色亮白轨道 vs 关闭深灰，亮暗对比强、一眼可辨，且纯黑白。
注意：iOS Toggle 滑块恒为白，深色下白轨道会让滑块边缘偏柔（靠"亮 vs 暗"整体对比传达开关态，可接受）；若要更利落滑块需自定义 Toggle（暂未做）。
教训：不要把 App 里的橙色（FAB/accentColor）当成品牌主色；主题黑白。

### 中文文案全角标点 + xcstrings 匹配 Xcode 格式
原因：`tripdates.clear` 等用了半角逗号、搜索 placeholder 用 `...`；另外用脚本改 `Localizable.xcstrings` 时若不匹配 Xcode 的 `" : "`（冒号前空格）序列化格式，会炸出整文件重排 diff（且 Xcode 在构建时会重写该文件、可能覆盖未提交编辑）。
实现：中文统一全角标点（见 CLAUDE.md 新规）；编辑 xcstrings 用 `separators=(',', ' : ')` 无尾换行，先做零改动 round-trip 验证再改；`git commit` 用显式路径避免误并入用户在途的图标改动。

## 2026-06-02 移除日历打包提醒

### 删除 Calendar Sync 里的"打包提醒"日历事件（含其时间设置）
原因：刚做完应用内通知系统（可选档位 + 时间的打包提醒）后，日历里再写一个"出发前1天打包提醒"事件是**重复提醒同一件事**，且为它加了子开关 + 时间选择器，属冗余配置、与 Carry 克制定位冲突。Calendar Sync 的非冗余核心价值只是"把行程显示到系统日历"。打包提醒交给应用内通知，两者职责清晰不重叠。未上线、无存量用户，正是动刀时机。
实现：`CalendarManager` 删 pack 事件写入（writeEvents 只写行程事件）+ 删 `packingListNotes`（仅 pack 用）；`addTrip`/`addAllUpcoming`/`writeEvents` 去掉 packHour/packMinute/includePackReminder 参数。`CalendarSettingsView` 删打包提醒子开关 + 时间行 + 相关 helper（packReminderRowEnabled/packTimeRowEnabled/rowTitleColor/toggleTint/packTimeBinding）+ 3 个 AppStorage（calendar_pack_*）。`TripStore` 创建行程时不再读 pack 偏好。删 3 个失效 xcstrings key（settings.calendar.pack_reminder / .packtime / calendar.event.pack.title）。Calendar Sync 现只剩"自动添加行程到日历"单一开关。

## 2026-06-02 通知偏好

### 默认提醒改为"用户自定义 + 创建时快照"，而非全局实时联动
原因：原默认对所有用户硬编码 `[提前3天 + 出发当天]`，太强硬、不尊重个体习惯；且默认管理隐含在物品清单里，作为未来行程规划 App 不可扩展（需集中的通知中枢）。参考 Tripsy「通知」设置（分组开关）。但 Carry 已有"逐行程提醒"能力，不能照搬 Tripsy 的纯全局实时模型。
实现：设置 →「通知」二级页选默认档位（默认开 出发当天 + 出发前1天）；新建行程时把全局默认**快照**进该行程的 `reminderConfigData`（`ReminderPreferences.defaultConfigs`）。改设置不影响已建行程，单行程仍可独立微调。`TripReminderConfig.defaults` 从 [提前3天+出发当天] 软化为 [出发当天 + 出发前1天]（去掉提前3天），仅作存量空配置行程的回退。偏好存 `UserDefaults`（nil→默认[0,1]，空串→[]全关，二者必须区分，否则"全关"被误当默认）；纳入备份。页面分组可生长（未来航班/协作）。入口放「提醒与显示」分区，未来通知场景增多再评估提为独立分区。
放弃：全局实时联动（会被动改变已建行程的已排程通知，体验差 + 重排风险）。

### 通知页加"单一全局默认时间"（修订 06-02：原决定不显示时间）
原因：初版"档位时间取 presets 固定值、设置页不显示时间"留了认知缺口——用户开了档位却不知道几点收到，且出发当天 7:00 / 其余 9:00 的混合不一致、用户看不到也无从理解。
实现：通知页顶部加一个时间选择器 `ReminderPreferences.defaultMinutes`（默认 09:00），所有已开启档位统一用此时间；`defaults` 回退也统一 9:00（去掉 7am 特例）。per-trip `TripReminderSheet` 仍可对单条提醒覆盖时间。
放弃：每档位各自时间选择器（太重，违背设置页保持简单）。

### 一级设置去掉日历同步右侧 On/Off 状态显示（反转 2026-05-31 决定）
原因：05-31 曾决定"Calendar 显 On/Off（真状态、有用）"。PM 复看后认为右侧状态显示在该行多余、想要更干净的一级列表。
实现：`SettingsView` 日历行去掉 `valueText`（On/Off），仅留标题+chevron；移除随之死掉的 `calendarSyncEnabled` 声明（CalendarSettingsView 内另有独立声明，不受影响）。`settings.calendar.status.on/off` 文案保留（无害，未来或复用）。

## 2026-06-01 电压预警（女性出行视角）

### 电压预警就地改造插头卡片电压行，不新增卡片/行
原因：女性出行常带电热美发工具，电压不匹配会烧设备，且多数人不知"转换插头(adapter)不变压、需变压器(converter)"。Carry 已有 `PlugCatalog` 电压 + `Locale.current.region` 家乡数据，零成本可做智能提醒。设计取舍：插头卡片固定高 112pt，新增整张卡片/独立行都有溢出或占空风险。
实现：复用现有数据，触发 = 清单含电热设备(`heatingAppliances` 集合匹配 `PackingItem.name` 英文规范名) + 家乡与目的地电压档位不同(`<160V`/`≥160V` 二分)。仅就地把电压行变橙 + 附提示。用"**可能**需变压器"措辞避免误报（设备可能本就全电压 100–240V）。
UI 迭代：①初版单行去掉 Hz 省空间 → 与普通状态信息不一致（用户发现）；②改两行(电压行 + 独立警示行) → 卡片显空、不利落；③**定稿单行保留 Hz**（`⚡️ 120V / 60Hz · may need a converter` 整行橙，`minimumScaleFactor(0.8)` 防长语言破版）——既一致又利落。
放弃：加 Curling iron 物品（中文与 Hair straightener 的「/卷发棒」重复致歧义，拆分需同步改 straightener 译文，属独立任务）；仅补 Hair dryer。

## 2026-06-01 首页冷启动揭示动画

### 首页分组入场揭示统一由单一 initialRevealProgress 阈值驱动
原因：冷启动入场揭示曾是两套并存的系统——Hero/Past 走连续值 `initialRevealProgress`（按阈值揭示），Upcoming 却单开 `didRevealUpcoming` 布尔 + `triggerUpcomingReveal` 的 `asyncAfter(0.28)` 硬编码延迟去对齐前一段 0.52s ramp；而 Planning 两套都没接、瞬间硬出现，造成"Upcoming 浮入 / Planning 硬出现"的视觉断层。`asyncAfter` 等动画正是 CLAUDE.md 点名的反模式（两处时长隐式耦合、深链时闭包因 `guard router.path.isEmpty` 早退导致 Upcoming 永久卡 opacity 0，还得在 onReceive 里补兜底）。`listRevealThreshold = 0.58` 本是 Upcoming 设计上的阈值，却成了 orphaned 死代码。
实现：Upcoming + Planning 一并收敛到 `initialRevealProgress >= listRevealThreshold`，与 Hero(0.16)/Past(0.78) 同一条 ramp，形成连续级联。删除 `didRevealUpcoming`、`triggerUpcomingReveal`、死的 `revealProgress` helper；macBody onAppear 去掉 `didRevealUpcoming = true`（Mac 无冷启动动画，`initialRevealProgress = 1.0` 不变）。深链兜底由"翻 didRevealUpcoming"改为"`if initialRevealProgress < 1 { … = 1 }`"——`initialRevealProgress` 两个 onAppear 均无 router.path 守卫，本就更稳。Planning 加 0.08/0.10s 基准 delay，读起来接 Upcoming 之后。
放弃：彻底重构成统一的"分组揭示"抽象（收益不抵改动量与时序风险，按最小必要集合止于复用现有 `initialRevealProgress` + 阈值）。遗留：深链(Widget/QuickAction)冷启动须真机验收，模拟器复现不了时序。
