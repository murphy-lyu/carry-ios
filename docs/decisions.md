# 决策日志

## 2026-06-25 行程「地点排序」拖拽自滚：自定义受控滚动，不全自定义拖拽

### 背景
行程「地点排序」（及列表长按拖拽）用 UICollectionView 原生 `beginInteractiveMovementForItem`（跨 section=跨天拖拽靠它）。它自带的「拖到边缘自动滚动」每帧推进 20~40pt（≈1000+pt/s）、**无公开 API 关闭或调速** → 手指挪一点就狂滚冲过头，难精确落点。

### 决策（两层，均不重写拖拽）
1. **受控自滚替代原生自滚（snap-back，f36d514）**：拖拽期本类「拥有」contentOffset——自家 `CADisplayLink` 按「行/秒」（实测行高×常数封顶）推进权威值 `dragAnchorOffsetY`；`scrollViewDidScroll` 把任何**非本类**的位移（=原生自滚）即时回正到该值，原生那一跳从不被画出。净滚动只由本类受控推进。**验证**：模拟器日志显示拖拽全程 `applyMine=1`、无原生位移进来。
2. **自滚边界用可见视口+安全区，不用 `adjustedContentInset`（2b8d388）**：真根是 `adjustedContentInset.bottom` 含**末段吸顶预留的 281pt 巨大底部 inset**，把「底边」抬到屏幕中部、令自滚在中段误触发。改用 `safeAreaInsets`（~34pt）→ 只有贴真边缘才滚，列表中部是「安静落点区」。

### 否决「全自定义拖拽重写」
一度准备弃用 `beginInteractiveMovement`、自己渲染快照跟手+自己重排（开了 worktree）。**否决原因**：当初判断「原生自滚压不住」是基于一个**过期 DerivedData 旧包**（`find` 误抓）——挂日志后证明 snap-back 其实有效，原生自滚已被回正压住。全重写是不必要的复杂度与风险（跨天/落点/抬起观感都要重做），按「改动有效性审计」原则撤销，保留最小必要集合（两层小改）。

### 教训（已写入 progress.md）
- **模拟器自跑务必用确定的 `-derivedDataPath`**，别 `find ~/Library/.../DerivedData` 抓包——极易拿到旧构建，据此误判根因、险些做无谓重写。
- **拖拽自滚/落点的「边缘」永远以可见视口 + `safeAreaInsets` 为准**，绝不掺业务用途的 `contentInset`（吸顶/避让预留）——否则边界被悄悄抬进屏幕中部。

## 2026-06-24 下线「导出签证行程单」功能（删除而非隐藏）

当前「导出行程单」（双语签证 PDF）与产品预期不一致，决定**下线重做**。在「藏入口保代码」与「直接删除」之间选**直接删除**，理由：① 功能完全自包含（3 个独占文件 `ExportItinerarySheet` / `ItineraryDocumentText` / `ItineraryPDFRenderer`，~456 行），不沾备份/CostBearing/schema/duplicate/Widget 任何「加字段同步 N 处」红线；② 既定要**重新设计**、不会原样复用，留着只有维护负担没有复用收益——尤其行程数据模型在持续演进，PDF 渲染器会静默腐烂；③ git 历史完整留底，重做时 `git show <删除提交>:路径` 即可调出参考，比让死代码烂在工作区强。删除范围：3 文件 + `PackingListView` 入口（按钮+sheet+state）+ `CarryLogger` 两个 event（`itineraryExported`/`itineraryExportFailed`，含 errorEvents 成员）+ 6 个 `itinerary.export.*` 文案 key。spec `itinerary-export-document.md` 保留作重做参考。**找回锚点：删除提交见本日 git log「Remove the visa itinerary PDF export feature」。**

## 2026-06-24 Widget large 概览 + 距离连线 + Quick Actions 精修 + 空写竞态教训

### large Widget =「按天分组」概览，不抄 Tripsy 的扁平时间流（spec: widget-upcoming-large.md）
large 尺寸填「概览」生态位（小/中只给下一件事）。**核心决策**：Tripsy 的「Next Activities」按**时间**扁平排（每项都有时刻），但 Carry 用户**常不填时间**——纯时间流在 Carry 真实数据下会空、别扭。故 Carry large 按**天分组 + 当天顺序**（今天/明天/周N），有时刻才显时刻。这适配 Carry 常态、是差异化而非模仿。数据走**附加式** `WidgetAgendaItem`（events/plan/stays 不动 → 小/中零回归）。QA：systemLarge 固定高不滚动、条目多两行，渲染行封顶 7 + 截断显「+N 更多」（防静默裁剪）。

### 时间轴距离连线：判据是「有详细地址 = 真实落点」（spec: itinerary-distance-legs.md）
任意相邻两个真实地点间显示距离；纯枢纽（机场航站楼）不显——因为有用的距离是「下机拿到车的地方→下一站」，非航站楼。判据用交通端 `address` 非空（机场地址为空、自然排除，**无需对航班特判**）；地点/住宿仍只看坐标（不加地址要求，否则地图点选/照片地点丢现有连线=回归）。纯叠加、不碰 rail 拓扑。

### Quick Actions：行程名 / Trip Book / 顺序（spec: quick-actions-phase-aware.md）
- 副标题用**行程名**（对齐 Widget displayTitle，行程名最 identifying），不用目的地城市。
- 「我的足迹」长按 → 重指向 **My Trip Book**（行程册 sheet）并改名/换图标——Trip Book 是更全的「回顾」首选页；**世界地图与 Trip Book 是两个东西**（地图=点亮国家的 GlobeView、Trip Book=统计+国家旗帜+花费，不含那张地图），Siri 的「Footprint」仍指地图、各司其职。
- 顺序 = **〔当前/最近行程〕· New Trip · My Trip Book**：长按首项最易点，旅行中「打开我的行程」最高频置顶，回顾垫底。

### 🔴 教训：Widget snapshot / Quick Actions / 交通 LA —「读全量数据的启动副作用」绝不在 `App.onAppear` 写
真机暴露：`writeWidgetSnapshot` 在 onAppear 调，但 `TripStore` 异步加载、此刻 `trips` 常为空 → **写空 snapshot 覆盖好的那份**，Widget 空白（读 App Group plist 实测 `trips=0` 坐实）。这与之前 Quick Actions/交通 LA 踩的是**同一个竞态**（CLAUDE.md「读全量数据再做副作用」铁律），widget snapshot 当时漏修。**统一根因解**：这类副作用一律挂 `TripStore.init` 的 Task（`fetchTrips` 之后、trips 已加载）+ 回前台/进后台钩子，**绝不挂 onAppear**。排查方法（记住）：直接读模拟器 `~/.../AppGroup/<uuid>/Library/Preferences/group.com.murphy.carry.plist` 的 `carry_widget_trips`，拿 snapshot 实际内容、不靠猜。

## 2026-06-23 不做「TripIt 账号导入器」（至少现阶段）

**背景**：Tripsy 有「TripIt Importer」——OAuth 连 TripIt 账号 → 拉全部行程/活动转入。比我们已做的 Tripsy 导入器（一次性读导出 SQLite 文件、无账号无 OAuth）重一个量级。用户问要不要跟。

**决策：不做。** 理由：① **受众错配**——TripIt 用户主要欧美商旅，Carry 首发中国大陆 App Store，早期用户有 TripIt 账号者极少，迁移价值薄。② **上架硬伤**——TripIt 是美国服务，API/OAuth 登录页在大陆大概率受 GFW 影响（Tripsy 自己都提示「登录页空白请关广告拦截」），且「连第三方账号拉数据」= 跨境收集账号数据，又一轮隐私/合规负担。③ **工程重、维护长尾**——OAuth 注册 + 授权流 + token 管理 + schema 映射 + 跟 API 变更，为窄受众不划算。④ **迁移路径已有**——备份/还原、Tripsy 导入器、同行者行程文件导入，均不绑第三方账号。⑤ 账号级第三方集成是「大而全」动作，与克制定位相反。

**留口**：等 Carry 真走向国际/商旅市场、有实际需求信号再重估；**且届时先评估「更通用的导入」**（`.ics` / 转发确认邮件 / 标准行程格式）能否覆盖更多人——真正价值是「把现有行程导进来」，专做单家 TripIt OAuth 是最窄解法。

## 2026-06-23 不做「Shortcuts 画廊」（Tripsy 式预制快捷指令陈列页）

**背景**：Tripsy 在设置一级菜单加了「Shortcuts」页，陈列一组预制 Apple Shortcuts（General：存 URL / 到地点·两地·酒店的路线 / 某天加照片 / 存位置；ChatGPT：从 URL·文本提取地点 / 旅行建议 / 批量搜存 / Trip Digest / 收据记账 / 问行程任何事 / 找季节）。用户问要不要跟。

**决策：不做。** 理由：① 这是 Tripsy「大而全规划器」定位的长尾功能，与 Carry 克制、聚焦气质相反；维护成本高（每个 shortcut 需逐个编写/测试/9 语言本地化/跨 iOS 维护 + 托管安装），易沦为设置里没人用的入口。② **ChatGPT 区尤其明确不做**——把 OpenAI 品牌区塞进「Made with love / 慢生活」App 是很重的品牌 + 依赖决策，「问我的行程任何事」本质就是「打开 App 看」，非 Carry。③ 系统入口的主场景已由 **Widget（瞄一眼）+ Quick Actions（跳一下）** 覆盖，画廊是边际收益递减。

**留口（将来若做，落点不是画廊而是 Intent）**：补 1–2 个**参数化 App Intent**（首推「到酒店 / 下一站的路线」——旅行中高频、on-brand、基于已有住宿/地点坐标、不碰 AI），它本身就让 Siri/Shortcuts 变有用；画廊页留到这些落地且确实被用之后，再作为「可发现性」的可选包装，而非先搭空架子。区分清楚：**真正的能力在 App Intent 的丰富度，不在那个陈列页**。

## 2026-06-23 Widget 表达行程规划：相位自适应桌面组件 + 出行日 Live Activity（spec: widget-trip-companion.md / widget-transit-live-activity.md）

### 评估框架：Widget 提炼「此刻的下一步」，不展示「整个计划」
背景：Widget（桌面组件 + Live Activity）此前只表达「打包」（出发前几天的事），而更核心的行程规划从未上 Widget。
决策：用三判据筛 Widget 价值——**可瞄（一眼看完）+ 当下相关（此刻有意义且随时间变）+ 省一次打开（看完不必进 App）**，Live Activity 再叠「有明确进行中+会结束的事件」。结论：行程规划真正配上 Widget 的不是「展示整张时间轴」，而是「替用户从计划里挑出当下唯一要紧的那条」——契合 Carry 克制气质。**明确排除**整条每日时间轴 / 地图 / 花费 / 酒店地址·确认号 Widget（过不了三判据，纯为做而做）。筛出两个真场景：旅行中「今日陪伴」、出行日「下一程」。

### A. 旅行伴侣桌面组件：随旅行相位自适应（出发前 / 旅行中），且 Widget 自给自足
- **相位模型**：出发前=倒计时+打包（现状不动）；旅行中=`Day N/M` + 下一件事倒计时 + 今晚住哪/退房。已结束自然落出（选片只取 `returnDate ≥ today`）。**仅有日期行程进旅行中相位**（无日期行程无「今天第几天」概念）。
- **关键决策：Widget 不依赖「用户每天打开 App」**。旅行中用户可能整天不开 App，但 Widget 必须仍显示正确的「今天」。故 snapshot 带**整段行程事件**（每个事件预先按各活动时区算好**绝对 Date**），Widget 在渲染时按 `Date()` 自行推导「今天 Day 几、下一件事」，并用 timeline entries（每事件 + 每午夜）跨天推进。绝不「只写今天事件、靠 App 被打开刷新」（脆弱、会显示昨天）。
- 刷新走既有 `didEnterBackground` 生命周期漏斗（编行程→离开 App→看 Widget 即覆盖），**不在十几处 mutation 散加调用 + reloadAllTimelines**（更克制）。snapshot 新字段全可选 → 旧版 JSON 解码退化为出发前相位、不崩（向后兼容铁律）。

### B. 出行日「下一程」Live Activity：A+B 起停、schedule-based、实时就绪
- **起停 = A+B**（产品决策，用户拍板）：A 自动起（冷启动 + 回前台扫所有行程，为 [出发前 24h, 到达+1h] 内最临近一程起 LA）；B 显式（交通详情页「在锁屏追踪此程」）。理由：A 覆盖「出行日体感最佳」主场景，B 给用户掌控感。
- **主开关默认开**（与打包 LA 默认关相反）：出行日是 LA 最高价值场景，默认关=「功能存在但没人看见」（类比之前翻译占位的教训）。代价是默认会自动占用锁屏——给了全局 opt-out（设置页主开关）+ 自动起避开「用户显式停过的段」。
- **本轮只做按时刻表倒计时，不接实时航班动态**（延误/登机口=Roadmap 独立项）。`TransportActivityAttributes` 预留 `liveStatus/gate/actualDepartureDate`，将来接 API 只填充+`update`、不改结构。**文案刻意不暗示在追踪实时航班**（只显「计划 09:00 起飞 · 倒计时」），避免用户误以为延误会自动反映。
- **显式「停」必须被尊重**（QA 抓出的根因）：用户停掉后 A 不得自动重起 → 记「用户已停段」集合（`liveActivityTransitDismissed`），A 跳过、再次显式起即解除、按现存段剪枝防累积。
- 倒计时用系统原生 `Text(timerInterval:)`（自走、无需频繁 update、本地 `pushType:nil`）；相位（起飞前/途中/已抵达）渲染时按 `Date()` 判定。

### 工程结构决策
- **两类 LA 独立**：打包（`PackingActivityAttributes`）与交通（`TransportActivityAttributes`）不同类型、ActivityKit 上可并存、相位接力（打包出发前 / 交通出行日）。`endAll()` 拆为「`endAllPacking()`（关打包开关用）+ `endTransit()`」——**关一个开关绝不误杀另一类 LA**（QA 抓出的真 bug）。
- **i18n 陷阱（写入 CLAUDE.md 已知错误模式）**：`Text("\(a) → \(b)")` 这类**插值字面量**被 SwiftUI 当 `LocalizedStringKey`，Xcode 构建自动抽成本地化键（`%@ → %@`），污染 catalog。纯数据/分隔符一律 `Text(verbatim:)`。

## 2026-06-23 本地化系统性缺陷 post-mortem + 复数变体规范 + 审计脚本

### 现象
一次全目录审计发现 **257 个 key、约 2000+ 条** 本地化缺陷长期潜伏在线：① 绝大多数字符串只翻了 en/中文，其余 6 语言（de/es/fr/ja/ko/pt-BR）以**英文原文 + `state: needs_review`** 躺着——整个物品库 171 项、大量 UI 在德/法/日/韩/葡设备上显示英文；② 全 App 计数文案一律用扁平 `%lld`+名词、从不用复数变体，`count==1` 显 `1 trips`/`1 días`（罗曼语连形容词都错格）。

### 根因（为什么积累到这个量级还没被发现）
1. **Xcode 行为**：新增一条英文 string 时自动把英文值复制进所有语言并标 `needs_review`。界面里「每种语言都有值」→ 造成「已翻译」的假象，实则是英文占位；不手动翻就一直是它。
2. **测试盲区**：日常只在 en/中文设备上验收，其余 6 语言的英文占位、漏译、半角标点**完全不可见**。
3. **规范不可执行**：旧规范只有「同步补全所有语言」一句话，**没有任何机器验证**，全靠人记得——批量加物品库/UI 时只填 en+中文便过关，无人复核。
4. **复数认知缺口**：从没把「计数文案需复数变体」写进规范；且即便意识到，第一轮也只按「英文名词复数」判断，**漏了罗曼语形容词/分词一致**（es `registrado/registrados`）。

### 决策
1. **「翻译完成」有了硬定义**（写入 CLAUDE.md）：9 语言全在 + 每种 `state==translated` + 非英文值不是英文照抄（品牌/格式键除外）。`needs_review` ≡ 未翻译。
2. **计数文案必须用 xcstrings substitution variations**（写入 CLAUDE.md），调用点用 `String.localizedStringWithFormat` / `String(format:locale:)`；禁止扁平 `%lld`+名词、禁止手动 `.one` 双键。列了「恒≥2/序数/年份/缩写单位/独立标签统计块」等合法扁平例外。
3. **可执行的强制手段** `scripts/i18n-audit.py`：检出 needs_review/缺语言/CJK 残留英文/中文半角/复数候选；改 xcstrings 后必跑，[E] errors=0 才算交付。把「靠人记得」换成「机器把关」——这是本次最重要的产出（规范无验证手段=迟早重蹈）。
4. 物品库/场景标签/UI/惊喜文案的 6 语言 + zh 缺口全部补齐（含 `icon.*.name` 4 项 zh 漏译），两个目录审计 0 error / 0 warning。

### 推广教训
任何「必须同步多份」的约定（多语言、内嵌默认+远程配置、埋点闭环、备份字段四处同步…），**只要没有机器可跑的校验，就等于没有约束**——人一定会在批量操作时漏。优先给这类约定配一个 audit 脚本，而不是再加一条「务必记得」。

## 2026-06-21 深夜 抹掉所有数据 + 数据二级页 · 权限&法务审计 · Roadmap 重梳

