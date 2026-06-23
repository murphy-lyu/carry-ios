# 地面 / 水路交通字段（火车 · 巴士 · 渡轮）

Status: Shipped（2026-06-23）

## 背景
交通段（`TransportSegment`）原以航班为主。火车/巴士/渡轮缺专属字段（车厢、席别、线路名、类型），
且沿用航班的「Code / Platform / Flight number / Booking code」文案与字段，不贴这些交通方式。本次为
火车/巴士/渡轮补齐字段并统一文案，航班/租车不变。

## 字段矩阵（按 mode 显隐 / 文案）

| 字段 | Flight | Train | Bus | Ferry |
|---|---|---|---|---|
| 顶部编号(`number`) | Flight number | Transport number | Transport number | Transport number |
| Route name(`routeName`，新) | — | ✓ | ✓ | ✓ |
| 承运方(`carrier`) | Airline | Operator | Operator | Operator |
| 端点 Code(`fromCode/toCode`) | ✓(IATA) | — | — | — |
| 端点 Platform(`fromTerminal/toTerminal`) | ✓(航站楼) | — | — | — |
| 预订码(`confirmationCode`) | Booking code | Reservation code | Reservation code | Reservation code |
| Coach number(`coachNumber`，新) | — | ✓ | — | — |
| Seat(`seat`) | ✓ | ✓ | ✓ | ✓ |
| Seat class(`seatClass`，新) | (用 `cabinClass` 枚举) | ✓ | ✓ | — |
| 类型(`serviceType`，新) | Aircraft(`aircraftType`) | Train type | Bus type | Ferry type |
| E-ticket / Cabin / Duration / Distance | ✓(航班专属) | — | — | — |

## 新增 model 字段（`TransportSegment`，全默认值 → SwiftData 轻量加法迁移，不升 schema）
`routeName` / `coachNumber` / `seatClass` / `serviceType`。全闭环：init + `TripStore`(addTransportSegment/
updateTransportSegment/duplicateTrip) + `DataBackupManager`(备份结构可选字段 + 双向映射) + 编辑 + 详情。
均按 mode gate 保存（切到不适用 mode 不串）。

## 文案 / 占位
- 编号统一 `transport_number`（火/巴/渡）；`carrier` 复用既有 `operator`（火/巴/渡）。
- 预订码按 mode：航班/租车 `confirmation`(Booking code)、火/巴/渡 `reservation`(Reservation code)。
- 类型按 mode：`train_type`(占位 Intercity / 城际) · `bus_type`(Shuttle / 接驳巴士) · `ferry_type`(Fast ferry / 高速渡轮)。
- 占位：Seat `11A`、Coach `08`(数字为主，字母+数字过滤)、Seat class `First class`(自由文本，各国席别名差异大、不做 picker)、Route name 自由文本(京沪高铁 / Eurostar)。
- 全部 9 语补齐（zh-Hans/zh-Hant 非简繁转换：席别/座位等級、车厢号/車廂號、城际/城際…），改后 `scripts/i18n-audit.py` [E]=0。

## More 段顺序
- 火/巴/渡：Reservation → Coach(仅火) → Seat → Seat class(火/巴) → Type。
- 航班/租车：保持原顺序（Seat → Cabin → Booking → E-ticket → Aircraft / 租车 Vehicle·Plate·Phone）。
- 详情信息卡 ground/sea 同序：Route name → Reservation → Coach → Seat → Seat class → Type。

## Ferry vs Cruise（边界）
Ferry = 点对点交通段（A→B 一段），归 `TransportSegment`。Cruise = 多日「住宿+活动+移动」合一的体验，
不套交通段模型，**本轮不做**（以后单独立项）。

## 注意（xcstrings 工作流坑）
改 xcstrings 后**别再跑 `xcodebuild`**：构建会重写 catalog、把代码插值 glue key（` · %@`、`%@ → %@`）的
非英译清掉、并给新 code 字符串生成空 stub → 制造重复/缺译。正确做法：代码先 build 验证，再从 HEAD 文本
重建 xcstrings（HEAD + 本次 key 改动）、跑 i18n-audit [E]=0、然后提交且**不再 build**。
