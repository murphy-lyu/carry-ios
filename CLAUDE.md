# Carry — 旅行助手 App

## 项目定位
Carry 是一款面向有旅行习惯、追求生活品质的 iOS 用户的旅行助手 App。
当前核心是旅行打包清单，未来会逐步延伸到完整的旅行规划场景。
产品哲学：克制、聚焦，只解决旅行场景中最核心的问题，体验做到极致，不做臃肿的大而全产品。
设计原则：视觉和交互都要追求极致，但一切以用户价值、理解成本和操作流畅度为准，不为设计而设计；始终先站在用户视角思考，克制表达，避免为了形式感牺牲实用性。若某个界面在视觉/排版上反复纠结，先回到功能本身判断：这一层信息是否真的需要展示、是否可以合并或删除，而不是默认继续堆叠布局。
沟通要求：始终使用中文回复。
表达规范：叙述说明使用中文；代码片段、命令、报错信息、配置键名等必要技术内容保持原始格式，不做强制翻译。

目标用户：有旅行习惯、追求生活品质的 iOS 用户。
当前阶段：即将上线 App Store（2026年6月），持续迭代中。

## 已上线功能
- 行程管理：创建/编辑/复制/删除行程
- 物品清单：
  - 从预设物品库（分类+常用物品）添加到清单
  - 从用户自定义库添加（用户自建、自维护）
  - 打包标记（标注是否已打包）
  - 物品数量
  - 物品与分类排序
  - 自定义分类
  - 智能推荐清单（基于场景）
  - "顺手考虑一下"功能
  - 经期打包提醒（HealthKit Cycle Tracking 本地预测，设置内显性 opt-in，默认关）
- 打包提醒：设置时间提醒用户记得打包（本地通知）
- 灵动岛 & 锁屏打包进度（Live Activity / ActivityKit）
- 桌面小组件（Widget，即将出发行程 + 打包进度，Small / Medium）
- 主屏快捷操作（长按图标，New Trip / Nearest Trip / Footprint）
- 日历同步：行程 + 打包提醒写入系统日历（EventKit，独立子开关）
- 目的地实用信息：充电插头 / 电压 / 货币 + 天气预报（DestinationInfoView）
- 分享清单：把打包清单分享给同行者参考
- 行程统计/概览：全部行程、即将出发、到访国家数量
- 地图（MapKit）：
  - 点亮到访过的国家
  - 显示用户当前位置
  - 切换地图样式
- 支持 Carry：请作者喝咖啡（StoreKit 内购，App 免费）
- 产品路线图：已上线和即将上线功能（支持远程 JSON 更新）
- 备份与还原
- 应用图标切换（多套主题图标）
- Light / Dark / 跟随系统 模式切换
- Siri / Spotlight 快捷指令（创建行程、打开行程、显示地图）
- 本地化（Localizable.xcstrings）

## 产品路线图方向

### 近期：完善打包清单体验
- 行程统计增强

### 中期：旅行规划
参考 Tripsy 方向：
- 行程路线规划
- 航班动态
- 酒店入住记录
- 租车信息
- 自驾路线
- 行程提醒

参考 Luggy 方向：
- 实时汇率

### 远期：旅行内容与建议
- 旅行攻略推荐
- 目的地着装搭配建议
- 妆容搭配建议

## 开发者背景
独立开发，无设计师，PM 背景（13年），有早期 Web 开发经验。
审美方向：Apple 原生风格，极简、克制、优雅。
代码风格：可读性优先，避免过度抽象。

## 技术栈
- 语言：Swift，iOS 17+
- UI 框架：SwiftUI 为主；手势拦截、动画性能优化等场景允许通过 UIViewRepresentable 使用 UIKit，但须隔离在独立组件里，不暴露给上层
- 数据层：SwiftData，versioned schema + migration plan（CarrySchema.swift / CarryMigrationPlan）
- 核心 Model：TripBundle、MyItem
- 状态管理：TripStore（ObservableObject）、NavigationRouter（ObservableObject）
- 导航：NavigationStack + NavigationPath，路由枚举 CreationRoute
- 入口：SplashView → ContentView（TabView：Trips / Settings）
- AppIntents / Siri Shortcuts：CarryShortcuts.swift
- 地图：MapKit
- 内购：StoreKit（CoffeeStore = 打赏）
- 本地化：Localizable.xcstrings
- 日志：CarryLogger（单例）