### 抹掉所有数据：本地一键重置，不做「删除账户」（spec: erase-all-data.md）
原因：Carry 本地优先、无账号、零服务器存储——这本身满足 GDPR/PIPL 实质（靠「不收集」而非「收集后给你删」）；Apple 5.1.1(v) 删号只约束「支持注册」的 App，不触发。做 Flighty 式「删除账户」会误导（暗示我们存了你的数据）。
决策：① `TripStore.eraseAllData()` = 等同删 App 重装的内容部分，**覆盖全部副作用存储**（通知/Live Activity/日历/背景图·附件沙盒/SwiftData/备份文件/widget），漏一处即留孤儿；**不重置 App 偏好**（外观/单位/图标/通知默认时间——属配置非用户数据）。② 备份文件最后清（`save→fetchTrips` 会写空备份，clearBackup 放最后连空的也删）。
**撤销窗口（防后悔缓冲）**：确认后**不立即删**，延迟 `eraseUndoWindow`（默认 9s，VoiceOver 下 20s=WCAG Timing Adjustable，开始时快照不跳变）→ 底部吐司带**倒计时环**（`TimelineView(.animation)` 帧驱动按真实流逝时间算进度，**不靠 withAnimation**——刚插入视图的 withAnimation 会瞬跳/不触发，踩过）+ 递减秒数（不显 0，归零=删除=退场）+「撤销」（品牌强调色逃生口）。**离开页面 / 进后台即中止**（`onDisappear` + `scenePhase==.background`）：撤销逃生口绑在页面，若任由全局 Task 跑完=「撤销没了、删除照常」两头落空 → 一律朝「不删」方向。窗口期 `.disabled(eraseUndoVisible)` 锁备份卡 + 抹除卡，杜绝「导入后又被抹除」冲突 + 双吐司叠压。
吐司视觉（撤销环）：3pt 环描边、中性描边不勾红边（红圈像「输入框报错」廉价）、抹除卡用 `Color(.systemRed)` 低透明度淡红底（红收进有边界容器、说明文字用灰不施压）。用标准 `.alert`（始终带 Cancel）非 `.confirmationDialog`（regular 宽度渲染成 popover、取消被隐成点外部）。

### 数据相关功能收进二级页「数据与备份」
原因：导出/导入/本地备份/抹除低频，「抹掉所有数据」尤其不该裸露在一级菜单。
决策：一级「管理」分区单行入口「数据与备份」→ push 二级 `dataManagementPage`（复用 `SettingsView` 实例方法返回的 destination，直接复用根的 state/helper，**无需抽独立 struct/迁移状态**；fileImporter + toast 须挂在该二级页、不能留根页被 push 出的页盖住）。「备份」分组 + 抹除独立成卡 + 红字脚注（学 Flighty「点击前告知后果」，但红集中动作区、说明留灰）。

### 权限 & 法务全面审计（纯合规）
- **隐私政策补「日历」披露**（原完全没提，唯一硬伤）：写入行程/提醒 + 「日历叠加」读取所选日历，均设备本地零传输。PIPL 第14条修「零传输」自相矛盾——据实披露航班查询 + 境外地点检索（跨境）发送的**不关联身份**查询参数。
- **用户协议重定位**：从「旅行打包清单应用」→「旅行助手应用（行程规划 + 打包）」，并修失真的「不依赖网络连接」（航班/检索/天气/地图为可选联网）。
- **境外检索服务商列举式披露**「Mapbox 或 Geoapify」（非泛指、非单具名）：云控 `SEARCH_PROVIDER` 会切换，列两个候选既不漂移又如实点名接收方；infrastructure.md 加「换服务商须同步隐私政策名单」提示。
- 定位 usage 从 pbxproj build setting **迁入 Info.plist** 单点维护；中文 usage 文案统一第二人称「你」；日历 usage 补「读取叠加」。**相册无需授权**（纯 PHPicker、不碰 PHAsset）——最佳实践非缺失。**开源致谢页不需要**（SPM 依赖=0、纯第一方+Apple 框架）。WeatherKit 归属已在天气视图按 Apple 要求做了。

### Roadmap：已上线按卖点价值排序 + 标题大白话 + iCloud 留已上线
- 「行程规划」从即将推出→已上线，**拆成 9 个亮点**；已上线 30 条**按卖点价值排序**（差异化新身份→打包智能→iOS 系统级→目的地实用→同步分享→打磨），非时间序——这是 marketing showcase。
- **标题全部改大白话**（用户视角「这是干啥」，非 dev feature-name；3 语言地道）；状态只靠圆点不显文字。
- **iCloud 同步留在「已上线」**（产品决定，避免上线时再改 roadmap）——但代码未真接 CloudKit，**上线前必须补**。
- 真源 `roadmap.json` + 内嵌默认必须同序同字段；改完用 GitHub API 验 main（避开 raw/config 5min 缓存）；线上生效需 push（Worker 回源 main）。

## 2026-06-21 海外检索多源加固 + 时区归一（本会话 review + 加固；详见 docs/infrastructure.md）

### 海外检索多源抽象 + Geoapify 备份源 + `SEARCH_PROVIDER` 云控自动降级
原因：海外 POI 检索单点依赖 Mapbox（`carry-places` Worker），Mapbox 故障/超额 = 功能全挂、且要发版才能换源。Worker 是咽喉，应能零发版换源救老用户。
实现：Worker 加 provider 抽象——`SEARCH_PROVIDER = mapbox | geoapify | auto`（默认 `auto`：Mapbox 主，**仅主源硬失败**（异常/非 200；空结果不算失败）才降级 Geoapify）。suggest 结果 id 带 `mb:`/`ga:` 前缀，`/retrieve` 据此路由回来源；Geoapify autocomplete 单次即带坐标，把 retrieve 所需数据塞进 id（base64url）→ **离线解析、零二次请求**。降级结果**不缓存**（避免主源恢复后仍吐 10 分钟备源）。App 侧零改动。
放弃：双源并发取并集（成本翻倍、排序难合）；备源做二次 place-details 请求（多耗额度、依赖其可用，不如把数据编进 id）。

### 合规红线（境内一律走高德）改用「坐标 IANA 时区」判定，不靠 country code / bbox
原因：① `ga:` id 客户端可控，伪造 `cc=jp` + 北京坐标可绕过「按 country code 挡 CN」；② 粗 bbox 兜底会误杀首尔/台北/河内（都在矩形内、是核心目的地）。
实现：`complianceCheck` = country code 命中 CN/HK/MO 挡 + **坐标 tz-lookup 落在 `Asia/Shanghai`/`Urumqi`/`Hong_Kong`/`Macau` 也挡**（坐标无法伪造其所在时区）。精准——首尔→Asia/Seoul 放行、北京伪造 jp→Asia/Shanghai 挡。线上验证：构造恶意 id → `domestic_excluded`。
放弃：信任客户端 storefront 反查 `request.cf.country`（旅行用户常人在境外但 storefront=CHN，会误杀）→ storefront 仅成本开关、非合规边界；合规由**无条件** CN 过滤保证。

### 中国大陆时区一律归一到北京时间（`Asia/Shanghai`）
原因：中国全国统一民用北京时间（GMT+8），新疆/西藏地理上属 UTC+6、MapKit/坐标查会给 `Asia/Urumqi`/`Kashgar` 等，导致纯国内行程（如 重庆→伊宁）被误判「跨时区」、每个 Day 头显无意义 GMT+8 标。
实现：`TimeZoneCanonicalizer.canonical()` 把大陆境内别名（`Asia/Urumqi`/`Kashgar`/`Harbin`/`Chongqing`/`Chungking`）→ `Asia/Shanghai`，在**两个数据写入口**应用：MapKit 地点解析（`AddStopView`）、备份导入（`DataBackupManager`）。港澳（独立法域）与境外不动；机场库本就全 `Asia/Shanghai`；手动选时区尊重用户。
放弃：在每个读取访问器都归一（写入口归一即可保证存量+新数据一致、少改面）。

### 其它本会话审查修复
- **Mapbox session token retrieve 后轮换**：Search Box 按 session 计费（N×suggest + 1×retrieve = 1 次），不轮换则后续 suggest 被逐条计费（隐性漏钱）。
- **详情卡 GMT 偏移按事件日期算**（非「今天」）：跨夏令时才对（夏天规划冬天伦敦航班应 GMT+0）。时区选择器仍按「当前」（通用选择器、不绑事件）。
- **多时区 Day 标种子取「最早出现的所在地时区」**（≈出发地），非主时区（最频繁≈目的地）：首站前的空白天显出发地。
- 海外检索其它：结果乱序覆盖防护（写回前校验 query）、解析失败退回无坐标停靠点（原死点击）、sheet 关闭取消在途请求；Worker 常量时间 token 比较、query 长度上限、disabled 按 path 返回正确形状、纯 geoapify 模式不强求 MAPBOX_TOKEN。

## 2026-06-21 Trip Book 花费体系细化 + 列表卡统一规则 + 浅色卡 elevation（spec: trip-book.md / itinerary-trip-spend.md）
- **花费分类「前提反转」二次**：trip-book.md 原定「Trip Book 不做餐饮/购物分类、只按实体类型聚合」，依据是「需新增让用户填消费类别的录入」。前提已不成立——单行程花费页落地后 `SpendCategory.from(stopCategory:)` 把用户加地点时本来就选的 `StopCategory` **零新增录入**地映射成 7 类。与航班里程/住宿晚数/总花费三次反转**同一逻辑链**（前提变了→决策反转）。故 Trip Book 花费卡升级为 7 类（地点拆 餐饮/景点/活动/购物/其他）。跨行程 `TripSpendStats` 与单行程 `TripSpendDetail` **共用 `SpendCategory`**，口径不漂移。
- **Trip Book 守单一烟蓝、不抄单行程页多彩**：花费卡比例带/图例、下钻明细行图标一律单烟蓝（`CarryAccent`，按额降序走 rank 透明度）。单行程花费页用多彩是「操作型详情」，Trip Book 是「克制回顾」——同一套 `SpendCategory` 两种呈现，刻意区分。
- **交通图标错 = 按方式拆，不是换图标**：把多种交通方式塌缩成一个「交通」行，一行只能挂一个图标（永远错，租车/火车都显飞机）。根因解 = 模型加 `transportByMode`（交通按 `TransportMode` 再拆），下钻每方式一行、各取各图标；与 `byCategory[.transport]` 同源、各方式和 = Trip total。卡片仍按类目合一（altitude 区分：卡=类目级、下钻=方式级）。
- **撤「最长一趟/最频繁年份」**：这两个 superlative **无父卡可挂**（Trip Book 无「行程清单」卡、无「按年」卡），唯一落点是已拥挤的概览 hero、用户否决。对比「最远一程（挂飞行卡）/最高一趟（挂花费卡）」能成立=各有父卡延伸。强行塞 hero 或单开卡（两条一行字撑不起卡）都更碎 → **根因撤除**（删 UI + 模型字段/计算 + 文案，不留死代码）。
- **花费「查看全部」= 时间轴流水账**：把「按趟堆叠」改「按时间倒序」。用户给的字面「年→月→日→行程」四级标题**压成三级**：年=分段标题 + 每趟左侧日期标记（月/日合一）+ 趟内明细。理由：每趟仅一个日期，拆「月」「日」两级 = 一堆只含 1 子项的空壳标题，碎、违克制。日期**不占左列**（改卡片上方一行）→ 卡片撑满整宽、消除右偏。无日期行程归底部「未排期」组（不硬塞某年）。年标题带**年度小计**（该年各趟 total 之和）。
- **浅色卡片用 elevation、不是提亮填充**：`CarrySurfaceCardBackground` 暗色靠「卡填充比近黑背景亮」分界；浅色背景已近白、卡片**无法更亮**，故改 iOS 标准 elevation —— 纯白不透明填充 + 柔和投影 + 0.5px 描边。暗色保留填充对比、不投影。
- **列表卡统一规则「预览 N + View all」**：① 自然有界的列表（大洲，地球只 7 洲）→ 全展示、永不触发（规则套上去自然=全展示，不是特例）；② 无界列表（国家/机场）→ 预览 10 + View all 全列表 sheet。替掉机场旧「+N 个」**静默兜底**（违「无静默截断」诚实原则）。affordance 走 Apple「See All → 目标页用内容名」惯例：**按钮一律泛化「View all」、sheet 标题用各自卡片名**（花费 sheet「View all expenses」→「Total spend」），不自我重复。

## 2026-06-21 晚 通知调度架构：全局预算 + 退房模型切换（spec: notification-budget.md）

### 退房提醒：从「提前量」改为「退房当天清晨固定时刻」（C 类行程日锚）
原因：退房本质是「当天 deadline 前撤离」、人已在房间，**不是**「提前赶去」的交通型事件——把赶飞机的提前量倒计时套到退房上，模型就错配（怎么调都别扭）。且大家多准点/延迟退房，1h 弹「12 点退房」时人早醒了在收拾，提醒冗余；真正有价值的是**当天清晨**「今天要退房、12 点前走」，给从容收拾/结账的 runway。故归入晨间唤醒锚（同出发提醒/每日摘要），默认 09:00。
实现：删提前量 key `lodging_checkout_lead_min`、新 `lodging_checkout_min`（默认 540）。**早退房 clamp**：`fireMins = checkOutMinutes>=0 ? min(morning, checkOutMinutes) : morning`，退房时刻早于清晨锚则落在退房时刻本身，杜绝「已退房才提醒」。文案 T1+C：标题 `退房 · 酒店名`，正文带退房时刻（`clockLabel` 按设备 12/24h 本地化）、没填回落无时刻版。还车时刻一并从硬编码 `%02d:%02d` 统一到 `clockLabel`。
放弃：仅调大提前量（治标不治本，模型仍错配）；按类配额公平性（近端优先已由时间维度天然给出，加配额增复杂度无明确收益）。

### 通知调度收口为「全局预算」单一入口，规避 iOS 64 上限 + 重排竞态
原因①（竞态，真 bug）：原 `scheduleReminders` 先 `cancelReminders`（异步 getPending 回调里 removePending 旧 id）再同步 add，id 确定性、新旧相同 → 那条 removePending 提交晚于 add 且删的正是刚 add 的同 id → **重排把刚排好的通知删掉**（首次排 pending 空不触发，故漏测）。原因②（64 上限）：iOS 每 App 挂起本地通知上限 64、超出系统静默丢最远的；原各行程独立调度无全局视野，多个密集行程叠加即破 64、远端静默排不上、且不自动补回。
实现：唯一入口 `NotificationManager.reschedule(trips:)` 跨**所有行程**构建值类型 `Candidate`（主线程读 @Model，回调只碰值类型避免 off-main）→ `commit` 在单个 getPending 回调里 `budget=64−foreign−safetyMargin(4)`、按 fireDate 升序取前 budget（近端优先）。**竞态根除**：删除集=「`carry.trip.` 前缀匹配 − 本次选中集」，与新增集**数学上不相交** → 无论回调早晚都不误删。**滚动补位**：冷启动 + 回前台重排，远端随临近 + 用户开 App 进入预算窗口。TripStore 18 处单行程调度收口为全局 `refreshNotifications()`。
**冷启动重排必须在 `trips` 加载后**（踩坑教训）：`TripStore.init` 的 `fetchTrips()` 在 `Task { @MainActor }` 里**异步**执行；若把 refresh 放 `App.onAppear`，onAppear 跑时 trips 仍空 → 候选空 → commit 把已排通知全当陈旧删（每次冷启动清空）。**正解放进 init 的 Task 内、`fetchTrips()` 之后**；回前台走 `willEnterForeground`（此时 trips 早已加载）。推广：任何「读全量数据再据此做副作用」的启动逻辑，必须挂在数据加载完成点之后，不能挂在与异步加载无序的生命周期钩子（onAppear）上。
放弃：防抖（常见行程量开销可忽略，打包/每日重排默认门控关）；把 refresh 塞进 `fetchTrips()`（被调 14 次、多为 per-mutation，会重复触发）。残余边界：>budget 条全落在用户长期不开 App 的近期窗口仍只触发最近 budget 条——64 上限的物理边界，文档登记。

## 2026-06-21 通知中心整体改造（spec: notification-center.md）
- **Settings 为唯一真相源，删 per-trip 提醒编辑**：原「行程 ··· 菜单 → TripReminderSheet 逐趟编辑」全删，出发提醒改读全局设置、改设置即重排所有行程。理由：B/C 类（交通/住宿/每日）本就逐事件自动派生、无需 per-trip；A 类全局默认覆盖绝大多数；要逐事件不同 → 用「事件级静音」而非完整编辑器。`TripBundle.reminderConfigs`/`remindersEnabled` 字段保留（schema 不破，已 vestigial）。
- **通知按「锚点」分三类（架构骨架）**：A 出发日锚（出发提醒/打包提醒，相对出发前 N 天）；B 事件时刻锚（交通/还车/退房，相对事件起始时刻前 X，按事件时区算绝对时刻、trigger 锁 timeZone）；C 行程日锚（每日摘要，每个行程日某时刻）。identifier 分命名空间（depart/pack/transport/lodging/daily）可独立取消。
- **打包提醒有独立时间（默认出发前一晚 20:00）**：与出发提醒（清晨倒计时 09:00）刻意分开——打包发生在晚上、倒计时适合一天的开始。共用一个时间是错配。打包模块合并了「催打包 + 还差 N 件」。
- **租车/住宿只提醒「结束动作」**：取车/入住用户绝不会忘（自己主动去做、按自己时间安排）→ **不提醒**；还车/退房有「忘记」风险 → 提醒，但**默认关**。提前量同日（3h，让「今天还车/退房」成立）。这是「该提醒什么」的克制判断。
- **出发提醒档位精简 `[0,1,2,3,7,14]`→`[0,1,3,7]`**：当天/前1天/前3天/前1周，去掉「前2天」（夹在 1/3 间冗余）与「前2周」（对休闲游太远）。给一个有节奏的阶梯，远档=规划、近档=收拾。
- **通知文案哲学（Made with Love，硬性）**：① 相信用户、温和提醒，不教他做什么、用问句也行；② **不提负面后果**（逾期费用/超时罚款一字不提，会制造心理压力）；③ 有人情味、不性冷淡、不矫情；④ 意图随时间变（远=问规划、近=收拾、清晨=倒计时、晚上=打包）；⑤ 交通分**航班/非航班两套口吻**；⑥ 每日摘要正文**带出当天第一站**（具体有期待，胜过「今天有 N 项」）。
- **门控重排**：地点变更只在「每日摘要」开、打包变更只在「打包提醒」开时才 `scheduleReminders` → 默认用户（两类都关）零额外开销。比无脑全量重排优雅。

