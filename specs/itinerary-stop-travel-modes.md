# Itinerary Stop Travel Modes（停靠点详情：交通方式选择器 + 联动导航）

> **Status: 已拍板 Path C（2026-06-15）— 待/正实现。** 依赖 `itinerary-stop-detail.md`（路程模块）与 `itinerary-stop-navigation.md`（Get Directions / `MapNavigationService`）。

## 决策（已拍板）

参考 Tripsy「旅行时间」与一款大陆 App 评估后，**否决了「在 App 内显示各方式时长」**，原因：
- **Apple `MKDirections` 根本没有「骑行」**（枚举只有 automobile/walking/transit），算不了骑行时长；
- 要补齐就得接**高德/百度路由 Web API**（第三方依赖、坐标/限流/隐私），用户**明确不接 API**。

故采用 **Path C：交通方式【选择器】+ 联动导航，不在 App 内显时长**。

## 做什么

详情底部路程模块：在 Get Directions 之上加一个**交通方式选择器**（**驾车（默认）/ 骑行 / 步行**）。选中某方式 → Get Directions **调起外部地图时用该方式**导航。直线距离「到下一站 N 公里」保留（离线、瞬时）。

```
┌─────────────────────────────────────┐
│  [🚗 驾车] [🚴 骑行] [🚶 步行]        │  ← 选择器，默认驾车
│  ─────────────────────────────────   │
│  ➤ Get Directions                  › │  ← 用选中方式调起；App List 按方式过滤
│  9.9 km to next stop                 │  ← 直线距离，保留
└─────────────────────────────────────┘
```

## 核心：各地图 App × 方式 支持矩阵（决定 List 过滤）

| App | 驾车 | 步行 | 骑行 | URL 参数 |
|---|---|---|---|---|
| Apple 地图 | ✅ | ✅ | **❌** | `MKLaunchOptionsDirectionsModeKey`：Driving/Walking（**无骑行**）|
| 高德 | ✅ | ✅ | ✅ | `iosamap://path?...&t=` → 驾车 0 / 步行 2 / 骑行 3 |
| Google 地图 | ✅ | ✅ | ✅ | `comgooglemaps://?...&directionsmode=` → driving/walking/bicycling |
| 百度 | ✅ | ✅ | ✅ | `baidumap://map/direction?...&mode=` → driving/walking/riding |

**关键规则**：**选「骑行」时，Get Directions 的 App List 隐藏 Apple 地图**（它不支持），其余支持骑行的（高德/百度/Google）照常。驾车/步行时四家都在。

## 交互细节

- 选择器默认**驾车**；切换即改 Get Directions 调起的方式（**联动**——避免「选了骑行却调起驾车」的割裂）。
- Get Directions 行为不变（≥2 个可用 App 弹菜单、1 个直接调起），只是**可用 App = 按当前方式过滤后的已安装 App**。
- **边界**：选「骑行」且设备**只装了 Apple 地图**（无高德/百度/Google）→ 过滤后 0 个可用 App → Get Directions 置灰 + 轻提示「未安装支持骑行的地图」（不静默无反应）。
- 无坐标 / 末站：按现状（无 Get Directions / 无坐标提示），选择器可不显或显但 Get Directions 不可用。

## 范围 / 不做

- **不在 App 内显时长**（Apple 无骑行时长 + 不接 API）。直线距离仍显。
- **不接**高德/百度路由 Web API。
- 不做公交（用户去掉）。
- 不做 App 内画线 / turn-by-turn（仍调起外部地图）。

## 技术 / 标准事项（ADA·不落项）

- `MapNavigationService`：新增 `MapNavigationMode { driving, cycling, walking }`（symbol + nameKey）；`MapNavigationApp.supports(_ mode:)`（Apple 不支持 cycling）；`open(_:coordinate:name:mode:)` 各家拼对应 URL 参数；`availableApps(for mode:)` = 已安装 ∩ 支持该方式。
- `StopDetailView`：`@State navMode = .driving` + 选择器 UI（3 段，选中烟蓝/未选灰，icon+短文案）；Get Directions 用 `navApps.filter{ $0.supports(navMode) }` + `open(...mode: navMode)`；0 可用时置灰 + 提示。
- **坐标**：沿用现有（高德系 GCJ-02 直传高德/Apple，百度转 BD-09）——不因方式改变坐标处理。
- **文案 × 9 语言**：方式名（驾车/骑行/步行）、骑行无地图提示，结构化 key 显式写 en；中文全角标点。
- **埋点**：现有 `itineraryStopNavigated` 的 context 带上所选方式（mode），闭环回收「用户用哪种方式导航」。
- **无障碍**：选择器为可选中分段、有朗读标签与选中态；Get Directions/置灰态有合理朗读。
- Dark Mode：选中/未选态用语义色，明暗自适应。

## 待办 / 分阶段

1. `MapNavigationService` 加 mode 维度（enum + supports + open(mode:) + availableApps(for:)）。
2. `StopDetailView` 路程模块加选择器 + 联动 + List 过滤 + 0-可用置灰。
3. 文案 × 9 语言 + 埋点带 mode。
4. 真机验（模拟器无地图 App、无法验调起）：四家 App × 三方式调起正确、骑行时 Apple 地图隐藏、坐标准确、置灰边界。
