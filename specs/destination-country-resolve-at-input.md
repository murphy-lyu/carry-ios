# Spec：目的地国家码「输入即解析」（resolve-at-input）

Status: Shipped（2026-06-22 实现并 push 到 origin/main 至 `8218ac5`，Worker 已部署、线上验证通过；设备级验收待真机）
Owner: —
Created: 2026-06-22

实现提交：resolve-at-input `16f73c0` · 城市模式 `7e1309e` · 本地化检索 `eecd0db` · CJK 干净标签 `8218ac5`。
增补设计见文末「## 增补：城市模式 + 本地化检索（实现阶段补强）」。

## 背景与根因

地图点亮到访国家/地区，依赖 `TripBundle.countryCode`（+ `additionalDestinations[].countryCode`）。
这些码当前**只由 `destinationCity` 自由文本反解析**得到：

1. `updateCountryCode(for:city:)` 先查一张 ~600 行硬编码城市表（`cityLookup` / `countryKeywords`，
   `TripStore.swift` 2068–2790），命中即用；
2. 未命中 token 走 `CLGeocoder.geocodeAddressString` 取 `isoCountryCode`（在线）；
3. 失败由 `geocodeMissingTrips` 下次启动自愈重试。

**根问题：用「字符串反查」还原国家，是语言相关、有歧义、永不完整的逆向映射。**
- 表按特定语言拼写做 key → 日文假名/韩文谚文/欧洲本地化地名（とうきょう、서울、München、Pékin）落表外；
- 字符串歧义（雪梨=Sydney 也=梨；Springfield/Tripoli 多国同名）；
- 表是维护负债，长不全、会漂移。
- 兜底 CLGeocoder 只能在线——「任意语言自由文本 → 国家、且 100% 离线正确」用 iOS 公开 API 不存在
  （唯一离线办法是坐标点-在-国界多边形，而本项目出于合规已禁止打包国界 GeoJSON）。

## 目标

在**解析的源头**（用户从检索结果中选定地点的那一刻）用结构化数据拿到权威 **ISO 国家码**并存档，
不再事后从字符串反推。ISO 码语言无关 → App 内 9 种语言行为完全一致。

不追求「自由打字也 100% 离线正确」（不可能）；自由打字保留现有在线兜底 + 自愈。

## 设计

目的地输入从「纯自由文本」升级为「**自由文本 + 自动补全建议**」（复用现有 `StopSearchCompleter` 双源检索：
国内 MapKit/高德、海外 places Worker）。
- 用户**选中**一条建议 → 捕获该结果的权威 `countryCode`（ISO）+ 坐标，连同显示名一起暂存；建行程时直接写入
  `trip.countryCode` / `latitude` / `longitude`，**跳过文本反解析**。
- 用户**只打字不选**（或多城市文本）→ 维持现状：`updateCountryCode` 文本路径 + `geocodeMissingTrips` 自愈。
- 那张 600 行表**降级**为「仅给『打字不选』fallback 用的离线加速器」，不再是主路径（可逐步退役，本期不删）。

地图点亮逻辑**完全不动**（仍读 `trip.countryCode` → `normalizedCountryCode` 展示层归并 HK/MO/TW）。

## 分层改动

### 1. places Worker（`scripts/places-proxy/worker.js`）— 透传 country
country 已在合规检查里算好（`countryCodeOf(p)` / `obj.cc`），只需加进两处 retrieve 返回：
- Mapbox 路径（~232–240）：`country: (countryCodeOf(p) || "").toUpperCase()`
- Geoapify 路径（~253–261）：`country: (obj.cc || "").toUpperCase()`
部署后旧 App 忽略多余字段、向后兼容。**需一次 wrangler 部署**（见 docs/infrastructure.md）。

### 2. iOS `ResolvedPlace`（`AddStopView.swift`）— 带上 countryCode
- `struct ResolvedPlace` 加 `let countryCode: String`（可空默认 ""）。
- MapKit 路径 `resolveMapKit`（~190）：从 `MKMapItem.placemark.isoCountryCode` 取（**现在白拿、没存**）。
- Worker 路径 `retrieve`（~80）：`RetrieveResponse.Place` 加 `country: String?`，回填到 `ResolvedPlace.countryCode`。
- 现有 stop 入库流程不受影响（多一个可选字段）。

### 3. 主目的地输入（`TripInfoView.swift`）— 加自动补全 + 暂存结构化结果
- destination 字段下方挂建议列表（仅在该字段聚焦且非空时显示），数据来自 `StopSearchCompleter`。
- 选中建议 → `destinationCity = 显示名`，并把 `ResolvedPlace`（countryCode + 坐标）存入 `@State resolvedPrimary`。
- 用户改动文本（与已选不一致）→ 清空 `resolvedPrimary`，回退自由文本语义。
- **IME 安全红线（写回侧）**：建议列表是 destination 字段的**兄弟视图**，绝不在输入法预编辑（marked text）态改写
  TextField 文本或重建其视图树（见 `stableField` 注释——叠层显隐会打断中文选词、丢字）。只读 text、在下方渲染。
- **IME 读取侧缺陷（2026-06-26 根因修）**：SwiftUI 原生 `TextField` 在**微信等第三方输入法选词上屏**时不可靠地推进
  binding（依赖的 UIKit editing-changed 事件未触发；系统拼音输入法会触发），导致选词后**不触发检索**、要再补字才恢复。
  解法＝共享组件 `IMESafeTextField`（`ViewModifiers.swift`，`UIViewRepresentable` 包 `UITextField`，听 UIKit
  `editingChanged` 回灌 binding + 组字期不反写 + focus 桥接）。`DestinationChipsField` 与 `CarrySearchField`（添加地点/
  住宿/机场/物品库等 6 处）均已换用。新增「打字即检索/补全」类输入框一律用 `IMESafeTextField`，勿退回原生 `TextField`。