## 项目结构
Carry/
├── CarryApp.swift          ← App 入口，ModelContainer 初始化，通知委托注册
├── ContentView.swift       ← TabView + NavigationRouter
├── ViewModifiers.swift     ← 全局 ViewModifier
├── Models/                 ← 数据模型、Store、Manager（含 LiveActivityManager）
├── Views/                  ← 所有页面
├── Globe/                  ← 3D 地球视图（GlobeView）
└── AppIntents/             ← Siri/Spotlight 快捷指令

CarryWidget/                ← Widget Extension target
├── CarryWidgetBundle.swift ← WidgetBundle 入口
├── CarryWidgetLiveActivity.swift ← 锁屏卡片 + 灵动岛 UI
└── Localizable.xcstrings   ← widget 专属本地化（9 种语言）

SharedSources/              ← 两个 target 共用的代码
└── PackingActivityAttributes.swift ← ActivityKit 共享数据模型

## 设计规范

> **最高标准：`docs/design-north-star.md`（设计北极星）—— 凌驾于 design-system.md 之上。**
> Carry 奔着 Apple 年度最佳设计应用（Apple Design Award）的水准做。`design-system.md` 是「当前决策的记录」、不是上限；每次碰 UI 都按 north-star 重新审视、往上推，再把抬高后的标准回写 design-system.md。克制是手段（去噪聚焦），卓越是目标——别用「不为设计而设计」当借口停在「够用」。

→ 具体落地（token、组件规格）详见 docs/design-system.md
关键约定：全部 View 支持 Dark Mode，颜色使用 token 禁止硬编码。

## 当前进度
→ 详见 docs/progress.md

## 政策合规约定（中国大陆上架）

Carry 在中国大陆 App Store 上架，涉及地理政治敏感内容时必须遵守以下规则。

### Storefront 检测
- `isChinaStorefront`（定义在 `SceneItemMap.swift`）通过 `SKPaymentQueue.default().storefront?.countryCode == "CHN"` 检测是否为大陆 storefront
- `#if DEBUG` 下可通过 UserDefaults `"debugChinaStorefront"` 覆盖，方便本地测试
- **禁止**用设备 Locale / Region 替代 storefront 判断，两者不等价

### 地图与统计：HK / MO / TW 归并
- `HomeView.normalizedCountryCode(_:)` 在大陆 storefront 下将 HK、MO、TW 归并为 CN，用于地球仪点亮和到访国家计数
- **禁止**在其他地方重复做此归并；原始 `countryCode` 存储层永远保持 ISO 原始值（HK / MO / TW），归并只发生在展示层
- MapKit 底图在大陆设备上自动切换高德，政治边界由 Apple 处理，无需额外干预
- **禁止**在 bundle 中放置含台湾独立国家描述的 GeoJSON 或边界数据（已删除 `countries-110m.geojson`）

### 旅行证件推荐：按 storefront 差异化
- 大陆 storefront + HK 或 MO 目的地 → 推荐「**港澳通行证**」，移除护照
- 大陆 storefront + TW 目的地 → 推荐「**台湾通行证**」，移除护照
- 其他 storefront 不受影响（外籍用户去港澳台仍推护照）
- 逻辑集中在 `generatePackingSections(destinationCodes:)` 内，**禁止**在其他地方散落地做证件判断
- 城市表（`cityLookup` / `countryKeywords`）必须包含「台湾」「台灣」「taiwan」→ TW 的映射，否则 TW 目的地无法被识别

### 隐私政策
- `carry-legal/privacy/zh.html` 第 14 条为 PIPL（《个人信息保护法》）专属声明，修改隐私政策时不得删除此条
- 英文版 `index.html` 无需同步此条（PIPL 仅适用于大陆）

## 重要约定（每次必须遵守）