## 2026-06-20 续 住宿上脊 · 机型剥离 · 跨天+1上标 · 底栏穿透根因 · Trip Book 统计
- **住宿并入时间轴主脊**（spec 增补 itinerary-transport-lodging.md）：从顶部常驻条 → 脊上「当天角色锚点」（入住/出发/返回/退房），让一天读成「离酒店→各点→回酒店」、酒店成可点导航节点。中间日「出发」置首+「返回」置末（空中间日只留返回）；入住按入住时间就位默认置末、退房按退房时间默认置首。**去顶部条避免重复露出**；共用 `TimelineRail` 保脊连续；酒店↔地点距离 leg（`.lodgingLeg`，复用 ItineraryLegConnector，大圆距离）。**diffable 行 ID 必带 role / stop+departing 维度**（同租车两事件教训，防 item id 重复崩）。
- **住宿字号对齐地点**：住宿现在是脊上一等节点，标题用 `.body`（同地点/交通），「酒店≠景点」靠床图标+动词+字重区分，**不靠缩小字号**。原「退到背景」是它还在顶部条做被动背景时的考虑，前提已变。
- **「出发/返回」前置角色词**：原「从 X 出发 / 回 X 过夜」动词在尾、长酒店名必截断 → 动词消失。改「**出发 · X**」「**返回 · X**」前置（与入住/退房对齐），动词永不被截。用户嫌「过夜」不好听，选「返回」配「出发」成去/回对仗。
- **跨天「+N」= 小上标 + 预留 gutter**：内联同字号 +1 显斜/拥挤 → 改更小、上移的小上标（时间轴 + 详情卡）。详情卡 hero 两时钟在「**+N 固定宽度小列(gutter)**」左缘右对齐、gutter 右缘=内容右边距 → 时钟成列、+N 右边距与卡片一致。**通用原则：右对齐主值 + 可选尾部小徽标 → 给徽标预留固定列、别让它溢出到边距。**
- **机型品牌前缀全链路剥**：`aircraftModelDisplay` 不止详情用——编辑页 load/预填、Trip Book 聚合也剥并归一为型号（「Airbus A321」→「A321」），统计才正确合并、各处一致。
- **首页底栏穿透根因**：底栏 hosting 缺 `sizingOptions=.intrinsicContentSize`，空态启动后导入 → 不放行区(`barView.bounds`)塌 0 → 穿透。详见 `home-sheet-debug-playbook §33b`。
- **Trip Book 航班/住宿统计「无数据」前提反转**：航班搜索 + 住宿两日期落地后能诚实算出里程/时长/机型/机场/晚数 → 纳入（部分覆盖、hide-when-empty）。见 `trip-book.md`。

## 2026-06-20 行程详情/编辑大打磨：通用附件 · 电话 · 日期时间组件统一 · 详情卡结构定稿

### 通用附件（文件/照片/链接）落到所有行程实体（spec: itinerary-attachments.md）
- **架构**：新增 `ItineraryAttachment` @Model + `AttachmentKind`（file/photo/link），以 `.cascade` 关系挂到 `ItineraryStop`/`TransportSegment`/`LodgingStay` 三类实体（交通/住宿/地点全覆盖）。文件**字节存沙盒、仅文件名进 model**（镜像 `BackgroundImageStore` 范式），`AttachmentStore` 负责 save/data/delete/copy/deleteOrphans，**上限 25MB**；照片存「缩略图 + 原图」，链接不抓标题（避免网络副作用与不确定性）。
- **备份/还原闭环**：`DataBackupManager` 新增 `BackupAttachment` + 三实体 backup struct 带 attachments 字段 + `attachmentFiles` 字节字典（可选、向后兼容，遵守「沙盒关联文件须显式随备份带字节」铁律）；`duplicateTrip` 经 `copyAttachments` 深拷贝。
- **分享/导出过滤掉附件**：附件是私人随身资料（订单截图、护照页…），分享给同行者的清单/导出 PDF 一律不含；隐私政策（carry-legal zh.html + index.html）同步加「附件仅本地、不随分享外发」段。
- **新建实体（owner 尚无 id）也能加附件**：用 `attachmentAddFlow` ViewModifier 把 PhotosPicker/fileImporter/相机/链接输入**统一挂到稳定父 Form**（不挂 Section 行——列表行回收会令 sheet 瞬间自关，已踩坑），owner 为空时先 buffer 到 pending、保存时 flush 进 store。相机走 `UIImagePickerController`（NSCameraUsageDescription 补全 9 语言）。
- **链接输入用独立 sheet、不用 alert**：alert 内 TextField 在 sheet 之上有 focus bug（无法输入/粘贴）→ 改 `LinkInputSheet`。
- **链接 App 内打开**：用 `SFSafariViewController`（UIViewControllerRepresentable）在 Carry 内开，不外跳 Safari。

### 电话字段：MapKit 自动回填 + 点按拨号
- `phone` 字段加到 `LodgingStay`/`TransportSegment`（租车）/`ItineraryStop`。地点搜索经 `MKLocalSearch` → `MKMapItem.phoneNumber` **自动回填**（零录入，对标 Tripsy 拿电话/地址的方式），搜索回调签名扩成 `(name, lat, lon, address, phone)`。
- 详情页 `CallableDetailRow`：点按 `tel://` 直接拨号，方便行程中联系酒店/租车行。

### 日期+时间交互组件全模块统一（chip + 弹出选择器）
- 交通/地点/住宿三处编辑表单的「可选日期/时间」**统一成 `FormChip` + 弹出 `ItineraryTimePickerSheet`**，弃「Toggle + 内联 DatePicker」（内联展开会令表单行高跳变、体验差）。见 [[carry-form-datetime-chip-pattern]]。
- **编辑表单日期行去掉日历图标**：与时间 chip 视觉统一（chip 自解释，不靠图标领位），不是表单里每行都要图标——按需，不画蛇添足。日期行加常驻文字标签（先前用户反馈「填了值标签消失剩裸值」的延续修正）。

### 详情/编辑卡片结构定稿
- **费用→备注→附件 固定顺序、各自独立卡**：详情与编辑里三者都拆成 standalone 卡片，顺序恒定。费用不再靠近顶部（先前用户反馈成本不该在最上方）。
- **详情浮层头部钉死不随滚动**：`DetailSheetScaffold` 量头部+内容高度、**只给单一 `.height` detent、刻意不含 `.large`**——iOS 26 的 `.large` 会把弹层「脱成两侧带边距的浮动卡片」（详情弹出即缩的根因）；不进 `.large` 即不缩。长内容仅下方卡片区内部滚动，关闭 X 常驻。
- **机型只显类型码**：`aircraftModelDisplay` 过滤掉「Airbus/Boeing/Embraer/Bombardier/COMAC/McDonnell Douglas」厂商前缀（保留 ATR），只留 `A330-200` 这类型号；机型从主区挪进「更多」。
- **航班号领衔**：承运方降为副标题（延续 06-19 标题约定）。
- **租车不用航班（起降）图标**：取车/还车用 key 图标；按 pickup/return 端点聚焦（focus 枚举 .full/.pickup/.dropoff），聚焦视图去掉「+N」、显示详细地址 + 导航入口 + 租期天数。删除按钮文案 mode-aware（「删除租车」等）。新增 `vehicleModel`/`licensePlate` 字段。
- **地点分类菜单只留地点类**：移除交通方式等非地点分类（`placeSelectableCases`）；地点添加/编辑表单去掉 footer 文案。

### 排序复核：新建无时间地点落到列表底部（确认非 bug）
用户反馈「新地点加到顶部」——逐层读代码均指向底部（`addItineraryStop` 的 sortOrder = 现有 max + 1），无法静态复现；经模拟器实测确认新地点确实落底部、为非问题（[[verify-code-reachability-before-asserting]] 的实践：先复现再断言）。无代码改动。

## 2026-06-19 Trip Book 纳入航班/住宿统计（前提反转，spec: trip-book.md）
背景：用户问飞行时间/里程、座位偏好、机型统计该不该进 Trip Book。`trip-book.md` 原把「航班里程/时长/机场 Top」「住宿晚数」列为 🔴 不做，**唯一理由是「没数据」**——但该前提已被后续功能推翻（与 2026-06-16「总花费」反转同一逻辑）：航班搜索 + `FlightLookupService` 让 `TransportSegment` 带上 `distanceMeters`/`durationMinutes`/`aircraftType`/`fromCode`/`toCode`（航班号查询自动回填、零新增录入）；住宿改「入住日+退房日」后 `nights` 成确定派生值。
决策：
- **纳入**：① 飞行卡（累计里程 + 飞行时长，合一，里程走 `CarryDistanceFormat`/`distance_unit`、时长 `Xh Ym`）；② 机型作飞行卡底部**轻量小行**（「N 种机型 · 最常 X」，不单列大卡）；③ 机场 Top 卡（按 IATA 码计数降序，镜像「最常去国家」，码作烟蓝胶囊 chip）；④ 住宿累计晚数卡。
- **座位偏好（窗/过道/中间）不做**：`seat` 是自由文本（"32A"），窗/过道/中间须靠「座位字母 × 逐机型座位图」反推、中间座几乎无法判 → 算不准（违背「诚实优先于炫目」）；做准只能新增三态录入 → 违背「零新增录入」。
- **部分覆盖 → 无数据整块隐藏**（同花费卡）：`hasFlightStats` / `airportTallies.isEmpty` / `totalNights > 0` 各自门控，老用户不显示一排 0。
- **口径**：航班统计只数 `mode == .flight` 段；里程用大圆距离；机型/机场按航段计（一趟多段各计一次，与现有国家 `N×` 同范式，和 > 总趟数属正常）。聚合纯函数在 `TripBookStats.compute`（可单测），适配在 `TripBookStats+Trips`。
- **卡片上下顺序按「旅行回顾」叙事线重排**：总量（概览）→ 去了哪（国家→大洲）→ **走了多远（飞行→机场→住宿）** → 我是哪类旅行者（国内国际→季节）→ 花了多少（压轴）。关键调整＝把高光「旅程」段（飞行里程/时长是 Trip Book 情绪最强、最可分享的数字）**上移到地理段之后、出行习惯段之前**，与地理接成「跨 N 国 → 飞 X 公里 → 住 Y 晚」的连贯弧线；偏分析的国内国际/季节退到中后段。旅程段 hide-when-empty → 无航班/住宿数据的用户该段整体隐藏、自动让位给习惯段，故对轻度用户零副作用。概览恒第一、花费恒压轴不变。

## 2026-06-19 交通详情卡 + 住宿条 视觉收尾
- **航班/火车详情标题拆两行**：班次号当标题、承运方放副标题槽（航司全名两行、不再从中间硬断行）。与租车头「公司 / 取车」同结构。
- **飞行时长放底部明细列表，不放 hero 连接线**：试过把时长放到两端之间的连接线上（Flighty 式），但在卡片 Grid 里时长会让「机场码↔时间」逐行配对错位（到达时间跑去对城市名行）、且中段空荡难调，模拟器不可自驱验证下风险高。**反转**改回 Tripsy 式——hero 只留两端点 + 连线，时长进 detailsCard（与距离/机型一组）。判据：hero 是「两端点旅程」的仪式感卡，塞第三个量会打乱配对；时长属描述性规格、归明细。
- **住宿条床图标透明度统一**：之前把酒店名统一成 `.secondary`，图标却仍按过夜天 `opacity 0.5` 调暗 → 不一致。统一成 full `dayColor`；过夜天「退后」改靠**空心床图标 `bed.double`（vs 实心 `.fill`）+ regular 字重 + 无前缀**承担，不再用 opacity 与统一后的名称打架。
- **「退房」未显是数据非 bug**：见下条住宿两日期决策——nights 偏大致退房日落行程外。

## 2026-06-19 住宿录入用「入住日 + 退房日」两日期，弃「住几晚」Stepper
背景：用户困惑「入住有『入住』前缀、退房没『退房』」。诊断——**不是显示 bug**：时间轴入住/过夜/退房三态本就对称正确；问题在输入用「住几晚」(nights)，反直觉、易错——入住 7/19、想住到 21 号（2 晚）却填了 3，退房日被推到 7/22（行程外），「退房」无 day 可渲染而消失，7/21 你其实还在住（第 3 晚）→ 显「过夜」反而是对的。
决策：录入改「**入住日 Picker + 退房日 Picker**」（都从行程内的天选），`nights = 退房日 − 入住日` 派生；**内部存储仍 `checkInDayOrder + nights`，零 schema 改动**。约束：入住日排除最后一天、退房日只列 `> 入住日` 的天 → **退房日恒在行程内、「退房」必然可渲染**。显示侧不动（三态已对称）。对标酒店/Tripsy 的「选两个日期」心智。落点仅 `LodgingEditView`。

## 2026-06-19 行程时间轴统一：主脊连续 · 点/边时间规则 · 航班标题班次号领衔 · 行距刻意可变

### 时间轴 = 点 / 边 / 跨度三类，连成一条连续主脊
抽共享 `TimelineRail`（46/28/9 几何），地点、航班火车、租车三种「在脊上」的行共用 → 竖脊**连续穿过交通段**（原先交通行不画半线、脊断开）。首项清上半线、末项清下半线，两端干净。住宿是「跨度/背景」，**不上脊、不连线**（轻量常驻条）。距离 leg 仍只在「地点↔地点」之间。

### 时间显示：点右对齐、边内联 route
**点类事件**（地点、住宿入住/退房、租车取车/还车）= 单一时间 → **右对齐**成一列，统一。**边**（航班/火车，一段移动、两端两时刻）→ 保留内联 `A 8:00 → B 10:15`，**不强行右对齐单一时间**（会丢另一端或拆散「站—时刻」对）。「同类同款」而非「全都一样」——边长得不同是对的。

### 航班/火车标题：班次号领衔，承运方降为浅色次要
`航司 · 班次号` → **`班次号 · 航司`**。理由：航班号/车次才是旅客认的唯一标识（登机牌/航显），航司前两位（MU）已编码、相对冗余（Flighty 同此）。承运方降 **regular 字重 + secondary 浅色**，一行两级层次。时间轴行 + 详情卡标题同序。**部分调整 2026-06-16 的标题约定**（当时航司在前）。租车无班次号 → 仍只显公司名。

### 副行 route 内联航站楼：代码 + 航站楼 + 时间
`SHA T2 8:00 → PEK T2 10:15`——航站楼紧跟机场代码（同属「在哪」）、在时间前；复用 `terminalDisplay`（航班数字前加 T，火车站台原样）；空则不显。

### ⚠️ 行距「按内容可变」是刻意的，不强行统一（防再纠结）
问：带距离的「地点↔地点」行距比交通/租车处更高，要不要统一？**结论：不统一，保持现状。** 那段更高是因为**多承载了一条信息（里程标签）**——「有内容→更高」是时间轴/行程类 UI 通行做法（Flighty 航班卡、Apple 地图换乘段同理），用户读得懂。强行统一只会二选一变差：要么撑出大片**空白线**（时间轴变长、没信息占地方），要么把距离标签**夹得局促**。这是信息驱动的高度差，不是瑕疵。

### 住宿条时间/名称颜色归一 secondary
中间过夜天酒店名 `.tertiary`→`.secondary`（深色下原来像渲染坏）；入住/退房**时间**也用 `.secondary`，与地点/交通的时间字段同列同色；过夜「N晚」（计数、非时间）仍 `.tertiary` 退作背景。住宿「退作背景」改靠淡床图标 + regular 字重 + 无前缀承担，不靠近乎不可读的暗文字。

## 2026-06-19 航班搜索/交通表单 UI 定稿：日期块 · 字段标签 · 时间轴去价格

### 日期块纯黑白灰；「建议当天」用灰底不用强调色
原因：日期列表里用强调蓝标「建议当天」+「Other date」蓝图标蓝字，多处蓝显杂（用户反馈「颜色有些杂，能只用黑白吗」）。
决策：日期块**纯黑白灰**——日期色卡（月缩写+日号圆体）中性灰，**建议当天（点「+」的那天）只用「更亮一档的灰底」**（`systemFill` vs `tertiarySystemFill`）做极轻提示，不引入强调色；「Other date…」同款灰色卡 + 日历图标（次要色）。强调色留给真正的主操作/选中态。日期行去 chevron（点选=提交、非导航，遵守 chrome 铁律）。

### 航班号字体 SF + 强制大写
原因：原圆体 semibold 违反 design-system「表单输入/placeholder=SF」；自动大写键盘可能被小写输入法绕过（出现「Mu5127」）。
决策：航班号输入用 **SF `.title3`**；binding `set: { $0.uppercased() }` 兜底强制大写。placeholder 示例号用 MU5127（用户个人纪念号，占位无副作用）。

### 「Other date…」日历：自绘零跳 vs 系统 graphical —— 用户取舍回系统
原因：系统 `.datePickerStyle(.graphical)` 在自托管 sheet 里**首次出现会落定微跳**（~3px，点空白可见）。曾自绘确定性月历网格（`LazyVGrid` + 固定行高）做到**零跳**并验证通过。
决策：**用户最终选回系统 graphical**（更原生精致），接受 ~3px 首次落定（`.frame(height:360)` 压到最小；正常流程「点日期即关」看不到）。记录：自绘网格是可行的零跳备选，若日后再不能接受跳可切回。点日期即触发查询（无 Done 按钮，与日期行点选即触发一致）。
> 通则：系统 graphical DatePicker 自托管有首次落定抖动；要绝对零跳得自绘网格（确定性布局）；是否值得换取「系统观感」是产品取舍。

### 交通表单字段用常驻标签（不靠 placeholder 当标签）
原因：代码/航站楼/座位/确认号用 placeholder 当标签，**填了值后标签消失、剩裸值**（`HGH`/`3`/`3B`/`ABC123`），用户看不懂（对比 Tripsy 每值有标签）。
决策：这些字段改 `LabeledContent`（标签左·值右，同「机型」行），空态标签即提示、填态「代码 HGH」一眼懂。**有意不标**：承运方/班次号（身份头，自解释，Tripsy 顶部也不标）、日期时间 chip（值自解释 + 📅 领位）、备注（自由文本）。
> 通则：**该标的是看不懂的不透明值（代码/编号），不该标的是自解释值（日期/时间/名称）**——按需加标签、不画蛇添足。

