# 项目进度

## 最后更新
2026-06-28

## 上次改动摘要（细节打磨 Vol.2：备注 data detector + 路径优化 + UI 规范对齐 · 2026-06-28）

> 单会话、无并行。**全部已提交并 push 到 origin/main**。

- **备注模块 data detector 根因修（`05ea5d7`）**：`isSelectable=false` 会阻止 UITextView data detector 点击（注释里的说法是错的）；改为 `isSelectable=true` + `sizeThatFits` 修复高度截断 + `UITextItemInteraction` 替换为 iOS 17 新 API `primaryActionFor` + http/https 链接在 Carry 内用 `SFSafariViewController` 打开（与附件链接体验对齐）、tel: 放行系统拨号。
- **路径优化器去掉时间锚点（`da876a1`）**：`plannedStartMinutes` 只有开始时间、无结束时间，锚点逻辑意义消失；改为只固定首尾两点，中间所有地点均参与优化。「已是最优」按钮文案 `Done` → `Got it`（`itinerary.optimize.got_it`，9 语言）。
- **航班详情日期对齐（`a7eaf21`）**：到达行有 `+1` 角标时，日期 Text 下方也补同宽 13pt 透明占位，使日期右边缘与时间数字右边缘对齐。
- **废弃 API 替换（`9655f59`）**：`UITextItemInteraction`（deprecated iOS 17）→ `textView(_:primaryActionFor:defaultAction:)`。
- **TripsyImportView UI 规范对齐（`da0d96d`/`ca6f0b0`）**：取消按钮移至左上角（`.cancellationAction`）；底部按钮 `CarryAccent` → Tier 1 `Color(.label)`；`carryCard()` 替换裸 `secondarySystemGroupedBackground`；行程名加 `design: .rounded`；`.background(.bar)` → `.bottomBarScrim` 渐变蒙层；删除无用 `colorScheme` 环境变量。
- **颜色 token 统一（`65bac58`）**：`ContentView` / `ScenePickerView` / `SuggestionPreviewView` / `TripDateRangePickerSheet` 四处硬编码 `Color(red: 0.08/0.09...)` → `CarrySubtleBackground.baseColor`。
- **去掉境内旅行「证件复印件」智能推荐（`da0d96d`）**：`city_break` 场景移除 `Photo ID copy`，不符合大陆用户境内旅行习惯；物品库保留供手动添加。
- **全 App 滚动条隐藏（`0f7be67`）**：扫描发现 21 个 View 文件的竖向 `ScrollView` 未隐藏指示器，批量替换为 `ScrollView(showsIndicators: false)`。保留例外：横向 ScrollView（已有）、List/Form 系统组件、TripDateRangePickerSheet 日历（需感知位置）。
- **ImportSharedTripSheet 文案截断修（`80abac0`）**：`update_note` Text 加 `.fixedSize(horizontal: false, vertical: true)`，防止 GeometryReader 量到压缩高度导致 detent 过小文案被截。

## 上次改动摘要（细节打磨：残影修复 + 住宿行程逻辑 + 行程册对齐 + 全天事件紧凑 · 2026-06-28）

> 单会话、无并行。**全部已提交并 push 到 origin/main**。

- **长按复制备注（`b37c50a`）**：NoteDetailRow 长按全段复制 + haptic + Toast，与地址/确认号等可复制字段一致。实现用 `UILongPressGestureRecognizer` 直接挂在 UITextView（SwiftUI `.onLongPressGesture` 无法穿透 UIKit 视图）；`isSelectable=false` 避免系统选择菜单与 Toast 冲突（data detector 点击不受影响）。VoiceOver「拷贝」无障碍动作兜底。
- **··· 菜单分割线（`95db1d5`）**：移除（红色危险操作）与备注/费用之间加 `Divider()`；仅在有 onNote 或 onCost 时才渲染分割线（CalendarEventDetailView 等 nil 场景不受影响）。
- **住宿中间日「出发/返回」仅有地点时才显（`f3d7a88`）**：中间日无任何地点时，「出发（置首）」和「返回（置末）」都不渲染——它们的价值是显示酒店→首站/末站→酒店的距离，无地点即无锚点、孤零零出现只有困惑。旧逻辑「出发」已有 `!timed.isEmpty` 门控但「返回」无条件渲染，现两者合并进同一 `else if !timed.isEmpty` 分支。
- **Trip Book 图标宽度对齐（`5daf87d`/`c9eb169`）**：飞行卡的「最远一程」(`airplane.departure`)、「最多机型」(`airplane.circle`)、费用卡的「最高一趟」(`arrow.up.circle`) 三行小料图标加 `.frame(width: 16, alignment: .center)`，不同 SF Symbol 内在宽度不同导致右侧文案无法左对齐，固定宽度后三行文案起点统一。
- **全天日历事件行高压缩（`c6be981`）**：`CalendarEventRow` 全天事件行高从 52pt（同行程行）→ 30pt，退到「信息条」层级；定时日历事件（插入时间轴、与行程行并排）保持 52pt 不变。
- **··· 按钮 menu 收起方形残影根因修（`2fab73c`/`4abc8b6`）**：三次迭代定位真根因——不是 shadow/material 渲染问题，而是 SwiftUI `Menu` 控件的 press/highlight 交互动画作用在自身矩形 bounds 上，收起时高亮以矩形淡出 → 方形残影。修法：在 `Menu` 控件本身加 `.clipShape(Circle())`（不只是 label 内部），把 Menu 的交互层裁成圆形；菜单弹出层在独立 window 不受影响。同时将 shadow 方案改为 `.background(.thickMaterial).clipShape(Circle()).shadow()` 顺序（shadow 从裁剪后像素计算）。
- **git 代理配置（永久生效）**：系统代理 `127.0.0.1:6152`（Surge/Clash），curl 自动读系统代理但 git 不跟随 → `git push` 直连 443 超时。已设 `git config --global http/https.proxy http://127.0.0.1:6152`，此后所有仓库 push/pull 走代理。
- **Ghostty 磁盘权限**：已将 Ghostty 加入「完全磁盘访问权限」，Claude Code bash 工具现可访问 `~/Documents`。

## 上次改动摘要（事件详情 ··· 菜单快速备注/费用入口 · 2026-06-27）

> 单会话、无并行。**全部已提交并 push 到 origin/main**。spec: `specs/quick-note-cost-menu.md`

- **QuickNoteSheet（`c012f86`）**：新建轻量备注编辑 sheet。medium/large detent，TextEditor 自动聚焦，dismiss 即保存（iOS Notes 范式，无 Cancel）。
- **QuickCostSheet（`c012f86`）**：新建轻量费用录入 sheet。medium detent 固定，大数字显示 + numpad 自动弹出，货币选择胶囊复用现有 CurrencyPickerView，dismiss 即保存。
- **DetailActionFooter 扩展（`c012f86`）**：加 `onNote`/`onCost` 可选回调和 `hasNote`/`hasCost` 状态参数。··· 菜单新增「添加备注」「记录费用」两项（位于「移除」之上）。nil 传参时菜单项不显示（CalendarEventDetailView 不受影响）。
- **三处调用接入（`c012f86`）**：TransportDetailView / LodgingDetailView / StopDetailView（ItineraryView 内）均接入两个 sheet 和对应 store 调用。
- **动态菜单文案（`3d53ac6`）**：已有内容时自动切换：`添加备注 → 编辑备注`、`记录费用 → 编辑费用`。9 语同步。
- **长按方案决策**：调研确认 ItineraryReorderCollection 在常态下也挂有 UILongPressGestureRecognizer（0.4s），与 SwiftUI .contextMenu 长按会产生手势冲突，放弃长按入口。
- **Tripsy 图标行方案决策**：裸图标行可见性好但可理解性差；Carry 维持现有 ··· 菜单方案，Edit 大胶囊保持主操作视觉重心不稀释。

## 上次改动摘要（Settings 多项默认值 + 文案优化 · 2026-06-27）

> 单会话、无并行。**全部已提交并 push 到 origin/main**。无 UI 结构改动，均为默认值或文案调整。

- **取消创建行程弹窗文案（`b7dca76`）**：确认弹窗保留（`hasDraft` 有草稿才触发，符合 Apple 新建表单范式）；两个按钮 9 语全部更新：`放弃更改 → 放弃行程`、`继续编辑 → 继续行程`（key: `tripinfo.discard.confirm` / `tripinfo.discard.keep`，仅 `TripInfoView` 使用，不影响编辑页）。
- **打包提醒默认开（`b7dca76`）**：`packEnabled = false → true`。核心功能对齐出发/交通/天气提醒，一并默认开。
- **退房提醒默认时间 9:00 → 11:00（`055e7df`）**：国际连锁酒店标准退房时间为 11:00，9:00 过早。`lodgingCheckOutMin = 540 → 660`。
- **打包提醒默认时间 21:00 → 20:00（`debd235`）**：`packMinutes = 1260 → 1200`。
- **打包 Live Activity 默认开（`37e2ec4`）**：灵动岛/锁屏打包进度是核心功能门面，与交通 LA 对齐同为默认开。`isEnabled = false → true`。
- **「经期打包提醒」→「经期随行提示」（`b7fd073`）**：功能本质是行程与经期重叠时的场景推荐（非通知），「随行提示」更准确；9 语同步更新。

## 上次改动摘要（创建/编辑行程：placeholder 颜色统一 + 退格删 chip + 键盘焦点回归修 · 2026-06-27）

> 单会话、无并行。**编译绿**；**已提交并 push 到 origin/main**（`2db4963` EditTripView placeholder + `616d28f` 焦点回归修 + `5e93a6a` TripInfoView placeholder + 退格删 chip）。**真机验收通过**。

**一、行程名称 placeholder 颜色统一（`2db4963` / `5e93a6a`）**
- **现象**：创建/编辑行程界面，「行程名称」placeholder 比「目的地城市」明显更暗，颜色不一致。
- **根因**：创建页 `TripInfoView.stableField`（编辑页 `EditTripView.stableField` 同款）用裸原生 `TextField`，placeholder 由 iOS 系统以 `.placeholderText` 灰自渲染；目的地字段 `DestinationChipsField` 走 `IMESafeTextField` + SwiftUI overlay `.secondary`，两者颜色不同。
- **修法**：两个 `stableField` 均改为 `IMESafeTextField` + `.secondary` overlay placeholder，与目的地/搜索框全 App 统一。
- **注意**：创建页是 `TripInfoView`、编辑页是 `EditTripView`，两个文件各有独立的 `stableField`，须两处都改。

**二、键盘每敲一字就收起（焦点回归，`616d28f`）**
- **根因**：将 `stableField` 改为 `IMESafeTextField` 时，焦点 binding 错误地桥回了 `@FocusState`——而 `IMESafeTextField` 持有 `UITextField`、无法挂 `.focused()`，`@FocusState` 因无所有者被 SwiftUI 持续重置为 false → 每敲一字触发重渲染 → `updateUIView` 误调 `resignFirstResponder()` → 键盘收起，**所有输入法**均受影响。此为 commit `a24cd03` 记录过、已有正解的反模式。
- **修法**：`TripInfoView` / `EditTripView` 的焦点改为普通 `@State Bool nameFieldFocused`（对齐 a24cd03），删除只含单 case 的 `FocusField` 枚举，`stableField` 去掉 `focus` 参数。
- **全仓审计**：所有 4 个 `IMESafeTextField` 调用点 + 6 个 `CarrySearchField` 调用点均已确认使用 `@State Bool`；唯一剩余的 `@FocusState`（`ItemPickerView.renameFocused`）是原生 TextField + `.focused()`，正确用法。

**三、目的地输入框：退格删除最后一个 chip（`5e93a6a`）**
- **交互**：目的地输入框为空时按退格键 → 删除最后一个已选 chip（iOS token field 标准交互，同邮件收件人栏）。
- **实现**：在 `ViewModifiers.swift` 新增 `BackspaceObservingTextField: UITextField` 子类，重写 `deleteBackward()`（UIKit 文档钩子，字段为空时退格不产生字符变化，`shouldChangeCharactersIn` 不触发，必须在此截获）；`IMESafeTextField` 增加可选 `onDeleteBackwardWhenEmpty` 回调；`DestinationChipsField` 接回调调用 `removeLastChip()`。

## 上次改动摘要（微信输入法选词不触发检索·根因修 + 花费空态居中 · 2026-06-26）

> 单会话、纯我的工作（与并行「多目的地 chip / FlightSearchSheet」会话物理隔离，全程隔离 index 只提自己文件、零卷入）。**编译绿（主 app + Widget）**；**已提交 main**（`fe06845` 输入法 + `9f3d4d9` 花费空态），未 push。真机验收交用户（已记入 Apple 提醒事项「Carry验收·输入法①~④」）。

**一、微信输入法选词上屏后不触发检索 —— 根因修（`fe06845`）**
- **现象**：行程规划添加地点，用微信输入法打「cuihu」预编辑态能出结果，但选词「翠湖」上屏后**不触发搜索**，再补个空格又恢复；系统拼音输入法无此问题。
- **根因（代码层面可断定）**：所有走 `StopSearchCompleter` 的搜索唯一触发是 `query`/`text` binding 变化，无旁路；而 SwiftUI 原生 `TextField` 依赖 UIKit 的 editing-changed 事件同步 binding，**微信等第三方输入法的「候选词提交」路径不触发它** → binding 停在选词前旧值 → didSet/onChange 不跑。「补空格即恢复」是决定性指纹（普通按键必触发 editing-changed、把输入框真实全文一次性灌进 binding）。判据可证伪：若 UIKit 层也不触发，则原生 UISearchBar 中文搜索全坏——但它们不坏，故是 SwiftUI 封装漏掉了这一下。
- **解法（绕开 SwiftUI binding、用 UIKit 可靠信号）**：新增共享组件 `IMESafeTextField`（`ViewModifiers.swift`，`UIViewRepresentable` 包 `UITextField`）——听 UIKit `editingChanged`（选词上屏必触发）回灌 binding；`updateUIView` 组字（marked text）期间绝不反写、清空时 `unmarkText`；与 `@FocusState`/`Bool` 双向桥接；占位符由外层 SwiftUI overlay 渲染（保持 `placeholder: LocalizedStringKey` 形参不变 → 调用点零改）。
- **范围**：① `CarrySearchField` 内部换用 → 一改覆盖 **6 个**字段（添加地点 / 地点搜索 sheet / 住宿 / 机场 / 首页行程搜索 / 物品库搜索）；② `DestinationChipsField`（目的地输入，创建/编辑共用）换用——其焦点编排较精细（选中后回焦、失焦固化 chip），改了焦点机制，**重点真机验**。③ 时区/货币的 `.searchable` 不动（系统组件难干净替换、输入多为拉丁字符、命中率低、纯本地过滤无 API 成本）。④ 纯表单框无需动（值在 Save/失焦时读、binding 已追平）。

**二、行程花费空态居中（`9f3d4d9`）**
- 空态原塞在 `ScrollView` 里且限 `minHeight: 360` → 在「顶部 360pt」内居中、偏上。改为：无花费时不套 `ScrollView`（无内容可滚），`emptyState` 用 `maxHeight: .infinity` 在整片可用区域垂直+水平居中；有花费时仍走 `ScrollView`。