### 4. `TripInfo` / `createTrip`（`TripStore.swift`）— 接受预解析结果
- `TripInfo` 加可选 `resolvedCountryCode/lat/lon`（默认 nil）。
- `createTrip(from:)`：若带预解析码 → 直接写 `bundle.countryCode/lat/lon`，**不调** `updateCountryCode`；
  否则维持现状调 `updateCountryCode(city:)`。
- 多城市：预解析只认主目的地；其余仍走文本 fallback（`geocodeMissingTrips` 补 extras）。

### 5. fallback 与自愈 — 保留
`updateCountryCode` / `geocodeMissingTrips` / 600 行表全部保留，服务「打字不选」与历史行程。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 中文输入法选词被打断、丢字 | 建议列表为兄弟视图、预编辑态不改 TextField；上真机测微信/拼音输入法选词 |
| 自动补全网络开销 | 复用 `StopSearchCompleter` 既有 debounce（`scheduleOverseas`）+ MKLocalSearchCompleter 增量；仅聚焦时触发 |
| 选了 A 又改字 → 用了陈旧码 | 文本变动即清 `resolvedPrimary`，回退文本路径 |
| 海外 Worker 不可达 | 选不到建议时用户仍可自由打字 → 文本兜底；与现状一致 |
| 合规 | 不引入国界多边形；country 来自已在用的检索服务商字段；HK/MO/TW 归并仍只在展示层 |
| 多城市行程 | 主目的地走结构化、extras 走文本兜底，无回归 |

## 向后兼容 / 迁移
- 数据模型无破坏性变更（`TripInfo` 新增字段可选、Worker 返回多余字段被旧端忽略）。
- 历史行程不受影响；其点亮仍由 `geocodeMissingTrips` 自愈。

## 验收
- 9 种语言各输入一个海外城市，选中建议 → 立即正确点亮（无需 geocode 往返）。
- 中文输入法选词不丢字。
- 离线时仍可自由打字建行程，联网后自愈点亮。
- 国内目的地（高德源）选中同样带 country 点亮；HK/MO/TW 在大陆 storefront 归并 CN 不变。

## 暂不做（Out of scope）
- 删除 600 行表（先降级保留，后续单独评估退役）。
- 把行程内 stop 也用于点亮（点亮仍只认 trip 主/附目的地）。
- 目的地字段 placeholder/label 的硬编码英文本地化（独立问题）。

## 增补：城市模式 + 本地化检索（实现阶段补强）

resolve-at-input 落地后，QA 发现「选中即点亮」对**用户实际点的那条**永远正确，但目的地字段复用 POI 检索
导致**首条相关性差**（建行程时尚无坐标可做 proximity 偏置）：`Tokyo`→新加坡的一家店、`首尔`→巴黎的韩餐馆。
补两层把「目的地字段」做成真正的城市检索：

### A. 城市模式（`kinds=place`，提交 `7e1309e`）
目的地是「城市」语义，不该掺 POI。Worker `/suggest` 加 `kinds=place`：
- Mapbox `types=country,region,district,place,locality`（去 `poi/address/neighborhood`）；
- Geoapify `type=city`（单 type，备源；目的地是省/州的少数情形在备源路径可能漏，可接受降级）；
- 缓存键加 `&k=`，城市/POI 结果分桶。
仅「建行程·目的地」字段传 `kinds=place`（`StopSearchCompleter.placeMode` + MapKit `resultTypes=[.address]`）；
AddStop 的地点检索**不变**（仍全量 POI）。

### B. 本地化检索（`lang=`，提交 `eecd0db` + `8218ac5`）
city-mode 在硬编码 `language=en` 下**伤拉丁文本地异名**：`München`→瑞士 Münchenstein、`Roma`→Romania、
`Lisboa`→哥伦比亚、`Wien`→空（撞同名小镇/英文名不匹配）。根因：英文索引匹配不到本地拼写。
- App 把 UI 语言传给 Worker（`lang=<Bundle.main.preferredLocalizations.first>`），place 模式用作 Mapbox/Geoapify
  检索语言 → `München`+`de`→慕尼黑·德国。缓存键加 `&l=`。POI 模式仍 `en`。
- **CJK 例外**（`8218ac5`）：CJK query 已被 `translateToEnglish` 翻成英文，若再用 `language=ja/ko` 检索会拿回
  Mapbox 冗余的全层级本地名（`東京`→「日本東京都東京都」、空 secondary）。故 `searchLang` 只对
  「city-mode + **非 CJK**」取 UI 语言，CJK 一律 `en` → `東京`→`Tokyo`、`서울`→`Seoul` 干净。拉丁异名仍按 UI 语言。

### 线上验收结果（curl 模拟各语言）
9 语言输入海外城市均解析到**正确城市 + 正确 ISO 国家码**、建议文字干净：
`Tokyo/東京/首尔/Seoul/Bali/Paris` ✅；`München/Wien/Köln(de)`、`Roma(es)`、`Lisboa(pt-BR)` ✅；`慕尼黑(zh)→Munich` ✅。

### 仍待真机验（设备行为，Worker 侧已穷尽）
- 中文输入法（微信/拼音）选词不丢字；
- 国内目的地走 MapKit/高德 `isoCountryCode` 点亮（不经 Worker）；
- 端到端：选中建议 → 建行程 → 地图点亮。