### 行程时间轴只显「何时/何地」，不显价格
原因：费用功能（itinerary-cost-tracking）曾把价格显示进时间轴的交通行 + 住宿入住行（理由「不进编辑页就能看到费用」），但地点行没有 → 不一致；且交通行右侧本是时间位却显价格，用户困惑（「行程规划里怎么显示价格？应该是时间吧」）。
决策：**时间轴一律只显时间**——交通行去价格（时间已在副行起讫站+时刻）、住宿入住行改显入住时间、地点行本就如此，三类一致。价格留**详情页 + Trip Book 花费汇总**（看钱的地方）。**反转**费用功能「时间轴可见费用」的决定（前提：时间轴是「行程」视图，钱不该喧宾夺主）。

## 2026-06-19 设置：通知权限可达性 + 行程提醒一级行语义

### 通知授权被拒/未设 → 给一条出路，但不做「权限假开关」
原因：首次创建行程引导的授权若被忽略/拒绝，iOS 不再二次弹窗、App 内又无处唤起 → 死胡同（「行程提醒」子页档位形同虚设、却既不提示也无法跳系统设置）。对照：日历早有「denied→去设置」，通知偏偏缺，是一致性缺口。
决策：在 `NotificationSettingsView` 顶部加**状态感知横幅**，而非加一个通知权限开关——系统权限**无法在 App 内被真正切换**，做成开关是误导。三态：`.denied`→深链 `UIApplication.openNotificationSettingsURLString`（iOS 16+，直达本 App 通知页，比通用设置页准）+ 下方档位置灰禁用；`.notDetermined`→应用内 `requestAuthorization`（补回首次漏掉）；`.authorized`→隐藏整块。`scenePhase` 回前台刷新，让横幅随真实授权态出现/消失。对齐已有日历 denied→Open Settings 模式，全 App 一致。

### 一级「行程提醒」行的值 = 「实际还会不会发提醒」，不是「系统授权态」
原因：原 `notificationStatusText` 只读系统授权态 → 用户把所有档位关掉、一级行仍显 On，误导（以为还有提醒）。
决策：授权正常 → 值**跟随档位**（≥1 档开=On、全关=Off）；denied=Off、notDetermined=未设置（权限异常仍在顶层可见）。一级与子页**共用同一 `ReminderPreferences.storageKey` 的 `@AppStorage`**，改档位即时同步。语义切分：**权限问题归页内横幅，「我的提醒开没开」归一级行值**，不再把两件事挤进一个 On/Off 里打架（横幅落地后这个切分才成立）。

## 2026-06-19 添加航班：搜索优先 + 日期/时间融合 chip + Worker 安全收尾（spec: itinerary-flight-search-first.md）

### 添加航班翻转为「检索优先 + 手动兜底」；「选日期 = 触发查询」（学 Flighty 之神，不抄其形）
原因：原添加航班是一张手动表单全摊开，自动填只是埋在中间的可选加速器（主次颠倒）。Flighty/Tripsy 都是渐进式单框：输号→识别→挑日期→出结果。
决策：新建 `FlightSearchSheet` 作第 1 段——输航班号→即时识别航司（新 `AirlineDatabase`）→展开日期→查询→结果确认卡→点卡 push 进**预填**的 `TransportEditView`（第 2 段=既有表单，不另写）；底部常驻低权重「手动输入」兜底（春秋 9C 等查不到的航班）。**触发模型对齐 Flighty：选日期这个动作本身即触发查询**——不预填一个「待触发」的默认值、不加查询按钮（预填会把天然触发点吃掉、逼出多余按钮）。Carry 反超点：日期选项用**本行程的天**（比通用今天/明天更贴场景）。**不照搬** Flighty 的航司/机场浏览（那是 flight-tracker 基因，Carry 是 trip-planner，只需「航班号→自动填」一条主路径）。
> 走过的弯路（勿重蹈）：① 横排日期 chip——宽 chip 丑、长行程要横滚；② 单行原生 DatePicker 预填默认值——把「选日期=触发」吃掉，只能靠回车/按钮，别扭。

### 交通段日期/时间用「融合 chip」（取代 toggle+内联控件）；日期暂锚定行程天
原因：原「day Picker 行 + 时间开关行」，开关一开把比开关高的 compact `.hourAndMinute` DatePicker 塞进同一行 → 行高被撑高跳变；信息量也大（用户反馈「从上到下太满、有压力」）。
决策：参考 Tripsy，日期/时间合成一行两个 chip（`📅 [日期 chip][时间 chip]`）：日期 chip 显示行程天（点选换天）、时间 chip 可选（未设占位、点开滚轮 sheet、可清除）。**根因解了行高跳变**（无开关、选择器移弹出层、chip 普通行高），信息量也压缩。曾用「隐形占位」是 workaround（关态虚高），已废弃。地点搜索+时间选择合并单一 `.sheet` 枚举（防多 sheet 互抑）。
> **「日期真正可选」（不启用日期）拆为单独立项**：Carry 时间轴是**按天分组**、交通段锚定某天；Tripsy 是**扁平按时间排**。无日期交通段与按天分组正面冲突，需「未排期」区 + `day` 可空/哨兵 + schema 迁移 + 备份/复制/删天/PDF 全链路，且重叠并行租车工作 → 单独 spec + 协调后再做；本轮先交付融合 chip（日期锚定天）。

### 客户端口令不进源码（gitignore Secrets.plist）+ 轮换；Worker 限流 best-effort，成本靠额度兜底
原因：`appToken` 原硬编码在 `FlightLookupService.swift`，而 `carry-ios` 是公开仓库 → GitHub 密钥扫描器会秒扫到、易被拿去刷 Worker 烧上游额度（低-中危的「花钱被刷」，非私钥泄露——真 key 只在 Worker）。
决策：① token 改从 **gitignore 的 `Carry/Resources/Secrets.plist`** 读（随 bundle 打包、缺失降级空），并**轮换**（Worker `APP_TOKEN` 同步换新、旧值作废）；**不改写 git 历史**（轮换后旧 token 已死、曝光无意义；改写共享 main 风险大于收益）。② Worker 加 Rate Limiting 绑定（`RATE_LIMITER` 20/60s）——但实测 Cloudflare 该限流 **best-effort/近似**（按数据中心、最终一致），50/50 短爆发全过、抓不住快爆发。结论：**成本真正兜底＝ APP_TOKEN 门槛（需反编译才得） + 上游月额度硬上限 + Worker 服务端缓存**；限流当额外一层（对持续盗刷仍有效）。要硬 enforcement 留 Durable Object 计数器后续。
> 通则：公开仓库**绝不**硬编码任何口令/key（哪怕是低安全级客户端门槛）——用 gitignore 的本地配置注入；半公开 token 的防线应是「额度上限 + 限流」而非「保密」。

## 2026-06-19 底部交互/导航视觉：新建 sheet 化 · 动作菜单归位 · 浮动栏通透 · 对齐根因

### 新建行程：单屏流 → page sheet（不再全屏 cover）；加草稿放弃确认
原因：创建流早简化为单屏（TripInfoView「Create」直接建行程、不再 push ItemPicker/PackingList），全屏 `fullScreenCover` 是旧多步流遗留——既不符 HIG「短表单用 sheet」（对齐 Apple 新建事件/提醒/联系人），其方角内容又撞屏幕物理圆角不协调。
决策：iPhone 创建改 `.sheet`(page sheet)。加「草稿放弃确认」：表单有草稿（名字/城市非空）时 `interactiveDismissDisabled` 拦下滑、取消弹「放弃这个新行程?/继续编辑」；空表单直接关（与现有「取消即弃」语义一致、只在有投入时才确认）。把首页的 `PresenterRecedeEffect`（放开为内部可见）复用到创建 sheet，弹出时首页后退缩放，与设置/搜索/Trip Book 四个 sheet 统一。Mac 走根 path push、无 sheet、不受影响。

### 行程动作菜单：留在右上角「…」，不下沉底部；低频动作不占拇指黄金区
原因：用户反馈右上「…」不好够/不好发现，参考 Tripsy 底部工具栏。实做「底部三件套（···/切换器/➕）」后**反而别扭**：① ➕ 跨 tab 变义（行程→加地点、打包→加物品），单动作控件随旁边 tab 静默改义 = 心智负担；② ··· 放左下是右手拇指**最难够**的角；③ 把一堆**低频/一次性**动作（编辑行程/提醒/分享/导出/删除…）塞进拇指黄金区本末倒置，还和导航（切换器）在同一行混淆「我在哪 / 能干嘛」；④ 全局 ➕ 还引入「加到哪天」歧义——而每天内联「+添加」精准零歧义、本就更好。
决策：**整套回退**。低频溢出动作留**右上角「…」**（iOS 全系统惯例，用户被训练「找更多看右上」→ 靠惯例可发现；低频够不着无妨）。原「不好发现」的真因是图标太弱（14pt secondary 灰）、非位置 → 提到 17pt label 主色、与返回键等分量（iOS 26 系统给工具栏按钮自动套同款玻璃圆）。加地点继续用内联「+添加」，优化顺序留天头（语义天生按天）。
> 教训（通则）：「可达性差」未必靠「搬到拇指区」解——先分清**频次**，高频才进拇指区、低频归惯例位（右上「…」）。「不好发现」常是**视觉分量**问题（太小太淡）而非位置问题。导航与动作别塞进同一条底部带。

### 浮动 glass 胶囊用「通透磨砂」，不用实心垫底（新增 `bottomBarFade`）
原因：行程/打包底部切换器是半透 glass 浮动胶囊，原垫 `bottomBarScrim`（实心兜底）——较高实心区把可视内容区视觉压短；且胶囊背景用 `Color.opacity` 平涂半透（只调暗不模糊）→ 胶囊后清晰文字穿透显脏。
决策：① 浮动栏（safeAreaInset 里的玻璃胶囊）垫底改用新 `bottomBarFade`（透明→底端半透 0.92），内容在栏后柔和消隐却仍透；② 胶囊背景 `.regularMaterial` 磨砂玻璃——半透同时**模糊**背后内容（糊成柔光、不再透清晰字），这是 iOS 原生悬浮栏「通透却不脏」的根。**选型延续**：整宽实心 CTA 底栏（采用/保存/Continue）仍用 `bottomBarScrim`（主操作要实底背书）；浮动导航/胶囊用 `bottomBarFade`+磨砂。（详见 design-system §底部栏过渡。）

### 原生控件内边距别用魔数补偿，改「同构渲染」结构性对齐
原因：设置「外观/距离单位」用原生 `.menu` Picker、自带尾部内边距 → `⇅` 落在其它行 `>`/`↗`（18pt）左边、整列不齐。先用 `-12pt` 负 trailing 补偿——治标，且补的是 SwiftUI 控件内置常量，**OS 版本一变就漂**（机型/屏宽不影响，因为是 point）。
决策：根因解＝让菜单行与其它行**同构渲染**——`Menu`（自定义 label = 值 + `settingsAccessory(.menu)`，**标题留 Menu 外**避开「label 展开闪空」坑）+ 内联 `Picker` 当菜单内容。箭头走同一段 `settingsAccessory` 代码 → 结构性同列、零补偿数、不随 OS 漂。
> 通则：对齐系统控件别靠「量一个偏移补回来」（脆、藏问题）；优先把两边收敛到**同一套渲染**，让对齐成为结构必然。

### 列表行尾部配件「恒定占位」，选中态不改变布局
原因：App Icon 选中行的对勾用 `if isSelected` 才插入 HStack → 挤窄副标题宽度 → **选中即换行**（同一文案选中两行、未选中一行）。
决策：对勾位置**恒定预留**（始终布局、`opacity` 切显隐），选中只切换可见性、不重排；副标题 `lineLimit(1)+minimumScaleFactor(0.85)` 恒单行（窄屏/大字号极轻微缩字、不换不截）。
> 通则：列表行的选中/状态配件应**预留固定槽位**，状态变化不该让文本可用宽度跳变。

## 2026-06-19 行程交通：租车入口收口 + 类型菜单/表单（spec: itinerary-car-rental.md）

### 租车 = 交通段（边），从「地点」类别撤出，升「+」顶层交通入口
原因：原本加租车走「地点」类别选择器 → 搜一个坐标点；但用户诉求是「公司叫什么/在哪不重要，重要的是取车地点（机场/车站）自己设」——租车本是「边」（移动）不是「点」。模型里 `TransportSegment.carRental` 早已建好，只是菜单没接、还留着一条「地点类别」错误路径在抢用户。
决策：`StopCategory.placeSelectableCases`（在地体验+住宿+兜底）从地点类别**撤掉** flight/train/carRental/cruise（**枚举 case 全保留**，旧数据仍解析渲染）；租车升为「+」交通组顶层、走现成 `TransportEditView`。cruise 今后走「其他交通→ferry」。

### 添加类型入口：嵌套子菜单（常用直列 + 「更多交通」子菜单），单一数据源；否决全屏 hub / doorway
原因：对比 Tripsy 全屏「新活动」hub——它类型几十种 + 搜索优先，**必须**重壳；Carry 类型就六类，全屏 modal 是「大锤敲图钉」，丢上下文、变慢，违背克制。但纯平铺 6 项交通又偏长（实地反馈：低频的巴士/渡轮/其他占一等舱、菜单太满）。
决策：`TransportMode.ordered = commonModes[航班/火车/租车] + moreModes[巴士/渡轮/其他]` 作**单一数据源**——「+」菜单与表单内类型选择器**共用**（内外一致、永不分叉）。菜单交通组＝常用直列 + **「更多交通」原生嵌套 `Menu` 子菜单**（巴士/渡轮/其他，各**直接落位**）。否决「全屏 hub」（过重）与「其他交通→进表单再选一次」（多一步 + 表单会重列常用项的重复感）。航班仍走「搜索优先」特例（`searchFlight`），其余走通用表单。
> **更新 2026-06-16「交通录入：Type 为单一权威」那条的理由句**：当时为「不把菜单堆成 8 项」而让 bus/ferry/租车/其他「只能从 Type 到达」；现租车升顶层、其余收进「更多交通」子菜单 → **既轻又全可达、内外清单一致**，取代旧的「只能从 Type 到达」安排。

### 类型固定在创建时：移除表单内「类型」选择行，标题承载类型
原因：外层「+」菜单已是一次明确的类型选择，进表单再用一整行重复展示+允许再改，多余；标题承载类型更干净（对齐 Tripsy/Apple 的类型专属编辑页）。
决策：删除表单顶部 `typeSection`，导航标题改 `navTitle` = 「添加{类型}」/「编辑{类型}」（`{add,edit}.title.typed` 带 %@，各语言占位符位置按习惯，台湾用「新增」）。字段仍按 `mode` 自适应，但 `mode` **只在创建时定、表单内不可改**；改类型 → 删除重加（极少见，且各类型字段本就不同）。一个取舍：编辑时不能就地换类型（会丢已填字段）——判定可接受。
> **部分反转 2026-06-16「表单内 Type 选择器作唯一权威、可就地改、不丢数据」**：保留「字段随 mode 自适应」，但**撤销「可就地改类型」**——类型改由创建入口单点决定。

### 还车地点同取车开关：派生、不加存储位
原因：多数租车原地还，单独填两处地点冗余（Tripsy「相同的下车地址」）。
决策：`sameReturnLocation`（默认开，仅 carRental）只折叠还车**地点**、保留还车日期/时间；保存时把取车地点拷给还车端（保证详情/地图/导出两端数据完整）。**不新增存储字段**——编辑时从「还车端为空 / 与取车端同名同坐标」**派生**初值。零 schema 变更。

### 租车在时间轴渲染为「取车 / 还车」两个事件（不是一条连接行）
原因：租车被当成 `TransportSegment`（边），与航班同构渲染成**一条连接行**落在出发日、还车只用「+N」角标 → **还车那天时间轴无任何提示**（按时还车却无感知）；且详情/列表标签错用航班语义「Departure/Arrival」。
决策：一条租车段在**取车日**渲染「取车 · 公司 / 取车地点 · 时间」、在**还车日**渲染「还车 · 公司 / 还车地点 · 时间」两条事件（各显本端、不再「+N」）。**零模型迁移**——不碰 `Itinerary.swift` 的 `timeline`（航班会话热区），在 `ItineraryView.daySections` 把租车 timeline 项解释成取车行、并在还车日按还车时间注入还车行；行 ID `.carRental(segment:day:pickup:)` 带 day 维度避 diffable 重复崩溃坑。详情按 mode 用「取车/还车」标签（`section.pickup/dropoff`）。

### ⚠️ 租车=离散事件、住宿=跨度，二者刻意不同（别再来回纠结）
背景：租车做成「取车/还车两事件」后，自然会问「住宿要不要也这样/统一」。
判据：二者都跨多天，但**用户体验的本质不同** → 走 2026-06-16「实心彩圆=离散事件 / 裸图标=跨度」两档框架的不同档：
- **住宿 = 你每晚所在的「基地/背景」**：不是某时刻「做一下」，而是这几晚都在 → **跨度**，每覆盖天一条**轻量常驻条**（回答「今晚睡哪」）、最轻退作背景、入住日钉顶不按时穿插（是「当天的框」非流内一项，对齐 Tripsy）。
- **租车 = 两个你要去做的离散动作**（按时去机场取车/还车，有明确时间地点、在当天行程流里）→ **离散事件**，按时间就位、实心彩圆同停靠点。
住宿其实也有「入住/退房」两端点事件；它只是**额外**多一条中间天常驻条，因为「今晚睡哪」值得每天提示、「我有辆车」不值得（故租车不要中间条）。**结论：住宿维持现状（已是最建议形式），不改成租车式离散事件。** 二者视觉差异 = 真实语义差异（基地-上下文 vs 时刻-动作），内部自洽。

## 2026-06-19 机场库 / 行程地图取景 / 航班时间轴定位 / 底部渐变配色坑

### 航班机场搜索 = 内置机场数据库，不挂通用地图 POI（spec: itinerary-airport-search.md）
原因：大陆设备 MapKit POI 走高德、境外机场覆盖差，且 App 无法切供应商；通用 POI 也给不出 IATA/时区。
决策：打包 `Carry/Resources/airports.json`（OurAirports 机场列表 + OpenFlights 时区 + Wikidata 9 语言名/城市别名，IATA 未命中用 ICAO 兜底抓取），`AirportDatabase`(actor) 全球离线检索、回填 IATA/坐标/IANA 时区。**仅航班机场选点走它**，其它交通方式仍走地图 POI。数据许可：OpenFlights ODbL **要求署名**（已落 AboutView「数据来源」卡）。重建脚本 `scripts/airports/`。

