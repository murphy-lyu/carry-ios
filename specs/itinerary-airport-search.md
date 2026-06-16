# 机场搜索：内置机场数据库（Airport Database Search）

> Status: Implemented（待真机验收）
> 决策修订：原定"英文原名、不维护翻译表"——但发现纯英文会让中国用户中文搜国内机场
> 从能搜到变成搜不到（回归），且为防回归本就必须取中文名，故改为 **bundle 简繁中文名，
> 搜索匹配 + 按设备语言显示**（中文设备显中文、其它显英文原名）。空态不提供"手动加无坐标
> 机场"兜底入口（保持封闭集合，保证 IATA/时区完整）。
> 数据来源/许可见 `scripts/airports/README.md`。**待办：App「关于/致谢」补 OpenFlights 署名（ODbL 要求）。**
> 关联：`itinerary-transport-lodging.md`、`itinerary-route-planning.md`
> 数据模型：`Carry/Models/Itinerary.swift` 的 `TransportSegment`

## 背景与根因

添加航班时，出发/到达机场**搜不到境外机场**。

排查结论（已核实，非猜测）：

1. 机场搜索没有独立实现，复用了通用地点搜索 `StopSearchCompleter`
   （`AddStopView.swift:17-48`），底层是 Apple `MKLocalSearchCompleter`。
2. 大陆设备上 MapKit 的 POI 数据由 Apple 自动切到高德，**境外机场覆盖/优先级差**，
   且这是系统按设备区域锁定的行为，App 端无法切换供应商（"按目的地切高德/Google"在
   MapKit 框架内不可行）。
3. 次因：搜索框对行程目的地坐标做了 150km 区域偏置（`AddStopView.swift:32-38`），
   目的地在国内时进一步把境外机场排除在外。
4. 通用 POI 搜索**给不出 IATA 码和 IANA 时区**——而 `TransportSegment` 早已预留
   `fromCode`/`toCode`（IATA）、`fromTimeZoneId`/`toTimeZoneId`（跨时区显示用），
   现状下这些字段在机场选点时始终为空。

**根因解**：航班的机场选点不应挂在通用地图 POI 搜索上，改用**内置机场数据库**
（按 IATA/ICAO 编码），与设备区域、地图供应商解耦。这也是 Flighty / Tripsy 等航班
App 的标准做法，并为路线图「航班动态」铺底（航班 API 普遍以 IATA 为 key）。

## 范围

- **仅作用于 `TransportMode.flight` 的出发/到达机场选点。** 其它交通方式（火车站/汽车站/
  港口）维持现有 `MKLocalSearchCompleter` 行为，不在本 spec 内。
- 不接任何航班动态 API（`liveStatusData` 仍留空）。
- 不改 SwiftData schema（字段已存在，无 migration）。

## 数据集

- 来源：OurAirports 开放数据（public domain）。
- 裁剪规则：仅保留 `type ∈ {large_airport, medium_airport}` 且**有 IATA 码**的机场，
  约 8000+ 个，覆盖所有有定期民航航班的机场；剔除 small/heliport/closed/私人机场。
- 每条记录字段：`iata`、`icao`、`name`（英文原名）、`city`、`country`(ISO)、
  `lat`、`lon`、`tz`(IANA 时区，OurAirports 自带)。
- 打包形态：裁剪后的精简 JSON（或更紧凑的二进制），随 app bundle 一起发布，**离线可用**。
  体积预期 < 1MB（裁剪后），构建期校验体积上限。
- 机场名是数据集英文原名，**属用户可见内容型数据，原样展示、不翻译**（与"地点名不翻译"
  约定一致）。城市/国家可用于辅助显示与搜索匹配。

## 检索

新增 `AirportDatabase`（单例，懒加载，纯内存索引）：

- 启动不阻塞：首次进入航班机场选点时懒加载并建索引。
- 匹配维度（任一命中即返回）：IATA 精确/前缀、ICAO 前缀、机场名包含、城市名包含。
- 排序：IATA/城市精确匹配优先 → 大机场（large_airport）优先 → 名称匹配。
- **全球无区域过滤、无目的地偏置**（境外机场搜不到的根因正是偏置/区域，这里不再引入）。
- 纯本地匹配，瞬时返回，无网络。

## 接入点

- `TransportEditView`：当 `mode == .flight` 时，出发/到达地点选择改走新的
  `AirportSearchSheet`（基于 `AirportDatabase`），而非现有 `ItineraryPlaceSearchSheet`。
- 选中机场后回填 `TransportSegment`：
  - `fromName`/`toName` ← 机场名
  - `fromCode`/`toCode` ← IATA
  - `fromLatitude/Longitude`、`toLatitude/Longitude` ← 机场坐标
  - `fromTimeZoneId`/`toTimeZoneId` ← IANA 时区（首次让这两个字段真正被填上）
- 写入仍走现有 store 漏斗，遵守 `CostBearing` 等既有约定（本 spec 不碰费用字段）。

## UI

- `AirportSearchSheet`：常驻搜索框 + 结果列表，复用 Carry 既有搜索组件与 design token。
- 列表每行：机场名（圆体可用于 IATA 角标）+ `IATA · 城市, 国家` 副标题。
- 空态/无结果：提示按 IATA 码或城市名搜索；不提供"手动加无坐标机场"入口
  （机场是封闭集合，强约束到数据库内，保证 IATA/时区完整）。
- Dark Mode、9 语言文案齐全（新增 key 同步补全；机场名本身不进 xcstrings）。

## 本地化

- 界面文案（搜索框 placeholder、空状态、副标题模板等）走结构化 key，补全 9 语言。
- 机场名/城市名为数据内容，原样显示，不本地化。

## 验收

- 大陆设备 + 国内目的地行程，添加航班搜 "JFK"/"纽约"/"Tokyo"/"羽田" 均能命中境外机场。
- 选中后 IATA、坐标、时区三项都正确回填（检查 `fromCode`/`fromTimeZoneId` 非空）。
- 离线（飞行模式）下机场搜索照常可用。
- 非 flight 交通方式的地点搜索行为不变。

## 不做（明确边界）

- 不做航班号自动带出航线/机场（属航班动态范畴，后续 spec）。
- 不做机场数据的远程更新（首版随 bundle，足够稳定；如需更新另起）。
- 不替换通用地点搜索（仅航班机场场景切换）。