> ### 🔴 第 0 条铁律：交付任何修复前，先过"根因门"（最高优先级，凌驾本节其它所有条目）
>
> 这是用户最在意、且我**已经违反过**的约束。每次提交修复**之前**，必须逐条自检，**全部为"是"才能交付**：
> 1. 这是**根因解**吗？——我能讲清"问题的根在哪、为什么这样改能从根上消除它"，而不是"看起来好了 / 不卡了 / 能跑了"。
> 2. 是否覆盖了**所有触发路径**，而不只是用户当下撞上的那一条？（例：删资源不能只在一个调用点删，要堵住所有删除路径 → 就地删 + 兜底回收。）
> 3. 是否**消除**了问题本身，而不只是把它**搬走 / 隐藏 / 延后**？（例：重活不能只从主线程挪到后台就算完，要从根上不做这件重活 → 解耦冷热路径。）
> 4. 编译器 / 并发告警是按根因消的吗？**没有**用 `@unchecked`、`nonisolated(unsafe)`、强制解包、`try?` 吞错、关警告等压制手段把问题盖住？
>
> **绝对禁止的交付行为（我犯过，永不再犯）：**
> - ❌ 先给"半截解 / 最小改动"，再问用户"要不要升级成标准版" —— 把根因解当成**可选项**征求确认，这本身就是违规。
> - ❌ 用"要不要我…""够用吗""留到 Phase 2 吗"这类话术，把"是否做根因解"的决定权**推回给用户**。
> - ❌ 以"改动更大 / 更费时 / 当前能用"为由，默认交付次优解。
>
> **必须的交付行为：**
> - ✅ 第一次就把**完整根因解**做完再交付；若发现自己手里是半截解，**先补到完整**再开口，而不是先把半截交出去。
> - ✅ 工程质量层面的判断（是否根因、是否健壮、是否清理副作用 / 告警）**不问用户、直接做对**。只有**产品决策**（视觉方向、是否上线某功能、取舍优先级）才需要问用户。
> - ✅ 用户**不应该需要**在每次修复时反复追问"这是根因吗""不是补丁吧"。这个自检是**我的默认职责**，不是用户的监督义务；让用户来兜这道关，就是失职。

- 业务逻辑、页面布局、导航全部 SwiftUI；手势拦截、动画性能优化等场景允许通过 UIViewRepresentable 使用 UIKit，但要隔离在独立文件/组件里，不暴露给上层；禁止使用私有 API
- 颜色必须使用 docs/design-system.md 中定义的 Color Token，禁止硬编码 hex
- 禁止硬编码用户可见文案（包括写死在代码中的标题、按钮文案、提示语、错误文案、空状态文案等）；统一使用 `Localizable.xcstrings` 管理并通过本地化 key 调用。仅允许技术性常量（如日志 tag、内部调试标记、协议字段）以代码常量形式存在，且不得直接面向用户展示。
- 所有 View 必须支持 Dark Mode
- 动画统一：标准交互用 .spring(duration: 0.3, bounce: 0.2)
- 信息密度必须服务于当前任务；如果上层页面已经提供了足够上下文，当前页面只保留完成当下操作所必需的信息，避免重复展示同一信息。
- 问题排查时避免发散猜测；若当前信息不足以可靠定位问题，应先明确提出所需的最小补充信息（复现步骤、报错文本、截图/录屏、设备与系统版本等），再继续分析与实现，以提升排查效率和结论可信度。
- **先验证"可达性"，再断言"现状"或据此让用户决策（防止拿死代码误导用户）**：在把任何一段代码描述为"线上现状 / 当前方案 / 会渲染成什么样"，或基于"代码当前怎么做"向用户抛出一个选择/决策**之前**，必须先确认它**真的会被执行/渲染**——从真实入口（View 的 `body`、实际调用方）**追调用链**、`grep` 它的调用点，确认确实被用到。**「定义存在 / 能编译」≠「被调用 / 被渲染」**：重构后留下的死代码残留极易被误当成线上逻辑。**禁止**凭记忆、或仅凭"代码里有这段"就当作生效行为向用户陈述；尤其禁止据此让用户反复纠结一个**根本不生效**的方案。自检：我说"现在是 X"之前，能指出 X 是从哪个入口被渲染/调用的吗？指不出就先去查，查不到就说明它是死代码（应删，而不是当方案讨论）。
  > 来源：把一段**零调用**的 monogram 兜底残留当成首页线上方案，让用户来回确认了好几轮才发现它根本不渲染。
