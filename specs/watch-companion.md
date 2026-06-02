# Watch Companion(Apple Watch 最小可用版)

> **Status: Draft（待评审，未实现）** — 故意做"最最最小"：只读 + 一瞥。目标是用最小的代码 / 维护成本，获得 App Store "Available on Apple Watch" 信任信号，并给真有 Watch 的旅行用户一个出门前抬腕一瞥的价值。
>
> **来源**：PM 提出"想让用户看到跨端能力，建立 Carry 不是一次性产品的信任"。

## 动机

两条平行：

1. **信任信号**（首要）：iPhone App Store 详情页有 "Also Available on Apple Watch" 标识，独立开发者能交付这个的人很少，传递"团队认真在维护"的强烈信号。
2. **真实用户价值**（次要但必须有，否则 Apple 拒）：旅行用户在打包/出门前一段时间内，会反复瞥手机看"还差几天 / 打包到哪了"。Watch 抬腕完成这件事比掏手机自然得多。

刻意**不做**：在 Watch 上创建/编辑行程、勾选物品、看清单详情、看地球 —— 屏太小、价值低、维护成本高。

## 核心设计原则

1. **只读，单向**：Watch 端**只展示** iPhone 推过来的快照；不在 Watch 上修改任何数据。完全消除双向同步复杂度（其他 Watch 类 App 的"勾选→同步→冲突"是最常出 bug 的地方）。
2. **复用 WidgetTripSnapshot**：iPhone 已有的 Widget 快照结构（`tripId / name / destinationCity / departureDate / packedCount / totalCount`）字段一致即可，Watch 端复制一份 mirror struct（同 widget 模式）。**零新模型**。
3. **WatchConnectivity 数据通道**（不用 CloudKit）：免费 Personal Team 即可用，无 entitlement 门槛；用 `transferUserInfo`（持久化、保证送达）推快照到 Watch。下周付费账号到位 + iCloud 同步上线后**仍保留 WC 通道**——它是低延迟刷新的主路径，CloudKit 同步用户行程数据，二者职责分离。
4. **Apple HIG 友好**：所有界面用系统 SwiftUI 容器，不堆装饰；Carry 的克制黑白调性正好契合 Watch 设计语言。

## 界面（仅 2 处）

### 1. 主界面（Watch app 打开后看到）

- **若有 upcoming trip**：单屏卡片
  - 顶部：目的地名（大号）
  - 中部：「X 天后出发」/「明天出发」/「今天出发」
  - 下部：打包进度条 + 「已打 18 / 24」
  - 若多个 upcoming，列表显示，最近的在最上
- **若无 upcoming trip**：空状态
  - 一行：「暂无即将出发的行程」
  - 不显示"创建行程"按钮（创建在 iPhone 上做）

### 2. Complication（表盘小组件，可选添加）

最简单形态：
- **circular**：进度环 + 中心数字（已打件数）
- **inline**：「Carry · 京都 3 天后」
- **rectangular**（modular 表盘）：目的地 + 倒计时 + 进度条

均显示**最近一个 upcoming trip**；没有 upcoming 时显示空白或 "Carry"。

不做 corner / extraLarge 等其他形态（首版收敛）。

## 数据流

```
iPhone 主 App
  │ TripStore 状态变化（创建/勾选/删除等）
  ▼
WatchConnectivity Session（iPhone 侧）
  │ transferUserInfo([WidgetTripSnapshot] JSON)
  ▼
Apple Watch
  │ WC delegate 收到 → 解码 → 写入 UserDefaults / @AppStorage
  ▼
Watch SwiftUI View 自动刷新；Complication 调 reloadTimeline
```

**关键点：**
- iPhone 端复用已有的 `WidgetTripSnapshot` 数组（已有的 widget 推送时算一次，给 WC 顺带推一次，零额外计算）
- 推送时机：与 widget 快照同步（trip 增删/勾选/打包完成等关键节点）
- Watch 端**不主动 fetch**；纯被动接收 + 渲染

## 实现要点

### 主 App 侧（小改动）

1. 新增 `WatchSessionManager`（单例）：实现 `WCSessionDelegate`，启用 `WCSession.default`
2. 在 `TripStore.publishWidgetSnapshot()`（已有）末尾顺带 `WatchSessionManager.shared.push(snapshots)`
3. 不需新 entitlement（WatchConnectivity 不需要）

### Watch App target（新建）

1. Xcode 新建 watchOS App target（你做 GUI 操作）：
   - Bundle ID: `com.murphy.carry.watchkitapp`（Apple 约定后缀）
   - Deployment: watchOS 10.0+（与 SwiftUI 现代特性匹配）
   - SwiftUI lifecycle
2. 文件结构：
   - `CarryWatchApp.swift` — `@main`
   - `WatchTripsView.swift` — 主界面
   - `WatchTripCard.swift` — 单卡组件
   - `WatchSessionDelegate.swift` — 接收 WC 数据，写入 `@AppStorage`
   - `WatchTrip.swift` — mirror struct（同 widget）
   - `CarryComplication.swift` — Complication 配置（WidgetKit timeline）
3. Watch icon：复用 `CarryLogo` 缩放

### App Store 截图

最少 1 张（Watch app 截图区独立要求）。建议 2 张：
- 1 张主界面（有 upcoming trip 的卡片）
- 1 张表盘上的 Complication 实拍

## 边界 / 陷阱

- **WC 未送达**：第一次 Watch 打开但 iPhone 没推过任何 snapshot → 空状态正常显示；不要崩。
- **iPhone 卸载 Watch 仍装**：Watch app 继续显示最后一次缓存的 snapshot，直到用户主动卸载 Watch 端。
- **数据格式升级**：mirror struct 加字段时**两端必须同步 + 字段在 Watch 侧可选 / 有默认值**（已在 `WidgetTripSnapshot` 注释里强调）。Watch 同样适用此规则。
- **Complication 刷新限额**：watchOS 对 reloadTimeline 有节流；只在 trip 真正变化时调，不要每次 snapshot push 都调。
- **过期 trip**：Watch 端不显示已出发/过期 trip（与 iPhone Widget 一致逻辑）。
- **本地化**：Watch 端文案另立 xcstrings（不与主 App 共享）；首版只做 9 语言中需要的（先全做，与主 App 一致）。
- **审核**：Apple "Designed for Apple Watch" 要求 Watch app 有真实价值。本设计"只读 + 一瞥 + Complication"属合规最小集，不是占位。

## 分阶段

| 阶段 | 内容 | 阻塞? |
|---|---|---|
| **首版上线前** | **不做**，但 spec 就绪、`WidgetTripSnapshot` 已设计为可复用 | — |
| **付费账号到位前** | 可写代码 + 真机调试（WC 不需付费 entitlement）| 否 |
| **v1.1（上线后 1–2 周）** | 完成 + 提交 ASC，触发 "Available on Apple Watch" 标识 | 等付费账号 |

## 待确认决策

1. Complication 几种形态全做（circular / inline / rectangular），还是只做 circular（最常用）？建议**全做**——增量极小，覆盖更多表盘。
2. 主界面"无 upcoming"时是否显示 past trip / dateless trip？建议**不显示**——Watch 是"glance 即将发生的事"，过去/未定的不展示。
3. 是否做 Watch app 独立打开的 detail（点击卡片进二级页看更多）？建议**首版不做**——单屏卡片够用，二级页会引诱"加更多功能"。
4. Watch icon 用现在的 CarryLogo（Thin 版）还是新设计一个 Watch 专属图标？建议**复用** CarryLogo——保持品牌识别。