**新会话 TODO（仅剩验收）**：① 微信输入法：添加地点选词即触发（核心）+ 其余 5 个搜索框 + **目的地字段焦点编排**（键盘不掉/可续输/失焦固化）；② 花费空态居中肉眼验。详见 Apple 提醒事项。

## 上次改动摘要（行程详情「锁屏追踪」逐段按钮下线 + 行程通知 4 个真 bug 根治 · 2026-06-25）

> 单会话、纯我的工作（与并行「地点排序自滚 / FlightSearchSheet」会话物理隔离，全程隔离 index 只提自己文件、零卷入）。**编译绿（主 app + Widget）、i18n [E]=0**；**已提交 main**（`535d9d7` LA 下线 + `0488035` 通知修复），未 push。真机验收交用户。spec: `widget-transit-live-activity.md`。

**一、交通详情「Track on Lock Screen」逐段按钮整段下线（`535d9d7`）**
- 决策：交通 LA 改「**仅自动 A**」。每段「在锁屏追踪此程」按钮（B 路径）是过度设计——用户计划行程时不会去想锁屏 UI，iOS 锁屏「一划即删」已是原生单程退出。删 `trackCard`/`transitTrackable`/`toggleTransitTracking` + B 专用方法（`userStopTransit`/`isTrackingTransit`/`systemActivitiesEnabled`）+ 2 个 track xcstrings key。功能本体（自动起 A）不变。
- **根因修「划掉又冒出来」**：持久化 `intendedTransitSegment`，A 运行前 `reconcileDismissedTransit` 对账——意图段已不在活跃 LA、又非我们主动结束 → 判用户划除（含 App 被杀期间划的）→ 记 dismissed、不再自动重起。不依赖在线监听，alive/被杀两种情形都正确。

**二、行程通知 4 个真 bug（`0488035`）**
- 🔴 **过期兜底成 now+60 → 矛盾 + 刷屏**：原 `makeCandidate` 把已过触发时刻的提醒改成「now+60 秒」重发。① 当天建当天出发行程 → offset 0「今天出发」+ offset 1（昨天）「明天见」同炸、自相矛盾；② now+60 是相对时间、每次重排（回前台/任何改动）反复武装 → 每分钟重发、点开还发。根因解：**整段移除过期兜底**（删 `useInterval` + interval 分支 + `allowImminentFallback`），过期即丢；装新版首次冷启动重排即把旧 now+60 残留当 stale 清掉（自愈）。
- 🔴 **导入的行程仍发提醒**：同行者分享 / Tripsy 导入刻意把 `remindersEnabled` 设 false（不该向你推送），但 `reschedule`/`collectXxx` 根本不看它、冷启动/回前台无条件全局重排绕过 → 照发。修：`reschedule` 收口点 honor `remindersEnabled`。
- 🟢 **冗余重排（性能）**：`restoreFromBackup`/`applyPostMergeSideEffects` 把全局 `refreshNotifications()` 放进 `for trip` 循环、按行程数跑 N 遍（含 N 次天气评估）→ 收敛为单次调用。
- 🟢 **每日摘要内容陈旧**：`updateItineraryStop`（改名）/`reorderItineraryStops`（重排）漏触发重排 → 「第一个是 X」陈旧。各补一行守卫式 `rescheduleDailySummary`（默认关零成本）。
- 🟢 **前台到点响声打断**：`willPresent` 由 `[.banner, .sound]` 改 `[.banner]`（用户选定：只横幅、不响声）。

**新会话 TODO（仅剩验收）**：① 导入同行者行程 → 无任何提醒；② 6.25 建当天出发行程 → 不刷屏、无「明天见」；③ 追踪中交通段锁屏划掉 → 回 App 不自动冒回来（含杀 App 后划）。

## 上次改动摘要（行程「地点排序」拖拽自滚过于灵敏 · 根因＝吸顶 inset 污染边界 · 模拟器实测修复 · 2026-06-25 深夜）

> 单会话、纯我的工作。用户睡前全权授权我自跑模拟器调试+验收。**编译绿**；**已提交 main**（`f36d514` 受控自滚 + `2b8d388` 边界根因修复）；**未 push**。设备级终验交用户明早。两个入口（行程列表长按拖拽 + 右上角「地点排序」）共用 `ItineraryReorderCollection`，同一修复一并覆盖。

- **症状**：拖拽地点排序时，手指稍微上/下移一点，列表就狂滚冲过头，难精确落到目标插入点（「C 想插 E/F 间却插到 M/N」）。
- **排查（可观测手段，避免盲调）**：
  1. 一度误判「原生 `beginInteractiveMovement` 自滚压不住、需全自定义重写」——**根因是我第一次装包时 `find` 抓到了过期 DerivedData 旧包**（snap-back 之前的坏版本）。开了 worktree 准备重写，模拟器挂日志（`RDBG`）才发现 **f36d514 的「回正」方案其实有效**：`applyMine=1`、无任何原生自滚进来，滚动就是受控的 165pt/s。**重写不需要**，worktree 已删。
  2. 但中部拖拽仍会触发自滚。再挂日志（`RDBG2`）抓到真根：`autoScrollVelocity` 用 `adjustedContentInset.bottom` 算底边，而该 inset 含**末段吸顶预留的 281pt 巨大底部 inset** → `bottomEdge = off+bounds−281` 被抬到屏幕中部 → 下方 60% 区域全成「越界」触发带。
- **根因解（`2b8d388`）**：自滚边界（与 band-clamp）改用**可见视口 + `safeAreaInsets`**（~34pt），**绝不用** `adjustedContentInset`；再软化边缘速度 4→3 行/秒、触发带 72→48pt。
- **模拟器实测（日志+截图）**：中部拖拽**零滚动**、精确重排；只有贴到真边缘才温和滚（~3 行/秒）；跨天拖拽 + 原生抬起观感不变。

**机制要点（snap-back，保留在 f36d514）**：拖拽期拥有 contentOffset——自家 displayLink 按「行/秒」推进 `dragAnchorOffsetY`，`scrollViewDidScroll` 把任何非本类位移即时回正到该权威值，原生那一跳不被画出。**教训**：① 装模拟器包务必用确定的 `-derivedDataPath`，别 `find` 抓到旧包误判；② 自滚/落点的「边缘」永远以可见视口+安全区为准，别掺业务用的 contentInset。

## 上次改动摘要（Roadmap：「导出行程单」从已上线移回即将推出 + 升为进行中 · 2026-06-25）

> 单会话、纯我的工作。只动 `Carry/Views/RoadmapView.swift`（`embeddedDefault`）+ 根目录 `roadmap.json`，两数据源同步。**已提交并 push 到 origin/main，GitHub API 核对线上生效**。

- **背景**：并行会话已把「导出签证行程单」功能整个删除（`63535f8`，见下方与 decisions 2026-06-24），但 Roadmap 仍把它列在「已上线」。本会话把它移到「即将推出」并标规划/进行中，让路线图与实际一致。
- **改动一（`8ae8cdd`）**：`itinerary-export` 从「已上线/Shipped」section 移到「即将推出/Upcoming」，状态 `done → planned`。文案 `导出行程单` → **`导出为行程单`**（en `Export as an itinerary PDF (for visas)`、繁中 `匯出為行程單…`）。`updatedAt` 两源都更到 2026-06-25。
- **改动二（`c46b1e0`）**：按用户要求与 `flight-status` **调换顺序+状态** → `itinerary-export` 升「进行中(in_progress)」排第一，`flight-status` 降「规划中(planned)」排第二。即将推出现序：导出为行程单(进行中) · 航班实时动态(规划) · Apple Watch(规划) · Mac(规划)。
- **排序参考（已与用户对齐）**：即将推出 section 规则＝**进行中在上、规划中在下；同状态内按「离上线远近」排**。
- **纪律**：roadmap 双源铁律（remote 覆盖 local 覆盖 embedded），改 `roadmap.json` 必须 push 才对线上用户生效；用 GitHub API（非 raw CDN，避 5min 缓存）核对。push 首次撞 GFW SSL 抖动、重试即过。提交只 `git add` 这两个文件，未碰并行会话的 `ItineraryReorderCollection.swift`（geoLeg 在途）。

## 待跟进 · 行程列表「切换器随滚动收起」动画细节（2026-06-23 夜）
- **现状 OK**：行程详情底部「行程/打包」切换器随滚动收起/露出（下滑 6pt 收、上滑 6pt 开、近顶恒显、spring 0.3 bounce 0.2），已复用到打包清单（`ItineraryReorderCollection` + `ReorderableItemCollection` 同一套 `onScrollHideChange` → `PackingListView.switcherHidden`）。用户初验「效果很不错」。
- **待办**：用户会**多用后再回看动画细节**（阈值灵敏度 / 收起展开顺滑度 / 内容回填的跳动感）。届时按真机手感微调上面几个数值（阈值在两个 collection 的 `updateSwitcherHide`，动画在 `PackingListView` 两处 `onScrollHide`/`onChange` 的 `withAnimation`）。当前不动。

## 上次改动摘要（Widget/Quick Actions 系统入口大批：距离连线 + 旅行伴侣修复 + large 概览 + Quick Actions 精修 · 2026-06-24）

> 单会话、纯我的工作（与并行「相册导入/性能」会话物理隔离，全程隔离 index 只提自己文件）。**全部编译绿、i18n [E]=0、已提交并 push 到 origin/main**。UI/真机验收交用户。spec: `widget-trip-companion.md` / `widget-transit-live-activity.md` / `quick-actions-phase-aware.md` / `widget-upcoming-large.md` / `itinerary-distance-legs.md`。

**一、时间轴：任意「真实地点」间显示距离（`ff740ef`，spec: itinerary-distance-legs.md）**
- 新增 `.geoLeg(from:to:day:)` + `ConnEndpoint`，在 `applySnapshot` 给「交通/租车端点参与」的相邻插 haversine 距离连线；**地址门控**（交通端 `address` 非空才算真实落点，机场无地址自然排除——免特判）。stop↔stop / stop↔lodging 仍走原 `.leg`/`.lodgingLeg`，零回归。纯叠加、不碰 rail 拓扑（connectivity）。

**二、旅行伴侣 Widget 真机暴露的两个 bug（`c789fab`/`7a4cd02`）**
- 🔴 **空写竞态**：`writeWidgetSnapshot` 原在 `App.onAppear` 调，trips 常未异步加载完 → 写空 snapshot 覆盖好的那份，Widget 空白/旧缓存（读模拟器 App Group plist 实测确认 `trips=0`）。根因解：移出 onAppear、挪进 `TripStore.init` Task（fetchTrips 后）+ 保留 didEnterBackground。**与 Quick Actions/交通 LA 同款竞态、当时漏修**。
- 🟢 **无时刻行程项也显示**：原「下一件事」只收有时刻项 → 没填时间的行程 Widget 啥都不显。加 `WidgetPlanItem`（含无时刻），当天无带时刻下一件事时显「今天的地点」（small 首项 / medium 前 3 + Today·N 处）。

**三、large 尺寸「接下来的行程」概览（`3ce52ab`/`6d9b64d`，spec: widget-upcoming-large.md）**
- `.systemLarge` 加入 supportedFamilies；新增 `WidgetAgendaItem`（地点+交通+住宿入住/退房，含无时刻 + 地点副标题 + 可选时刻），**按天分组**（今天/明天/周N）——差异化 Tripsy 的扁平时间流、适配 Carry「常不填时间」。相位自适应（旅行中=今天起清单 / 出发前=倒计时+打包+Day1 预览）。附加式（events/plan/stays 不动，小/中零回归）。
- QA 修：systemLarge 固定高不滚动、条目多两行 → 渲染行封顶从 9 降到 **7** + 截断显「+N 更多」（防静默裁剪）。

**四、Quick Actions 精修（`db21cdf`）**
- 副标题 目的地 → **行程名**（对齐 Widget displayTitle）；「我的足迹」→ **My Trip Book**（重命名+书本图标，经 `router.showTripBookRequest` 开行程册 sheet；Siri Footprint 仍指地图）；顺序改为 **〔当前/最近行程〕· New Trip · My Trip Book**。

**新会话 TODO（仅剩验收）**：① **真机验收**全套 Widget（小/中/大相位、距离连线、Quick Actions 顺序/标题/跳转）；真机当前被 Xcode DDI 挡着、可先模拟器。② large 在「进行中且 ≥8 项」行程上确认不裁剪 + 底部「+N 更多」。③（未来）目的地「今日实用信息」large（天气+货币+插头）= 独立第二个 large，需 WeatherKit 喂数据，留独立 spec。④（未来）交通 LA 接航班实时动态 API 填 `liveStatus/gate`。

## 上次改动摘要（相册导入 + 长行程列表/地图性能根因优化 · 2026-06-24）

> 多会话并行。本会话主改：相册导入链路 + 行程列表/地图性能。**编译绿、零警告**。真机/视觉验收交用户（真机当前被 Xcode DDI 个性化失败挡着，可先用模拟器）。

- **相册导入提速（`30980d6`）**：`extract` 串行逐张 → 有界并发 TaskGroup（N≈核数封顶 6，内存仍有界）；`parseExifDate` 改每次新建 DateFormatter（并发解码下共享单例非线程安全）。
- **地名不再阻塞进预览（`30980d6`）**：`assemble` 只聚类、立刻进预览；反向地理编码拆成后台 `geocodeNames` 流式回填（按地点 id，不覆盖用户改名）。消除原先「卡在 100% 等命名」的假死。
- **导入回列表不再「逐个蹦」（`30980d6`）**：`ItineraryReorderCollection.applySnapshot` 批量结构变化（>12 项/段数变）不播逐行插入动画，小改动仍保留。
- **160 天列表滚动卡顿根因（`30980d6`）**：`daySections` 构建时一次性算好①连线预算②行查找表（stop/day/segment/lodging by id），行闭包 O(1) 查，取代每个可见 cell 各重算整天 `timelineRowIDs`（内含扫全部天找租车）+ `safe*` 每访重排 = O(可见行×天²)。
- **空名地点展示兜底（`30980d6`）**：`ItineraryStop.displayName` 空名退本地化「未命名地点」（复用 `phototrip.place.untitled`），覆盖列表/详情/地图/导航；存储层保持真相（空）。来源：地理编码失败（旧隐患）+ 流式命名未完成即保存（新）。
- **详情页缩略图异步解码（`30980d6`）**：`AsyncThumbnail` 后台解 `UIImage(data:)` 再上屏，免主线程同步解码丢帧；预览页 `LazyVStack` 只解码可见天。
- **#1 完成帧 + #2 长行程滚动（`2f22782`，并行会话）**：导入读完钉满 N/N 并短暂停留再进预览（修「停在 49/50 像漏一张」）；day header / add-stop 行也走 O(1) 缓存 + 静态 DateFormatter。
- **#3 地图标注跳过空天（`43b202f` 合并）**：`mapAnnotations` 只为「有内容」的天建 MapContent，空天不再空跑一个 ForEach 身份（长行程焦点落空天 / 全屏全量时减负）。可证明行为等价。worktree/分支已清理。
- **「导出签证行程单」下线删除（`63535f8`/`11b6bfa`/`3fd91f9`）**：与产品预期不符、待重做 → 删而非藏（自包含、git 留底，详见 decisions 2026-06-24）。删 3 文件（`ExportItinerarySheet`/`ItineraryDocumentText`/`ItineraryPDFRenderer`）+ `PackingListView` 入口 + `CarryLogger` 两 event（含 errorEvents）+ 6 个 `itinerary.export.*` 文案；同步改 architecture.md、删 CLAUDE.md 失效举例。spec `itinerary-export-document.md` 保留作重做参考。找回：`git show 63535f8^:<路径>`。

