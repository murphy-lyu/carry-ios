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
├── CarryApp.swift          ← App 入口，ModelContainer 初始化
├── ContentView.swift       ← TabView + NavigationRouter
├── ViewModifiers.swift     ← 全局 ViewModifier
├── Models/                 ← 数据模型、Store、Manager
├── Views/                  ← 所有页面
├── Globe/                  ← 3D 地球视图（GlobeView）
└── AppIntents/             ← Siri/Spotlight 快捷指令

## 设计规范
→ 详见 docs/design-system.md
关键约定：全部 View 支持 Dark Mode，颜色使用 token 禁止硬编码。

## 当前进度
→ 详见 docs/progress.md

## 重要约定（每次必须遵守）
- 业务逻辑、页面布局、导航全部 SwiftUI；手势拦截、动画性能优化等场景允许通过 UIViewRepresentable 使用 UIKit，但要隔离在独立文件/组件里，不暴露给上层；禁止使用私有 API
- 颜色必须使用 docs/design-system.md 中定义的 Color Token，禁止硬编码 hex
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

## 文件索引
- docs/design-system.md：视觉规范与组件标准
- docs/architecture.md：架构与模块说明
- docs/decisions.md：决策日志
- docs/progress.md：进度追踪
- specs/：功能 spec 文件目录
