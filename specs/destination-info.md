# Destination Info — Spec

> **Status: Pending**

## 功能定位

在 PackingListView 顶部展示三类目的地实用信息，帮助用户打包前做出更好的决策：

| 模块 | 数据来源 | 核心价值 |
|------|---------|---------|
| 天气预报 | WeatherKit（Apple 原生，免费） | 行程期间每日天气，决定带什么衣物/雨具 |
| 充电插头 & 电压 | 静态本地数据（按 countryCode 查询） | 是否需要转换器/变压器 |
| 货币 | 静态本地数据（按 countryCode 查询） | 目的地使用什么货币 |

实时汇率**不在本版本范围**（需要第三方 API，暂缓）。

---

## UI 位置

**PackingListView** 顶部，行程标题/日期下方，packing list 内容上方。

### 展示形态

新增 `DestinationInfoView` 组件，水平排列三张紧凑卡片，可横向滑动：

```
┌────────────────────────────────────────────────────────────────┐
│  ☁️ Tokyo                  🔌 Plug & Voltage    💱 Currency   │
│  [天气卡片，含城市名]        [插头卡片]            [货币卡片]   │
└────────────────────────────────────────────────────────────────┘
              ↑ 水平可滑动，每张卡片约 160pt 宽
```

每张卡片遵循 `design-system.md` Card 规范（Surface Card 背景，圆角 16pt，内边距 16pt，Light Mode 加阴影）。

---

## 天气卡片详细设计

### 城市名 & 多目的地切换

- 卡片顶部始终显示当前查看城市的名称
- 城市名来源：`splitCities(trip.destinationCity)` 与 `[主目的地] + additionalDestinations` 按顺序 zip，无需 SwiftData migration
- 单目的地：只显示城市名，无切换器
- 多目的地：城市名下方显示小圆点指示器（● ○ ○），点击左右切换；切换时重新展示对应城市的天气数据

```
┌─────────────────────────────────────┐
│  ☁️  Tokyo              ● ○ ○      │  ← 多目的地时显示圆点
│  Mon  Tue  Wed  Thu  Fri           │
│  ☀️   ⛅   🌧   ☀️   ☁️           │
│  24° 22° 19° 26° 23°              │
│  ─────────────────────────────     │
│  ≡ Weather                         │  ← 归因（见下方要求）
└─────────────────────────────────────┘
```

### 天气内容

- 每日 chip：星期缩写 + 天气图标（SF Symbols） + 最高温
- 行程天数 ≤ 10 天：全部展示
- 行程天数 > 10 天：只展示前 10 天（WeatherKit 免费层上限）
- 出发日距今 > 10 天：显示 "Forecast available closer to departure"（本地化 key：`destination.weather.unavailable`）
- 行程已过期：整个天气卡片隐藏

### WeatherKit 归因（合规必须）

Apple 要求展示 WeatherKit 数据时必须包含归因标记。实现方式：

```swift
// 通过 WeatherService 获取官方归因信息
let attribution = try await WeatherService.shared.attribution
// attribution.combinedMarkLightURL / combinedMarkDarkURL — 官方 logo（PNG，AsyncImage 加载）
// attribution.legalPageURL — 法律条款页链接
```

归因位置：天气卡片底部，小字 + 点击跳转：
```swift
Link(destination: attribution.legalPageURL) {
    AsyncImage(url: colorScheme == .dark
        ? attribution.combinedMarkDarkURL
        : attribution.combinedMarkLightURL)
    .frame(height: 12)
}
```

---

## 插头卡片

- 卡片标题："Plug & Voltage"
- 显示目的地所用插头类型（Type A/B/C/G 等）+ 电压（如 230V / 50Hz）
- 多目的地时，所有目的地插头类型取**并集**，去重后展示（不做切换，直接展示出行涉及的全部类型）
- 国家不在数据表时：整张卡片隐藏

---

## 货币卡片

- 卡片标题："Currency"
- 显示货币代码 + 符号（如 JPY ¥ / EUR € / THB ฿）
- 货币名称：仅显示货币代码 + 符号，不显示完整名称（避免本地化工作量过大）
- 多目的地时，所有目的地货币取**并集**，去重后展示（最多 3 个，超出省略）
- 国家不在数据表时：整张卡片隐藏

> **⚠️ 货币本地化待办**
> 当前版本货币名称仅显示代码（如 "JPY"）和符号（如 "¥"），不显示语言化的货币名称，避免 80+ 国家 × 9 语言的翻译工作量。
> 后续版本可利用 `Locale` + `Locale.commonISOCurrencyCodes` 自动获取系统本地化货币名称，无需手动维护 xcstrings。

---

## 数据架构

