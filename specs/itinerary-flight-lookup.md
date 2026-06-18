# Itinerary Flight Lookup（航班号 → 自动回填航班基础信息）

> **Status: Implemented (P1) — 编译绿 + 启动不崩 + Worker 真实联调通过（curl 验证国际/国内航班均可）。待真机走「输航班号→自动填」完整验收。未提交。**
>
> **落点**：`Carry/Models/FlightLookupService.swift`（调 Worker→解析→`FlightLookupResult`，稳处理 全/残/多实例/跨午夜）、`TransportSegment.aircraftType` 新字段（四处同步）、`TransportEditView` 航班模式「用航班号自动填」块（日期+按钮+四态，映射进表单：航司/机场/起降时刻/航站楼/机型；时刻按机场时区的时:分存、dayOrder 按航班当地日期算）、`TransportDetailView` 展示机型、`scripts/flight-proxy/`（Cloudflare Worker 代理，已部署 `carry-flight.murphy-latte.workers.dev`）、`CarryLogger` 4 个 `flightLookup*` 事件、6 个 `itinerary.flight.*` 文案（9 语言）。
> **配置**：`FlightLookupConfig.proxyURLString`（Worker URL）+ `appToken`（若 Worker 设了 APP_TOKEN 要同步填）。
> **现状市场**：测试用 RapidAPI 免费档（非商用）；**上架前切 API.market Pro $5 商用档**（只改 Worker 变量、App 不动）。

> **（原 Draft 内容如下）**
>
> **已确认的产品决策（来自需求讨论 2026-06-18）：**
> 1. **起步只做「静态基础信息」，不做实时动态**：输航班号 + 日期 → 拉取尽量完整的航班基础信息（航线、计划起降时刻、航站楼、机型等），作为行程的基础展示。**不做**实际起降/延误/值机登机提醒等实时内容——那是未来 Pro 订阅阶段的事（`TransportSegment.liveStatusData` 字段已为它预留）。
> 2. **理由**：起步无收入，实时动态级 API（FlightAware/飞常准）成本高、要轮询/推送基建，一上来做等于「贷款做 App」。静态信息用便宜 freemium API 即可，价值已很大（省去手动录两端机场+时刻）。
> 3. **选型 = AeroDataBox**（$5/月 = 3000 次/月档；免费档 300–600 次/月可先验证）。唯一同时满足：便宜、自助注册、**支持按航班号 + 未来日期查计划信息**。备选 AviationStack 免费档非商用 + 未来航班端点被限流，FlightAware/飞常准留给 Pro 阶段。调研见对话记录。
> 4. **一次性「富化」、非持续依赖**：仅在用户录入时调 1 次 API，结果写进 `TransportSegment` 静态字段，之后永不再调 → 用量 = 航班录入数，极低。
> 5. **优雅降级**：查不到/超额/网络失败 → 回退现有**手动录入**（机场走本地 `AirportDatabase` 搜索）。API 是增强、不是命脉。

## 动机

`itinerary-transport-lodging.md` 已让航班成为独立的 `TransportSegment`（边），`itinerary-airport-search.md` 让用户能搜机场回填坐标/时区。但当前**录一个航班要手动选两端机场 + 填起降时刻 + 航站楼**，繁琐。

Flighty/Tripsy 的体验是「输航班号 + 日期 → 自动带出全部」。Tripsy 用 FlightAware + FlightStats，且把**实时动态做成 PRO 订阅**（印证实时=付费）。Carry 起步阶段只取其「静态自动回填」这一半——用便宜 API 把录入从「手动填 N 个字段」变成「输航班号 + 日期」，与现有架构严丝合缝、零 schema 风险。

## 范围

**做（P1）**：
- 在航班录入界面（`TransportEditView`，`mode == .flight`）增加「输航班号 + 日期 → 查询 → 自动回填」。
- 回填：航司、航班号、出发/到达机场（IATA + 名称）、计划起降本地时刻、航站楼、（可选）机型。
- 机场坐标/时区**不依赖 API**，用返回的 IATA 在本地 `AirportDatabase` 解析（沿用现有范式，保证跨时区显示正确）。
- 查不到/失败 → 提示 + 回退手动。

**不做（明确边界，留 Pro 阶段）**：
- 实时动态：实际起降、延误、登机口实时变更、行李转盘。
- 值机/登机/延误**推送提醒**（要轮询/推送基建）。
- 历史航班统计、准点率。
- 大陆国内航班的高准确度实时（需飞常准，Pro 阶段再叠）。

## 数据流（一次性富化）

```
用户输 航班号(如 MU5101) + 日期
        │
        ▼ (调用一次)
  [代理/客户端] → AeroDataBox  flight by number + date
        │  返回：航司、两端 IATA、计划起降本地时刻(+UTC)、航站楼、机型、状态
        ▼
  按 IATA 在本地 AirportDatabase 解析两端机场 → 坐标 + IANA 时区 + 本地化名
        │
        ▼
  映射进 TransportEditView 的 @State 字段（用户可再改）→ 保存即写入 TransportSegment
        │
        ▼
  之后纯静态展示，永不再调 API
```