- **「本地默认 + 远程可覆盖」的配置，改动必须落到"用户实际读的那一份"，否则隐形**：典型是**产品路线图**，有两份数据——App 内嵌默认（`Carry/Views/RoadmapView.swift` 里的 `RoadmapPayload.embeddedDefault`）与仓库根的 `roadmap.json`（线上经 `https://raw.githubusercontent.com/murphy-lyu/carry-ios/main/roadmap.json` 拉取）。**加载优先级：能拉到远程就整份覆盖内嵌默认 → 否则用本地缓存 → 最后才用内嵌默认**。即**线上用户实际看到的是远程 `roadmap.json`，只改内嵌默认是无效改动**。任何路线图变更（新增条目 / 改 status / 调顺序 / 改措辞）必须**同步改 `roadmap.json` 并 push**；`roadmap.json` 用 `title`/`titleEn`/`titleZhHant` 三字段编码多语言（en / zh-Hans / zh-Hant），与内嵌默认保持**同序同字段**。验证：raw CDN 有约 5 分钟缓存，push 后别只 curl raw（会读到旧缓存），改用 GitHub API `https://api.github.com/repos/murphy-lyu/carry-ios/contents/roadmap.json?ref=main` 确认 main 已更新。推广：任何"内置默认 + 远程下发"的配置，先认准"用户运行时实际读哪一份"，改动落到那一份（并保持两份一致）。
- **零容忍止血/补丁/过渡方案（用户硬性要求）**：问题修复必须从根本上用最合理、最科学的框架与技术解决，追求逻辑与科学正确，而非"看起来能用就行"。**禁止**提出或采用任何"止血""最小改动""临时兜底""先扛过去""补丁叠加"类方案——即使它更快、改动更小。不得以"开发耗时/工期"为由降级方案：AI 完成同等工作仅需分钟级，绝不能套用人类"一个修复要三天"的时间权衡来合理化偏方。遇到性能/架构类问题，先判断"业界（如 Flighty、Tripsy 等）如何做到"——别人能做到的、非自研黑科技的效果，本项目理论上也应能用正确技术做到；若当前实现卡顿/别扭，应合理怀疑是框架或技术方案选型不当，并负责任地换用科学解，不得回避根因。根因方案的代码改动可能很小也可能很大，以"是否真正解决根因"为唯一标准，不以改动大小论。典型反模式：用 `DispatchQueue.asyncAfter` 硬编码延迟来"等待"另一个异步过程（如动画）结束——这会把两处时长隐式耦合，任一改动都可能静默失效；正确做法是用该过程自身的完成回调（如 `addCompletion`、`onCompletion` 闭包）来驱动状态变化，让生命周期由事件而非时间控制。
- 对迭代中的排查/优化任务，必须执行“改动有效性审计”：持续回看本轮已做改动，区分有效/无效/副作用改动。凡是“无明显收益 + 引入复杂度或潜在性能/稳定性风险”的改动，应及时回退，不得因投入成本而保留。允许尝试很多方案，但最终合入代码应保持最小必要集合（Minimal Effective Set）：只保留能被验证带来正向效果、且维护成本可控的改动，并在文档中记录“改动内容 → 结果 → 去留决策”。
- 新 View 必须注入 store / router（通过 @EnvironmentObject）
- NavigationRouter.path 操作统一走 router，禁止在子 View 里自行维护 NavigationPath
- SwiftData 变更必须考虑 migration，不能直接改 model schema
- **备份/还原格式变更**：新增字段一律用**可选类型**保持向后兼容；产品**发布前**新增可选字段**不升 `currentBackupVersion`**（无在野旧备份，统一归当前版本），版本号只在**发布后**因破坏性格式变更才递增（它唯一作用是拦截"更新格式的备份在旧 App 还原"）。任何**不在 SwiftData 里的关联文件**（如背景图字节存在沙盒、仅文件名进 model）必须**显式随备份带上字节并在还原时写回**，否则重装/还原会丢失——`DataBackupManager` 改动时同步检查这点。
- 新功能开发前先写 specs/ 下的 spec 文件，确认后再实现
- **Live Activity 数据同步**：TripStore 中任何修改物品数量（add/remove/merge）、行程信息（name/destination/date）、打包状态的函数，必须调用 `LiveActivityManager.shared.update(for:)` 或 `end(for:)`。删除行程调用 `end`，其余调用 `update`。仅 iOS（`#if !targetEnvironment(macCatalyst)`）。
- **Widget Extension 文件约定**：`CarryWidget/` 下所有文件仅属于 CarryWidgetExtension target，不得与主 app target 混用；跨 target 共享的类型统一放 `SharedSources/`，通过 pbxproj `PBXSourcesBuildPhase` 显式加入两个 target
- **Widget 本地化**：widget 使用 `CarryWidget/Localizable.xcstrings`，不共享主 app 的 xcstrings；新增 widget 文案必须同步补全 9 种语言
- **埋点闭环**：在 `CarryLogger.Event` 新增 case 时，必须在同一次改动里补齐调用点，禁止"先定义后接线"——已定义却从未调用的 Event 是死代码，上线后无法回收数据。错误类 Event 新增后必须同步加入 `errorEvents` 集合。新增用户可触发的功能/交互（按钮、入口、分享等）应评估是否需要对应埋点