### 行程地图：预览取景由「地点」驱动，交通端点不参与缩放
原因：航班 from/to 端点（机场可相距数千公里）一并算进总包围盒 → 加航班后地图缩成跨国尺度、市内地点变针尖。
决策：**预览**取景只用停靠点（`framingCoordinates`，纯航班日才回退含端点）；**全屏**维持框住全程含航班弧线。分工：预览看当天本地、全屏看全程。不引入离群统计/阈值（不可预测、不克制）。

### 航班在当天时间轴的定位：硬时间锚点，按「相对正午」就位
原因：原 timeline 只把定时航班相对「其它定时项」插入；Carry 地点常不填钟点 → 航班无锚点落末尾，早班机被无时间地点压到底、丢了「清晨」信息。
决策：base 全是无时间地点时，按航段**出发时间相对正午**定位——上午(<12:00)领起当天置顶、午后/傍晚收束置底；有定时项时沿用原「按时间逐个插入」。航班行外观不变（航司·航班号/起讫+时间，信息量足、有订票价值，比缩成「抵达 X」更有用）。

### ⚠️ 底部「消隐渐变/实心垫底」配色坑：目标色 == 该页「底部最上层不透明层」色，不是页面根！
原因（踩坑）：行程详情根是 `CarrySubtleBackground`(暗底端 0.08)，但内容层（ItineraryView/packingContent）铺 `systemBackground`(纯黑) + `.ignoresSafeArea(.bottom)` **盖住了根** → 底部真实是纯黑；`bottomBarFade` 淡出到 0.08 baseColor 就在纯黑上显**比背景亮的灰雾**（Dark 才可见，浅色 0.98 vs 1.0 几乎无差）。
决策/判据：`bottomBarFade`/`bottomBarScrim`/`bottomContentFade` 的目标色**必须等于该页底部「最上层不透明层」实际渲染色**——别按页面根判（内容层常覆盖根）。改为两面都淡出 `systemBackground`。另：UIKit `CAGradientLayer.colors` 存的 CGColor **不随 light/dark trait 自适应**（`FXBottomFadeView` 深色停白），须 `registerForTraitChanges` 重设；SwiftUI `Color(动态UIColor)` 则会自适应。排查同类问题用「可观测/实测」：截图看真实底色 > 静态读「根背景」（agent 静态读把行程详情判反了）。

## 2026-06-18 设置信息架构与一致性 / 自定义分类 / SwiftUI 呈现坑

### Settings 一级 IA：用「Language & Region」替代无主题的「General」
原因：「General」是无主题兜底名；其下 Distance Unit/Currency 实为语言/区域/格式偏好，不是「通用」。
决策：语言 + 货币 + 距离单位归「**Language & Region**」（对标 iOS 系统设置），Personalization 收回为纯外观（Appearance/App Icon）；Language 从外观组下移到此组。`settings.section.general` key 改名 `settings.section.language_region`。

### 行尾可供性与「点击后发生什么」严格对应（Apple HIG）
决策：`chevron.right` 仅 push（进设置下一层）；离开 App（系统设置/邮件）用 `arrow.up.right`；开 in-app sheet 的动作行不挂箭头；就地弹菜单用**原生 `.menu` Picker** 自带的上下箭头。设置**子页背景统一 `systemGroupedBackground`**，与父页一致（App Icon/About/Roadmap 原误用首页氛围渐变 `CarrySubtleBackground`，push 进去会跳色）。Roadmap 由 sheet 改 push（信息内容归层级、避免模态套模态）。

### 我的物品「自定义分类」：派生自物品、无独立实体；管理全程无 modal
原因：`MyItem.category` 是自由字符串、无独立分类实体。删除一个分类必然牵涉其下物品。
决策：复用 = 列出当前 collection 去重的非目录 category（最近用在前）；重命名/删除批量作用于该 collection 内 category 匹配的物品；**删除只清空物品的 category（→暂不分类）、保留物品**（PM 选定，非删物品）。管理 UI **不用任何 modal**（行内 TextField 重命名 + 即时 swipe 删除），原因见下条。spec: `my-item-custom-categories.md`。

### ⚠️ SwiftUI 嵌套呈现坑（两个，UI 改动优先排查）— 详见 memory `swiftui-nested-presentation-and-menu-label-gotchas`
① 在「sheet 内再 push 的页」上呈现 alert/confirmationDialog 会坏：挂在 push 页→一弹就把该页弹回上层；挂在被它盖住的父视图→modal 根本不显示。解：用**行内 UI**，或把该页改成 **sheet**（独立呈现上下文）。
② 自定义 `Menu` 的 `label` 里包文字 → 菜单展开瞬间那段文字渲染空（设置「外观/距离单位」标题消失）。解：**标题放菜单外**、值用**原生 `.menu` Picker**。`.buttonStyle(.plain)` 不是病根（去掉无效，是错误机制的瞎猜）。
教训：两处都先「猜机制 + 微调」失败 → 结构性根因解才稳，且**验证后再下「修好了」结论**。

### 深色首页空态 Sheet：要分离用真实磨砂玻璃，别加假光（详见 memory dark-card-no-fake-light-use-material）
原因：深色下卡片贴近黑色背景、缺浮起感。试过「抬灰填充」（变灰盒子贴在宇宙上）、「发光顶沿」（脏 3D 斜面）均显廉价、被 PM 否。
决策：用 `UIVisualEffectView` 磨砂（**仅空态 + 深色**，空态是固定浮卡、无拖拽/吸附 → 零性能风险、无过冲漏图），让 MapKit 地球从卡后透上来 = 真实景深。⚠️ 状态：实现过、用户验过好看；模拟器疑似命中「按钮下方点不动」伪影（真机正常）**待真机最终确认**；尚未由我单独提交（与在途 HomeView/FX 纠缠）。

## 2026-06-18 备用图标渲染 / xcstrings 噪声 / 真机启动崩溃定位

### 备用图标必须带「实体尺寸渲染」，不能只给单张 1024
原因：`setAlternateIconName` 在桌面渲染要求 bundle 里**真实存在**桌面尺寸（120/180）的图标渲染。单张 1024「新格式」只对**主图标**有效（系统运行时降采样），备用图标拿不到 → 切换静默回退主图标。
决策：`IconCat`/`IconDog` 用 `sips` 从 1024 生成全尺寸（20–1024，iPhone+iPad），改经典多尺寸 `Contents.json`。`assetutil` 验证渲染含 120/180、模拟器实测桌面图标切换成功。**新增备用图标时必须给全尺寸渲染，不能只丢一张 1024。**

### xcstrings 重排噪声用 git clean filter 根治（而非每次手工还原）
原因：6 万行 `Localizable.xcstrings` 有两个写入者（Xcode 规范排序 vs 脚本/文本插入顺序），基线一偏离、下次 Xcode 一碰整篇重排出巨 diff，反复发生。
决策：装 git **clean filter**（`scripts/xcstrings-normalize.py` + `.gitattributes`），在 git 边界把 catalog 规范化成单一确定顺序——任何写入顺序经 clean 后字节一致，重排 diff **结构性消失**，真实文案改动照常显示。⚠️ filter 命令在 `.git/config`、不随仓库提交，**换机/重新 clone 须重设** `git config filter.xcstrings.clean "python3 scripts/xcstrings-normalize.py"`。优于之前 CLAUDE.md 记的「脚本须匹配 Xcode 序列化格式」——那靠纪律，这靠结构，更稳。

### 真机启动崩溃（`_xpc_init_pid_domain`）判定为环境/工具链问题、非 app 代码
原因：另一台电脑 Xcode Run 到真机启动即崩，`OS_dispatch_mach_msg _setContext:` unrecognized selector。真机 `bt` 显示崩溃全程在 `dyld → _libxpc_initializer → _xpc_init_pid_domain → objc_defaultForwardHandler → _objc_fatal`，**在 `main()` 之前、栈里无一帧 app 代码**；且重启手机能恢复（代码 bug 不可能被重启修好）。
决策：不改 app 代码。判为「那台 Mac 的 Xcode 版本 < 手机 iOS 版本（缺 Device Support）」或设备脏状态。对策＝升级该 Xcode / 改用本机（Xcode 26.5）装机 + 手机删 app 重启重装。**方法论留痕**：遇到诡异 selector 崩溃，先看 `bt` 判断「崩在系统库 init 阶段、app 代码还没上场」=环境问题，别往业务代码上猜（本会话一度误锚到已修的 diffable 崩溃）。

### 切图标系统弹窗的标题/间距不可控、不修
原因：该弹窗由 iOS 在 `setAlternateIconName` 成功后自动呈现，app 仅调 API、不创建弹窗，弹窗布局全由系统排版。
决策：不修。仅靠私有 API 才能抑制系统弹窗，违反「禁止私有 API」铁律。我们能修且已修的是图标渲染本身（桌面 + 弹窗内图标都已正常）。

## 2026-06-18 时间轴 marker：三档 → 两档

原因：原「停靠点实心彩圆 / 交通描边空心圆 / 住宿裸图标」三档里，**交通的描边空心圆显悬空、像按钮、与停靠点不成一家**（用户反馈丑）。
决策：交通改用**与停靠点完全同款的实心彩圆**（`systemBackground` 垫底 + `dayColor.opacity(0.15)` 轻染 + 图标，**28pt + 13pt 图标，与停靠点同尺寸** —— 起初试 24pt 略小，但视觉不齐，按用户反馈统一为 28pt）。marker 收为**两档**——**实心彩圆 = 离散事件**（停靠点 + 交通）、**裸图标 = 跨度**（住宿，最轻）；类型靠图标+颜色区分，不靠容器形状变花样。**地图端点**仍用「白底描边圆」（地图瓦片上需高对比，属另一语境，不并入）。回写 `design-system.md` §交通连接行 / §时间轴对齐。

## 2026-06-18 照片回溯行程 · 性能/隐私/入口迭代

### 长行程滚动卡顿：根因是 focused 天回写触发整页重建，改「滚动停下才回写」
原因：collection 滚动中持续回写 `focusedDayId` @State → `ItineraryView.body` 整体重算（daySections 逐天 timeline + 地图全标注 + 快照）。长行程×多 stop 下连续触发几十轮 → 卡死。
决策：focused 天回写移到滚动结束（`scrollViewDidEndDragging/Decelerating`），滚动过程零 body 重算。代价=日历条高亮滚动停下才更新（可接受）。更深的地图标注/daySections memoization **留真机 profile 再动**，不盲改即将上线的核心视图（遵 CLAUDE.md「两次没解决就停手、用可观测手段」）。

### 单次导入上限 40 张 + 可多次导入
原因：一次生成上百 stop 会压垮长行程列表，也拉长处理耗时/内存。
决策：`maxSelectionCount = 40`；落库「追加」语义，想补更多就多次导入。用产品策略兜住性能，而非放任单次灌入。

### 入口弱化进「更多」菜单
原因：旅行后补行程的人偏小众，且功能涉相册权限——隐私敏感用户占多数，不宜把入口放显眼处。
决策：从行程页直出按钮 → 右上角 `ellipsis.circle` 菜单项「用照片还原行程」。仅有日期行程显示（无日期行程没日期窗口可过滤）。

### 隐私姿态：端上处理、零上传、只存缩略图 → App Store 隐私可填「未收集」
原因：照片/位置全程不离开设备，只派生本地缩略图。Apple「收集」定义=数据离开设备。
决策：隐私问卷填「未收集」；`PrivacyInfo.xcprivacy` 不加 Required-Reason API；首屏加隐私安心文案。**前提**：一旦做云同步/上传含照片，结论失效、必须回改。详见 `docs/photo-trip-launch-checklist.md`。

### 零相册授权：仅用 PHPicker、直读所选图 EXIF（用户当场拍板，已落地）
原因：请求全库 `.readWrite` 才能读 `PHAsset.location` → 触发「访问所有照片」弹窗，是隐私敏感用户（本功能主力人群）的最大顾虑。
决策：**不请求授权、不碰 PHAsset、picker 不传 `photoLibrary`**——`PhotosPickerItem.loadTransferable(Data)` + `CGImageSource` 直读 EXIF（GPS/时间）+ 缩略图。彻底无弹窗，且与系统相册同源（消除「有位置却读不到」）。删 `PhotoLibraryAccess.swift`、移除 `NSPhotoLibraryUsageDescription`。取舍：逐张载入原图数据略重（40 张上限兜住）；放弃 assetLocalIdentifier（不绑库）→ 本版不做「回相册看原图」，符合零授权取向。这是 Apple 推荐的隐私最佳实践。

## 2026-06-17 照片回溯行程（spec: `photo-trip-reconstruction.md`）

### 复用既有行程结构，不为「回溯」另起数据模型
原因：回溯生成的产物本质就是「天 + 有序地点」，与正向手排同质。
决策：生成物 = 普通 `ItineraryDay`/`ItineraryStop`，落库后与手排行程完全一致（同页查看/编辑/导出）；照片是 `ItineraryStop` 新挂的一层 `StopPhoto`。来源标记放 **stop 粒度**（`fromPhotos`）而非整趟——一趟可手排+回溯混合，stop 粒度更准；「该趟含照片地点」由 `stops.contains{$0.fromPhotos}` 派生。

### 坐标系：境内必转 WGS-84 → GCJ-02，按 storefront 门控（非按坐标几何）
原因：EXIF GPS 是 WGS-84；项目库内坐标在大陆 storefront 下存 GCJ-02（Apple/高德直传）。直接写 EXIF 坐标 → 境内照片地图整体偏移几百米、反向编码编错街区。
决策：仅 `isChinaStorefront` 时转（`CoordinateTransform`，纯几何 nonisolated，境外自动 no-op）；门控用 storefront 不用坐标包络框——非大陆设备 MapKit 全程 WGS-84、不应转。天安门偏移 556m 验证正确。

### 照片存储：缩略图字节入库 + 原图引用相册（不囤原图）
原因：囤原图体积爆炸；纯引用则换机/删图后挂空。
决策：`StopPhoto` 存 `assetLocalIdentifier`（回相册取原图）+ `thumbnailData`（小图随库/备份走）。备份**带缩略图字节**（CLAUDE.md：关系图外的字节必须显式带上），但**分享/导出行程不带照片**（隐私+体积，`Backup*` 新字段默认 nil、分享路径不填）。对标 Apple 自家做法。

### 生成结果是「草稿」不是「结果」——预览页必经，绝不自动落库
原因：聚类永不可能 100% 准；体验命门是「90% 自动 + 那 10% 改得顺手」，而非追求算法满分。
决策：聚类产物先以内存草稿（`PhotoItineraryDraft` 值类型）渲染预览页，点「保存」才经 `TripStore.importItineraryFromPhotos` 批量落库；顶部文案「保存」非「完成」，暗示初稿可改。

### 编辑用菜单动作，不用拖拽手势（本版）
原因：自定义跨卡片拖拽合并/拆分易与 List/ScrollView 手势冲突、脆。顺着框架、不对抗（CLAUDE.md）。
决策：合并/拆分/挪照片走选中后的菜单动作，稳、零学习成本；拖拽手势留作后续打磨。离群单点**不自动丢待整理**（避免误删真地点）——宁可多生成让用户删。

## 2026-06-16（晚）日历叠加层 + 一连串交互/视觉决策

### 日历事件叠加层：只读叠加、隐私红线由「不入 model」构造保证（spec: `itinerary-calendar-overlay.md`）
原因：旅行期日历常含行程相关事件（节假日/订位/演出），但也含工作/私人事件；且 Carry 能分享/导出行程，混入会泄露隐私。
决策：① **opt-in + 用户勾选日历**（不替用户猜哪些算行程相关）；② 事件**只活在视图层临时查询、永不写进 `TripBundle`/SwiftData** → 分享/导出/备份从源头取不到（构造保证，非「记得过滤」）；③ 排除 `carry://` 自写事件防回环；④ 首次默认勾「只读公共日历」（节假日类，非生日/非可编辑）——节假日是公开信息、零隐私，且那个默认勾教用户「这些可勾选」。
放弃：Tripsy 式全量倒入（噪音 + 隐私）。

### 点日历事件 → Carry 内详情浮层，不跳系统日历
原因：行程规划是核心页，误触跳出系统日历体感差。原则：**除导航必需外，尽量不让用户跳出 app**。
决策：点事件弹 `CalendarEventDetailView`（日历名 + 标题 + 日期 + 全天/时区，只读）；删掉 `openInSystemCalendar`。

### 设置多选：默认勾选教可供性，不堆一列开关
原因：一列开关指示性强但太重、牺牲美感（用户反馈）。
决策：改回轻量勾选样式 + **首次默认勾节假日**——默认那个勾既让用户一眼看出「可勾选」，又因节假日公开零隐私默认显示合理；个人/可编辑日历默认不勾，隐私最稳。

### 住宿条：去盒子 + 接入按天分色（用颜色区分层级，不用盒子）
原因：住宿的灰底 pill 内边距把图标/文字顶离时间轴对齐网格（north-star §5）——先后造成「图标歪」「文字没对齐」两次问题。
决策：去掉 pill，床图标落 rail 列、文字落内容列、与停靠点同列；床图标**染当天色**（接 `ItineraryDayPalette`，进 Carry 日间色系），比纯灰暖、仍裸图标比停靠点轻。借 Tripsy「用颜色」而非它的「用盒子」。

### dateless 行程：空态引导 + 单天标题「想去的地点」
原因：dateless 永远只 1 天、本质是先收集想去的地方；「Day 1」暗示了不存在的多天日程，且空行程「Day 1 + 添加」很空旷。
决策：① 整趟空 → 空态（图标 + 「想去哪些地方?」+ CTA，并抑制地图自带邀请避免双 CTA）；② 单天标题 dateless 时显「想去的地点」（有日期仍显真实日期）。改日期后地点留第一天（`syncItineraryDays` 既有行为）。