### 天气 — WeatherKit

**前置工程配置（实现前必做）：**
1. Xcode → Target → Signing & Capabilities → 添加 `WeatherKit` capability
2. Apple Developer Portal → App ID → 开启 WeatherKit
3. `.entitlements` 文件中确认 `com.apple.developer.weatherkit = true`

**调用方式：**
```swift
import WeatherKit
import CoreLocation

let weather = try await WeatherService.shared.weather(
    for: CLLocation(latitude: lat, longitude: lon),
    including: .daily
)
// weather.dailyForecast: [DayWeather]
// DayWeather: .date, .condition, .highTemperature, .lowTemperature
```

**缓存策略：**
- 按 `(latitude, longitude, 日期 yyyy-MM-dd)` 组合缓存，存入内存字典（`WeatherManager` 单例管理）
- App 进入前台时，若缓存超过 3 小时则刷新
- 请求失败：有缓存则用缓存，无缓存则隐藏卡片（不显示错误状态）

**新增文件：** `WeatherManager.swift`

### 插头 & 电压 — 静态数据

**新增文件：** `PlugCatalog.swift`

```swift
struct PlugInfo {
    let types: [String]     // ["A", "B"]
    let voltage: Int        // 120
    let frequency: Int      // 60
}
let plugCatalog: [String: PlugInfo] = [
    "US": PlugInfo(types: ["A", "B"], voltage: 120, frequency: 60),
    "GB": PlugInfo(types: ["G"],      voltage: 230, frequency: 50),
    "JP": PlugInfo(types: ["A", "B"], voltage: 100, frequency: 50),
    // ...约 100 个国家
]
```

### 货币 — 静态数据

**新增文件：** `CurrencyCatalog.swift`

```swift
struct CurrencyInfo {
    let code: String    // "JPY"
    let symbol: String  // "¥"
}
let currencyCatalog: [String: CurrencyInfo] = [
    "JP": CurrencyInfo(code: "JPY", symbol: "¥"),
    "US": CurrencyInfo(code: "USD", symbol: "$"),
    // ...约 100 个国家
]
```

> 后续可改为用 `Locale(identifier: "en_\(countryCode)")` 自动推导，减少维护量。

---

## 多目的地数据恢复（无需 migration）

`DestinationEntry` 只存坐标，不存城市名。城市名通过以下方式恢复：

```swift
// 在 PackingListView 或 DestinationInfoView 内计算
let cityTokens = splitCities(trip.destinationCity)  // ["Tokyo", "Osaka"]
let coords = [(trip.latitude, trip.longitude)]
           + trip.additionalDestinations.map { ($0.latitude, $0.longitude) }
let destinations = zip(cityTokens, coords)
// → [("Tokyo", (35.68, 139.69)), ("Osaka", (34.69, 135.50))]
```

---

## 加载状态

| 状态 | 天气卡片 | 插头卡片 | 货币卡片 |
|------|---------|---------|---------|
| 坐标未解析 | Skeleton placeholder | 隐藏 | 隐藏 |
| 加载中 | Skeleton placeholder | 立即显示（静态数据） | 立即显示（静态数据） |
| 加载成功 | 展示数据 | 展示数据 | 展示数据 |
| 加载失败 / 无缓存 | 隐藏 | — | — |
| 国家不在数据表 | — | 隐藏 | 隐藏 |

整个 `DestinationInfoView`：三张卡片全部隐藏时，View 不占位。

---

## 隐私政策更新

WeatherKit 会将目的地坐标发送至 Apple 服务器获取天气数据。虽然这是行程目的地（非用户当前位置），但需要更新隐私政策：

- **Privacy Policy 页面**（https://murphy-lyu.github.io/carry-legal/privacy/）：在位置数据章节补充"目的地坐标用于通过 WeatherKit 获取天气预报"
- **App Store Privacy Nutrition Labels**：在 App Store Connect 中确认位置数据用途覆盖 WeatherKit

---

## 本地化 Keys（新增）

结构化 key，需补全 9 种语言：

| Key | 用途 | 英文参考值 |
|-----|------|----------|
| `destination.weather.unavailable` | 出发日 > 10 天时 | "Forecast available closer to departure" |
| `destination.weather.section_title` | 天气卡片标题 | "Weather" |
| `destination.plug.section_title` | 插头卡片标题 | "Plug & Voltage" |
| `destination.currency.section_title` | 货币卡片标题 | "Currency" |

---

## 不在本版本范围内

- 实时汇率
- 货币完整名称的多语言本地化（后续用 `Locale` 自动获取）
- 天气通知推送
- 多目的地各自独立的插头/货币切换（取并集已足够）
- 签证信息
- watchOS / widget