### 🔔 下个会话待跟进（本会话上下文将满、移交）
- **本会话所有改动已全部提交进 main**（性能 `30980d6` + 导出删除三连）；工作区唯一未提交的 `Carry/Views/ItineraryReorderCollection.swift` 是**并行会话的 geoLeg 在途改动、非本会话**，勿替它提交。main `ahead 3`，未 push（用户没要求 push）。
- **验收清单已写进 Apple 提醒事项**（7 条 "Carry验收①~⑦"）：真机 DDI / 导入 49→50 / 地名流式浮现+不空白 / 读图提速 / 回列表不逐个蹦 / 长行程上滚顺滑 / 地图切天一致。真机当前被 **Xcode DDI 个性化失败**挡（部署侧、非代码：网络/重启/Developer Mode 关再开，或先用模拟器）。
- **🔴 #2 长行程空列表上滚仍待真机确认**：已做的 O(1) 行/连线缓存（`30980d6`）+ header/addstop O(1)（`2f22782`）是否消除「逐条加载卡」**未经真机验证**。若仍卡 → 下一个根因嫌疑＝**自适应高度 SwiftUI cell（UIHostingConfiguration）+ 200 section 估算高度，在「默认跳末日 → 上滚」时逐 section 自测真高、内容偏移回修 thrash**。按性能纪律：先**控制组实验**（临时给 cell 固定高看是否变顺）确认根因，**别盲改**；且 `ItineraryView`/`ItineraryReorderCollection` 正被并行会话改（geoLeg），动前先看工作区。

## 上次改动摘要（Quick Actions 相位感知 + 数据驱动 · spec: quick-actions-phase-aware.md · 2026-06-23）

> 单会话、纯我的工作。延续 Widget 的「行程规划如何上系统入口」评估，这轮做主屏长按 Quick Actions。**编译绿、i18n [E]=0**。**未提交未 push**。UI/真机验收交用户。

- **背景/缺口**：原 3 个 Quick Action 全静态（New Trip / Nearest Trip / Footprint），Nearest Trip 落「上次看的脸」、不感知相位、无副标题；行程规划完全没上。
- **改法（动态 + 相位感知）**：`QuickActionTarget.resolve(trips:)` 单一真源（`CarryShortcuts.swift`），相位三态——**today**（旅行中→行程脸 + 今天锚点，副标题 `城市 · Day N`）/ **upcoming**（最近即将出发→打包脸，副标题 `城市 · 明天 / 还有 N 天`）/ **recent**（无未来→回落最近过去、保持上次脸，保留旧 `findNearestTrip` 行为不回归）。中间槽据此**变脸**，仍 ≤4 槽（New Trip · 中间槽 · Footprint）。
- **路由统一**：`handlePendingShortcut` 的 open_trip 从裸 `path.append(id)` 升级为构造 `TripDeepLink(face,anchor)` 走 `handlePendingTrip`（与通知/Widget 同源、无闪烁选脸 + 滚到当天），顺手修掉「落上次的脸」。Siri `OpenNearestTripIntent` 同源对齐。
- **刷新时机**：`refreshQuickActions(trips:)` 挂 `TripStore.init` Task（冷启动 trips 已载）+ `didEnterBackground`；**不挂 onAppear**（trips 可能未载、会瞬时写空中间槽）。
- **QA 两轮**：子代理对抗式审查 + 我逐条核验。修了 2 处真改进（① onAppear 竞态→移除该刷新点；② handlePendingShortcut 先同步读全 key 一次清、闭包用局部值，消除 0.35s 窗口串读）；其余 7 条核验为非问题（dayOrder 已被 returnDate 前置过滤、daysUntil 恒≥1、macCatalyst API 合法且原本无守卫等），不过度改。
- **本地化**：+4 key（`quickaction.today.title` / `.subtitle.day` / `.subtitle.tomorrow` / `.subtitle.in_days`）×9 语言；删了不可达的 `.subtitle.today`（出发当天已归 today 相位）。
- **第 4 槽「下一程」未做**（用户未要、与交通 LA 重叠，spec 标默认不做）。
- **新会话 TODO**：① 提交 + push（用户定）；② UI/真机验收：出发前长按落打包脸 + 副标题「还有 N 天/明天」；旅行中落行程脸今天 + 「Day N」；无未来回落最近过去；冷启动跳转不丢；Siri 相位落点一致；切语言看副标题（count=1 显「明天」）。

## 上次改动摘要（行程详情/列表视觉收口 + 交通字段体系 · 2026-06-23 夜）

> 一整场「行程规划 UI 扣到 ADA」+「地面/水路交通字段补全」。全部已提交 push（与并行 Widget 会话物理共用工作树、提交走隔离 index / 只取自己 hunk，互不卷入；中途并行一次整文件 `git add` 把我未提交的 `field.place` hunk 扫进了它的 commit `0d46898`——已在 main、功能无碍）。

- **行程列表视觉**：日期头分级（`.title3` bold 20 + 当天色点 10 + 上方留白 22，不画横线）；行高 46→**52**、距离段 legGap 24→**18**（补偿行高对 leg 的副作用）；日历条↔日期头间距 36→**28**；住宿行单行→**两行**（名锚 + 角色副行）；日历叠加事件**按时序插入主脊、脊在其处断开**（A 方案，全天仍钉顶）；交通行 provider（航司/公司）统一**浅灰退后**。
- **详情复制**：值字段**长按即复制 + Toast**（`longPressCopy`，手势统一长按）；标题栏 **`.textSelection`** 长按系统拷贝；电话/URL 长按复制、tap 保留拨号/打开。
- **出发后专注**：进行中行程打开**落行程列表 + 滚到今天**；底部切换器**随滚动收起**（上滑/近顶/切脸回），行程+打包同一套；用稳定 `ScrollHideRelay` **解耦**（翻转只重排胶囊、不重渲地图/daySections）。
- **底栏玻璃**：行程切换器与首页底栏统一到 `BottomBarGlass`（iOS26 Liquid Glass / 否则 ultraThinMaterial+叠白），去掉原 regularMaterial+黑叠层的「灰脏」。
- **交通字段**：航班加 **E-ticket**（纯数字、真实占位、全闭环）；**火车/巴士/渡轮**整套字段（`routeName`/`coachNumber`/`seatClass`/`serviceType` 4 新 model 字段 + 按 mode 文案 Transport number / Reservation code / Train·Bus·Ferry type，去 Code/Platform）；**Add Other** 保留为通用兜底（地点改 `Location`、去 Seat）；**Cruise 决定不加**（多日复合体验、套不进交通段模型）。spec: `itinerary-ground-transport-fields.md`。
- **Dark Mode 终验 ✅**（代码审计 + 真机关键屏）。

**本场新待办**：① 切换器滚动收起动画细节真机多用后微调（见顶部「待跟进」块）；② **建议并行 transit 会话改用独立 worktree**（同工作树同改 `TransportEditView`/`TripStore`/xcstrings/`CLAUDE.md`，整文件 `git add` 互卷已发生）；③ 改 xcstrings 后**别再跑 xcodebuild**（会重写 catalog、清插值 glue key 非英译 + 给新 code 字符串造空 stub/重复）——正解：代码先 build 验证，再从 HEAD 重建 xcstrings + i18n-audit [E]=0、提交后不再 build（已写入 CLAUDE.md）。

## 上次改动摘要（Widget 表达行程规划：旅行伴侣桌面组件 + 出行日「下一程」Live Activity · 2026-06-23）

> 单会话、纯我的工作。先评估「行程规划如何在 Widget 体现」→ 写两份 spec（确认后）→ 逐个实现 + 两轮 QA。**两份均编译绿（主 app + Widget Extension）、i18n [E]=0**。✅ **已隔离 index 提交并 push 到 origin/main（`0d46898`）**——与并行「train/bus/ferry / transport type」会话物理隔离、只含本会话 16 文件，零卷入；并行会话 rebuild 主 xcstrings 冲掉的我 4 个 key 已补回。UI/真机验收交用户。spec: `widget-trip-companion.md` / `widget-transit-live-activity.md`。

**背景**：Widget 原只表达「打包」（出发前几天的事），而更核心的行程规划（航班/住宿/地点/交通/时区…）从未上 Widget。评估用「可瞄+当下相关+省一次打开」三判据筛出两个真场景：旅行中「今日陪伴」、出行日「下一程」。明确排除整条时间轴/地图/花费/酒店地址等（过不了判据）。

**一、旅行伴侣桌面组件（Spec A，已实现待验收）**
- 桌面组件随**旅行相位**自适应：出发前=倒计时+打包（保持现状无回归）；**新增旅行中**=`Day N/M` + 下一件事倒计时 + 今晚住哪/退房。仅有日期行程进旅行中相位。
- 数据：`WidgetTripSnapshot` 扩 `returnDate/isDateless/events/stays`（事件绝对时刻按各活动时区在 App 侧算好，复用 `absoluteDate`）；选片从「未来行程」改「未结束行程」（纳入进行中）。刷新走现有 `didEnterBackground` 漏斗（未散加 per-mutation 调用）；Widget 靠 timeline entries（每事件+每午夜）跨天自走、App 不开也对。新字段全可选→旧 JSON 退化出发前、不崩。
- 修了自审 bug：`tonight` 文案 `%@` 占位却当无参标签渲染 → 改 `String(format:)` 单 Text。

**二、出行日「下一程」Live Activity（Spec B，已实现待真机验收）**
- 起停 **A+B**（用户拍板）：A 自动起（冷启动 `TripStore.init` Task + 回前台扫所有行程，为 [出发前 24h, 到达+1h] 内最临近一程起 LA）；B 显式（交通详情页「在锁屏追踪此程」按钮）。主开关 `liveActivityTransitEnabled` **默认开**，放「锁屏实时活动」设置页（原「锁屏打包进度」页泛化为两开关、入口标题改 `settings.liveactivity.title`）。
- 新增共享模型 `TransportActivityAttributes`（SharedSources/，pbxproj 登记进两 target，预留 liveStatus/gate 给未来航班动态、不改结构）；`LiveActivityManager` 扩交通 LA 全生命周期（含并入 `endAll`、删行程/抹数据/关开关清理、并发锁复用）；新增 `TransportSegment.absoluteDeparture/Arrival`。
- 锁屏+灵动岛三态（`CarryTransitLiveActivity`）：倒计时 `Text(timerInterval:)` 系统自走、相位（起飞前/途中/已抵达）渲染时按 `Date()` 判定。**schedule-based、本轮不接实时航班动态**（Roadmap 独立项），文案不暗示实时追踪。

**本地化**：主 app +4 key、widget +7 key（A 的 day_of/tonight/checkin/checkout + B 的 until_departure/en_route/arrived），9 语言齐、`i18n-audit` [E]=0。

**交付前自审 + 子代理 QA 一轮（已全修，复编绿、[E]=0）**：
1. 🔴 真 bug：`endAll()` 改为结束打包+交通后，关「打包」开关会连交通 LA 一起杀 → 拆出 `endAllPacking()`，打包开关只调它。
2. 🔴 真 bug：Widget LA 的 `Text("\(from) → \(to)")` / 首页 `Text(" · \(name)")` 是插值字面量 → Xcode 构建把 `%@ → %@`、` · %@` 误抽成本地化键（i18n [E]=16）→ 改 `Text(verbatim:)` + 删误抽键。
3. 🟡 events `prefix(60)` 会截「最早 60 条」致长行程后段无下一件事 → 改「先丢过去事件(< today)再截 60」，恒保留当天及未来。
4. 🟡 B 按钮 auth 关闭时会假显「追踪中」→ optimistic 前查 `systemActivitiesEnabled`。
5. 🟡 冷启动系统残留交通 LA 会被 teardown+recreate 闪烁 → `startTransit` 命中已存在 Activity 时重连而非重建。
6. 🟢 `startTransitIfNeeded` 加「出发晚于时间窗即跳过」粗筛（过去侧不剪，避免误杀返程日晚航班）；`widgetEvents` 仅 number 空时才取 displayCarrier（省航司库懒加载）。
- 复核判为「非问题不改」：timerInterval 范围（传固定 now、分支保证有效）、returnDate 旧 snapshot 短窗退化（设计内兜底自愈）、时区回退设备时区（项目既有约定）。

**第二轮根因复扫（更严视角，已修，复编绿、[E]=0）**：
7. 🔴 真 UX 根因 bug：A+B 冲突——用户在详情页**显式停掉**某程追踪后，A 回前台会自动把它重新起起来、覆盖用户意图。根因解：`LiveActivityManager` 记「用户已停段」集合（`liveActivityTransitDismissed`，UserDefaults），A 跳过 dismissed 段；再次显式起（B）即解除；`startTransitIfNeeded` 按现存段剪枝防累积。B「停」改走新 `userStopTransit(segmentId:)`。
8. 🟢 质量：`absoluteDate` 公式原有 3 份拷贝 → TripStore 那份指向单一真源 `TransportSegment.itineraryAbsoluteDate`（NotificationManager 既有份属已上线、不动）；`widgetEvents` 跳过无名定时地点（退化数据不入「下一件事」）。
**收尾（已完成）**：✅ 提交+push（`0d46898`，隔离 index）；✅ 并行会话冲掉的 4 个主 xcstrings key 补回；✅ 验收待办写入 Apple Note「Carry · Widget 验收待办」；✅ 顺手清掉并行会话遗留在暂存区的一个 stale 反向 hunk（`TransportEditView.swift`，工作区彻底干净、零代码改动）。

**新会话 TODO（仅剩验收，交用户）**：① **Spec A 设备验收**（调某行程出发日到昨天看旅行中态：Day N/M·下一件事倒计时·今晚住哪；出发前无回归；明暗/多语言）；② **Spec B 真机验收**（LA 模拟器受限）：建今/明起飞航班→开 App(A)/点详情按钮(B)→锁屏+灵动岛下一程倒计时、跨时区起降无错点、到达后自动消失、删行程/抹数据清理、与打包 LA 并存观感、**显式「停」后回前台不被自动重起**；③ 主开关「锁屏实时活动→出行日下一程」默认开，觉激进可改默认关（产品默认值，非 bug）；④（未来）接航班实时动态 API 时填充 `TransportActivityAttributes` 的 `liveStatus/gate` 并 `update`，不改结构。

## 上次改动摘要（计数文案复数化全清扫 + 全目录未翻译键审计补全 · 2026-06-23）

> 单会话、纯本地化（i18n）工作。**编译绿**（主 app + Widget）。复数清扫走隔离 index 提交进 main（`75516bf`/`240c2da`/`ed99979`）；全目录翻译在独立 worktree 完成、再以隔离方式合入 main（`ed2aa1e`）。全程与并行 weather/notification 会话物理隔离、互不卷入（确认其 weather keys 叠在我的翻译之上、无覆盖）。**均未 push**（push 由用户定）。验收交用户（切设备语言看物品库/设置/空状态/Widget + count=1 语法）。