### 「地点排序」提到行程面菜单第一位（本面专属操作置顶）
原因：规划核心流是「先加一堆地点 → 统一划分到每天」，地点排序是本屏主任务；且打包面本就「本面专属操作置顶 → 再行程级通用操作」，行程面原把它埋在第 4 位、破了规律。
决策：行程面菜单首项 = 地点排序（≥2 地点时），与打包面同构。

### 空 section 拖入：补占位落点行（diffable 原生重排的通用解法）
原因：`UICollectionViewDiffableDataSource` reorderingHandlers **无法把 item 拖进 0-item section**（落点解析不到）→ 空天拖不进。
决策：空天补一行 `.emptyDayDrop` 占位（「拖到这里」虚线框），使 section 非空可接收落点；不可拖（`canReorderItem` 仅 `.stop`）、提交时只收 `.stop` 被天然过滤。推广：凡需拖入可能为空的 section，补占位行是稳妥解。

### DEBUG 预览开关不跨启动持久化
原因：「模拟首页空态」误开后值存进 UserDefaults、每次启动都空屏，而 Xcode 重装不清 UserDefaults → 重装也不好（用户踩坑，排查耗时）。
决策：这类**一次性预览开关每次启动无条件重置为关**（init 直接 `=false` + 清 key），不读存储值。推广：调试预览类 flag 默认 session-only，绝不跨启动持久化——避免误开后伪装成「app 坏了」。

## 2026-06-16 交通录入：Type 为单一权威 + 表单自适应（交互打磨）

### 问题
`+` 菜单选一次类型、交通表单内 Type 又能改一次，两者会打架；且改 Type 后整屏不跟着变（火车却让填航班号/航站楼）——违反 north-star §2/§7「界面须反映自身状态、不留会骗人的死控件」+ 单一真源。

### 决策（用户在「① 自适应 / ② 锁死」中选 ①）
表单内 Type 选择器作**唯一权威**，`+` 菜单只是「快捷种子」。改 Type → 标签 + 字段可见性**整屏切换**：
- 承运方：航班=航空公司 / 火车·巴士·渡轮=运营商 / 租车=公司 / 其他=承运方
- 班次号：航班号·车次·…；**租车隐藏**（无班次）
- 站点：机场 / 车站 / 港口 / 取车·还车地点 / 地点（含搜索 sheet 标题同步）
- 代码、航站楼/站台：**仅航班、火车显示**（航站楼↔站台分别命名）；段头租车=取车/还车
- 座位：**租车隐藏**

理由：与统一数据模型 `TransportSegment + mode` 同构（UI 镜像 model），选错可就地改、不丢数据，且巴士/渡轮/租车/其他这 4 个「只能从 Type 到达」的模式无需把菜单堆成 8 项。
**否决 ②**（锁死）：更简单但牺牲灵活性与可达性，不够 ADA。
落地：14 个自适应标签 key × 9 语言；旧合并键 `itinerary.transport.field.terminal` 改名后成死 key，已删。

## 2026-06-16 距离单位设置 + 优化入口移到 day header

### 距离单位：三档「自动 / 公里 / 英里」，默认「自动」跟随设备地区
原因：距离原由 `MKDistanceFormatter` 按设备 locale 自动选公里/英里，用户**无法手动切换**（设备美区但习惯公制、或反之时无出口），全球化本地化体验不完整。
决策：新增 `DistanceUnit`（automatic/kilometers/miles，镜像 `AppearanceMode`），`@AppStorage("distance_unit")` 默认 `automatic`。`.automatic → MKDistanceFormatter.units = .default`（交回 locale）→ **设备地区默认零回归**。设置「个性化」后新建「通用 / General」分组承载，交互对标「外观」行（confirmationDialog 三档）。
放弃：两档（公里/英里）——会丢「自动跟随」语义，用户换区不会自动变。

### 距离展示统一走单一格式化入口 `CarryDistanceFormat`（消灭两套 formatter）
原因：改前有 2 个独立 `MKDistanceFormatter`（`ItineraryView` 全局 + `OptimizeRouteView` 自建）、3 个展示点，单位偏好若只接一处会口径分裂（根因门「覆盖所有触发路径」）。
决策：抽 `CarryDistanceFormat.string(meters:unit:)` 为全 App 唯一入口，两处都改读同一 `@AppStorage`，切换实时重渲染。**每单位一个固定的全局 `let` formatter**（metric/imperial/default 各一）——既缓存（不每次 new、避滚动热路径分配）、又无 `.units` 跨调用 mutation/竞态。
放弃：① 单个全局可变 formatter 每次改 `.units`（主线程虽安全但语义脏、有竞态隐患）；② 每次调用 new 一个（初版，per-leg 分配、是相对原缓存的性能回归，code-review 时改掉）。

### 「Optimize order」从每天列表底部移到当天 day header 尾部
原因（north-star §1/§2/§9）：原内联灰行在列表**底部**——地点越多越该用、却被顶得越靠下（相关性与可达性反向）；与高频 `Add` 等重抢戏；对齐进时间轴「地点列」后语义上像「路线里又一个节点」（归错类）。
决策：移到 day header 尾部（对齐 Apple section-header accessory）。header 吸顶 → 始终可达；中性 secondary 色 = 工具非主 CTA；门槛沿用坐标点 ≥4、排序模式隐藏；垂直内边距压到最小使各天 header 等高、点击区横向铺开补回。
放弃：① 保留原内联位置只调视觉——不解决「最该用时最难够到」的核心悖论；② 把它与 trip 级「地点排序」（手动、跨天、整趟）合进一个 day 级菜单——**作用域不同**（自动单天 vs 手动整趟），合并会混淆、且为单动作包菜单是多余 chrome。

## 2026-06-16 费用记录 + 本位币 + Trip Book 花费沉淀（spec: `itinerary-cost-tracking.md`）

### 费用的真相 = 金额 + 原币种；本位币等值存「快照」而非实时折算（推翻 spec 初稿默认）
原因：功能定位是「旅行资产沉淀」= 长期记忆。纯实时折算在高波动币种下会算错历史值（近年 JPY 对 CNY 波动 >30%）——「我 2024 年那趟日本花了多少」会被今天的汇率扭曲。
决策：每笔永久存 `costAmount + costCurrencyCode`（用户实付、永不丢）；另存 `costHomeAmount` = 录入时按当时汇率折算的本位币快照。Trip Book 优先用快照、缺失退实时折算、再缺则诚实标注「未计入」。
放弃：纯实时折算（模型最小但失真）；逐笔存汇率（用快照更直接）。

### 每笔费用可单独带币种（多币种），不强制统一本位币
原因（用户拍板）：出国时航班记 CNY、酒店记 JPY 是真实场景；强制统一要用户自己心算换算，违背「顺手记录」。
决策：每笔 = 金额 + 币种（默认本位币、可改任意）；Trip Book 用汇率折算回本位币聚合。
放弃：单币种（简单但出国记账不真实）。

### 改本位币时重算所有快照（单一不变式）
原因：本位币可改；若快照停在旧币种，Trip Book 会把不同币种快照混加 → 错。
决策：改本位币 → `TripStore.recomputeCostSnapshots()` 从**原始** `costAmount + costCurrencyCode` 按当前汇率折算成新本位币、覆盖快照（绝不「折快照的快照」）；取不到汇率 → -1 退实时折算。不变式：`costHomeAmount` 永远以当前本位币计。改币种属低频操作，重算成本可接受。

### 本位币单一真源 `preferred_currency_code`；ExchangeRateManager 升共享单例
原因：原 `ExchangeRateManager` 是 `DestinationInfoView` 局部实例、base 写死设备 locale；费用折算要在录入 / Trip Book / 改币种三处复用。
决策：`ExchangeRateManager.shared` 单例，base 读 `preferred_currency_code`（未设回退 locale）；目的地汇率屏与费用折算口径就此统一。币种名走 `Locale.localizedString(forCurrencyCode:)`、不进 xcstrings。

### Trip Book 反转「坚决不做花费」→ 做
原因：`trip-book.md` 原断言「Carry 零记账字段、坚决不做花费」——前提是「无数据」。现费用是用户主动录入的行程数据，前提不再成立；记账是「数据沉淀 → 黏性」核心。
决策：Trip Book 加「总花费」卡。仍克制：只按实体类型（交通/住宿/地点）聚合，**不做** Tripsy 的消费分类标签 / 分摊 / 预算 / 账单导入。已在 `trip-book.md` 标注反转。

### 花费卡视觉：比例带用单一烟蓝三档深浅、去分隔线（north-star ADA 自审后定稿）
原因：第一版照搬 Tripsy 是「一列数字」，glance 读不出构成（north-star §2）；满宽分隔线是 chrome 堆叠（§1）。
决策：总额下加 8pt capsule 比例带（交通/住宿/地点占比），用 `CarryAccent` 100%/55%/28% 三档透明度编码——守单一强调色纪律（§4），**不分配不同色相**；图例行去分隔线，靠圆点 + 间距 + 右对齐成行。多币种折算前缀「≈」、未折算诚实脚注。已回写 `design-system.md` §费用/货币。

## 2026-06-16 行程地点详情：交通方式导航 + 收尾修复

### 交通方式采用 Path C（选择器 + 联动调起，不在 App 内显时长、不接路由 API）
原因：参考 Tripsy「旅行时间」与一款大陆 App 评估后，否决「App 内显示各方式时长」——Apple `MKDirections` 枚举只有 automobile/walking/transit、**无骑行**，算不了骑行时长；要补齐须接高德/百度路由 Web API（第三方依赖 + 坐标/限流/隐私），用户明确**不接 API**。
实现：详情路程模块加交通方式选择器，选中即**联动** Get Directions 调起外部地图的方式（避免「选骑行却调起驾车」的割裂）。`MapNavigationApp.supports(_:)` 决定 List 过滤、`open(_:mode:)` 各家拼方式 URL；到下一站直线距离（离线瞬时）保留。过滤在视图层就地做（复用 onAppear 缓存的已装列表，不重跑 `canOpenURL`）。
放弃：App 内显时长、接路由 API、App 内画线 / turn-by-turn。

### 公交纳入（反转 spec「不做公交」）——因其支持面与骑行相反
原因：骑行的短板是 Apple（唯一不支持，须在选骑行时隐藏）；公交相反——四家 deep-link 文档上**都支持**（含 Apple，Apple 有 transit 只是无 cycling）。Path C 不显时长，公交「调起外部地图、班次由地图自带」与其它方式一致，纳入成本低、更完善。
实现：加 `.transit`；`supports` 公交暂全 true、**待真机实测各家是否正常调起**再定稿过滤；选择器 4 段、文字 `minimumScaleFactor(0.8)` 防长语言/窄屏破版。
放弃：在 App 内显示公交时长 / 班次（同 Path C）。

### 「内容贴合」的 detent 补偿常量必须随页面 chrome 变更同步重算
原因：`StopDetailView` 的 `.height(contentHeight + 72)` 中 `+72` 当初含导航栏 ~44pt；后来移除 NavigationStack（关闭 X 内联进头部）却没同步减，导致 Edit 按钮下方凭空留白。
教训：凡「内容实测高 + 固定补偿常量」驱动的 detent/布局，补偿常量的每一项都对应一块具体 chrome（导航栏、拖拽指示、安全区…）；移除/新增 chrome 时必须回头重算该常量，否则留白或裁切。本次重算为 `+28`（仅 home-indicator 气口）。

### 不同字号文字「读成同一行」用 `.center` 垂直居中，不用 `.firstTextBaseline`
原因：名称（body）+ 右侧时间（caption）共享基线时，小字号的视觉中心落在大字中心**之下**，看着「偏下」。
教训：一对不同字号、需读成「同一行」的文字（名称—值、标题—时间），用 `HStack(alignment: .center)` 让视觉中心对齐；`.firstTextBaseline` 只适合同级排版的连续文字流。已同步进 design-system §Typography。

### `open()` 多分支映射用穷举 switch、不留 `default`（编译期兜住「加方式漏改」）
原因：`open()` 对四家地图各有一段 `switch mode` 映射 URL 参数。Apple 分支原用 `default` 退化驾车——将来加第 5 种方式时会**静默**走 default、产生错误交通模式且无编译报错。
教训：这类「枚举 → 每分支映射」若漏一个 case 会静默出错，应穷举所有 case（不留 default），让编译器在加方式时强制在每处显式处理。高德/Google/百度本就穷举，本次把 Apple 也改穷举（骑行已被 supports 过滤，显式写退化驾车）。

## 2026-06-15 行程交通段 + 住宿：「节点 + 边 + 跨度」数据模型（借 Tripsy，呈现克制）

> 起因：行程规划要做完整，并为「签证行程单导出」打底。原模型「万物皆 `ItineraryStop`（单坐标点）」语义错位——航班是两点间的移动、住宿是跨若干晚的跨度，塞进单坐标点会丢到达信息/跨度。spec：`itinerary-transport-lodging.md`。

- **三类对象**：节点 `ItineraryStop`（点，不动）+ 边 `TransportSegment`（航班/火车/巴士/渡轮/自驾：承运方·班次·起讫站+代码+坐标+时区+航站楼·跨天起降·座位·确认号）+ 跨度 `LodgingStay`（横跨 N 晚、归 `TripBundle`、用 day sortOrder 锚定）。**借 Tripsy 的正确数据模型，但呈现/范围用 Carry 克制**（不抄费用分摊/协作/邮箱解析）。
- **未来航班动态预留**：`TransportSegment.liveStatusData`（JSON）现留空，将来接航班 API 只填充不改表。航班动态本身需外部 API、本轮不做。
- **时间轴排序规则**（与「地点排序」手动重排不冲突）：停靠点**始终保持手动 sortOrder**，绝不因时间被重排；**设了出发时间的交通段按时间「就位」**插入停靠点序列（carry-forward 基准），解决「带时间的航班排在最后」；未设时间的交通段留在添加处。交通/住宿**不可手动拖**（重排模式只动 stop），故按时间就位是交通唯一合理定位。
- **住宿统一走跨度 `Stay`**（不做「单天 lodging 点」），三态呈现：入住日「入住·名称」(+时间)、退房日「退房·名称」(+时间)、过夜中间天极轻灰条。利于签证文档「每晚住哪」汇总。
- **入口**：每天底部统一「+」Menu → 地点/航班/火车/住宿（对标 Tripsy），时间轴是一切的家。
- **地图**：航班画**大圆弧虚线**（`contourStyle: .geodesic`）区别市内实线路程；起讫端点加轻量 mode 图标标记；取景/空态判定纳入交通端点坐标。
- **健壮性铁律（本轮踩坑）**：① **`UICollectionViewDiffableDataSource` 的 item identifier 必须全局唯一（跨 section 也不能重复）**——住宿跨 N 天时 `.lodging(stay.id)` 在多 section 重复直接崩；行 ID 改 `.lodging(stay:day:)` 带天维度。② **改行程日期不丢数据**：`syncItineraryDays` 缩短天数时，交通段须同停靠点一起挪到保留天（否则随删天级联删除）；住宿 `checkInDayOrder` 越界夹回有效区间。
- 已合并 `main`（merge `4cacbc8`）。

## 2026-06-15 签证行程单导出：仅 PDF · EN/ZH 二选一 · 不碰护照号

> 起因：用户要「出国办签证那种标准行程单」。spec：`itinerary-export-document.md`。

- **诚实定位**：这是签证材料里的**一份「行程说明」**（day-by-day plan），**不是**机票/酒店预订凭证、不声称官方效力、不编造预订号。对外话术须准确，避免投诉/审核风险。
- **只做 PDF**：使馆只认可打印 PDF。**不做 Excel**（使馆不收）、**不做 JPEG**（海报已覆盖「好看可分享图」）、**不做中英对照并排**（可分别导 EN/ZH 两份覆盖，价值重叠、违背克制）。
- **双语 = 导出时选一种**（EN 交签证 / ZH 自留）：文档框架文案 + 日期格式按所选语言渲染，**用户数据（地点名/航司/酒店名）原样带出、不翻译**。
- **🔴 文档固定文案用代码内 EN/ZH 字典（`ItineraryDocumentText`），不进 xcstrings**：xcstrings 走**设备 locale**，无法按用户**选定语言**取值；导出二选一故代码字典最简且正确。（推广：任何「按用户选定语言而非设备 locale 渲染」的固定文案都该走代码字典。）
- **申请人信息**：姓名 + 出行目的，**坚决不碰护照号**（敏感个人信息 → 触发 PIPL 义务）；导出时填、`@AppStorage` 本地存、不上云、不强制。
- **概览地图**默认带上、可关（复用 `TripShare.renderRouteMap`）。文件名 `行程名_Itinerary_yyyyMMdd.pdf`（手拼日期，避免 `.formatted` 按 locale 重排成 MMddyyyy）。
- 实现：`ItineraryPDFRenderer`（`UIGraphicsPDFRenderer` A4 分页：头部+概览图+逐日+住宿汇总+页脚页码）；入口在行程「…」菜单与分享/发送并列。

## 2026-06-15 行程地图预览：地图永不为空（替代灰盒占位）

> 起因：当天无地点时地图位是灰渐变占位盒，「空空的」且常谎称整趟空白。north-star §1 内容为王 / §9 顺平台（Apple Maps 地图永不是灰盒）。

- **三档真地图**替代灰盒：① 当天有地点 → 正常路线图；② 当天空、整趟别处有地点 → 铺**整趟真地图、其它天针/线淡化** + 「这天还没安排地点」；③ 整趟空、目的地已解析 → 居中**目的地真地图**（复用 `TripBundle.latitude/longitude`）+「添加第一个地点」邀请；④ 兜底（整趟空且目的地未知）→ 才用原灰盒。
- **可展开门控**：仅 route/context（有真实路线）可点开全屏；destination/placeholder 不可点。
- 顺带删「单点·再加一个就能连线」提示（针自解释 + 添加入口就在下方，多余 hand-holding）。已在 `main`。

## 2026-06-15 首页 Sheet 自动吸附改「克制果冻」回弹（放开旧"无回弹"禁令）

> 起因：用户要下拉收起/上拉展开松手落位带一点回弹。历史包袱：playbook §5/§13 曾规定"直接吸附必须单向无回弹"。

