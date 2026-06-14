# 行程停靠点 · 一键调起第三方导航

> **Status: Proposed（待用户确认 → 再实现）。** 关联：`Carry/Views/ItineraryView.swift`（`TimelineStopRow` 加 trailing 按钮）、`Carry/Models/Itinerary.swift`（`ItineraryStop.coordinate` / `hasCoordinate`）、`Carry/Info.plist`（`LSApplicationQueriesSchemes`）、新文件 `Carry/Models/MapNavigationService.swift`（探测 + deep link + 坐标转换）。

## 目标
在行程规划页每个**有坐标**的停靠点行最右侧加一个导航按钮；点击弹 action sheet，列出设备上**已安装**的导航 App，用户选一个 → 调起它做「当前位置 → 该停靠点」的路线导航。

## 非目标（Non-Goals）
- 不自研「系统级导航 App 选择器」——iOS 无此 API，方案是自建 action sheet（探测已装 App）。
- 不在 app 内画导航路线 / 不做实时导航（交给第三方 App）。
- v1 出行方式固定**驾车**（驾车是「到目的地」的默认诉求）；步行/公交留作后续。
- 无坐标停靠点不支持（不显示按钮），不做按名字搜索兜底。

## 支持的导航 App 与顺序
action sheet 仅列**已安装**的（Apple 地图永远在）。顺序：

1. **Apple 地图** —— 永远可用（`MKMapItem`，无需 scheme / 无需探测）
2. **高德地图** —— `iosamap`
3. **Google 地图** —— `comgooglemaps`
4. **百度地图** —— `baidumap`（按用户要求**置于末位**）

> 顺序可后续微调；当前为推荐默认。

## 坐标系（关键 · 合规相关）
停靠点坐标源自 Apple `MKLocalSearch`：**国内设备为 GCJ-02，境外为 WGS-84**。各家要求不同，传错会整体偏移数百米：

| App | 期望坐标系 | 处理 |
|---|---|---|
| Apple 地图 | 与系统一致（国内 GCJ-02） | 直接用 `MKMapItem` |
| 高德 | GCJ-02 | 直传，URL 带 `dev=0`（表示已是高德坐标、不要再纠偏）|
| Google | WGS-84 | 直传（境外正确；国内会偏，但 Google 国内本就基本不可用，可接受）|
| 百度 | **BD-09** | **需 GCJ-02 → BD-09 转换**，URL 带 `coord_type=bd09ll` |

GCJ-02→BD-09 用公开标准算法（约 10 行，`MapNavigationService` 内）。

## Deep link 格式（起点留空 = 各 App 用自身当前定位）
- **Apple**：`MKMapItem(placemark:).openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])`，`mapItem.name = stop.name`。
- **高德**：`iosamap://path?sourceApplication=Carry&slat=&slon=&dlat={lat}&dlon={lon}&dname={name}&dev=0&t=0`
- **Google**：`comgooglemaps://?daddr={lat},{lon}&directionsmode=driving`
- **百度**：`baidumap://map/direction?destination=latlng:{bdLat},{bdLon}|name:{name}&mode=driving&coord_type=bd09ll&src=com.murphy.carry`

`{name}` 需 URL 编码。

## Info.plist
`LSApplicationQueriesSchemes` 增加：`iosamap`、`comgooglemaps`、`baidumap`（不加则 `canOpenURL` 恒返回 false）。Apple 地图无需登记。

## UI
- 位置：`TimelineStopRow` 主行最右，与 `stop.name` 同一 HStack 的尾部。
- 仅 `stop.hasCoordinate == true` 时显示。
- 图标：`arrow.triangle.turn.up.right.circle`（转向箭头 = 路线/导航）。
- 颜色：`.secondary` 中性灰（工具动作，按按钮配色 Tier 3，不染强调色）。
- 命中区 ≥ 44×44，`.contentShape(Rectangle())`，`.buttonStyle(.plain)`，避免吃掉行的点击/拖拽。
- 交互：点按 → `confirmationDialog`（action sheet），列已装 App，每项一个 Button 调起。

## 文案（9 语言，结构化 key，含 en）
- `itinerary.nav.button.a11y` —— 按钮无障碍标签（如「导航到这里」）
- `itinerary.nav.sheet.title` —— action sheet 标题（如「用哪个 App 导航？」）
- App 名称：用各自品牌名（高德地图 / 百度地图 / Google 地图 / Apple 地图），中文标点全角。

## 埋点
新增 `CarryLogger.Event`：`.itineraryStopNavigated`（context: 选了哪个 App），与按钮同次接线（埋点闭环）。

## 数据/迁移
无。纯读 `stop.coordinate`，不改 model、不动存储。

## 验收
- 有坐标停靠点显示按钮、无坐标不显示。
- 各 App 装/未装时 action sheet 正确增减；Apple 永远在。
- 真机：四个 App 各调起一次，确认落点准（**尤其百度**：对照同一 POI，转换后落点应与高德/Apple 一致，验证 BD-09 转换正确）。
- 暗色模式、9 语言、Mac Catalyst（Catalyst 上 scheme 多半探测不到第三方 App → 只剩 Apple 地图，属正常）。