**关键：API 只负责「这趟航班是哪两个机场 + 什么时刻」；坐标/时区一律走本地机场库**——既降低对 API 数据质量的依赖，又复用 `itinerary-airport-search.md` 的成果、保证 `fromTimeZoneId/toTimeZoneId` 正确（跨时区起降时长计算依赖它）。

## 字段映射（API → TransportSegment）

| TransportSegment 字段 | 来源 | 备注 |
|---|---|---|
| `modeRaw` | 固定 `.flight` | |
| `carrier` | API 航司名（或本地航司表美化） | |
| `number` | 用户输入 / API 规整 | |
| `fromCode` / `toCode` | API IATA | |
| `fromName` / `toName` | **本地 AirportDatabase**（按 IATA，本地化名） | API 名仅兜底 |
| `fromLatitude/Longitude` / `toLatitude/Longitude` | **本地 AirportDatabase** | 不用 API 坐标 |
| `fromTimeZoneId` / `toTimeZoneId` | **本地 AirportDatabase**（IANA） | 跨时区时长正确的关键 |
| `fromTerminal` / `toTerminal` | API（常缺，可空） | |
| `departDayOrder` | 由 API 出发日期 − 行程出发日 推算 | 对齐 `ItineraryDay.sortOrder` |
| `departLocalMinutes` | API 计划出发本地时刻 → 自午夜分钟 | |
| `arriveDayOrder` | 由 API 到达日期推算（红眼可 > departDayOrder） | 模型已支持跨天 |
| `arriveLocalMinutes` | API 计划到达本地时刻 | |
| `liveStatusData` | **不填**（Pro 阶段实时动态用） | |

**待定（产品决策）**：机型（aircraft type）当前 `TransportSegment` **无对应字段**。两个选项：① 加一个可选 `aircraftType: String = ""`（发布前轻量迁移、零风险）；② 暂存进 `note`。倾向 ①（「尽量完整」且发布前加可选字段无迁移痛点）。**需你拍板。**

## 交互（挂在 TransportEditView 航班模式）

1. 航班模式表单**顶部**加一块「**用航班号自动填**」：航班号输入框 + 日期（默认取该交通段所在天的日期）+「查询」按钮。
2. 点查询 → loading（按钮转圈/禁用）→
   - **成功**：回填上述字段，给一个轻提示「已自动填入，可修改」。用户仍可手动改任意字段（API 是起点不是终点）。
   - **查不到**（航班号/日期无匹配）：提示「没查到这趟航班，可手动填写」，不清空用户已填内容。
   - **失败**（网络/超额）：提示「查询暂不可用，可手动填写」，回退手动。
3. 手动录入路径**完全保留**（现有 `AirportSearchSheet` 等不动）——自动填只是加速器。
4. 一次只富化当前这一段；不批量。

## 选型与成本控制

- **AeroDataBox**：走 RapidAPI 或 API.market；起步 $5/月（3000 次）或先用免费档验证。**商用建议至少上 $5 付费档**（免费档条款常为非商用）。
- **用量极低**：1 次/航班录入，且**可缓存**（同一 `航班号+日期` 结果可复用）。3000 次/月 ≈ 数千次航班录入，远超起步所需。
- **API Key 处理（二选一，倾向前者）**：
  - **代理（推荐）**：架免费 **Cloudflare Worker**（0 成本）→ App 调自家代理 → 代理调 AeroDataBox。好处：**藏 key** + **服务端缓存同一航班**（多人同航班只算 1 次）+ 可限流防刷。
  - **直连（可起步）**：端上直调，key 设**硬性月额度上限**，最坏损失封顶。先验证可用此法，后续再迁代理。
- **⚠️ 大陆国内航班覆盖**：AeroDataBox 全球聚合，**国内准确度未必够**。起步**接受局限 + 失败回手动**（有机场库兜底），**不为此买飞常准**；Pro 阶段做大陆实时再叠飞常准。

## 数据覆盖现实（2026-06-18 真实联调验证）

实测三条真实响应（免费档 Basic 质量）：
- **国际 AA100（JFK→LHR）**：出发 + 到达**都完整**。
- **大陆国内 MU5433（浦东 PVG→重庆 CKG）**：出发 + 到达**都完整**（IATA、计划起降含时区、航站楼、坐标）。
- **MU5101（沪→京）**：出发端只有城市名「Shanghai」、残缺——但**这趟航班本身数据稀烂（连 Flighty 都搜不到）**，是个坏样本，不代表国内普遍情况。