## 框架协作与诊断纪律（核心规范 · 每次必须遵守）

> 反复踩坑攒出来的三条核心工作方式，凌驾于"快点改完"之上。

### 1. 先理解框架行为再动手——不假设，要推导
**动手前先弄清相关框架/API 的实际行为机制：不靠假设，要靠推导**——从框架真实行为推出"它在这里自动做了什么、为什么这样改能从机制上解决"。讲不清这条因果就先去查（读框架行为 / 文档 / 最小实验），而不是先改了再看。

### 2. 两次没解决就停手，改用可观测手段重新诊断
**同一个问题连续两次修改仍未解决 → 立刻停止"继续猜 / 叠补丁"**，改用**可观测手段**重新定位根因：日志、断点、控制变量对照、最小复现。盲改第三次几乎必然是在错误方向上加复杂度。
> 实例（本项目）：行程页"加停靠点/加一天点了没反应"——不是继续乱调坐标，而是用**对照法**发现「`Menu` 正常、`Button` 失效」→ 推出 touch-down 与 touch-up 的差别 → 定位到根 `ZStack` 的 `.simultaneousGesture(TapGesture)` 吞掉了 List 行内按钮的 touch-up。一个可观测对照信号，胜过盲猜十次。

### 3. 不对抗框架——顺着它自动做的改，不在它之上堆逻辑
**先找出"框架/系统已经自动替你做了什么"**（默认行为、生命周期、自带机制、安全区、原生交互），**顺着它的机制改**；**不要在它之上再堆一层自己的逻辑去绕过/对抗它**。能用框架原生能力达成的，绝不自造平行机制。
> 实例（本项目）：
> - 同一视图挂多个 `.sheet(item:)` 会相互抑制 → 顺势**合并成单一枚举驱动的 sheet**，而非加 workaround 硬让两个并存。
> - `List.onMove` 不支持跨 section 是框架边界 → 跨天拖拽**改用 `UICollectionView` 原生 interactive movement**（框架本就支持跨 section），而非在 List 上硬凑。
> - 底部悬浮元素遮挡内容 → 用框架的 `safeAreaInset` / `contentInset` 让框架自己避让，而非手算偏移去顶内容。

## 经验教训：性能/动画类疑难问题的排查纪律

> 来源：FX 缩放 Sheet 的掉帧问题，纯靠迭代试错走了 3–4 天才找到真正根因（自动吸附用手写 `CADisplayLink` → 应换成 Core Animation）。这套纪律的目的：以后遇到类似"卡顿/不流畅/动画别扭"的问题**不再走这么多弯路**。详细经过见 `docs/home-sheet-debug-playbook.md` §21–§32。