- **决策**：直接吸附分支从 `dampingRatio 1.0`（临界阻尼·硬停）改为**方向不对称欠阻尼 spring**——展开到顶 `0.74 / 0.52s`（多一点"到位"精神气）、收起到底 `0.82 / 0.46s`（贴底缘更收敛）。做**克制 spring**、非明显果冻（对齐 north-star 克制/优雅）。
- **为何能推翻旧禁令**：旧禁令针对的是**多驱动竞争**导致的"先上弹/中段跳变"伪影，其根因已随单一 CA 通道 + 内容固定尺寸 + 删 mask 重构**消除**。现过冲由**唯一** animator 干净插值、只经唯一漏斗 `placeSheet`，是设计效果非伪影。仍禁止：第二驱动源、动画开始即推 `shapeProgress` 终态、`startSnapShapeFollow`。
- **几何安全**：展开过冲把底缘推出屏幕下方、收起过冲只放大浮动间隙，均**不漏 MapKit**（真机已确认）。底栏搭同一 animator → 一起弹、免费同步。
- **打断安全**：`beginInteractiveControl` 先增 generation 再停 animator（作废过期完成）+ 读 presentation 层钳回合法区间。
- 真机验收通过 + 全盘审计无 bug/崩溃/死锁/泄漏/回归。代码 commit `977b713`；spec：`home-sheet-snap-spring.md`（Shipped）；playbook §5 已加放开注脚。

## 2026-06-14 首页底栏随 Sheet 同步缩放：底栏移进 FX 控制器、同一 animator 驱动

> 起因：首页 Sheet 上拉/下拉本就有缩放，用户要底部三键栏（搜索 / 行程册 / 创建 FAB）跟随**同步缩放**。先做了基线近似版（commit `b2be676`：底栏留在 SwiftUI、`.scaleEffect` 追同一目标），用户选「终极/像素级一致」方案。

- **决策**：底栏从 HomeView 的 `.safeAreaInset(edge:.bottom)` **移进 `FXSheetViewController`**，与卡片由**同一个 `UIViewPropertyAnimator`** 驱动 → frame-perfect 同步。两套引擎（SwiftUI 动画 vs Core Animation）只能"高度近似"，快速甩动时初速度对不齐；同 animator 是唯一能根除的架构。
- **机制**：缩放在唯一漏斗 `placeSheet` 里对 `barView` 施加**底边锚定**同 `scale` transform（`translate(0,(1-s)·h/2)·scale(s)` ≈ `.scaleEffect(anchor:.bottom)`）。吸附时 `placeSheet(at:target)` 在 snap animator 块内被调用 → 底栏被同一 animator 插值；拖拽逐帧直接 set。**不引第二驱动源**（守 playbook §5）；删除基线的 `SheetScaleModel`/`onScaleChanged`/`BottomBarScaleSync`/`import Combine`，不留过渡件。
- **手势穿透取舍（已知、非 bug）**：底栏作 UIKit 兄弟视图后，「空白区返回 nil 让 pan 穿透到列表」与「透明背景吸 tap」二者**互斥**。选择保留 pan 穿透（用户明确要"从底栏上滑滚列表"），代价是三按钮间两条 ~14pt 空隙的点击会穿透到列表行——按钮各有 54pt 命中区夹住、死区极小、危害可忽略，故接受。
- **验收**：真机 + iPhone 17 Pro 模拟器双验收通过；全盘审计无 bug/崩溃/约束冲突/循环引用（详见 playbook §19）。
- **还原点**：`b2be676`（`git checkout b2be676 -- Carry/Views/CarryBottomSheetFX.swift Carry/Views/HomeView.swift`）。commit：`7a5a900`。

## 2026-06-14 分享行程：海报图（社交）+ 可导入文件（同伴），两条独立线

> 起因：Phase 2「分享行程」。形态选型 + 无后端下的同伴协作方案。

- **形态二分**：① 分享行程 = 渲染**海报图**（封面 + 按天时间轴 + 路线地图 + 水印），给所有人社交晒；② 发送给朋友 = **可导入 `.carrytrip` 文件**，给也用 Carry 的同伴。两个独立菜单项，受众/用途不同，不合并。
- **只带行程规划**：海报与 `.carrytrip` 都只含天/地点，**不带打包清单**（偏隐私）、不带背景图/个人库。
- **预览优先于直接分享**：点分享先弹预览页（让用户先被自己的行程图打动 = north-star §8；并可调「是否含地图」），再 `ShareLink`。海报渐进渲染（先无图、地图异步合入）。
- **路线地图**：`MKMapSnapshotter` 静态图 + 按天配色图钉/连线（白描边 casing）；大陆高德底图由 Apple 处理边界，合规。异步、失败/无坐标优雅降级。
- **导入冲突最优解（无后端）**：文件保留**发送方 UUID**；首次导入=新建，再次导入（同 UUID）=**更新该行程的行程规划**（替换天/地点、保留收件方打包清单）→ 同伴改了再发、对方能拿到更新，不堆重复。
- **文档类型注册**：Exported UTI `com.murphy.carry.trip`（conforms `public.json`）+ `CFBundleDocumentTypes` + `LSSupportsOpeningDocumentsInPlace=YES`（就地读原文件、不留 Inbox 拷贝）。
- **复用** `DataBackupManager`/`CarryBackup`（版本迁移现成），新增单行程 `makeItineraryShareFile`/`readSharedTripSummary`/`importSharedTrip`。
- 海报封面用 `FocalCoverImage`（焦点对齐 + 整图最小 cover）而非 `PositionedImage`——海报头与卡片宽高比不同，后者按裁剪区域缩放会过度放大、构图变怪。

## 2026-06-14 验收默认交给用户、不主动驱动模拟器自跑（写入 CLAUDE.md）

- 用户在场时 UI/交互验收**交给用户**（其模拟器 + 真机验收快、反馈即时、保真高）；仅当用户**明确要求**或**离开**（睡觉/暂离、无法及时反馈）时才自行用模拟器跑通自验。`xcodebuild` 编译验证**始终需要**、不在此限——约束只针对"启动 App + 点按 + 截图做功能/视觉验收"这类交互式自跑。详见 `CLAUDE.md`「重要约定」。

## 2026-06-14 编辑地点：「显示标签」与「地图位置」分离 + 时间段（开始/结束）

> 起因：用户发现编辑页改名只改纯文本、和地图不匹配，问「名称是做啥用的」；又提出时间该支持开始 + 结束。

- **决策（用户认可的设计）**：编辑页分两段——
  - **地点**段：名称是**可自定义的显示标签**（改名不动定位），地址只读 + 「更换地点」(relocate) 才改定位。relabel 与 relocate 彻底分开。section 标题用「**地点(Place)**」而非「位置(Location)」——含名称、语义为「这个地点」；footer 说明名称用途。
  - **详情**段：类型 + **开始 + 结束时间**（结束以现成 `stayMinutes` 存，不改 schema）。
- **时间留在编辑（可选）、不进添加流**：添加流保持快速捕获；时间是「选完地点之后」的属性，不适合像类别那样预设。
- **类别不强行与添加流一致**：编辑用原生 Form Picker（显眼可扫读），添加用搜索框尾部菜单（搜索优先）——两屏任务不同，差异是对的。
- spec：`itinerary-route-planning.md`。

## 2026-06-14 菜单 Picker「收起选中值」间距不可控 → 改自定义 Menu（通用）

> 现象：StopEditView 的 Type 行，下拉菜单图标↔文字间距正常，但收起后的选中值（✈️Flight）贴死。

- **根因**：原生菜单 `Picker` 两套渲染——下拉项走系统菜单（间距合适）；**收起选中值由系统按自己的紧凑排版渲染、无视选项里的自定义 `HStack(spacing:)`**，SwiftUI 不给控制。
- **解法（推广）**：需要可控图标↔文字间距的「带值菜单行」，把原生 `Picker` 换成自定义 `Menu`——收起值标签自己手搓（`HStack(spacing:6){图标·文字·chevron}`，accent 色），间距 100% 可控；下拉内仍放 `Picker`（系统菜单、间距好、带勾选）。整行作 Menu label → 点哪都能开，行为同原生。

## 2026-06-14 底部主按钮容器：实心 → 上沿渐变淡出（BottomBarScrim，超越「禁渐变」旧规）

> 起因：行程/打包页底部切换器加了「内容在栏下渐变淡出」后，用户认为该效果更佳、要全 App 统一；但 design-system 原有「底部主按钮容器一律实心、禁渐变」规范（曾据此把优化页钉条改实心）与之冲突。用户拍板：以 north-star（ADA 级）为准、采用渐变，规范随之更新。

- **决策**：底部 `safeAreaInset(.bottom)` 栏统一走 **`BottomBarScrim`** 修饰器（`ViewModifiers.swift`，单一真源）——顶部定高「透明→实心」渐变条 + 其下实心兜底（`ignoresSafeArea(.bottom)` 延到屏幕底边）。滚动内容在栏上沿柔和淡出，按钮坐实心、其下不透出内容。淡出色 = **该页背景色**（一级 `systemBackground` / 二级 chrome 同色系 / `CarrySubtleBackground` 上用 `baseColor`）故无缝。
- **为何推翻「禁渐变」**：原规则是针对 `.regularMaterial` 在深背景上偏亮成**色带**——根因是「材质」不是「渐变」。淡出到页面色的渐变无色带、且让内容优雅消隐，更贴 Apple 浮动栏。**本决策 supersede**「优化页钉条改实心（`CarrySubtleBackground.baseColor`）」那条：优化页同改用 `BottomBarScrim(CarrySubtleBackground.baseColor)`。
- **落地（整宽实心栏 → `BottomBarScrim`）**：行程/打包页切换器、`SuggestionPreviewView`、`ScenePickerView`、`TripInfoView`、`OptimizeRouteView`、`TripDateRangePickerSheet`（月历滚动内容淡出，取代原硬分隔线）、新建预览 Save（`PackingListView.saveTripButton`）。
- **第二套：浮动元素 → `bottomContentFade`**：玻璃/圆角浮动控件**不该被实心遮挡**（垫实心杀玻璃通透），改用「内容向页面底色消隐、浮动元素仍浮起」的 overlay 渐变。**落地**：`HomeView` 底部 glass 胶囊栏（手搓 `safeAreaInset` 栏，iOS 26 `scrollEdgeEffectStyle` 不认它、不生效，故走此法）、`ItemPickerView` 智能预览圆角浮条。
- **两者均为纯 `LinearGradient` overlay + `allowsHitTesting(false)`**：不用 `.mask`/`.blur`/材质 → 不触发离屏渲染、不挡点击、开销极低（关键选型，勿退回 mask/material）。
- 回写 `design-system.md` §「底部栏 / 浮动元素下的内容过渡」（两套模式 + 选型 + 性能）。

## 2026-06-14 行程页 日历 ↔ 列表 双向联动（防回授）+ 末日吸顶补偿

> 起因：行程页上方日历条与下方按天列表原本各管各——切日历不滚列表、滚列表不更新日历高亮，两者脱节。用户要双向联动。

- **机制（顺框架，不自造平行态）**：列表 section header 本就 `pinToVisibleBounds`，「吸顶」是 UIKit 现成的，只需把目标 section 滚到顶即可。正向＝切日历改 `scrollTargetDayId` → 滚该天 header 到顶；反向＝`scrollViewDidScroll` 算当前吸顶 section（仍有 cell 越过顶缘的最小 section，用实际 cell frame、对 estimated 高度稳健）→ 回写 `focusedDayId`。
- **防回授（关键）**：用 `lastScrolledDayId` 作正反向**单一真相**——反向回写时先把它写成新天，使随后 `update()` 判定「已在位」不再反手程序滚动；再加 `isProgrammaticScroll` 标志，正向动画途中屏蔽反向回写（否则穿过的中间天逐一误选、与动画对冲），动画结束 / 用户中途抓住列表时解除。这套切断了「程序滚动→didScroll→改选中→再程序滚动」环。
- **🔴 末日吸顶补偿**：最后一天地点少时下方无内容可顶、吸不到顶（agenda/日历类列表通病）。解＝按需补底部 `contentInset`，量＝`视口高 − 末段高`（与吸顶偏移在数学上对齐 `maxY == targetY`，不多不少）；够长的日子算 0 不补，故不凭空多空隙，内容增删后随 layout 落定重算。末段高用「首行 minY − header 高」反推，避开「末段恰好 pinned 时 header origin 失真」。
- 地图安全：`ItineraryMapView` 用 `Map(initialPosition:)`，`focusedDayId` 变只换当天的针、相机不跳，故列表滚动驱动选中天不会让地图乱漂。

## 2026-06-14 页面背景：铺一层统一底色，别让两块区域各自上色赌一致

> 起因：添加地点页（`AddStopView`）Light 模式顶部割裂——搜索框 band 与下方列表区交界一条硬边。

- **根因**：band 显式涂 `systemGroupedBackground`（灰紫），而 `.insetGrouped` 的 `List` **在 sheet 上下文里默认渲染成白底**（`systemBackground`），两块底色对不上。「两个区域各画各的底、赌它们一致」本身就脆。
- **决策（通用）**：需要整屏一致底色时，**铺一层统一背景**、让前景元素（搜索 band 等）只负责遮挡滚动内容，而不是依赖控件隐式底色去对色。落地＝`List` 加 `.scrollContentBackground(.hidden)` + `.background(Color(.systemGroupedBackground).ignoresSafeArea())`，band 保留遮挡底。语义色自适应，Dark 不受影响。
- 已回写 `design-system.md` §Sheet / Modal。

## 2026-06-14 首页搜索态保留「我的行程」大标题（连续感 > 冗余标题 / 裸搜索框）

> 起因：用户觉得首页搜索页（`HomeView.searchSheet`）只有搜索框、顶部显空，问是否缺标题。

- **判断**：① **不加**「搜索行程」式标题——与搜索框 placeholder 文字重复，是冗余噪音；② 也不维持「裸搜索框」（虽符合原生搜索态惯例，但解决不了用户的「空」）。**决策＝让首页「我的行程」大标题延续进搜索态**（标题在上、搜索框在下，30pt rounded 与首页主标题同号）——顶部不空、有页面归属感、接近原生大标题搜索，且标题非冗余（是首页标题「留住」而非新增重复）。
- 字号：用户确认维持 30pt（连续感优先；30pt 已小于原生大标题 34pt，不算大）。
- 对照：`AddStopView` 有「添加地点」标题是因为它是独立任务模态（标题答「我在干嘛」）；首页搜索是临时筛选态，语境不同，故处理方式不同、各自正确。

## 2026-06-14 优化路线：以「道路口径」判定是否改进（修订「MKDirections 只用于展示」）

> 起因：真机走查发现优化预览偶尔「当前 83km → 优化后 87km，节省 0 米」——优化后按道路反而更长。根因＝口径不一致：排序用直线（Haversine）搜最优、判定与展示却用道路（MKDirections）；直线更短的顺序换成道路可能更长。

- **决策**：「是否算改进」改用**道路口径**（在可得时），不再只是展示。优化器仍用直线快速搜出候选顺序（瞬时/离线）；只有候选**按道路确实更短**（省 >50m 且 >1%，与直线同阈值）才呈现「采用」，否则走「已是较优」、不给变长的优化。离线 / 6s 超时 / 失败 → 退回直线判定 + 「按直线距离」注脚。
- **不做**全程道路矩阵最优（N² 次 MKDirections、限流、离线失效；Apple/Google 靠服务端矩阵，客户端不现实）。
- **呈现（方案 A 渐进披露）**：进页地图 + 建议顺序**立即出**，仅「判定区」（节省/对比/CTA）随道路结果定调：computing→「计算中」+ CTA 禁用；improved→省距离 + 「采用此顺序」；notImproved→「已较优」+ 中性「完成」；unavailable→直线 + 注脚。地图/顺序全程不跳变。
- **实现**：`RouteOptimizer.isImprovement(original:optimized:)` 抽纯函数（直线/道路共用阈值，7 例独立验证）；道路计算与 6s 超时 `withTaskGroup` 竞速。零新增文案（复用 `calculating`/`optimal.*`/`done`）。
- spec：`specs/itinerary-optimize-road-gating.md`。

## 2026-06-13（补记）字体系统：角色制双字形（圆体=展示/数字/短标签，SF=密集正文/表单/系统控件）

> 起因：行程规划视觉审查发现「同屏混用 SF Rounded / 默认 SF」。north-star §3 定「Carry 的声音 = SF Rounded」，但「全 app 一律圆体」会让密集长列表可读性降、偏重偏童趣。

- **决策**：圆体不是越多越好——按**角色**分配双字形。**SF Rounded**＝展示型标题 / 数字（序号·计数·距离·价格·读数）/ 结构性短标题（Day 头·分区·卡片标题）/ 短突出标签（胶囊·chip·badge·浮层）/ 紧贴 hero 的副标题；**SF（默认）**＝密集列表正文 / 表单输入 / 长段落说明 / 系统控件（Form·Picker·navigationTitle·toolbar·Section）。口诀「被展示/醒目/数字/短标签→圆体；密集正文/表单/系统控件→SF」，拿不准默认 SF。依据：Apple 自家 Rounded 也只给数字/短标签/展示标题。这才是 §3「字形统一」的正确解＝一致遵守同一套角色规则、非同一种字形。
- **按钮子规则**：主 CTA 圆体；次级/工具动作、字段标签 SF。
- **落地**：行程规划三屏整屏对齐 + 全 app 自定义界面约 120 处走查对齐（含 Widget 锁屏/灵动岛）；系统 Form 设置页保持 SF。回写 `design-system.md` §Typography。

## 2026-06-14 搜索框收成单一组件 CarrySearchField（单一形态·描边主导）

> 起因：用户发现首页「搜索行程」圆角（24pt）与「添加地点 / 添加物品」（12pt）不一致，问是否该统一、以谁为准。