→ **修正结论**：AeroDataBox **国际 + 大陆国内都覆盖良好**（不是之前误判的「国内弱」）。**个别航班**（如 MU5101）可能在任何地区都数据残缺 → App 必须**对部分数据尽力填、缺的回退手填**（这是少数边界，非常态）。飞常准仍留 Pro 阶段做更强的实时动态，但**静态信息 AeroDataBox 已够用**。

**解析要点**：查一个日期可能返回**多个航班实例**（不同日期/经停，如 MU5433 返回 6/19 + 6/20 两班）→ App 须挑出**出发日期匹配**的那班（出发无时刻时退到达日期、再退第一条）。**跨午夜**常见（PVG 20:50 起飞、CKG 次日 00:05 到达）→ `arriveDayOrder > departDayOrder`，模型已支持。
**App 侧设计**：`FlightLookupResult` 每字段可空，有啥填啥；机场可再走本地 `AirportDatabase`（按 IATA）补全坐标/时区。已落地 `Carry/Models/FlightLookupService.swift`。

## 边界与异常

- 航班号格式：宽松解析（去空格、大写、IATA/ICAO 皆可尝试），失败即提示。
- 一个航班号当天多航段/经停：取与日期最匹配的一条；多条让用户选或取第一条（P1 取第一条 + 可手改）。
- 日期超出 API 可查范围（太远的未来）：提示「该日期暂查不到，可手动填」。
- 跨午夜/跨天：按 API 到达日期算 `arriveDayOrder`，复用模型既有跨天能力。
- 时区缺失：若本地机场库无该 IATA 时区 → 时间按无时区存（现有行为），不崩。

## 隐私

- 调用会把**航班号 + 日期**（+ 经代理则到自家服务器）发给第三方航空数据服务。非个人敏感数据，但按项目规范，**隐私政策补一句**（类比现有「地理编码/天气」条款）：航班号/日期发送至航空数据服务仅用于查询航班信息，不关联身份、不存储。中英双语 + 大陆 PIPL 文件同步（`carry-legal`）。
- `PrivacyInfo.xcprivacy`：纯网络查询，无 Required-Reason API 新增。
- App Store 隐私问卷：不新增「收集」（查询参数非用户身份数据、不外传个人信息）。

## 本地化

新增文案（航班号自动填入口、查询中、成功/查不到/失败提示、机型标签若加字段）进 `Localizable.xcstrings`，9 语言齐全、中文全角、结构化 key 显式写 en。

## 埋点（CarryLogger）

即定义即接线：`flightLookupStarted` / `flightLookupResolved`（带是否命中、航司维度）/ `flightLookupNotFound` / `flightLookupFailed`（入 `errorEvents`）。

## 分阶段

- **P1（本 spec）**：航班号→静态回填，AeroDataBox + 本地机场库，手动兜底。先直连验证或直接上 Worker 代理。
- **P2（未来 Pro 订阅阶段，单独 spec）**：实时动态（FlightAware/飞常准）、值机/登机/延误推送提醒，作为付费功能，填充 `liveStatusData`。与 Tripsy「实时=PRO」同构。

## 已确认的实现决策（2026-06-18）

1. **机型字段**：✅ 给 `TransportSegment` 加可选 `aircraftType: String = ""`（发布前轻量迁移、零风险）。同步四处：模型 + `DataBackupManager` 备份/还原 + `duplicateTrip` 深拷 + `SchemaV1`。
2. **Key 方案**：✅ **Cloudflare Worker 代理**（免费档）。App 调自家 Worker；Worker 持 RapidAPI key（作为 Worker secret，不进 App、不进 git）+ 服务端缓存同一 `航班号+日期` + 限流。
3. **接入渠道**：**API.market**（前身 MagicAPI）——AeroDataBox 在此 Pro 档约 **$5/月、6000 次**，比 RapidAPI（最低商用 $49.99/月）便宜近 10 倍。base 形如 `https://prod.api.market/api/v1/aedbx/aerodatabox`，端点 `/flights/number/{航班号}/{日期 YYYY-MM-DD}`，鉴权 header `x-magicapi-key`。（Worker 把 base/header 做成可配，将来换市场只改变量。）
4. Worker 代码 + 部署步骤见 `scripts/flight-proxy/`（随仓库版本管理，便于 solo 维护）。App 侧只配置 Worker URL（公开、无敏感）。

## 用户需自行完成的外部准备（代码无法代办）

1. 在 **API.market** 订阅 AeroDataBox **Pro（约 $5/月、6000 次、含商用许可）** → 拿到 API.market key + 确切接口 base。
2. 部署 **Cloudflare Worker**（`scripts/flight-proxy/worker.js`）→ key 设为 `MARKET_KEY` secret、base 设为 `UPSTREAM_BASE` 变量 → 拿到 Worker URL。
3. 把 Worker URL 回填进 App 配置常量（spec 实现时给出位置）。
