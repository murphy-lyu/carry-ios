# Carry — 旅行助手 App

## 项目定位
Carry 是一款面向有旅行习惯、追求生活品质的 iOS 用户的旅行助手 App。
当前核心是旅行打包清单，未来会逐步延伸到完整的旅行规划场景。
产品哲学：克制、聚焦，只解决旅行场景中最核心的问题，体验做到极致，不做臃肿的大而全产品。
设计原则：视觉和交互都要追求极致，但一切以用户价值、理解成本和操作流畅度为准，不为设计而设计；始终先站在用户视角思考，克制表达，避免为了形式感牺牲实用性。若某个界面在视觉/排版上反复纠结，先回到功能本身判断：这一层信息是否真的需要展示、是否可以合并或删除，而不是默认继续堆叠布局。
沟通要求：始终使用中文回复。
表达规范：叙述说明使用中文；代码片段、命令、报错信息、配置键名等必要技术内容保持原始格式，不做强制翻译。

目标用户：有旅行习惯、追求生活品质的 iOS 用户。
当前阶段：已上线 App Store（2026年5月），持续迭代中。

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
- 打包提醒：设置时间提醒用户记得打包（本地通知）
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
- 天气预报（目的地，暂缓中）
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
- 目的地天气预报
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
→ 详见 docs/design-system.md
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
- 业务逻辑、页面布局、导航全部 SwiftUI；手势拦截、动画性能优化等场景允许通过 UIViewRepresentable 使用 UIKit，但要隔离在独立文件/组件里，不暴露给上层；禁止使用私有 API
- 颜色必须使用 docs/design-system.md 中定义的 Color Token，禁止硬编码 hex
- 禁止硬编码用户可见文案（包括写死在代码中的标题、按钮文案、提示语、错误文案、空状态文案等）；统一使用 `Localizable.xcstrings` 管理并通过本地化 key 调用。仅允许技术性常量（如日志 tag、内部调试标记、协议字段）以代码常量形式存在，且不得直接面向用户展示。
- 所有 View 必须支持 Dark Mode
- 动画统一：标准交互用 .spring(duration: 0.3, bounce: 0.2)
- 信息密度必须服务于当前任务；如果上层页面已经提供了足够上下文，当前页面只保留完成当下操作所必需的信息，避免重复展示同一信息。
- 问题排查时避免发散猜测；若当前信息不足以可靠定位问题，应先明确提出所需的最小补充信息（复现步骤、报错文本、截图/录屏、设备与系统版本等），再继续分析与实现，以提升排查效率和结论可信度。
- 问题修复优先采用根因治理而非补丁叠加；默认从正确性、执行效率、性能、稳定性和可维护性出发设计方案，避免以”能跑就行”的偏方替代长期可持续实现。仅在必须临时止血时允许短期兜底方案，并需明确标注风险、适用范围与后续回收计划。典型反模式：用 `DispatchQueue.asyncAfter` 硬编码延迟来”等待”另一个异步过程（如动画）结束——这会把两处时长隐式耦合，任一改动都可能静默失效；正确做法是用该过程自身的完成回调（如 `addCompletion`、`onCompletion` 闭包）来驱动状态变化，让生命周期由事件而非时间控制。
- 对迭代中的排查/优化任务，必须执行“改动有效性审计”：持续回看本轮已做改动，区分有效/无效/副作用改动。凡是“无明显收益 + 引入复杂度或潜在性能/稳定性风险”的改动，应及时回退，不得因投入成本而保留。允许尝试很多方案，但最终合入代码应保持最小必要集合（Minimal Effective Set）：只保留能被验证带来正向效果、且维护成本可控的改动，并在文档中记录“改动内容 → 结果 → 去留决策”。
- 新 View 必须注入 store / router（通过 @EnvironmentObject）
- NavigationRouter.path 操作统一走 router，禁止在子 View 里自行维护 NavigationPath
- SwiftData 变更必须考虑 migration，不能直接改 model schema
- 新功能开发前先写 specs/ 下的 spec 文件，确认后再实现
- **Live Activity 数据同步**：TripStore 中任何修改物品数量（add/remove/merge）、行程信息（name/destination/date）、打包状态的函数，必须调用 `LiveActivityManager.shared.update(for:)` 或 `end(for:)`。删除行程调用 `end`，其余调用 `update`。仅 iOS（`#if !targetEnvironment(macCatalyst)`）。
- **Widget Extension 文件约定**：`CarryWidget/` 下所有文件仅属于 CarryWidgetExtension target，不得与主 app target 混用；跨 target 共享的类型统一放 `SharedSources/`，通过 pbxproj `PBXSourcesBuildPhase` 显式加入两个 target
- **Widget 本地化**：widget 使用 `CarryWidget/Localizable.xcstrings`，不共享主 app 的 xcstrings；新增 widget 文案必须同步补全 9 种语言

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

## 文件索引
- docs/design-system.md：视觉规范与组件标准
- docs/architecture.md：架构与模块说明
- docs/decisions.md：决策日志
- docs/progress.md：进度追踪
- specs/：功能 spec 文件目录

## 文档按需读取索引

> 本节告诉 Claude 在什么场景下读取哪个文档，避免每次都加载全部内容。

| 场景 | 需要读取 |
|------|---------|
| 每次会话开始（建议） | `docs/progress.md` — 了解当前进度与上次改动 |
| 实现任何 UI / 视觉需求 | `docs/design-system.md` — Color Token、组件规范、Mac Catalyst 面板规格 |
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
