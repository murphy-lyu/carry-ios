# 行程时间轴：任意「真实地点」间显示距离（Distance Legs）

> **Status: Draft — 待确认，未实现。** 确认后再编码。
> 关联：`itinerary-route-planning.md`（leg/距离连线既有机制）、`itinerary-transport-lodging.md`（交通段 from/to 地址字段）。

## 需求（产品话）

行程里相邻两个**真实地点**之间，只要这段距离对用户有意义，就显示「这一跳多远」。判据：**有具体落点的就显示；纯中转枢纽（机场航站楼）不显示**——因为用户真正在地面挪动的距离，是从「下机后拿到车的地方」到下一个地点，而非航站楼。

典型缺口：租车「取车点」（如「伊宁机场停车场」，有详细地址+坐标）→ 下一个地点（餐厅）**现在不显示距离**，应显示。机场（航站楼，无街道地址）→ 下一处**不显示**（现状已对）。

## 现状（已核实）

- 距离连线（leg）**只在 `地点↔地点`（`.leg`）和 `地点↔住宿`（`.lodgingLeg`）之间**插入；交通段/租车端点参与的相邻**不插**。
- 距离一律 **haversine 直线**（`RouteOptimizer.haversineMeters`）。
- **rail 连续性由节点自画**：`lineCache.connectivity[rowID]`（按「无 leg 的相邻」算每个节点上下半线），leg 行只是额外叠加「带距离的一段 rail」。→ **加 leg 是纯叠加，不动 connectivity / rail 拓扑。**

## 规则（统一，不按类型特判）

相邻两行 A→B，取 **A 的「离开点」**与 **B 的「进入点」**；两者都是「真实本地点坐标」时，插入距离连线 = `haversine(A.exit, B.entry)`。

「连接点」按行类型：
- **地点 / 住宿** → 自身坐标（**只看有无坐标**，沿用现状；不加地址要求，否则地图点选/照片回溯的无地址地点会丢现有连线 = 回归）。
- **交通段（航班/火车/巴士/渡轮）** → 离开点=**到达端**(`to`)、进入点=**出发端**(`from`)；**仅当该端 `address` 非空**才算真实落点（机场 `address` 为空 → 自然排除，无需对航班特判）。
- **租车** → 取车行=取车点(`from`)、还车行=还车点(`to`)；同样要 `address` 非空。
- **日历事件** → 不参与（只读叠加，v1 跳过）。

连带效果（已与用户确认「都可以插」）：有地址的车站会两边都出（去站多远 + 出站后多远）；交通↔交通也可能出（如还车点→巴士站）；机场两侧永不出。

## 实现要点（约 2 文件，纯叠加、不碰 connectivity）

- 新增行类型 `ItineraryRowID.geoLeg(from: ConnEndpoint, to: ConnEndpoint, day: Int)`；`ConnEndpoint`（Hashable）= `.stop(UUID)` / `.lodging(UUID)` / `.transport(UUID, arrival: Bool)`。`(from,to,day)` 在一天内唯一 → diffable id 唯一。
- `ItineraryReorderCollection.applySnapshot` 的 leg 插入 switch：**保留**现有 3 个 case（stop↔stop / stop↔lodging 不动），加 `default` 分支——`parent.connEndpoint(previous, asExit:true)` + `parent.connEndpoint(entry, asExit:false)` 都非 nil 时插 `.geoLeg`。
- `ItineraryView` 提供两个闭包：
  - `connEndpoint(rowID, asExit:) -> ConnEndpoint?`：解析连接点 + **地址门控**（交通端 `address` 空 → 返回 nil；无坐标 → nil）。模型在 ItineraryView 侧，门控在此做。
  - `geoLegContent(from, to, day)`：解析两端坐标 → haversine → `ItineraryLegConnector`（复用现有视觉，railColor 同当天色）。
- cellRegistration 加 `.geoLeg` case；左滑删除过滤、重排模式过滤里把 `.geoLeg` 与 `.leg`/`.lodgingLeg` 同等对待（不可删、重排模式隐藏）。

## 边界

- 任一端解析不出坐标/被地址门控 → **不插 geoLeg**；节点照常直连（rail 连续，与今天「无 leg 的相邻」一致）。
- 同一地点两端 → 小距离/0 km（与现有 leg 一致，不特殊抑制）。
- 距离用 haversine 直线，与现有 leg 口径一致。

## 验收

编译绿后 UI 验收：① 租车取车点（有地址）→ 下一地点显示距离；② 机场（航站楼）两侧不显示；③ 有地址的火车/巴士站两侧显示；④ 既有 stop↔stop / stop↔lodging 距离无回归；⑤ 重排模式仍隐藏所有连线；⑥ rail 连续、无悬空线头（与刚修的 reconfigure 共存）。