**一、计数文案复数化（根因解：xcstrings substitution variations，非手动 `.one`）**
- 触发：首页「My Trip Book」pill `home.tripbook.subtitle`（`%lld trips · %lld countries`）count=1 显 `1 trips · 1 countries`。根因＝全 App 计数文案一律扁平 `%lld`、从未用复数变体。
- 全 App 扫 + 修：约 **25 个 inline 计数 key** 转复数变体（en/de/es/fr/pt-BR 分 one/other，含动词/形容词/分词一致如 `1 stop awaits` vs `2 stops await`、es `1 registrado` vs `2 registrados`；中日韩无复数、保持扁平）。涵盖行程卡 days、打包/物品 items、住宿 nights、通知 stops/things/days、提醒 days/weeks、日历批量 trips、数据导入/恢复 trips、Trip Book 花费、照片行程 places、Tripsy 导入、Widget 进度/件数。
- 调用点：普通 `String(format:)` → `String.localizedStringWithFormat`（让复数按 locale 选 one/other）；已带 `locale:`/`localizedStringWithFormat` 的不动。
- 拆历史欠债：删 SettingsView 手动 `count==1 ? ".one" : ...` 三处分支 + 两个 `.one` 键（restore.success 第二调用点漏判 `.one` 是真 bug，一并修）。
- 验证可达性避免「修非 bug」：`widget.countdown.days_left`/`departure.days`（调用点 0/1 已特判、天数恒 ≥2）、`notif.2days/3days`（硬编码）、`tripbook.aircraft.many`（gate ≥2）、`Day %d`/年份/缩写单位/纯数字比例——均确认安全、不动。
- 详情页「My Trip Book」无此问题（大数字+独立标签统计块范式，不需语法一致）。

**二、全目录未翻译键审计补全**
- 信号＝`state==needs_review` 或缺语言。审计两个目录共 **257 个 key** 有未翻译语言（221 needs_review + 23 缺语言 + zh-Hans 缺 26 / zh-Hant 缺 30 + widget 3）。
- 分类处理：26 个专有名词/品牌/纯格式键（Mapbox/OpenStreetMap/`%lld`/`–`/emoji/URL）设为源值；231 个真实文案（38 UI 键 + 整个物品库 + 场景/行程类型标签 + 惊喜长文案）逐一翻译（派 3 并行子代理产出、我统一机械校验 zh 全角/残留英文后应用，1371 值/229 key）；删 2 死键（`Add %lld items`、被英文键取代的中文孤儿 note）。
- 质量：繁简非转换（复合维生素/複合維生素、暖手宝/暖暖包、驱蚊液/防蚊液、连衣裙/洋裝、酒店/飯店…）、中文全角、德语名词大写、法语标点空格、日语常体、韩语해요体。
- **复核：两个目录 0 needs_review / 0 missing。** xcstrings diff 偏大（~6400 行）＝250 key 各补 6–8 语言 + 脚本展开多行格式（非全文件 reflow，44k 行只动 ~15%；Xcode 下次构建可能重排回紧凑、一次无害格式化 diff）。

**新会话 TODO**：① push（用户定）；② 设备级验收（切 de/es/fr/ja/ko/pt/繁中 看物品库·设置·空状态·Widget + count=1 语法）；③ 注意 xcstrings 与并行 weather 会话同改、提交务必隔离 index。

## 上次改动摘要（目的地国家码「输入即解析」+ 城市模式 + 本地化检索 · 2026-06-22）

> 本会话工作（先开 worktree 实现 resolve-at-input，合回 main 后续在主仓库续做）。**编译绿**、Worker 已部署（3 次）、线上穷尽验证过。提交走隔离 index、只含本会话文件。**已 push 到 origin/main（至 `8218ac5`）**。设备级验收（IME 选词、国内点亮、端到端）交用户真机。spec: `destination-country-resolve-at-input.md`。

**根问题**：地图点亮到访国家依赖 `trip.countryCode`，原本只由 `destinationCity` **自由文本反查**（600 行城市表 + CLGeocoder）——语言相关、有歧义、永不完整（日文假名/韩文/欧洲本地名落表外）。

1. **resolve-at-input（`16f73c0`）**：目的地字段从纯文本升级为「文本 + 自动补全」（复用 `StopSearchCompleter` 双源）。选中建议 → 捕获该结果**权威 ISO 国家码 + 坐标**，建行程直接写入、跳过文本反查。Worker `/retrieve` 透传 `country`（Mapbox `isoCountryCode` / Geoapify `cc`）；`ResolvedPlace.countryCode`；`TripInfo`/`createTrip` 接受预解析码；`TripInfoView` 加 IME 安全的建议列表（兄弟视图、预编辑态不改 TextField）。打字不选/历史行程仍走文本兜底 + `geocodeMissingTrips` 自愈。
2. **城市模式（`7e1309e`）**：目的地是「城市」字段，原复用 POI 检索 + 无 proximity → 首条常是同名错国家 POI（Tokyo→新加坡店、首尔→巴黎韩餐馆）。Worker `/suggest` 加 `kinds=place`：Mapbox `types=country,region,district,place,locality`（去 poi/address）、Geoapify `type=city`；缓存键含 kinds 分桶。仅目的地字段传，AddStop 的 POI 检索不变。
3. **本地化检索（`eecd0db`）**：city-mode 在 `language=en` 下伤欧洲本地异名（München→瑞士、Roma→Romania、Lisboa→哥伦比亚、Wien→空）。App 把 UI 语言传给 Worker（`lang=`），place 模式用作 Mapbox/Geoapify 检索语言 → München+de→慕尼黑·德国。POI 模式仍 en。
4. **CJK 干净标签（`8218ac5`）**：CJK query 已翻英文，却用 `language=ja/ko` 检索会拿回 Mapbox 冗余全层级名（東京→「日本東京都東京都」）。改为「city-mode + 非 CJK」才取 UI 语言，CJK 保持 en → 東京→`Tokyo`、서울→`Seoul` 干净。拉丁异名仍按 UI 语言。

**验收（线上已验）**：9 语言输入海外城市均解析到正确城市 + 正确 ISO 码、建议文字干净。**新会话/真机 TODO**：① 中文输入法选词不丢字；② 国内目的地走 MapKit/高德 `isoCountryCode` 点亮；③ 端到端选中→建行程→点亮。

## 上次改动摘要（通知/深链承接路由：按语义选脸 + 锚点到天 · 2026-06-23）

> 本块为本会话工作（与天气/深链同会话延续）。提交走隔离 index、只含本会话文件（`ItineraryView` 与并行会话的日历叠加层共存，仅切片提交本会话 3 个 hunk）。**编译绿 0 警告，待验收**。未 push。spec: `notification-deeplink-routing.md`。

- **问题（2026-06-23 审查）**：6 类行程通知点开**全部**落 `PackingListView` 的「上次看的脸」，丢弃 id 里的 `segId`/`stayId`/`dayOrder` 锚点 → 打包类可能开在行程脸、行程类可能开在打包脸；有锚点也不定位到天。
- **根因解（提交 `7be69f0`）**：裸 `UUID` 升级为富目标 `TripDeepLink(tripId + face + anchor)`（`TripDetailFace`/`TripDeepLinkAnchor` 提升为共享类型）。`NotificationManager.deepLink(fromIdentifier:)` 按类别映射脸+锚点（depart/pack/weather→打包；transport/lodging/daily→行程 + 段/住宿/天锚点）。`handlePendingTrip` 跳转前写 `TripDetailFaceStore`（首帧即对脸、无闪烁）+ 拆 modal + 落 path + 存锚点；`ItineraryView` 就绪后消费锚点设 `focusedDayId` 滚到对应天。`carry://packing/{id}` 同源修复。

## 上次改动摘要（天气预警 DEBUG 验证钩子 + 深链跳转拆 modal · 2026-06-22）

> 另一并行会话同时在改行程详情/编辑（见下一块）。本块为本会话工作，提交走隔离 index、只含本会话文件。**编译绿、模拟器验收通过**。未 push（用户验收后自行 push）。

- **天气预警可验证性（Part 2）**：Developer Options 新增「Weather Alert」段的 `Simulate weather alert` 选择器（`debugForceWeatherAlertKind`，会话级、`TripStore.init` 启动清零）。强制 `WeatherAlertEvaluator.evaluate` 返回选定 kind、跳过 WeatherKit + 6h 节流，**下游链路全真**（写 store → reschedule → collectWeatherAlerts → 通知 → 点击埋点），端到端可在模拟器验。spec 补「模拟器验收」节。已读模拟器日志确认 `weather_alert_scheduled` + cache 写入 + `weather_alert_fired`。
- **深链跳转被 modal 挡住（根因修复）**：通知/Widget/快捷指令唤起行程时只 push 根 NavigationStack，盖在栈上的根级 sheet（Settings/Search/Trip Book/创建/分享导入）不会被关 → 行程详情被挡住看不到（复现：停在某 sheet → 按 Home → 收到通知点进来）。修法：`NavigationRouter.rootModalDismissalRequest` 信号 + `handlePendingTripId` 跳转前清掉 ContentView 级 sheet、HomeView 观察信号关自己 6 个根级 sheet；详情页内 sheet 靠 path 重置自动卸载。提交 `7eccc8a`。

## 上次改动摘要（行程规划「详情 + 编辑」视觉大审查/重构：确立「编辑=详情的可编辑态」语言 · 2026-06-22）

> 单会话、纯我的工作。**编译绿**。**全部已提交并 push 到 origin/main（至 `ea416cb`）**，工作区干净。每步均经用户截图验收后才提交。提交走隔离 index（防并行会话卷入），xcstrings 每次 key 级核验只含我的键。

**一、详情页（只读）**
- 节奏/层次重排：schedule 与 place-info 分离 + 时间右成列（等宽数字）；地点/景区把日期·时间收进**头部副标题**（caption 用中点连读是对的，与卡片表格行的「时间右列」是**不同容器**的不同处理）。
- **日历事件详情统一进共享设计语言**（`DetailSheetHeader` + 灰画布白卡）：补 **URL 行**（`CalendarOverlayEvent.url` ← `EKEvent.url`，可点 `LinkDetailRow`）；来源日历降为底部色点行；时间线右侧补「开始–结束」。

**二、编辑页（阶段 2）—— 确立设计语言「编辑 = 详情的可编辑态」**
- **语言要点**：同画布/卡片但**功能性表单**；地点/搜索行用**通用 `mappin`**（语义 marker 钥匙/箭头**只留详情**）；**身份段以实体名作标题**（地点=Place、住宿=Lodging、交通=Flight/Car rental…）；图标「挣来才有」（密集 More 表无图标、单一功能卡 cost/note/attachments 有、端点有 marker）；时间 chip 等宽。
- **租车**：取/还车**完全对称**（删 toggle）+ **还车镜像取车**（选/改取车自动同步、手改即解绑，内部 `returnMirrorsPickup`）；端点 = `mappin + 地址 / 分隔线 / calendar + 日期时间 chips` 二栏；去派生 Days；新建默认取车=行程首日 17:00 / 还车=末日 17:00；车型占位 `保时捷 911 Turbo S`。
- **航班/火车/巴士/渡轮**：修地点行**蓝染**（缺 `.buttonStyle(.plain)`）；空字段 pattern 占位（码 ABC / 航站楼 2 / 座位 32A / 机型 A320）；**Cabin 行高**修（原生 `.menu` Picker 偏高 → `Menu{Picker}`+自定义 label）。
- **地点/景点**（共用 `StopEditView`）：Type 值蓝→主色 + **修「自定义 Menu label 含标题→展开缩没」gotcha**（标题外置到 `LabeledContent`）；Note 补图标 + 行高 `2...5→1...4`；**移除电话编辑**（自动回填的辅助信息、详情只读即可）。
- **住宿**：**搜索优先添加流** `LodgingSearchSheet`（点「+」先搜 → 选中 push 进**预填表单**让用户选入住/退房日期 → 保存才落；底部「找不到酒店？手动添加」push 空表单）——照搬航班 `FlightSearchSheet` 的「搜索+手动兜底」+ 地点的预填；名称/地址改成与地点同款（可编辑名 + 只读址 + Change location）；Booking code 移到「More」段（与交通一致）；新建默认入住 **15:00** / 退房 **12:00**；移除 Nights、移除电话编辑。

**三、删除 & 列表**
- **编辑态删除全移除**（交通含航班/地点/景点/住宿）→ 删除**只留详情「···」菜单**（根因：编辑/详情叠层，在编辑里删后会露出**悬空详情**）；详情删除**去二次确认**（开菜单+点红字本就两步）；清 4 个死键。
- **列表左滑删除补全**：原仅 `.stop` → 扩到 `.transport`/`.carRental`/`.lodging`（租车两行、住宿跨天任删一条都删整段）；日历事件/连接线不可删（对的）。

**四、日期选择器**
- 时长 chip 改**只显天数**（`date.days_only`，原「X天X晚」窄屏/大字号截断）。
- **月标题贴星期栏**根因解：`scrollTo(anchor:.top)` 会把 `LazyVStack.padding(.top)` 顶出视口 → 改 **`.contentMargins(.top, 20, for: .scrollContent)`**（scrollTo 尊重内容内缩边）。

**记忆**：存了 `carry-unify-in-service-of-beauty`（美的前提下统一、不以统一牺牲美）。

**新会话 TODO**：① 日期选择器 `.contentMargins` 20pt 待真机终验（觉得多/少改个数）；② 住宿名称段「Lodging」标题、其它交通(火车/巴士/渡轮)细节核查；③ **Dark Mode 终验 ✅ 已过（2026-06-23，代码 + 真机关键屏）**：代码全用语义色 + 自适应 token（`ItineraryDayPalette` 含 light/dark 两套、`legibleInk` 按亮度选墨、`BottomBarGlass`/Toast/材质均自适应），无硬编码深色 bug；真机截图复核行程列表 / 航班详情(含 e-ticket) / 住宿详情 / 编辑住宿 / 复制 Toast 均干净（层级对、对比够、无发灰/亮晕）。**唯一未截到**：日历叠加行（该趟无 overlay 事件），代码自适应、低风险，下次带日历事件的深色屏顺带一扫即可；④ 阶段 2 剩余编辑页打磨。

## 上次改动摘要（通知默认/退房模型/竞态+64配额 · 权限&法务审计 · 抹掉所有数据 · 数据二级页 · Roadmap 重梳 · 2026-06-21 深夜）

> 单会话、纯我的工作。**编译绿**。**已 push 到 origin/main**（本批已提交部分 + carry-legal）。⚠️ **有两处我的工作未提交**（见末尾），因与并行 Tripsy 会话在同文件原子混合、切不开。

