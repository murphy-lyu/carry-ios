# 决策日志

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

## 待补充
每次开发中产生新的架构或设计决策，在此追加。
格式：## YYYY-MM 类别 + 说明 + 原因 + 放弃方案