1. **先用"对照组"隔离根因，不要逐层枚举成本试错。** 某效果不如一个已知的好参照时，第一步永远是用**控制变量法**找出那个唯一差异，而不是凭经验猜可疑点逐个改：
   - 项目内有现成对照（本例 fallback 实现：同内容、唯一差别=缩放 transform）→ **立刻 A/B**，差异即根因方向。
   - 有竞品参照（如 Tripsy）→ 用它隔离变量（"锁 60Hz 看 Tripsy 是否仍丝滑"一举排除了"帧率不够"这个假设）。
   - 这两个实验本应在**第一次报问题时**就做，而不是拖到第 3 天。
2. **"改了只是好一点点"是危险信号**——说明在修次要成本、不是根因。别在同一条路上继续磨，停下来重新对照隔离。本例 relayout→mask→blur→帧率 每步都"好一点"，持续强化了错误方向。
3. **动画/交互"不丝滑"，第一嫌疑是动画的"机制"对不对，而非逐帧成本。** iOS 原生丝滑动画 = **Core Animation**（`UIViewPropertyAnimator` / `CASpringAnimation`，渲染服务器 GPU 插值、与刷新率自适应）。**手写 `CADisplayLink` 每帧改属性几乎总是错的**（主线程每帧算、易抖、还要自己处理限步/时序）。看到吸附/动画用 `CADisplayLink + 每帧 setFrame/手算插值` → 高度怀疑，优先换 CA 动画。
4. **任何"历史 workaround"在它的前提改变后，必须重新质疑、而非当成不可碰的雷区。** 本例手写 displayLink 当初是为旧的 CAShapeLayer mask 服务（mask 没法被动画器干净插值）；mask 删掉后它早该退役，却因被标"雷区"一直绕着供着，严重拖慢定位。
5. **对标平台/竞品的实现方式。** 我们的方案在架构上与"系统/竞品怎么做"不同时，那个差异就是头号嫌疑，先查它再微调参数。iOS 圆角 Sheet 的正解 ≈ Apple 自家：`layer.cornerRadius`（非 path mask）+ CA 动画（非 displayLink）+ 内容固定尺寸不每帧 relayout + 缩放用 transform（必要时 `shouldRasterize` 缓存 blur/阴影）。
6. **缺客观数据时尽早仪表化。** 没法真机 profile 时，加帧时间埋点拿数据，比"假设 + 真机主观反馈"的慢回路快得多。

**iOS 流畅滚动/动画 速查（直接规避踩过的坑）**：
- 每帧 resize SwiftUI 宿主 view（改 `frame.size`）→ 触发整树 relayout，必卡。内容固定尺寸，缩放/位移用 `transform`/`center`。
- 缩放含 `.blur`/`.shadow` 的内容 → CA 每帧重渲染滤镜。运动期对内容层 `shouldRasterize`（运动结束/列表滚动时必须关）。
- 圆角优先 `layer.cornerRadius + cornerCurve=.continuous`（GPU 原生）；避免每帧重建 `CAShapeLayer.path`（整层重栅格化）。上下不同圆角用两层各圆两角的嵌套 layer，而非 path mask。
- 自定义高刷 `CADisplayLink` 需 Info.plist `CADisableMinimumFrameDurationOnPhone=YES` 才能上 120Hz——但**优先用 CA 动画，别手写 displayLink**。

## 本地化规范

### 硬编码文案：零容忍
所有面向用户的文案（标题、按钮、提示语、错误、空状态、placeholder 等）**必须**通过 `Localizable.xcstrings` 管理。禁止在 Swift 代码中直接写死任何语言的字符串——包括中文，也包括英文。

合法写法：
- `Text(LocalizedStringKey("some.key"))`
- `NSLocalizedString("some.key", comment: "")`

非法写法（无论什么语言）：
- `Text("搜索物品...")` ← 硬编码中文
- `Text("Add items")` ← 硬编码英文
- `placeholder: "Search..."` ← 硬编码英文

例外：仅允许技术性常量（日志 tag、内部调试标记、协议字段），且不得直接面向用户展示。

### 结构化 key 必须显式写 "en"
xcstrings 中有两类 key：

- **语义性 key**（key 本身就是英文原文）：如 `"Add items"`、`"One last check before you close the door."`——key 即为英文值，无需 `"en"` 条目
- **结构化 key**（如 `itempicker.hero.title`、`packing.scene_card.subtitle`）：**必须**在 localizations 中包含 `"en"` 显式条目，否则英文设备显示的是 key 名本身