**已提交并 push（origin/main 至 `e73f0c5`）：**
1. **通知**：默认时间调整（每日 09:00 / 打包 21:00 / 还车·退房 1h）；**退房提醒从「提前量」改「当天清晨固定时刻」C 锚**（早退房 clamp、文案带退房时刻）；🔴 **修重排竞态**（原 cancel→add 顺序会删掉刚排的通知）→ 改**全局 64 预算调度** `NotificationManager.reschedule(trips:)`（值类型候选主线程构建、回调里「前缀匹配−选中集」差删 + 近端优先取 budget）；冷启动（`TripStore.init` Task 内、fetchTrips 后）+ 回前台滚动补位。spec: `notification-budget.md`。提交 `ce5a8c3`。
2. **权限&法务审计**：`NSLocationWhenInUseUsageDescription` 从 pbxproj 迁入 Info.plist；中文 usage 文案统一「你」；日历文案补「读取叠加」；About 增 Mapbox/OpenStreetMap 署名。**carry-legal 已 push**：隐私政策补**日历披露** + PIPL 第14条修「零传输」自相矛盾（据实披露航班/境外检索跨境）；用户协议**重定位为「旅行助手」** + 修「不依赖网络」失真；境外检索服务商改列「Mapbox 或 Geoapify」防漂移。release-checklist 记了 ASC 待办。
3. **抹掉所有数据**（spec: `erase-all-data.md`，**仅模型层已提交**）：`TripStore.eraseAllData` 覆盖全副作用（cancelAll 通知 / endAll Live Activity / `CalendarManager.removeAllCarryEvents` / 背景图·附件 deleteOrphans / SwiftData / `DataBackupManager.clearBackup` / widget），新 `allDataErased` 埋点。**UI 在 SettingsView（未提交，见末尾）**。
4. **Roadmap 重梳并 push**（`roadmap.json` 真源 + 内嵌默认同序）：「行程规划」从即将推出→已上线并拆 9 亮点；**已上线按卖点价值排序（30 条）**；即将推出 = 航班实时动态(进行中)/Apple Watch 版/Mac 版；**全部标题改大白话**（3 语言地道）。iCloud 同步按用户决定**留在已上线**——但代码未真接 CloudKit，**上线前必须补**。

**🔴 未提交（我的，等并行 Tripsy 会话提交后再隔离补上）：**
- `Carry/Views/SettingsView.swift`：抹除 UI + 「数据与备份」二级页 `dataManagementPage`（`.dataManagement` 路由）+ 撤销窗口（9s、倒计时环 TimelineView 帧驱动、`.disabled(eraseUndoVisible)` 锁操作、`.onDisappear`/进后台即中止）。**与并行 Tripsy 导入在同一原子 diff hunk、无法 `git apply` 分离**。
- `CLAUDE.md`：我加的两条约定（本地通知调度闭环、读全量数据再做副作用），与并行的海外检索/时区段共处。
- **新会话 TODO**：① 待并行会话提交后，把这两处走隔离 index 干净补提；② 上线前把 iCloud CloudKit 真正接上（roadmap/隐私政策已对外标已上线/承诺）。

## 上次改动摘要（Trip Book 花费体系：7 类细分 + 按方式拆 + 时间轴 View all；浅色卡片 elevation；列表卡统一规则 · 2026-06-21）

> 单会话、纯 Trip Book / 花费模块；5 个隔离-index commit（`e42b4e8`/`9a4eaf7`/`e8247cd`/`ba444bd`/`86d8950`），与并行通知会话不重叠、未碰其文件。全程编译绿；**未 push**（用户在另一会话统一 push）；UI 验收交用户（含用增强备份 `carry_backup_augmented.json` 在模拟器验过 >10 国家/机场的 View all）。

**1. 花费体系细化**（`e42b4e8`/`e8247cd`）
- `TripSpendStats` 由「交通/住宿/地点」3 类 → 按 `SpendCategory` **7 类**（地点拆 餐饮/景点/活动/购物/其他，零新增录入、复用单行程页 `TripSpendDetail` 口径不漂移）。`TripSpendBreakdown` 由固定三字段重构为 `[SpendCategory: Double]`。
- 交通再按 `TransportMode` 拆（`transportByMode`，与 `byCategory[.transport]` 同源、和=Trip total）——「查看全部」下钻按方式分行，修「租车/火车都显示成飞机」（同单行程逐笔修法）。明细行单烟蓝图标（不用单行程页多彩，守 Trip Book 单一强调色）。
- 花费卡加「最高一趟」texture 行（≥2 趟才出，中性措辞避免超支暗示）。scope 卡图标 `airplane.departure`→`map`（消与机场卡撞图标 + 脱离飞行区误读）。

**2. 花费「查看全部」改时间轴**（`ba444bd`）
- 「按趟堆叠」→「按时间倒序流水账」：年分段（倒序）+ 年度小计 + 每趟左侧日期标记 + **整宽卡片**（日期不占左列、消右偏）；无日期行程归底「未排期」组。`TripSpendRow` 带 `departureDate`。

**3. Trip Book 卡片增减**
- 新增：在地足迹卡（`StopCategory` 计数）、飞行「最远一程」（路线+距离+时长，≥2 段有距离才出，`FlightLeg`/`longestFlight*`）。
- **撤掉**概览「最长一趟/最频繁年份」：无父卡可挂、hero 已挤 → 根因撤除（含模型字段/计算/文案）。对比「最远一程/最高一趟」能成立=各有父卡延伸。

**4. 浅色卡片 elevation 根因修复**（`ba444bd`）
- `CarrySurfaceCardBackground` 浅色由「半透明白叠近白背景、无边框无投影」（看不清分界）→ 纯白不透明 + 柔和投影 + 0.5px 描边（iOS 标准 elevation，背景近白时卡片无法「更亮」只能抬升）；暗色保留填充对比、不变。仅 Trip Book 在用。

**5. 列表卡统一规则「预览 10 + View all」**（`86d8950`）
- 国家/机场预览前 10 + 「View all」全列表 sheet（替机场旧「+N」**静默兜底**）；大洲天生 ≤7 → 套规则即「永远全展示」、自然豁免。
- affordance 统一（Apple「See All → 目标页用内容名」）：按钮一律 `View all`、sheet 标题用各自卡片名（花费 sheet 从「View all expenses」→「Total spend」）。删死 key `tripbook.airports.more`/`tripbook.spend.view_all`。

- **待办**：① push（用户在另一会话统一）；② 真机回归一遍三卡阈值 + 时间轴跨年分组；③ 大洲不动（≤7 全展示，已确认非 bug）。

## 上次改动摘要（通知默认时间调整 + 退房提醒模型切换 + 通知模块审计/根因修复/64 配额重构 · spec: notification-budget.md · 2026-06-21 晚）

> 单会话、纯通知模块。**全程编译绿**（主 app + Widget）；**未提交**（push 由用户定）；UI 验收交用户。与并行会话（`TripSpendStats.swift`/`HomeView.swift`）不重叠、全程未碰。

**1. 通知默认时间/提前量调整**
- 每日摘要 08:00→**09:00**；打包提醒 20:00→**21:00**；租车还车 3h→**1h**；住宿退房（见下，模型已改）。两份默认值同步（`ReminderPreferences` + 设置页 `@AppStorage`）。
- 删死代码 `ReminderPreferences.lodgingCheckInMinutes`（key `carry.notif.lodging_checkin_min`，零调用、设置页未暴露的入住提醒残留）；注意与 `LodgingStay.checkInMinutes`（用户填的入住时间，活代码）无关、未动。

**2. 退房提醒：提前量 → 清晨固定时刻（C 类行程日锚）**
- 根因：退房是「当天 deadline 前撤离」、人已在房间，不是「提前赶去」的交通型事件；套交通提前量模型别扭、1h 弹「12点退房」基本冗余。改**退房当天清晨固定时刻**（默认 **09:00**，同出发提醒/每日摘要），晨间唤醒、从容收拾。
- **早退房 clamp**：退房时刻早于清晨锚 → 落在退房时刻本身，杜绝「已退房才提醒」。
- 文案 **T1+C**：标题 `退房 · 酒店名`；正文退房时刻有填→`今天 12:00 前退房，记得收拾好行李、结清账单。`（按设备 12/24h 本地化），没填→回落无时刻版。新增 `notif.lodging.checkout.body.timed`、改 `notif.lodging.checkout.body`/`settings.notif.lodging.subtitle`、删废弃 `settings.notif.lodging.checkout_lead`——9 语言齐、全角校验过。设置页住宿段从提前量 Picker 改时:分 DatePicker。
- 顺手统一：还车通知时刻从硬编码 `%02d:%02d`（24h）改 `clockLabel`（跟随设备 12/24h）。

**3. 🔴 通知重排竞态（高危真 bug，已修）**
- 原 `scheduleReminders` 先 `cancelReminders`（异步 getPending 回调里 removePending 旧 id）再同步 add；id 确定性、新旧相同 → removePending 提交晚于 add 且删的正是刚 add 的同 id → **重排时把刚排好的通知删掉**（首次排空 pending 不触发，故漏测；改设置/编辑后通知静默失效）。修复并入下方全局预算结构。

**4. 🟢 64 挂起上限：全局预算调度（spec: notification-budget.md）**
- iOS 每 App 挂起本地通知上限 64、超出系统静默丢最远的。改「各行程独立调度」为**全局预算**：`NotificationManager.reschedule(trips:)` 跨所有行程构建值类型 `Candidate`（主线程读 @Model）→ `commit` 在 getPending 回调里 `budget=64−foreign−4`、按 fireDate 升序取前 budget（近端优先）。**竞态根除**：删除集=「前缀匹配−选中集」与新增集天然不相交。
- **滚动补位**：冷启动（`TripStore.init` 的 Task、`fetchTrips` 之后）+ 回前台（`willEnterForeground`）重排，远端随临近补位。TripStore 18 处单行程 `scheduleReminders(for:)` 收口为全局 `refreshNotifications()`。删死代码 `scheduleAt`/`schedule`/`scheduleAfterInterval`。
- **🔴 自审抓出并修掉新引入的雷**：冷启动 refresh 原放 `App.onAppear`，但 `trips` 在 init 的 Task 里**异步**加载 → onAppear 跑时 trips 空 → 候选空 → commit 把已排通知全删（每次冷启动清空）。已移进 init Task 内 `fetchTrips()` 之后。

- **待办**：① UI 验收（退房文案带/不带时刻、还车 12/24h、设置页默认时间、**冷启动后通知不丢**）；② 提交 + push（用户定）；③ 64 预算裁剪只在多个密集行程 >60 条时触发，DEBUG 有日志可观测。

## 上次改动摘要（海外检索多源加固 + Geoapify 备份 + 时区归一 · 本会话 review · 2026-06-21）

> 对上两个会话的「海外 POI 检索」+「时区系统」做两轮代码审查 + 全部修复，并接入备份检索源。**编译绿（主 app + Widget）；Worker 已部署 + 线上 curl 验证通过**。已提交 `19f19b9`（海外检索 review 批 + Geoapify）/ `c87370c`（时区种子）/ `1bdf150`（时区归一）；**未 push**。App 侧 UI 验收交用户（模拟器搜海外地点走一遍）。决策见 decisions.md 同日条目；运维见 docs/infrastructure.md。

**1. 🟢 海外检索多源 + Geoapify 备份 + `SEARCH_PROVIDER` 自动降级**
- Worker 加 provider 抽象，`auto` = Mapbox 主 + Geoapify「主源硬失败才降级」；suggest id 带 `mb:`/`ga:` 前缀路由回来源；Geoapify 把 retrieve 数据编进 id（base64url）离线解析。App 零改动。线上切 `geoapify` 验证 `ga:` 通、再切回 `auto`。

**2. 🔴 合规红线加固（堵伪造绕过）**
- `ga:` id 客户端可伪造 `cc` 绕过 CN 过滤 → 改用**坐标 IANA 时区**判定（沪/乌/港/澳）+ country code 双防线；比 bbox 准（不误杀首尔/台北）。线上验证恶意 id → `domestic_excluded`。

**3. 🟢 时区三修**
- 大陆时区归一北京时间（`Asia/Urumqi` 等 → `Asia/Shanghai`，`TimeZoneCanonicalizer`，MapKit 捕获 + 备份导入两入口）；详情卡 GMT 偏移按事件日期算（夏令时）；多时区 Day 标种子取出发地。

**4. 🟢 海外检索 review 批 bug**
- Mapbox session token retrieve 后轮换（漏钱）；结果乱序覆盖防护；解析失败退回无坐标停靠点（原死点击）；sheet 关闭取消在途请求；Worker 常量时间 token、query 上限、disabled 按 path 返回、纯 geoapify 不强求 MAPBOX_TOKEN、降级结果不缓存、翻译 cache 兜底。

**5. 数据校准（一次性，非代码）**
- 用户真实备份 `carry_backup_2026-06-20_15-01.json` 扫全 14 条：1 处 `Asia/Urumqi` 归一 + 23 处空时区按坐标补全 → `*.calibrated.json`（其余字段逐字节未变）。

- **待办**：① push（用户定）；② App 侧 UI 验收（搜海外地点：session 轮换 / 乱序 / 死点击 / 详情卡夏令时 / 关闭清理）；③ Geoapify key 用户已轮换。

## 上次改动摘要（按天色板定稿 + 住宿详情跟随当天色 + 航班机场/航司名本地化全链路 · 2026-06-21）

> 本会话三块、各自独立提交（隔离 index、与并行「时区 / HomeView / 海外 POI」会话不重叠）。**全程编译绿；未 push**（领先 origin 30）；UI 验收交用户。

**1. 行程按天色板定稿**（`420b6e1`/`fdc84f5`/`6e734f6`/`c38f6fe`）
- 经「哑光 10 → 暖色 10 → 精简 7 → 全色环铺开 7」多轮，最终：`Day1 烟蓝(品牌) → 万寿菊 → 棕榈绿 → 雪青 → 覆盆子 → 青绿 → 赤陶`，每天一个清楚不同色名。
- 色序用 `scripts/itinerary-day-palette-solve.py`（CIEDE2000、明暗取较差值）求解：两两 ≥ ΔE 14.7、相邻最差 ≈20。前 4 天（蓝/橙/绿/紫）按用户偏好钉死。否决「纯暖色」（暖色占色相环一小段、ΔE 崩到 8）与「降饱和」。决策见 decisions.md；规范见 design-system.md。

**2. 住宿详情跟随「被点那天」的色**（`18e7425`）
- 住宿跨两天、列表入住/退房各显当天色；点退房行（覆盆子）原详情却显入住日色（雪青）——不一致。改：`.lodgingDetail` 路由带 `dayOrder`，详情按被点那天取色。