- **决策**：圆角统一 **12pt**（首页 24pt 是脱离 design-system 的孤例，拉回规范，而非迁就特例）；并抽共享组件 `CarrySearchField`（`ViewModifiers.swift`）把"形状 + 行为 + 来源"收成单一真源——根因是三处各写一份才会漂移。
- **表面方向（用户拍板）**：起初按上下文设了 `.plain/.grouped/.floating` 三表面枚举（怕分组背景上同色隐形）。浅色实拍后发现首页成了唯一"灰框"、三屏色调不齐。用户选**全部用描边主导 `.floating`**（systemBackground.opacity(0.84) + 细描边）——细描边让"白色半透明"在任何底色上都立得住（灰底=白底+描边、白底=描边定界），故无需分上下文。随即删掉 `Surface` 枚举（零调用死代码），收成真正单一形态。
- **关键认知**：纯实心填充才有"衬在同灰分组背景上整框隐形"的坑；描边主导式不受影响——这是能统一成一种表面的前提。
- **回写**：`design-system.md` §搜索框（组件 + 12pt/44pt 形状 + 描边主导唯一表面 + 通吃底色原理）。

## 2026-06-14 UIScrollView 重配判定：比 bounds.size，绝不比整个 bounds（bounds.origin == contentOffset）

> 起因：背景图构图界面选图后卡在填充态、无法缩放/拖动（用户报 bug）。回归来自重构 `a0d64b7` 把"配一次"的 `configured: Bool` 改成比较整个 `scrollView.bounds` 来决定是否重配。

- **根因 / 教训（通用）**：**`UIScrollView.bounds.origin` 就是它的 `contentOffset`**，随每次滚动/缩放而变。任何"用整个 `bounds` 判断视图是否需要重新配置"的逻辑，都会被用户的滚动/缩放误判为"变了" → 反复重配。这里的后果是每个手势都把 `zoomScale`/偏移重置回 `fillScale`，画面动一下就弹回。
- **修复**：判定与缓存都只用 `bounds.size`（`lastConfiguredBounds: CGRect` → `lastConfiguredSize: CGSize`）。需要"窗口真正改尺寸（sheet 转场落定 / 旋转）才重算"时，**永远比 size，不比 origin/整 rect**。
- **诊断纪律印证**：纯读码两次没定位（zoom 数学新旧一致，看不出问题）→ 按 CLAUDE.md §2 改用可观测手段，`NSLog` 跑模拟器一眼看出 `configured` 随 origin 反复触发、size 恒定。结论：盲猜第三次不如一条日志。

## 2026-06-14 确立 Carry Modal Convention + 创建/快速添加改模态

> 起因：UI 走查发现创建行程、快速添加物品用的是 push（层级导航），而它们语义上是"自包含任务"。借机把呈现方式（push / sheet / cover）按统一语义规范一遍。

- **规范（详见 `design-system.md` §Carry Modal Convention）**：① 创建新对象且完成后进入它 → `fullScreenCover`；② 对当前对象的子任务 → `.sheet`；③ 单字段 → `alert`；④ 层级浏览 → push；⑤ chrome：模态离开用取消/Done/X、禁用返回 chevron，cover/sheet 根步自带取消。
- **改动**：创建行程 push→`fullScreenCover`（commit `195f362`）；快速添加物品 push→`.sheet`（commit `bdcbb66`）。其余行程内子任务（编辑行程/场景/分类/提醒/背景图）经核对**本就是合规 sheet**，未改（不为改而改）。
- **全 App 模态总审计（2026-06-14 已完成）**：逐个呈现面按 5 条规则核对——创建/快速添加（已改）、行程内子任务（编辑行程/场景/分类/提醒/背景图/日期/MyItem/加地点/编辑地点/优化顺序）= sheet、设置子页（关于/图标/通知/灵动岛/经期/小组件）= push、设置/搜索/行程册/支持/路线图/地图全屏 = sheet。**结论：全部合规，无一处用返回 chevron 当离开，无需改动。** 唯一判断题：路线图以 sheet 叠 sheet 呈现（而同为信息页的「关于」是 push）——**有意保留 sheet**（路线图是展示型橱窗、堆叠质感衬它；关于是纯文字详情、push 合适，二者语义不同）。「取消」存在 `"Cancel"`/`"common.cancel"`/RoadmapL10n 多 key 的历史冗余，均有完整翻译、可正常工作，判定不值得为零收益去碰在途文件，保留现状。

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

### 按天分色：精简到 7 色 + 全色环铺开 + Day1 品牌烟蓝 + 易读性靠渲染（2026-06-20，2026-06-21 定稿）
背景：PM 先问扩到 15/31 天，再要求转暖色基调，真机一看后又嫌「暖色版后几天太像」，最后定稿为**全色环铺开**的 7 色、绿色打头。
判断（反转伪需求）：**不需要 N 个全局唯一色，只需「局部可区分」**——地图/时间轴上只有彼此挨近的天才需要区分。目标从「凑齐 15/31 个唯一色」改为「**N 色循环 + 任意连续 5 天可分**」，对任意天数都成立。
落地（最终）：
- **7 色、色相绕色环铺开**：`Day 1 烟蓝(品牌) → Day 2 万寿菊 → Day 3 棕榈绿 → 雪青 → 覆盆子 → 青绿 → 赤陶`（蓝/橙/绿/紫/莓红/青/赭红）。每天一个清楚不同的「颜色名」。CIEDE2000 floor **14.7**，相邻最差 ΔE≈20。前四天（蓝/橙/绿/紫）按用户偏好钉死，后三天求解、并避免覆盆子与赤陶相邻。
- **「暖色主导」被否决（关键迭代教训）**：中途做过暖色版（珊瑚/海蓝绿/胭脂粉/浆果红…），但**暖色只占色相环一小段**，挤 7 个必然出现「珊瑚/胭脂粉/浆果红三个粉红一家」——ΔE 数字够（14+）但作小色点/淡色调眼睛仍觉「都差不多」（真机实测被否）。**真正决定「看起来像不像」的是色相家族数，不是 ΔE 数字**。故放弃暖色主导，改全色环铺开（牺牲一点「暖度统一」换辨识度——多日导航辨识 > 色调统一，这正是当初破例上多色的初衷）。
- **Day 1＝品牌烟蓝**：曾一度让绿色打头（出行心情）、把烟蓝移到 Day 3；后用户决定 **Day 1 用回品牌色**（品牌延续性），绿色与烟蓝对调到 Day 3。对调后相邻最差色差反升（16→20，烟蓝不再挨雪青）。纯展示、无技术代价。
- **🔴 易读性靠「改渲染」而非「改颜色」（关键根因）**：色板里几个浅色（如青绿/赤陶/万寿菊）在白底上低于 WCAG 3:1，导致**地图针白色序号看不清**、浅色路线在浅地图上发虚。**试过加深颜色修对比度——必塌可分性**（浅色承载着亮度分隔维度：降饱和 floor→8.7，整组压暗→6.6）。根因在「渲染默认日色够深能托白字」这个错误假设。解：① 地图针序号改 `Color.legibleInk`（`AppearanceMode.swift`，按底色 WCAG 亮度自动取深/浅字）；② 浅色路线加暗 casing 衬底；③ 时间轴浅色图标/色点偏柔但有色圈+位置+序号共同标识、可接受、不动。**禁止再用「加深色板」修对比度。**
- **性能非问题**：取色是 `palette[index % count]` 的 O(1) 索引；纯展示层、零迁移。
- **维护铁律**：任何新增 / 重排 / 调色，先重跑 `scripts/itinerary-day-palette-solve.py` 复核、再回写 `ItineraryDayPalette`；前景元素永远不写死白色、走 `legibleInk`。

### 航班机场/航司名本地化：render-time resolution + 按需加载（2026-06-21，spec: itinerary-flight-name-localization.md）
背景：中文环境已保存航班的机场/航司名显示英文——多语言库（`airlines.json`/`airports.json`，9 语言）只用于搜索、没接显示层。
- **render-time resolution（核心）**：**存语言无关的「键」（IATA 码 / 航班号），显示时按当前语言查名、回落原文**——不存固定语言字符串。好处：跟随设备语言、切语言也变；确定性、零迁移、无新字段、无启发式。覆盖**所有显示点**（时间轴 / 详情 / 搜索卡 / 地图 / 导出 / Trip Book 花费 / 通知）。
- **不可变参考数据用 nonisolated 同步单一源，不用 actor**：`AirlineDatabase`/`AirportCatalog` 从 actor 改为 `static let` 懒加载的 `nonisolated enum`（项目 `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`，故纯数据/工具类型须显式 `nonisolated`）。搜索仍走 `AirportDatabase` actor（逐键扫表、要离主线程）读同一份 `AirportCatalog.all`——**数据与搜索引擎分离、共用一份、不重复加载**。
- **语言键解耦设备 vs 导出**：`Airline/Airport.localizedName(for languageKey:)` 核心；`displayName`=设备键（App 内）；导出走 `DocLanguage.nameLanguageKey`（所选语言、含**繁体 `.zhHant`**）。`ItineraryDocumentText.pick` 三参（繁体回落简体仅限繁简同字、有别的给地道繁体）。
- **🔴 按需加载 vs 预热（性能取舍，改动有效性审计的结果）**：曾为「机场名零闪」在**每次启动预热整个 1.6M 机场库** → 但这让**不用航班的用户也白付**每次启动开销，只为少数人省一次次要信息（详情里代码下方那行机场名）的轻微刷新。判定**不划算**：删预热、改**按需加载**（懒 `static let`，只在开航班详情/机场搜索时解码），详情用 `Task.detached` 把解码放后台。代价：首次开某航班详情时机场名那行一瞬「英→中」——次要、可接受。**结论：高频/用户真看的（航司名，225K 小库）随用随载；低频/次要的（机场全名）按需 + 接受微闪，不为它给全员加常驻开销。**

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

## 2026-06-22 行程「详情 + 编辑」视觉重构

### 设计语言：「编辑 = 详情的可编辑态」（非照搬版式，而是同一套设计语言）
原因：阶段 2 编辑态原先像通用 iOS 设置表单，与已打磨的详情页脱节。
决定：① 同画布（`carryCanvas` 灰）+ 同白卡，但**编辑是功能性表单**——地点/搜索行用**通用 `mappin`**，语义化 marker（钥匙/箭头/床）**只留详情**（详情=展示/仪式感，编辑=精确输入）。② **身份段以实体名作标题**：地点=Place、住宿=Lodging、交通=Flight/Car rental…（各屏一致的「实体名头」，非强行同字）。③ **图标「挣来才有」**：密集 More 表（座位/确认号/车型…）无图标；单一功能卡（cost/note/attachments）有前导图标；端点有 marker；时间 chip 等宽数字。④ 同一信息只显一次、在它该在的容器里（schedule：地点/景区进副标题、住宿因复杂进卡）。
放弃：把详情的「整段路线 hero」搬进编辑（内联编辑机场码/航站楼/时刻在紧凑 rail 里指向不清，是「为好看牺牲清晰」——航班编辑保留字段列表）。

### 电话在编辑态不露出（自动回填的辅助信息），但租车保留
原因：地点/住宿电话是搜索时从 map 自动回填的，没人会手敲；它属辅助信息。
决定：地点（`StopEditView`）/住宿（`LodgingEditView`）编辑态**移除电话字段**——电话仍由搜索/换地点自动捕获、保存原样带上、详情只读展示。**租车保留电话可编辑**——它是用户想手记的租车公司热线，未必等于取车点电话。

### 住宿添加 = 搜索优先 → 预填表单（不直接落）
原因：住宿原是「表单里有个搜索按钮」，与「添加地点（搜索优先）」不一致；且若选中即直接落，入住/退房只有 1 晚（多数住多晚）。
决定：新 `LodgingSearchSheet`——点「+」先进搜索（搜索即出结果），选中 → 解析坐标 → **push 进预填表单**（名称/地址带入，用户选入住/退房日期）→ 保存才落进行程；底部常驻「找不到酒店？手动添加」→ push 空表单。照搬航班 `FlightSearchSheet` 的「搜索 + 底部手动兜底」结构 + 地点的预填思路。`LodgingEditView` 加 `embedInOwnNavigationStack`/`onFinish`/`prefill`（与 `TransportEditView` 同款）以便被 push。
放弃：选中即 `addLodgingStay` 直接落（默认 1 晚、需事后改，体验差）。

### 删除只留详情「···」菜单，去二次确认
原因：详情与编辑是叠层 sheet（点 Edit 时详情未销毁）；在**编辑里删除** → 编辑关闭 → 露出**悬空详情**（仍显示已删实体 + Edit 按钮），衔接断裂。
决定：① **所有编辑页（交通含航班/地点/景点/住宿）移除底部删除**——删除唯一入口=详情「···」菜单（走详情删 → 详情自身 dismiss，干净）。② 详情删除**去二次确认 alert**：删除藏在 ··· 菜单里、本就「开菜单 + 点红字」两步，低损失、可重加，确认多余。清掉因此变死的 4 个本地化键。

### 行程列表左滑删除 = 所有可删实体
原因：`trailingSwipe` 原 `guard case .stop` 只放行地点，交通/住宿可删却无左滑（漏接，只接了 stop 的 `onDelete`）。
决定：按行类型分派——`.stop`/`.transport`/`.carRental`/`.lodging` 各接自己的删除回调（租车两行、住宿跨天多行，任删一条都删整段）；日历事件（系统只读）、连接线、占位行**保持不可删**（正确）。

### scrollTo(anchor:.top) 的顶部留白用 contentMargins，不用 content padding
原因：日期选择器初始 `scrollTo(targetMonth, anchor:.top)` 把起始月对齐到滚动视口顶边，会把 `LazyVStack.padding(.top)` 顶出视口 → 加 padding 无效，月标题贴星期栏。
决定：改用 **`.contentMargins(.top, 20, for: .scrollContent)`**——它是 scroll 的内容内缩边，`scrollTo` 以它为对齐基准，故任何锚定月份都稳定留白。推广：凡「scrollTo 对齐 + 想要顶部留白」一律用 `contentMargins`（scroll 内缩），而非内容 `.padding`（会被 scrollTo 顶掉）。

## 2026-06-23（夜）行程详情/列表收口 + 交通字段体系

### 日历叠加事件：定时按时序入主脊、脊在其处「断开」（A 方案，否决脊连续穿过）
原因：原先所有日历叠加事件不分时刻全钉当天顶部，违背「时间轴按时序读」（18:00 事件压在 10:35 航班上、看不出冲突）。
决定：**全天事件**仍钉顶部 band；**定时事件**按 `startMinutes` 插进主脊时间位，但**脊在它处自然断开**（相邻规划行不朝它连线）——它是「来自你日历的外部叠加项、不属于你规划路线」，断开诚实表达这一点。**否决「脊连续穿过 + marker」**：试过空心环（太抢、层级倒置）与小彩点（虽退后但脊连续）——最终选 A，因为「明确分离」比「脊全连续」更符合语义。

### 详情复制：两种形式 + 手势统一长按
决定：**值字段 = 长按即复制 + 居中 Toast**（`longPressCopy`）；**标题栏 = 长按出系统拷贝菜单**（`.textSelection`，承载航班号/酒店名/地点名等身份字段）。手势统一**长按**=复制，tap 留给字段本职（电话拨号、URL 打开）。该复制的：地址、确认/预订号、车牌、电话(长按)、URL(长按)；不复制：时间/日期/晚数/舱位/车型/机型/距离/费用/航司·公司名/座位。

### 底栏悬浮玻璃单一真源 `BottomBarGlass`
原因：行程切换器用 `regularMaterial + 黑色叠层`，在亮底发灰显「脏」；首页底栏用 `ultraThinMaterial + 叠白`，干净通透——两处不一致。
决定：抽 `BottomBarGlass`（iOS26 原生 Liquid Glass / 否则 ultraThinMaterial+叠白+白描边）到 `ViewModifiers.swift`，首页与切换器**共用**。**禁用 `regularMaterial + 黑叠层`**于悬浮胶囊。

### 交通字段按「概念归属层级」设计，不一刀切
- **E-ticket（航班）**：电子客票号 13 位纯数字，与确认号/PNR（预订定位码）**不同概念**，并列不替代；纯数字 `.numeric` 过滤。
- **火车/巴士/渡轮**：补 `routeName`/`coachNumber`(火)/`seatClass`(火·巴)/`serviceType`（按 mode 显 Train/Bus/Ferry type）；统一编号文案 `Transport number`、预订码 `Reservation code`；**去掉 Code/Platform**（无标准站码、站台临场才知）。详见 spec `itinerary-ground-transport-fields.md`。
- **Coach number 放 Seat 之上**（登车顺序：先找车厢、再找座位）。
- **Seat class 自由文本不做 picker**（各国席别名差异大）；占位用本地化真实示例（一等座 / 商務車廂 / 1. Klasse）。

### Add Other 保留为「通用兜底」，Cruise 不加
- **Other 保留**：catch-all 逃生口（地铁/出租/接送/缆车等无专属类型者），删了用户没法记；单一灵活兜底=反臃肿。地点文案改通用 **`Location`**（非 Station，出租车没有站）、去 Seat（多无座位号）。
- **Cruise 不加**：邮轮是「多日、船即目的地、住宿+活动+多港」的复合体验，**套不进 A→B 交通段模型**；对目标用户（飞机+火车+自驾为主）小众。真要做该是独立实体，另立项。

### 切换器「随滚动收起」用稳定 relay 解耦，避免重渲
原因：把 `onScrollHide` 闭包传进 `ItineraryView` 会使每次收起/展开翻转都重渲它（重算 daySections + 重 diff 地图），≤2 次/手势但浪费、长行程可能 hitch。
决定：状态走**引用型 `ScrollHideRelay`（ObservableObject）**，容器 `@StateObject` 订阅、子视图只持稳定引用不订阅 → 翻转**只重排底部 inset 胶囊**，不触碰 ItineraryView。逐帧滚动只做算术 + 翻转才回调（带滞回）。

### xcstrings 工作流：改完别再 build（技术坑）
原因：`xcodebuild` 会重写 String Catalog——把代码插值 glue key（` · %@`、`%@ → %@`）的非英译清掉、给新 code 字符串生成空 stub → 制造重复键/缺译，污染 diff 且与并行会话叠加成乱。
决定：**代码先 build 验证 → 再从 HEAD 文本重建 xcstrings（HEAD + 本次 key 改动）→ `scripts/i18n-audit.py` [E]=0 → 提交，且提交后不再 build**。已写入 CLAUDE.md 本地化规范。