### 新增文案：同步补全所有语言
每次新增或修改面向用户的文案，必须在同一次改动中完成全部 9 种语言，不允许"先占位后补"：

`en` / `zh-Hans` / `zh-Hant` / `de` / `es` / `fr` / `ja` / `ko` / `pt-BR`

### 文化适配，不是字面翻译
翻译的目标是让母语用户读起来自然，而不是把英文逐词搬过来，也不是把简体中文用工具转成繁体就完事。

**zh-Hans 与 zh-Hant 不是简繁转换关系**，词汇和表达有实质差异，以台湾/香港用语为基准：

| 概念 | zh-Hans（大陆） | zh-Hant（台湾/香港） |
|------|----------------|-------------------|
| 哪里 | 哪儿 / 哪里 | 哪裡（不用「哪儿」） |
| 应用/软件 | 应用、软件 | 應用程式、軟體 |
| 视频 | 视频 | 影片 |
| 文件夹 | 文件夹 | 資料夾 |
| 优化 | 优化 | 最佳化 |
| 防晒衣 | 防晒衣 | 防曬衣 |
| 冲浪衣 | 冲浪衣 | 衝浪衣 |

其他语言同理：德语名词首字母大写；法语冒号/问号前有空格；日语优先用常体（だ/である）而非敬体（です/ます）；韩语界面文案通常用해요体而非합니다体。

### 中文文案必须用全角标点（zh-Hans / zh-Hant）

中文文案的标点**必须用中文全角**，禁止混用英文半角。常见对照：

| 英文半角（禁止） | 中文全角（正确） |
|---|---|
| `,` 逗号 | `，` |
| `.` 句号 | `。` |
| `:` 冒号 | `：` |
| `;` 分号 | `；` |
| `?` 问号 | `？` |
| `!` 叹号 | `！` |
| `...` 省略号 | `…` |
| `()` 括号 | `（）` |

例外：与代码/版本号/英文术语/数字相邻的技术性内容（如 `iOS 17`、`100ml`、`\(count)` 插值、URL）保持原样，不强制转全角。

> 这是**反复出现过**的问题（如 `tripdates.clear` 用了半角逗号、搜索 placeholder 用了 `...`）。新增/修改中文文案时务必检查标点；改动 xcstrings 后可快速扫描 zh-Hans/zh-Hant 值中是否含 `[,.;:?!]` 或 `...`。

### Key 命名规范
两类 key，用途不同，选型也不同：

**结构化 key**：用于有明确界面归属的 UI 文案（标题、按钮、Tab 名、错误提示、空状态等）。格式为 `screen.component.purpose`，全小写，点分隔。例：
- `itempicker.hero.title`
- `packing.scene_card.subtitle`
- `myitems.empty.title`

必须在 xcstrings 中显式写 `"en"` 条目。

**语义 key**：用于内容型文案（Surprise Item 的 note、较长的描述文案等）。直接用英文原文作为 key，key 本身即为英文展示值，无需 `"en"` 条目。例：
- `"One last check before you close the door."`
- `"For evenings with nowhere to be — the right scent shifts the whole mood of a room…"`

语义 key 的优点是在代码中可读、自文档化；结构化 key 的优点是与界面层级对应、便于批量管理。

### 修改语义 key 的文案
语义 key 的 key 名就是英文原文，修改英文等于 key 本身变了。正确流程：

1. 在 xcstrings 中**新增** key（新英文文案），同步补全所有 9 种语言
2. 在 Swift 代码中将引用切换到新 key
3. 将旧 key 从 xcstrings 中**删除**

禁止直接在旧 key 的 `"en"` locale 下修改 value——语义 key 没有 `"en"` 条目，且这样做会造成 key 与实际展示文案不一致，埋下难以发现的 bug。

### 修改现有文案：同步更新所有语言
修改任何已有文案（改措辞、调语气、重写 copy）时，所有语言版本必须同步更新，不允许只改英文或只改中文，让其他语言停留在旧版本。旧文案的 key 如果不再使用，应从 xcstrings 中一并删除，避免产生无效条目。