**3. 航班机场/航司名按界面语言本地化**（spec: `itinerary-flight-name-localization.md`；`3e73e89`→`76279de`）
- 根因：多语言库（`airlines.json`/`airports.json`，9 语言）只用于搜索、没接显示层 → 直显英文。改 **render-time resolution**：存语言无关的码/航班号，显示时按当前语言查名、回落原文。零迁移、无新字段、无启发式。
- **航司**：`AirlineDatabase` 去 actor 化为同步单一源（不可变参考数据无需 actor），`TransportSegment.carrierName(forLanguageKey:)`/`displayCarrier`。覆盖**全部显示点**：时间轴 / 详情 / 搜索卡 / 导出 / Trip Book 花费 / 通知。
- **机场**：`AirportCatalog`（数据单一源）+ `AirportDatabase` actor 仅搜索；详情按码取 `displayName`。
- **导出按「所选语言」**（非设备 locale）：`DocLanguage.nameLanguageKey` + `Airline/Airport.localizedName(for:)`；**新增繁体导出** `.zhHant`（固定文案补地道繁体、非简转繁；`modeName` 移入 `ItineraryDocumentText`；台/港/澳设备默认繁体）。
- **🔴 性能松解（关键决策，`76279de`）**：机场库 1.6M 改**按需加载**、**删掉「每次启动预热」**——不用航班的用户零开销；详情机场名后台 `Task.detached` 异步（首次开某航班详情时那行一瞬「英→中」、次要可接受）。航司库 225K 随用随载。地图端点标签不本地化（次要 a11y + 避免逼加载大库）。
- **并发**：项目 `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`；纯数据/工具类型显式标 `nonisolated`（`Airport`/`Airline`/`AirportCatalog`/`AirlineDatabase`/`AirportLocale`/`FlightNumberParser`）。
- **待办**：① push（用户定，本地领先 origin 30，含本会话全部 + 并行已提交）；② UI 验收（中文环境航司/机场名、繁体导出 PDF、详情机场名一瞬刷新）。

## 上次改动摘要（行程时区系统化 Phase 1+2 · spec: itinerary-timezone.md · 2026-06-21 夜）

> 跨多文件大改 + SwiftData 轻量迁移（加可选字段，未上线故无需 schema 版本）。**编译绿**（主 app + Widget）。**已提交未 push**（`88382eb` Phase 1 / `67cd49e` Phase 2 / `ef37140` 实测修复）。**模拟器实测通过**（用户授权后跑 iOS 26.5）：建上海→巴黎行程（The Bund + AF111 PVG→CDG），Day 头 Jun 21 显 GMT+8、Jun 22+ 顺延 GMT+2 ✓。
> **实测修了 3 个 bug**（`ef37140`）：① 捕获——MapKit 本地搜索的 `CLPlacemark.timeZone` 几乎总 nil，改用 `MKMapItem.timeZone`；② 刷新——collection section id=天，加航班不重配头部 → 小标加完不显（要退出再进），改为 apply 后重配可见头部；③ 空白天 carry-forward——空白天继承「上次落地后所在时区」（飞抵巴黎后的空白天显巴黎，非回退出发地）。
- **🔴 修真 bug（Phase 1）**：原来地点/住宿时间是「裸的当地分钟数、无时区」，通知里 `tzId:""` → 按**设备时区**算 → 跨时区行程下退房/每日提醒**错点触发**（如人在上海、巴黎退房提醒按上海时间响）。
- **🟢 Phase 1 正确性**：`ItineraryStop`/`LodgingStay` 加 `timeZoneId`（地点搜索从 `placemark.timeZone` 自动捕获；航班已有机场时区）；`TripBundle.primaryTimeZoneId/isMultiTimeZone` + 各活动 `effectiveTimeZoneId` 兜底；通知（lodging/daily/无区 transport）改用「活动自身时区 → 行程主时区 → 设备」并传给 trigger。全链路同步：备份/还原、分享文件、复制行程、TripStore setter。
- **🟢 Phase 2 多时区显示**（方案比原 spec 更克制）：多时区行程时**每个 Day 头部**显示该天时区小标 `GMT±N`（按当天日期算偏移、含夏令时）；单时区零显示。换区基本跨天发生、当天跨区的航班已 `A→B` 自解释，故按天标比逐条贴更清晰、改动面更小。
- **⏸ Phase 3 暂缓**：可编辑兜底时区切换器——Carry 现状**无**可见切换器（用户最初截图是 Tripsy 非 Carry，已在 spec 更正），自动捕获已覆盖常见场景；新增可编辑 picker 是设计敏感点，待用户过眼 Phase 1+2 后定。
- **待办**：① push（用户定）；② Phase 3 设计确认（兜底切换器，Carry 现无可见切换器）；③ 可选：详情卡内时间旁加时区小注（主时间轴已由 Day 头覆盖）；④ 退房提醒跨时区真机扫一眼（逻辑已修，低风险）。

## 上次改动摘要（航班名本地化：机场/航司名按界面语言显示 · spec: itinerary-flight-name-localization.md · 2026-06-21）

> 中文环境下已保存航班的机场名/航司名显示英文——根因是「已有的多语言库（`airlines.json`/`airports.json`，含 9 语言）只用于搜索选点，没接到显示层」。改 render-time resolution：存语言无关的码、显示时按当前语言查名、回落原文。**编译绿**；UI 验收交用户。本会话改的与并行会话不重叠/已隔离提交。
- **🟢 航司名**（新 `FlightNameCache.swift`，普通 enum + `static let` 同步缓存 225K 小库）：`displayCarrier(for:)` 航班从航班号 `FlightNumberParser.split` 出 IATA → 本地化 `displayName`；非航班/未识别 → 存的承运方原文。接入时间轴行、详情副标题/标题、搜索结果卡。gate 在 `.flight`（火车号不误判航司）。
- **🟢 机场名**（仅详情副行露名，时间轴/Trip Book 显码本就语言无关）：`AirportDatabase` 加 O(1) `airport(forIATA:)`（新 `byIATA` 索引）；`TransportDetailView` 用 `@State + .task(id:)` 异步解析本地化名（1.6M 大库不在主线程同步解码），回落英文。
- **确定性、零迁移、无新字段、无启发式**：码/号命中库 → 本地化；否则原文。同时修好「上游英文」与「手动搜索冻结语言」（render-time 解析跟随设备语言、切语言也变）。机场名非自由文本→无覆盖顾虑；承运方自定义（非航班/未识别）原样保留。

## 上次改动摘要（通知中心整体改造：统一进 Settings + per-event 静音 + 文案重写 · spec: notification-center.md · 2026-06-21）

> 把全 App 通知统一成「设置 → 行程提醒」中心。**已提交**（`381ef8b` 代码+文案 / `248574e` 收尾文案微调）；**未 push**。编译绿，设置页明暗双模自验过。与并行会话（住宿上标等）交织过，xcstrings 走 surgical 提交。
- **🟢 架构：Settings 为唯一真相源**。删 per-trip 提醒编辑（`TripReminderSheet`/`ReminderPickerSheet` + 行程 ··· 菜单「行程提醒」入口 + addReminder/removeReminder/updateReminderTime/setRemindersEnabled）；出发提醒改读全局设置，改设置即 `store.rescheduleAllTrips()` 套全部行程。`TripBundle.reminderConfigs`/`remindersEnabled` 字段保留（schema，已 vestigial）。
- **🟢 引擎重写 `NotificationManager`（A/B/C 三锚）**：A=出发日锚（出发提醒、打包提醒）；B=事件时刻锚（交通起飞/发车、还车、退房——按「出发日+dayOrder+当天分钟+事件时区」算绝对时刻、trigger 锁 timeZone，命名空间分离可独立取消）；C=行程日锚（每日摘要）。
- **🟢 6 类通知**（默认值）：出发提醒（开，档位精简成 `[0,1,3,7]`=当天/前1/前3/前1周，清晨 09:00）；**打包提醒**（关，**自己的时间默认出发前一晚 20:00**，与出发提醒分开——打包发生在晚上）；交通出发（开，多档提前量默认 3h，**航班/非航班两套口吻**）；**还车**（关，**只还车、取车不提醒**，同日 3h）；**退房**（关，**只退房、入住不提醒**，同日 3h）；每日摘要（关，08:00，**正文带出当天第一站**）。
- **🟢 逐事件静音**：`TransportSegment`/`LodgingStay` 加 `remindersMuted`（轻量迁移+备份+duplicate 全链路）；交通/住宿**详情页**底部「接收提醒」开关。
- **🟢 文案哲学（Made with Love）**：相信用户、温和提醒、**不提后果不施压**（不说逾期/超时罚款）、有人情味；远档问规划、近档收拾、清晨倒计时、晚上打包。9 语言齐、中文全角。
- **门控重排**：地点变更只在「每日摘要」开、打包变更只在「打包提醒」开时才重排 → 默认用户零额外开销。埋点 `reminderMutedToggled`。
- **本会话另落地的小改动**（均已提交进 main）：首页卡片去打包进度条留件数 pill；打包页去重复提醒 pill；设置段「一般旅行提醒」→「出发提醒」；行程详情弹层 iOS 26 缩卡片修复（删 `.large` 单一 `.height`，`584a316`/根因实测）；地点编辑加「日期」改天（`#5`，`dc6e34e`，`moveItineraryStop`）。
- **待办（都另开会话）**：① **全 App 时区**未系统化，需单独 spec（见记忆 carry-timezone-handling-todo）；② **地点只留「到达时间」**去掉结束时间（已与用户定调，spec 待写）；③ push 由用户定。

## 上次改动摘要（法务页 + Roadmap 迁到自营域名规避 GFW · 2026-06-20 续）

> 接航班那条线，把另外两个「挂在 GitHub、国内被墙」的资源也迁到 `nevestudio.app`。本会话改 `Carry/Views/LegalViews.swift` / `Carry/Views/RoadmapView.swift` / `CLAUDE.md` / 新增 `scripts/config-proxy/{worker.js,README.md}` + 本 progress.md；并在 `carry-legal` 仓库加/删了 roadmap.json（见下）。**编译绿**。三个新域名均实测国内可达（用户真机验过航班；法务/roadmap 由 curl 验 200）。
- **🔴 同根问题**：法务页走 `murphy-lyu.github.io`（GitHub Pages）、Roadmap 走 `raw.githubusercontent.com`——两者在大陆都被 GFW 干扰，无 VPN 打不开/拉不到。法务页打不开是大陆上架的**合规 + 体验缺口**；Roadmap 拉不到 → 国内用户永远只看到内嵌默认（远程更新对国内失效）。
- **🟢 法务页 → `legal.nevestudio.app`**（Cloudflare Pages 接 `carry-legal` 仓库，自动部署）：`LegalViews.swift` base 从 `github.io/carry-legal/` 改为 `legal.nevestudio.app/`；中文页用干净地址 `/<slug>/zh`（Pages 把 `.html` 308 跳到去 `.html` 地址，直接指终点省一跳）。GitHub Pages 旧址保留、老版本不破。**待办（用户）**：App Store Connect 隐私政策 URL 换成 `https://legal.nevestudio.app/privacy/zh`。
- **🟢 Roadmap → `config.nevestudio.app`（Worker 代发，非 Pages）**：纠结过「roadmap 挂 legal 仓库」语义不对（用户洁癖，正确）→ 最终**真源 `roadmap.json` 留在 carry-ios 仓库不动**（单一真源、CLAUDE.md 铁律核心不变），新建 `carry-config` Worker（`scripts/config-proxy/`）回源 raw + 缓存 5 分钟 + 路径白名单（只放行 `/roadmap.json`，防开放代理），绑 `config.nevestudio.app`。`RoadmapView.swift` 拉取地址改 `config.nevestudio.app/roadmap.json`。曾短暂把 roadmap.json 推进 carry-legal、随即删除（commit `65d2766`→`a65c3ae`）。
- **域名分工定型**：`legal.*`=法务（Pages）、`config.*`=app 远程配置（Worker）、`flight.*`=航班代理（Worker）；各司其职、互不混。静态内容将来按「每 app 一文件夹」扩展，不搞子域名泛滥。
- **待办**：① App Store Connect 隐私 URL（用户）；② push（用户定，会一并推并行会话提交）；③ 真机再扫一眼法务页/roadmap 国内加载（低风险，curl 已绿）。

## 上次改动摘要（航班代理改用自定义域名规避 GFW + 工作室品牌 Neve 定名 · 2026-06-20 续）

> 本会话只动 `Carry/Models/FlightLookupService.swift` 一处（+ 本 progress.md），与并行会话不重叠。**编译绿**（主 app + Widget）。**待用户真机验收**（国内关 VPN 测航班搜索）。
- **🔴 根因：航班查询在中国大陆无 VPN 拿不到结果**——不是 API Free 档的问题。链路是 `App → Cloudflare Worker(carry-flight) → 上游 AeroDataBox(经 RapidAPI)`，App 只连 `carry-flight.murphy-latte.workers.dev`。`*.workers.dev` 是 GFW 干扰最稳定的一类域名（DNS 污染 + TLS SNI 阻断）→ 连不上 Worker（第二跳在墙外、与此无关）。实测两跳服务都在线，纯网络可达性问题。
- **🟢 解：给 Worker 绑自定义域名 `flight.nevestudio.app`**（甩掉 `workers.dev` 这层针对性封锁）→ App `proxyURLString` 从 `https://carry-flight.murphy-latte.workers.dev/flight` 改为 `https://flight.nevestudio.app/flight`。旧 workers.dev 路由仍在线、两条并存不停机。已验证新域名 SSL 签好、打到 Worker（无 token 返回 401）。
- **⚠️ 不保证彻底**：Cloudflare 普通免费边缘在国内仍可能被限速。验收若仍不通 → **Plan B：代理挪到香港/新加坡小服务器**（GFW 不主动阻断、无需 ICP）。决定性验证＝用户真机关 VPN 实测。
- **🟢 工作室品牌定名 Neve**（域名 `nevestudio.app`，Cloudflare Registrar 注册）：Carry 之后做一系列「Made with love / 慢生活」小 App 的总品牌；Neve = 意大利语「雪」= 冰 = 太太的名字（私心彩蛋）。口头叫「Neve」，`nevestudio.app` 当数字大本营；将来咖啡馆可另用干净的名字/域名。
- **影响上架**：中国大陆上架时，若航班搜索国内不可用，功能降级安全（有「手动输入」兜底 `flightSearchManualFallback`），非硬 blocker，但体验缺口待 Plan B 决定。

## 上次改动摘要（行程按天色板定稿：7 色全色环铺开 + 地图针白字易读性根因 · 2026-06-20 续）

> 色板定稿。本会话改 `AppearanceMode.swift` / `ItineraryMapView.swift` / `docs/{decisions,design-system,progress}.md` / `scripts/itinerary-day-palette-solve.py`，与并行会话在途改动（`ItineraryView`/`ItineraryReorderCollection`/`TripReminderConfig`/`NotificationManager`/`HomeView`/`Localizable.xcstrings`/`specs/itinerary-map-scroll.md`）**不重叠**，走隔离 index 提交（`design-system.md` 共享、只 patch 自己的 hunk）。**编译绿**；UI 验收交用户。
- **🟢 7 色定稿**（`AppearanceMode.swift`，`sortOrder % 7`）：`Day1 烟蓝(品牌) → Day2 万寿菊 → Day3 棕榈绿 → 雪青 → 覆盆子 → 青绿 → 赤陶`（蓝/橙/绿/紫/莓红/青/赭红）。**色相绕色环铺开**，每天一个不同色名。CIEDE2000 floor **14.7**，相邻最差 ΔE≈20。前四天按用户偏好钉死、后三天求解。
- **🟡 「暖色主导」版被否（迭代教训）**：曾做暖色版（珊瑚/海蓝绿/胭脂粉/浆果红），真机一看后几天「三个粉红一家」太像——暖色只占色相环一小段、ΔE 够但色相家族太挤。**决定「像不像」的是色相家族数、非 ΔE 数字**。改全色环铺开。Day1 用回品牌烟蓝、绿色对调到 Day3（对调后相邻最差 16→20）。
- **🔴 地图针白字易读性根因（`ItineraryMapView.swift`）**：浅色（青绿/赤陶/万寿菊等）低于 WCAG 3:1 → 针上白序号看不清、浅色路线发虚。**加深颜色必塌可分性**（降饱和 floor→8.7、整组压暗→6.6）；根因在「渲染假设日色够深托白字」。解：① 针序号改 `Color.legibleInk`（新增于 `AppearanceMode.swift`，按底色 WCAG 亮度自动取深/浅字）；② 浅色路线加暗 casing 衬底；③ 时间轴浅图标/色点偏柔但有色圈+位置+序号共同标识、不动。**禁止再用加深色板修对比度**。
- **待办**：① UI 验收（建 7+ 天行程看时间轴、**地图针序号在浅色针上是否清晰**、路线、明暗两态）；② push 由用户定（含前序 `420b6e1`/`fdc84f5`）。

