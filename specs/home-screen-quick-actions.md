# Home Screen Quick Actions — Spec

> **Status: Implemented（待真机验证）** — 2026-05-31

## 背景

长按主屏幕 App 图标弹出的快捷操作菜单（Home Screen Quick Actions，旧称 3D Touch 菜单，现由 Haptic Touch 触发）目前是空的。

Carry 已有 `CarryAppShortcuts: AppShortcutsProvider`（New Trip / Nearest Trip / Footprint），但 `AppShortcutsProvider` 只填充 Spotlight / Siri / 快捷指令 App，**不会**出现在图标长按菜单——后者是独立系统，需 `UIApplicationShortcutItems`（静态）或 `UIApplication.shared.shortcutItems`（动态）驱动。

## 目标

图标长按菜单提供 3 个快捷操作，复用现有动作语义，与 Siri/Spotlight 完全一致：

| 菜单项 | 动作 | SF Symbol | 现有 action key |
|--------|------|-----------|----------------|
| New Trip | 新建行程 | `plus` | `create_trip` |
| Nearest Trip | 打开最近行程 | `suitcase.fill` | `open_trip`（无则 fallback create） |
| Footprint | 打开足迹地图 | `globe.asia.australia.fill` | `show_map` |

## 方案

### 1. 动态 shortcutItems（非 Info.plist 静态）

启动时设置一次固定的 3 个 `UIApplicationShortcutItem`，内容不变（效果等同静态）。选动态的原因：
- 图标用 `UIApplicationShortcutIcon(systemImageName:)` 直接支持 SF Symbol，复用现有符号
- 标题走 `Localizable.xcstrings`（项目主本地化），不分散到 `InfoPlist.xcstrings`
- 代价：首次安装从未打开时图标无菜单；打开一次后永久有。对本 App 影响可忽略

### 2. 捕获触发：AppDelegate + SceneDelegate

纯 SwiftUI lifecycle 下，Quick Action 的**热启动**回调只在 `SceneDelegate.windowScene(_:performActionFor:)`。引入：
- `CarryAppDelegate: UIApplicationDelegate`（`@UIApplicationDelegateAdaptor` 挂载）→ `configurationForConnecting` 指定 `delegateClass = CarrySceneDelegate.self`
- `CarrySceneDelegate: UIResponder, UIWindowSceneDelegate`
  - `scene(_:willConnectTo:options:)` 处理**冷启动**（`connectionOptions.shortcutItem`）
  - `windowScene(_:performActionFor:completionHandler:)` 处理**热启动**
  - **不创建 window**——SwiftUI WindowGroup 仍负责 window，SceneDelegate 仅接收回调

### 3. 分发复用现有链路

SceneDelegate 把 `shortcutItem.type` 翻成现有 `carry_shortcut_action`（+ `carry_shortcut_trip_id`）UserDefaults key：
- 冷启动：`ContentView.handlePendingShortcut()` 启动时自然读取
- 热启动：发 `NotificationCenter` 通知（`.carryQuickActionTriggered`），`ContentView.onReceive` 再调一次 `handlePendingShortcut()`

`handlePendingShortcut()` 的 switch（`create_trip` / `open_trip` / `show_map`）已覆盖三种动作，导航零改动。

shortcutItem.type 命名：`com.murphy.carry.quickaction.{create_trip|nearest_trip|footprint}`，在 SceneDelegate 映射到 action key。

### 4. 本地化

复用 `CarryAppShortcuts` 已有的 3 个语义 key（`Localizable.xcstrings` 中已含 8 语言翻译，语义 key 无需 `"en"` 条目）：
- `"New Trip"` / `"Nearest Trip"` / `"Footprint"`

不新增结构化 key——quick action 标题与 Siri/Spotlight 的 `shortTitle` 本就应一致，复用同一 key 天然保证同步。

## 文件改动

- `CarryApp.swift`：加 `@UIApplicationDelegateAdaptor`；新增 `CarryAppDelegate` / `CarrySceneDelegate`；启动设置 `shortcutItems`；定义通知名
- `ContentView.swift`：`onReceive(.carryQuickActionTriggered)` → `handlePendingShortcut()`
- `Localizable.xcstrings`：3 个 key × 9 语言

## 风险与测试

- **SceneDelegate 与 SwiftUI WindowGroup 协作**：SceneDelegate 绝不能自建 window，否则黑屏/双 window。注入后须确认正常启动。
- **必须真机测两条路径**（模拟器对 Quick Action 支持不完整）：
  1. 冷启动：杀掉 App → 长按图标选动作 → 进对应页面
  2. 热启动：App 切后台 → 长按图标选动作 → 回前台进对应页面
- 三个动作 × 冷/热 = 6 个组合都要过；Nearest Trip 在无行程时应 fallback 到新建。