### 物品库维护规范

**重命名物品时必须保留向后兼容**
`itemPickerCatalog` 中的物品名是用户清单数据的存储 key。改名后，已有用户的清单里仍然存着旧名字，若找不到对应条目会导致数据异常。正确做法：在 `ItemCatalog.swift` 的 `itemNameAliases` 字典中添加 `旧名 → 新名` 的映射，不得删除已有 alias。

```swift
// 示例
private let itemNameAliases: [String: String] = [
    "Colored contacts": "Coloured contacts",  // 改过的别名，永久保留
    // ...
]
```

**`ItemPickerCategory.name` 必须与 xcstrings key 完全一致**
该字段在 UI 中作为 `LocalizedStringKey` 使用。任何不一致（如 `"Documents"` vs `"Travel Documents"`）都会导致所有语言的分类标题 fallback 回英文原文，且只在非英文设备上才能发现。修改分类名时，`ItemPickerCategory.name`、对应 `ItemCategory` enum 的 rawValue、`catalogCategory(named:)` 的 case、以及 xcstrings key 必须四处同步更新。

### 已知错误模式（不要重犯）
- placeholder 写死中文字符串 → 英文设备看到中文
- 结构化 key 漏写 `"en"` → 英文设备显示 key 名
- `ItemPickerCategory.name` 与 xcstrings key 名不一致 → 分类标题 fallback 回英文原文
- xcstrings key 已更新但 Swift 数据源未同步 → UI 渲染旧字符串（如 `"Documents"` vs `"Travel Documents"`）
- 用简繁转换工具替代真实翻译 → zh-Hant 出现大陆用语或错误字形
- 中文文案用了英文半角标点（`,` `.` `...` 等）→ 应全角（`，` `。` `…`），见上「中文文案必须用全角标点」
- 用脚本改 `Localizable.xcstrings` 时序列化格式不匹配 Xcode → 整文件重排出 6 万行 diff。Xcode 用 `" : "`（冒号前空格）；脚本须用 `json.dumps(..., ensure_ascii=False, indent=2, separators=(',', ' : '))` 且无尾换行，先做零改动 round-trip 验证再改。另：Xcode 构建会重写该文件、可能覆盖未提交的脚本编辑（编辑前最好确认 Xcode 未在构建）。`git commit` 用显式路径，避免误并入用户在 Xcode 内换图标等在途改动。

## 文件索引
- docs/design-north-star.md：设计最高标准（ADA 级评判框架，凌驾于 design-system.md）
- docs/design-system.md：视觉规范与组件标准（当前落地，非上限）
- docs/architecture.md：架构与模块说明
- docs/decisions.md：决策日志
- docs/progress.md：进度追踪
- specs/：功能 spec 文件目录

## 文档按需读取索引

> 本节告诉 Claude 在什么场景下读取哪个文档，避免每次都加载全部内容。

| 场景 | 需要读取 |
|------|---------|
| 每次会话开始（建议） | `docs/progress.md` — 了解当前进度与上次改动 |
| 实现任何 UI / 视觉需求 | **先** `docs/design-north-star.md`（最高标准/评判框架）+ `docs/design-system.md`（Color Token、组件规范、Mac Catalyst 面板规格） |
| 触碰 `CarryBottomSheet.swift` | `docs/home-sheet-debug-playbook.md` — 必读，避免重踩已知问题 |
| 架构新增或模块重构 | `docs/architecture.md` |
| 遇到可能重复讨论的设计决策 | `docs/decisions.md` — 确认是否已有定论 |
| 发布前 | `docs/release-checklist.md` |
| 性能相关改动 | `docs/performance-audit-2026-05-27.md` |
| 开发某个 spec 功能前 | 对应 `specs/*.md`（注意看 Status 标记是否已 Shipped）|

### 会话结束时更新
每次会话结束后，更新以下文件保持上下文连续：
1. `docs/progress.md` → `## 上次改动摘要` 区块（3-5 条最新改动）
2. `docs/decisions.md` → 如有新的架构/设计决策，追加记录
3. `docs/architecture.md` / `docs/design-system.md` → 如有结构或规范变化，同步更新