## 上次改动摘要（住宿上脊导航锚点 + Trip Book 航班/住宿统计 + 底栏穿透根因 + 一串航班细节 · 2026-06-20 续）

> 本会话产出**已分批提交、未 push**。⚠️ **交接**：工作区另有并行 **notification-center（提醒静音）** 会话的在途改动**未提交**，与本会话部分文件（`ItineraryView`/`TransportDetailView`/`Localizable.xcstrings` + 通知专属 `NotificationManager`/`TripReminderConfig` 等）交织。本会话用「**隔离 index 逐 hunk**」只提了自己的部分（`4c28bce`），通知那块**原样留在工作区**——新会话先 `git status` 看清，提交时与那条线协调（理想各开 worktree）。
- **🟢 Trip Book 航班/住宿统计 + 卡片重排**（`44ff9ec`/`121b12b`）：飞行卡（累计里程+时长+机型小行）、常经停机场卡、住宿晚数卡；按「旅行回顾」叙事线排（总量→去哪→走多远→哪类旅行者→花费）。前提反转见 `trip-book.md`。
- **🔴 首页底栏三按钮穿透根因解**（`01ce2ee`，playbook §33b）：根因＝底栏 hosting 缺 `sizingOptions=.intrinsicContentSize`，空态启动（内容空、固有高 0）后导入数据 → 不放行区 `barView.bounds` 塌成 0 → 点按钮穿到背后卡片。只在「空态启动→导入」复现、重启即好、间歇。
- **🟢 住宿并入时间轴主脊（导航锚点）**（`4c28bce`，spec 增补 itinerary-transport-lodging.md）：住宿从顶部常驻条→脊上角色节点（入住/出发/返回/退房），共用 `TimelineRail` 脊连续；酒店↔地点距离 leg（`.lodgingLeg`）；点节点进详情（含导航）。行 ID 加 role / stop+departing 维度保 diffable 唯一。
- **🟢 机型剥离统一 / 跨天 +1 小上标 / 出发返回文案 / 住宿字号**（`4c28bce`）：机型品牌前缀全链路剥（编辑页+Trip Book，不只详情）；跨天 +N 改小上标（时间轴 + 详情卡两时钟成列 + 预留「+N gutter」）；住宿「出发/返回」前置角色词（防长名截断）+ 标题字号对齐地点（`.body`）。
- **🟢 一批航班细节**（WIP `7cede4a`）：总费用文案、确认号→预订代码(Booking code)、舱位选择器、机型字段可编辑、手动查不到自动预填航班号+航司、返程跨天到达可选次日、时间选择器加取消+草稿回退。
- **🟢 CLAUDE.md §0 诊断纪律**（`0debcc1`）：排查前先把「精确症状/复现/期望vs实际/可靠性」钉死、缺了问用户别猜（来源：底栏穿透绕多轮）。
- **待办**：① push（用户定）；② 并行 notification-center 由其会话收口；③ 中间日「出发/返回」文案真机扫一眼（低风险）。

## 上次改动摘要（行程详情/编辑大打磨 + 通用附件 + 电话 + 表单日期时间统一 · 2026-06-20）

> 一整轮「行程模块」打磨，**已全部提交并 push 到 main**（截至 `121b12b`/`584a316`）。后续仍有少量本会话后期小改 + 多个并行会话的在途改动**未提交**（见文末「⚠️ 交接」）。本会话用过模拟器实测（用户授权）。
- **🟢 活动详情卡（交通/地点/住宿）系统性重排**：字段排序框架（骨架→定位/凭据→描述规格→费用→备注→附件，写入 design-system）；**费用 / 备注 / 附件各自独立成卡（详情）/独立 Section（编辑），固定顺序 费用→备注→附件**，不与类型字段混排。
- **🟢 交通「航线 hero」独立成卡**：出发/到达竖直 rail 串成一段旅程；marker 随 mode（租车=钥匙、其余=↗↘）。**租车详情按端聚焦**（取车/还车各只显该端地址 + 导航卡 DirectionsModule；「取车/还车」移到浮窗副标题；聚焦端去「+N」）。
- **🟢 通用附件「文件/照片/链接/拍照」**：新 `ItineraryAttachment`（挂 地点/交通/住宿，cascade）；原文件存沙盒（`AttachmentStore`，25MB 上限、`reconcileAttachmentFiles` 兜底回收），照片存 640px 缩略图；链接走应用内 `SFSafariViewController`（不外跳）；拍照 `CameraPicker`（仅相机可用时显示，Info.plist+InfoPlist.xcstrings 加 `NSCameraUsageDescription`）。**新建实体也能加**（owner 为 nil 缓冲 `pending`，保存后 flush）。备份带字节、复制行程拷文件。**分享/导出审计通过**（渲染器不读附件）。隐私政策（carry-legal 中英）已补。组件：`AttachmentEditSection`(纯渲染+回调)/`.attachmentAddFlow`(呈现挂稳定父级 Form)/`AttachmentDetailCard`。详情尾标统一 `eye`+固定边框对齐。
- **🟢 电话字段（住宿/租车/地点）**：MapKit `MKMapItem.phoneNumber` 自动回填（Tripsy 同款，零接口）+ 可手填；详情 `CallableDetailRow` 点按 `tel:` 拨号。`ItineraryPlaceSearchSheet` 回调加 `phone`。
- **🟢 表单日期/时间交互统一**：抽 `ItineraryFormControls.swift`（`FormChip` + `ItineraryTimePickerSheet` + `itineraryTimeString`）；交通/地点/住宿三处时间一律 **chip+弹出**（去 toggle+内联跳变）；地点开始/结束改双时间 chip。日期/天控件因结构不同保留各自。**去掉日期行的日历图标**（表单同区其它行无图标，对齐一列）。
- **🟢 详情浮层钉头部**：`DetailSheetScaffold`——头部固定不随滚动、仅卡片区滚动；自定义 detent 封顶 0.94×（避免 iOS26 把弹层缩成内缩卡片）。
- **🟢 机型只显型号**：`aircraftModelDisplay` 剥厂商前缀（Airbus A330-200→A330-200），ATR 等不剥；非破坏（仅展示层）。编辑页航班号领衔、航司在下；机型挪入「更多」。
- **🟢 编辑地点类别只列地点类**（`StopCategory.placeSelectableCases`，剔除航班/火车/租车/邮轮）——之前只有「添加」过滤、「编辑」漏了，已对齐。地点编辑两条 footer 文案按用户要求删除（死键同删）。
- **🟢 删除按钮文案随类型**（删除租车/航班…）；租车「天数」派生显示（编辑+详情，同住宿晚数口径）。
- **✅ 排查「新增无时间地点排到顶部」**：模拟器实测**未复现**——新地点正确落当天底部（代码 sortOrder=max+1 + timeline 按 sortOrder，本就垫底）。临时调试日志已删。若复现需用户提供具体场景。

## ⚠️ 交接（2026-06-20，多并行会话共用同一 checkout，git 交织）
> 工作区当前混了**本会话后期小改**（ItineraryView / Transport*Detail / Transport*Edit / LodgingDetail / Localizable）+ **其它并行会话在途改动**（CostInputRow / FlightSearchSheet / DataBackupManager 的 `cabinClass` 舱位等级 / `cost.field.total` 改名 等），**均未提交**。`main` 领先 origin 1（`584a316` 详情卡 iOS26 内缩修复，已提交未推）。
> **新会话接手前必读**：先 `git status` 看清；提交务必走「隔离 index + 显式 `git add 我的文件`」，**禁止 `git add -A` / `git commit -a`**（会卷入并行会话改动）。详见 CLAUDE.md「并行会话纪律」。根治：各会话开独立 `git worktree`。

## 上次改动摘要（Trip Book 纳入航班/住宿统计 · spec 前提反转 · 2026-06-19 续 4）

> 用户问飞行时间/里程、座位、机型该不该进 Trip Book。评估后（详见 `decisions.md` / `trip-book.md`）：原 🔴「没数据」前提已被航班搜索 + 住宿两日期推翻 → 这几项转为可做。**编译绿（主 app + Widget）**；**未提交、未 push**；UI 验收交用户。
- **🟢 飞行卡**（`hasFlightStats` 门控）：累计里程（`CarryDistanceFormat` + `distance_unit` 偏好）+ 飞行时长（`Xh Ym`）两大数；底部**轻量机型小行**（「N 种机型 · 最常 X」，1 种时「机型 · X」）。
- **🟢 机场 Top 卡**（`airportTallies` 非空门控）：按 IATA 码经停次数降序前 6，码作烟蓝胶囊 chip + `N×`，镜像「最常去国家」卡。
- **🟢 住宿累计晚数卡**（`totalNights>0` 门控）：大数 + 「累计住宿晚数」。
- **座位偏好不做**：`seat` 自由文本无法可靠反推窗/过道/中间，做准须新增录入 → 违背克制。
- **落点**：`TripBookStats`（+`LabelTally`、航班/住宿聚合字段、`compute` 计数）、`TripBookStats+Trips`（从 `safeItineraryDays` 的 flight 段 + `safeLodgingStays` 映射）、`HomeView`（3 张卡 + helper、加 `distance_unit` @AppStorage）、`Localizable.xcstrings`（8 key × 9 语言，clean filter 验证无重排噪声、并行会话在途文案未丢）。**全部 hide-when-empty**，老用户无数据不显示空卡。

## ⚠️ 交接（2026-06-19 续：交通详情收尾 + 住宿两日期/图标，未提交、与并行会话交织）

> ⚠️ **续 4 追加**：上面 Trip Book 航班/住宿统计的改动也落在这批未提交集里，新增动了 `Carry/Models/TripBookStats.swift`、`TripBookStats+Trips.swift`、`Carry/Views/HomeView.swift`（均非并行会话共享文件，冲突风险低），并续改 `Localizable.xcstrings` / `specs/trip-book.md` / `docs/decisions.md`。提交时一并处理。

> 本会话尾段的改动**全部未提交**，且与并行「附件/地址」会话**共享同几个文件**（`LodgingEditView` / `TransportDetailView` / `ItineraryView` / `Localizable.xcstrings` / `Itinerary` / `TripStore` / `DataBackupManager` / `CarrySchema` 等），逐 hunk 交织。**未 push（main 领先 origin 27；token 已远程轮换、push 安全）**。新会话接手前先 `git status` 看清，提交时与并行会话协调、别互相覆盖。
> ✅ **build 已绿（2026-06-19 续 3）**：附件重构已接完——`AttachmentEditSection`/`attachmentAddFlow` 改为按 owner 分流（入库/缓冲），三编辑页调用点均补齐 `owner/existing/pending/tripId`。详见下方「续 3」。

- **本会话已提交**（按序）：`16135f0` 租车两事件渲染、`f76409d` 住宿过夜名提 secondary、`ed99513` 交通打磨大批、`12932a9` 文档、`9545ba6` 交通/租车标题字号对齐地点。
- **未提交（本会话尾段，落在上面交织文件里）**：
  1. **航班/火车详情标题拆两行**（班次号标题 + 承运方副标题）。
  2. **飞行时长放回明细列表**（试 hero 连接线失败，反转回 Tripsy 式；hero 只留两端点）。
  3. **住宿条床图标透明度统一**（full dayColor，过夜靠空心图标+regular+无前缀退后）。
  4. **住宿录入改「入住日 + 退房日」两日期**（弃「住几晚」Stepper，nights 派生、退房恒在行程内）+ 「住宿」组内**只读行**显「晚数 · N 晚」（原 footer 太弱、已移进 Section）。spec/decisions 已记。
- **待办**：① 真机/模拟器 UI 验收（用户来，本会话后期奉用户要求**未自驱模拟器**）；② 与并行会话协调后整批提交；③ push（token 已处理）。

## 上次改动摘要（附件补齐：详情拆卡 + 拍照 + 新建即加 + 电话 · 2026-06-19 续 3）

> 编译绿（iPhone 17 Pro / iOS 27）；未 push。
- **🟢 详情页费用/备注独立成卡**：交通/地点/住宿详情把费用、备注从信息卡拆出，与附件并列、固定顺序 **费用 → 备注 → 附件**（与编辑页一致；信息卡只留骨架+定位/凭据+规格）。design-system 已更新。
- **🟢 拍照加附件**：附件菜单加「拍照」（`CameraPicker` = UIImagePickerController `.camera`），仅相机可用时显示（模拟器隐藏）；Info.plist + InfoPlist.xcstrings 加 `NSCameraUsageDescription`（9 语言）。
- **🟢 新建实体也能加附件**：owner 为 nil（新建交通/住宿）时附件缓冲 `pending`（文件先落沙盒），保存拿到 id 后 flush 入库；取消由 `reconcileAttachmentFiles` 兜底清孤儿。`AttachmentEditSection`/`.attachmentAddFlow` 重构为按 owner 分流。地点恒既有实体、用 `.constant([])`。
- **🟢 电话字段（住宿/租车/地点）+ 应用内 Safari 链接**（本轮稍前）：MapKit `MKMapItem.phoneNumber` 自动回填、`CallableDetailRow` 点按拨号；链接用 `SFSafariViewController` 应用内打开。

## 上次改动摘要（活动详情卡重排 + 航线 hero + 租车字段/详情/天数 + 通用附件 · 2026-06-19 续 2）

> 本轮全程**编译绿**（iPhone 17 Pro / iOS 27 模拟器）；**未 push**。UI 验收交用户。涉及 spec：`itinerary-car-rental.md`、`itinerary-attachments.md`（新建，已 Shipped）；规范沉淀进 `docs/design-system.md`。

- **🟢 活动详情卡字段排序框架**：交通/地点/住宿三类详情卡按统一信息层级（骨架→定位/凭据→描述规格→费用→备注）重排，费用不再靠上。框架写入 design-system。
- **🟢 交通「航线 hero」独立成卡**：出发/到达单拎一卡、竖直 rail 串成「一段旅程」，机场码/时间放大；marker 随 mode（租车=钥匙、其余=↗↘）；rail 半段线修正不越界。
- **🟢 租车详情按端聚焦 + 导航**：取车/还车各只显该端地址（`.pickup`/`.dropoff`），「取车/还车」移到浮窗**副标题**，并接 `DirectionsModule`；聚焦端去掉「+N」。
- **🟢 租车新字段**：`vehicleModel`/`licensePlate`（详情/编辑，仅租车）、端点 `fromAddress`/`toAddress`（详情名称下显详细地址，捕获原被丢弃的搜索 placemark.title）、派生「天数」（编辑+详情，同住宿晚数口径）。全部轻量迁移 + 备份/复制/store/9 语言全链路同步。删除按钮文案随类型（删除租车/航班…）。
- **🟢 通用附件「文件/照片/链接」（新功能，全行程实体共用）**：新 `ItineraryAttachment` model（挂 地点/交通/住宿，cascade）；原文件存沙盒（`AttachmentStore`，25MB 上限、孤儿回收 `reconcileAttachmentFiles`），照片另存 640px 缩略图；链接纯 URL。复用 SwiftUI 原生 `photosPicker`/`fileImporter`/`quickLookPreview`（无 UIKit 包装）。详情查看（`AttachmentDetailCard`）、编辑管理（`AttachmentEditSection`，仅既有实体）。备份带字节（auto-backup 不带、export 内嵌 `attachmentFiles` 字典）、复制行程拷文件、`duplicateTrip` 同步。**分享/导出审计通过**：渲染器不读 `.attachments`，天然不外泄。隐私政策（carry-legal zh+en）已补「附件仅本地、不上传、不随分享」。埋点 `attachmentAdded/Opened/SaveFailed`。v1 取舍：未做拍照（仅相册/文件/链接）；附件仅在编辑既有实体时可加。
  - **附件添加流程修复**：`.sheet`/picker 原挂在 Form Section（列表行）上 → 行回收时被销毁（链接 sheet 一弹即消失）。重构为 `AttachmentEditSection`（纯渲染 + `request` 回调）+ `.attachmentAddFlow` 修饰器（呈现挂稳定父级 Form）；confirmationDialog → Menu；链接输入用独立 sheet 而非 alert+TextField（嵌套呈现失焦坑）。
- **🟢 编辑页「费用/备注/附件」各自独立 Section、固定顺序**（费用→备注→附件）：三类编辑页把这三项从「更多/详情」混排里拆出、收到表单底部固定次序，不与类型字段混在一起。详情页保持信息卡聚合（场景不同）。
- **🟢 链接在 Carry 内打开**：附件链接点按用 `SFSafariViewController`（应用内 Safari）打开、不跳出；仅 http/https，其它 scheme 交系统。
- **🟢 电话字段（住宿 / 租车 / 地点）**：MapKit 搜索结果的 `MKMapItem.phoneNumber` 自动回填（Tripsy 同款，零额外接口），可手填；详情卡 `CallableDetailRow` 点按直接 `tel:` 拨号。住宿电话紧随地址、租车在车牌后（仅租车）、地点在详情段。航班/火车不加（无可拨地点电话）。全链路（model/备份/复制/store/9 语言 `itinerary.transport.field.phone`）同步，轻量迁移。`ItineraryPlaceSearchSheet` 回调加 `phone` 参数，两调用方（住宿/交通）+ 地点搜索 `AddStopView` 均接上。

## 上次改动摘要（行程时间轴统一 + 租车两事件/详情 + 航班标题与航站楼 · 2026-06-19 续）

> 一大轮「行程交通」打磨,与并行航班/租车会话**共享多个文件、逐 hunk 交织**;按用户授权**整批合入一个 commit `ed99513`**(含并行会话的租车详情/字段/备份工作,整体编译绿)。**模拟器 iOS 26.5 实测**;**未 push**(main 领先 origin 25)。spec: `itinerary-car-rental.md`(含多条增补)。

- **🟢 租车 = 两个时间轴事件(取车/还车)**:租车段不再渲染成单条连接行(还车被「+N」角标藏在出发日),改为**取车日一条「取车 · 公司 / 取车地点 · 时间」、还车日一条「还车 …」**,镜像住宿入住/退房。零模型迁移(不碰 `Itinerary.swift` 的 `timeline`,在 `daySections` 把租车 timeline 项解释成取车行 + 还车日按时间注入还车行);行 ID `.carRental(segment:day:pickup:)` 带 day 维度避 diffable 重复崩溃坑。
- **🟢 时间轴主脊连续 + 时间右对齐统一**:抽共享 `TimelineRail`,地点/航班火车/租车三种行共用同款 rail 几何 → **竖脊连续穿过交通段**(原先断开),首/末项清半线、两端干净;距离 leg 仍只在地点↔地点。**点类事件(地点/住宿/取还车)时间右对齐**成一列;**航班/火车作为「边」保留内联 `A→B` route**(两端两时刻,刻意不同)。
- **🟢 航班标题翻转 + 航站楼**:标题 `航司·班次` → **`班次号 · 航司`**(航班号领衔、旅客主认它;航司降 **regular 字重 + secondary 浅色**,一行两级层次);时间轴/详情卡**两处同序**。副行 route 内联**航站楼**(复用 `terminalDisplay`,航班数字前加 T):`SHA T2 8:00 → PEK T2 10:15`,空则不显。
- **🟢 住宿条颜色一致**:中间过夜天酒店名 `.tertiary`→`.secondary`(深色下不再像渲染坏);入住/退房**时间**也归 `.secondary`(与其它时间字段同列同色),过夜「N晚」计数仍 `.tertiary` 退作背景。
- **🟢 租车详情/字段(并行会话,随本 commit 进)**:详情按端点聚焦(`.pickup`/`.dropoff` + 导航卡,航班/火车 `.full`);新增可选 `vehicleModel`/`licensePlate` + 端点 `fromAddress`/`toAddress`(轻量迁移、备份/复制/store/文案全链路同步);详情/列表对租车用「取车/还车」标签(非 Departure/Arrival)。
- **决策记录**(`decisions.md`):租车=离散事件 vs 住宿=跨度(刻意不同)、租车两事件渲染、标题班次号领衔等已记。**待办**:真机走查;整批 push 由用户定节奏。

## 上次改动摘要（航班搜索/交通表单：日期块视觉 + 全类型字段标签 + 时间轴去价格 · 2026-06-19 续）

> 接「添加航班搜索优先」之后的一串 UI 打磨（多轮真机/模拟器对照）。**编译绿、模拟器 iOS 26.5 实测**。**3 个文件未提交**：`FlightSearchSheet.swift` / `TransportEditView.swift` / `ItineraryView.swift`（均我的 hunk，与并行租车会话交织但本轮只动这几处）。前序航班功能已提交（`1dc5cca`/`ac84c54`/`b2fa04b`/`fbdf71c`/`3509a09`），**整体仍未 push**（本地 main 领先 origin 21）。

- **🟢 FlightSearchSheet 搜索框 + 日期块定稿**：① 航班号字体改 **SF `.title3`**（原圆体 semibold 违反「表单输入=SF」）；② 航班号**强制大写**（binding 兜底 `.uppercased()`，防小写输入法绕过）；③ placeholder 示例号 = **MU5127**（用户纪念号）；④ 底部「手动输入」footer 去 `.bar` 磨砂板 → 细分隔线 + 两段式居中（克制）；⑤ 日期列表：**日期色卡**（月缩写+日号，圆体）+ 星期，去 chevron（点选=提交非导航）；**纯黑白灰**（去强调蓝，建议当天=更亮一档灰底），「Other date…」同款 42×42 灰色卡 + 日历图标。
- **🟡 「Other date…」日历：用户取舍回系统 graphical**：自绘月历（确定性网格、零跳）做过、验证零跳，但用户**最终选回系统 `.datePickerStyle(.graphical)`**（更原生精致），接受其首次出现的 ~3px 落定微跳（`.frame(height:360)` 已压到最小；正常「点日期即关」看不到）。点日期即触发查询（无 Done）。
- **🟢 交通编辑表单：全类型字段常驻标签**（`TransportEditView`）：代码/航站楼·站台、座位、确认号改 `LabeledContent`（标签左·值右，同「机型」行）——根治「填了值后 placeholder 标签消失、剩裸值 `HGH`/`3`/`3B`/`ABC123` 看不懂」。承运方/班次号（身份头）、日期时间 chip（自解释+📅）、备注（自由文本）有意不标。覆盖航班/火车/租车/巴士/渡轮/其他。
- **🟢 行程时间轴去价格**（`ItineraryView`）：费用功能曾把价格显示进时间轴的**交通行 + 住宿入住行**（地点行没有 → 不一致）。按用户「时间轴只显何时/何地」改：交通行去价格（时间已在副行）、住宿入住行改显**入住时间**。价格仍在详情页 + Trip Book。
- **待办（交新会话）**：① 真机走完整验收（搜索→预填→保存、春秋手填、日期块、字段标签、时间轴）；② **push**（领先 origin 21 个提交，含并行会话）；③ 上架前切 API.market 商用档（仅改 Worker 变量）；④ 「日期真正可选」（脱离按天分组）单独立项。

## 上次改动摘要（设置：通知权限可达性 + 行程提醒一级行语义校正 · 2026-06-19）

> 修一个上架前的体验缺口：用户若忽略/拒绝首次通知授权，App 内再无处唤起授权或跳系统设置。**已提交 `9ec9921`、未 push**（编译绿）。`SettingsView.swift` 与「视觉打磨」会话共享，只动 `notificationStatusText` 一处自己的 hunk。

- **🟢 通知权限横幅（`NotificationSettingsView`）**：根因——「行程提醒」子页只有档位开关，授权被拒时它们形同虚设、且无任何出路（对照：日历早有「denied→去设置」，通知缺、是一致性缺口）。解：顶部加**状态感知横幅**——`.denied`→深链 `openNotificationSettingsURLString`（iOS 16+ 直达本 App 通知页）+ 下方档位**置灰禁用**；`.notDetermined`→应用内直接 `requestAuthorization`（补回首次漏掉）；`.authorized`→不显示。`scenePhase` 回前台自动刷新，从系统设置改完回来横幅即消。**不做误导性「权限假开关」**（系统权限无法在 App 内真正切换）。
- **🟢 一级行 On/Off 语义校正（`SettingsView`）**：原 `notificationStatusText` 只读系统授权态 → 用户把所有档位关掉、一级「行程提醒」仍显 On（误导）。解：授权正常时值改为**跟随档位**（≥1 档开=On、全关=Off）；denied=Off、notDetermined=未设置（权限问题仍在顶层可见）。与子页**共用** `ReminderPreferences.storageKey` 的 `@AppStorage`，改档位即时反映。
- **文案**：新增 `settings.notifications.permission.{denied,undetermined}.{title,subtitle,button}` 6 key × 9 语言；一级行复用现有 on/off/notSet。
- **待办**：真机验收——三态横幅（拒绝/未授权/已授权）+ 去系统设置往返横幅刷新 + 一级行随档位变化。

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

> 把「添加航班」从手动优先翻转为**检索优先 + 手动兜底**，把交通段编辑表单的日期/时间重做成 Tripsy 式融合 chip，外加一轮**安全收尾**（token 移出源码+轮换、Worker 限流）。**编译绿（主 app + Widget）+ 模拟器 iOS 26.5 实测通过 + Worker 线上验证通过**。**已提交、未 push**（`1dc5cca` 航班+chip+租车合并 / `ac84c54` token 移出源码 / `b2fa04b`·`fbdf71c` Worker 限流）。与并行租车会话共享 `TransportEditView.swift`，只动了我的 hunk，未碰其租车逻辑。

- **🟢 第1段 `FlightSearchSheet`（新）**：渐进式单框——输航班号 → 即时识别航司（新 `AirlineDatabase`，实测 MU→中国东方航空）→ 竖排日期列表（本行程的天 + 「选择其他日期」日历）→ **点日期即触发查询**（对齐 Flighty，不预填、不加按钮）→ 结果确认卡 → 点卡 push 进**预填**的 `TransportEditView`。底部常驻低权重「手动输入」兜底（春秋 9C 等查不到的航班）。
- **🟢 航司表**：`scripts/airlines/`（OpenFlights `airlines.dat` + Wikidata 多语言名，英文名也优先 Wikidata——9C 旧名 "China SSS" 已修为 "Spring Airlines/春秋航空"）→ `Carry/Resources/airlines.json`（986 航司，~225KB，已确认进 bundle）+ `AirlineDatabase`（actor）+ `FlightNumberParser`。
- **🟢 `TransportEditView` 改造**：① 加 `prefill`/`embedInOwnNavigationStack`/`onFinish`，被 `FlightSearchSheet` push 时不自带 NavigationStack、保存经 `onFinish` 关整张 sheet；② 移除原内嵌「✨自动填」块（前移到第1段）；③ **日期/时间融合 chip**（`📅 [日期 chip][时间 chip]`）取代「day Picker 行 + 时间开关行」——日期 chip 显示行程天（点选换天）、时间 chip 可选（点开滚轮 sheet、可清除）。
- **🔴 根因解·行高跳变**：原「时间开关一开，把比开关高的 compact DatePicker 塞进同一行 → 行被撑高」。根因＝控件硬塞进开关行；融合 chip 后无开关、选择器移弹出层、chip 普通行高 → 行高恒定（曾用的「隐形占位」是 workaround，已废弃）。地点搜索 + 时间选择合并为单一 `.sheet` 枚举（防多 sheet 互抑）。
- **🟢 工程**：`FlightLookupService` 上游 DTO 补 `nonisolated`，根治 Swift 6「main-actor 隔离 Decodable 不能在 nonisolated 解码」报错。「+」菜单航班入口改走 `FlightSearchSheet`。埋点 `flightSearchManualFallback`（即定义即接线）。文案 `flight.search.*` + `clear_time`（9 语言齐全），删死键 `itinerary.flight.lookup.*` / `itinerary.transport.field.day`。
- **🔐 安全收尾（token + 限流，线上已验）**：`appToken` 原硬编码在 `FlightLookupService.swift`（`carry-ios` 公开仓库会被密钥扫描）→ 改从 **gitignore 的 `Carry/Resources/Secrets.plist`** 读取（随 bundle 打包、缺失降级空、不进 git），并**轮换**（Worker `APP_TOKEN` secret 同步换新值，旧 token 作废；curl 实测新 token→200、旧 token→401）。Worker 加 **Rate Limiting 绑定**（`RATE_LIMITER`，按 IP 20/60s）。实测 Cloudflare 该限流 best-effort/近似、抓不住短爆发（50/50 全过）——成本真正兜底＝**APP_TOKEN 门槛 + 上游月额度上限 + 服务端缓存**；要硬 enforcement 留 Durable Object 后续。**未改写 git 历史**（旧 token 已作废，曝光无意义；改写共享 main 风险大）。
- **留作单独立项**：日期「真正可选」（脱离按天分组、需「未排期」区 + schema 迁移），与按天分组架构冲突且重叠并行租车工作，单独 spec 后再做。
- **待办**：① 真机走完整验收（搜索→预填→保存、春秋手填、融合 chip）；② **push**（本地 main 领先 origin 多个提交，含并行会话提交）；③ 上架前切 API.market 商用档（**仅改 Worker 变量、App 不动、不用重新过审**；RapidAPI 免费档非商用）。
- **✅ 已完成（原待办收口）**：提交；APP_TOKEN（Worker secret + App 两端齐）；隐私政策「航班号发第三方查询」（carry-legal `fc6451a`，中英齐）；token 移出源码+轮换；Worker 限流绑定。

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
